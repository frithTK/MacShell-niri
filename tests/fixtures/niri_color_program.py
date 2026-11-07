#!/usr/bin/env python3
"""Fake niri, wl-copy and notifications for the isolated color picker tests."""
import json
import os
from pathlib import Path
import sys
import time

root=Path(os.environ['COLOR_TEST_ROOT']); name=Path(sys.argv[0]).name
with (root/'events.jsonl').open('a') as output:
    output.write(json.dumps({'program':name,'args':sys.argv[1:]})+'\n')
if name=='niri':
    assert sys.argv[1:]==['msg','-j','pick-color']
    mode=os.environ.get('COLOR_TEST_MODE','ok')
    if mode=='fail': print('test failure',file=sys.stderr); sys.exit(1)
    if mode=='flood': sys.stdout.write('x'*100000); sys.stdout.flush(); time.sleep(20)
    if mode=='stderr-flood': sys.stderr.write('x'*100000); sys.stderr.flush(); time.sleep(20)
    if mode=='wait': (root/'picker.pid').write_text(str(os.getpid())); time.sleep(30)
    if mode=='slow': time.sleep(.3)
    sys.stdout.write(os.environ.get('COLOR_REPLY','null')); sys.stdout.flush()
elif name=='wl-copy' and os.environ.get('COLOR_COPY_FAIL')=='1':
    sys.exit(1)
