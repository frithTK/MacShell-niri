import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.install_niri import quickshell


@unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
class LockKeyboardTests(unittest.TestCase):
    def test_real_event_stream_switch_disconnect_and_reconnect(self):
        with tempfile.TemporaryDirectory(prefix='maclock-layout-') as directory:
            root = Path(directory)
            for name in ('runtime', 'cache', 'config'):
                (root / name).mkdir()
            (root / 'runtime').chmod(0o700)
            shell = root / 'lock'
            shutil.copytree(ROOT / 'MacLock', shell)
            shutil.copyfile(ROOT / 'tests/maclock-keyboard.qml', shell / 'shell.qml')
            address = str(root / 'niri.sock')
            server = socket.socket(socket.AF_UNIX)
            self.addCleanup(server.close)
            server.bind(address); server.listen(2); server.settimeout(8)
            env = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='', QT_QUICK_BACKEND='software',
                       XDG_RUNTIME_DIR=str(root / 'runtime'), XDG_CACHE_HOME=str(root / 'cache'), XDG_CONFIG_HOME=str(root / 'config'),
                       NIRI_SOCKET=address, DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
            env.pop('DISPLAY', None); env.pop('WAYLAND_DISPLAY', None)
            logpath = root / 'log'
            with logpath.open('w') as log:
                process = subprocess.Popen([quickshell(), '-p', str(shell)], env=env, stdout=log, stderr=subprocess.STDOUT)
                self.addCleanup(lambda: process.poll() is None and process.kill())
                def wait(marker):
                    deadline = time.monotonic() + 6
                    while time.monotonic() < deadline and process.poll() is None:
                        if marker in logpath.read_text(): return
                        time.sleep(.03)
                    self.fail('Missing ' + marker + ': ' + logpath.read_text())
                def send(conn, event):
                    conn.sendall((json.dumps(event) + '\n').encode())
                def connect():
                    conn, _ = server.accept(); conn.settimeout(3)
                    self.assertEqual(conn.makefile('rb').readline(), b'"EventStream"\n')
                    return conn
                conn = connect()
                send(conn, {'Ok': 'Handled'})
                send(conn, {'KeyboardLayoutsChanged': {'keyboard_layouts': {'names': ['English (US)', 'Russian'], 'current_idx': 0}}})
                wait('MACLOCK_LAYOUT_STEP_0')
                send(conn, {'KeyboardLayoutSwitched': {'idx': 1}}); wait('MACLOCK_LAYOUT_STEP_1')
                send(conn, {'KeyboardLayoutSwitched': {'idx': 99}}); wait('MACLOCK_LAYOUT_STEP_2')
                send(conn, {'KeyboardLayoutSwitched': {'idx': 0}}); wait('MACLOCK_LAYOUT_STEP_3')
                conn.close(); wait('MACLOCK_LAYOUT_STEP_4')
                conn = connect()
                send(conn, {'KeyboardLayoutsChanged': {'keyboard_layouts': {'names': ['English (US)', 'Russian'], 'current_idx': 1}}})
                wait('MACLOCK_LAYOUT_STEP_5')
                send(conn, {'KeyboardLayoutsChanged': {'keyboard_layouts': {'names': ['Japanese'], 'current_idx': 0}}})
                wait('MACLOCK_LAYOUT_STEP_6')
                send(conn, {'Err': 'test error'}); wait('MACLOCK_LAYOUT_STEP_7')
                conn.close(); conn = connect()
                send(conn, {'KeyboardLayoutsChanged': {'keyboard_layouts': {'names': ['Japanese'], 'current_idx': 0}}})
                process.wait(timeout=6); conn.close()
            output = logpath.read_text()
            self.assertEqual(process.returncode, 0, output)
            self.assertIn('MACLOCK_LAYOUT_PASS', output)
            self.assertNotIn('TypeError', output)
            self.assertNotIn('ReferenceError', output)


if __name__ == '__main__': unittest.main()
