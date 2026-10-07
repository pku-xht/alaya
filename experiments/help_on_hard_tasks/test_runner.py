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

class InitialEventAudit(unittest.TestCase):
    def make_log(self, notice=None):
        log = [
            {'entry': 'workspace-root', 'event': {'type': 'arrived', 'notice': {'type': 'changed'}}},
            {'entry': 'session-tip', 'event': {'type': 'opened'}},
            {'entry': 'agent-call', 'event': {'type': 'arrived', 'notice': {'type': 'called'}}},
        ]
        if notice:
            log.append({'entry': 'intervention', 'event': {'type': 'arrived', 'notice': {'type': notice}}})
        log.append({'entry': 'first-sample', 'event': {'type': 'answered', 'op': {
            'type': 'sample', 'model': {'name': run.MODEL, 'params': {
                'max_tokens': run.OUTPUT, 'temperature': 0}}}, 'answer': {}}})
        return [dict(row, position=i) for i, row in enumerate(log)]

    def audit_request(self, root, log):
        guidance = 'Fixture guidance.'
        (root / 'guidance.md').write_text(guidance)
        run.write(root / 'manifest.json', {'root': 'session-tip', 'arm': 'solo'})
        (root / 'first-request.jsonl').write_text(json.dumps({'request': {
            'messages': [{'role': 'system', 'content': 'System.\n' + guidance},
                         {'role': 'user', 'content': 'Task.'}],
            'tools': [{'name': name} for name in ('bash', 'submit', 'time_budget')]}}) + '\n')
        runner = run.Run(argparse.Namespace(root=root, binary=Path('/unused')))
        with patch.object(runner, 'last', side_effect=AssertionError('audit must remain offline')):
            runner.audit_request(log)

    def test_initial_workspace_is_allowed_and_session_tip_is_ancestor(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.audit_request(root, self.make_log())
            result = run.read(root / 'request-audit.json')
            self.assertTrue(result['passed'])
            self.assertEqual(result['initial_workspace_event'], {
                'entry': 'workspace-root', 'position': 0, 'type': 'changed'})
            self.assertTrue(result['manifest_root_is_ancestor'])
            self.assertEqual(result['external_notices_before_first_sample'], [])

    def test_reply_tell_and_later_workspace_change_are_rejected(self):
        for notice in ('replied', 'said', 'changed'):
            with self.subTest(notice=notice), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with self.assertRaisesRegex(RuntimeError, 'external notices: ' + notice):
                    self.audit_request(root, self.make_log(notice))
                self.assertFalse((root / 'request-audit.json').exists())

    def test_initial_event_must_be_position_zero_workspace_change(self):
        for bad_root in (
            {'position': 1, 'event': {'type': 'arrived', 'notice': {'type': 'changed'}}},
            {'position': 0, 'event': {'type': 'arrived', 'notice': {'type': 'said'}}},
        ):
            with self.subTest(root=bad_root):
                log = self.make_log()
                log[0] = dict(bad_root, entry='workspace-root')
                with self.assertRaisesRegex(RuntimeError, 'position-zero workspace'):
                    run.audit_initial_events(log, 'session-tip', 'first-sample')

    def test_manifest_root_must_precede_first_sample(self):
        log = self.make_log()
        for root in ('missing-tip', 'first-sample'):
            with self.subTest(root=root), self.assertRaisesRegex(RuntimeError, 'not an ancestor'):
                run.audit_initial_events(log, root, 'first-sample')

if __name__ == '__main__':
    unittest.main()
