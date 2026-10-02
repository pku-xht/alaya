#!/usr/bin/env python3
"""Deterministic Docker acceptance test; uses a local scripted model, no API credentials.

Run from the Alaya repository after building both images. Artifacts are retained in
--output (which must not exist) to allow inspecting every recorded evaluation.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import sys
import threading
import uuid

from _harness import FIXTURE, ROOT, run, state_hash

EDIT = """from pathlib import Path
import re
def fill(path, start, end, body):
    p = Path(path)
    pattern = re.escape(start) + r'\\n.*?(?=\\n' + re.escape(end) + r')'
    text, count = re.subn(pattern, lambda _: start + '\\n' + body,
                          p.read_text(), count=1, flags=re.S)
    assert count == 1
    p.write_text(text)
fill('TinyTrivial/Proof/Core.lean',
     '-- !benchmark @start proof def=prove_idNat kind=prove target=spec_idNat',
     '-- !benchmark @end proof def=prove_idNat', '  intro n\\n  rfl')
"""
IMPL_EDIT = """fill('TinyTrivial/Impl/Core.lean',
     '-- !benchmark @start code def=idNat',
     '-- !benchmark @end code def=idNat', '  fun n => n')
"""


class ScriptedModel(BaseHTTPRequestHandler):
    mode = "proof"
    requests = []

    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append(request)
        count = sum(m["role"] == "assistant" for m in request["messages"])
        if count == 0:
            name, arguments = "bash", {"command": "sleep 2; cat TinyTrivial/Spec/Core.lean"}
        elif count == 1:
            edit = EDIT + (IMPL_EDIT if self.mode == "codeproof" else "")
            name, arguments = "bash", {"command": "python3 - <<'PY'\n" + edit + "\nPY"}
        else:
            name, arguments = "submit", {"message": "Deterministic fixture"}
        payload = {
            "id": str(uuid.uuid4()), "object": "chat.completion", "model": "scripted",
            "choices": [{"index": 0, "finish_reason": "tool_calls", "message": {
                "role": "assistant", "content": "Deterministic integration check.",
                "tool_calls": [{"id": f"call-{count}", "type": "function", "function": {
                    "name": name, "arguments": json.dumps(arguments)}}]}}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20}}
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def test_mode(args, mode):
    directory = args.output / mode
    directory.mkdir()
    source = directory / "source"
    data = directory / "audit"
    uid = f"{os.getuid()}:{os.getgid()}"

    def docker(image, *command, mounts=(), workdir="/workspace"):
        volumes = [v for host, target in mounts for v in ("--volume", f"{host}:{target}")]
        return run("docker", "run", "--rm", "--network", "none", "--user", uid,
                   "--env", "HOME=/tmp", "--workdir", workdir, *volumes, image, *command)

    docker(args.grader_image, "python", "/opt/alaya-vero/render.py",
           "--benchmark", "/benchmark", "--sandbox", "/rendered/source", "--mode", mode,
           mounts=((FIXTURE, "/benchmark:ro"), (directory, "/rendered")))
    assert (directory / "MINIVERO_TASK.md").exists()
    assert not (source / "MINIVERO_TASK.md").exists()
    assert not (source / "INSTRUCTION.md").exists()
    assert not (source / ".lake/packages").exists()
    docker(args.agent_image, "python3", "/opt/alaya-vero/prepare.py", "/workspace",
           mounts=((source, "/workspace"),))
    docker(args.agent_image, "sh", "-c", "test ! -e /opt/vero && test ! -e /grader")

    def alaya(*command, **kwargs):
        return run(args.alaya, *command, "--data", data, **kwargs)

    def read_state(hash_):
        return json.loads((data / "states" / f"{hash_}.json").read_text())

    def read_evaluation(hash_):
        return read_state(hash_)["kind"]["evaluation"]

    root = state_hash(alaya("root", source, "--task-file", directory / "MINIVERO_TASK.md",
                             "--agent", "mini-vero", "--set", f"agent.mode={mode}",
                             "--model", "gpt-oss-120b",
                             "--image", args.agent_image,
                             "--workdir", "/testbed").stdout)
    # What the run was created with is recorded on its root alone.
    run_record = read_state(root)["kind"]["root"]
    assert run_record["workdir"] == "/testbed"

    def evaluate(state, expected, passed):
        result = alaya("eval", state, "--input", FIXTURE, "--grader-image", args.grader_image,
                       "--grader", f"python /opt/alaya-vero/grade.py --mode {mode} --benchmark /grader",
                       codes=({"pass": 0, "fail": 1, "error": 2}[expected],))
        evaluated = state_hash(result.stdout)
        record = read_evaluation(evaluated)
        assert record["status"] == expected, record
        assert len(record["checks"]) == 1, record
        assert sum(c["ok"] for c in record["checks"]) == passed, record
        assert "sha256:" in record["grader_image"]
        assert record["input"]
        assert ".vero/report.md" in alaya("ls", evaluated, ".vero").stdout
        report = alaya("cat", evaluated, ".vero/report.md").stdout
        assert report.strip()
        return {"state": evaluated, "record": record}

    blank = evaluate(root, "fail", 0)
    # No task file is in the source snapshot. Scoring still completes.
    ScriptedModel.mode, ScriptedModel.requests = mode, []
    server = ThreadingHTTPServer(("127.0.0.1", 0), ScriptedModel)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        model = ["--provider", "dgx", "--url", f"http://127.0.0.1:{server.server_port}/v1",
                 "--json"]
        partial = alaya("resume", root, *model, "--time-budget", "1", codes=(4,))
        rows = [json.loads(line) for line in partial.stdout.splitlines() if line.strip()]
        assert rows[-1]["time_budget_spent"], rows
        continuing = rows[-1]["state"]
        complete = alaya("resume", continuing, *model, "--time-budget", "300")
        rows = [json.loads(line) for line in complete.stdout.splitlines() if line.strip()]
        assert rows[-1]["outcome"] == "Submitted", rows
        final = rows[-1]["state"]
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    assert len(ScriptedModel.requests) == 3
    assert "root" not in read_state(final)["kind"]
    correct = evaluate(final, "pass", 1)
    # Every eval runs the grader and records a new evaluation.
    assert evaluate(final, "pass", 1)["state"] != correct["state"]

    branch = directory / "tampered"
    alaya("checkout", final, branch)
    (branch / "MINIVERO_TASK.md").write_text("# forged benchmark (proof)\n")
    if mode == "codeproof":
        # Attempt a mode downgrade with a valid proof and no implementation slot.
        (branch / "TinyTrivial/Impl/Core.lean").write_text("")
    else:
        proof = branch / "TinyTrivial/Proof/Core.lean"
        proof.write_text(proof.read_text().replace("  intro n\n  rfl", "  sorry"))
    bad = state_hash(alaya("commit", final, branch, "--message", "negative grading control").stdout)
    rejected = evaluate(bad, "fail", 0)

    if mode == "codeproof":
        linked = directory / "symlinked"
        alaya("checkout", final, linked)
        impl = linked / "TinyTrivial/Impl/Core.lean"
        impl.unlink()
        impl.symlink_to("/grader/TinyTrivial/Impl/Core.lean")
        linked_state = state_hash(alaya("commit", final, linked,
                                       "--message", "trusted-reference symlink attack").stdout)
        symlink_rejection = evaluate(linked_state, "fail", 0)
        assert "anti-cheat" in symlink_rejection["record"]["checks"][0]["name"]

    # Trusted mount is read-only; grader shares the agent's user and working directory. On
    # Linux that user is the host's, never root; Docker Desktop keeps the image's own.
    non_root = "test \"$(id -u)\" != 0 && " if sys.platform == "linux" else ""
    contract = alaya("eval", root, "--input", FIXTURE, "--grader",
                     "test \"$PWD\" = /testbed && " + non_root +
                     "! touch /grader/should-not-exist 2>/dev/null && "
                     "printf '1..1\\nok 1 - execution contract\\n'")
    assert read_evaluation(state_hash(contract.stdout))["status"] == "pass"

    cache_command = "printf '1..1\\nok 1 - image identity\\n'"
    first_image = state_hash(alaya("eval", root, "--grader", cache_command).stdout)
    second_image = state_hash(alaya("eval", root, "--grader-image", args.grader_image,
                                    "--grader", cache_command).stdout)
    assert first_image != second_image
    assert read_evaluation(first_image)["grader_image"] == run_record["image"]
    assert read_evaluation(second_image)["grader_image"] == correct["record"]["grader_image"]

    timeout = alaya("eval", root, "--timeout", "1", "--grader",
                    "echo 1..1; sleep 20; echo stale > stale.txt; echo 'ok 1 - late'", codes=(2,))
    assert read_evaluation(state_hash(timeout.stdout))["status"] == "error"
    for container in run("docker", "ps", "-aq").stdout.split():
        mounts = run("docker", "inspect", "--format", "{{json .Mounts}}", container,
                     codes=(0, 1))
        if mounts.returncode == 0:
            assert not any(m["Source"].startswith(str(data / "tmp") + "/")
                           for m in json.loads(mounts.stdout)), "grader container survived timeout"
    retried = alaya("eval", root, "--grader",
                   "test ! -e stale.txt && printf '1..1\\nok 1 - clean retry\\n'")
    assert read_evaluation(state_hash(retried.stdout))["status"] == "pass"
    # Every command's scratch, a grader's checkout included, is gone when the command ends.
    assert not list((data / "tmp").iterdir())
    alaya("html", directory / "report.html")
    result = {"mode": mode, "root": root, "agent_image": run_record["image"],
              "blank": blank, "correct": correct, "tampered": rejected,
              "budget_exit": partial.returncode, "model_requests": len(ScriptedModel.requests),
              "timeout": state_hash(timeout.stdout), "retry": state_hash(retried.stdout)}
    (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"{mode}: blank 0/1, correct 1/1, tampered 0/1; budget/resume and cleanup passed",
          flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent-image", required=True)
    parser.add_argument("--grader-image", required=True)
    parser.add_argument("--alaya", type=Path, default=ROOT / ".lake/build/bin/alaya")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    binary = args.output / "alaya"
    shutil.copy2(args.alaya, binary)
    args.alaya = binary
    result = [test_mode(args, mode) for mode in ("proof", "codeproof")]
    (args.output / "results.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
