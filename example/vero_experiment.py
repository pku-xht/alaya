#!/usr/bin/env python3
"""Time-bounded fresh Vero runs and a matched ask_user pilot (Linux/WSL)."""
from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from vero_smoke import call, save, instruction_delivery

MODEL = "xmcp:closeai/gpt-5.4-mini"
TASK = (
    "Read INSTRUCTION.md and complete the Vero primepy code-and-proof task. "
    "You have at most 30 minutes of wall-clock time, with no model-turn limit. "
    "Implement the allowed code slots and prove the fixed specifications in the proof slots. "
    "Do not change specifications or files outside the allowed slots. "
    "Do not use native_decide or new axioms. Lean 4.29.1 is installed. "
    "Call lake build to inspect feedback. Maximize correctly proved specifications; "
    "do not claim success based on a build that contains sorry. "
    "Use submit when finished. Network is disabled."
)


def cleanup_containers(data):
    """Only stop containers mounting this run's disposable workspace."""
    ids = call(["docker", "ps", "-q"]).split()
    removed = []
    for ident in ids:
        info = json.loads(call(["docker", "inspect", ident]))[0]
        if any(m.get("Source") == str(data / "work") and
               m.get("Destination") == "/workspace" for m in info["Mounts"]):
            call(["docker", "rm", "-f", ident])
            removed.append(ident)
    return removed


def step(alaya, data, agent, state, seconds):
    cmd = [str(alaya), "step", state, "--data", str(data), "--agent", agent,
           "--model", MODEL, "--temperature", "0", "--json"]
    with subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, start_new_session=True) as proc:
        try:
            stdout, stderr = proc.communicate(timeout=seconds)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
            cleanup_containers(data)
            raise
    if proc.returncode not in (0, 3):
        raise subprocess.CalledProcessError(proc.returncode, cmd, stdout, stderr)
    result = json.loads(stdout.strip())
    if (proc.returncode == 3) != bool(result["question"]):
        raise ValueError("Waiting exit code does not match question state")
    return result


def continue_run(alaya, data, agent, state, budget, path, *, no_more_help=False):
    record = {"start": state, "agent": agent, "model": MODEL,
              "budget_seconds": budget, "steps": [], "replies": [],
              "started_at": datetime.now(timezone.utc).isoformat()}
    start = time.monotonic()
    save(path, record)
    while True:
        remaining = budget - (time.monotonic() - start)
        if remaining <= 0:
            record["stop_reason"] = "wall_clock_limit"
            break
        try:
            result = step(alaya, data, agent, state, remaining)
        except subprocess.TimeoutExpired:
            record["stop_reason"] = "wall_clock_limit_in_flight_turn_discarded"
            break
        except subprocess.CalledProcessError as exc:
            detail = exc.stderr or ""
            for key in ("XMCP_API_KEY", "LLM_API_KEY"):
                if os.environ.get(key):
                    detail = detail.replace(os.environ[key], "[REDACTED]")
            record["error"] = detail[-3000:]
            record["stop_reason"] = "execution_error"
            break
        state = result["state"]
        result["elapsed_seconds"] = round(time.monotonic() - start, 3)
        record["steps"].append(result)
        record["terminal"] = state
        save(path, record)
        print(json.dumps({"run": path.stem, "turn": len(record["steps"]), **result}), flush=True)
        if result["outcome"]:
            record["stop_reason"] = result["outcome"]
            break
        if result["question"]:
            if not no_more_help:
                record["stop_reason"] = "Waiting"
                break
            reply = "No further answer is available. Continue solving independently."
            child = call([alaya, "reply", state, reply, "--data", data])
            record["replies"].append({"question": state, "state": child, "text": reply})
            state = child
    record["terminal"] = state
    record["elapsed_seconds"] = round(time.monotonic() - start, 3)
    save(path, record)
    return record


def evaluate(alaya, data, benchmark, state, dest):
    command = shlex.join([sys.executable, str(Path(__file__).with_name("vero_smoke.py").resolve()),
                          "grade", str(benchmark), "{checkout}", "{out}"])
    start = time.monotonic()
    evaluation = call([alaya, "eval", state, "--data", data, "--grader", command,
                       "--timeout", "900"], timeout=960).splitlines()[-1].split()[0]
    call([alaya, "checkout", evaluation, dest, "--data", data, "--evidence"])
    return {"state": evaluation, "parent": state,
            "seconds": round(time.monotonic() - start, 3),
            "verdict": json.loads((dest / "verdict.json").read_text())}


