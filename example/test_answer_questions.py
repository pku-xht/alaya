"""HTTP contract tests with a stub CLI; not a Lean or browser integration test.

Run: python3 -m unittest discover -s example -p test_answer_questions.py
"""

from concurrent.futures import ThreadPoolExecutor
import http.client
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from urllib.parse import urlencode

from answer_questions import MAX_BODY_BYTES, QuestionApplication, QuestionServer


YES_NO = "a" * 64
SINGLE = "b" * 64
OPEN = "c" * 64
REPLY = "d" * 64
QUESTIONS = [
    {"state": YES_NO, "question": "Use this approach?", "question_type": "yes_no", "options": []},
    {"state": SINGLE, "question": "Which fits?", "question_type": "single_choice", "options": ["One", "Two"]},
    {"state": OPEN, "question": "Why?", "question_type": "open_ended", "options": []},
]

STUB_CLI = r'''
import json
from pathlib import Path
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")
args = sys.argv[1:]
delimiter = args.index("--") if "--" in args else len(args)
flags = args[:delimiter]
data = Path(flags[flags.index("--data") + 1])
questions_file = data / "questions.json"
questions = json.loads(questions_file.read_text(encoding="utf-8"))
if args[0] == "waiting":
    assert "--json" in flags
    for question in questions:
        print(json.dumps(question, ensure_ascii=False))
elif args[0] in ("show", "ls", "cat"):
    assert "--json" in flags, "reads ask for JSON"
    assert delimiter < len(args), "reads require a positional delimiter"
    positional = args[delimiter + 1:]
    state = positional[0]
    value = {"state": state, "workspace": "f" * 64}
    if args[0] == "show":
        assert len(positional) == 1
        kind = "question" if state in [q["state"] for q in questions] else "turn"
        value.update(kind=kind, history=[{"state": state, "kind": kind, "events": []}])
    else:
        assert len(positional) == 2
        path = positional[1]
        if ".." in path.split("/") or path.startswith("/"):
            print("invalid snapshot path", file=sys.stderr)
            sys.exit(65)
        value["path"] = path
        if args[0] == "ls":
            value["entries"] = [{"name": "Main.lean", "path": "Main.lean", "kind": "file", "size": 4}]
        else:
            value.update(kind="text", content="code", size=4)
    override = data / "inspect-override.json"
    if override.exists():
        value = json.loads(override.read_text(encoding="utf-8"))
    print(json.dumps(value))
elif args[0] == "reply":
    assert delimiter < len(args), "reply requires a positional delimiter"
    if (data / "busy").exists():
        print("the data directory is in use by another alaya command: try again when it ends",
              file=sys.stderr)
        sys.exit(75)
    if "--unavailable" not in flags:
        state, answer = args[delimiter + 1:]
        value = {"state": state, "answer": answer}
    else:
        state, = args[delimiter + 1:]
        answer = None
        value = {"state": state, "status": "unavailable"}
    with (data / "calls.jsonl").open("a", encoding="utf-8") as calls:
        calls.write(json.dumps(value) + "\n")
    question = next(q for q in questions if q["state"] == state)
    if answer is not None and question["question_type"] == "yes_no" and answer not in ("yes", "no"):
        print("yes/no answers must be yes or no", file=sys.stderr)
        sys.exit(65)
    if answer is not None and question["question_type"] == "single_choice":
        choices = {str(index) for index in range(1, len(question["options"]) + 1)}
        if answer not in choices | {"none_of_above"}:
            print("single-choice answers must select one option or none_of_above", file=sys.stderr)
            sys.exit(65)
    # Match JavaScript String.trim(), including NBSP and ideographic space but
    # excluding Python-only whitespace such as NEL and record separators.
    js_whitespace = "\t\n\v\f\r \u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000\ufeff"
    if answer is not None and question["question_type"] == "open_ended" and not answer.strip(js_whitespace):
        print("open-ended answers must not be blank", file=sys.stderr)
        sys.exit(65)
    time.sleep(0.05)
    questions_file.write_text(json.dumps([q for q in questions if q["state"] != state]), encoding="utf-8")
    print("d" * 64)
else:
    raise AssertionError(args)
'''


