#!/usr/bin/env python3
"""Inspect fresh old/new Vero runs without publishing private prompts or traces.

Full request bodies, tool transcripts and source patches stay in each private
run directory. The generated comparison contains metrics, hashes and limitations.
Use --help for the four run-directory arguments; no provider calls are made.
"""
from __future__ import annotations

import argparse
import collections
import difflib
import hashlib
import json
import re
from pathlib import Path

from verify_replay import Store, require
from vero_smoke import save


def sha(data):
    return hashlib.sha256(data).hexdigest()


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def cost_fields(value, prefix=""):
    """Keep provider-reported numeric costs; never invent rates or a currency."""
    fields = {}
    if isinstance(value, dict):
        for key, item in value.items():
            path = prefix + "." + key if prefix else key
            if re.search(r"cost|price|fee", key, re.I) and isinstance(item, (int, float)):
                fields[path] = item
            fields.update(cost_fields(item, path))
    elif isinstance(value, list):
        for i, item in enumerate(value):
            fields.update(cost_fields(item, prefix + f"[{i}]"))
    return fields


def read_captures(directory, instruction):
    requests, responses, metadata = [], [], []
    unknown_usage = 0
    truncated_ids = set()
    for path in sorted(Path(directory).glob("*.meta.json")):
        prefix = str(path)[:-len(".meta.json")]
        meta = load(path)
        raw = Path(prefix + ".request.json").read_bytes()
        require(sha(raw) == meta["request_sha256"], "captured request hash mismatch")
        request = json.loads(raw)
        require(request["model"] == "closeai/gpt-5.4-mini" and request["temperature"] == 0,
                "captured request changed the model or temperature")
        requests.append(request)
        metadata.append(meta)
        if meta["response_present"]:
            raw = Path(prefix + ".response.json").read_bytes()
            require(sha(raw) == meta["response_sha256"], "captured response hash mismatch")
            try:
                response = json.loads(raw)
                responses.append(response)
                unknown_usage += int(not isinstance((response.get("usage") or {}).get("total_tokens"), int))
            except json.JSONDecodeError:
                responses.append({"non_json_response": True})
                unknown_usage += 1
        else:
            unknown_usage += 1
        for message in request["messages"]:
            if message.get("role") != "tool":
                continue
            try:
                body = json.loads(message["content"])
            except (ValueError, TypeError):
                continue
            if isinstance(body, dict) and "elided_chars" in body:
                truncated_ids.add((message.get("tool_call_id"), sha(message["content"].encode())))
    first = requests[0] if requests else None
    texts = lambda request: [m.get("content") or "" for m in request.get("messages", [])]
    result = {"request_count": len(requests), "response_count": len(responses),
              "full_instruction_in_first_request": bool(first) and any(instruction in t for t in texts(first)),
              "done_condition_seen_in_any_request": any("Anything short of all four" in t
                  for request in requests for t in texts(request)),
              "unique_truncated_results_sent": len(truncated_ids),
              "provider_reported_models": sorted({str(r["model"]) for r in responses if "model" in r}),
              "provider_cost_fields": [cost_fields(r) for r in responses if cost_fields(r)],
              "failed_transport_exchanges": [{"curl_exit_code": m["curl_exit_code"], "seconds": m["seconds"]}
                    for m in metadata if m.get("curl_exit_code") not in (None, 0)],
              "provider_error_responses": sum("error" in r for r in responses),
              "cost_status": "provider fields available" if any(cost_fields(r) for r in responses)
                  else "unavailable: provider responses contain no numeric cost/price/fee fields",
              "request_hashes": [m["request_sha256"] for m in metadata],
              "response_hashes": [m["response_sha256"] for m in metadata]}
    result["provider_usage"] = {key: sum((r.get("usage") or {}).get(key) or 0 for r in responses)
                                for key in ["prompt_tokens", "completion_tokens", "total_tokens"]}
    request_files = list(Path(directory).glob("*.request.json"))
    result["persisted_request_count"] = len(request_files)
    result["incomplete_exchange_count"] = sum(not Path(str(p)[:-len(".request.json")] + ".meta.json").exists()
                                               for p in request_files)
    result["unknown_usage_exchange_count"] = unknown_usage + result["incomplete_exchange_count"]
    return result


