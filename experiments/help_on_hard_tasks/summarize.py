#!/usr/bin/env python3
"""Export reviewed aggregate evidence, excluding raw requests and model reasoning."""
import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess

def load(path):
    return json.loads(path.read_text())

def summarize(binary, root):
    state = load(root / 'state.json')
    manifest = load(root / 'manifest.json')
    tip = state['entry']
    result = subprocess.run([str(binary), 'log', tip, '--data', str(root / 'data'), '--json'],
                            capture_output=True, check=True)
    rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    count = Counter()
    events = []
    clock = 0
    lengths = 0
    responses = 0
    failed_samples = 0
    questions = []
    executed_commands = 0
    execution_errors = 0
    time_checks = 0
    external_before_first = []
    initial_workspace_event = None
    for row_index, row in enumerate(rows):
        clock += row.get('elapsed_ms', 0)
        event = row.get('event', {})
        if responses == 0 and event.get('type') == 'arrived':
            kind = event.get('notice', {}).get('type')
            if kind in ('said', 'changed', 'replied'):
                if kind == 'changed' and row_index == 0 and row.get('position') == 0:
                    initial_workspace_event = row['entry']
                else:
                    external_before_first.append(kind)
        if event.get('type') == 'answered' and event.get('op', {}).get('type') == 'exec' and event.get('frame', [''])[-1].split('#')[0] == 'bash':
            if event.get('answer') is not None:
                executed_commands += 1
            else:
                execution_errors += 1
        if event.get('op', {}).get('type') == 'time':
            time_checks += 1
        if event.get('type') == 'asked':
            questions.append({'entry': row['entry'], 'seconds': round(clock / 1000, 3),
                              'question_type': event['question']['form']['type']})
        if event.get('type') == 'answered' and event.get('op', {}).get('type') == 'sample' and event.get('answer') is None:
            failed_samples += 1
        if event.get('op', {}).get('type') == 'sample' and event.get('answer') is not None:
            responses += 1
            response = event['answer']
            lengths += response.get('finish_reason') == 'length'
            for call in response.get('tool_calls', []):
                count[call['name']] += 1
                events.append({'entry': row['entry'], 'seconds': round(clock / 1000, 3), 'tool': call['name']})
    provenance = []
    for path in sorted(root.glob('answer-*-provenance.json')):
        item = load(path)
        provenance.append({k: item.get(k) for k in ['author_type', 'answer_begin', 'recorded', 'answer_sha256']})
    grade = state.get('grade', {}).get('value', {})
    audit_path = root / 'request-audit.json'
    return {'run': root.name, 'task': manifest['task'], 'arm': manifest['arm'], 'status': state['status'],
        'samples': responses, 'run_time_seconds': round(clock / 1000, 3), 'tool_requests': dict(count),
        'failed_sample_effects': failed_samples,
        'termination_result': {'status': state.get('result', {}).get('value', {}).get('status'),
                               'stop_reason': state.get('stop_reason')},
        'executed_bash_commands': executed_commands, 'actual_time_checks': time_checks,
        'bash_effect_errors': execution_errors,
        'external_notices_before_first_sample': external_before_first,
        'initial_workspace_event': initial_workspace_event,
        'questions': questions, 'proxy_answers': provenance, 'human_answers': 0,
        'length_truncated_responses': lengths, 'grader_status': grade.get('status'),
        'passed': grade.get('passed'), 'total': grade.get('total'),
        'initial_request_audited': load(audit_path)['passed'] if audit_path.exists() else False,
        'guidance_sha256': manifest['guidance_sha256'], 'binary_sha256': manifest['binary_sha256'],
        'agent_terminal': state.get('agent_terminal', tip), 'grader_terminal': state.get('grade', {}).get('entry'),
        'deviation': manifest.get('deviation'), 'tool_timeline': events}

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--runs', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    records = [summarize(a.binary, r) for r in sorted(a.runs.iterdir())
               if (r / 'state.json').exists() and (r / 'manifest.json').exists()
               and load(r / 'state.json').get('grade')]
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(json.dumps(records, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps([{k: r[k] for k in ['run', 'status', 'passed', 'total', 'samples', 'run_time_seconds',
                                      'tool_requests', 'questions', 'length_truncated_responses']} for r in records], ensure_ascii=False))

if __name__ == '__main__':
    main()
