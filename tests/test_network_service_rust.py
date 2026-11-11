"""Experimental JSON-lines Wi-Fi service against private NetworkManager."""
import os
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

from gi.repository import Gio, GLib
from test_network_agent_rust import Harness, PATH, IFACE, PROFILE, SETTING
from test_network_session_rust import HoldingBus
import network_control as net
from scripts.install_niri import quickshell

BINARY = os.environ.get('MACSHELL_TEST_NETWORK_SERVICE_BINARY')
ROOT = Path(__file__).resolve().parents[1]


class Client(Harness):
    def __init__(self, address):
        self.sequence = 0
        super().__init__(address, binary=BINARY)

    def send(self, action, data=None):
        self.sequence += 1
        import json
        self.process.stdin.write(json.dumps({'id': self.sequence, 'generation': 9, 'action': action, 'data': data or {}}) + '\n')
        self.process.stdin.flush()
        return self.sequence


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_NETWORK_SERVICE_BINARY')
class NetworkServiceTests(unittest.TestCase):
    def setUp(self):
        self.bus = HoldingBus()
        self.client = Client(self.bus.address)
        self.client.wait('state')

    def tearDown(self):
        try:
            self.bus.release_activation()
            if self.client:
                self.client.close()
        finally:
            self.bus.close()

    def ask_secret(self, uuid):
        result = queue.Queue()
        def done(bus, reply):
            try:
                result.put(('ok', bus.call_finish(reply).unpack()))
            except GLib.Error as error:
                result.put(('error', str(error)))
        settings = {'connection': {'uuid': GLib.Variant('s', uuid)}}
        peer, _ = self.bus.agents['wifi']
        self.bus.connection.call(peer, PATH, IFACE, 'GetSecrets',
            GLib.Variant('(a{sa{sv}}osasu)', (settings, PROFILE, SETTING, [], 1)),
            None, Gio.DBusCallFlags.NONE, 4000, None, done)
        return result

    def test_saved_join_prompts_and_confirms_before_success(self):
        request = self.client.send('join', {'network': self.bus.ap})
        self.assertTrue(self.bus.entered.wait(3))
        pending = self.ask_secret('test-id')
        prompt = self.client.wait('secret')
        self.assertEqual(prompt['id'], request)
        self.client.send('secret', {'request': request, 'password': 'synthetic-secret'})
        self.assertEqual(pending.get(timeout=3), ('ok', ({SETTING: {'psk': 'synthetic-secret'}},)))
        self.bus.props[(self.bus.active_path, net.ACTIVE)]['State'] = GLib.Variant('u', 2)
        self.bus.release_activation()
        result = self.client.wait('result')
        self.assertEqual((result['id'], result['state'], result['ok']), (request, 'connected', True))
        self.assertEqual(result['generation'], 9)
        self.assertNotIn('synthetic-secret', repr(self.client.seen))

    def test_new_profile_cancel_rejects_prompt_and_never_retries(self):
        self.bus.cancel_mode = 'deny'
        self.bus.settings = None
        self.client.send('refresh')
        self.client.wait('state', lambda e: not e['networks'][0]['saved'])
        request = self.client.send('join', {'network': self.bus.ap, 'password': 'synthetic-password'})
        self.assertTrue(self.bus.entered.wait(3))
        settings = self.bus.calls[0][0]
        uuid = settings['connection']['uuid']
        initial = self.ask_secret(uuid)
        self.assertEqual(initial.get(timeout=3), ('ok', ({SETTING: {'psk': 'synthetic-password'}},)))
        pending = self.ask_secret(uuid)
        prompt = self.client.wait('secret')
        self.assertEqual(prompt['id'], request)
        self.client.send('cancel', {'request': request})
        self.assertIn('UserCanceled', pending.get(timeout=3)[1])
        self.client.send('secret', {'request': request, 'password': 'late-synthetic-secret'})
        self.bus.release_activation()
        result = self.client.wait('result', timeout=7)
        self.assertEqual((result['id'], result['state']), (request, 'unknown'))
        self.assertEqual(len(self.bus.calls), 1)
        self.assertNotIn('synthetic-password', repr(self.client.seen))
        self.assertNotIn('late-synthetic-secret', repr(self.client.seen))

    def test_cancel_waits_for_networkmanager_to_stop_attempt(self):
        self.bus.cancel_mode = 'delay'
        request = self.client.send('join', {'network': self.bus.ap})
        self.assertTrue(self.bus.entered.wait(3))
        pending = self.ask_secret('test-id')
        self.client.wait('secret')
        self.client.send('cancel', {'request': request})
        self.assertIn('UserCanceled', pending.get(timeout=3)[1])
        self.bus.release_activation()
        time.sleep(1.3)
        self.bus.props[(self.bus.active_path, net.ACTIVE)]['State'] = GLib.Variant('u', 4)
        result = self.client.wait('result', timeout=7)
        self.assertEqual((result['id'], result['state']), (request, 'canceled'))
        self.assertEqual(len(self.bus.calls), 1)
        self.assertEqual(self.bus.disconnects, [])

    def test_cancel_stops_the_returned_activation_and_confirms_state(self):
        request = self.client.send('join', {'network': self.bus.ap})
        self.assertTrue(self.bus.entered.wait(3))
        self.client.send('cancel', {'request': request})
        self.bus.release_activation()
        result = self.client.wait('result', timeout=7)
        self.assertEqual((result['id'], result['state'], result['ok']), (request, 'canceled', True))
        self.assertEqual(self.bus.deactivations, [self.bus.active_path])
        self.assertEqual(self.bus.disconnects, [])

    def test_cancel_does_not_disconnect_an_already_connected_network(self):
        request = self.client.send('join', {'network': self.bus.ap})
        self.assertTrue(self.bus.entered.wait(3))
        self.client.send('cancel', {'request': request})
        self.bus.props[(self.bus.active_path, net.ACTIVE)]['State'] = GLib.Variant('u', 2)
        self.bus.release_activation()
        result = self.client.wait('result', timeout=7)
        self.assertEqual((result['id'], result['state']), (request, 'connected'))
        self.assertEqual(self.bus.deactivations, [])

    def test_cancel_confirms_when_active_connection_disappears(self):
        self.bus.cancel_mode = 'delay'
        request = self.client.send('join', {'network': self.bus.ap})
        self.assertTrue(self.bus.entered.wait(3))
        pending = self.ask_secret('test-id')
        self.client.wait('secret')
        self.client.send('cancel', {'request': request})
        self.assertIn('UserCanceled', pending.get(timeout=3)[1])
        self.bus.release_activation()
        time.sleep(1.3)
        self.bus.props[(net.ROOT, net.NM)]['ActiveConnections'] = GLib.Variant('ao', [])
        self.assertTrue(self.bus.connection.unregister_object(self.bus.ids.pop()))
        result = self.client.wait('result', timeout=7)
        self.assertEqual((result['id'], result['state']), (request, 'canceled'))
        self.assertEqual(self.bus.disconnects, [])

    def test_stale_disconnect_and_scan(self):
        self.client.send('disconnect', {'network': self.bus.ap})
        self.client.wait('error')
        self.assertEqual(self.bus.disconnects, [])
        self.client.send('scan')
        self.client.wait('state')

    def test_owner_loss_during_join_invalidates_request(self):
        self.client.send('join', {'network': self.bus.ap})
        self.assertTrue(self.bus.entered.wait(3))
        self.bus.connection.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus',
            'org.freedesktop.DBus', 'ReleaseName', GLib.Variant('(s)', (net.NM,)),
            None, Gio.DBusCallFlags.NONE, 1000, None)
        self.client.wait('unavailable')
        self.bus.release_activation()
        self.assertEqual(len(self.bus.calls), 1)

    def test_launcher_selects_compatible_binary_or_python_fallback(self):
        with tempfile.TemporaryDirectory(prefix='macshell-wifi-launch-') as temp:
            root = Path(temp)
            shutil.copy(ROOT / 'MacShell/network-service.sh', root / 'network-service.sh')
            (root / 'network_control.py').write_text('print("legacy")\n')
            binary = root / 'network-service-rust'
            def launch(check=True):
                return subprocess.run(['sh', str(root / 'network-service.sh')], capture_output=True, text=True, check=check, timeout=5)
            missing = launch(check=False)
            self.assertNotEqual(missing.returncode, 0)
            self.assertNotIn('legacy', missing.stdout)
            self.assertIn('Rust', missing.stderr)
            shutil.copy(BINARY, binary)
            probe = subprocess.run([str(binary), '--protocol-version'], capture_output=True, text=True, timeout=3, check=True)
            self.assertEqual(probe.stdout.strip(), 'macshell-network 1')
            ready = launch()
            self.assertEqual(ready.returncode, 0, ready.stderr)
            binary.write_text('#!/bin/sh\necho incompatible\n')
            binary.chmod(0o755)
            incompatible = launch(check=False)
            self.assertNotEqual(incompatible.returncode, 0)
            self.assertNotIn('legacy', incompatible.stdout)

    @unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
    def test_qml_controller_with_private_networkmanager(self):
        self.client.close()
        self.client = None
        def finish_activation():
            if self.bus.entered.wait(8):
                time.sleep(.3)
                self.bus.props[(self.bus.active_path, net.ACTIVE)]['State'] = GLib.Variant('u', 2)
                self.bus.release_activation()
        thread = threading.Thread(target=finish_activation, daemon=True)
        thread.start()
        with tempfile.TemporaryDirectory(prefix='macshell-wifi-qml-') as temp:
            root = Path(temp)
            shell = root / 'shell'
            shutil.copytree(ROOT / 'MacShell', shell)
            shutil.copy(ROOT / 'tests/wifi-rust.qml', shell / 'shell.qml')
            shutil.copy(BINARY, shell / 'network-service-rust')
            (shell / 'network_control.py').write_text('raise SystemExit("unexpected Python fallback")\n')
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
            result = subprocess.run([quickshell(), '-p', str(shell)], env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('WIFI_RUST_QML_PASS', result.stdout + result.stderr)
        thread.join(timeout=2)


if __name__ == '__main__':
    unittest.main()