def output_metrics(events, all_events):
    originals = {}
    for event in all_events:
        body = event.get("content")
        if event["type"] == "observation" and isinstance(body, dict) and isinstance(body.get("output"), str):
            text = body["output"]
            originals["sha256:" + sha(text.encode())] = text
    calls = {}
    for event in events:
        if event["type"] == "response":
            calls.update({c["id"]: c for c in event["response"]["tool_calls"]})
    long_outputs = compile_calls = compile_failures = compile_errors = 0
    reads = []
    for event in events:
        if event["type"] != "observation":
            continue
        body = event["content"]
        if not isinstance(body, dict):
            continue
        call = calls.get(event["call_id"], {})
        args = call.get("arguments", {})
        if isinstance(args, str):
            args = json.loads(args)
        if isinstance(body.get("output"), str) and len(body["output"]) > 10000:
            long_outputs += 1
        if call.get("name") == "bash" and re.search(r"\blake\s+(build|lean)\b", args.get("command", "")):
            compile_calls += 1
            compile_failures += int(body.get("exit_code") not in (0, None))
            compile_errors += int(body.get("error") is not None)
        if call.get("name") == "read_output":
            text = originals.get(args.get("ref"))
            recovered = body.get("content")
            valid = isinstance(recovered, str) and text is not None and recovered == text[
                args["offset"]:args["offset"] + args["limit"]]
            if "error" not in body:
                require(valid, "read_output content differs from the original event")
                require(body["end_offset"] == args["offset"] + len(recovered), "incorrect page end")
                require(body["eof"] == (body["end_offset"] == len(text)), "incorrect EOF")
            reads.append({"reference": args.get("ref"), "offset": args.get("offset"),
                          "limit": args.get("limit"), "characters": len(recovered) if isinstance(recovered, str) else 0,
                          "exact_match": valid, "eof": body.get("eof"), "failed": "error" in body})
    attempts = sum(c["name"] == "read_output" for c in calls.values())
    return {"long_output_events": long_outputs, "reread_calls": attempts,
            "reread_results": reads, "compile_commands": compile_calls,
            "failed_compile_commands": compile_failures, "compile_execution_errors": compile_errors}


def ancestry_events(states, terminal):
    """Only the selected branch's past can justify a recovered output reference."""
    history, seen, current = [], set(), terminal
    while current is not None:
        require(current not in seen, "cyclic trajectory")
        seen.add(current)
        history.append(states[current]["appended"])
        current = states[current]["parent"]
    return [event for group in reversed(history) for event in group]


def usage_of(events):
    usage = {"input": 0, "output": 0, "total": 0}
    for event in events:
        if event["type"] == "response":
            for key in usage:
                usage[key] += (event["response"].get("usage") or {}).get(key) or 0
    return usage


def verify_sent_cache(directory, cache):
    """Bind normalized cached model inputs to actual recorded transport bodies."""
    canonical = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    sent = {canonical(load(path)) for path in Path(directory).glob("*.request.json")}
    checked = 0
    for path in Path(cache).glob("*.json"):
        key = json.loads(load(path)["key"])
        require(key["structured_output"] == "native", "unexpected structured output policy")
        payload = {**key["request"], **key["model"]}
        require(canonical(payload) in sent, "cached model input has no exact sent transport body")
        checked += 1
    require(checked > 0, "no completed model requests")
    return checked


