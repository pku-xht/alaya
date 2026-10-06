#!/usr/bin/env python3
"""Check a pinned Mathlib-dependent Vero benchmark with non-root, offline image dependencies."""
import argparse
import json
import os
from pathlib import Path
from _harness import ROOT, entry, grade, grader_answer, json_lines, run, task_grader

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
# The run is created on the source alone; the agent is called on it with its configuration.
root = json_lines(run(alaya, "new", source, "--data", data, "--json").stdout)[0]
called = json_lines(run(alaya, "call", root["entry"], "mini-vero", "--set-file", f"task={output / 'MINIVERO_TASK.md'}",
                        "--set", "mode=proof", "--set", "model=gpt-oss-120b",
                        "--image", args.agent_image, "--data", data, "--json").stdout)[0]
environment = called["event"]["notice"]["call"]["environment"]
workspace = root["event"]["notice"]["workspace"]
stats = json.loads(run("restic", "--repo", data / "restic", "--insecure-no-password",
                       "stats", workspace, "--mode", "restore-size", "--json").stdout)
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
# Grade the untouched source at the root, with the benchmark's grader image: `resume` exits 1 for
# the fail this is.
grader_image = task_grader(args.grader_image, benchmark, "alaya-vero-grader-mathlib")
final = grade(alaya, data, root["entry"], grader_image,
              "python /opt/alaya-vero/grade.py --mode proof --benchmark /grader", codes=(1,), timeout=5400)
record = final["value"]
answer = grader_answer(json_lines(run(alaya, "log", final["entry"], "--json",
                                      "--data", data).stdout))["entry"]
assert record["status"] == "fail", record
assert len(record["checks"]) == spec_total, (len(record["checks"]), spec_total)
assert not any(check["ok"] for check in record["checks"]), record
report = json.loads(run(alaya, "cat", answer, ".grade/report.json", "--data", data).stdout)
assert report["summary"]["total_specs"] == spec_total, report["summary"]
result = {"root": root["entry"], "call": called["entry"], "image": environment["image"],
          "snapshot_stats": stats,
          "package_symlinks": {p.name: str(p.readlink()) for p in packages},
          "uid_gid": uid, "network": "none", "build_exit": build.returncode,
          "grading": {"entry": final["entry"], "answer": answer, "status": record["status"],
                      "checks": len(record["checks"]),
                      "passed_specs": report["summary"]["passed_specs"]},
          "rejects_host_packages": True, "rejects_changed_lock": True,
          "dependency_build_exit": cached.returncode}
(output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
