#!/usr/bin/env python3
"""Offline image derivation, pristine rendering, and full public-module audit."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

TASKS = ['primepy', 'munkres', 'pythonconstraint', 'greenery']
AGENT = 'alaya-human-help-agent:20261003'
GRADER = 'alaya-help-hard-grader:20261007'

def run(args, log: Path, **kwargs):
    log.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(list(map(str, args)), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kwargs)
    log.write_bytes(result.stdout)
    if result.returncode:
        raise RuntimeError(f'command failed ({result.returncode}); see {log}')
    return result.stdout.decode()

def tree_hash(root: Path):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob('*')) if p.is_file() and '.lake' not in p.parts and '.git' not in p.parts}

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--vero', type=Path, required=True)
    a = p.parse_args()
    a.root.mkdir(parents=True, exist_ok=True)
    dockerfile = a.root / 'Grader.Dockerfile'
    dockerfile.write_text('FROM alaya-human-help-grader:20261003\nCOPY benchmarks/vero/grade.py benchmarks/vero/render.py benchmarks/vero/prepare.py /opt/alaya-vero/\n')
    run(['docker', 'build', '--network', 'none', '-t', GRADER, '-f', dockerfile, a.source], a.root / 'image-build.log')
    results = []
    for task in ['tiny_trivial', *TASKS]:
        trusted = a.source / 'benchmarks/vero/tests/fixtures/tiny_trivial' if task == 'tiny_trivial' else a.vero / 'benchmarks' / task
        dest = a.root / 'tasks' / task
        dest.mkdir(parents=True, exist_ok=False)
        run(['docker', 'run', '--rm', '--network', 'none', '--user', f'{os.getuid()}:{os.getgid()}', '-e', 'HOME=/tmp',
             '-v', f'{trusted}:/benchmark:ro', '-v', f'{dest}:/rendered', GRADER, 'python', '/opt/alaya-vero/render.py',
             '--benchmark', '/benchmark', '--sandbox', '/rendered/source', '--mode', 'codeproof'], dest / 'render.log')
        run(['docker', 'run', '--rm', '--network', 'none', '--user', f'{os.getuid()}:{os.getgid()}', '-e', 'HOME=/tmp',
             '-v', f'{dest}/source:/workspace', AGENT, 'python3', '/opt/alaya-vero/prepare.py', '/workspace'], dest / 'prepare.log')
        task_grader = f'alaya-help-hard-{task}:20261007'
        run(['docker', 'build', '--network', 'none', '-t', task_grader, '-f', '-', trusted], dest / 'grader-build.log',
            input=f'FROM {GRADER}\nCOPY . /grader\n'.encode())
        # Audit on a separate copy; never include compiled caches in the sampled root.
        check = dest / 'public-check'
        shutil.copytree(dest / 'source', check, symlinks=True)
        targets = [str(p.relative_to(check).with_suffix('')).replace('/', '.')
                   for p in sorted(check.rglob('*.lean')) if '.lake' not in p.parts
                   and len(p.relative_to(check).parts) > 1 and p.name != 'Test.lean']
        result = subprocess.run(['docker', 'run', '--rm', '--network', 'none', '--user', f'{os.getuid()}:{os.getgid()}',
            '-e', 'HOME=/tmp', '-v', f'{check}:/workspace', '-w', '/workspace', AGENT, 'lake', 'build', *targets],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (dest / 'public-check.log').write_bytes(result.stdout)
        image_id = run(['docker', 'image', 'inspect', '--format', '{{.Id}}', task_grader], dest / 'image-id.log').strip()
        record = {'task': task, 'public_compilation_exit': result.returncode, 'grader_image': task_grader,
                  'structural_targets': targets,
                  'audit_note': 'Explicit Impl/Spec/Proof/Joint/Bundle/Harness modules. Blank executable Test fails on sorry implementations by design.',
                  'grader_image_id': image_id, 'public_source_sha256': tree_hash(dest / 'source'),
                  'task_sha256': hashlib.sha256((dest / 'MINIVERO_TASK.md').read_bytes()).hexdigest()}
        (dest / 'audit.json').write_text(json.dumps(record, indent=2) + '\n')
        results.append(record)
        print(json.dumps({k: record[k] for k in ('task', 'public_compilation_exit', 'grader_image_id')}), flush=True)
    (a.root / 'preflight.json').write_text(json.dumps(results, indent=2) + '\n')

if __name__ == '__main__':
    main()
