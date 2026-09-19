"""Delivery and measurement checks without network calls or Vero dependencies."""
import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import compare_vero_runs as metrics
import record_model_io as recorder
from vero_smoke import instruction_delivery
from vero_smoke import call


class OutputExperimentTests(unittest.TestCase):
    def test_failed_helper_preserves_redacted_diagnostics(self):
        failure = subprocess.CalledProcessError(1, ["grader"], stderr="storage error private-key")
        with patch.dict(os.environ, {"XMCP_API_KEY": "private-key"}), patch("vero_smoke.subprocess.run", side_effect=failure):
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                call(["grader"])
        notes = "\n".join(raised.exception.__notes__)
        self.assertIn("storage error [REDACTED]", notes)
        self.assertNotIn("private-key", notes)

    def test_instruction_delivery_preserves_middle_unicode_and_line_endings(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            raw = ("前" * 7000 + "\r\nDONE: prove every condition\r\n" + "尾" * 7000).encode()
            source = root / "INSTRUCTION.md"
            source.write_bytes(raw)
            info = instruction_delivery(root, "original task", source)
            self.assertEqual((root / "delivered-task.txt").read_bytes(), b"original task\n\n" + raw)
            self.assertEqual(info["instruction_sha256"], hashlib.sha256(raw).hexdigest())
            self.assertEqual(source.read_bytes(), raw)

    def test_capture_keeps_bodies_and_never_reads_credentials_or_headers(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            request, response = root / "in.json", root / "out.json"
            request.write_text('{"model":"closeai/gpt-5.4-mini","temperature":0,"messages":[]}')
            arguments = ["--config", str(root / "must-not-be-read.conf"), "--data", "@" + str(request),
                         "--output", str(response), "--dump-header", str(root / "must-not-be-read.headers"),
                         recorder.ENDPOINT]
            def fake(args, **kwargs):
                self.assertEqual(args, ["fake-curl", *arguments])
                response.write_text('{"usage":{"total_tokens":23},"cost":0.1}')
                return subprocess.CompletedProcess(args, 7)
            with patch.dict(os.environ, {"ALAYA_MODEL_IO_DIR": str(root / "capture")}), patch.object(recorder.subprocess, "run", side_effect=fake):
                self.assertEqual(recorder.run(arguments, curl="fake-curl"), 7)
            files = list((root / "capture").iterdir())
            self.assertEqual(len(files), 3)
            self.assertFalse(any("config" in p.name or "headers" in p.name for p in files))
            meta = json.loads(next(p for p in files if p.name.endswith("meta.json")).read_text())
            self.assertEqual(meta["curl_exit_code"], 7)
            self.assertEqual(meta["request_sha256"], hashlib.sha256(request.read_bytes()).hexdigest())

    def test_capture_failure_prevents_unrecorded_paid_call(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            request = root / "request.json"
            request.write_text("{}")
            destination = root / "not-a-directory"
            destination.write_text("occupied")
            with patch.dict(os.environ, {"ALAYA_MODEL_IO_DIR": str(destination)}), patch.object(recorder.subprocess, "run") as run:
                with self.assertRaises(OSError):
                    recorder.run(["--data", "@" + str(request), "--output", str(root / "out"), recorder.ENDPOINT])
                run.assert_not_called()

    def test_unrelated_curl_is_unchanged_and_unrecorded(self):
        with patch.dict(os.environ, {"ALAYA_MODEL_IO_DIR": "unused"}), patch.object(recorder.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0)
            recorder.run(["https://example.invalid"], curl="curl-real")
            run.assert_called_once_with(["curl-real", "https://example.invalid"], check=False)

    def test_read_metrics_prove_middle_and_unicode_page_match(self):
        text = "α" * 10000 + "中🙂" * 6000 + "end"
        ref = "sha256:" + hashlib.sha256(text.encode()).hexdigest()
        original = {"type": "observation", "call_id": "large", "content": {"output": text, "exit_code": 0}}
        args = {"ref": ref, "offset": 10000, "limit": 10000}
        response = {"type": "response", "response": {"tool_calls": [{"id": "read", "name": "read_output", "arguments": args}]}}
        result = {"type": "observation", "call_id": "read", "content": {"content": text[10000:20000], "end_offset": 20000, "eof": False}}
        measured = metrics.output_metrics([response, result], [original, response, result])
        self.assertEqual(measured["reread_calls"], 1)
        self.assertTrue(measured["reread_results"][0]["exact_match"])
        result["content"]["content"] = "wrong"
        with self.assertRaisesRegex(ValueError, "differs"):
            metrics.output_metrics([response, result], [original, response, result])

    def test_capture_metrics_deduplicate_truncation_and_verify_actual_input(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            request = {"model": "closeai/gpt-5.4-mini", "temperature": 0, "messages": [
                {"role": "user", "content": "task\n\nfull instructions"},
                {"role": "tool", "tool_call_id": "one", "content": json.dumps({"elided_chars": 20})}]}
            for i in range(2):
                raw = json.dumps(request).encode()
                (root / f"{i}.request.json").write_bytes(raw)
                (root / f"{i}.meta.json").write_text(json.dumps({"request_sha256": hashlib.sha256(raw).hexdigest(),
                    "response_sha256": None, "response_present": False}))
            result = metrics.read_captures(root, "full instructions")
            self.assertTrue(result["full_instruction_in_first_request"])
            self.assertEqual(result["unique_truncated_results_sent"], 1)
            self.assertEqual(result["request_count"], 2)
            self.assertEqual(metrics.cost_fields({"usage": {"cost": .5, "prompt_tokens": 25}}), {"usage.cost": .5})

    def test_reference_validation_does_not_use_sibling_outputs(self):
        states = {"root": {"parent": None, "appended": []},
                  "left": {"parent": "root", "appended": [{"type": "observation", "content": {"output": "private-left"}}]},
                  "right": {"parent": "root", "appended": []}}
        self.assertEqual(metrics.ancestry_events(states, "right"), [])
        self.assertEqual(len(metrics.ancestry_events(states, "left")), 1)

    def test_cache_request_must_match_the_actual_transport_payload(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            sent, cache = root / "sent", root / "cache"
            sent.mkdir(); cache.mkdir()
            request = {"messages": [{"role": "user", "content": "full task"}]}
            model = {"model": "closeai/gpt-5.4-mini", "temperature": 0}
            (sent / "one.request.json").write_text(json.dumps({**request, **model}))
            entry = {"key": json.dumps({"request": request, "model": model, "structured_output": "native"})}
            (cache / "one.json").write_text(json.dumps(entry))
            self.assertEqual(metrics.verify_sent_cache(sent, cache), 1)
            (sent / "one.request.json").write_text(json.dumps({"messages": [], **model}))
            with self.assertRaisesRegex(ValueError, "exact sent"):
                metrics.verify_sent_cache(sent, cache)


if __name__ == "__main__":
    unittest.main()
