"""Compare Rust ObjectManager decoding with Python using synthetic BlueZ data."""
import json
import os
import subprocess
import unittest

from gi.repository import GLib
from test_dbus_protocol import PrivateBus
import bluetooth_service as bluetooth

BINARY = os.environ.get('MACSHELL_TEST_BLUEZ_SNAPSHOT_HARNESS')
BATTERY = 'org.bluez.Battery1'


class SnapshotBus(PrivateBus):
    def method(self, bus, sender, path, iface, method, parameters, invocation):
        if method == 'GetManagedObjects':
            objects = {}
            for (object_path, interface), props in self.props.items():
                if interface in (bluetooth.ADAPTER, bluetooth.DEVICE, BATTERY):
                    objects.setdefault(object_path, {})[interface] = props
            invocation.return_value(GLib.Variant('(a{oa{sa{sv}}})', (objects,)))
        else:
            super().method(bus, sender, path, iface, method, parameters, invocation)

    def expected(self):
        objects = {}
        for (path, interface), props in self.props.items():
            if interface in (bluetooth.ADAPTER, bluetooth.DEVICE, BATTERY):
                objects.setdefault(path, {})[interface] = {key: value.unpack() for key, value in props.items()}
        return bluetooth.discovered(objects)


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_BLUEZ_SNAPSHOT_HARNESS')
class BluezSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.bus = SnapshotBus()

    def tearDown(self):
        self.bus.close()

    def check_snapshot(self):
        result = subprocess.run([BINARY], env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=self.bus.address),
                                text=True, capture_output=True, timeout=5, check=True)
        self.assertEqual(json.loads(result.stdout), self.bus.expected())

    def test_empty_and_default_objects(self):
        self.bus.props = {key: value for key, value in self.bus.props.items()
                          if key[1] not in (bluetooth.ADAPTER, bluetooth.DEVICE, BATTERY)}
        self.check_snapshot()
        self.bus.props[('/org/bluez/hci0', bluetooth.ADAPTER)] = {}
        self.bus.props[(self.bus.device, bluetooth.DEVICE)] = {'Adapter': GLib.Variant('o', '/org/bluez/hci0')}
        self.check_snapshot()

    def test_multiple_adapters_devices_battery_and_unicode_sort(self):
        bus = self.bus
        bus.props[('/org/bluez/hci1', bluetooth.ADAPTER)] = {
            'Alias': GLib.Variant('s', 'Second'), 'Powered': GLib.Variant('b', False)}
        bus.props[(bus.device, bluetooth.DEVICE)].update({
            'Paired': GLib.Variant('b', True), 'Connected': GLib.Variant('b', True),
            'Alias': GLib.Variant('s', 'z keyboard')})
        bus.props[(bus.device, BATTERY)] = {'Percentage': GLib.Variant('y', 101)}
        for index, (name, connected, paired, adapter, percent) in enumerate([
            ('Straße', False, True, '/org/bluez/hci1', 0),
            ('STRASSE', False, True, '/org/bluez/hci0', 100),
            ('speaker', False, False, '/org/bluez/hci0', 42),
            ('unknown', True, False, '/org/bluez/hci9', 50),
        ]):
            path = f'/org/bluez/hci0/dev_00_00_00_00_00_{index:02X}'
            bus.props[(path, bluetooth.DEVICE)] = {
                'Adapter': GLib.Variant('o', adapter), 'Alias': GLib.Variant('s', name),
                'Connected': GLib.Variant('b', connected), 'Bonded': GLib.Variant('b', paired)}
            bus.props[(path, BATTERY)] = {'Percentage': GLib.Variant('y', percent)}
        self.check_snapshot()

    def test_empty_name_fallback_and_unpaired_connected_device(self):
        props = self.bus.props[(self.bus.device, bluetooth.DEVICE)]
        props['Alias'] = GLib.Variant('s', '')
        props['Name'] = GLib.Variant('s', '')
        props['Address'] = GLib.Variant('s', '')
        props['Connected'] = GLib.Variant('b', True)
        self.check_snapshot()
