"""Saved Wi-Fi activation against a private synthetic NetworkManager only."""
import json
import os
import subprocess
import threading
import unittest

from gi.repository import Gio, GLib
from test_dbus_protocol import PrivateBus
from test_network_agent_rust import Harness as AgentHarness, PATH as AGENT_PATH
import network_control as net

BINARY = os.environ.get('MACSHELL_TEST_NETWORK_ACTIVATE_HARNESS')
AGENT_BINARY = os.environ.get('MACSHELL_TEST_NETWORK_AGENT_HARNESS')


class ActivationBus(PrivateBus):
    def __init__(self):
        self.mode = 'normal'
        self.calls = []
        self.entered = threading.Event()
        self.release = threading.Event()
        super().__init__()
        self.settings = GLib.Variant('a{sa{sv}}', {
            'connection': {'uuid': GLib.Variant('s', 'test-id')},
            '802-11-wireless': {'ssid': GLib.Variant('ay', list(b'Test WiFi'))},
            '802-11-wireless-security': {'key-mgmt': GLib.Variant('s', 'wpa-psk')}})

    def register(self, path, interface, methods, properties=None):
        if path == net.ROOT and interface == net.NM:
            methods += '<method name="ActivateConnection"><arg type="o" direction="in"/><arg type="o" direction="in"/><arg type="o" direction="in"/><arg type="o" direction="out"/></method>'
        return super().register(path, interface, methods, properties)

    def method(self, bus, sender, path, iface, method, parameters, invocation):
        if method == 'AddAndActivateConnection2':
            self.calls.append(parameters.unpack())
            if self.mode == 'hold':
                self.entered.set()
                self.release.wait(timeout=3)
            if self.mode == 'deny':
                invocation.return_dbus_error(net.NM + '.Error.Failed', 'synthetic')
            else:
                invocation.return_value(GLib.Variant('(ooa{sv})', (self.profile, self.active_path, {})))
            return
        if method == 'ActivateConnection':
            self.calls.append(parameters.unpack())
            if self.mode == 'hold':
                self.entered.set()
                self.release.wait(timeout=3)
            if self.mode == 'deny':
                invocation.return_dbus_error(net.NM + '.Error.Failed', 'synthetic')
            else:
                invocation.return_value(GLib.Variant('(o)', ('/foreign' if self.mode == 'foreign' else self.active_path,)))
            return
        super().method(bus, sender, path, iface, method, parameters, invocation)

    def close(self):
        self.release.set()
        super().close()


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_NETWORK_ACTIVATE_HARNESS')
class NetworkActivateRustTests(unittest.TestCase):
    def setUp(self):
        self.bus = ActivationBus()

    def tearDown(self):
        self.bus.close()

    def run_command(self, mode):
        result = subprocess.run([BINARY, mode], env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=self.bus.address),
                                capture_output=True, text=True, timeout=7, check=True)
        return json.loads(result.stdout)

    def test_saved_activation_returns_path_without_ownership_claim(self):
        result = self.run_command('saved')
        self.assertEqual(result, {'ok': True, 'path': self.bus.active_path, 'owned': False})
        self.assertEqual(self.bus.calls, [(self.bus.profile, net.ROOT + '/Devices/1', self.bus.ap)])

    def test_stale_or_invalid_selection_never_dispatches(self):
        for mode, expected in [('stale-uuid', 'Stale'), ('stale-ssid', 'Stale'),
                               ('stale-security', 'Stale'), ('invalid', 'Invalid'), ('wrong-owner', 'OwnerChanged')]:
            with self.subTest(mode=mode):
                self.assertEqual(self.run_command(mode)['error'], expected)
        self.assertEqual(self.bus.calls, [])

    def test_inspection_reads_state_without_activation(self):
        for value, expected in [(1, 'Activating'), (2, 'Activated'), (3, 'Deactivating'), (4, 'Deactivated'), (99, 'Unknown')]:
            self.bus.props[(self.bus.active_path, net.ACTIVE)]['State'] = GLib.Variant('u', value)
            self.assertEqual(self.run_command('inspect'), {'ok': True, 'state': expected})
        self.assertEqual(self.run_command('inspect-invalid')['error'], 'Invalid')
        self.assertEqual(self.bus.calls, [])

    def test_missing_object_requires_absence_from_active_list(self):
        self.assertTrue(self.bus.connection.unregister_object(self.bus.ids.pop()))
        self.assertEqual(self.run_command('inspect')['error'], 'Unavailable')
        self.bus.props[(net.ROOT, net.NM)]['ActiveConnections'] = GLib.Variant('ao', [])
        self.assertEqual(self.run_command('inspect'), {'ok': True, 'state': 'Deactivated'})

    def test_rejected_or_foreign_reply_is_uncertain(self):
        for mode in ('deny', 'foreign'):
            self.bus.mode = mode
            self.assertEqual(self.run_command('saved')['error'], 'Uncertain')
        self.assertEqual(len(self.bus.calls), 2)

    def test_timeout_never_retries_activation(self):
        self.bus.mode = 'hold'
        try:
            self.assertEqual(self.run_command('saved')['error'], 'Uncertain')
            self.assertTrue(self.bus.entered.is_set())
            self.assertEqual(len(self.bus.calls), 1)
        finally:
            self.bus.release.set()

    def test_owner_loss_after_dispatch_is_uncertain(self):
        self.bus.mode = 'hold'
        process = subprocess.Popen([BINARY, 'saved'], env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=self.bus.address),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertTrue(self.bus.entered.wait(3))
            self.bus.connection.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus',
                                          'org.freedesktop.DBus', 'ReleaseName', GLib.Variant('(s)', (net.NM,)),
                                          None, Gio.DBusCallFlags.NONE, 1000, None)
            self.bus.release.set()
            output, error = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, error)
            self.assertEqual(json.loads(output)['error'], 'Uncertain')
            self.assertEqual(len(self.bus.calls), 1)
        finally:
            self.bus.release.set()
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_create_new_profile_with_synthetic_secret(self):
        self.bus.settings = None
        result = self.run_command('create')
        self.assertEqual(result, {'ok': True, 'profile': self.bus.profile, 'path': self.bus.active_path, 'owned': False})
        settings, device, ap, options = self.bus.calls[0]
        self.assertEqual((device, ap), (net.ROOT + '/Devices/1', self.bus.ap))
        self.assertEqual(options['persist'], 'disk')
        self.assertEqual(settings['802-11-wireless']['ssid'], list(b'Test WiFi'))
        self.assertEqual(settings['802-11-wireless-security']['psk'], 'synthetic-password')
        self.assertEqual(settings['802-11-wireless-security']['psk-flags'], 0)
        self.assertEqual(settings['connection']['permissions'], ['user:tester:'])
        self.assertNotIn('synthetic-password', json.dumps(result))

    def test_create_rejects_stale_or_already_saved_without_dispatch(self):
        self.assertEqual(self.run_command('create')['error'], 'Stale')
        self.bus.settings = None
        self.assertEqual(self.run_command('create-stale')['error'], 'Stale')
        self.assertEqual(self.run_command('create-stale-interface')['error'], 'Stale')
        self.assertEqual(self.bus.calls, [])

    def test_create_timeout_is_uncertain_without_retry(self):
        self.bus.settings = None
        self.bus.mode = 'hold'
        try:
            self.assertEqual(self.run_command('create')['error'], 'Uncertain')
            self.assertTrue(self.bus.entered.is_set())
            self.assertEqual(len(self.bus.calls), 1)
        finally:
            self.bus.release.set()


