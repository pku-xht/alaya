"""Shared helpers for the Vero acceptance scripts: run a command, read an entry, read a log.

Kept apart from any one suite so that each check can be run on its own.
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]
FIXTURE = Path(__file__).parent / "fixtures/tiny_trivial"


def run(*args, codes=(0,), **kwargs):
    result = subprocess.run([str(a) for a in args], text=True, capture_output=True, **kwargs)
    if result.returncode not in codes:
        raise AssertionError(f"{args}\nexit {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


def entry(output):
    """The entry an appending command ends at: the first token of its last stdout line."""
    lines = output.strip().splitlines()
    assert lines, output
    name = lines[-1].split()[0]
    assert re.fullmatch(r"[0-9a-f]{64}", name), output
    return name


def json_lines(output):
    return [json.loads(line) for line in output.splitlines() if line.strip()]


def grader_answer(log):
    """The answer of the last grader's command in `alaya log --json` rows: the workspace as it
    left it, its reports included, is read at its entry."""
    graders = [row["frame"] for row in log if row.get("event", {}).get("type") == "opened"
               and row["event"]["routine"]["name"] == "grader"]
    assert graders, log
    found = [row for row in log if row.get("event", {}).get("type") == "answered"
             and row["frame"] == graders[-1] and row["event"]["op"]["type"] == "exec"]
    assert len(found) == 1, log
    return found[0]


def task_grader(base, benchmark, tag):
    """The image of a task's grader: `base`, the Vero grader image, with the task's trusted
    benchmark at /grader. Its digest, which a call pins, names the very files that grade."""
    run("docker", "build", "--platform", "linux/amd64", "--quiet", "--tag", tag, "--file", "-",
        benchmark, input=f"FROM {base}\nCOPY . /grader\n")
    return tag


def grade(alaya, data, at, image, command, codes=(0,), timeout=None, workdir=None):
    """Grades the point `at` as a person does: stops the call running there, if one is, calls the
    grader with `command` in `image`, and resumes. The status object `resume` ends with."""
    stopped = run(alaya, "stop", at, "--reason", "to grade this point", "--data", data,
                  codes=(0, 65))
    if stopped.returncode == 0:
        at = entry(stopped.stdout)
    options = ["--set", f"command={command}"]
    if timeout is not None:
        options += ["--set", f"timeout_seconds={timeout}"]
    if workdir is not None:
        options += ["--workdir", workdir]
    called = entry(run(alaya, "call", at, "grader", "--image", image, *options,
                       "--data", data).stdout)
    final = json_lines(run(alaya, "resume", called, "--json", "--data", data, codes=codes).stdout)[-1]
    assert final.get("call") == "grader" and final["status"] == "done", final
    return final
