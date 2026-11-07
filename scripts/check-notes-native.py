#!/usr/bin/env python3
"""Exercise Notes in an isolated nested niri with disposable user data."""
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
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.install_niri import quickshell


def child(directory, parent_display, parent_socket):
    display, address = os.environ.get('WAYLAND_DISPLAY'), os.environ.get('NIRI_SOCKET')
    if not display or display == parent_display or not address or address == parent_socket:
        raise RuntimeError('Refusing to test a non-isolated compositor')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.connect(address)
        pid, uid, _ = struct.unpack('3i', conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    token = ('MACSHELL_NESTED_TEST_TOKEN=' + os.environ['MACSHELL_NESTED_TEST_TOKEN']).encode()
    if uid != os.getuid() or token not in Path('/proc', str(pid), 'environ').read_bytes().split(b'\0'):
        raise RuntimeError('Nested niri socket does not belong to the test compositor')
    root = Path(directory)
    shell = root / 'shell'
    shutil.copytree(ROOT / 'MacShell', shell)
    path = shell / 'shell.qml'
    source = path.read_text().replace('import QtQuick\n', 'import QtQuick\nimport QtQuick.Window\nimport QtTest\n', 1)
    path.write_text(source.replace('ShellRoot {', 'ShellRoot {\n' + (ROOT / 'tests/notes-native.qml').read_text(), 1))
    for name in ('home', 'cache', 'config', 'data', 'settings/macbar', 'settings/macdock'):
        (root / name).mkdir(parents=True)
    (root / 'settings/macbar/settings.json').write_text(json.dumps(dict(barEnabled=False, spotlightEnabled=False,
        ccEnabled=False, notificationsEnabled=False, clipHistory=False, autoContrast=False, barGlass=False, statsMetrics=[])))
    (root / 'settings/macdock/settings.json').write_text(json.dumps(dict(dockEnabled=False, windowCapture=False)))
    env = dict(os.environ, HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'config'),
        XDG_CACHE_HOME=str(root / 'cache'), XDG_DATA_HOME=str(root / 'data'), MACSHELL_NOTES_DATA_HOME=str(root / 'data'),
        MACSHELL_SETTINGS_HOME=str(root / 'settings'), QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='',
        QT_QUICK_CONTROLS_STYLE='Basic', DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
        DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'), NIRI_SOCKET=str(root / 'no-session'))
    try:
        result = subprocess.run([quickshell(), '-p', str(shell)], env=env, capture_output=True, text=True, timeout=45)
        log = result.stdout + result.stderr
        Path('/tmp/macshell-notes-native.log').write_text(log)
        if result.returncode or 'MACSHELL_NOTES_PASS' not in log or re.search(r'TypeError|ReferenceError|Binding loop|Unable to assign', log):
            raise RuntimeError(log[-10000:])
    finally:
        subprocess.run(['niri', 'msg', 'action', 'quit', '--skip-confirmation'], capture_output=True, timeout=8)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--child':
        root = Path(sys.argv[2])
        try: child(*sys.argv[2:])
        except Exception as error:
            (root / 'result').write_text('ERROR: ' + repr(error)); raise
        else: (root / 'result').write_text('PASS')
        return
    if not os.environ.get('WAYLAND_DISPLAY') or not os.environ.get('NIRI_SOCKET'):
        raise RuntimeError('A parent Wayland/niri session is required')
    with tempfile.TemporaryDirectory(prefix='macshell-notes-nested-') as directory:
        root = Path(directory)
        config = root / 'niri.kdl'; config.write_text('hotkey-overlay { skip-at-startup; }\nwindow-rule {\n    match title="^Notes$"\n    open-floating true\n}\n')
        command = ['niri', '-c', str(config), '--', sys.executable, str(Path(__file__).resolve()), '--child', directory,
                   os.environ['WAYLAND_DISPLAY'], os.environ['NIRI_SOCKET']]
        with (root / 'niri.log').open('w') as output:
            process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                env=dict(os.environ, MACSHELL_NESTED_TEST_TOKEN=uuid.uuid4().hex))
            try:
                deadline = time.monotonic() + 60
                result = root / 'result'
                while time.monotonic() < deadline and not result.exists() and process.poll() is None: time.sleep(.1)
                if not result.exists() or result.read_text() != 'PASS':
                    raise RuntimeError((result.read_text() if result.exists() else 'no result') + '\n' + (root / 'niri.log').read_text()[-8000:])
                print('MACSHELL_NOTES_NATIVE_PASS: isolated niri, editor, persistence, search and delete/undo')
            finally:
                if process.poll() is None: process.terminate()
                process.wait(timeout=5)


if __name__ == '__main__': main()