@unittest.skipUnless(BINARY and AGENT_BINARY, 'Set activation and agent test harnesses')
class NetworkCreateAgentIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.bus = PrivateBus()
        self.agent = AgentHarness(self.bus.address, binary=AGENT_BINARY)
        self.bus.agents['wifi'] = (self.agent.ready['unique'], AGENT_PATH)
        self.agent.send('begin', id=10, uuid='d4ac1208-0a7b-4012-8abc-381d6ca41234',
                        profile=None, provided=True)
        self.agent.wait('begun')
        self.process = None

    def tearDown(self):
        try:
            if self.process and self.process.poll() is None:
                self.process.kill()
                self.process.communicate()
            self.agent.close()
        finally:
            self.bus.close()

    def start_create(self):
        self.process = subprocess.Popen([BINARY, 'create'], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=self.bus.address), text=True)

    def test_create_and_agent_secret_on_private_bus(self):
        self.start_create()
        event = self.agent.wait('need')
        self.assertTrue(event['provided'])
        self.agent.send('reply', delivery=event['delivery'], password='synthetic-password')
        self.assertTrue(self.agent.wait('reply')['accepted'])
        output, error = self.process.communicate(timeout=5)
        self.assertEqual(self.process.returncode, 0, error)
        self.assertTrue(json.loads(output)['ok'])
        self.assertEqual(self.bus.secret, 'synthetic-password')
        self.assertNotIn('synthetic-password', output + error + json.dumps(self.agent.seen))

    def test_cancel_during_secret_request_does_not_report_success(self):
        self.start_create()
        self.agent.wait('need')
        self.agent.send('finish', user=True)
        self.assertTrue(self.agent.wait('finished')['found'])
        output, error = self.process.communicate(timeout=5)
        self.assertEqual(self.process.returncode, 0, error)
        self.assertEqual(json.loads(output)['error'], 'Uncertain')
        self.assertIsNone(self.bus.secret)
