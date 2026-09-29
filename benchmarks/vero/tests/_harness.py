"""Shared helpers for the Vero acceptance scripts: run a command, read a state hash.

Kept apart from any one suite so that each check can be run on its own.
"""
from __future__ import annotations

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


def state_hash(output):
    found = re.search(r"\b[0-9a-f]{64}\b", output)
    assert found, output
    return found.group()
