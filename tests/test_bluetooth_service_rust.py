"""Rust Bluetooth JSON protocol on a private D-Bus and synthetic BlueZ."""
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import unittest

from gi.repository import Gio, GLib
from test_dbus_protocol import Client
from test_bluez_pair_rust import PairBus
from scripts.install_niri import quickshell

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get('MACSHELL_TEST_BLUETOOTH_BINARY')


class RustClient(Client):
    def __init__(self, address, command=None):
        self.process = subprocess.Popen(command or [BINARY], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True,
                                        env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=address))
        self.queue = queue.Queue()
        self.lines = []
        self.sequence = 0
        def read():
            for line in self.process.stdout:
                self.queue.put(json.loads(line))
        self.thread = threading.Thread(target=read, daemon=True)
        self.thread.start()

    def close(self):
        if self.process.stdin.closed:
            return
        super().close()
        if self.process.returncode:
            raise AssertionError(f'Bluetooth service exited {self.process.returncode}')


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_BLUETOOTH_BINARY')
class BluetoothServiceRustTests(unittest.TestCase):
    def setUp(self):
        self.bus = PairBus()
        self.client = RustClient(self.bus.address)
        self.client.wait(lambda m: m.get('type') == 'state' and m.get('pairingAvailable'))

    def tearDown(self):
        try:
            self.client.close()
        finally:
            self.bus.close()

    def test_discovery_pair_connect_disconnect_and_power(self):
        self.client.send('discover')
        self.client.wait(lambda m: m.get('type') == 'state' and m.get('discovering'))
        self.assertIn(self.bus.device, [d['path'] for d in self.client.lines[-1]['others']])
        request = self.client.send('pair', path=self.bus.device)
        prompt = self.client.wait(lambda m: m.get('type') == 'prompt' and m.get('prompt'))['prompt']
        self.assertEqual(prompt['code'], '000042')
        self.assertEqual(prompt['request'], request)
        self.client.send('respond', prompt=prompt['id'], accept=True)
        result = self.client.wait(lambda m: m.get('type') == 'result' and m.get('id') == request)
        self.assertEqual((result['ok'], result['phase'], result['generation']), (True, 'connected', 7))
        self.assertTrue(self.bus.props[(self.bus.device, 'org.bluez.Device1')]['Trusted'].unpack())
        request = self.client.send('disconnect', path=self.bus.device)
        self.assertTrue(self.client.wait(lambda m: m.get('type') == 'result' and m.get('id') == request)['ok'])
        request = self.client.send('connect', path=self.bus.device)
        self.assertTrue(self.client.wait(lambda m: m.get('type') == 'result' and m.get('id') == request)['ok'])
        self.client.send('stopDiscovery')
        self.client.wait(lambda m: m.get('type') == 'state' and m.get('discovering') is False)
        self.assertEqual(self.bus.refs, {'another-client'})
        request = self.client.send('power', enabled=False)
        self.assertTrue(self.client.wait(lambda m: m.get('type') == 'result' and m.get('id') == request)['ok'])
        self.assertFalse(self.bus.props[('/org/bluez/hci0', 'org.bluez.Adapter1')]['Powered'].unpack())

    def test_cancel_prompt_never_trusts(self):
        request = self.client.send('pair', path=self.bus.device)
        self.client.wait(lambda m: m.get('type') == 'prompt' and m.get('prompt'))
        self.client.send('cancel', request=request)
        result = self.client.wait(lambda m: m.get('type') == 'result' and m.get('id') == request)
        self.assertEqual((result['ok'], result['phase']), (True, 'canceled'))
        self.assertFalse(self.bus.props[(self.bus.device, 'org.bluez.Device1')]['Trusted'].unpack())

    def test_owner_loss_fails_pending_request_and_recovers(self):
        request = self.client.send('pair', path=self.bus.device)
        self.client.wait(lambda m: m.get('type') == 'prompt' and m.get('prompt'))
        self.bus.name('ReleaseName')
        result = self.client.wait(lambda m: m.get('type') == 'result' and m.get('id') == request)
        self.assertFalse(result['ok'])
        self.client.wait(lambda m: m.get('type') == 'unavailable')
        self.bus.name('RequestName')
        self.client.wait(lambda m: m.get('type') == 'state' and m.get('pairingAvailable'))
        self.assertFalse(self.bus.props[(self.bus.device, 'org.bluez.Device1')]['Trusted'].unpack())

    def test_unrelated_generation_cannot_start_operation(self):
        self.client.send('refresh')
        self.client.wait(lambda m: m.get('type') == 'state' and m.get('generation') == 7)
        self.client.process.stdin.write(json.dumps({'id': 800, 'generation': 8, 'action': 'power', 'data': {'enabled': False}}) + '\n')
        self.client.process.stdin.flush()
        self.client.send('refresh')
        self.client.wait(lambda m: m.get('type') == 'state' and m.get('generation') == 7)
        time.sleep(.15)
        self.assertTrue(self.bus.props[('/org/bluez/hci0', 'org.bluez.Adapter1')]['Powered'].unpack())

    def test_invalid_request_reports_request_id(self):
        request = self.client.send('connect', path='/org/bluez/not-a-device')
        error = self.client.wait(lambda m: m.get('type') == 'error' and m.get('id') == request)
        self.assertIn('Invalid Bluetooth device', error['error'])
        self.assertEqual(error['generation'], 7)

    def test_sigterm_releases_only_our_discovery(self):
        self.client.send('discover')
        self.client.wait(lambda m: m.get('type') == 'state' and m.get('discovering'))
        self.assertEqual(len(self.bus.refs), 2)
        self.client.process.terminate()
        self.client.process.wait(timeout=5)
        deadline = time.monotonic() + 2
        while len(self.bus.refs) != 1 and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(self.bus.refs, {'another-client'})
        self.assertEqual(self.client.process.returncode, 0)

    def test_sigterm_cancels_pending_pair_before_exit(self):
        self.client.send('pair', path=self.bus.device)
        self.client.wait(lambda m: m.get('type') == 'prompt' and m.get('prompt'))
        self.client.process.terminate()
        self.client.process.wait(timeout=5)
        deadline = time.monotonic() + 2
        while not self.bus.cancel_calls and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertGreater(self.bus.cancel_calls, 0)
        self.assertEqual(self.client.process.returncode, 0)
        self.assertFalse(self.bus.props[(self.bus.device, 'org.bluez.Device1')]['Trusted'].unpack())

    def test_owner_loss_during_discovery_exits_for_safe_restart(self):
        self.client.send('discover')
        self.client.wait(lambda m: m.get('type') == 'state' and m.get('discovering'))
        self.bus.name('ReleaseName')
        self.client.wait(lambda m: m.get('type') == 'unavailable')
        self.client.process.wait(timeout=5)
        deadline = time.monotonic() + 2
        while len(self.bus.refs) != 1 and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(self.bus.refs, {'another-client'})
        self.assertEqual(self.client.process.returncode, 0)

    def test_unreachable_bus_does_not_fall_back_to_real_system_bus(self):
        result = subprocess.run([BINARY], env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS='unix:path=/no-such-macshell-bus'),
                                capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)['type'], 'unavailable')

    def test_no_owner_emits_only_unavailable_until_bluez_appears(self):
        self.client.close()
        self.bus.name('ReleaseName')
        self.client = RustClient(self.bus.address)
        self.client.wait(lambda m: m.get('type') == 'unavailable')
        time.sleep(.2)
        seen = []
        while not self.client.queue.empty():
            seen.append(self.client.queue.get_nowait())
        self.assertFalse(any(m.get('type') not in ('unavailable', 'error') for m in seen), seen)
        self.bus.name('RequestName')
        self.client.wait(lambda m: m.get('type') == 'state' and m.get('pairingAvailable'))

    def test_launcher_selects_rust_and_falls_back(self):
        with tempfile.TemporaryDirectory(prefix='macshell-bt-launcher-') as temp:
            root = Path(temp)
            shutil.copy(ROOT / 'MacShell/bluetooth-service.sh', root / 'bluetooth-service.sh')
            (root / 'bluetooth_service.py').write_text('print("legacy")\n')
            binary = root / 'bluetooth-service-rust'
            binary.write_text('#!/bin/sh\nif [ "${1-}" = --protocol-version ]; then echo "macshell-bluetooth 1"; else echo rust; fi\n')
            binary.chmod(0o755)
            def launch():
                return subprocess.run(['sh', str(root / 'bluetooth-service.sh')], capture_output=True,
                                      text=True, timeout=5, check=True).stdout.strip()
            self.assertEqual(launch(), 'rust')
            binary.write_text('#!/bin/sh\necho incompatible\n')
            self.assertEqual(launch(), 'legacy')
            binary.unlink()
            self.assertEqual(launch(), 'legacy')

    @unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
    def test_qml_controller_with_private_bluez(self):
        self.client.close()
        with tempfile.TemporaryDirectory(prefix='macshell-bt-qml-') as temp:
            root = Path(temp)
            shell = root / 'shell'
            shutil.copytree(ROOT / 'MacShell', shell)
            shutil.copy(ROOT / 'tests/bluetooth-rust.qml', shell / 'shell.qml')
            shutil.copy(BINARY, shell / 'bluetooth-service-rust')
            (shell / 'bluetooth_service.py').write_text('raise SystemExit("unexpected Python fallback")\n')
            for name in ('runtime', 'config', 'cache'):
                (root / name).mkdir()
            (root / 'runtime').chmod(0o700)
            env = dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=self.bus.address,
                       XDG_RUNTIME_DIR=str(root / 'runtime'), XDG_CONFIG_HOME=str(root / 'config'),
                       XDG_CACHE_HOME=str(root / 'cache'), QT_QPA_PLATFORM='offscreen',
                       QT_QPA_PLATFORMTHEME='', QT_QUICK_BACKEND='software',
                       DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
            env.pop('DISPLAY', None)
            env.pop('WAYLAND_DISPLAY', None)
            result = subprocess.run([quickshell(), '-p', str(shell)], env=env, capture_output=True, text=True, timeout=18)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('BLUETOOTH_RUST_QML_PASS', result.stdout + result.stderr)
            self.assertTrue(self.bus.props[(self.bus.device, 'org.bluez.Device1')]['Trusted'].unpack())
            self.assertFalse(self.bus.props[('/org/bluez/hci0', 'org.bluez.Adapter1')]['Powered'].unpack())
