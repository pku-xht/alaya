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
import unittest

from answer_questions import MAX_BODY_BYTES, QuestionApplication, QuestionServer


YES_NO = "a" * 64
MULTIPLE = "b" * 64
OPEN = "c" * 64
REPLY = "d" * 64
QUESTIONS = [
    {"state": YES_NO, "question": "Use this approach?", "question_type": "yes_no", "options": []},
    {"state": MULTIPLE, "question": "Which apply?", "question_type": "multiple_choice", "options": ["One", "Two"]},
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
    assert "--json" in args
    for question in questions:
        print(json.dumps(question, ensure_ascii=False))
elif args[0] == "reply":
    assert delimiter < len(args), "reply requires a positional delimiter"
    state, answer = args[delimiter + 1:]
    with (data / "calls.jsonl").open("a", encoding="utf-8") as calls:
        calls.write(json.dumps({"state": state, "answer": answer}) + "\n")
    question = next(q for q in questions if q["state"] == state)
    if question["question_type"] == "yes_no" and answer not in ("yes", "no"):
        print("yes/no answers must be yes or no", file=sys.stderr)
        sys.exit(1)
    time.sleep(0.05)
    questions_file.write_text(json.dumps([q for q in questions if q["state"] != state]), encoding="utf-8")
    print("d" * 64)
else:
    raise AssertionError(args)
'''


class QuestionHttpTests(unittest.TestCase):
    def setUp(self):
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
        status, body, _ = self.request("POST", "/api/reply", {"state": question["state"], "answer": "[]"})
        self.assertEqual((status, body), (200, {"reply": REPLY}))

    def test_valid_answers_and_verbatim_open_text(self):
        answers = [(YES_NO, "no"), (MULTIPLE, "[]"), (OPEN, "Quotes '\"; $(literal)\n中文 <script>example</script>")]
        for state, answer in answers:
            with self.subTest(state=state):
                status, body, _ = self.request("POST", "/api/reply", {"state": state, "answer": answer},
                                               headers={"Origin": self.server.origin})
                self.assertEqual((status, body), (200, {"reply": REPLY}))
        self.assertEqual(self.replies(), [{"state": state, "answer": answer} for state, answer in answers])
        self.assertEqual(self.request()[1], {"questions": []})

    def test_open_answers_resembling_flags_and_empty_text(self):
        answers = ["--data", "-m", "", "--"]
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
        (self.directory / "questions.json").write_text("broken JSON", encoding="utf-8")
        status, body, _ = self.request()
        self.assertEqual(status, 502)
        self.assertIsInstance(body["error"], str)


if __name__ == "__main__":
    unittest.main()
