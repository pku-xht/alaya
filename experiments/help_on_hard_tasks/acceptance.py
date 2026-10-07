#!/usr/bin/env python3
"""Independent tiny Vero accept/reject checks; no model calls."""
import argparse
from pathlib import Path
import re
import shutil
from types import SimpleNamespace
from run import Run, write

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--task-root', type=Path, required=True)
    args = parser.parse_args()
    if args.root.exists():
        raise RuntimeError('acceptance root must be absent')
    summary = []
    for variant in ['blank', 'solved']:
        root = args.root / variant
        source = root / 'source'
        shutil.copytree(args.task_root / 'source', source)
        if variant == 'solved':
            edits = [('TinyTrivial/Impl/Core.lean', 'code def=idNat', '  fun n => n'),
                     ('TinyTrivial/Proof/Core.lean', 'proof def=prove_idNat kind=prove target=spec_idNat', '  intro n\n  rfl')]
            for name, tag, body in edits:
                path = source / name
                pattern = r'(-- !benchmark @start ' + re.escape(tag) + r'\n).*?(\n-- !benchmark @end)'
                changed, count = re.subn(pattern, lambda m: m[1] + body + m[2], path.read_text(), count=1, flags=re.S)
                if count != 1:
                    raise RuntimeError('tiny fixture marker changed')
                path.write_text(changed)
        runner = Run(SimpleNamespace(root=root, binary=args.binary))
        entry = runner.last('new', 'new', source)['entry']
        called = runner.last('grade-call', 'call', entry, 'grader', '--image', 'alaya-help-hard-tiny_trivial:20261007',
            '--set', 'command=python /opt/alaya-vero/grade.py --mode codeproof --benchmark /grader')['entry']
        result = runner.last('grade', 'resume', called, allowed=(0, 1, 2))
        expected = 'pass' if variant == 'solved' else 'fail'
        if result['value']['status'] != expected or result['value']['total'] != 1:
            raise RuntimeError(f'tiny {variant}: unexpected verdict')
        summary.append({'variant': variant, 'expected': expected, 'result': result})
    write(args.root / 'acceptance.json', summary)
    print('Tiny Vero blank rejected (0/1); local identity implementation/proof accepted (1/1).')

if __name__ == '__main__':
    main()
