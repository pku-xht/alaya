#!/usr/bin/env python3
"""Deterministic Docker acceptance test; uses a local scripted model, no API credentials.

Run from the Alaya repository after building both images. Artifacts are retained in
--output (which must not exist) to allow inspecting every recorded run and grading.
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

from _harness import FIXTURE, ROOT, entry, grader_answer, json_lines, run

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

    def log(at):
        """The log that ends at an entry, one row per entry, without its closing `next` row."""
        rows = json_lines(alaya("log", at, "--json").stdout)
        assert "next" in rows[-1], rows[-1]
        return rows[:-1]

    def create():
        """A run on the rendered source; its three entries: root, the agent's opening, the task."""
        rows = json_lines(alaya("new", source, "--task-file", directory / "MINIVERO_TASK.md",
                                "--agent", "mini-vero", "--set", f"agent.mode={mode}",
                                "--model", "gpt-oss-120b", "--image", args.agent_image,
                                "--workdir", "/testbed", "--json").stdout)
        assert [r["position"] for r in rows] == [0, 1, 2], rows
        assert rows[1]["event"]["type"] == "opened", rows
        return rows

    def configuration(rows):
        return rows[1]["event"]["routine"]["arguments"]

    vero = ["--grader", f"python /opt/alaya-vero/grade.py --mode {mode} --benchmark /grader",
            "--grader-input", FIXTURE, "--grader-image", args.grader_image]

    def drive(at, *options, code=0):
        """`alaya run` from an entry; the appended entries and the final status object."""
        rows = json_lines(alaya("run", at, *options, "--json", codes=(code,)).stdout)
        assert rows and "status" in rows[-1], rows
        return rows[:-1], rows[-1]

    def graded(final, expected, passed, total=1):
        """Check a graded point: its verdict, the notice that assigned the grader, the grader's
        operation, and its report."""
        assert final["status"] in ("done", "stopped"), final
        record = final["verdict"]
        assert record["status"] == expected, record
        assert len(record["checks"]) == total, record
        assert sum(c["ok"] for c in record["checks"]) == passed, record
        trace = log(final["entry"])
        [assigned] = [r["event"]["notice"] for r in trace if r["event"]["type"] == "arrived"
                      and r["event"]["notice"]["type"] == "assigned"]
        answer = grader_answer(trace)
        operation = answer["event"]["op"]
        return {"entry": final["entry"], "answer": answer["entry"], "record": record,
                "grader": assigned["grader"],
                "image": operation["image"], "input": operation["input"],
                "checkout": answer["event"]["answer"]["checkout"]}

    def grade_at(at, expected, passed, total=1, grader=None):
        """Grade a point of a run, with Vero's grader unless another is given: `grade` stops a
        fork there if the agent still runs, assigns the grader, runs it, and exits with the
        verdict."""
        code = {"pass": 0, "fail": 1, "error": 2}[expected]
        rows = json_lines(alaya("grade", at, *(grader or vero), "--json", codes=(code,)).stdout)
        return graded(rows[-1], expected, passed, total)

    def vero_graded(at, expected, passed):
        result = grade_at(at, expected, passed)
        assert "sha256:" in result["image"]
        assert result["input"]
        # The report is in the checkout as the grader left it, read at its answer's entry.
        assert ".grade/report.md" in alaya("ls", result["answer"], ".grade").stdout
        assert alaya("cat", result["answer"], ".grade/report.md").stdout.strip()
        return result

    rows = create()
    task = rows[-1]["entry"]
    run_record = configuration(rows)
    assert run_record["environment"]["workdir"] == "/testbed"
    assert "sha256:" in run_record["environment"]["image"], run_record
    # A grader is no part of a run: `new` takes none, and the configuration names none.
    assert "graders" not in run_record, run_record
    refused = alaya("new", source, "--task", "t", "--agent", "mini-vero", "--model", "gpt-oss-120b",
                    "--image", args.agent_image, *vero, codes=(64,))
    assert "unknown option --grader" in refused.stderr, refused.stderr

    # The untouched source, graded where the task arrives. No task file is in the snapshot.
    blank = vero_graded(task, "fail", 0)
    # The notice records the grader as it was assigned: its image pinned, its input snapshotted.
    assert "sha256:" in blank["grader"]["image"] and blank["grader"]["input"], blank["grader"]
    ScriptedModel.mode, ScriptedModel.requests = mode, []
    server = ThreadingHTTPServer(("127.0.0.1", 0), ScriptedModel)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        model = ["--provider", "dgx", "--url", f"http://127.0.0.1:{server.server_port}/v1"]
        partial = alaya("run", task, *model, "--time-budget", "1", "--json", codes=(4,))
        paused = json_lines(partial.stdout)[-1]
        assert paused["status"] == "paused", paused
        appended, final = drive(paused["entry"], *model, "--time-budget", "300")
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    assert len(ScriptedModel.requests) == 3
    # The agent is over, and nothing has graded the run yet; graded at its end, it passes.
    assert final["status"] == "done" and final["verdict"] is None, final
    correct = grade_at(final["entry"], "pass", 1)
    trace = log(final["entry"])
    assert trace[2]["entry"] == task and trace[-1]["entry"] == final["entry"], trace
    # What the run was created with is recorded on its opening alone.
    assert [r["position"] for r in trace if r["event"]["type"] == "opened"
            and r["event"]["routine"]["name"] == "agent"] == [1], trace
    ended = [i for i, r in enumerate(trace)
             if r["event"]["type"] == "returned" and r["frame"] == [0]]
    assert len(ended) == 1, trace
    assert trace[ended[0]]["event"]["value"]["status"] == "Submitted", trace[ended[0]]
    submitted, before_end = trace[ended[0]]["entry"], trace[ended[0] - 1]["entry"]
    assert ".grade/report.md" in alaya("ls", correct["answer"], ".grade").stdout
    # Every grading runs the grader again and records a new answer, on a fork.
    again = grade_at(submitted, "pass", 1)
    assert again["answer"] != correct["answer"] and again["entry"] != correct["entry"]
    # Once the agent is over, the run cannot be stopped.
    refused = alaya("stop", final["entry"], codes=(65,))
    assert "over" in refused.stderr, refused.stderr

    # A hand-edited workspace, committed where the agent was about to end, then graded.
    branch = directory / "tampered"
    alaya("checkout", final["entry"], branch)
    (branch / "MINIVERO_TASK.md").write_text("# forged benchmark (proof)\n")
    if mode == "codeproof":
        # Attempt a mode downgrade with a valid proof and no implementation slot.
        (branch / "TinyTrivial/Impl/Core.lean").write_text("")
    else:
        proof = branch / "TinyTrivial/Proof/Core.lean"
        proof.write_text(proof.read_text().replace("  intro n\n  rfl", "  sorry"))
    bad = entry(alaya("commit", before_end, branch, "--message", "negative grading control").stdout)
    rejected = vero_graded(bad, "fail", 0)

    if mode == "codeproof":
        linked = directory / "symlinked"
        alaya("checkout", final["entry"], linked)
        impl = linked / "TinyTrivial/Impl/Core.lean"
        impl.unlink()
        impl.symlink_to("/grader/TinyTrivial/Impl/Core.lean")
        linked_entry = entry(alaya("commit", before_end, linked,
                                   "--message", "trusted-reference symlink attack").stdout)
        symlink_rejection = vero_graded(linked_entry, "fail", 0)
        assert "anti-cheat" in symlink_rejection["record"]["checks"][0]["name"]

    def shell_graded(command, expected, *options):
        """A run on the same source, graded where its task arrives by a shell grader."""
        rows = create()
        return rows, grade_at(rows[-1]["entry"], expected, 1 if expected == "pass" else 0,
                              1 if expected != "error" else 0, grader=["--grader", command, *options])

    # Trusted mount is read-only; grader shares the agent's user and working directory. On
    # Linux that user is the host's, never root; Docker Desktop keeps the image's own.
    non_root = "test \"$(id -u)\" != 0 && " if sys.platform == "linux" else ""
    shell_graded("test \"$PWD\" = /testbed && " + non_root +
                 "! touch /grader/should-not-exist 2>/dev/null && "
                 "printf '1..1\\nok 1 - execution contract\\n'", "pass", "--grader-input", FIXTURE)

    # A grader runs in the run's image unless it names its own, pinned by digest when assigned.
    cache_command = "printf '1..1\\nok 1 - image identity\\n'"
    own_rows, first_image = shell_graded(cache_command, "pass")
    _, second_image = shell_graded(cache_command, "pass",
                                             "--grader-image", args.grader_image)
    assert first_image["image"] != second_image["image"]
    assert first_image["image"] == configuration(own_rows)["environment"]["image"]
    assert configuration(own_rows)["environment"]["image"] == run_record["environment"]["image"]
    assert second_image["image"] == correct["image"] == second_image["grader"]["image"]

    _, timeout = shell_graded("echo 1..1; sleep 20; echo stale > stale.txt; echo 'ok 1 - late'",
                              "error", "--grader-timeout", "1")
    assert "timed out" in timeout["record"]["reason"], timeout["record"]
    for container in run("docker", "ps", "-aq").stdout.split():
        mounts = run("docker", "inspect", "--format", "{{json .Mounts}}", container,
                     codes=(0, 1))
        if mounts.returncode == 0:
            assert not any(m["Source"].startswith(str(data / "tmp") + "/")
                           for m in json.loads(mounts.stdout)), "grader container survived timeout"
    # What the grader wrote is in its checkout, never in the run's workspace.
    assert "stale.txt" not in alaya("ls", timeout["entry"]).stdout
    _, retried = shell_graded("test ! -e stale.txt && printf '1..1\\nok 1 - clean retry\\n'", "pass")
    # Every command's scratch, a grader's checkout included, is gone when the command ends.
    assert not list((data / "tmp").iterdir())
    alaya("html", directory / "report.html")
    result = {"mode": mode, "task": task, "agent_image": run_record["environment"]["image"],
              "blank": blank, "correct": correct, "again": again, "tampered": rejected,
              "budget_exit": partial.returncode, "model_requests": len(ScriptedModel.requests),
              "timeout": timeout["entry"], "retry": retried["entry"]}
    (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"{mode}: blank 0/1, correct 1/1, tampered 0/1; budget pause/continue and cleanup passed",
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
