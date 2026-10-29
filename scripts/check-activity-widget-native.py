#!/usr/bin/env python3
"""Exercise desktop Activity against the real shared sampler and shell."""
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

with tempfile.TemporaryDirectory(prefix='macshell-activity-widget-') as directory:
    root = Path(directory)
    shell = root / 'shell'
    shutil.copytree(project / 'MacShell', shell)
    path = shell / 'shell.qml'
    source = path.read_text().replace('import QtQuick\n', 'import QtQuick\nimport QtQuick.Window\nimport QtTest\n', 1)
    source = source.replace('ShellRoot {', 'ShellRoot {\n' + (project / 'tests/activity-widget-integration.qml').read_text(), 1)
    path.write_text(source)
    path = shell / 'SystemStats.qml'
    source = path.read_text().replace('    id: root\n', '    id: root\n    readonly property int testProcessId: service.testProcessId\n', 1)
    path.write_text(source)
    path = shell / 'JsonService.qml'
    source = path.read_text().replace('    id: root\n', '    id: root\n    readonly property int testProcessId: process.running ? process.processId : 0\n', 1)
    path.write_text(source)
    for name in ('cache', 'config', 'runtime', 'settings/macbar', 'settings/macdock'):
        (root / name).mkdir(parents=True)
    (root / 'runtime').chmod(0o700)
    (root / 'settings/macbar/settings.json').write_text(json.dumps(dict(barEnabled=False, spotlightEnabled=False,
        ccEnabled=False, notificationsEnabled=False, clipHistory=False, autoContrast=False, barGlass=False, statsMetrics=[])))
    (root / 'settings/macdock/settings.json').write_text(json.dumps(dict(dockEnabled=False, windowCapture=False)))
    environment = dict(os.environ, QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='',
        QT_QUICK_CONTROLS_STYLE='Basic', XDG_CACHE_HOME=str(root / 'cache'), XDG_CONFIG_HOME=str(root / 'config'),
        MACSHELL_SETTINGS_HOME=str(root / 'settings'), NIRI_SOCKET=str(root / 'no-session'),
        DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'), DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
    result = subprocess.run([quickshell(), '-p', str(shell)], env=environment, capture_output=True, text=True, timeout=55)
    log = result.stdout + result.stderr
    Path('/tmp/macshell-activity-widget-native.log').write_text(log)
    for line in log.splitlines():
        if any(word in line for word in ('ERROR', 'TypeError', 'ReferenceError', 'Binding loop', 'ACTIVITY_WIDGET')):
            print(line)
    if result.returncode or 'MACSHELL_ACTIVITY_WIDGET_PASS' not in log or re.search(r'TypeError|ReferenceError|Binding loop|Unable to assign', log):
        raise SystemExit(result.returncode or 1)
    values = json.loads((root / 'settings/macwidgets/settings.json').read_text())['values']
    assert len(values['widgets']) == 3 and values['enabled'] is False
    assert values['widgets'][0]['settings']['activity']['future']['keep'] is False
    print('User settings and devices were isolated; the shell used one real /proc sampler.')
