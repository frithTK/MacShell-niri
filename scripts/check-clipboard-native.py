#!/usr/bin/env python3
"""Exercise clipboard tools on a nested compositor with disposable history."""
import base64
import json
import os
from pathlib import Path
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
    env = dict(os.environ, XDG_CACHE_HOME=str(root / 'cache'), XDG_CONFIG_HOME=str(root / 'config'))
    for name in ('cache', 'config'):
        (root / name).mkdir()
    watchers = [subprocess.Popen(['wl-paste', '--type', kind, '--watch', 'cliphist', 'store'], env=env,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                for kind in ('text', 'image')]
    def command(*args, input=None):
        return subprocess.run(args, input=input, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              check=True, timeout=5).stdout
    def copy(kind, data):
        # wl-copy's background owner inherits its output descriptors.
        subprocess.run(['wl-copy', '--type', kind], input=data, env=env, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=True, timeout=5)
    def wait_for(needle):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            entries = command('cliphist', 'list').splitlines()
            for line in entries:
                if needle in line:
                    return line
            time.sleep(.1)
        raise RuntimeError('Clipboard entry not stored in isolated history')
    try:
        time.sleep(.4)
        original = 'MacShell clipboard test 🌿\nsecond line'.encode()
        copy('text/plain;charset=utf-8', original)
        entry = wait_for(b'MacShell clipboard test')
        identifier = entry.split(b'\t', 1)[0].decode()
        if command('cliphist', 'decode', identifier) != original:
            raise RuntimeError('Clipboard text did not round-trip')
        png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a2G8AAAAASUVORK5CYII=')
        copy('image/png', png)
        image_entry = wait_for(b'[[ binary data')
        image_id = image_entry.split(b'\t', 1)[0].decode()
        if command('cliphist', 'decode', image_id) != png:
            raise RuntimeError('Clipboard image did not round-trip')
        command('cliphist', 'delete', input=entry + b'\n')
        if any(line.startswith(identifier.encode() + b'\t') for line in command('cliphist', 'list').splitlines()):
            raise RuntimeError('Deleted clipboard entry remains in history')
        copy('text/plain;charset=utf-8', b'MacShell paste test')
        qml_dir = root / 'qml'
        qml_dir.mkdir()
        (qml_dir / 'shell.qml').write_text('''import QtQuick
import QtQuick.Window
import Quickshell
ShellRoot {
    settings.watchFiles: false
    Window {
        visible: true; width: 400; height: 120; title: "MacShell clipboard test"
        TextInput { anchors.fill: parent; focus: true
            onTextChanged: if (text === "MacShell paste test") { console.log("MACSHELL_PASTE_PASS"); Qt.quit(); }
        }
    }
}''')
        app_env = dict(env, QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='')
        with (root / 'app.log').open('w') as log:
            app = subprocess.Popen(['qs', '-p', str(qml_dir)], env=app_env, stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    focused = json.loads(command('niri', 'msg', '-j', 'focused-window'))
                    if focused and focused.get('title') == 'MacShell clipboard test':
                        break
                    if app.poll() is not None:
                        raise RuntimeError('Test window exited before paste: ' + (root / 'app.log').read_text())
                    time.sleep(.1)
                else:
                    raise RuntimeError('Isolated test window did not gain focus')
                command('wtype', '-M', 'ctrl', '-k', 'v', '-m', 'ctrl')
                app.wait(timeout=8)
                if app.returncode or 'MACSHELL_PASTE_PASS' not in (root / 'app.log').read_text():
                    raise RuntimeError('Keyboard paste failed: ' + (root / 'app.log').read_text())
            finally:
                if app.poll() is None:
                    app.terminate()
                    app.wait(timeout=5)
        shell = root / 'shell'
        shutil.copytree(ROOT / 'MacShell', shell)
        source = (shell / 'shell.qml').read_text()
        (shell / 'shell.qml').write_text(source.replace('ShellRoot {', 'ShellRoot {\n' +
            (ROOT / 'tests/clipboard-reprobe.qml').read_text(), 1))
        for name in ('home', 'data', 'shell-cache', 'settings/macbar', 'settings/macdock', 'bin'):
            (root / name).mkdir(parents=True)
        (root / 'settings/macbar/settings.json').write_text(json.dumps(dict(barEnabled=True, spotlightEnabled=True,
            ccEnabled=False, notificationsEnabled=False, clipHistory=True, autoContrast=False, barGlass=False, statsMetrics=[])))
        (root / 'settings/macdock/settings.json').write_text(json.dumps(dict(dockEnabled=False, windowCapture=False)))
        # Only the fixture's private bin gains cliphist; no host clipboard watcher is used.
        pgrep = root / 'bin/pgrep'
        pgrep.write_text('#!/bin/sh\nexit 1\n')
        pgrep.chmod(0o755)
        shell_env = dict(env, HOME=str(root / 'home'), XDG_DATA_HOME=str(root / 'data'),
            XDG_CACHE_HOME=str(root / 'shell-cache'), MACSHELL_SETTINGS_HOME=str(root / 'settings'),
            PATH=str(root / 'bin') + ':/usr/bin:/bin', MACSHELL_TEST_CLIPHIST=shutil.which('cliphist'),
            MACSHELL_TEST_CLIPHIST_LINK=str(root / 'bin/cliphist'), QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='',
            QT_QUICK_CONTROLS_STYLE='Basic', DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
            DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'), NIRI_SOCKET=str(root / 'no-session'))
        result = subprocess.run([quickshell(), '-p', str(shell)], env=shell_env, capture_output=True, text=True, timeout=30)
        log = result.stdout + result.stderr
        if result.returncode or 'MACSHELL_CLIPBOARD_REPROBE_PASS' not in log:
            raise RuntimeError('Clipboard retry failed: ' + log[-5000:])
    finally:
        for process in watchers:
            process.terminate()
        for process in watchers:
            process.wait(timeout=5)
        subprocess.run(['niri', 'msg', 'action', 'quit', '--skip-confirmation'], capture_output=True, timeout=8)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--child':
        root = Path(sys.argv[2])
        try:
            child(*sys.argv[2:])
        except Exception as error:
            (root / 'result').write_text('ERROR: ' + repr(error))
            raise
        else:
            (root / 'result').write_text('PASS')
        return
    if not os.environ.get('WAYLAND_DISPLAY') or not os.environ.get('NIRI_SOCKET'):
        raise RuntimeError('A parent Wayland/niri session is required')
    with tempfile.TemporaryDirectory(prefix='macshell-clipboard-nested-') as directory:
        root = Path(directory)
        config = root / 'niri.kdl'
        config.write_text('hotkey-overlay { skip-at-startup; }\n')
        command = ['niri', '-c', str(config), '--', sys.executable, str(Path(__file__).resolve()), '--child',
                   directory, os.environ['WAYLAND_DISPLAY'], os.environ['NIRI_SOCKET']]
        with (root / 'niri.log').open('w') as output:
            process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                       env=dict(os.environ, MACSHELL_NESTED_TEST_TOKEN=uuid.uuid4().hex))
            try:
                deadline = time.monotonic() + 35
                result = root / 'result'
                while time.monotonic() < deadline and not result.exists() and process.poll() is None:
                    time.sleep(.1)
                if not result.exists() or result.read_text() != 'PASS':
                    raise RuntimeError((result.read_text() if result.exists() else 'no result') + '\n' +
                                       (root / 'niri.log').read_text()[-4000:])
                print('MACSHELL_CLIPBOARD_PASS: isolated storage, recovery, deletion, keyboard paste and dependency retry')
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)


if __name__ == '__main__':
    main()
