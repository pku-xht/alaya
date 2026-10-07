"""Aggregate only HTTP observer metadata; absence of 429 is not proof of no throttling."""
import argparse
from collections import Counter
import json
from pathlib import Path

def summarize(paths):
    requests, coverage = {}, []
    for path in paths:
        for line in path.read_text().splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            if row['type'].startswith('coverage_'):
                coverage.append({'file': path.name, **row})
            elif row['type'] == 'observed_request_end':
                # Observer replacement may overlap. Later files keep the typed retry fields.
                requests[row['run'], row['pid']] = row
    runs = []
    for run in sorted({key[0] for key in requests}):
        rows = sorted([row for key, row in requests.items() if key[0] == run], key=lambda r: r['observed_at'])
        counts = Counter(str(row['http_status']) for row in rows)
        failures = [row for row in rows if row['http_status'] == 429]
        runs.append({'run': run, 'observed_requests': len(rows), 'status_counts': dict(counts),
            'first_observed': rows[0]['observed_start'], 'last_observed': rows[-1]['observed_at'],
            'observed_429': len(failures), 'retry_headers': [
                {'observed_at': row['observed_at'], 'retry_after': row.get('retry_after'),
                 'legacy_untyped_values': row.get('retry_after_numeric')} for row in failures]})
    return {'best_effort': True, 'limitation': 'Partial observation; retry headers are requested delays, not an exact accounting of time lost.',
            'coverage': coverage, 'runs': runs}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('inputs', type=Path, nargs='+')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = summarize(args.inputs)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps([{key: run[key] for key in ('run', 'observed_requests', 'status_counts')} for run in result['runs']]))

if __name__ == '__main__':
    main()
