#!/usr/bin/env python3
"""Check live theme changes with the real shell and isolated settings/devices."""
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
parser.add_argument('--capture-dir', type=Path, default=Path('/tmp/macshell-theme-native-images'))
args = parser.parse_args()
args.capture_dir.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='macshell-theme-') as directory:
    root = Path(directory)
    shutil.copytree(project / 'MacShell', root / 'shell')
    path = root / 'shell/shell.qml'
    source = path.read_text().replace('import QtQuick\n', 'import QtQuick\nimport QtQuick.Window\nimport Quickshell.Wayland\nimport QtTest\n', 1)
    source = source.replace('ShellRoot {', 'ShellRoot {\n' + (project / 'tests/theme-native.qml').read_text(), 1)
    path.write_text(source)
    path = root / 'shell/MacBar.qml'
    source = path.read_text().replace('    id: root\n', '    id: root\n    property var testUi: null\n    property var testCc: null\n    property alias testPalette: pal\n    property var testBarPalette: null\n    property var testInk: null\n', 1)
    source = source.replace('                id: ui\n', '                id: ui\n                Component.onCompleted: { root.testUi = ui; root.testCc = cc; root.testBarPalette = screenPal; root.testInk = barInk; }\n', 1)
    source = source.replace('text: "Sound · " + Math.round(root.volume * 100) + "%" + (root.sink ? " · " + (root.sink.description || root.sink.name) : "")', 'text: "Sound · 50% · Speakers"')
    source = source.replace('readonly property real volume: (sink && sink.audio) ? sink.audio.volume : 0', 'readonly property real volume: .5')
    path.write_text(source)
    for name, window in [('MacDock.qml', 'prefsWindow'), ('ClockApp.qml', 'win')]:
        path = root / 'shell' / name
        source = path.read_text().replace('    id: root\n', '    id: root\n    function testWindow() { return ' + window + '; }\n', 1)
        if name == 'MacDock.qml':
            source = source.replace('source: "file://" + Quickshell.env("HOME") + "/.face"', 'source: ""')
            source = source.replace('property string userName: Quickshell.env("USER") || ""', 'property string userName: "Demo"')
            source = source.replace('if (text.trim() !== "") root.userName = text.trim()', 'root.userName = "Demo"')
        path.write_text(source)
    for name in ('cache', 'config', 'settings/macbar', 'settings/macdock'):
        (root / name).mkdir(parents=True)
    # Intentionally conflicting legacy files: Settings/Dock wins only once both load.
    (root / 'settings/macbar/settings.json').write_text(json.dumps(dict(darkMode=True, clipHistory=False, autoContrast=False, wallpaperAppearance='light')))
    (root / 'settings/macdock/settings.json').write_text(json.dumps(dict(darkMode=False, dockEnabled=False)))
    environment = dict(os.environ, QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic',
                       XDG_CACHE_HOME=str(root / 'cache'), XDG_CONFIG_HOME=str(root / 'config'), MACSHELL_SETTINGS_HOME=str(root / 'settings'),
                       NIRI_SOCKET=str(root / 'no-session'), DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
                       DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'), MACSHELL_THEME_CAPTURE=str(args.capture_dir.resolve()))
    result = subprocess.run([quickshell(), '-p', str(root / 'shell')], env=environment, capture_output=True, text=True, timeout=50)
    log = result.stdout + result.stderr
    Path('/tmp/macshell-theme-native.log').write_text(log)
    for line in log.splitlines():
        if any(word in line for word in ('ERROR', 'TypeError', 'ReferenceError', 'Binding loop', 'THEME_NATIVE')):
            print(line)
    if result.returncode or 'MACSHELL_THEME_NATIVE_PASS' not in log or re.search(r'TypeError|ReferenceError|Binding loop|Unable to assign', log):
        raise SystemExit(result.returncode or 1)
    for kind in ('macbar', 'macdock'):
        saved = json.loads((root / ('settings/' + kind + '/settings.json')).read_text())
        assert saved['darkMode'] is False, 'Theme not persisted in ' + kind
    print('Both settings files retained the final light theme; user settings and devices were isolated.')
