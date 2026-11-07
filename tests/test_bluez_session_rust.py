"""Integrated BlueZ session behavior on an isolated, synthetic D-Bus."""
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

BINARY = os.environ.get('MACSHELL_TEST_BLUEZ_SESSION_HARNESS')
AGENT_PATH = '/org/macshell/BluetoothAgent'
OTHER = 'another-client'


class SessionBus(PrivateBus):
    def __init__(self, hold=False):
        self.hold = hold
        self.hold_snapshot = False
        self.hold_start = False
        self.pending = queue.Queue()
        self.reads_count = 0
        self.refs = {OTHER}
        super().__init__()
        self.signal = self.connection.signal_subscribe(
            'org.freedesktop.DBus', 'org.freedesktop.DBus', 'NameOwnerChanged',
            '/org/freedesktop/DBus', None, Gio.DBusSignalFlags.NONE, self.owner_changed)

    def owner_changed(self, bus, sender, path, iface, signal, parameters):
        name, old, new = parameters.unpack()
        if name.startswith(':') and old and not new:
            self.refs.discard(name)

    def method(self, bus, sender, path, iface, method, parameters, invocation):
        if method == 'GetManagedObjects':
            self.reads_count += 1
            if self.hold or self.hold_snapshot:
                self.pending.put((method, invocation))
                return
        if iface == 'org.bluez.AgentManager1' and method == 'RegisterAgent' and self.hold:
            self.pending.put((method, invocation))
            return
        if iface == bluetooth.ADAPTER and method == 'StartDiscovery':
            if self.hold_start:
                self.pending.put((method, invocation))
                return
            self.refs.add(sender)
            invocation.return_value(None)
        elif iface == bluetooth.ADAPTER and method == 'StopDiscovery':
            self.refs.discard(sender)
            invocation.return_value(None)
        else:
            super().method(bus, sender, path, iface, method, parameters, invocation)

    def reply_snapshot(self, invocation):
        objects = {}
        for (path, interface), props in self.props.items():
            if interface in (bluetooth.ADAPTER, bluetooth.DEVICE):
                objects.setdefault(path, {})[interface] = props
        invocation.return_value(GLib.Variant('(a{oa{sa{sv}}})', (objects,)))

    def name(self, method):
        args = GLib.Variant('(su)', ('org.bluez', 0)) if method == 'RequestName' else GLib.Variant('(s)', ('org.bluez',))
        self.connection.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus',
                                  'org.freedesktop.DBus', method, args, None,
                                  Gio.DBusCallFlags.NONE, 2000, None)

    def close(self):
        self.connection.signal_unsubscribe(self.signal)
        super().close()


