"""Deterministic guard tests. No provider, Docker, or credential store access."""
import argparse
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import run

class RunnerGuards(unittest.TestCase):
    def test_fresh_seed_refuses_an_existing_root_before_calling_cli(self):
        with tempfile.TemporaryDirectory() as root:
            runner = run.Run(argparse.Namespace(root=Path(root), binary=Path('/unused')))
            with self.assertRaisesRegex(RuntimeError, 'absent'):
                runner.seed()

    def test_resume_retains_cumulative_time_and_subtracts_prior_samples(self):
        with tempfile.TemporaryDirectory() as root:
            p = Path(root)
            binary = p / 'binary'
            binary.write_text('frozen')
            runner = run.Run(argparse.Namespace(root=p, binary=binary, credential_file=None))
            run.write(p / 'manifest.json', {'binary_sha256': run.digest(binary)})
            runner.save({'status': 'replied', 'samples': 13, 'segment': 1, 'entry': 'reply-entry', 'replies': 1})
            call_args = []
            def last(label, *args, **kwargs):
                if label == 'segment-002':
                    call_args.extend(args)
                    return {'entry': 'terminal', 'status': 'done'}
                return {'run_time_ms': 1799000}
            with patch.object(runner, 'last', last), patch.object(runner, 'cmd', return_value=[]), \
                 patch.object(runner, 'model_env', return_value={}), patch.object(runner, 'audit_request'):
                runner.advance()
            self.assertEqual(call_args[call_args.index('--samples') + 1], 1011)
            self.assertEqual(call_args[call_args.index('--time-budget') + 1], 1800)

    def test_reply_rejects_unattributed_or_human_label(self):
        with tempfile.TemporaryDirectory() as root:
            p = Path(root)
            answer, provenance = p / 'a.txt', p / 'p.json'
            answer.write_text('advice')
            run.write(provenance, {'author_type': 'human'})
            runner = run.Run(argparse.Namespace(root=p, binary=p / 'unused', answer=answer, provenance=provenance))
            runner.save({'status': 'waits', 'replies': 0})
            with self.assertRaisesRegex(RuntimeError, 'assistant-proxy'):
                runner.reply()

    def test_grading_refuses_a_live_run(self):
        with tempfile.TemporaryDirectory() as root:
            p = Path(root)
            runner = run.Run(argparse.Namespace(root=p, binary=p / 'unused'))
            runner.save({'status': 'running'})
            with self.assertRaisesRegex(RuntimeError, 'terminal'):
                runner.grade()

if __name__ == '__main__':
    unittest.main()
