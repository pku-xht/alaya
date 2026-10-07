#!/usr/bin/env python3
"""Fresh event-log runs; attributed replies; terminal grading. Linux only.

Raw CLI output remains under --root (ignored/local scratch). No secret is serialized.
"""
from __future__ import annotations
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

SECONDS = 1800
SAMPLES = 1024
OUTPUT = 65536
MODEL = 'deepseek-v4.1-flash'
PROVIDER = 'xmcp'
AGENT_IMAGE = 'alaya-human-help-agent:20261003'

def read(path):
    return json.loads(Path(path).read_text())

def write(path, data):
    Path(path).write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def utc():
    return dt.datetime.now(dt.timezone.utc).isoformat()

def rows(path):
    result = []
    for line in Path(path).read_text().splitlines():
        if line.strip():
            result.append(json.loads(line))
    return result

def samples(log):
    return [r for r in log if r.get('event', {}).get('type') == 'answered'
            and r['event'].get('op', {}).get('type') == 'sample']

def audit_initial_events(log, manifest_root, first_sample_entry):
    """Separate the initial workspace from later external intervention.

    `new` returns the opened session tip, so manifest.root is an ancestor of the
    first sample, not necessarily the position-zero workspace event itself.
    """
    first_index = next((i for i, row in enumerate(log)
                        if row.get('entry') == first_sample_entry), None)
    if first_index is None or first_index == 0:
        raise RuntimeError('first sample has no initial event prefix')
    prefix = log[:first_index]
    initial = prefix[0]
    event = initial.get('event', {})
    if (initial.get('position') != 0 or event.get('type') != 'arrived'
            or event.get('notice', {}).get('type') != 'changed'):
        raise RuntimeError('log must start with the position-zero workspace changed event')
    if not manifest_root or not any(row.get('entry') == manifest_root for row in prefix):
        raise RuntimeError('manifest root is not an ancestor before the first sample')
    unexpected = [row['event']['notice']['type'] for row in prefix[1:]
                  if row.get('event', {}).get('type') == 'arrived'
                  and row['event'].get('notice', {}).get('type') in ('said', 'changed', 'replied')]
    if unexpected:
        raise RuntimeError('unexpected pre-sample external notices: ' + ', '.join(unexpected))
    return {'initial_workspace_event': {'entry': initial['entry'], 'position': 0, 'type': 'changed'},
            'manifest_root_is_ancestor': True, 'external_notices_before_first_sample': []}

