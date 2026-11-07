"""Multi-adapter power operations against a private synthetic BlueZ bus."""
import os
import queue
import threading
import time
import unittest

from gi.repository import Gio, GLib
from test_bluez_session_rust import Harness, SessionBus, OTHER
import bluetooth_service as bluetooth

BINARY = os.environ.get('MACSHELL_TEST_BLUEZ_SESSION_HARNESS')
A = '/org/bluez/hci0'
B = '/org/bluez/hci1'


class PowerBus(SessionBus):
    def __init__(self, missing_power=False):
        self.set_calls = []
        self.modes = {}
        self.set_entered = threading.Event()
        self.release_set = threading.Event()
        self.hold_stop = False
        self.hold_start = False
        self.starts = queue.Queue()
        self.stops = queue.Queue()
        super().__init__()
        second = {'Alias': ('s', 'Second')}
        if not missing_power:
            second['Powered'] = ('b', False)
        self.register(B, bluetooth.ADAPTER, '<method name="StartDiscovery"/><method name="StopDiscovery"/>', second)

    def register(self, path, interface, methods, properties=None):
        if interface != bluetooth.ADAPTER:
            return super().register(path, interface, methods, properties)
        properties = properties or {}
        self.props[(path, interface)] = {key: GLib.Variant(sig, value) for key, (sig, value) in properties.items()}
        xml = '<node><interface name="' + interface + '">' + methods + ''.join(
            '<property name="' + key + '" type="' + sig + '" access="readwrite"/>'
            for key, (sig, _) in properties.items()) + '</interface></node>'
        def get_prop(bus, sender, object_path, iface, name):
            key = (object_path, iface, name)
            self.reads[key] = self.reads.get(key, 0) + 1
            return self.props[(object_path, iface)][name]
        def set_prop(bus, sender, object_path, iface, name, value):
            if name == 'Powered':
                self.set_calls.append((object_path, value.unpack()))
                mode = self.modes.get(object_path, 'normal')
                if mode == 'hold':
                    self.set_entered.set()
                    self.release_set.wait(timeout=3)
                if mode == 'reject':
                    return False
                if mode == 'ignore':
                    return True
            self.props[(object_path, iface)][name] = value
            return True
        self.ids.append(self.connection.register_object(path, Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], self.method, get_prop, set_prop))

    def method(self, bus, sender, path, iface, method, parameters, invocation):
        if iface == bluetooth.ADAPTER and method == 'StartDiscovery' and self.hold_start:
            self.starts.put((sender, invocation))
            return
        if iface == bluetooth.ADAPTER and method == 'StopDiscovery' and self.hold_stop:
            self.stops.put((sender, invocation))
            return
        super().method(bus, sender, path, iface, method, parameters, invocation)

    def finish_stop(self):
        sender, invocation = self.stops.get(timeout=2)
        self.refs.discard(sender)
        invocation.return_value(None)

    def finish_start(self):
        sender, invocation = self.starts.get(timeout=2)
        self.refs.add(sender)
        invocation.return_value(None)


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_BLUEZ_SESSION_HARNESS')
class BluezPowerTests(unittest.TestCase):
    def setUp(self):
        self.bus = PowerBus(missing_power=self._testMethodName == 'test_invalid_preflight_prevents_all_writes')
        if self._testMethodName == 'test_no_adapters_completes_without_changes':
            self.bus.props = {key: value for key, value in self.bus.props.items() if key[1] != bluetooth.ADAPTER}
        if self._testMethodName == 'test_invalid_adapter_path_is_rejected':
            self.bus.props[('/org/bluez/rogue', bluetooth.ADAPTER)] = {'Powered': GLib.Variant('b', True)}
        radio_mode = 'deny' if self._testMethodName == 'test_radio_failure_prevents_power_write' else 'ok'
        self.harness = Harness(self.bus.address, {'MACSHELL_TEST_RADIO': radio_mode})
        self.harness.wait('owner', lambda value: value['unique'])
        self.assertTrue(self.harness.wait('registration')['success'])
        self.harness.wait('snapshot')

    def tearDown(self):
        self.bus.release_set.set()
        try:
            self.harness.close()
        finally:
            self.bus.close()

    def power(self, enabled, request=10):
        self.harness.send('power', id=request, enabled=enabled)
        self.harness.wait('power-started')

    def result(self, request=10):
        return self.harness.wait('power-result', lambda value: value['id'] == request)

    def enabled(self, path):
        return self.bus.props[(path, bluetooth.ADAPTER)]['Powered'].unpack()

    def test_changes_and_verifies_only_needed_adapters(self):
        self.power(False)
        self.assertTrue(self.result()['success'])
        self.assertFalse(self.enabled(A))
        self.assertFalse(self.enabled(B))
        self.assertEqual(self.bus.set_calls, [(A, False)])
        self.power(True, request=11)
        self.assertTrue(self.result(11)['success'])
        self.assertTrue(self.enabled(A))
        self.assertTrue(self.enabled(B))
        self.assertEqual(set(self.bus.set_calls[1:]), {(A, True), (B, True)})

    def test_radio_unblocks_only_on_enable_before_power_write(self):
        self.power(False)
        self.assertTrue(self.result()['success'])
        self.assertFalse(any(m.get('type') == 'radio-unblock' for m in self.harness.all_messages))
        self.bus.set_calls.clear()
        self.power(True, request=11)
        self.harness.wait('radio-unblock')
        self.assertTrue(self.result(11)['success'])
        self.assertEqual(set(self.bus.set_calls), {(A, True), (B, True)})

    def test_radio_failure_prevents_power_write(self):
        self.bus.props[(A, bluetooth.ADAPTER)]['Powered'] = GLib.Variant('b', False)
        self.power(True)
        self.harness.wait('radio-unblock')
        result = self.result()
        self.assertFalse(result['success'])
        self.assertIn('Synthetic radio denial', result['error'])
        self.assertEqual(self.bus.set_calls, [])

    def test_set_reply_without_power_change_fails(self):
        self.bus.modes[A] = 'ignore'
        self.power(False)
        result = self.result()
        self.assertFalse(result['success'])
        self.assertIn('did not confirm', result['error'])
        self.assertTrue(self.enabled(A))

    def test_set_rejection_is_reported(self):
        self.bus.modes[A] = 'reject'
        self.power(False)
        self.assertFalse(self.result()['success'])
        self.assertTrue(self.enabled(A))

    def test_invalid_preflight_prevents_all_writes(self):
        self.power(False)
        result = self.result()
        self.assertFalse(result['success'])
        self.assertIn('Invalid Bluetooth adapter state', result['error'])
        self.assertEqual(self.bus.set_calls, [])
        self.assertTrue(self.enabled(A))

    def test_stop_own_discovery_finishes_before_power_write(self):
        self.harness.send('discover')
        self.harness.wait('discovering')
        self.harness.wait('discovery', lambda event: event['owned'] == 1)
        self.bus.hold_stop = True
        self.power(False)
        time.sleep(.1)
        self.assertEqual(self.bus.set_calls, [])
        self.assertEqual(self.bus.refs, {OTHER, self.harness.unique})
        self.bus.finish_stop()
        self.assertTrue(self.result()['success'])
        self.assertEqual(self.bus.refs, {OTHER})
        self.assertFalse(self.enabled(A))

    def test_power_waits_for_late_discovery_start_and_stop(self):
        self.bus.hold_start = True
        self.bus.hold_stop = True
        self.harness.send('discover')
        self.harness.wait('discovering')
        self.power(False)
        time.sleep(.1)
        self.assertEqual(self.bus.set_calls, [])
        self.bus.finish_start()
        time.sleep(.1)
        self.assertEqual(self.bus.set_calls, [])
        self.bus.finish_stop()
        self.assertTrue(self.result()['success'])
        self.assertEqual(self.bus.refs, {OTHER})

    def test_discovery_start_failure_closes_without_power_write(self):
        self.bus.hold_start = True
        self.harness.send('discover')
        self.harness.wait('discovering')
        self.power(False)
        _, pending = self.bus.starts.get(timeout=2)
        pending.return_dbus_error('org.bluez.Error.Failed', 'synthetic failure')
        self.assertFalse(self.result()['success'])
        self.harness.wait('closed')
        self.assertEqual(self.bus.set_calls, [])

    def test_discovery_stop_failure_closes_without_power_write(self):
        self.harness.send('discover')
        self.harness.wait('discovering')
        self.harness.wait('discovery', lambda event: event['owned'] == 1)
        self.bus.hold_stop = True
        self.power(False)
        _, pending = self.bus.stops.get(timeout=2)
        pending.return_dbus_error('org.bluez.Error.Failed', 'synthetic failure')
        self.assertFalse(self.result()['success'])
        self.harness.wait('closed')
        self.assertEqual(self.bus.set_calls, [])

    def test_cancel_while_waiting_for_discovery_does_not_write(self):
        self.harness.send('discover')
        self.harness.wait('discovering')
        self.harness.wait('discovery', lambda event: event['owned'] == 1)
        self.bus.hold_stop = True
        self.power(False)
        self.harness.send('cancel', id=10)
        self.harness.wait('cancel-command')
        self.assertEqual(self.result()['phase'], 'canceled')
        self.bus.finish_stop()
        time.sleep(.1)
        self.assertEqual(self.bus.set_calls, [])
        self.assertTrue(self.enabled(A))

    def test_cancel_during_dispatched_write_closes_connection(self):
        self.bus.modes[A] = 'hold'
        self.power(False)
        self.assertTrue(self.bus.set_entered.wait(timeout=2))
        self.harness.send('cancel', id=10)
        self.harness.wait('cancel-command')
        self.assertEqual(self.result()['phase'], 'canceled')
        self.harness.wait('closed')
        self.bus.release_set.set()

    def test_owner_loss_during_dispatched_write_closes_connection(self):
        self.bus.modes[A] = 'hold'
        self.power(False)
        self.assertTrue(self.bus.set_entered.wait(timeout=2))
        self.bus.name('ReleaseName')
        self.assertFalse(self.result()['success'])
        self.harness.wait('closed')
        self.bus.release_set.set()

    def test_timeout_waiting_for_discovery_does_not_write(self):
        self.harness.send('discover')
        self.harness.wait('discovering')
        self.harness.wait('discovery', lambda event: event['owned'] == 1)
        self.bus.hold_stop = True
        self.power(False)
        self.harness.send('tick', now=20001)
        self.harness.wait('ticked')
        result = self.result()
        self.assertFalse(result['success'])
        self.assertIn('timed out', result['error'])
        self.bus.finish_stop()
        time.sleep(.1)
        self.assertEqual(self.bus.set_calls, [])

    def test_timeout_during_dispatched_write_closes_connection(self):
        self.bus.modes[A] = 'hold'
        self.power(False)
        self.assertTrue(self.bus.set_entered.wait(timeout=2))
        self.harness.send('tick', now=20001)
        self.harness.wait('ticked')
        result = self.result()
        self.assertFalse(result['success'])
        self.assertIn('timed out', result['error'])
        self.harness.wait('closed')
        self.bus.release_set.set()

    def test_no_adapters_completes_without_changes(self):
        self.power(True)
        self.assertTrue(self.result()['success'])
        self.assertEqual(self.bus.set_calls, [])

    def test_invalid_adapter_path_is_rejected(self):
        self.power(False)
        self.assertIn('Invalid Bluetooth adapter', self.result()['error'])
        self.assertEqual(self.bus.set_calls, [])

    def test_inventory_is_refreshed_before_power_changes(self):
        path = '/org/bluez/hci2'
        self.bus.register(path, bluetooth.ADAPTER, '<method name="StartDiscovery"/><method name="StopDiscovery"/>',
                          {'Powered': ('b', True), 'Alias': ('s', 'New')})
        self.power(False)
        self.assertTrue(self.result()['success'])
        self.assertFalse(self.enabled(path))
        self.assertEqual(set(self.bus.set_calls), {(A, False), (path, False)})

    def test_partial_failure_is_not_reported_as_success(self):
        self.bus.props[(B, bluetooth.ADAPTER)]['Powered'] = GLib.Variant('b', True)
        self.bus.modes[A] = 'ignore'
        self.power(False)
        self.assertFalse(self.result()['success'])
        self.assertTrue(self.enabled(A))

    def test_power_and_device_operations_are_serialized(self):
        self.bus.modes[A] = 'hold'
        self.power(False)
        self.assertTrue(self.bus.set_entered.wait(timeout=2))
        self.harness.send('connect', id=12, device=self.bus.device)
        self.assertIn('current Bluetooth operation', self.harness.wait('command-error')['message'])
        self.harness.send('discover')
        self.assertIn('current Bluetooth operation', self.harness.wait('command-error')['message'])
        self.bus.release_set.set()
        self.assertTrue(self.result()['success'])
