#!/usr/bin/env python3
"""Synthetic Cargo producing executable protocol fixtures for installer tests."""
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
manifest = Path(args[args.index('--manifest-path') + 1])
target = Path(args[args.index('--target-dir') + 1])
crate = manifest.parent.name
with open(os.environ['FAKE_CARGO_LOG'], 'a') as log:
    log.write(json.dumps({'crate': crate, 'args': args, 'currency': os.environ.get('MACSHELL_CURRENCY_TEST_API'), 'widget': os.environ.get('MACSHELL_WIDGET_TEST_API')}) + '\n')
if os.environ.get('FAKE_CARGO_FAIL') == crate:
    sys.exit(1)
bins = [args[i + 1] for i, arg in enumerate(args) if arg == '--bin']
if not bins:
    bins = {'biometric-probe': ['macshell-biometric-probe', 'fingerprint-operation']}.get(crate, ['macshell-' + crate])
target = target / 'release'; target.mkdir(parents=True, exist_ok=True)
for binary in bins:
    if os.environ.get('FAKE_CARGO_MISSING') == binary: continue
    protocol = {'macshell-capture-experimental': 'macshell-capture 1', 'macshell-recording-experimental': 'macshell-recording 1', 'fingerprint-operation': 'macshell-fingerprint-operation 1', 'clock-service-prototype': 'macshell-clock-service 1', 'clock-sound-import': 'macshell-clock-import 1'}.get(binary, binary + ' 1')
    if os.environ.get('FAKE_CARGO_BAD_PROTOCOL') == binary: protocol = 'wrong 1'
    script = '#!/bin/sh\ncase "$1" in --ready-protocol-version) echo "macshell-session-ready 1";; --supervisor-protocol-version) echo "macshell-shell-supervisor 1";; *) echo "' + protocol + '";; esac\n'
    path = target / binary; path.write_text(script); path.chmod(0o755)