class Run:
    def __init__(self, args):
        self.a = args
        self.root = args.root.resolve()
        self.data = self.root / 'data'
        self.binary = args.binary.resolve()

    def cmd(self, label, *args, allowed=(0,), env=None):
        self.root.mkdir(parents=True, exist_ok=True)
        path = self.root / f'{label}.jsonl'
        err = self.root / f'{label}.stderr'
        if path.exists():
            raise RuntimeError(f'refusing to overwrite {path}')
        with path.open('w') as out, err.open('w') as error:
            result = subprocess.run([str(self.binary), *map(str, args), '--data', str(self.data), '--json'],
                                    stdout=out, stderr=error, env=env)
        output = rows(path)
        if result.returncode not in allowed:
            # Do not echo arbitrary provider error bodies or raw traffic.
            raise RuntimeError(f'{label} exit {result.returncode}; inspect local {err} and {path}')
        return output

    def last(self, label, *args, **kwargs):
        return self.cmd(label, *args, **kwargs)[-1]

    def state(self):
        return read(self.root / 'state.json')

    def save(self, state):
        write(self.root / 'state.json', state)

    def model_env(self):
        env = os.environ.copy()
        if not env.get('XMCP_API_KEY') and self.a.credential_file:
            import yaml
            credential = yaml.safe_load(self.a.credential_file.read_text())
            key = credential.get('refs', {}).get('XMCP_API_KEY')
            if not isinstance(key, str) or not key.strip():
                raise RuntimeError('XMCP key absent in credential store')
            env['XMCP_API_KEY'] = key
        if not env.get('XMCP_API_KEY'):
            raise RuntimeError('XMCP credential missing')
        return env

    def seed(self):
        if self.root.exists():
            raise RuntimeError('fresh run requires absent --root')
        preflight = read(self.a.task_root / 'audit.json')
        if preflight['public_compilation_exit'] != 0:
            raise RuntimeError('candidate failed public-module compilation')
        self.root.mkdir(parents=True)
        source = self.root / 'source'
        shutil.copytree(self.a.task_root / 'source', source, symlinks=True)
        actual = {str(p.relative_to(source)): digest(p) for p in sorted(source.rglob('*'))
                  if p.is_file() and '.lake' not in p.parts}
        if actual != preflight['public_source_sha256']:
            raise RuntimeError('pristine source hash mismatch')
        shutil.copyfile(self.a.guidance, self.root / 'guidance.md')
        shutil.copyfile(self.a.task_root / 'MINIVERO_TASK.md', self.root / 'task.md')
        root = self.last('new', 'new', source)['entry']
        call = self.last('call', 'call', root, 'help-study', '--image', AGENT_IMAGE,
            '--set-file', f'task={self.root / "task.md"}', '--set', 'mode=codeproof',
            '--set', f'model={MODEL}', '--set', f'model.params.max_tokens={OUTPUT}',
            '--set', f'model.output_tokens={OUTPUT}', '--set', 'model.params.temperature=0',
            '--set', 'question_types=["open_ended"]' if self.a.arm == 'help' else 'question_types=[]',
            '--set-file', f'guidance={self.root / "guidance.md"}')['entry']
        # `--samples 0` means unlimited in this CLI, so preparation never calls resume.
        log = self.cmd('initial-log', 'log', call)
        if samples(log):
            raise RuntimeError('initialization unexpectedly sampled')
        write(self.root / 'manifest.json', {
            'study': 'help-hard-20261007', 'task': preflight['task'], 'arm': self.a.arm,
            'created': utc(), 'model': MODEL, 'provider': PROVIDER, 'route': 'ds/deepseek-flash',
            'max_output_tokens': OUTPUT, 'max_samples': SAMPLES, 'cumulative_seconds': SECONDS,
            'temperature': 0, 'helper': 'assistant_proxy' if self.a.arm == 'help' else 'unavailable_tool',
            'root': root, 'initial_call': call, 'first_request_entry': None,
            'grader_image': preflight['grader_image'], 'grader_image_id': preflight['grader_image_id'],
            'pristine_source_sha256': actual, 'guidance_sha256': digest(self.root / 'guidance.md'),
            'binary_sha256': digest(self.binary), 'runner_sha256': digest(__file__),
            'source_base': 'c2aefbea19de06b53357c5b8ee505c859043cc03'})
        self.save({'entry': call, 'status': 'prepared', 'segment': 0, 'replies': 0, 'samples': 0})
        print(json.dumps({'status': 'prepared', 'root': str(self.root), 'entry': call}))

    def audit_request(self, log):
        sampled = samples(log)
        if not sampled:
            return
        path = self.root / 'first-request.jsonl'
        request = rows(path)[-1] if path.exists() else self.last('first-request', 'show', sampled[0]['entry'], '--request')
        actual = request['request']
        messages = actual['messages']
        guidance = (self.root / 'guidance.md').read_text()
        manifest = read(self.root / 'manifest.json')
        expected = ['bash', 'submit', 'ask_user', 'time_budget'] if manifest['arm'] == 'help' else ['bash', 'submit', 'time_budget']
        tools = [t.get('name', t.get('function', {}).get('name')) for t in actual['tools']]
        assert len(messages) == 2 and [m['role'] for m in messages] == ['system', 'user']
        assert messages[0]['content'].endswith(guidance)
        assert tools == expected, tools
        spec = sampled[0]['event']['op']['model']
        assert spec['name'] == MODEL and spec['params']['max_tokens'] == OUTPUT
        assert spec['params']['temperature'] == 0
        initial_audit = audit_initial_events(log, manifest['root'], sampled[0]['entry'])
        write(self.root / 'request-audit.json', {'passed': True, 'first_sample_entry': sampled[0]['entry'],
                                               'roles': ['system', 'user'], 'tools': tools,
                                               **initial_audit,
                                               'guidance_sha256': digest(self.root / 'guidance.md')})

    def advance(self):
        state = self.state()
        if state['status'] not in ('prepared', 'replied', 'operational_interruption'):
            raise RuntimeError(f'cannot sample from {state["status"]}')
        if digest(self.binary) != read(self.root / 'manifest.json')['binary_sha256']:
            raise RuntimeError('binary changed since root')
        env = self.model_env()
        remaining = SAMPLES - state['samples']
        if remaining <= 0:
            raise RuntimeError('sample budget exhausted')
        segment = state['segment'] + 1
        label = f'segment-{segment:03d}'
        self.save({**state, 'status': 'running', 'segment': segment, 'started': utc()})
        began = time.monotonic()
        try:
            result = self.last(label, 'resume', state['entry'], '--provider', PROVIDER,
                '--samples', remaining, '--time-budget', SECONDS, allowed=(0, 1, 3, 4), env=env)
        except Exception:
            emitted = rows(self.root / f'{label}.jsonl')
            last = next((r['entry'] for r in reversed(emitted) if 'entry' in r), state['entry'])
            log = self.cmd(f'{label}-error-log', 'log', last)
            self.save({**state, 'entry': last, 'status': 'operational_interruption', 'segment': segment,
                       'samples': len(samples(log)), 'finished': utc()})
            raise
        log = self.cmd(f'{label}-log', 'log', result['entry'])
        view = self.last(f'{label}-show', 'show', result['entry'], '--request')
        state.update(entry=result['entry'], status=result['status'], segment=segment,
                     samples=len(samples(log)), result=result, finished=utc(),
                     run_time_ms=view.get('run_time_ms'), segment_wall_seconds=time.monotonic() - began)
        self.save(state)
        self.audit_request(log)
        if result['status'] == 'waits':
            self.cmd(f'question-{state["replies"] + 1:03d}', 'waiting')
        print(json.dumps({k: state[k] for k in ('status', 'samples', 'run_time_ms', 'entry')}), flush=True)

    def reply(self):
        state = self.state()
        if state['status'] != 'waits':
            raise RuntimeError('run is not waiting for a question')
        index = state['replies'] + 1
        answer = self.a.answer.read_text()
        provenance = read(self.a.provenance)
        if provenance.get('author_type') != 'assistant_proxy':
            raise RuntimeError('this study requires attributed assistant-proxy answers')
        if not all(provenance.get(k) for k in ('public_context', 'validation', 'limitations')):
            raise RuntimeError('answer provenance incomplete')
        shutil.copyfile(self.a.answer, self.root / f'answer-{index:03d}.txt')
        write(self.root / f'answer-{index:03d}-provenance.json', {**provenance, 'recorded': utc(),
            'question_entry': state['entry'], 'answer_sha256': digest(self.a.answer)})
        response = self.last(f'reply-{index:03d}', 'reply', state['entry'], answer)
        self.save({**state, 'entry': response['entry'], 'status': 'replied', 'replies': index})
        print(json.dumps({'status': 'replied', 'replies': index}))

    def grade(self):
        state = self.state()
        if state['status'] == 'waits' and (state.get('run_time_ms', 0) >= SECONDS * 1000 or state['samples'] >= SAMPLES):
            state['status'] = 'paused'
        if state['status'] not in ('done', 'failed', 'paused'):
            raise RuntimeError('agent must be terminal or budget-paused before grading')
        tip = state['entry']
        if state['status'] == 'paused':
            tip = self.last('terminal-stop', 'stop', tip, '--reason', 'frozen study budget ended')['entry']
        manifest = read(self.root / 'manifest.json')
        called = self.last('grade-call', 'call', tip, 'grader', '--image', manifest['grader_image_id'],
            '--set', 'command=python /opt/alaya-vero/grade.py --mode codeproof --benchmark /grader')['entry']
        result = self.last('grade', 'resume', called, allowed=(0, 1, 2))
        self.save({**state, 'agent_terminal': tip, 'grade': result, 'graded': utc()})
        print(json.dumps(result, ensure_ascii=False), flush=True)

    def probe(self):
        if self.root.exists():
            raise RuntimeError('probe root must be absent')
        source = self.root / 'source'
        source.mkdir(parents=True)
        (source / 'fixture.txt').write_text('Offline lifecycle fixture.\n')
        root = self.last('new', 'new', source)['entry']
        call = self.last('call', 'call', root, 'help-probe', '--image', AGENT_IMAGE)['entry']
        waiting = self.last('wait', 'resume', call, allowed=(3,))
        if waiting['status'] != 'waits':
            raise RuntimeError('probe did not wait')
        reply = self.last('reply', 'reply', waiting['entry'], 'probe-ok')['entry']
        end = self.last('continued', 'resume', reply)
        if end.get('value', {}).get('status') != 'ProbeComplete':
            raise RuntimeError('probe continuation wrong')
        # Independent grader consumes a file written only after the question was answered.
        call = self.last('grade-call', 'call', end['entry'], 'grader', '--image', AGENT_IMAGE,
            '--set', "command=test \"$(cat probe-reply.txt)\" = probe-ok && printf '1..1\\nok 1 - reply persisted\\n'")['entry']
        grade = self.last('grade', 'resume', call)
        if grade.get('value', {}).get('status') != 'pass':
            raise RuntimeError('probe grader failed')
        write(self.root / 'acceptance.json', {'fixture': True, 'model_calls': 0, 'question_reply_continue_grade': True,
                                               'grade': grade, 'completed': utc()})
        print('Offline ask/reply/continue/grade probe passed.')

def main():
    p = argparse.ArgumentParser()
    p.add_argument('action', choices=['seed', 'advance', 'reply', 'grade', 'probe'])
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--task-root', type=Path)
    p.add_argument('--arm', choices=['solo', 'help'])
    p.add_argument('--guidance', type=Path)
    p.add_argument('--credential-file', type=Path)
    p.add_argument('--answer', type=Path)
    p.add_argument('--provenance', type=Path)
    a = p.parse_args()
    getattr(Run(a), a.action)()

if __name__ == '__main__':
    main()
