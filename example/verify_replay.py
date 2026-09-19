#!/usr/bin/env python3
"""Verify fresh replay lineage, source files, and all grading evidence; write result.json."""
from __future__ import annotations

import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path


class Store:
    def __init__(self, path):
        self.path = Path(path) / "store"

    def blob(self, digest):
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("invalid digest")
        data = (self.path / "blobs" / digest[:2] / digest).read_bytes()
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f"corrupt blob: {digest}")
        return data

    def json(self, digest):
        return json.loads(self.blob(digest))

    def states(self):
        return {path.name[6:]: self.json(path.name[6:])
                for path in (self.path / "refs").glob("state.*")}

    def files(self, tree, prefix=""):
        result = {}
        for entry in self.json(tree):
            name = prefix + entry["name"]
            if entry["type"] == "dir":
                result.update(self.files(entry["hash"], name + "/"))
            else:
                result[name] = entry["hash"]
        return result


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(run):
    run = Path(run).resolve()
    manifest = json.loads((run / "manifest.json").read_text(encoding="utf-8"))
    original, fresh = Store(run / "archive"), Store(run / "replay")
    states = fresh.states()
    common, intervention = manifest["common"], manifest["intervention"]
    require(states[intervention]["parent"] == common, "wrong intervention parent")
    results = {}
    for label in ("unassisted", "intervention"):
        log = (run / f"replay-{label}.log").read_text(encoding="utf-8")
        final_matches = re.findall(r"^FINAL ([0-9a-f]{64})$", log, re.MULTILINE)
        require(len(final_matches) == 1, f"missing or ambiguous FINAL for {label}")
        final = final_matches[0]
        terminal = states[final]
        require(terminal["outcome"]["status"] == "Submitted", "replay did not submit")
        path, current = [], final
        start = common if label == "unassisted" else intervention
        while current != start:
            require(current is not None and current not in path, "broken continuation lineage")
            path.append(current)
            current = states[current]["parent"]
        source = lambda files: {p: h for p, h in files.items() if p.startswith("src/") and p.endswith(".py")}
        expected = manifest["branches"][label]
        expected_files = source(original.files(expected["workspace"]))
        actual_files = source(fresh.files(terminal["workspace"]))
        require(bool(actual_files) and actual_files == expected_files, "replayed source differs")
        evaluations = [(h, s) for h, s in states.items()
                       if s["parent"] == final and s["kind"] == "evaluation"]
        require(len(evaluations) == 1, "expected exactly one fresh evaluation")
        evaluation_hash, evaluation = evaluations[0]
        require(not any(s["parent"] == evaluation_hash for s in states.values()), "evaluation is not a leaf")
        evidence = fresh.files(evaluation["evaluation"]["evidence"])
        verdict = json.loads(fresh.blob(evidence["verdict.json"]))
        require(verdict == evaluation["evaluation"]["summary"], "verdict and state disagree")
        require(verdict == expected["recorded"]["summary"], "fresh grading differs from archive")
        cases = list(ET.fromstring(fresh.blob(evidence["junit.xml"])).iter("testcase"))
        require(not any(case.find("skipped") is not None for case in cases), "tests were skipped")
        for key, case_prefix in (("score", "test_program["), ("standalone", "test_generated_python_is_standalone[")):
            group = [c for c in cases if c.get("name", "").startswith(case_prefix)]
            passed = sum(c.find("failure") is None and c.find("error") is None for c in group)
            require({"passed": passed, "total": len(group)} == verdict[key], "JUnit counts disagree")
            require(len(group) == 232, "acceptance suite is incomplete")
        results[label] = {"start": start, "terminal": final, "continuation": list(reversed(path)),
                          "evaluation": evaluation_hash, "workspace": terminal["workspace"],
                          "full_workspace_matches_archive": terminal["workspace"] == expected["workspace"],
                          "source_files": actual_files, "source_matches_archive": True,
                          "fresh_verdict": verdict, "grading_ms": evaluation["evaluation"]["elapsed_ms"],
                          "evidence_files": evidence}
    result = {"verified_at_utc": datetime.now(timezone.utc).isoformat(),
              "mode": "fixed recorded actions, fresh tool execution and grading; no new model sampling",
              "archive_sha256": manifest["archive_sha256"], "common": common,
              "image": states[common]["image"], "checks_passed": True, "branches": results}
    (run / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: verify_replay.py RUN_DIRECTORY")
    print(json.dumps(verify(sys.argv[1]), indent=2))
