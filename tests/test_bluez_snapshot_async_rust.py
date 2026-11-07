"""Exercise async snapshot reads and stale replies on an isolated D-Bus."""
import json
import os
import queue
import subprocess
import threading
import time
import unittest

from gi.repository import Gio, GLib
from test_dbus_protocol import PrivateBus
import bluetooth_service as bluetooth

BINARY = os.environ.get('MACSHELL_TEST_BLUEZ_ASYNC_HARNESS')


class HoldingBus(PrivateBus):
    def __init__(self):
        self.requests = queue.Queue()
        super().__init__()

    def method(self, bus, sender, path, iface, method, parameters, invocation):
        if iface == 'org.freedesktop.DBus.ObjectManager' and method == 'GetManagedObjects':
            self.requests.put(invocation)
        else:
            super().method(bus, sender, path, iface, method, parameters, invocation)

    def reply(self, invocation):
        objects = {}
        for (path, interface), props in self.props.items():
            if interface in (bluetooth.ADAPTER, bluetooth.DEVICE, bluetooth.BATTERY):
                objects.setdefault(path, {})[interface] = props
        invocation.return_value(GLib.Variant('(a{oa{sa{sv}}})', (objects,)))


class Harness:
    def __init__(self, address):
        self.process = subprocess.Popen([BINARY], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True,
                                       env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=address))
        self.messages = queue.Queue()
        self.lines = []
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()
        self.wait('ready')

    def read(self):
        for line in self.process.stdout:
            self.messages.put(json.loads(line))

    def send(self, action, **params):
        self.process.stdin.write(json.dumps({'action': action, **params}) + '\n')
        self.process.stdin.flush()

    def wait(self, kind, timeout=4):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                message = self.messages.get(timeout=.1)
            except queue.Empty:
                continue
            self.lines.append(message)
            if message.get('type') == kind:
                return message
        raise AssertionError('No expected response: ' + repr(self.lines[-8:]))

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=5)
        self.thread.join(timeout=2)
        error = self.process.stderr.read()
        self.process.stdout.close()
        self.process.stderr.close()
        if error:
            raise AssertionError(error)


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_BLUEZ_ASYNC_HARNESS')
class BluezSnapshotAsyncTests(unittest.TestCase):
    def setUp(self):
        self.bus = HoldingBus()
        self.harness = Harness(self.bus.address)
        self.owner = self.bus.connection.get_unique_name()

    def tearDown(self):
        try:
            self.harness.close()
        finally:
            self.bus.close()

    def set_owner(self, owner):
        self.harness.send('owner', owner=owner)
        return self.harness.wait('owner')['epoch']

    def refresh(self):
        self.harness.send('refresh')
        return self.harness.wait('refresh')['result']

    def test_refresh_coalesces_and_reads_latest_snapshot(self):
        epoch = self.set_owner(self.owner)
        self.assertEqual(self.refresh(), 'Started')
        first = self.bus.requests.get(timeout=2)
        self.assertEqual(self.refresh(), 'Coalesced')
        self.assertEqual(self.refresh(), 'Coalesced')
        self.assertTrue(self.bus.requests.empty())
        self.bus.reply(first)
        state = self.harness.wait('snapshot')
        self.assertEqual(state['epoch'], epoch)
        self.assertEqual(state['state']['adapters'][0]['name'], 'Adapter')
        second = self.bus.requests.get(timeout=2)
        self.bus.props[('/org/bluez/hci0', bluetooth.ADAPTER)]['Alias'] = GLib.Variant('s', 'Updated')
        self.bus.reply(second)
        state = self.harness.wait('snapshot')
        self.assertEqual(state['state']['adapters'][0]['name'], 'Updated')
        self.assertTrue(self.bus.requests.empty())

    def test_owner_epoch_discards_old_response_even_if_unique_name_reused(self):
        old_epoch = self.set_owner(self.owner)
        self.refresh()
        old = self.bus.requests.get(timeout=2)
        self.set_owner(None)
        new_epoch = self.set_owner(self.owner)
        self.assertGreater(new_epoch, old_epoch)
        self.refresh()
        current = self.bus.requests.get(timeout=2)
        self.bus.reply(old)
        time.sleep(.1)
        self.bus.reply(current)
        snapshot = self.harness.wait('snapshot')
        self.assertEqual(snapshot['epoch'], new_epoch)
        self.assertFalse(any(m.get('type') == 'snapshot' and m.get('epoch') == old_epoch for m in self.harness.lines))

    def test_reply_from_replaced_unique_owner_is_discarded(self):
        old_epoch = self.set_owner(self.owner)
        self.refresh()
        old = self.bus.requests.get(timeout=2)
        self.bus.connection.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus',
                                      'org.freedesktop.DBus', 'ReleaseName',
                                      GLib.Variant('(s)', ('org.bluez',)), None,
                                      Gio.DBusCallFlags.NONE, 2000, None)
        replacement = Gio.DBusConnection.new_for_address_sync(
            self.bus.address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
            None, None)
        xml = ('<node><interface name="org.freedesktop.DBus.ObjectManager">'
               '<method name="GetManagedObjects"><arg type="a{oa{sa{sv}}}" direction="out"/>'
               '</method></interface></node>')
        def handle(bus, sender, path, interface, method, parameters, invocation):
            self.bus.requests.put(invocation)
        registration = replacement.register_object('/', Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], handle, None, None)
        try:
            replacement.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus',
                                  'org.freedesktop.DBus', 'RequestName',
                                  GLib.Variant('(su)', ('org.bluez', 0)), None,
                                  Gio.DBusCallFlags.NONE, 2000, None)
            self.set_owner(None)
            new_epoch = self.set_owner(replacement.get_unique_name())
            self.refresh()
            current = self.bus.requests.get(timeout=2)
            self.bus.reply(old)
            time.sleep(.1)
            self.bus.reply(current)
            self.assertEqual(self.harness.wait('snapshot')['epoch'], new_epoch)
            self.assertFalse(any(m.get('type') == 'snapshot' and m.get('epoch') == old_epoch for m in self.harness.lines))
        finally:
            replacement.unregister_object(registration)
            replacement.close_sync(None)

    def test_error_and_coalesced_retry(self):
        epoch = self.set_owner(self.owner)
        self.refresh()
        pending = self.bus.requests.get(timeout=2)
        self.assertEqual(self.refresh(), 'Coalesced')
        pending.return_dbus_error('org.bluez.Error.Failed', 'synthetic failure')
        error = self.harness.wait('snapshot-error')
        self.assertEqual(error['epoch'], epoch)
        self.assertIn('synthetic failure', error['message'])
        followup = self.bus.requests.get(timeout=2)
        self.bus.reply(followup)
        self.assertEqual(self.harness.wait('snapshot')['epoch'], epoch)

    def test_timeout_and_late_reply(self):
        epoch = self.set_owner(self.owner)
        self.refresh()
        pending = self.bus.requests.get(timeout=2)
        error = self.harness.wait('snapshot-error', timeout=5)
        self.assertEqual(error['epoch'], epoch)
        self.assertTrue(error['message'])
        self.bus.reply(pending)
        self.assertEqual(self.refresh(), 'Started')
        self.bus.reply(self.bus.requests.get(timeout=2))
        self.assertEqual(self.harness.wait('snapshot')['epoch'], epoch)

    def test_invalid_owner_and_disappearance_fail_closed(self):
        self.harness.send('refresh')
        self.assertIn('unavailable', self.harness.wait('error')['message'])
        for invalid in ('org.bluez', ':', ':1.2\u0000bad'):
            self.harness.send('owner', owner=invalid)
            self.assertIn('Invalid', self.harness.wait('error')['message'])
        self.set_owner(self.owner)
        self.set_owner(None)
        self.harness.send('refresh')
        self.assertIn('unavailable', self.harness.wait('error')['message'])

    def test_drop_with_pending_call_is_safe(self):
        self.set_owner(self.owner)
        self.refresh()
        pending = self.bus.requests.get(timeout=2)
        self.harness.send('drop')
        self.harness.wait('dropped')
        self.bus.reply(pending)
        time.sleep(.1)
        self.harness.send('ping')
        self.harness.wait('pong')
        self.assertFalse(any(m.get('type') in ('snapshot', 'snapshot-error') for m in self.harness.lines))
