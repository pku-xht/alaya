#!/usr/bin/env python3
"""Check a pinned Mathlib-dependent Vero benchmark with non-root, offline image dependencies."""
import argparse
import json
import os
from pathlib import Path
from _harness import ROOT, run, state_hash

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--benchmark", type=Path, required=True)
p.add_argument("--agent-image", required=True)
p.add_argument("--grader-image", required=True)
p.add_argument("--output", type=Path, required=True)
args = p.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)
benchmark = args.benchmark.resolve()
uid = f"{os.getuid()}:{os.getgid()}"
run("docker", "run", "--rm", "--network", "none", "--user", uid, "-e", "HOME=/tmp",
    "-v", f"{benchmark}:/benchmark:ro", "-v", f"{output}:/rendered", args.grader_image,
    "python", "/opt/alaya-vero/render.py", "--benchmark", "/benchmark",
    "--sandbox", "/rendered/source", "--mode", "proof")
source = output / "source"
lock = (source / "lake-manifest.json").read_bytes()
assert not (source / ".lake/packages").exists()
base = ["docker", "run", "--rm", "--network", "none", "--user", uid, "-e", "HOME=/tmp",
        "-v", f"{source}:/workspace", "-w", "/workspace", args.agent_image]
# A host cache must be rejected without deleting the user's directory.
first_package = json.loads(lock)["packages"][0]["name"]
real_package = source / ".lake/packages" / first_package
real_package.mkdir(parents=True)
marker = real_package / "keep"
marker.write_text("preserve this directory")
rejected = run(*base, "python3", "/opt/alaya-vero/prepare.py", "/workspace", codes=(1,))
assert "real directory/file" in rejected.stderr
assert marker.read_text() == "preserve this directory"
marker.unlink()
real_package.rmdir()
# A changed lock must not silently select the image's revision.
changed = json.loads(lock)
changed["packages"][0]["rev"] = "0" * 40
(source / "lake-manifest.json").write_text(json.dumps(changed))
rejected = run(*base, "python3", "/opt/alaya-vero/prepare.py", "/workspace", codes=(1,))
assert "does not match" in rejected.stderr
(source / "lake-manifest.json").write_bytes(lock)
run(*base, "python3", "/opt/alaya-vero/prepare.py", "/workspace")
packages = list((source / ".lake/packages").iterdir())
assert packages and all(p.is_symlink() and str(p.readlink()).startswith("/opt/vero-packages/")
                        for p in packages)
alaya = ROOT / ".lake/build/bin/alaya"
data = output / "audit"
root = state_hash(run(alaya, "root", source, "--task-file", output / "MINIVERO_TASK.md",
                      "--agent", ROOT / "agents/mini-vero-default.json", "--image",
                      args.agent_image, "--data", data).stdout)
state = json.loads((data / "states" / f"{root}.json").read_text())
stats = json.loads(run("restic", "--repo", data / "restic", "--insecure-no-password",
                       "stats", state["workspace"], "--mode", "restore-size", "--json").stdout)
# A source-only snapshot is small; compiled packages would be gigabytes.
assert stats["total_size"] < 10_000_000, stats
cached = run(*base, "lake", "build", "@mathlib/Mathlib", "@proofwidgets/widgetPackageLock")
(output / "dependency-build.log").write_text(cached.stdout + cached.stderr)
build = run(*base, "lake", "build")
(output / "build.log").write_text(build.stdout + build.stderr)
assert (source / "lake-manifest.json").read_bytes() == lock

# Grading must also work offline on a Mathlib benchmark: an untouched
# submission is a fail with 0 of N specification checks, never an error.
spec_total = sum(
    len(module.get("specs", []))
    for package in json.loads((benchmark / "manifest.json").read_text())["packages"]
    for module in package.get("modules", [])
)
grading = run(alaya, "eval", root, "--timeout", "5400",
              "--grader-image", args.grader_image, "--input", benchmark,
              "--grader", "python /opt/alaya-vero/grade.py --mode proof --benchmark /grader",
              "--data", data, codes=(1,))
evaluation = state_hash(grading.stdout)
record = json.loads((data / "states" / f"{evaluation}.json").read_text())["evaluation"]
assert record["status"] == "fail", record
assert len(record["checks"]) == spec_total, (len(record["checks"]), spec_total)
assert not any(check["ok"] for check in record["checks"]), record
report = json.loads(run(alaya, "cat", evaluation, ".vero/report.json", "--data", data).stdout)
assert report["summary"]["total_specs"] == spec_total, report["summary"]
result = {"root": root, "image": state["image"], "snapshot_stats": stats,
          "package_symlinks": {p.name: str(p.readlink()) for p in packages},
          "uid_gid": uid, "network": "none", "build_exit": build.returncode,
          "grading": {"state": evaluation, "status": record["status"],
                      "checks": len(record["checks"]),
                      "passed_specs": report["summary"]["passed_specs"]},
          "rejects_host_packages": True, "rejects_changed_lock": True,
          "dependency_build_exit": cached.returncode}
(output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
