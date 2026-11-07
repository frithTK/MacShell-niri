#!/usr/bin/env python3
"""Validate or deliberately perturb an isolated niri candidate."""
import os
from pathlib import Path
import sys
import time

assert sys.argv[1:3] == ['validate','-c']
candidate=Path(sys.argv[3]); profile=Path(os.environ['BLUR_TEST_PROFILE'])
assert candidate.parent == profile
text=candidate.read_text()
assert 'include "./user.kdl"' in text
assert '.macshell-blur-' in text
with (profile/'validator.log').open('a') as stream: stream.write('validate\n')
mode=os.environ.get('BLUR_TEST_MODE','ok')
if mode=='reject': sys.exit(1)
if mode=='hang':
    (profile/'validator.pid').write_text(str(os.getpid()))
    time.sleep(30)
if mode=='edit-config':
    with (profile/'config.kdl').open('a') as stream: stream.write('// external edit\n')
if mode=='edit-fragment': (profile/'macshell-blur.kdl').write_text('// external fragment\n')
if mode=='replace-socket':
    Path(os.environ['NIRI_SOCKET']).unlink()
    Path(os.environ['NIRI_SOCKET']).write_text('not a socket')
