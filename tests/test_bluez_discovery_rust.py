"""Discovery transport ownership and uncertain operations on a private bus."""
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

BINARY = os.environ.get('MACSHELL_TEST_BLUEZ_DISCOVERY_HARNESS')
A = '/org/bluez/hci0'
B = '/org/bluez/hci1'
OTHER = 'other-client'


class DiscoveryBus(PrivateBus):
    def __init__(self):
        self.requests = queue.Queue()
        self.refs = {A: {OTHER}, B: {OTHER}}
        super().__init__()
        self.register(B, bluetooth.ADAPTER, '<method name="StartDiscovery"/><method name="StopDiscovery"/>',
                      {'Powered': ('b', True), 'Alias': ('s', 'Second')})
        self.signal = self.connection.signal_subscribe(
            'org.freedesktop.DBus', 'org.freedesktop.DBus', 'NameOwnerChanged',
            '/org/freedesktop/DBus', None, Gio.DBusSignalFlags.NONE, self.owner_changed)

    def owner_changed(self, bus, sender, path, iface, signal, parameters):
        name, old, new = parameters.unpack()
        if name.startswith(':') and old and not new:
            for refs in self.refs.values():
                refs.discard(name)

    def method(self, bus, sender, path, iface, method, parameters, invocation):
        if iface == bluetooth.ADAPTER and method in ('StartDiscovery', 'StopDiscovery'):
            self.requests.put((method, path, sender, invocation))
        else:
            super().method(bus, sender, path, iface, method, parameters, invocation)

    def finish(self, request):
        method, path, sender, invocation = request
        if method == 'StartDiscovery':
            self.refs[path].add(sender)
        else:
            self.refs[path].discard(sender)
        invocation.return_value(None)

    def close(self):
        self.connection.signal_unsubscribe(self.signal)
        super().close()


class Harness:
    def __init__(self, address):
        self.process = subprocess.Popen([BINARY], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True,
                                       env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=address))
        self.messages = queue.Queue()
        self.lines = []
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()
        self.unique = self.wait('ready')['unique']

    def read(self):
        for line in self.process.stdout:
            self.messages.put(json.loads(line))

    def send(self, action, **params):
        self.process.stdin.write(json.dumps({'action': action, **params}) + '\n')
        self.process.stdin.flush()

    def wait(self, kind, predicate=lambda _: True, timeout=4):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                message = self.messages.get(timeout=.1)
            except queue.Empty:
                continue
            self.lines.append(message)
            if message.get('type') == kind and predicate(message):
                return message
        raise AssertionError('No expected response: ' + repr(self.lines[-8:]))

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=5)
        self.thread.join(timeout=2)
        error = self.process.stderr.read()
        self.process.stdout.close()
        self.process.stderr.close()
        if error or self.process.returncode:
            raise AssertionError(f'process exit {self.process.returncode}: {error}')


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_BLUEZ_DISCOVERY_HARNESS')
class BluezDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.bus = DiscoveryBus()
        self.harness = Harness(self.bus.address)
        self.harness.send('owner', owner=self.bus.connection.get_unique_name())
        self.harness.wait('owner')

    def tearDown(self):
        try:
            self.harness.close()
        finally:
            self.bus.close()

    def start(self, adapters=((A, True),)):
        self.harness.send('start', adapters=adapters)
        self.harness.wait('started')

    def request(self, method=None):
        request = self.bus.requests.get(timeout=2)
        if method:
            self.assertEqual(request[0], method)
        self.assertEqual(request[2], self.harness.unique)
        return request

    def wait_released(self, path=A):
        deadline = time.monotonic() + 2
        while self.harness.unique in self.bus.refs[path] and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(self.bus.refs[path], {OTHER})

    def test_cancel_during_start_stops_only_our_late_reference(self):
        self.start()
        start = self.request('StartDiscovery')
        self.harness.send('stop')
        self.harness.wait('stopping')
        self.assertTrue(self.bus.requests.empty())
        self.bus.finish(start)
        stop = self.request('StopDiscovery')
        self.bus.finish(stop)
        self.harness.wait('state', lambda value: value['owned'] == 0)
        self.assertEqual(self.bus.refs[A], {OTHER})

    def test_change_enabled_adapters_releases_old_and_starts_new(self):
        self.start(((A, True), (B, False)))
        self.bus.finish(self.request('StartDiscovery'))
        self.harness.wait('state', lambda value: value['owned'] == 1)
        self.start(((A, False), (B, True)))
        requests = [self.request(), self.request()]
        self.assertEqual({(request[0], request[1]) for request in requests}, {('StopDiscovery', A), ('StartDiscovery', B)})
        for request in requests:
            self.bus.finish(request)
        deadline = time.monotonic() + 2
        while self.bus.refs[B] != {OTHER, self.harness.unique} and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(self.bus.refs[A], {OTHER})
        self.assertEqual(self.bus.refs[B], {OTHER, self.harness.unique})
        self.harness.send('stop')
        self.harness.wait('stopping')
        self.bus.finish(self.request('StopDiscovery'))
        self.wait_released(B)

    def test_unknown_start_result_closes_connection_and_releases_own_reference(self):
        self.start()
        pending = self.request('StartDiscovery')
        self.bus.refs[A].add(self.harness.unique)  # Fake daemon processed it but withheld its reply.
        self.harness.wait('discovery-error', timeout=5)
        self.assertTrue(self.harness.wait('closed')['ok'])
        self.wait_released()
        pending[3].return_value(None)

    def test_stop_failure_closes_connection(self):
        self.start()
        self.bus.finish(self.request('StartDiscovery'))
        self.harness.wait('state', lambda value: value['owned'] == 1)
        self.harness.send('stop')
        self.harness.wait('stopping')
        pending = self.request('StopDiscovery')
        pending[3].return_dbus_error('org.bluez.Error.Failed', 'synthetic failure')
        self.harness.wait('discovery-error')
        self.assertTrue(self.harness.wait('closed')['ok'])
        self.wait_released()

    def test_owner_loss_with_inflight_start_closes_connection(self):
        self.start()
        pending = self.request('StartDiscovery')
        self.bus.refs[A].add(self.harness.unique)
        self.harness.send('owner', owner=None)
        self.harness.wait('owner')
        self.assertTrue(self.harness.wait('closed')['ok'])
        self.wait_released()
        pending[3].return_value(None)

    def test_drop_with_owned_discovery_closes_connection(self):
        self.start()
        self.bus.finish(self.request('StartDiscovery'))
        self.harness.wait('state', lambda value: value['owned'] == 1)
        self.harness.send('drop')
        self.harness.wait('dropped')
        self.assertTrue(self.harness.wait('closed')['ok'])
        self.wait_released()

    def test_discovery_deadline_releases_owned_reference(self):
        self.start()
        self.bus.finish(self.request('StartDiscovery'))
        self.harness.wait('state', lambda value: value['owned'] == 1)
        self.harness.send('tick', now=30001)
        self.harness.wait('ticked')
        self.bus.finish(self.request('StopDiscovery'))
        self.wait_released()

    def test_failure_on_one_adapter_releases_all_our_references(self):
        self.start(((A, True), (B, True)))
        requests = [self.request('StartDiscovery'), self.request('StartDiscovery')]
        for _, path, _, _ in requests:
            self.bus.refs[path].add(self.harness.unique)
        requests[0][3].return_dbus_error('org.bluez.Error.Failed', 'synthetic failure')
        self.harness.wait('discovery-error')
        self.assertTrue(self.harness.wait('closed')['ok'])
        self.wait_released(A)
        self.wait_released(B)
        requests[1][3].return_value(None)
