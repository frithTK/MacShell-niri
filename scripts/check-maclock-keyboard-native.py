#!/usr/bin/env python3
"""Check the lock-screen layout indicator in an isolated nested niri, preview only."""
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
    lock = root / 'lock'
    shutil.copytree(ROOT / 'MacLock', lock)
    path = lock / 'shell.qml'
    source = path.read_text().replace('ShellRoot {', 'ShellRoot {\n    Timer { interval: 100; repeat: true; running: true; onTriggered: if (!root.preview || lock.locked || pam.active) { console.error("MACLOCK_NATIVE_LAYOUT_FAIL real lock/auth"); Qt.exit(1); } }\n', 1)
    path.write_text(source)
    path = lock / 'LockScreen.qml'
    source = path.read_text().replace('    id: ls\n', '    id: ls\n' + (ROOT / 'tests/maclock-keyboard-native.qml').read_text(), 1)
    path.write_text(source)
    for name in ('home', 'cache', 'config', 'settings'):
        (root / name).mkdir()
    language = os.environ.get('MACLOCK_LAYOUT_LANG', 'en')
    if language not in ('en', 'ru'):
        raise RuntimeError('MACLOCK_LAYOUT_LANG must be en or ru')
    locale_dir = root / 'config/environment.d'
    locale_dir.mkdir()
    (locale_dir / '90-macshell-locale.conf').write_text('# MacShell locale preferences v1\n# ui=' + language + '\n# session=system\n# region=system\n')
    env = dict(os.environ, HOME=str(root / 'home'), USER='Demo', XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'),
               MACSHELL_SETTINGS_HOME=str(root / 'settings'), QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic',
               MACLOCK_PREVIEW='1', DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
               DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'), PIPEWIRE_REMOTE='macshell-no-audio')
    env.pop('MACLOCK_PREVIEW_KB', None)
    logpath = root / 'shell.log'
    try:
        with logpath.open('w') as log:
            process = subprocess.Popen([quickshell(), '-p', str(lock)], env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                stage = 0
                deadline = time.monotonic() + 25
                while process.poll() is None and time.monotonic() < deadline:
                    output = logpath.read_text()
                    if stage < 2 and 'MACLOCK_NATIVE_LAYOUT_' + str(stage) in output:
                        capture = os.environ.get('MACLOCK_LAYOUT_CAPTURE')
                        if stage == 1 and capture:
                            time.sleep(.8)
                            subprocess.run(['grim', '-o', 'winit', capture], env=env, capture_output=True, timeout=5, check=True)
                        subprocess.run(['niri', 'msg', 'action', 'switch-layout', str(1 - stage)], env=env,
                                       capture_output=True, text=True, timeout=5, check=True)
                        stage += 1
                    time.sleep(.05)
                if process.poll() is None:
                    raise RuntimeError('MacLock layout check timed out')
            finally:
                if process.poll() is None:
                    process.terminate(); process.wait(timeout=5)
        output = logpath.read_text()
        if process.returncode or 'MACLOCK_NATIVE_LAYOUT_PASS' not in output or re.search(r'TypeError|ReferenceError|Binding loop|Unable to assign|MACLOCK_NATIVE_LAYOUT_FAIL', output):
            raise RuntimeError(output[-8000:])
    finally:
        subprocess.run(['niri', 'msg', 'action', 'quit', '--skip-confirmation'], env=env, capture_output=True, timeout=8)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--child':
        root = Path(sys.argv[2])
        try: child(*sys.argv[2:])
        except Exception as error: (root / 'result').write_text('ERROR: ' + repr(error)); raise
        else: (root / 'result').write_text('PASS')
        return
    if not os.environ.get('WAYLAND_DISPLAY') or not os.environ.get('NIRI_SOCKET'):
        raise RuntimeError('A parent Wayland/niri session is required')
    with tempfile.TemporaryDirectory(prefix='maclock-layout-nested-') as directory:
        root = Path(directory)
        config = root / 'niri.kdl'
        config.write_text('input { keyboard { xkb { layout "us,ru"; }; }; }\nhotkey-overlay { skip-at-startup; }\n')
        command = ['niri', '-c', str(config), '--', sys.executable, str(Path(__file__).resolve()), '--child', directory,
                   os.environ['WAYLAND_DISPLAY'], os.environ['NIRI_SOCKET']]
        with (root / 'niri.log').open('w') as output:
            process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                       env=dict(os.environ, MACSHELL_NESTED_TEST_TOKEN=uuid.uuid4().hex))
            try:
                deadline = time.monotonic() + 40
                result = root / 'result'
                while time.monotonic() < deadline and not result.exists() and process.poll() is None: time.sleep(.1)
                if not result.exists() or result.read_text() != 'PASS':
                    raise RuntimeError((result.read_text() if result.exists() else 'no result') + '\n' + (root / 'niri.log').read_text()[-8000:])
                print('MACLOCK_NATIVE_LAYOUT_PASS: real niri layout switches; preview only, no lock or PAM')
            finally:
                if process.poll() is None: process.terminate()
                process.wait(timeout=5)


if __name__ == '__main__': main()