def inspect(root):
    root = Path(root).resolve()
    pilot = (root / "experiment.json").exists()
    manifest = load(root / ("experiment.json" if pilot else "run.json"))
    store = Store(root / "trajectory")
    states = store.states()
    initial = store.files(states[manifest["root"]]["workspace"])
    instruction = store.blob(initial["INSTRUCTION.md"]).decode("utf-8")
    all_events = [e for s in states.values() for e in s["appended"]]
    captures = read_captures(root / "model-io", instruction)
    captures["cache_requests_verified_against_actual_payloads"] = verify_sent_cache(
        root / "model-io", root / "trajectory/cache/v1")
    # Old runners do not save delivery metadata, and intentionally retain the bug.
    if "instruction_delivery" in manifest:
        delivery = manifest["instruction_delivery"]
        raw_task = (root / delivery["delivered_task_file"]).read_bytes()
        require(sha(raw_task) == delivery["delivered_task_sha256"], "delivered task hash mismatch")
        require(sha(instruction.encode()) == delivery["instruction_sha256"], "instruction changed")
        require(captures["full_instruction_in_first_request"], "full instruction was not actually transmitted")
    summaries = {}
    for label in (["baseline", "control", "simulated"] if pilot else ["smoke"]):
        record = load(root / (label + ".json")) if pilot else manifest
        events = [e for step in record["steps"] for e in states[step["state"]]["appended"]]
        usage = usage_of(events)
        evidence_dir = root / (label + "-evidence" if pilot else "evidence")
        report, artifact = load(evidence_dir / "report.json"), load(evidence_dir / "artifact.json")
        final = store.files(states[record["terminal"]]["workspace"])
        changed = sorted(n for n in set(initial) | set(final)
                         if n.endswith(".lean") and not n.startswith(".lake/") and initial.get(n) != final.get(n))
        start = store.files(states[record.get("start", manifest["root"])]["workspace"])
        segment_changed = sorted(n for n in set(start) | set(final)
                         if n.endswith(".lean") and not n.startswith(".lake/") and start.get(n) != final.get(n))
        patch = []
        for name in changed:
            old = store.blob(initial[name]).decode() if name in initial else ""
            new = store.blob(final[name]).decode() if name in final else ""
            patch.extend(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
                                             fromfile="initial/" + name, tofile=label + "/" + name))
        (root / (label + "-source.patch")).write_text("".join(patch), encoding="utf-8")
        filled = collections.Counter(slot["key"] for slot in artifact["slots"] if slot["found"]
            and not slot["is_empty"] and not slot["contains_sorry"] and not slot["contains_admit"]
            and not slot["contains_axiom"])
        summary = {"turns": len(record["steps"]), "seconds": record["elapsed_seconds"],
                   "budget_seconds": record["budget_seconds"], "stop_reason": record["stop_reason"],
                   "early_submit": record["stop_reason"] == "Submitted" and record["elapsed_seconds"] < record["budget_seconds"],
                   "usage": usage, "score": load(evidence_dir / "verdict.json")["score"],
                   "final_build_ok": report["build"]["ok"], "impl_broken": report["build"].get("impl_broken"),
                   "filled_code_slots": filled["code"], "filled_proof_slots": filled["proof"],
                   "changed_lean_files": changed, "segment_changed_lean_files": segment_changed,
                   "proof_files_changed": [n for n in changed if "/Proof/" in n],
                   **output_metrics(events, ancestry_events(states, record["terminal"]))}
        if pilot:
            evaluation = manifest["baseline_evaluation"] if label == "baseline" else manifest["branches"][label]["evaluation"]
            summary["grading_seconds"] = evaluation["seconds"]
            leaf = states[evaluation["state"]]
        else:
            leaf = states[manifest["evaluation"]]
            summary["grading_seconds"] = leaf["evaluation"]["elapsed_ms"] / 1000
        summary["grader_execution_seconds"] = leaf["evaluation"]["elapsed_ms"] / 1000
        summaries[label] = summary
    result = {"model": manifest["model"], "mode": manifest["mode"], "vero_commit": manifest["vero_commit"],
              "image": manifest["image"], "instruction_sha256": sha(instruction.encode()),
              "capture": captures, "runs": summaries}
    result["unique_solver_usage_including_question"] = usage_of(all_events)
    result["unique_solver_responses_including_question"] = sum(e["type"] == "response" for e in all_events)
    result["generation_seconds"] = sum(s["seconds"] for s in summaries.values())
    result["grading_seconds"] = sum(s["grading_seconds"] for s in summaries.values())
    if pilot:
        answer = load(root / "simulated-answer.json")
        result["simulation"] = {"kind": "same_model_simulated_human", "human_participant": False,
            "seconds": answer["seconds"], "usage": answer["raw_response"].get("usage"),
            "reported_model": answer["raw_response"].get("model"),
            "provider_cost_fields": cost_fields(answer["raw_response"])}
        result["question_seconds"] = manifest["question"]["seconds"]
        result["question_usage"] = usage_of(states[manifest["question"]["state"]]["appended"])
        result["common_prefix_seconds"] = manifest["question"]["prefix_seconds"]
        result["comparison_budget_seconds"] = manifest["comparison_budget_seconds"]
        result["generation_seconds"] += result["question_seconds"] + result["simulation"]["seconds"]
        for label in ["control", "simulated"]:
            require(summaries[label]["budget_seconds"] == manifest["comparison_budget_seconds"], "unequal paired budgets")
    result["total_tokens_including_simulation"] = result["unique_solver_usage_including_question"]["total"] + (
        (result["simulation"]["usage"] or {}).get("total_tokens", 0) if pilot else 0)
    result["token_total_basis"] = "known committed solver responses and recorded simulation; captured provider usage reported separately"
    result["known_captured_provider_tokens_including_simulation"] = captures["provider_usage"]["total_tokens"] + (
        (result["simulation"]["usage"] or {}).get("total_tokens", 0) if pilot else 0)
    if pilot:
        result["binary_sha256"] = {p.name: sha(p.read_bytes()) for p in (root / "bin").iterdir() if p.is_file()}
    save(root / "truncation-metrics.json", result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["old-smoke", "new-smoke", "old-pilot", "new-pilot"]:
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    runs = {name: inspect(getattr(args, name.replace("-", "_")))
            for name in ["old-smoke", "new-smoke", "old-pilot", "new-pilot"]}
    for key in ["model", "mode", "vero_commit", "image", "instruction_sha256"]:
        require(len({run[key] for run in runs.values()}) == 1, "old/new setting drift: " + key)
    result = {"runs": runs, "limitations": [
        "Fresh old and new samples, one execution per experimental condition; exploratory only.",
        "The old implementation omits middle instruction content; it is a defect control, not a fair model-capability baseline.",
        "The implementation and instruction-delivery changes are bundled; their separate effects are not identified.",
        "Paired no-answer/simulated-answer continuations share one question and equal budgets within each implementation.",
        "Old/new pilots may elicit different questions and have different prefix durations; comparison is not a same-question causal estimate.",
        "Simulated answers are same-model data, not human participants; API latency is not human thinking time.",
        "Early submissions and compile failures are retained; no forced continuation or time-feedback changes.",
        "Costs are unavailable unless the provider explicitly returned numeric cost fields.",
        "The primary token total counts known committed solver responses and recorded simulation; captured provider usage is reported separately, including any returned but discarded responses.",
        "Failed or interrupted provider exchanges may have unknown usage and billing; unknown exchanges are counted explicitly.",
        "Any captured transport timeout is an elapsed-time confound and prevents attributing wall-time differences solely to implementation changes.",
        "Full requests, responses, trajectories and source patches remain private local evidence; only this metric summary is suitable for review before publication."]}
    # Optional outer orchestration timing includes setup, HTML export and grading;
    # it is separate from model/tool execution and is never a solver budget.
    result["phase_wall_seconds"] = {}
    for label, run_path in [("old", args.old_pilot), ("new", args.new_pilot)]:
        directory = run_path.resolve().parent
        candidates = [directory / (label + "-pipeline-retry.json"), directory / (label + "-pipeline.json")]
        manifest = next((p for p in candidates if p.exists()), None)
        if manifest:
            phases = load(manifest)["phases"]
            result["phase_wall_seconds"][label] = [{k: phase[k] for k in ["phase", "exit_code", "seconds"]} for phase in phases]
    result["totals"] = {label: {
        "generation_seconds": sum(runs[label + suffix]["generation_seconds"] for suffix in ["-smoke", "-pilot"]),
        "grading_seconds": sum(runs[label + suffix]["grading_seconds"] for suffix in ["-smoke", "-pilot"]),
        "tokens_including_simulation": sum(runs[label + suffix]["total_tokens_including_simulation"] for suffix in ["-smoke", "-pilot"]),
        "known_captured_provider_tokens_including_simulation": sum(runs[label + suffix]["known_captured_provider_tokens_including_simulation"] for suffix in ["-smoke", "-pilot"]),
        "unknown_usage_exchange_count": sum(runs[label + suffix]["capture"]["unknown_usage_exchange_count"] for suffix in ["-smoke", "-pilot"])
    } for label in ["old", "new"]}
    args.output.mkdir(parents=True, exist_ok=True)
    save(args.output / "comparison.json", result)
    lines = ["# Fresh Vero implementation comparison", "", "| Implementation/run | Vero | Seconds | Tokens | Stop | Long outputs | Rereads |", "|---|---:|---:|---:|---|---:|---:|"]
    for name, run in runs.items():
        for label, segment in run["runs"].items():
            score = segment["score"]
            lines.append(f"| {name}/{label} | {score['passed']}/{score['total']} | {segment['seconds']:.3f} | {segment['usage']['total']} | {segment['stop_reason']} | {segment['long_output_events']} | {segment['reread_calls']} |")
    lines += ["", "All seconds are segment execution time; grading and shared prefix/question/simulation time are reported separately in comparison.json.", "", *["- " + text for text in result["limitations"]]]
    (args.output / "comparison.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps({name: value["runs"] for name, value in runs.items()}, indent=2))


if __name__ == "__main__":
    main()
