#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Grade a Bija attempt against the reference acceptance suite, as an alaya grader.

usage: grade.py --tests /grader

`alaya grade` runs it on a point of a run, in the grader image (the Dockerfile's `grader`
target), in a checkout of the attempt, with the reference's `tests/` as its trusted input at
/grader. From the repository root, TAG the image's tag in README.md:

    alaya grade ENTRY --grader-image ghcr.io/msv-lab/alaya-bija-grader:TAG \
      --grader-input benchmarks/bija/reference/tests \
      --grader 'python3 /opt/alaya-bija/grade.py --tests /grader' --grader-timeout 1800

It replaces the checkout's `tests/` with the reference's 232 programs, runs the suite with the
attempt's own project, and prints TAP on stdout: one check per program run through the command
line (`program AREA/NAME`), then one per program compiled with `bija build` and run under a bare
interpreter (`standalone AREA/NAME`). A suite that did not run bails out. The pass counts by
area go to stderr, and the suite's output and JUnit report stay in the checkout under `.grade/`,
where `alaya cat ENTRY .grade/pytest.txt` reads them, ENTRY the entry of the grader's answer.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

KINDS = {"test_program": "program", "test_generated_python_is_standalone": "standalone"}


def run_suite(checkout: Path, reference: Path, reports: Path) -> int:
    """Runs pytest over the checkout; its output and JUnit report go to REPORTS."""
    tests = checkout / "tests"
    if tests.exists():
        shutil.rmtree(tests)
    shutil.copytree(reference, tests, ignore=shutil.ignore_patterns("__pycache__"))
    # A fresh environment outside the checkout, so the attempt's own .venv is neither trusted nor
    # modified.
    env = {**os.environ, "UV_PROJECT_ENVIRONMENT": "/tmp/grader-venv"}
    command = ["uv", "run", "pytest", "-q", "--tb=no", "-p", "no:cacheprovider",
               f"--junitxml={reports / 'junit.xml'}"]
    with (reports / "pytest.txt").open("w", encoding="utf-8") as log:
        result = subprocess.run(command, cwd=checkout, env=env, stdout=log, stderr=subprocess.STDOUT)
    return result.returncode


def checks(junit: Path) -> list[tuple[bool, str]]:
    """One (passed, name) per program and kind: every command-line check, then every standalone
    one, each in the order of the programs' names."""
    found: dict[str, list[tuple[str, bool]]] = {kind: [] for kind in KINDS.values()}
    for case in ET.parse(junit).getroot().iter("testcase"):
        test, _, program = case.get("name", "").partition("[")
        if test in KINDS and program.endswith("]"):
            passed = case.find("failure") is None and case.find("error") is None
            found[KINDS[test]].append((program[:-1], passed))
    return [(passed, f"{kind} {program}")
            for kind in KINDS.values() for program, passed in sorted(found[kind])]


def escape(name: str) -> str:
    return name.replace("\\", "\\\\").replace("#", "\\#")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tests", type=Path, required=True, help="the reference's tests/")
    args = parser.parse_args()
    checkout = Path.cwd()
    reports = checkout / ".grade"
    reports.mkdir(exist_ok=True)
    status = run_suite(checkout, args.tests.resolve(), reports)
    junit = reports / "junit.xml"
    if not junit.exists():
        sys.stderr.write((reports / "pytest.txt").read_text(encoding="utf-8", errors="replace"))
        print(f"Bail out! the suite did not run (pytest exit {status})")
        return 1
    results = checks(junit)
    print(f"1..{len(results)}")
    for number, (passed, name) in enumerate(results, 1):
        print(f"{'ok' if passed else 'not ok'} {number} - {escape(name)}")
    areas: dict[str, list[bool]] = {}
    for passed, name in results:
        if name.startswith("program "):
            areas.setdefault(name.split()[1].split("/")[0], []).append(passed)
    sys.stderr.write(", ".join(f"{area} {sum(r)}/{len(r)}" for area, r in sorted(areas.items())) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
