"""Read-only NetworkManager snapshots on a synthetic, private D-Bus."""
import json
import os
import subprocess
import threading
import time
import unittest

from gi.repository import GLib
from test_dbus_protocol import Client, PrivateBus
import network_control as net

BINARY = os.environ.get('MACSHELL_TEST_NETWORK_SNAPSHOT_HARNESS')
WORKER = os.environ.get('MACSHELL_TEST_NETWORK_WORKER_HARNESS')


class HeldListBus(PrivateBus):
    def __init__(self):
        self.entered = threading.Event()
        self.invocation = None
        super().__init__()

    def method(self, bus, sender, path, iface, method, parameters, invocation):
        if method == 'ListConnections':
            self.invocation = invocation
            self.entered.set()
        else:
            super().method(bus, sender, path, iface, method, parameters, invocation)

    def release_list(self):
        invocation = self.invocation
        self.invocation = None
        GLib.idle_add(lambda: (invocation.return_value(GLib.Variant('(ao)', ([],))), False)[1])


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_NETWORK_SNAPSHOT_HARNESS')
class NetworkSnapshotRustTests(unittest.TestCase):
    def setUp(self):
        self.bus = PrivateBus()
        self.client = None

    def tearDown(self):
        try:
            if self.client:
                self.client.close()
        finally:
            self.bus.close()

    def run_snapshot(self, owner=None):
        result = subprocess.run([BINARY] + ([owner] if owner else []),
                                env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=self.bus.address),
                                capture_output=True, text=True, timeout=8, check=True)
        return json.loads(result.stdout)

    def python_snapshot(self):
        self.client = Client('network_control.py', self.bus.address)
        return self.client.wait(lambda m: m.get('type') == 'state')

    def test_matches_python_with_hidden_and_non_utf8_networks(self):
        root = net.ROOT
        second, hidden = root + '/AccessPoint/2', root + '/AccessPoint/3'
        self.bus.register(second, net.AP, '', {'Ssid': ('ay', [110, 101, 116, 255]),
                          'Strength': ('y', 95), 'Flags': ('u', 0), 'WpaFlags': ('u', 0), 'RsnFlags': ('u', 0)})
        self.bus.register(hidden, net.AP, '', {'Ssid': ('ay', []), 'Strength': ('y', 100)})
        wifi = self.bus.props[(root + '/Devices/1', net.WIFI)]
        wifi['AccessPoints'] = GLib.Variant('ao', [self.bus.ap, second, hidden])
        wifi['ActiveAccessPoint'] = GLib.Variant('o', self.bus.ap)
        self.bus.settings = GLib.Variant('a{sa{sv}}', {
            'connection': {'uuid': GLib.Variant('s', 'test-id'), 'timestamp': GLib.Variant('t', 10)},
            '802-11-wireless': {'ssid': GLib.Variant('ay', list(b'Test WiFi'))},
            '802-11-wireless-security': {'key-mgmt': GLib.Variant('s', 'wpa-psk'),
                                         'psk': GLib.Variant('s', 'synthetic-secret-marker')}})
        expected = self.python_snapshot()
        result = self.run_snapshot()
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['state'], {k: v for k, v in expected.items() if k != 'generation'})
        self.assertNotIn('synthetic-secret-marker', json.dumps(result))
        self.assertEqual(result['state']['networks'][1]['rawSsid'], [110, 101, 116, 255])
        self.assertTrue(result['state']['networks'][0]['saved'])

    def test_empty_device_list_and_unavailable_bus(self):
        self.bus.props[(net.ROOT, net.NM)]['Devices'] = GLib.Variant('ao', [])
        result = self.run_snapshot()
        self.assertEqual(result['state']['networks'], [])
        self.assertTrue(result['state']['available'])
        bad = subprocess.run([BINARY], env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS='unix:path=/no-such-macshell-bus'),
                             capture_output=True, text=True, timeout=8)
        self.assertNotEqual(bad.returncode, 0)

    @unittest.skipUnless(WORKER, 'Set MACSHELL_TEST_NETWORK_WORKER_HARNESS')
    def test_background_worker_matches_synchronous_snapshot(self):
        expected = self.run_snapshot()
        result = subprocess.run([WORKER], env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=self.bus.address),
                                capture_output=True, text=True, timeout=9, check=True)
        self.assertEqual(json.loads(result.stdout), expected)

    def test_rejects_stale_or_invalid_owner(self):
        self.assertEqual(self.run_snapshot(':1.999999')['error'], 'OwnerChanged')
        self.assertEqual(self.run_snapshot('org.freedesktop.NetworkManager')['error'], 'Invalid')

    def test_rejects_oversize_and_foreign_paths(self):
        device = self.bus.props[(net.ROOT + '/Devices/1', net.WIFI)]
        device['AccessPoints'] = GLib.Variant('ao', ['/foreign/object'])
        self.assertEqual(self.run_snapshot()['error'], 'Invalid')
        device['AccessPoints'] = GLib.Variant('ao', [self.bus.ap] * 2049)
        self.assertEqual(self.run_snapshot()['error'], 'Limit')

    def test_rejects_oversize_ssid(self):
        self.bus.props[(self.bus.ap, net.AP)]['Ssid'] = GLib.Variant('ay', [65] * 33)
        self.assertEqual(self.run_snapshot()['error'], 'Limit')

    def test_wired_connection_and_active_saved_profile(self):
        root = net.ROOT
        wired = root + '/Devices/2'
        self.bus.register(wired, net.DEV, '', {'DeviceType': ('u', 1), 'State': ('u', 100)})
        self.bus.props[(root, net.NM)]['Devices'] = GLib.Variant('ao', [root + '/Devices/1', wired])
        self.bus.props[(root + '/Devices/1', net.DEV)]['ActiveConnection'] = GLib.Variant('o', self.bus.active_path)
        self.bus.props[(root + '/Devices/1', net.WIFI)]['ActiveAccessPoint'] = GLib.Variant('o', self.bus.ap)
        self.bus.settings = GLib.Variant('a{sa{sv}}', {
            'connection': {'uuid': GLib.Variant('s', 'saved-id')},
            '802-11-wireless': {'ssid': GLib.Variant('ay', list(b'Test WiFi'))},
            '802-11-wireless-security': {'key-mgmt': GLib.Variant('s', 'wpa-psk')}})
        expected = self.python_snapshot()
        result = self.run_snapshot()['state']
        self.assertEqual(result, {k: v for k, v in expected.items() if k != 'generation'})
        self.assertTrue(result['ethernet'])
        self.assertTrue(result['networks'][0]['inUse'])
        self.assertEqual(result['networks'][0]['profile'], self.bus.profile)

    def replace_bus_with_held_list(self):
        self.bus.close()
        self.bus = HeldListBus()

    def test_owner_loss_during_snapshot_never_emits_state(self):
        self.replace_bus_with_held_list()
        process = subprocess.Popen([BINARY], env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=self.bus.address),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertTrue(self.bus.entered.wait(3))
            self.bus.connection.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus',
                                          'org.freedesktop.DBus', 'ReleaseName', GLib.Variant('(s)', (net.NM,)),
                                          None, 0, 1000, None)
            self.bus.release_list()
            output, error = process.communicate(timeout=6)
            self.assertEqual(process.returncode, 0, error)
            result = json.loads(output)
            self.assertFalse(result['ok'])
            self.assertNotIn('state', result)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_hung_reply_is_bounded(self):
        self.replace_bus_with_held_list()
        start = time.monotonic()
        process = subprocess.Popen([BINARY], env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=self.bus.address),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertTrue(self.bus.entered.wait(3))
            output, error = process.communicate(timeout=4)
            self.assertEqual(process.returncode, 0, error)
            self.assertFalse(json.loads(output)['ok'])
            self.assertLess(time.monotonic() - start, 4)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            if self.bus.invocation:
                self.bus.release_list()


if __name__ == '__main__':
    unittest.main()
