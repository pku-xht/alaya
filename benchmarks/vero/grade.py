#!/usr/bin/env python3
"""Grade a Vero attempt as an alaya grader.

usage: grade.py --mode (proof|codeproof) --benchmark /grader [--lake-timeout S]

`alaya grade` runs it on a point of a run, in the grader image (the Dockerfile's `grader`
target), in a checkout of the attempt, with the trusted benchmark as its input at /grader:

    alaya grade ENTRY --grader-image ghcr.io/msv-lab/alaya-vero-grader:0a7325d --grader-input BENCHMARK \
      --grader 'python /opt/alaya-vero/grade.py --mode codeproof --benchmark /grader'

The mode and the benchmark are arguments; nothing is read from the checkout to choose them. It
extracts only the answer slots the mode permits, rebuilds from the trusted benchmark in /tmp,
writes Vero's reports to `.grade/` in the checkout, and prints TAP on stdout: one check per
specification, plus a failing `acceptance: joint:...` check for an invalid joint claim. Anything
unexpected — an unknown Vero status, a compiler timeout, an exception — is `Bail out!`.
"""
from __future__ import annotations

import argparse
import contextlib
from functools import cache
import json
from pathlib import Path
import shutil
import sys
import tempfile
import traceback

from prepare import prepare


# The grading vocabulary is read from the pinned Vero instead of being hand-written here:
# ``SpecStatus`` is a ``Literal`` in ``vero.evaluation.grade``, and the status Vero counts as a
# pass is the one its own ``grade_specs`` counts. A status outside that vocabulary is an error,
# never a silent zero: otherwise a rename inside Vero would look exactly like "every submission
# failed", which no experiment can tell apart from a model that could not solve the task.
@cache
def spec_vocabulary() -> tuple[frozenset[str], str]:
    from typing import get_args

    from vero.evaluation.grade import SpecStatus

    statuses = frozenset(get_args(SpecStatus))
    passing = "passed"
    if passing not in statuses or len(statuses) < 2:
        raise RuntimeError(f"the pinned Vero reports unexpected spec statuses: {sorted(statuses)}")
    return statuses, passing


@cache
def joint_vocabulary() -> frozenset[str]:
    """The joint statuses the pinned Vero can produce, read from its own source."""
    import re

    import vero.evaluation.joint_rerender as module

    source = Path(module.__file__).read_text(encoding="utf-8")
    found = frozenset(re.findall(r'status="([a-z_]+)"', source))
    if not found:
        raise RuntimeError("cannot read the joint status vocabulary from the pinned Vero")
    return found


# A joint status is not a rejection when there is no claim at all, or when Vero verified one.
JOINT_NOT_A_REJECTION = frozenset({"no_claim", "ok"})


def spec_ok(status: str, spec_name: str) -> bool:
    statuses, passing = spec_vocabulary()
    if status not in statuses:
        raise RuntimeError(f"{spec_name}: unknown Vero spec status {status!r}; "
                           f"the pinned Vero reports {sorted(statuses)}")
    return status == passing


def joint_rejection(status: str) -> str | None:
    if status in JOINT_NOT_A_REJECTION:
        return None
    if status not in joint_vocabulary():
        raise RuntimeError(f"unknown Vero joint status {status!r}; "
                           f"the pinned Vero reports {sorted(joint_vocabulary())}")
    return status


def clean_name(text: str) -> str:
    return " ".join(text.split()).replace("\\", "\\\\").replace("#", "\\#")


def trusted_copy(source: Path, destination: Path) -> None:
    shutil.copytree(source, destination,
                    ignore=shutil.ignore_patterns(".lake", ".git", "__pycache__"))
    prepare(destination)


def answer_files(bench, mode: str) -> set[str]:
    from vero.generation.extractor import expected_slots
    if mode == "proof":
        return {module.proof_rel() for module in bench.iter_modules() if module.specs}
    return {slot.file for slot in expected_slots(bench, mode)}


def check_agent_paths(workspace: Path, bench, mode: str) -> None:
    for filename in answer_files(bench, mode):
        relative = Path(filename)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"unsafe benchmark path: {relative}")
        current = workspace
        for part in relative.parts:
            current = current / part
            if current.is_symlink():
                raise ValueError(f"agent slot path is a symlink: {relative}")


