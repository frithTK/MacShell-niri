#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

state_path = Path(os.environ['NIRI_FAKE_STATE'])
log_path = Path(os.environ['NIRI_FAKE_LOG'])
args = sys.argv[1:]
log_path.parent.mkdir(parents=True, exist_ok=True)
with log_path.open('a') as log:
    log.write(' '.join(args) + '\n')

def load():
    return json.loads(state_path.read_text()) if state_path.exists() else {'outputs': {}, 'casts': []}

def save(state):
    state_path.write_text(json.dumps(state))

state = load()
if args[:2] == ['msg', '--help'] or args == ['--help']:
    if os.environ.get('NIRI_FAKE_VIRTUAL') == '1':
        print('create-virtual-output\nremove-virtual-output\noutputs')
    else:
        print('outputs\nwindows')
    sys.exit(0)
if args[:3] == ['msg', '--json', 'outputs']:
    print(json.dumps(state.get('outputs', {})))
    sys.exit(0)
if args[:3] == ['msg', '--json', 'casts']:
    print(json.dumps(state.get('casts', [])))
    sys.exit(0)
if args[:2] == ['msg', 'create-virtual-output']:
    name = 'HEADLESS-1'
    if '--name' in args:
        name = args[args.index('--name') + 1]
    elif len(args) >= 3 and not args[2].startswith('-'):
        name = args[2]
    outputs = state.setdefault('outputs', {})
    if outputs:
        right = max(item['logical']['x'] + item['logical']['width'] for item in outputs.values())
    else:
        right = 0
    outputs[name] = {'logical': {'x': right, 'y': 0, 'width': 1920, 'height': 1080}}
    save(state)
    sys.exit(0)
if args[:2] == ['msg', 'remove-virtual-output']:
    name = args[2] if len(args) > 2 and args[2] != '--name' else args[args.index('--name') + 1]
    state.setdefault('outputs', {}).pop(name, None)
    save(state)
    sys.exit(0)
if args[:2] == ['msg', 'output'] and len(args) >= 4 and args[3] == 'off':
    state.setdefault('outputs', {}).pop(args[2], None)
    save(state)
    sys.exit(0)
if args[:2] == ['msg', 'output'] and len(args) >= 4 and args[3] == 'on':
    name = args[2]
    outputs = state.setdefault('outputs', {})
    if name not in outputs:
        if outputs:
            right = max(item['logical']['x'] + item['logical']['width'] for item in outputs.values())
        else:
            right = 0
        outputs[name] = {'logical': {'x': right, 'y': 0, 'width': 1920, 'height': 1080}}
    save(state)
    sys.exit(0)
if args[:2] == ['msg', 'output'] and 'position' in args and 'set' in args:
    name = args[2]
    x = int(args[args.index('set') + 1])
    y = int(args[args.index('set') + 2])
    logical = state.setdefault('outputs', {}).setdefault(name, {}).setdefault('logical', {'width': 1920, 'height': 1080})
    logical['x'] = x
    logical['y'] = y
    save(state)
    sys.exit(0)
if args[:2] == ['msg', 'output'] and 'custom-mode' in args:
    sys.exit(0)
if args[:3] == ['msg', 'action', 'set-dynamic-cast-monitor']:
    sys.exit(0)
sys.exit(1)
