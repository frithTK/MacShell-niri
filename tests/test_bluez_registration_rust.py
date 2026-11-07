"""AgentManager registration and BlueZ owner races on a private bus only."""
import json
import os
import queue
import subprocess
import threading
import time
import unittest

from gi.repository import Gio, GLib
from test_dbus_protocol import PrivateBus

BINARY = os.environ.get('MACSHELL_TEST_BLUEZ_REGISTRATION_HARNESS')


class HoldingBus(PrivateBus):
    def __init__(self):
        self.registrations = queue.Queue()
        super().__init__()

    def method(self, bus, sender, path, iface, method, parameters, invocation):
        if iface == 'org.bluez.AgentManager1' and method == 'RegisterAgent':
            self.registrations.put((sender, parameters.unpack(), invocation))
        else:
            super().method(bus, sender, path, iface, method, parameters, invocation)

    def name(self, operation):
        args = GLib.Variant('(su)', ('org.bluez', 0)) if operation == 'RequestName' else GLib.Variant('(s)', ('org.bluez',))
        self.connection.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus',
                                  'org.freedesktop.DBus', operation, args, None,
                                  Gio.DBusCallFlags.NONE, 2000, None)


class Harness:
    def __init__(self, address):
        self.process = subprocess.Popen([BINARY], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True,
                                        env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=address))
        self.messages = queue.Queue()
        self.lines = []
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()
        self.ready = self.wait(lambda message: message.get('type') == 'ready')

    def read(self):
        for line in self.process.stdout:
            self.messages.put(json.loads(line))

    def send(self, action):
        self.process.stdin.write(json.dumps({'action': action}) + '\n')
        self.process.stdin.flush()

    def wait(self, predicate, timeout=4):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                message = self.messages.get(timeout=.1)
            except queue.Empty:
                continue
            self.lines.append(message)
            if predicate(message):
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


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_BLUEZ_REGISTRATION_HARNESS')
class BluezRegistrationTests(unittest.TestCase):
    def setUp(self):
        self.bus = HoldingBus()
        self.harness = Harness(self.bus.address)

    def tearDown(self):
        try:
            self.harness.close()
        finally:
            self.bus.close()

    def registration(self):
        sender, params, invocation = self.bus.registrations.get(timeout=3)
        self.assertEqual(sender, self.harness.ready['unique'])
        self.assertEqual(params, ('/org/macshell/BluetoothAgent', 'KeyboardDisplay'))
        return invocation

    def begin(self):
        self.harness.send('begin')
        return self.harness.wait(lambda message: message.get('type') == 'begin')['ok']

    def test_registration_is_required_and_loss_invalidates_it(self):
        owner = self.harness.wait(lambda message: message.get('type') == 'owner' and message.get('unique'))
        invocation = self.registration()
        self.assertFalse(self.begin())
        invocation.return_value(None)
        registration = self.harness.wait(lambda message: message.get('type') == 'registration')
        self.assertEqual(registration, {'type': 'registration', 'epoch': owner['epoch'], 'success': True})
        self.assertTrue(self.begin())
        self.bus.name('ReleaseName')
        lost = self.harness.wait(lambda message: message.get('type') == 'owner' and message.get('unique') is None)
        self.assertGreater(lost['epoch'], owner['epoch'])
        self.assertFalse(self.begin())

    def test_registration_failure_does_not_enable_pairing(self):
        self.harness.wait(lambda message: message.get('type') == 'owner' and message.get('unique'))
        self.registration().return_dbus_error('org.bluez.Error.Failed', 'synthetic failure')
        result = self.harness.wait(lambda message: message.get('type') == 'registration')
        self.assertFalse(result['success'])
        self.assertFalse(self.begin())

    def test_late_reply_from_previous_owner_epoch_is_ignored(self):
        old = self.harness.wait(lambda message: message.get('type') == 'owner' and message.get('unique'))
        previous = self.registration()
        self.bus.name('ReleaseName')
        self.harness.wait(lambda message: message.get('type') == 'owner' and message.get('unique') is None)
        self.bus.name('RequestName')
        current = self.harness.wait(lambda message: message.get('type') == 'owner' and message.get('unique'))
        self.assertGreater(current['epoch'], old['epoch'])
        pending = self.registration()
        previous.return_value(None)
        # Let the old callback run before checking the agent's availability.
        time.sleep(.1)
        self.assertFalse(self.begin())
        pending.return_value(None)
        result = self.harness.wait(lambda message: message.get('type') == 'registration')
        self.assertEqual(result['epoch'], current['epoch'])
        self.assertTrue(result['success'])
        self.assertTrue(self.begin())

    def test_registration_timeout_does_not_enable_pairing(self):
        self.harness.wait(lambda message: message.get('type') == 'owner' and message.get('unique'))
        pending = self.registration()
        result = self.harness.wait(lambda message: message.get('type') == 'registration', timeout=7)
        self.assertFalse(result['success'])
        self.assertFalse(self.begin())
        pending.return_value(None)

    def test_late_registration_reply_after_host_drop_is_safe(self):
        self.harness.wait(lambda message: message.get('type') == 'owner' and message.get('unique'))
        pending = self.registration()
        self.harness.send('drop')
        self.harness.wait(lambda message: message.get('type') == 'dropped')
        pending.return_value(None)
        time.sleep(.1)
        self.harness.send('ping')
        self.harness.wait(lambda message: message.get('type') == 'pong')
        self.assertFalse(any(message.get('type') == 'registration' for message in self.harness.lines))

    def test_replacement_owner_gets_a_new_registration(self):
        old = self.harness.wait(lambda message: message.get('type') == 'owner' and message.get('unique'))
        previous = self.registration()
        self.bus.name('ReleaseName')
        self.harness.wait(lambda message: message.get('type') == 'owner' and message.get('unique') is None)
        replacement = Gio.DBusConnection.new_for_address_sync(
            self.bus.address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
            None, None)
        xml = ('<node><interface name="org.bluez.AgentManager1"><method name="RegisterAgent">'
               '<arg type="o" direction="in"/><arg type="s" direction="in"/></method></interface></node>')
        def register(bus, sender, path, interface, method, parameters, invocation):
            self.bus.registrations.put((sender, parameters.unpack(), invocation))
        registration = replacement.register_object('/org/bluez', Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], register, None, None)
        try:
            replacement.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                                  'RequestName', GLib.Variant('(su)', ('org.bluez', 0)), None,
                                  Gio.DBusCallFlags.NONE, 2000, None)
            new = self.harness.wait(lambda message: message.get('type') == 'owner' and message.get('unique'))
            self.assertNotEqual(new['unique'], old['unique'])
            current = self.registration()
            previous.return_value(None)
            time.sleep(.1)
            self.assertFalse(self.begin())
            current.return_value(None)
            result = self.harness.wait(lambda message: message.get('type') == 'registration')
            self.assertEqual(result['epoch'], new['epoch'])
            self.assertTrue(result['success'])
            self.assertTrue(self.begin())
        finally:
            replacement.unregister_object(registration)
            replacement.close_sync(None)