class Harness:
    def __init__(self, address, environment=None):
        self.process = subprocess.Popen([BINARY], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True,
                                       env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=address, **(environment or {})))
        self.messages = queue.Queue()
        self.backlog = []
        self.all_messages = []
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()
        self.unique = self.wait('ready')['unique']

    def read(self):
        for line in self.process.stdout:
            self.messages.put(json.loads(line))

    def send(self, action, **data):
        self.process.stdin.write(json.dumps({'action': action, **data}) + '\n')
        self.process.stdin.flush()

    def wait(self, kind, predicate=lambda _: True, timeout=4):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for index, message in enumerate(self.backlog):
                if message.get('type') == kind and predicate(message):
                    return self.backlog.pop(index)
            try:
                message = self.messages.get(timeout=.1)
            except queue.Empty:
                continue
            self.all_messages.append(message)
            self.backlog.append(message)
        raise AssertionError('No expected response: ' + repr(self.all_messages[-10:]))

    def close(self):
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass
        self.process.wait(timeout=5)
        self.thread.join(timeout=2)
        error = self.process.stderr.read()
        self.process.stdout.close()
        self.process.stderr.close()
        if error or self.process.returncode:
            raise AssertionError(f'process exit {self.process.returncode}: {error}')


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_BLUEZ_SESSION_HARNESS')
class BluezSessionTests(unittest.TestCase):
    def setUp(self):
        self.bus = SessionBus()
        self.harness = Harness(self.bus.address)

    def tearDown(self):
        try:
            self.harness.close()
        finally:
            self.bus.close()

    def ready(self):
        owner = self.harness.wait('owner', lambda e: e['unique'])
        registration = self.harness.wait('registration')
        snapshot = self.harness.wait('snapshot')
        self.assertEqual(owner['generation'], registration['generation'])
        self.assertEqual(owner['generation'], snapshot['generation'])
        self.assertTrue(registration['success'])
        return owner

    def call_agent(self, connection):
        result = queue.Queue()
        def finished(bus, response):
            try:
                result.put(('ok', bus.call_finish(response).unpack()))
            except GLib.Error as error:
                result.put(('error', str(error)))
        connection.call(self.harness.unique, AGENT_PATH, bluetooth.AGENT, 'RequestConfirmation',
                        GLib.Variant('(ou)', (self.bus.device, 42)), None,
                        Gio.DBusCallFlags.NONE, 4000, None, finished)
        return result

    def test_discovery_and_authorization_share_current_owner(self):
        self.ready()
        self.harness.send('discover')
        self.harness.wait('discovering')
        self.harness.wait('discovery', lambda e: e['owned'] == 1)
        self.assertEqual(self.bus.refs, {OTHER, self.harness.unique})
        self.harness.send('begin', id=71, device=self.bus.device)
        self.harness.wait('begun')
        result = self.call_agent(self.bus.connection)
        prompt = self.harness.wait('prompt')
        self.assertEqual((prompt['request'], prompt['code']), (71, '000042'))
        self.harness.send('respond', prompt=prompt['id'], accept=True)
        self.assertEqual(self.harness.wait('response')['result'], 'Accepted')
        self.assertEqual(result.get(timeout=3), ('ok', ()))
        self.harness.send('stop')
        self.harness.wait('stopping')
        deadline = time.monotonic() + 2
        while self.harness.unique in self.bus.refs and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(self.bus.refs, {OTHER})

    def test_owner_loss_cancels_pending_authorization(self):
        self.ready()
        self.harness.send('begin', id=42, device=self.bus.device)
        self.harness.wait('begun')
        result = self.call_agent(self.bus.connection)
        self.harness.wait('prompt')
        self.bus.name('ReleaseName')
        self.harness.wait('owner', lambda e: e['unique'] is None)
        reset = self.harness.wait('owner-reset', lambda e: e['failed'] == 42)
        self.assertTrue(reset['cancelPrompt'])
        self.assertIn('Canceled', result.get(timeout=3)[1])
        self.harness.send('discover')
        self.assertIn('unavailable', self.harness.wait('command-error')['message'])

    def test_owner_loss_during_discovery_closes_only_our_connection(self):
        self.ready()
        self.harness.send('discover')
        self.harness.wait('discovering')
        self.harness.wait('discovery', lambda e: e['owned'] == 1)
        self.bus.name('ReleaseName')
        self.harness.wait('closed')
        deadline = time.monotonic() + 2
        while self.harness.unique in self.bus.refs and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(self.bus.refs, {OTHER})

    def test_trusted_property_signal_refreshes_but_unknown_sender_does_not(self):
        self.ready()
        attacker = Gio.DBusConnection.new_for_address_sync(
            self.bus.address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
            None, None)
        args = GLib.Variant('(sa{sv}as)', (bluetooth.ADAPTER, {'Alias': GLib.Variant('s', 'Changed')}, []))
        try:
            reads = self.bus.reads_count
            attacker.emit_signal(None, '/org/bluez/hci0', 'org.freedesktop.DBus.Properties', 'PropertiesChanged', args)
            time.sleep(.15)
            self.assertEqual(self.bus.reads_count, reads)
            self.bus.props[('/org/bluez/hci0', bluetooth.ADAPTER)]['Alias'] = GLib.Variant('s', 'Changed')
            self.bus.connection.emit_signal(None, '/org/bluez/hci0', 'org.freedesktop.DBus.Properties', 'PropertiesChanged', args)
            snapshot = self.harness.wait('snapshot', lambda e: e['state']['adapters'][0]['name'] == 'Changed')
            self.assertTrue(snapshot['state']['enabled'])
            self.assertGreater(self.bus.reads_count, reads)
        finally:
            attacker.close_sync(None)

    def test_queued_snapshot_is_discarded_when_owner_disappears(self):
        self.ready()
        self.harness.send('pause-poll')
        self.harness.wait('paused')
        reads = self.bus.reads_count
        self.bus.props[('/org/bluez/hci0', bluetooth.ADAPTER)]['Alias'] = GLib.Variant('s', 'Obsolete')
        self.bus.connection.emit_signal(None, '/org/bluez/hci0', 'org.freedesktop.DBus.Properties',
            'PropertiesChanged', GLib.Variant('(sa{sv}as)', (bluetooth.ADAPTER, {}, [])))
        deadline = time.monotonic() + 2
        while self.bus.reads_count == reads and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertGreater(self.bus.reads_count, reads)
        time.sleep(.1)
        self.bus.name('ReleaseName')
        self.harness.wait('owner', lambda e: e['unique'] is None)
        self.harness.send('resume-poll')
        self.harness.wait('resumed')
        with self.assertRaises(AssertionError):
            self.harness.wait('snapshot', lambda e: e['state']['adapters'][0]['name'] == 'Obsolete', timeout=.25)
        self.bus.props[('/org/bluez/hci0', bluetooth.ADAPTER)]['Alias'] = GLib.Variant('s', 'Current')
        self.bus.name('RequestName')
        self.harness.wait('owner', lambda e: e['unique'])
        self.harness.wait('snapshot', lambda e: e['state']['adapters'][0]['name'] == 'Current')

    def test_close_discards_queued_snapshot_and_cancels_authorization(self):
        self.ready()
        self.bus.hold_start = True
        self.harness.send('discover')
        self.harness.wait('discovering')
        method, start = self.bus.pending.get(timeout=2)
        self.assertEqual(method, 'StartDiscovery')
        self.harness.send('begin', id=91, device=self.bus.device)
        self.harness.wait('begun')
        pending_agent = self.call_agent(self.bus.connection)
        self.harness.wait('prompt')
        self.harness.send('pause-poll')
        self.harness.wait('paused')
        self.bus.hold_snapshot = True
        self.harness.send('refresh')
        self.harness.wait('refreshed')
        method, snapshot = self.bus.pending.get(timeout=2)
        self.assertEqual(method, 'GetManagedObjects')
        self.bus.props[('/org/bluez/hci0', bluetooth.ADAPTER)]['Alias'] = GLib.Variant('s', 'Discarded')
        self.bus.reply_snapshot(snapshot)
        start.return_dbus_error('org.bluez.Error.Failed', 'synthetic failure')
        time.sleep(.1)
        self.harness.send('resume-poll')
        self.harness.wait('resumed')
        reset = self.harness.wait('owner-reset', lambda e: e['failed'] == 91)
        self.assertTrue(reset['cancelPrompt'])
        self.assertIn('Canceled', pending_agent.get(timeout=3)[1])
        self.harness.wait('closed')
        self.assertFalse(any(e.get('type') == 'snapshot' and e['state']['adapters'][0]['name'] == 'Discarded'
                             for e in self.harness.all_messages))


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_BLUEZ_SESSION_HARNESS')
class BluezSessionRaceTests(unittest.TestCase):
    def setUp(self):
        self.bus = SessionBus(hold=True)
        self.harness = Harness(self.bus.address)

    def tearDown(self):
        try:
            self.harness.close()
        finally:
            self.bus.close()

    def requests(self):
        return dict(self.bus.pending.get(timeout=2) for _ in range(2))

    def test_old_snapshot_and_registration_do_not_survive_owner_reappearance(self):
        old_owner = self.harness.wait('owner', lambda e: e['unique'])
        old = self.requests()
        self.bus.name('ReleaseName')
        self.harness.wait('owner', lambda e: e['unique'] is None)
        self.bus.name('RequestName')
        new_owner = self.harness.wait('owner', lambda e: e['unique'] and e['generation'] > old_owner['generation'])
        current = self.requests()
        self.bus.reply_snapshot(old['GetManagedObjects'])
        old['RegisterAgent'].return_value(None)
        time.sleep(.1)
        self.bus.reply_snapshot(current['GetManagedObjects'])
        current['RegisterAgent'].return_value(None)
        snapshot = self.harness.wait('snapshot')
        registration = self.harness.wait('registration')
        self.assertEqual(snapshot['generation'], new_owner['generation'])
        self.assertEqual(registration['generation'], new_owner['generation'])
        self.assertTrue(registration['success'])

    def test_drop_with_pending_requests_does_not_leak_callbacks(self):
        self.harness.wait('owner', lambda e: e['unique'])
        pending = self.requests()
        self.harness.send('drop')
        self.harness.wait('dropped')
        self.bus.reply_snapshot(pending['GetManagedObjects'])
        pending['RegisterAgent'].return_value(None)
        time.sleep(.1)
        self.harness.send('ping')
        self.assertEqual(self.harness.wait('command-error')['message'], 'closed')
        self.assertFalse(any(e.get('type') in ('snapshot', 'registration') for e in self.harness.all_messages))
