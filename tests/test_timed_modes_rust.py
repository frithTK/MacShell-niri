"""Rust timed-mode protocol and session identity checks in isolated profiles."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.install_niri import quickshell
from test_system_stats_rust import Client

BINARY = os.environ.get('MACSHELL_TEST_TIMED_MODES_BINARY')
BOOT = Path('/proc/sys/kernel/random/boot_id').read_text().strip()


def environment(**overrides):
    env = dict(os.environ)
    env.pop('MACSHELL_SESSION_TOKEN', None)
    env.pop('NIRI_SOCKET', None)
    env.update(overrides)
    return env


def request(action, data, generation=1):
    return {'action': action, 'data': data, 'generation': generation}


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_TIMED_MODES_BINARY to test Rust timed modes')
class TimedModesRustTests(unittest.TestCase):
    def start(self, env):
        client = Client([BINARY], env=env)
        self.addCleanup(client.close)
        client.message(lambda m: m.get('type') == 'ready')
        return client

    def test_restore_rebases_focus_and_confines_awake_to_session(self):
        client = self.start(environment(MACSHELL_SESSION_TOKEN='current-session'))
        now = time.time()
        data = {'focus': {'mode': '60', 'boot': 'previous-boot', 'session': 'previous-session',
                          'utc': now + 1800, 'deadline': 55, 'future': {'keep': True}},
                'awake': {'mode': 'manual', 'boot': BOOT, 'session': 'current-session'}}
        client.send(request('restore', data, generation=9))
        state = client.message(lambda m: m.get('type') == 'state')
        self.assertTrue(state['sessionKnown']); self.assertTrue(state['changed'])
        self.assertEqual(state['generation'], 9)
        self.assertEqual(state['values']['focus']['boot'], BOOT)
        self.assertEqual(state['values']['focus']['future'], {'keep': True})
        self.assertGreater(state['remaining']['focus'], 1790)
        self.assertLessEqual(state['remaining']['focus'], 1800)
        self.assertEqual(state['values']['awake']['mode'], 'manual')
        client.send(request('set', {'kind': 'awake', 'mode': '15'}, generation=10))
        changed = client.message(lambda m: m.get('type') == 'state' and m.get('generation') == 10)
        self.assertTrue(changed['changed']); self.assertGreater(changed['remaining']['awake'], 899)
        tick = client.message(lambda m: m.get('type') == 'state' and m.get('generation') == 10)
        self.assertFalse(tick['changed'])
        self.assertLess(tick['remaining']['awake'], changed['remaining']['awake'])
        client.send(request('set', {'kind': 'awake', 'mode': 'off'}, generation=11))
        self.assertEqual(client.message(lambda m: m.get('generation') == 11)['values']['awake']['mode'], 'off')

    def test_unknown_session_never_restores_awake(self):
        client = self.start(environment())
        client.send(request('restore', {'focus': {'mode': 'manual'}, 'awake': {'mode': 'manual', 'boot': BOOT, 'session': 'old'}}))
        state = client.message(lambda m: m.get('type') == 'state')
        self.assertFalse(state['sessionKnown'])
        self.assertEqual(state['values']['focus']['mode'], 'manual')
        self.assertEqual(state['values']['awake']['mode'], 'off')

    def test_saved_protocol_matches_python_for_same_session(self):
        env = environment(MACSHELL_SESSION_TOKEN='same-session')
        clients = [Client([sys.executable, '-u', str(ROOT / 'MacShell/timed_modes.py')], env=env),
                   Client([BINARY], env=env)]
        try:
            states = []
            saved = {'focus': {'mode': 'manual', 'future': {'keep': True}},
                     'awake': {'mode': 'manual', 'boot': BOOT, 'session': 'same-session'}}
            for client in clients:
                client.message(lambda m: m.get('type') == 'ready')
                client.send(request('restore', saved, generation=4))
                states.append(client.message(lambda m: m.get('type') == 'state'))
            for key in ('values', 'remaining', 'changed', 'sessionKnown', 'generation'):
                self.assertEqual(states[0][key], states[1][key], key)
            for client in clients:
                client.send(request('set', {'kind': 'focus', 'mode': '15'}, generation=5))
            updates = [client.message(lambda m: m.get('generation') == 5) for client in clients]
            self.assertEqual(updates[0]['values']['focus']['mode'], updates[1]['values']['focus']['mode'])
            self.assertLess(abs(updates[0]['values']['focus']['deadline'] - updates[1]['values']['focus']['deadline']), 2)
            self.assertLess(abs(updates[0]['values']['focus']['utc'] - updates[1]['values']['focus']['utc']), 2)
        finally:
            for client in clients: client.close()

    def test_invalid_and_expired_saved_values_are_off(self):
        client = self.start(environment(MACSHELL_SESSION_TOKEN='s'))
        for focus in [{'mode': '60', 'boot': BOOT, 'utc': 'bad', 'deadline': 200},
                      {'mode': 'evening'}, {'mode': '60', 'boot': 'previous', 'utc': 1}, True]:
            client.send(request('restore', {'focus': focus, 'awake': {'mode': 'off'}}))
            state = client.message(lambda m: m.get('type') == 'state')
            self.assertEqual(state['values']['focus']['mode'], 'off')
        client.send(request('set', {'kind': 'focus', 'mode': 'bogus'}, generation=22))
        self.assertEqual(client.message(lambda m: m.get('type') == 'error')['generation'], 22)

    def test_expiry_publishes_off_and_marks_it_for_persistence(self):
        client = self.start(environment(MACSHELL_SESSION_TOKEN='s'))
        now = time.time(); uptime = time.clock_gettime(time.CLOCK_BOOTTIME)
        client.send(request('restore', {'focus': {'mode': '15', 'boot': BOOT, 'session': 's',
                                                  'utc': now + 3, 'deadline': uptime + 3}}))
        self.assertEqual(client.message(lambda m: m.get('type') == 'state')['values']['focus']['mode'], '15')
        expired = client.message(lambda m: m.get('type') == 'state' and m.get('values', {}).get('focus', {}).get('mode') == 'off', timeout=6)
        self.assertTrue(expired['changed'])
        self.assertEqual(expired['remaining']['focus'], 0)

    def test_live_niri_socket_matches_python_session_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / 'niri.sock')
            server = socket.socket(socket.AF_UNIX); server.bind(path); server.listen(1)
            self.addCleanup(server.close)
            errors = []
            def serve():
                try:
                    connection, _ = server.accept()
                    with connection:
                        with connection.makefile('rb') as stream:
                            self.assertEqual(stream.readline(), b'"Version"\n')
                        connection.sendall(b'{"Ok":{"Version":"test"}}\n')
                except Exception as error: errors.append(error)
            thread = threading.Thread(target=serve, daemon=True); thread.start()
            stat = os.stat(path)
            session = f'{BOOT}:{stat.st_dev}:{stat.st_ino}:{stat.st_ctime_ns}'
            client = self.start(environment(NIRI_SOCKET=path))
            client.send(request('restore', {'awake': {'mode': 'manual', 'boot': BOOT, 'session': session}}))
            state = client.message(lambda m: m.get('type') == 'state')
            self.assertTrue(state['sessionKnown'])
            self.assertEqual(state['values']['awake']['mode'], 'manual')
            self.assertEqual(state['values']['awake']['session'], session)
            thread.join(timeout=3); self.assertFalse(thread.is_alive()); self.assertFalse(errors)

    def test_socket_replacement_during_probe_never_confirms_session(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); first = root / 'first.sock'; second = root / 'second.sock'; link = root / 'current.sock'
            server = socket.socket(socket.AF_UNIX); server.bind(str(first)); server.listen(1)
            other = socket.socket(socket.AF_UNIX); other.bind(str(second)); other.listen(1)
            self.addCleanup(server.close); self.addCleanup(other.close)
            link.symlink_to(first)
            errors = []
            def serve():
                try:
                    connection, _ = server.accept()
                    with connection:
                        connection.recv(1024)
                        link.unlink(); link.symlink_to(second)
                        connection.sendall(b'{"Ok":{"Version":"test"}}\n')
                except Exception as error: errors.append(error)
            thread = threading.Thread(target=serve, daemon=True); thread.start()
            client = self.start(environment(NIRI_SOCKET=str(link)))
            client.send(request('restore', {'awake': {'mode': 'manual', 'boot': BOOT, 'session': 'old'}}))
            state = client.message(lambda m: m.get('type') == 'state')
            self.assertFalse(state['sessionKnown'])
            self.assertEqual(state['values']['awake']['mode'], 'off')
            thread.join(timeout=3); self.assertFalse(thread.is_alive()); self.assertFalse(errors)

    def test_full_socket_backlog_does_not_block_startup_or_confirm_session(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / 'busy.sock')
            server = socket.socket(socket.AF_UNIX); server.bind(path); server.listen(0)
            blocker = socket.socket(socket.AF_UNIX); blocker.connect(path)
            self.addCleanup(server.close); self.addCleanup(blocker.close)
            started = time.monotonic()
            client = self.start(environment(NIRI_SOCKET=path))
            self.assertLess(time.monotonic() - started, 3)
            client.send(request('restore', {'awake': {'mode': 'manual', 'boot': BOOT, 'session': 'old'}}))
            state = client.message(lambda m: m.get('type') == 'state')
            self.assertFalse(state['sessionKnown'])
            self.assertEqual(state['values']['awake']['mode'], 'off')

    def test_niri_error_response_does_not_confirm_session(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / 'failed.sock')
            server = socket.socket(socket.AF_UNIX); server.bind(path); server.listen(1)
            self.addCleanup(server.close)
            def serve():
                connection, _ = server.accept()
                with connection:
                    connection.recv(1024)
                    connection.sendall(b'{"Err":"unavailable"}\n')
            thread = threading.Thread(target=serve, daemon=True); thread.start()
            client = self.start(environment(NIRI_SOCKET=path))
            client.send(request('restore', {'awake': {'mode': 'manual', 'boot': BOOT, 'session': 'old'}}))
            state = client.message(lambda m: m.get('type') == 'state')
            self.assertFalse(state['sessionKnown'])
            self.assertEqual(state['values']['awake']['mode'], 'off')
            thread.join(timeout=3); self.assertFalse(thread.is_alive())

    def test_stalled_niri_response_times_out_without_restoring_awake(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / 'stalled.sock')
            server = socket.socket(socket.AF_UNIX); server.bind(path); server.listen(1)
            self.addCleanup(server.close)
            release = threading.Event()
            def serve():
                connection, _ = server.accept()
                with connection:
                    connection.recv(1024)
                    release.wait(6)
            thread = threading.Thread(target=serve, daemon=True); thread.start()
            try:
                started = time.monotonic()
                client = self.start(environment(NIRI_SOCKET=path))
                self.assertLess(time.monotonic() - started, 5)
                client.send(request('restore', {'awake': {'mode': 'manual', 'boot': BOOT, 'session': 'old'}}))
                state = client.message(lambda m: m.get('type') == 'state')
                self.assertFalse(state['sessionKnown'])
                self.assertEqual(state['values']['awake']['mode'], 'off')
            finally:
                release.set(); thread.join(timeout=3)
            self.assertFalse(thread.is_alive())

    def test_launcher_prefers_rust_and_falls_back(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            shutil.copy(ROOT / 'MacShell/timed-modes.sh', folder / 'timed-modes.sh')
            (folder / 'timed_modes.py').write_text('print("legacy")\n')
            binary = folder / 'timed-modes-rust'
            binary.write_text('#!/bin/sh\nif [ "${1-}" = --protocol-version ]; then echo "macshell-timed-modes 1"; else echo rust; fi\n')
            binary.chmod(0o755)
            def launch(check=True):
                return subprocess.run(['sh', str(folder / 'timed-modes.sh')], capture_output=True, text=True, timeout=5, check=check)
            self.assertEqual(launch().stdout.strip(), 'rust')
            binary.write_text('#!/bin/sh\necho incompatible\n')
            incompatible = launch(check=False)
            self.assertNotEqual(incompatible.returncode, 0)
            self.assertNotIn('legacy', incompatible.stdout)
            self.assertIn('Rust', incompatible.stderr)
            binary.unlink()
            missing = launch(check=False)
            self.assertNotEqual(missing.returncode, 0)
            self.assertNotIn('legacy', missing.stdout)

    @unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
    def test_qml_restore_and_changes_use_rust(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); shell = root / 'shell'
            shutil.copytree(ROOT / 'MacShell', shell)
            shutil.copy(ROOT / 'tests/timed-modes-rust.qml', shell / 'shell.qml')
            shutil.copy(BINARY, shell / 'timed-modes-rust')
            (shell / 'timed_modes.py').write_text('raise SystemExit("unexpected Python fallback")\n')
            for name in ('runtime', 'config', 'cache'): (root / name).mkdir()
            (root / 'runtime').chmod(0o700)
            env = environment(MACSHELL_SESSION_TOKEN='qml-test-session', TEST_BOOT=BOOT,
                              XDG_RUNTIME_DIR=str(root / 'runtime'), XDG_CONFIG_HOME=str(root / 'config'),
                              XDG_CACHE_HOME=str(root / 'cache'), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='',
                              QT_QUICK_BACKEND='software', DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
            env.pop('DISPLAY', None); env.pop('WAYLAND_DISPLAY', None)
            result = subprocess.run([quickshell(), '-p', str(shell)], env=env, capture_output=True, text=True, timeout=16)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('TIMED_RUST_QML_PASS', result.stdout + result.stderr)


if __name__ == '__main__': unittest.main()
