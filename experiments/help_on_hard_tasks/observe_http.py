#!/usr/bin/env python3
"""Read-only, best-effort HTTP status observer for this study's own curl children.

Never opens curl.conf, request.json, response.json, or /proc/*/environ. Only emits
HTTP status and Retry-After fields from response.headers. Does not alter requests,
retries or budgets. Observations can miss short-lived children; absence is not proof
that no throttling occurred. Linux /proc only.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import time

def header_metadata(text):
    """Keep only final status and typed retry values; never copy arbitrary headers."""
    statuses = re.findall(r'^HTTP/\S+\s+(\d{3})', text, re.M)
    retries = re.findall(r'^(retry-after(?:-ms)?):\s*(\d+)\s*$', text, re.M | re.I)
    return {
        'http_status': int(statuses[-1]) if statuses else None,
        'retry_after': [{'value': int(value), 'unit': 'milliseconds' if name.lower().endswith('-ms') else 'seconds'}
                        for name, value in retries],
    }

def command(pid):
    try:
        return Path(f'/proc/{pid}/cmdline').read_bytes().decode(errors='replace').rstrip('\0').split('\0')
    except (OSError, ValueError):
        return []

def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--study-root', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--seconds', type=int, default=7200)
    a = p.parse_args()
    study = a.study_root.resolve()
    deadline = time.monotonic() + a.seconds
    owned, children = {}, {}
    scan_at = 0.0
    a.output.parent.mkdir(parents=True, exist_ok=True)
    with a.output.open('x') as out:
        def emit(record):
            out.write(json.dumps({'observed_at': now(), **record}) + '\n')
            out.flush()
        emit({'type': 'coverage_start', 'best_effort': True, 'scope': str(study / 'runs')})
        try:
            while time.monotonic() < deadline:
                if time.monotonic() >= scan_at:
                    owned = {}
                    for path in Path('/proc').iterdir():
                        if not path.name.isdigit():
                            continue
                        args = command(path.name)
                        if not args or Path(args[0]).name != 'alaya' or '--data' not in args:
                            continue
                        data = Path(args[args.index('--data') + 1])
                        if data.name == 'data' and data.parent.parent == study / 'runs':
                            owned[path.name] = data.parent.name
                    scan_at = time.monotonic() + 1
                live = set()
                for pid, run in owned.items():
                    for task in Path(f'/proc/{pid}/task').glob('*'):
                        try:
                            direct = (task / 'children').read_text().split()
                        except OSError:
                            continue
                        for child in direct:
                            args = command(child)
                            if not args or Path(args[0]).name != 'curl' or '--dump-header' not in args:
                                continue
                            path = Path(args[args.index('--dump-header') + 1])
                            if path.name != 'response.headers' or Path('/tmp') not in path.parents:
                                continue
                            live.add(child)
                            if child not in children:
                                children[child] = {'run': run, 'path': path, 'fd': None, 'started': now()}
                            item = children[child]
                            if item['fd'] is None:
                                try:
                                    item['fd'] = os.open(path, os.O_RDONLY)
                                except OSError:
                                    pass
                for pid in list(children):
                    if pid in live:
                        continue
                    item = children.pop(pid)
                    text = ''
                    if item['fd'] is not None:
                        try:
                            text = os.pread(item['fd'], 65536, 0).decode(errors='replace')
                        finally:
                            os.close(item['fd'])
                    emit({'type': 'observed_request_end', 'run': item['run'], 'pid': int(pid),
                          'observed_start': item['started'], **header_metadata(text)})
                time.sleep(0.05 if owned else 0.5)
        finally:
            for item in children.values():
                if item['fd'] is not None:
                    os.close(item['fd'])
            emit({'type': 'coverage_end'})

if __name__ == '__main__':
    main()
