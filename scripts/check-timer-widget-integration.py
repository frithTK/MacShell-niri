#!/usr/bin/env python3
"""Exercise two timer widgets and Clock in a verified isolated niri compositor."""
import json
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project))
from scripts.install_niri import quickshell

token = os.environ.get('MACSHELL_NESTED_TEST_TOKEN')
address = os.environ.get('NIRI_SOCKET')
if not token or not address:
    raise SystemExit('This test requires a dedicated nested niri session.')
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
    connection.connect(address)
    pid, uid, _ = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
if uid != os.getuid() or ('MACSHELL_NESTED_TEST_TOKEN=' + token).encode() not in Path('/proc', str(pid), 'environ').read_bytes().split(b'\0'):
    raise SystemExit('Refusing to run outside the isolated test compositor.')

with tempfile.TemporaryDirectory(prefix='macshell-timer-widget-') as directory:
    root = Path(directory)
    shell = root / 'shell'
    shutil.copytree(project / 'MacShell', shell)
    if os.environ.get('MACSHELL_CLOCK_TEST_RUST') == '1':
        for name in ('clock-service-prototype', 'clock-audio-worker', 'clock-sound-import'):
            shutil.copy2(project / 'native/clock-core/target/debug' / name, shell / (name + '-rust'))
        (shell / 'clock_service.py').write_text('raise SystemExit("unexpected Python Clock fallback")\n')
    path = shell / 'shell.qml'
    source = path.read_text().replace('import QtQuick\n', 'import QtQuick\nimport QtQuick.Window\nimport QtTest\n', 1)
    source = source.replace('ShellRoot {', 'ShellRoot {\n' + (project / 'tests/timer-widget-integration.qml').read_text(), 1)
    path.write_text(source)
    for name in ('cache', 'config', 'home', 'settings/macbar', 'settings/macdock'):
        (root / name).mkdir(parents=True)
    (root / 'settings/macbar/settings.json').write_text(json.dumps(dict(barEnabled=False, spotlightEnabled=False,
        ccEnabled=False, notificationsEnabled=False, clipHistory=False, autoContrast=False, barGlass=False, statsMetrics=[])))
    (root / 'settings/macdock/settings.json').write_text(json.dumps(dict(dockEnabled=False, windowCapture=False)))
    environment = dict(os.environ, HOME=str(root / 'home'), QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='',
        QT_QUICK_CONTROLS_STYLE='Basic', XDG_CACHE_HOME=str(root / 'cache'), XDG_CONFIG_HOME=str(root / 'config'),
        MACSHELL_SETTINGS_HOME=str(root / 'settings'), NIRI_SOCKET=str(root / 'no-session'),
        DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'), DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
    environment.pop('MACSHELL_CLOCK_SERVICE', None)
    result = subprocess.run([quickshell(), '-p', str(shell)], env=environment, capture_output=True, text=True, timeout=50)
    log = result.stdout + result.stderr
    Path('/tmp/macshell-timer-widget-native.log').write_text(log)
    if result.returncode or 'TIMER_WIDGET_NATIVE_PASS' not in log or re.search(r'TypeError|ReferenceError|Binding loop|Unable to assign', log):
        raise SystemExit('Timer widget integration failed:\n' + log[-10000:])
    document = json.loads((root / 'settings/macshell/clock.json').read_text())
    assert document['timing']['timer']['state'] == 'idle'
    print('TIMER_WIDGET_NATIVE_PASS: isolated shared Clock service, two desktop cards and single completion.')
