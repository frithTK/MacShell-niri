#!/usr/bin/env python3
"""Fake niri validation or Quickshell runtime, confined to a temporary test root."""
import json
import os
from pathlib import Path
import sys
import time

root=Path(os.environ['PREFLIGHT_TEST_ROOT']); role=Path(sys.argv[0]).name
if role=='niri':
    assert sys.argv[1:3]==['validate','-c']
    (root/'niri-call.json').write_text(json.dumps(sys.argv[1:]))
    mode=os.environ.get('PREFLIGHT_NIRI_MODE','ok')
else:
    assert sys.argv[1]=='-p'; probe=Path(sys.argv[2]); runtime=Path(os.environ['XDG_RUNTIME_DIR'])
    (root/'qs-call.json').write_text(json.dumps({'args':sys.argv[1:],'probe':probe.read_text(),
        'runtime':str(runtime),'runtimeMode':runtime.stat().st_mode & 0o777,'cache':os.environ.get('XDG_CACHE_HOME'),
        'qpa':os.environ.get('QT_QPA_PLATFORM'),'theme':os.environ.get('QT_QPA_PLATFORMTHEME'),
        'style':os.environ.get('QT_QUICK_CONTROLS_STYLE'),'dbus':os.environ.get('DBUS_SESSION_BUS_ADDRESS'),
        'display':os.environ.get('DISPLAY'),'wayland':os.environ.get('WAYLAND_DISPLAY')}))
    mode=os.environ.get('PREFLIGHT_QS_MODE','ok')
if mode=='fail': print('probe failed',file=sys.stderr); sys.exit(1)
if mode=='mismatch': print('Qt updated without rebuilding',file=sys.stderr); sys.exit(0)
if mode=='loadfail': print('Failed to load configuration',file=sys.stdout); sys.exit(0)
if mode=='invalid-utf8': sys.stdout.buffer.write(b'\xff'); sys.stdout.flush(); sys.exit(0)
if mode=='flood': sys.stdout.write('x'*(1100000)); sys.stdout.flush(); time.sleep(30)
if mode=='hang':
    child=os.fork()
    if child==0:
        (root/'child.pid').write_text(str(os.getpid())); time.sleep(30); os._exit(0)
    (root/'parent.pid').write_text(str(os.getpid())); time.sleep(30)
