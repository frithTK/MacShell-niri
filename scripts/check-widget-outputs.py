#!/usr/bin/env python3
"""Exercise the real widget controller/writer with synthetic outputs, without surfaces."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project))
from scripts.install_niri import quickshell

with tempfile.TemporaryDirectory(prefix='macshell-widget-outputs-') as directory:
    root = Path(directory)
    shutil.copytree(project / 'MacShell', root / 'shell')
    shutil.copyfile(project / 'tests/widget-outputs.qml', root / 'shell/shell.qml')
    path = root / 'shell/MacWidgets.qml'
    source = path.read_text()
    # Synthetic QtObjects deliberately have no QScreen. Remove only the desktop
    # surface component from this temporary copy; controller and writer stay real.
    start = source.index('    // ───────────── the desktop layer')
    end = source.index('    IpcHandler {', start)
    if source[start:end].count('    Variants {') != 1:
        raise SystemExit('Update the surface isolation for the output controller fixture.')
    path.write_text(source[:start] + source[end:])
    for name in ('cache', 'config', 'runtime', 'settings/macwidgets'):
        (root / name).mkdir(parents=True)
    (root / 'runtime').chmod(0o700)
    values = dict(defaults=dict(tempUnit='C', locMode='auto', cityName='', mode='auto', styles={kind: 'liquid' for kind in ('weather', 'calendar', 'clock', 'player')}),
                  desktopOutput='main', outputs={key: dict(identity=dict(connector=name, serial=serial)) for key, name, serial in [('main', 'DP-1', 'one'), ('second', 'DP-2', 'two')]},
                  bindings={'DP-1': 'main', 'DP-2': 'second'}, widgets=[dict(id=key, type='clock', version=1, output=profile, position=dict(column=column, row=0), settings=dict(size='small', style='dark')) for key, profile, column in [('a', 'main', 8), ('b', 'second', 0)]])
    (root / 'settings/macwidgets/settings.json').write_text(json.dumps(dict(version=1, revision=1, values=values)))
    environment = {key: value for key, value in os.environ.items() if key not in ('DISPLAY', 'WAYLAND_DISPLAY')}
    environment.update(QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic',
                       XDG_CACHE_HOME=str(root / 'cache'), XDG_CONFIG_HOME=str(root / 'config'), XDG_RUNTIME_DIR=str(root / 'runtime'),
                       MACSHELL_SETTINGS_HOME=str(root / 'settings'), NIRI_SOCKET=str(root / 'no-session'),
                       DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'), DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
    result = subprocess.run([quickshell(), '-p', str(root / 'shell')], env=environment, capture_output=True, text=True, timeout=15)
    log = result.stdout + result.stderr
    Path('/tmp/macshell-widget-outputs.log').write_text(log)
    for line in log.splitlines():
        if any(word in line for word in ('ERROR', 'Error', 'FAIL', 'PASS', 'Binding loop')):
            print(line)
    if result.returncode or 'MACSHELL_WIDGET_OUTPUTS_PASS' not in log or re.search(r'TypeError|ReferenceError|Binding loop|Unable to assign|Failed to start IPC|Failed to load configuration', log):
        raise SystemExit(result.returncode or 1)
