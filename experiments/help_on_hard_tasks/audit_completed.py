"""Re-audit completed runs without sampling or changing their trajectories."""
import argparse
import json
from pathlib import Path
import subprocess
import run

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runs', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    results = []
    for root in sorted(args.runs.iterdir()):
        if not (root/'state.json').exists() or not run.read(root/'state.json').get('grade'):
            continue
        runner = run.Run(argparse.Namespace(root=root, binary=args.binary))
        raw = subprocess.check_output([str(runner.binary), 'log', runner.state()['entry'],
                                       '--data', str(runner.data), '--json'])
        log = [json.loads(line) for line in raw.splitlines() if line.strip()]
        runner.audit_request(log)
        results.append({'run': root.name, 'passed': run.read(root/'request-audit.json')['passed']})
    print(json.dumps(results))

if __name__ == '__main__':
    main()
