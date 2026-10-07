"""Requested tools are not the same as effects that actually occurred."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import summarize

class EvidenceCounts(unittest.TestCase):
    def test_counts_delivered_questions_separately_from_requests(self):
        events = [
            {'entry': 'a', 'elapsed_ms': 1, 'event': {'type': 'arrived', 'notice': {'type': 'said'}}},
            {'entry': 'b', 'elapsed_ms': 1000, 'event': {'type': 'answered', 'op': {'type': 'sample'},
                'answer': {'tool_calls': [{'name': 'ask_user'}, {'name': 'bash'}], 'finish_reason': 'tool_calls'}}},
            {'entry': 'c', 'elapsed_ms': 1000, 'event': {'type': 'answered', 'op': {'type': 'sample'},
                'answer': {'tool_calls': [{'name': 'ask_user'}], 'finish_reason': 'tool_calls'}}},
            {'entry': 'd', 'elapsed_ms': 2, 'event': {'type': 'asked',
                'question': {'text': 'fixture', 'form': {'type': 'open_ended'}}}}]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'state.json').write_text(json.dumps({'entry': 'd', 'status': 'waits'}))
            (root / 'manifest.json').write_text(json.dumps({'task': 'fixture', 'arm': 'help',
                'guidance_sha256': 'fixture', 'binary_sha256': 'fixture'}))
            output = '\n'.join(json.dumps(e) for e in events).encode()
            with patch.object(summarize.subprocess, 'run', return_value=SimpleNamespace(stdout=output)):
                result = summarize.summarize(Path('/unused'), root)
            self.assertEqual(result['tool_requests']['ask_user'], 2)
            self.assertEqual(len(result['questions']), 1)
            self.assertEqual(result['executed_bash_commands'], 0)
            self.assertEqual(result['external_notices_before_first_sample'], ['said'])

if __name__ == '__main__':
    unittest.main()
