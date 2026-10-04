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
    """The entry of a grader program's answer in `alaya log --json` rows; its checkout is there."""
    found = [row for row in log if row.get("event", {}).get("type") == "answered"
             and row["event"]["op"]["type"] == "external"]
    assert len(found) == 1, log
    return found[0]
