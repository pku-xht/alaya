#!/usr/bin/env python3
"""Verify the recorded example and prepare isolated stores for cached replay.

Usage: python3 example/prepare_replay.py tmp/fork-demo/run-001
The destination must be new and under this repository's ignored tmp directory.
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
import tarfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / "example/trajectory.tar.gz"
COMMON = "f2f6b32a81d2"
INTERVENTION = "d7f71105cd18"
TERMINALS = {"unassisted": "591182d5114e", "intervention": "80a182b272b5"}


def prepare(destination: Path) -> dict:
    destination = destination.resolve()
    if not destination.is_relative_to((ROOT / "tmp").resolve()):
        raise ValueError("destination must be under the repository's tmp directory")
    if destination.exists():
        raise ValueError("destination already exists; choose a new run directory")
    files = {}
    with tarfile.open(ARCHIVE) as archive:
        for member in archive.getmembers():
            path = PurePosixPath(member.name)
            if any(part.startswith("._") for part in path.parts):
                continue
            if path.is_absolute() or any(part in ("..", "") for part in path.parts):
                raise ValueError(f"unsafe archive path: {member.name}")
            if member.isdir():
                continue
            if not member.isfile() or path.parts[0] not in ("store", "cache"):
                raise ValueError(f"unexpected archive entry: {member.name}")
            if "\\" in member.name or ":" in member.name or member.name in files:
                raise ValueError(f"ambiguous archive path: {member.name}")
            files[member.name] = archive.extractfile(member).read()

    blobs = {name.rsplit("/", 1)[1]: data for name, data in files.items()
             if name.startswith("store/blobs/")}
    for digest, data in blobs.items():
        if not re.fullmatch(r"[0-9a-f]{64}", digest) or hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f"blob digest mismatch: {digest}")
    states = {}
    for name, data in files.items():
        if name.startswith("store/refs/state."):
            digest = name.split("state.", 1)[1]
            if data.decode().strip() != digest:
                raise ValueError(f"state reference mismatch: {name}")
            states[digest] = json.loads(blobs[digest])

    def resolve(prefix):
        matches = [digest for digest in states if digest.startswith(prefix)]
        if len(matches) != 1:
            raise ValueError(f"ambiguous or missing state: {prefix}")
        return matches[0]

    common, intervention = resolve(COMMON), resolve(INTERVENTION)
    if states[intervention]["parent"] != common:
        raise ValueError("intervention does not branch from the expected common state")
    keep = {intervention}
    current = common
    while current:
        keep.add(current)
        current = states[current]["parent"]

    branches = {}
    for label, prefix in TERMINALS.items():
        terminal = resolve(prefix)
        evaluation = next((digest for digest, state in states.items()
                           if state["parent"] == terminal and state["kind"] == "evaluation"), None)
        if evaluation is None:
            raise ValueError(f"missing evaluation: {label}")
        branches[label] = {"terminal": terminal, "workspace": states[terminal]["workspace"],
                           "evaluation": evaluation, "recorded": states[evaluation]["evaluation"]}
    manifest = {"archive_sha256": hashlib.sha256(ARCHIVE.read_bytes()).hexdigest(),
                "verified_blobs": len(blobs), "archived_states": len(states),
                "replay_initial_states": len(keep), "common": common,
                "intervention": intervention, "image": states[common]["image"], "branches": branches}
    for store in ("archive", "replay"):
        for name, data in files.items():
            if store == "replay" and name.startswith("store/refs/state."):
                if name.split("state.", 1)[1] not in keep:
                    continue
            path = destination / store / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    print(json.dumps(prepare(Path(sys.argv[1])), indent=2))
