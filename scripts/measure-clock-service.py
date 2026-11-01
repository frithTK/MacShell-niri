#!/usr/bin/env python3
"""Measure an isolated idle Clock service without touching user settings."""
import argparse
import json
from pathlib import Path
import runpy
import selectors
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=int, choices=range(1, 61), default=10, metavar='1..60')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    measure = runpy.run_path(str(ROOT / 'scripts/measure-shell.py'))['measure']
    with tempfile.TemporaryDirectory(prefix='macshell-clock-measure-') as directory:
        store = Path(directory) / 'macshell/clock.json'
        process = subprocess.Popen([sys.executable, '-u', str(ROOT / 'MacShell/clock_service.py'),
                                    '--store', str(store)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        try:
            if not selector.select(5):
                raise RuntimeError('Clock service did not start')
            message = json.loads(process.stdout.readline())
            if message.get('type') != 'ready':
                raise RuntimeError('Clock service failed: ' + str(message))
            result = measure(process.pid, args.seconds)
            result.update(scenario='idle-clock-service', clockFileCreated=store.exists())
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            selector.close()
            process.stdout.close()
            process.stderr.close()
    text = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text)
    print(text, end='')


if __name__ == '__main__':
    main()
