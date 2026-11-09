#!/usr/bin/env python3
"""Exercise utility discovery, Calculator and Clock windows in an isolated niri shell."""
import argparse
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

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--capture', type=Path, help='Save six window screenshots to this directory')
args = parser.parse_args()
if args.capture:
    args.capture.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix='macshell-calculator-') as directory:
    root = Path(directory)
    shell = root / 'shell'
    shutil.copytree(project / 'MacShell', shell)
    if os.environ.get('MACSHELL_CLOCK_TEST_RUST') == '1':
        for name in ('clock-service-prototype', 'clock-audio-worker', 'clock-sound-import'):
            shutil.copy2(project / 'native/clock-core/target/debug' / name, shell / (name + '-rust'))
        (shell / 'clock_service.py').write_text('raise SystemExit("unexpected Python Clock fallback")\n')
    path = shell / 'shell.qml'
    source = path.read_text().replace('import QtQuick\n', 'import QtQuick\nimport QtQuick.Window\nimport QtTest\n', 1)
    source = source.replace('ShellRoot {', 'ShellRoot {\n' + (project / 'tests/calculator-native.qml').read_text(), 1)
    path.write_text(source)
    path = shell / 'ClockApp.qml'
    source = path.read_text().replace('function open(tabName) {', 'function testWindow() { return win; }\n    function open(tabName) {', 1)
    path.write_text(source)
    for name in ('cache', 'config', 'settings/macbar', 'settings/macdock'):
        (root / name).mkdir(parents=True)
    (root / 'settings/macbar/settings.json').write_text(json.dumps(dict(barEnabled=False, spotlightEnabled=False,
        ccEnabled=False, notificationsEnabled=False, clipHistory=False, autoContrast=False, barGlass=False, statsMetrics=[])))
    (root / 'settings/macdock/settings.json').write_text(json.dumps(dict(dockEnabled=False, windowCapture=False)))
    environment = dict(os.environ, QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic',
        XDG_CACHE_HOME=str(root / 'cache'), XDG_CONFIG_HOME=str(root / 'config'), MACSHELL_SETTINGS_HOME=str(root / 'settings'),
        NIRI_SOCKET=str(root / 'no-session'), DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
        DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
        MACSHELL_CALCULATOR_CAPTURE=str(args.capture.resolve()) if args.capture else '')
    result = subprocess.run([quickshell(), '-p', str(shell)], env=environment, capture_output=True, text=True, timeout=50)
    log = result.stdout + result.stderr
    Path('/tmp/macshell-calculator-native.log').write_text(log)
    for line in log.splitlines():
        if any(word in line for word in ('ERROR', 'TypeError', 'ReferenceError', 'Binding loop', 'CALCULATOR_')):
            print(line)
    if result.returncode or 'MACSHELL_CALCULATOR_PASS' not in log or re.search(r'TypeError|ReferenceError|Binding loop|Unable to assign', log):
        raise SystemExit(result.returncode or 1)
    clock_file = root / 'settings/macshell/clock.json'
    assert not clock_file.exists(), 'Opening Clock must not start or save a timer'
    if args.capture:
        assert len(list(args.capture.glob('calculator-*.png'))) == 6
    print('Preferences and service inputs were isolated; no timer, alarm, recording or hardware action was started.')