def extract_submission(workspace: Path, bench, mode: str, temporary: Path):
    from vero.generation.extractor import extract
    if mode != "proof":
        return extract(workspace, bench, mode=mode)
    # Upstream schedules Impl slots even in proof mode. Never read those files:
    # extract only the manifest-selected proof files, then discard missing Impl slots.
    allowed = answer_files(bench, mode)
    answers = temporary / "answers"
    answers.mkdir()
    for filename in allowed:
        source = workspace / filename
        if source.is_file():
            target = answers / filename
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
    artifact = extract(answers, bench, mode=mode)
    artifact.slots = [slot for slot in artifact.slots if slot.file in allowed]
    artifact.extras = [slot for slot in artifact.extras if slot.file in allowed]
    artifact.file_errors = {f: e for f, e in artifact.file_errors.items() if f in allowed}
    return artifact


def emit_results(results: list[tuple[bool, str]]) -> int:
    for number, (ok, name) in enumerate(results, 1):
        print(f"{'ok' if ok else 'not ok'} {number} - {clean_name(name)}", flush=True)
    # A trailing plan includes additional acceptance checks without changing spec results.
    print(f"1..{len(results)}", flush=True)
    return 0 if all(ok for ok, _ in results) else 1


def grade(benchmark: Path, mode: str, lake_timeout: int) -> int:
    from vero.generation.benchmark import Benchmark
    from vero.generation.extractor import write_artifact
    from vero.evaluation.runner import run_evaluation

    workspace = Path.cwd()
    bench = Benchmark(benchmark)
    if mode not in bench.modes_supported:
        raise ValueError(f"benchmark does not support {mode}")
    total = sum(len(module.specs) for module in bench.iter_modules())
    if total == 0:
        raise ValueError("benchmark has no specifications")
    print("TAP version 14", flush=True)
    report_dir = workspace / ".grade"
    if report_dir.is_symlink() or report_dir.is_file():
        report_dir.unlink()
    elif report_dir.exists():
        shutil.rmtree(report_dir)
    report_dir.mkdir()
    # Symlinked answer files must not resolve against the trusted mount during grading.
    try:
        check_agent_paths(workspace, bench, mode)
    except ValueError as exc:
        reason = str(exc)
        (report_dir / "report.json").write_text(
            json.dumps({"rejected": reason, "mode": mode, "total_specs": total}) + "\n")
        (report_dir / "report.md").write_text(f"# Rejected\n\n{reason}\n")
        return emit_results([(False, f"anti-cheat: {reason}") for _ in range(total)])

    with tempfile.TemporaryDirectory(prefix="alaya-vero-") as temporary:
        staging = Path(temporary) / "benchmark"
        with contextlib.redirect_stdout(sys.stderr):
            trusted_copy(benchmark, staging)
            trusted = Benchmark(staging)
            artifact = extract_submission(workspace, trusted, mode, Path(temporary))
            write_artifact(artifact, report_dir / "artifact.json")
            result = run_evaluation(
                benchmark_dir=staging, artifact=artifact, mode=mode,
                eval_sandbox_dir=Path(temporary) / "build", report_dir=report_dir,
                lake_timeout=lake_timeout)
        report = result.report
        if len(report.specs) != total or report.summary.total_specs != total:
            raise RuntimeError("Vero returned a different specification count")
        results = []
        for spec in report.specs:
            name = f"{spec.module}.{spec.spec}"
            ok = spec_ok(spec.status, name)
            if not ok:
                name += f" - {spec.status}"
            results.append((ok, name))
        if report.joint is not None:
            rejection = joint_rejection(report.joint.status)
            if rejection is not None:
                results.append((False, f"acceptance: joint:{rejection}"))
    # Reports and temporary cleanup are complete before publishing results and the plan.
    return emit_results(results)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--benchmark", type=Path, required=True)
    parser.add_argument("--mode", choices=("proof", "codeproof"), required=True)
    parser.add_argument("--lake-timeout", type=int, default=600)
    args = parser.parse_args()
    try:
        return grade(args.benchmark.resolve(), args.mode, args.lake_timeout)
    except Exception as exc:
        traceback.print_exc(file=sys.stderr)
        print(f"Bail out! {clean_name(str(exc))}", flush=True)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