def baseline(args):
    from vero.generation.sandbox import create_sandbox
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    (root / "bin").mkdir()
    alaya = root / "bin" / "alaya-baseline"
    shutil.copy2(args.alaya, alaya)
    benchmark = args.vero.resolve() / "benchmarks" / "primepy"
    source, data = root / "source", root / "trajectory"
    create_sandbox(benchmark, source, mode="codeproof")
    image = call(["docker", "image", "inspect", args.image, "--format", "{{.Id}}"])
    delivery = instruction_delivery(root, TASK, source / "INSTRUCTION.md")
    state = call([alaya, "root", TASK, source, "--instruction-file", source / "INSTRUCTION.md",
                  "--data", data, "--agent", "mini-swe", "--image", image])
    manifest = {"kind": "fresh_model_answer_pilot", "model": MODEL,
                "benchmark": str(benchmark), "mode": "codeproof", "budget_seconds": args.seconds,
                "image": image, "root": state, "task": TASK,
                "instruction_delivery": delivery,
                "vero_commit": call(["git", "-C", args.vero, "rev-parse", "HEAD"]),
                "baseline_alaya_commit": call(["git", "-C", Path(__file__).resolve().parent, "rev-parse", "HEAD"]),
                "cache_initially_empty": not (data / "cache").exists()}
    save(root / "experiment.json", manifest)
    record = continue_run(alaya, data, "mini-swe", state, args.seconds, root / "baseline.json")
    manifest["baseline_evaluation"] = evaluate(alaya, data, benchmark, record["terminal"], root / "baseline-evidence")
    save(root / "experiment.json", manifest)
    call([alaya, "html", root / "report.html", "--data", data, "--agent", "mini-swe", "--hide", ".lake"])
    print(json.dumps(manifest["baseline_evaluation"]), flush=True)


def ask(args):
    from verify_replay import Store
    root = args.output.resolve()
    manifest = json.loads((root / "experiment.json").read_text())
    if "question" in manifest:
        raise ValueError("question already sampled; use a new experiment for a new question")
    baseline_record = json.loads((root / "baseline.json").read_text())
    # Fixed selection rule: latest completed, nonterminal baseline turn before submission.
    candidates = [s for s in baseline_record["steps"] if not s["outcome"] and not s["question"]]
    selected = candidates[-1]
    if selected["elapsed_seconds"] >= manifest["budget_seconds"] - 120:
        candidates = [s for s in candidates if s["elapsed_seconds"] <= manifest["budget_seconds"] / 2]
        selected = candidates[-1]
    alaya = root / "bin" / "alaya-ask"
    shutil.copy2(args.alaya, alaya)
    data = root / "trajectory"
    message = (
        "The ask_user tool is now available as an exception to the bash requirement. "
        "For this experimental checkpoint, ask exactly one concrete question about an "
        "unresolved obstacle in the current task. Call ask_user alone with a nonempty "
        "'question' string, including the relevant context. Do not execute bash, edit files, "
        "or submit in this turn. After the answer, continue the original code-and-proof task; "
        "no further assistance will be available. You have approximately " +
        str(int(manifest["budget_seconds"] - selected["elapsed_seconds"])) +
        " seconds left. Preserve the benchmark's rules and do not confuse compilation "
        "with proof completion."
    )
    start = time.monotonic()
    told = call([alaya, "tell", selected["state"], message, "--data", data])
    result = step(alaya, data, "mini-ask", told, 120)
    seconds = round(time.monotonic() - start, 3)
    save(root / "question-attempt.json", {"parent": told, **result, "seconds": seconds})
    if not result["question"]:
        raise ValueError("model did not produce the requested question; attempt saved")
    store = Store(data)
    states = store.states()
    if states[selected["state"]]["workspace"] != states[result["state"]]["workspace"]:
        raise ValueError("question changed the shared workspace")
    manifest["question"] = {
        "selection_rule": "latest nonterminal baseline turn; fallback latest before half-budget if less than 120s remains",
        "researcher_elicited": True, "checkpoint": selected["state"],
        "prefix_seconds": selected["elapsed_seconds"], "instruction": message,
        "instruction_state": told, "state": result["state"],
        "text": result["question"], "seconds": seconds}
    save(root / "experiment.json", manifest)
    print(json.dumps(manifest["question"]), flush=True)


