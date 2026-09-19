#!/usr/bin/env python3
"""Fresh Alaya/Vero smoke run; use --help. Requires Vero on PYTHONPATH.

The upstream checkout is a read-only dependency. Only rendered slots enter
the agent container; the reference implementation and grader stay outside.
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


def save(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def call(args, *, timeout=600):
    p = subprocess.run([str(a) for a in args], capture_output=True, text=True,
                       timeout=timeout, check=True)
    return p.stdout.strip()


def verify(root):
    from verify_replay import Store

    record = json.loads((root / "run.json").read_text())
    store = Store(root / "trajectory")
    states = store.states()  # also validates each content hash
    assert record["cache_initially_empty"], "run reused a cache"
    parent = record["root"]
    usage = {"input": 0, "output": 0, "total": 0}
    responses = observations = 0
    for step in record["steps"]:
        state = states[step["state"]]
        assert state["parent"] == parent
        for event in state["appended"]:
            if event["type"] == "response":
                responses += 1
                for key in usage:
                    usage[key] += event["response"].get("usage", {}).get(key, 0)
            if event["type"] == "observation":
                observations += 1
        parent = step["state"]
    assert parent == record["terminal"]
    assert responses == len(record["steps"]) and responses > 0, "no complete model turns"
    assert observations > 0, "no executed tool observations"
    evaluation = states[record["evaluation"]]
    assert evaluation["kind"] == "evaluation" and evaluation["parent"] == parent
    assert not any(s["parent"] == record["evaluation"] for s in states.values())
    verdict = json.loads((root / "evidence" / "verdict.json").read_text())
    assert evaluation["evaluation"]["summary"] == verdict
    evidence = store.files(evaluation["evaluation"]["evidence"])
    assert json.loads(store.blob(evidence["verdict.json"])) == verdict
    for name in ("report.json", "report.md", "artifact.json"):
        assert store.blob(evidence[name]) == (root / "evidence" / name).read_bytes()
    initial = store.files(states[record["root"]]["workspace"])
    final = store.files(states[parent]["workspace"])
    changed = sorted(p for p in initial if p.endswith(".lean") and initial[p] != final.get(p))
    result = {"checks_passed": True, "response_count": responses,
              "observation_count": observations, "usage": usage,
              "changed_lean_files": changed, "verdict": verdict,
              "terminal": parent, "evaluation": record["evaluation"],
              "elapsed_seconds": record["elapsed_seconds"],
              "stop_reason": record["stop_reason"]}
    save(root / "verification.json", result)
    return result


def grade(benchmark, checkout, out):
    from vero.generation.benchmark import Benchmark
    from vero.generation.extractor import extract, write_artifact
    from vero.evaluation.runner import run_evaluation
    from vero.evaluation.instance_check import find_instance_sites

    out.mkdir(parents=True, exist_ok=True)
    artifact = extract(checkout, Benchmark(benchmark), mode="codeproof")
    write_artifact(artifact, out / "artifact.json")
    # Grade only a newly rendered project, never the continuation workspace.
    result = run_evaluation(benchmark_dir=benchmark, artifact=artifact,
                            mode="codeproof", eval_sandbox_dir=out / "clean",
                            report_dir=out, lake_timeout=120)
    # Conservative local gate: new instance sites require review. Do not
    # silently claim that the optional upstream LLM judge has run.
    sites = find_instance_sites(sorted((out / "clean").rglob("*.lean")))
    summary = result.report.summary
    verdict = {
        "passed": summary.passed_specs == summary.total_specs and not sites,
        "score": {"passed": summary.passed_specs, "total": summary.total_specs},
        "benchmark": artifact.benchmark_id, "mode": "codeproof",
        "instance_sites": len(sites), "llm_judge_run": False,
        "acceptance": "needs_instance_review" if sites else "no_instance_sites",
    }
    save(out / "verdict.json", verdict)
    print(json.dumps(verdict), flush=True)
    return 0 if verdict["passed"] else 1


def run(args):
    from vero.generation.sandbox import create_sandbox

    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)  # a fresh cache is mandatory
    benchmark = args.vero.resolve() / "benchmarks" / "primepy"
    data = root / "trajectory"
    alaya = args.alaya.resolve()
    image = call(["docker", "image", "inspect", args.image, "--format", "{{.Id}}"])
    source = root / "source"
    create_sandbox(benchmark, source, mode="codeproof")
    task = ("Read INSTRUCTION.md and complete the Vero primepy code-and-proof task. "
            "This is an infrastructure smoke test with at most " + str(args.steps) +
            " model turns; prioritize a compiling implementation and some valid proofs. "
            "Only edit the allowed slots. Do not use native_decide or new axioms. "
            "Lean 4.29.1 is installed; call lake build to inspect feedback. "
            "Use the submit tool when finished. Network is disabled.")
    common = ["--data", data, "--agent", "mini-swe"]
    state = call([alaya, "root", task, source, "--image", image, *common])
    record = {"kind": "fresh_model_smoke", "started_at": datetime.now(timezone.utc).isoformat(),
              "model": args.model, "benchmark": "primepy", "mode": "codeproof",
              "vero_commit": call(["git", "-C", args.vero, "rev-parse", "HEAD"]),
              "alaya_commit": call(["git", "-C", alaya.parent, "rev-parse", "HEAD"]),
              "image": image, "root": state, "steps": [],
              "step_limit": args.steps, "budget_seconds": args.seconds,
              "cache_initially_empty": not (data / "cache").exists()}
    save(root / "run.json", record)
    start = time.monotonic()
    for i in range(args.steps):
        remaining = args.seconds - (time.monotonic() - start)
        if remaining <= 0:
            record["stop_reason"] = "wall_clock_limit"
            break
        try:
            step = json.loads(call([alaya, "step", state, *common, "--model", args.model,
                                    "--temperature", "0", "--json"], timeout=remaining))
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
            record["stop_reason"] = type(exc).__name__
            detail = str(getattr(exc, "stderr", "") or "")
            for key in ("XMCP_API_KEY", "LLM_API_KEY"):
                if os.environ.get(key):
                    detail = detail.replace(os.environ[key], "[REDACTED]")
            record["error"] = detail[-2000:]
            break
        state = step["state"]
        record["steps"].append(step)
        record["terminal"] = state
        record["elapsed_seconds"] = round(time.monotonic() - start, 3)
        save(root / "run.json", record)
        print(json.dumps({"turn": i + 1, **step, "elapsed_seconds": record["elapsed_seconds"]}), flush=True)
        if step["outcome"] or step["question"]:
            record["stop_reason"] = step["outcome"] or "Waiting"
            break
    record.setdefault("stop_reason", "step_limit")
    record["terminal"] = state
    record["elapsed_seconds"] = round(time.monotonic() - start, 3)
    save(root / "run.json", record)
    # The grading node is a terminal leaf, separate from future continuations.
    command = shlex.join([sys.executable, str(Path(__file__).resolve()), "grade",
                          str(benchmark), "{checkout}", "{out}"])
    evaluation = call([alaya, "eval", state, "--data", data, "--grader", command,
                       "--timeout", "900"], timeout=960).splitlines()[-1].split()[0]
    record["evaluation"] = evaluation
    call([alaya, "checkout", evaluation, root / "evidence", "--data", data, "--evidence"])
    call([alaya, "html", root / "report.html", *common, "--hide", ".lake"])
    save(root / "run.json", record)
    print(json.dumps(verify(root)), flush=True)


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "grade":
        return grade(*(Path(p).resolve() for p in sys.argv[2:]))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vero", type=Path, required=True)
    parser.add_argument("--alaya", type=Path, required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model", default="xmcp:closeai/gpt-5.4-mini")
    parser.add_argument("--steps", type=int, default=6)
    parser.add_argument("--seconds", type=int, default=1800)
    args = parser.parse_args()
    if args.steps < 1 or args.seconds < 1:
        parser.error("steps and seconds must be positive")
    if not os.environ.get("XMCP_API_KEY"):
        parser.error("XMCP_API_KEY must be supplied through the environment")
    run(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