class QuestionHttpTests(unittest.TestCase):
    def setUp(self):
        for name, value in (("EVENT_POLL_SECONDS", 0.05), ("EVENT_HEARTBEAT_SECONDS", 0.1)):
            setting = patch(f"answer_questions.{name}", value)
            setting.start()
            self.addCleanup(setting.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        (self.directory / "questions.json").write_text(json.dumps(QUESTIONS), encoding="utf-8")
        script = self.directory / "stub_cli.py"
        script.write_text(STUB_CLI, encoding="utf-8")
        template = self.directory / "page.html"
        template.write_text('<script>const token = "__ALAYA_TOKEN__";</script>', encoding="utf-8")
        application = QuestionApplication([sys.executable, str(script)], self.directory, template)
        self.server = QuestionServer(application)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close_server)

    def close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def request(self, method="GET", path="/api/questions", value=None, headers=None, raw=None):
        request_headers = {"X-Alaya-Token": self.server.application.token}
        if headers:
            request_headers.update(headers)
        request_headers = {key: value for key, value in request_headers.items() if value is not None}
        if value is not None:
            raw = json.dumps(value).encode("utf-8")
            request_headers.setdefault("Content-Type", "application/json")
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=10)
        try:
            connection.request(method, path, body=raw, headers=request_headers)
            response = connection.getresponse()
            body = response.read().decode("utf-8")
            if response.getheader("Content-Type", "").startswith("application/json"):
                body = json.loads(body)
            return response.status, body, dict(response.getheaders())
        finally:
            connection.close()

    def replies(self):
        path = self.directory / "calls.jsonl"
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()] if path.exists() else []

    def open_events(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        connection.request("GET", "/api/events", headers={
            "X-Alaya-Token": self.server.application.token, "Origin": self.server.origin,
        })
        response = connection.getresponse()
        self.addCleanup(connection.close)
        self.addCleanup(response.close)
        self.assertEqual(response.status, 200)
        self.assertEqual(response.getheader("Content-Type"), "text/event-stream; charset=utf-8")
        self.assertEqual(response.getheader("Cache-Control"), "no-store")
        return connection, response

    def event(self, response, include_heartbeat=False):
        while True:
            fields = {}
            while True:
                line = response.readline()
                self.assertTrue(line, "The event stream ended unexpectedly")
                if line == b"\n":
                    break
                key, _, value = line.decode("utf-8").rstrip("\n").partition(":")
                fields[key] = value.lstrip()
            if "event" in fields:
                return fields["event"], json.loads(fields["data"])
            if include_heartbeat:
                self.assertEqual(fields, {"": "keepalive"})
                return None, None

    def wait_until(self, predicate):
        deadline = time.monotonic() + 3
        while not predicate() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(predicate())

    def write_questions(self, questions):
        path = self.directory / "new-questions.json"
        path.write_text(json.dumps(questions), encoding="utf-8")
        path.replace(self.directory / "questions.json")

    def test_events_deliver_initial_and_changed_question_lists(self):
        _, stream = self.open_events()
        self.assertEqual(self.event(stream), ("questions", {"questions": QUESTIONS}))
        changed = [*QUESTIONS, dict(QUESTIONS[2], state="e" * 64, question="Next question?")]
        self.write_questions(changed)
        self.assertEqual(self.event(stream), ("questions", {"questions": changed}))
        self.assertEqual(self.replies(), [])

    def test_events_send_heartbeats_without_duplicate_snapshots(self):
        _, stream = self.open_events()
        self.assertEqual(self.event(stream), ("questions", {"questions": QUESTIONS}))
        self.assertEqual(self.event(stream, include_heartbeat=True), (None, None))

    def test_events_report_backend_failure_then_recover(self):
        _, stream = self.open_events()
        self.assertEqual(self.event(stream), ("questions", {"questions": QUESTIONS}))
        (self.directory / "questions.json").write_text("broken JSON", encoding="utf-8")
        event, value = self.event(stream)
        self.assertEqual(event, "unavailable")
        self.assertIsInstance(value["error"], str)
        self.assertNotIn("questions", value)
        self.write_questions(QUESTIONS)
        self.assertEqual(self.event(stream), ("questions", {"questions": QUESTIONS}))

    def test_events_initial_failure_is_not_an_empty_list(self):
        (self.directory / "questions.json").write_text("broken JSON", encoding="utf-8")
        _, stream = self.open_events()
        event, value = self.event(stream)
        self.assertEqual(event, "unavailable")
        self.assertIn("error", value)
        self.assertNotIn("questions", value)
        self.write_questions([])
        self.assertEqual(self.event(stream), ("questions", {"questions": []}))

    def test_events_disconnect_and_reconnect_receive_fresh_snapshot(self):
        connection, stream = self.open_events()
        self.event(stream)
        monitor = self.server.application.events_thread
        stream.close()
        connection.close()
        self.wait_until(lambda: self.server.application.events_subscribers == 0)
        self.write_questions(QUESTIONS[1:])
        _, reconnected = self.open_events()
        self.assertEqual(self.event(reconnected), ("questions", {"questions": QUESTIONS[1:]}))
        self.assertIs(self.server.application.events_thread, monitor)

    def test_events_share_monitor_and_remove_replied_question(self):
        _, first = self.open_events()
        self.event(first)
        monitor = self.server.application.events_thread
        _, second = self.open_events()
        self.event(second)
        self.assertIs(self.server.application.events_thread, monitor)
        self.assertEqual(self.server.application.events_subscribers, 2)
        self.assertEqual(self.request("POST", "/api/reply", {"state": YES_NO, "answer": "yes"})[0], 200)
        for stream in (first, second):
            self.assertEqual(self.event(stream), ("questions", {"questions": QUESTIONS[1:]}))
            self.assertEqual(self.event(stream, include_heartbeat=True), (None, None))
        self.assertEqual(self.replies(), [{"state": YES_NO, "answer": "yes"}])

    def test_events_shutdown_closes_stream_and_monitor(self):
        _, stream = self.open_events()
        self.event(stream)
        self.server.shutdown()
        self.assertEqual(stream.read(), b"")
        self.wait_until(lambda: self.server.application.events_subscribers == 0)
        self.assertFalse(self.server.application.events_thread.is_alive())

    def test_events_enforce_token_host_and_origin_without_query_tokens(self):
        for headers in ({"X-Alaya-Token": None}, {"X-Alaya-Token": "wrong"},
                        {"X-Alaya-Token": "é"}, {"Origin": "https://elsewhere.test"},
                        {"Host": "localhost:1234"}, {"Sec-Fetch-Site": "cross-site"}):
            with self.subTest(headers=headers):
                self.assertEqual(self.request(path="/api/events", headers=headers)[0], 403)
        self.assertEqual(self.request(path=f"/api/events?token={self.server.application.token}")[0], 404)
        self.assertIsNone(self.server.application.events_thread)

    def test_page_and_question_listing(self):
        status, body, headers = self.request(path="/", headers={"X-Alaya-Token": None})
        self.assertEqual(status, 200)
        self.assertIn(self.server.application.token, body)
        self.assertNotIn("__ALAYA_TOKEN__", body)
        self.assertNotIn(YES_NO, body)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
        status, body, _ = self.request()
        self.assertEqual((status, body), (200, {"questions": QUESTIONS}))

    def test_unicode_separators_remain_inside_question_records(self):
        question = dict(QUESTIONS[1], question="Line\u0085Next\u2028Paragraph\u2029End",
                        options=["First\u2028option", "Second\u2029option"])
        (self.directory / "questions.json").write_text(json.dumps([question]), encoding="utf-8")
        status, body, _ = self.request()
        self.assertEqual((status, body), (200, {"questions": [question]}))
        status, body, _ = self.request("POST", "/api/reply", {"state": question["state"], "answer": "1"})
        self.assertEqual((status, body), (200, {"reply": REPLY}))

    def test_valid_answers_and_verbatim_open_text(self):
        answers = [(YES_NO, "no"), (SINGLE, "2"), (OPEN, "  Quotes '\"; $(literal)\n中文 <script>example</script>  ")]
        for state, answer in answers:
            with self.subTest(state=state):
                status, body, _ = self.request("POST", "/api/reply", {"state": state, "answer": answer},
                                               headers={"Origin": self.server.origin})
                self.assertEqual((status, body), (200, {"reply": REPLY}))
        self.assertEqual(self.replies(), [{"state": state, "answer": answer} for state, answer in answers])
        self.assertEqual(self.request()[1], {"questions": []})

    def test_open_answers_resembling_flags_and_nonblank_unicode(self):
        answers = ["--data", "-m", "--", "\u0085", "\u001c", " \u00a0中文\u3000 "]
        questions = [dict(QUESTIONS[2], state=f"{index:064x}")
                     for index in range(1, len(answers) + 1)]
        (self.directory / "questions.json").write_text(json.dumps(questions), encoding="utf-8")
        expected = []
        for question, answer in zip(questions, answers):
            with self.subTest(answer=answer):
                value = {"state": question["state"], "answer": answer}
                status, body, _ = self.request("POST", "/api/reply", value)
                self.assertEqual((status, body), (200, {"reply": REPLY}))
                expected.append(value)
        self.assertEqual(self.replies(), expected)
        self.assertEqual(self.request()[1], {"questions": []})

    def test_invalid_answer_preserves_waiting(self):
        status, body, _ = self.request("POST", "/api/reply", {"state": YES_NO, "answer": "maybe"})
        self.assertEqual(status, 400)
        self.assertIn("yes or no", body["error"])
        self.assertEqual(self.request()[1], {"questions": QUESTIONS})
        self.assertEqual(self.request("POST", "/api/reply", {"state": YES_NO, "answer": "yes"})[0], 200)

    def test_single_choice_none_of_above_is_a_real_answer(self):
        value = {"state": SINGLE, "answer": "none_of_above"}
        self.assertEqual(self.request("POST", "/api/reply", value)[:2], (200, {"reply": REPLY}))
        self.assertEqual(self.replies(), [value])
        self.assertEqual(self.request()[1], {"questions": [QUESTIONS[0], QUESTIONS[2]]})

    def test_single_choice_rejects_arrays_empty_and_invalid_indices_without_removing_question(self):
        for answer in ("[]", "[1]", "[1,2]", "", " ", "0", "3", "01", '"1"', "None of the above"):
            with self.subTest(answer=answer):
                status, body, _ = self.request("POST", "/api/reply", {"state": SINGLE, "answer": answer})
                self.assertEqual(status, 400)
                self.assertIn("select one", body["error"])
                self.assertEqual(self.request()[1], {"questions": QUESTIONS})
        self.assertEqual(self.request("POST", "/api/reply", {"state": SINGLE, "answer": "1"})[0], 200)

    def test_blank_open_answers_preserve_waiting_and_do_not_publish_removal(self):
        _, stream = self.open_events()
        self.assertEqual(self.event(stream), ("questions", {"questions": QUESTIONS}))
        for answer in ("", " \t\n\r", "\u00a0", "\u3000", "\ufeff\u2028\u2029"):
            with self.subTest(answer=answer):
                status, body, _ = self.request("POST", "/api/reply", {"state": OPEN, "answer": answer})
                self.assertEqual(status, 400)
                self.assertIn("must not be blank", body["error"])
                self.assertEqual(self.request()[1], {"questions": QUESTIONS})
        self.assertEqual(self.event(stream, include_heartbeat=True), (None, None))
        value = {"state": OPEN, "answer": " \u00a0keep this\u3000 "}
        self.assertEqual(self.request("POST", "/api/reply", value)[0], 200)
        self.assertEqual(self.replies()[-1], value)

    def test_unavailable_is_distinct_for_every_form(self):
        expected = []
        for question in QUESTIONS:
            value = {"state": question["state"], "status": "unavailable"}
            self.assertEqual(self.request("POST", "/api/reply", value)[:2], (200, {"reply": REPLY}))
            expected.append(value)
        self.assertEqual(self.replies(), expected)
        self.assertEqual(self.request()[1], {"questions": []})

    def test_unavailable_rejects_ambiguous_or_unknown_status(self):
        for value in ({"state": YES_NO, "status": "unavailable", "answer": "no"},
                      {"state": YES_NO, "status": "unknown"},
                      {"state": YES_NO, "status": None},
                      {"state": YES_NO, "answer": None}):
            self.assertEqual(self.request("POST", "/api/reply", value)[0], 400)
        self.assertEqual(self.replies(), [])

    def test_context_and_snapshot_reads_are_pinned_and_read_only(self):
        endpoints = [("context", {"state": YES_NO}),
                     ("files", {"state": YES_NO, "path": ""}),
                     ("file", {"state": YES_NO, "path": "--data"}),
                     ("file", {"state": YES_NO, "path": "src/中文 #?.lean"})]
        for endpoint, query in endpoints:
            status, body, headers = self.request(path=f"/api/{endpoint}?{urlencode(query)}")
            self.assertEqual(status, 200)
            self.assertEqual(body["state"], YES_NO)
            self.assertEqual(body["workspace"], "f" * 64)
            self.assertEqual(headers["Cache-Control"], "no-store")
            if "path" in query:
                self.assertEqual(body["path"], query["path"])
        self.assertEqual(self.replies(), [])
        self.assertEqual(self.request()[1], {"questions": QUESTIONS})

    def test_context_queries_validate_state_and_path(self):
        paths = ["/api/context", f"/api/context?state={YES_NO}&state={YES_NO}",
                 "/api/context?state=../../states", f"/api/context?state={YES_NO}&path=x",
                 f"/api/file?state={YES_NO}", f"/api/file?state={YES_NO}&path=%00",
                 f"/api/file?state={YES_NO}&path=%FF",
                 f"/api/files?state={YES_NO}&path=../escape",
                 f"/api/file?state={YES_NO}&path=/etc/passwd"]
        for path in paths:
            with self.subTest(path=path):
                self.assertEqual(self.request(path=path)[0], 400)
        self.assertEqual(self.replies(), [])

    def test_context_refuses_mismatched_backend_response(self):
        (self.directory / "inspect-override.json").write_text(
            json.dumps({"state": SINGLE, "workspace": "f" * 64}), encoding="utf-8")
        status, body, _ = self.request(path=f"/api/context?state={YES_NO}")
        self.assertEqual(status, 502)
        self.assertIn("unexpected state", body["error"])

    def test_context_is_only_for_questions_the_page_listed(self):
        for endpoint, query in [("context", {"state": "e" * 64}),
                                ("files", {"state": "e" * 64, "path": ""}),
                                ("file", {"state": "e" * 64, "path": "Main.lean"})]:
            with self.subTest(endpoint=endpoint):
                status, body, _ = self.request(path=f"/api/{endpoint}?{urlencode(query)}")
                self.assertEqual(status, 404)
                self.assertIn("not a question", body["error"])

    def test_context_is_the_question_branch(self):
        status, body, _ = self.request(path=f"/api/context?{urlencode({'state': YES_NO})}")
        self.assertEqual((status, body), (200, {"state": YES_NO, "workspace": "f" * 64,
            "history": [{"state": YES_NO, "kind": "question", "events": []}]}))

    def test_context_endpoints_require_token_and_same_origin(self):
        for endpoint, query in [("context", {"state": YES_NO}),
                                ("files", {"state": YES_NO, "path": ""}),
                                ("file", {"state": YES_NO, "path": "Main.lean"})]:
            path = f"/api/{endpoint}?{urlencode(query)}"
            for headers in ({"X-Alaya-Token": None}, {"Origin": "http://elsewhere.test"}):
                self.assertEqual(self.request(path=path, headers=headers)[0], 403)

    def test_a_busy_data_directory_is_a_retryable_failure(self):
        (self.directory / "busy").write_text("", encoding="utf-8")
        status, body, _ = self.request("POST", "/api/reply", {"state": YES_NO, "answer": "yes"})
        self.assertEqual(status, 503)
        self.assertIn("try again", body["error"])
        (self.directory / "busy").unlink()
        self.assertEqual(self.request("POST", "/api/reply", {"state": YES_NO, "answer": "yes"})[0], 200)

    def test_stale_question_never_calls_reply(self):
        status, body, _ = self.request("POST", "/api/reply", {"state": "e" * 64, "answer": "yes"})
        self.assertEqual(status, 409)
        self.assertIn("no longer waiting", body["error"])
        self.assertEqual(self.replies(), [])

    def test_concurrent_submissions_record_only_one_reply(self):
        gate = threading.Barrier(2)

        def submit(answer):
            gate.wait(timeout=5)
            return self.request("POST", "/api/reply", {"state": YES_NO, "answer": answer})[0]

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(submit, ["yes", "no"]))
        self.assertEqual(sorted(results), [200, 409])
        self.assertEqual(len(self.replies()), 1)

    def test_tokens_required_for_api_reads_and_writes(self):
        for token in (None, "wrong", "é"):
            for method, path, value in [("GET", "/api/questions", None),
                                        ("POST", "/api/reply", {"state": YES_NO, "answer": "yes"})]:
                with self.subTest(token=token, method=method):
                    self.assertEqual(self.request(method, path, value, {"X-Alaya-Token": token})[0], 403)
        self.assertEqual(self.replies(), [])

    def test_cross_origin_and_host_rejected(self):
        for headers in ({"Origin": "https://example.com"}, {"Origin": "null"},
                        {"Host": "example.com"}, {"Host": "localhost:1234"},
                        {"Sec-Fetch-Site": "cross-site"}, {"Sec-Fetch-Site": "same-site"}):
            with self.subTest(headers=headers):
                self.assertEqual(self.request("POST", "/api/reply", {"state": YES_NO, "answer": "yes"}, headers)[0], 403)
                self.assertEqual(self.request(path="/", headers=headers)[0], 403)
        self.assertEqual(self.request("OPTIONS", "/api/reply")[0], 403)
        self.assertEqual(self.replies(), [])

    def test_invalid_payload_never_calls_reply(self):
        for value in ([], {}, {"state": "bad", "answer": "yes"}, {"state": YES_NO, "answer": [1]},
                      {"state": SINGLE, "answer": []}, {"state": SINGLE, "answer": [1]},
                      {"state": YES_NO, "answer": "yes", "extra": True},
                      {"state": YES_NO, "answer": "a\0b"}, {"state": YES_NO, "answer": "\ud800"}):
            with self.subTest(value=value):
                self.assertEqual(self.request("POST", "/api/reply", value)[0], 400)
        for raw in (b"{", b"\xff", b"[" * 2000):
            with self.subTest(raw=raw[:10]):
                self.assertEqual(self.request("POST", "/api/reply", raw=raw,
                                              headers={"Content-Type": "application/json"})[0], 400)
        self.assertEqual(self.replies(), [])

    def test_content_type_and_size_limits(self):
        status, _, _ = self.request("POST", "/api/reply", raw=b"{}")
        self.assertEqual(status, 415)
        status, _, _ = self.request("POST", "/api/reply", raw=b"{}", headers={
            "Content-Type": "application/json", "Content-Length": str(MAX_BODY_BYTES + 1)})
        self.assertEqual(status, 413)
        self.assertEqual(self.replies(), [])

    def test_no_file_or_command_endpoints(self):
        for path in ("/../questions.json", "/answer_questions.py", "/api/resume", "/?token=x"):
            with self.subTest(path=path):
                self.assertEqual(self.request(path=path)[0], 404)
        self.assertEqual(self.replies(), [])

    def test_backend_failures_report_json(self):
        payloads = ["broken JSON", *(
            json.dumps([dict(QUESTIONS[0], question_type=kind)])
            for kind in ("unsupported", "multiple_choice")
        )]
        for payload in payloads:
            with self.subTest(payload=payload):
                (self.directory / "questions.json").write_text(payload, encoding="utf-8")
                status, body, _ = self.request()
                self.assertEqual(status, 502)
                self.assertIsInstance(body["error"], str)


if __name__ == "__main__":
    unittest.main()