def simulate(args):
    from verify_replay import Store
    root = args.output.resolve()
    manifest = json.loads((root / "experiment.json").read_text())
    if (root / "simulated-answer.json").exists():
        raise ValueError("answer already exists; refusing to resample silently")
    store = Store(root / "trajectory")
    states = store.states()
    q = manifest["question"]
    files = store.files(states[q["state"]]["workspace"])
    allowed = ["INSTRUCTION.md", "Primepy/Impl/Primes.lean", "Primepy/Spec/Primes.lean",
               "Primepy/Proof/Primes.lean", "Primepy/Bundle.lean", "Primepy/Harness.lean",
               "lean-toolchain", "lakefile.toml"]
    context = {"question": q["text"], "files": {
        name: store.blob(files[name]).decode() for name in allowed}, "recent_tool_feedback": []}
    current = q["checkpoint"]
    for _ in range(3):
        state = states[current]
        context["recent_tool_feedback"].insert(0, [e for e in state["appended"] if e["type"] == "observation"])
        current = state["parent"]
        if current is None:
            break
    request = {"model": MODEL.split(":", 1)[1], "temperature": 0,
               "messages": [{"role": "system", "content":
                   "For a research pilot, simulate a human Lean developer answering ONE question. "
                   "You are the same model as the solver, not a real human or a guaranteed expert. "
                   "Use only the visible task, current source and tool feedback provided below. "
                   "You have no access to reference implementations or grading results and no tools. "
                   "Give a focused, actionable answer with concrete Lean syntax or a small code sketch "
                   "where useful. Be honest about uncertainty. Preserve frozen specifications and marker "
                   "rules. Do not introduce axioms, sorry, admit or native_decide as a solution. "
                   "Do not solve unrelated APIs. Aim for at most 700 words."},
                   {"role": "user", "content": json.dumps(context, ensure_ascii=False)}]}
    save(root / "answer-context.json", context)
    save(root / "answer-request.json", request)
    start = time.monotonic()
    req = urllib.request.Request("https://llm.xmcp.ltd/chat/completions",
          data=json.dumps(request).encode(), headers={"Content-Type": "application/json",
          "Authorization": "Bearer " + os.environ["XMCP_API_KEY"]})
    with urllib.request.urlopen(req, timeout=180) as response:
        result = json.load(response)
    seconds = round(time.monotonic() - start, 3)
    answer = result["choices"][0]["message"]["content"]
    if not isinstance(answer, str) or not answer.strip():
        raise ValueError("empty simulated answer")
    save(root / "simulated-answer.json", {"kind": "same_model_simulated_human",
          "human_participant": False, "requested_model": request["model"],
          "seconds": seconds, "answer": answer, "raw_response": result})
    print(json.dumps({"seconds": seconds, "usage": result.get("usage"), "answer": answer}), flush=True)


def compare(args):
    root = args.output.resolve()
    manifest = json.loads((root / "experiment.json").read_text())
    if "branches" in manifest:
        raise ValueError("comparison already started; inspect saved records before resuming")
    answer = json.loads((root / "simulated-answer.json").read_text())
    q = manifest["question"]
    # Charge simulated-answer wait equally to both arms so solver budgets match.
    budget = manifest["budget_seconds"] - q["prefix_seconds"] - q["seconds"] - answer["seconds"]
    if budget <= 0:
        raise ValueError("no continuation time remains")
    alaya, data = root / "bin" / "alaya-ask", root / "trajectory"
    benchmark = Path(manifest["benchmark"])
    common = "\nNo further assistance is available. Continue the original task independently within the remaining budget."
    replies = {"control": "No answer is available for this question." + common,
               "simulated": answer["answer"] + common}
    manifest["comparison_budget_seconds"] = budget
    manifest["timing_policy"] = "shared prefix + question + simulated answer wait + branch execution <= 1800s; grading separate"
    manifest["branches"] = {}
    for label, text in replies.items():
        state = call([alaya, "reply", q["state"], text, "--data", data])
        manifest["branches"][label] = {"reply_state": state, "reply": text}
    save(root / "experiment.json", manifest)
    # Sequential: the CLI uses a shared disposable DATA/work directory.
    for label, branch in manifest["branches"].items():
        record = continue_run(alaya, data, "mini-ask", branch["reply_state"], budget,
                              root / (label + ".json"), no_more_help=True)
        branch["evaluation"] = evaluate(alaya, data, benchmark, record["terminal"], root / (label + "-evidence"))
        save(root / "experiment.json", manifest)
        print(json.dumps({"branch": label, **branch["evaluation"]}), flush=True)
    call([alaya, "html", root / "fork.html", "--data", data, "--agent", "mini-ask", "--hide", ".lake"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["baseline", "ask", "simulate", "compare"])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--vero", type=Path, required=True)
    parser.add_argument("--alaya", type=Path, required=True)
    parser.add_argument("--image", default="alaya-vero:lean4.29.1")
    parser.add_argument("--seconds", type=int, default=1800)
    args = parser.parse_args()
    if args.seconds <= 0 or not os.environ.get("XMCP_API_KEY"):
        parser.error("positive seconds and XMCP_API_KEY are required")
    {"baseline": baseline, "ask": ask, "simulate": simulate, "compare": compare}[args.phase](args)


if __name__ == "__main__":
    main()
