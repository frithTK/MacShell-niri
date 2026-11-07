"""Synthetic NetworkManager radio writes on a private D-Bus only."""
import json
import os
import subprocess
import threading
import unittest

from gi.repository import Gio, GLib
from test_dbus_protocol import PrivateBus
import network_control as net

BINARY = os.environ.get('MACSHELL_TEST_NETWORK_RADIO_HARNESS')


class RadioBus(PrivateBus):
    def __init__(self):
        self.mode = 'normal'
        self.writes = []
        self.entered = threading.Event()
        self.release = threading.Event()
        self.scans = []
        self.scan_mode = 'normal'
        super().__init__()

    def method(self, bus, sender, path, iface, method, parameters, invocation):
        if method == 'RequestScan' and iface == net.WIFI:
            self.scans.append((path, parameters.unpack()))
            if self.scan_mode == 'hold':
                self.entered.set()
                self.release.wait(timeout=3)
            if self.scan_mode == 'deny' or (self.scan_mode == 'deny-second' and path.endswith('/2')):
                invocation.return_dbus_error('org.freedesktop.NetworkManager.Device.Wireless.ScanNotAllowed', 'synthetic')
            else:
                invocation.return_value(None)
            return
        super().method(bus, sender, path, iface, method, parameters, invocation)

    def register(self, path, interface, methods, properties=None):
        if path != net.ROOT or interface != net.NM:
            return super().register(path, interface, methods, properties)
        properties = properties or {}
        self.props[(path, interface)] = {key: GLib.Variant(sig, value) for key, (sig, value) in properties.items()}
        xml = '<node><interface name="' + interface + '">' + methods + ''.join(
            '<property name="' + key + '" type="' + sig + '" access="readwrite"/>'
            for key, (sig, _) in properties.items()) + '</interface></node>'
        def get_prop(bus, sender, obj, iface, name):
            return self.props[(obj, iface)][name]
        def set_prop(bus, sender, obj, iface, name, value):
            self.writes.append((name, value.unpack()))
            if self.mode == 'hold':
                self.entered.set()
                self.release.wait(timeout=3)
            if self.mode == 'deny':
                return False
            if self.mode != 'ignore':
                self.props[(obj, iface)][name] = value
            return True
        info = Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0]
        self.ids.append(self.connection.register_object(path, info, self.method, get_prop, set_prop))

    def close(self):
        self.release.set()
        super().close()


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_NETWORK_RADIO_HARNESS')
class NetworkRadioRustTests(unittest.TestCase):
    def setUp(self):
        self.bus = RadioBus()

    def tearDown(self):
        self.bus.close()

    def run_radio(self, state, owner=None):
        result = subprocess.run([BINARY, state] + ([owner] if owner else []),
                                env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=self.bus.address),
                                capture_output=True, text=True, timeout=7, check=True)
        return json.loads(result.stdout)

    def test_changes_and_confirms_only_wifi_power(self):
        self.assertTrue(self.run_radio('off')['ok'])
        self.assertFalse(self.bus.props[(net.ROOT, net.NM)]['WirelessEnabled'].unpack())
        self.assertEqual(self.bus.writes, [('WirelessEnabled', False)])
        self.assertTrue(self.run_radio('on')['ok'])
        self.assertTrue(self.bus.props[(net.ROOT, net.NM)]['WirelessEnabled'].unpack())
        self.assertEqual(self.bus.writes[-1], ('WirelessEnabled', True))

    def test_noop_and_hardware_block_do_not_write(self):
        self.assertTrue(self.run_radio('on')['ok'])
        self.bus.props[(net.ROOT, net.NM)]['WirelessEnabled'] = GLib.Variant('b', False)
        self.bus.props[(net.ROOT, net.NM)]['WirelessHardwareEnabled'] = GLib.Variant('b', False)
        self.assertEqual(self.run_radio('on')['error'], 'HardwareBlocked')
        self.assertEqual(self.bus.writes, [])

    def test_rejected_or_unconfirmed_write_is_not_success(self):
        self.bus.mode = 'deny'
        self.assertEqual(self.run_radio('off')['error'], 'Uncertain')
        self.bus.mode = 'ignore'
        self.assertEqual(self.run_radio('off')['error'], 'Uncertain')
        self.assertTrue(self.bus.props[(net.ROOT, net.NM)]['WirelessEnabled'].unpack())
        self.assertEqual(len(self.bus.writes), 2)

    def test_unknown_owner_never_writes(self):
        self.assertEqual(self.run_radio('off', ':1.999999')['error'], 'OwnerChanged')
        self.assertEqual(self.bus.writes, [])

    def test_timed_out_write_is_uncertain_and_never_retried(self):
        self.bus.mode = 'hold'
        try:
            result = self.run_radio('off')
            self.assertTrue(self.bus.entered.is_set())
            self.assertEqual(result['error'], 'Uncertain')
            self.assertEqual(self.bus.writes, [('WirelessEnabled', False)])
        finally:
            self.bus.release.set()

    def test_owner_loss_during_write_is_uncertain(self):
        self.bus.mode = 'hold'
        process = subprocess.Popen([BINARY, 'off'], env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=self.bus.address),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertTrue(self.bus.entered.wait(2))
            self.bus.connection.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus',
                                          'org.freedesktop.DBus', 'ReleaseName', GLib.Variant('(s)', (net.NM,)),
                                          None, Gio.DBusCallFlags.NONE, 1000, None)
            self.bus.release.set()
            output, error = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, error)
            self.assertEqual(json.loads(output)['error'], 'Uncertain')
            self.assertEqual(self.bus.writes, [('WirelessEnabled', False)])
        finally:
            self.bus.release.set()
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_scan_only_wifi_once_without_changing_radio(self):
        wired = net.ROOT + '/Devices/2'
        self.bus.register(wired, net.DEV, '', {'DeviceType': ('u', 1)})
        wifi = net.ROOT + '/Devices/1'
        self.bus.props[(net.ROOT, net.NM)]['Devices'] = GLib.Variant('ao', [wifi, wired, wifi])
        self.assertEqual(self.run_radio('scan'), {'ok': True, 'count': 1})
        self.assertEqual(self.bus.scans, [(wifi, ({},))])
        self.assertEqual(self.bus.writes, [])

    def test_scan_empty_foreign_and_limit(self):
        self.bus.props[(net.ROOT, net.NM)]['Devices'] = GLib.Variant('ao', [])
        self.assertEqual(self.run_radio('scan'), {'ok': True, 'count': 0})
        self.bus.props[(net.ROOT, net.NM)]['Devices'] = GLib.Variant('ao', ['/foreign/device'])
        self.assertEqual(self.run_radio('scan')['error'], 'Invalid')
        self.bus.props[(net.ROOT, net.NM)]['Devices'] = GLib.Variant('ao', [net.ROOT + '/Devices/1'] * 65)
        self.assertEqual(self.run_radio('scan')['error'], 'Limit')
        self.assertEqual(self.bus.scans, [])

    def test_scan_rejection_and_timeout_are_not_retried(self):
        self.bus.scan_mode = 'deny'
        self.assertEqual(self.run_radio('scan')['error'], 'Uncertain')
        self.assertEqual(len(self.bus.scans), 1)
        self.bus.scan_mode = 'hold'
        try:
            self.assertEqual(self.run_radio('scan')['error'], 'Uncertain')
            self.assertTrue(self.bus.entered.is_set())
            self.assertEqual(len(self.bus.scans), 2)
        finally:
            self.bus.release.set()

    def test_scan_wrong_owner_never_dispatches(self):
        self.assertEqual(self.run_radio('scan', ':1.999999')['error'], 'OwnerChanged')
        self.assertEqual(self.bus.scans, [])

    def test_scan_partial_failure_is_not_success(self):
        first, second = net.ROOT + '/Devices/1', net.ROOT + '/Devices/2'
        self.bus.register(second, net.DEV, '', {'DeviceType': ('u', 2)})
        self.bus.register(second, net.WIFI, '<method name="RequestScan"><arg type="a{sv}" direction="in"/></method>')
        self.bus.props[(net.ROOT, net.NM)]['Devices'] = GLib.Variant('ao', [first, second])
        self.bus.scan_mode = 'deny-second'
        self.assertEqual(self.run_radio('scan')['error'], 'Uncertain')
        self.assertEqual([entry[0] for entry in self.bus.scans], [first, second])

    def test_scan_owner_loss_during_request_is_uncertain(self):
        self.bus.scan_mode = 'hold'
        process = subprocess.Popen([BINARY, 'scan'], env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=self.bus.address),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertTrue(self.bus.entered.wait(2))
            self.bus.connection.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus',
                                          'org.freedesktop.DBus', 'ReleaseName', GLib.Variant('(s)', (net.NM,)),
                                          None, Gio.DBusCallFlags.NONE, 1000, None)
            self.bus.release.set()
            output, error = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, error)
            self.assertEqual(json.loads(output)['error'], 'Uncertain')
            self.assertEqual(len(self.bus.scans), 1)
        finally:
            self.bus.release.set()
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == '__main__':
    unittest.main()
