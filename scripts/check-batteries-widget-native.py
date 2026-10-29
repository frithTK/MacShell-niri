#!/usr/bin/env python3
"""Check Batteries in niri with existing controllers and isolated device inputs."""
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

with tempfile.TemporaryDirectory(prefix='macshell-batteries-widget-') as directory:
    root = Path(directory)
    shell = root / 'shell'
    shutil.copytree(project / 'MacShell', shell)
    path = shell / 'shell.qml'
    source = path.read_text().replace('import QtQuick\n', 'import QtQuick\nimport QtQuick.Window\nimport QtTest\n', 1)
    source = source.replace('ShellRoot {', 'ShellRoot {\n' + (project / 'tests/batteries-widget-native.qml').read_text(), 1)
    path.write_text(source)
    (shell / 'BatteryControl.qml').write_text('''import QtQuick
import "BatteryState.js" as State
QtObject {
    property bool present: true
    property bool testReady: true
    property real fraction: 0
    readonly property real percentage: Math.round(fraction * 100)
    property bool charging: false
    property bool full: false
    property bool onBattery: true
    property string remaining: ""
    property string source: "Power Source: Battery"
    readonly property var widgetData: ({present: present, ready: testReady,
        percentage: State.chargePercentage(present, testReady, fraction), charging: charging, full: full, remaining: remaining})
}
''')
    path = shell / 'BluetoothControl.qml'
    source = path.read_text().replace('enabled: root.active', 'enabled: false')
    # Any accidental discovery attempt fails immediately. No system bus is used.
    old = 'function discover() { error = ""; service.send(discovering ? "stopDiscovery" : "discover"); }'
    assert old in source
    source = source.replace(old, 'function discover() { throw new Error("Batteries must not start discovery"); }')
    path.write_text(source)
    for name in ('cache', 'config', 'settings/macbar', 'settings/macdock'):
        (root / name).mkdir(parents=True)
    (root / 'settings/macbar/settings.json').write_text(json.dumps(dict(barEnabled=False, spotlightEnabled=False,
        ccEnabled=False, notificationsEnabled=False, clipHistory=False, autoContrast=False, barGlass=False, statsMetrics=[])))
    (root / 'settings/macdock/settings.json').write_text(json.dumps(dict(dockEnabled=False, windowCapture=False)))
    environment = dict(os.environ, QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic',
        XDG_CACHE_HOME=str(root / 'cache'), XDG_CONFIG_HOME=str(root / 'config'), MACSHELL_SETTINGS_HOME=str(root / 'settings'),
        NIRI_SOCKET=str(root / 'no-session'), DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'), DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
    result = subprocess.run([quickshell(), '-p', str(shell)], env=environment, capture_output=True, text=True, timeout=60)
    log = result.stdout + result.stderr
    Path('/tmp/macshell-batteries-widget-native.log').write_text(log)
    for line in log.splitlines():
        if any(word in line for word in ('ERROR', 'TypeError', 'ReferenceError', 'Binding loop', 'BATTERIES_WIDGET')):
            print(line)
    if result.returncode or 'MACSHELL_BATTERIES_WIDGET_PASS' not in log or re.search(r'TypeError|ReferenceError|Binding loop|Unable to assign', log):
        raise SystemExit(result.returncode or 1)
    values = json.loads((root / 'settings/macwidgets/settings.json').read_text())['values']
    assert len(values['widgets']) == 3 and values['enabled'] is False
    assert values['widgets'][0]['settings']['batteries']['devices'] == ['laptop']
    assert values['widgets'][0]['settings']['batteries']['future']['keep'] is False
    print('Device inputs and settings were isolated; no discovery or hardware change was permitted.')
