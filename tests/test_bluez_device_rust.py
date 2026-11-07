"""Direct device connect/disconnect on a synthetic private BlueZ bus."""
import os
import queue
import time
import unittest

from gi.repository import GLib
from test_bluez_pair_rust import PairBus
from test_bluez_session_rust import Harness
import bluetooth_service as bluetooth

BINARY = os.environ.get('MACSHELL_TEST_BLUEZ_SESSION_HARNESS')


class DeviceBus(PairBus):
    def __init__(self, missing_connected=False):
        self.missing_connected = missing_connected
        self.device_mode = 'normal'
        self.device_calls = []
        self.held_devices = queue.Queue()
        super().__init__()

    def register(self, path, interface, methods, properties=None):
        if interface == bluetooth.DEVICE and self.missing_connected:
            properties = dict(properties or {})
            properties.pop('Connected', None)
        return super().register(path, interface, methods, properties)

    def method(self, bus, sender, path, iface, method, parameters, invocation):
        if iface == bluetooth.DEVICE and method in ('Connect', 'Disconnect'):
            self.device_calls.append(method)
            if self.device_mode == 'hold':
                self.held_devices.put((method, invocation))
                return
            if self.device_mode == 'ignore':
                invocation.return_value(None)
                return
            if self.device_mode == 'already':
                name = 'AlreadyConnected' if method == 'Connect' else 'NotConnected'
                invocation.return_dbus_error('org.bluez.Error.' + name, 'synthetic result')
                return
            if self.device_mode == 'error':
                invocation.return_dbus_error('org.bluez.Error.Failed', 'synthetic failure')
                return
        super().method(bus, sender, path, iface, method, parameters, invocation)


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_BLUEZ_SESSION_HARNESS')
class BluezDeviceTests(unittest.TestCase):
    def setUp(self):
        self.bus = DeviceBus(missing_connected=self._testMethodName == 'test_missing_connected_property_is_not_success')
        environment = {'MACSHELL_TEST_DEVICE_TIMEOUT_MS': '500'} if self._testMethodName.startswith('test_local_timeout_') else None
        self.harness = Harness(self.bus.address, environment=environment)
        self.harness.wait('owner', lambda e: e['unique'])
        self.assertTrue(self.harness.wait('registration')['success'])
        self.harness.wait('snapshot')

    def tearDown(self):
        try:
            self.harness.close()
        finally:
            self.bus.close()

    def start(self, action, request=3, path=None):
        self.harness.send(action, id=request, device=self.bus.device if path is None else path)
        return self.harness.wait('device-started')

    def result(self, request=3):
        return self.harness.wait('device-result', lambda value: value['id'] == request)

    def connected(self, value):
        self.bus.props[(self.bus.device, bluetooth.DEVICE)]['Connected'] = GLib.Variant('b', value)

    def test_connect_then_disconnect_confirm_actual_state(self):
        self.start('connect')
        self.assertTrue(self.result()['success'])
        self.assertTrue(self.bus.props[(self.bus.device, bluetooth.DEVICE)]['Connected'].unpack())
        self.start('disconnect', request=4)
        self.assertTrue(self.result(4)['success'])
        self.assertFalse(self.bus.props[(self.bus.device, bluetooth.DEVICE)]['Connected'].unpack())
        self.assertEqual(self.bus.device_calls, ['Connect', 'Disconnect'])

    def test_method_success_without_state_change_is_failure(self):
        self.bus.device_mode = 'ignore'
        self.start('connect')
        result = self.result()
        self.assertFalse(result['success'])
        self.assertIn('did not confirm', result['error'])
        self.connected(True)
        self.start('disconnect', request=4)
        self.assertFalse(self.result(4)['success'])

    def test_already_connected_and_not_connected_require_confirmation(self):
        self.bus.device_mode = 'already'
        self.connected(True)
        self.start('connect')
        self.assertTrue(self.result()['success'])
        self.connected(False)
        self.start('disconnect', request=4)
        self.assertTrue(self.result(4)['success'])
        self.start('connect', request=5)
        self.assertFalse(self.result(5)['success'])
        self.connected(True)
        self.start('disconnect', request=6)
        self.assertFalse(self.result(6)['success'])

    def test_remote_error_is_reported(self):
        self.bus.device_mode = 'error'
        self.start('connect')
        result = self.result()
        self.assertFalse(result['success'])
        self.assertIn('synthetic failure', result['error'])

    def test_invalid_path_does_not_call_device(self):
        self.harness.send('connect', id=3, device='/org/bluez/hci0/dev_bad')
        self.assertIn('Invalid Bluetooth device', self.harness.wait('command-error')['message'])
        self.assertEqual(self.bus.device_calls, [])

    def test_missing_connected_property_is_not_success(self):
        self.start('disconnect')
        result = self.result()
        self.assertFalse(result['success'])
        self.assertIn('Invalid Bluetooth device state', result['error'])
        self.assertEqual(self.bus.device_calls, [])

    def test_wrong_cancel_is_ignored_and_correct_cancel_completes_once(self):
        self.bus.device_mode = 'hold'
        self.start('connect')
        method, pending = self.bus.held_devices.get(timeout=2)
        self.assertEqual(method, 'Connect')
        self.harness.send('cancel', id=99)
        self.harness.wait('cancel-command')
        with self.assertRaises(AssertionError):
            self.harness.wait('device-result', timeout=.15)
        self.harness.send('cancel', id=3)
        self.harness.wait('cancel-command')
        self.assertEqual(self.result()['phase'], 'canceled')
        pending.return_value(None)
        time.sleep(.1)
        self.assertEqual(self.bus.device_calls, ['Connect'])

    def test_timeout_ignores_late_response(self):
        self.bus.device_mode = 'hold'
        self.start('connect')
        _, pending = self.bus.held_devices.get(timeout=2)
        self.harness.send('tick', now=30001)
        self.harness.wait('ticked')
        result = self.result()
        self.assertFalse(result['success'])
        self.assertIn('timed out', result['error'])
        pending.return_value(None)
        time.sleep(.1)
        self.assertEqual(self.bus.device_calls, ['Connect'])

    def test_local_timeout_rechecks_state_before_failing(self):
        self.bus.device_mode = 'hold'
        self.start('connect')
        _, pending = self.bus.held_devices.get(timeout=2)
        result = self.result()
        self.assertFalse(result['success'])
        self.assertIn('did not confirm', result['error'])
        pending.return_value(None)

    def test_local_timeout_succeeds_if_requested_state_was_reached(self):
        self.bus.device_mode = 'hold'
        self.start('connect')
        _, pending = self.bus.held_devices.get(timeout=2)
        self.connected(True)
        self.assertTrue(self.result()['success'])
        pending.return_value(None)

    def test_stale_completion_cannot_advance_reused_request(self):
        self.bus.device_mode = 'hold'
        self.start('connect')
        _, previous = self.bus.held_devices.get(timeout=2)
        self.harness.send('cancel', id=3)
        self.harness.wait('cancel-command')
        self.assertEqual(self.result()['phase'], 'canceled')
        self.start('disconnect')
        _, current = self.bus.held_devices.get(timeout=2)
        key = (self.bus.device, bluetooth.DEVICE, 'Connected')
        reads = self.bus.reads[key]
        previous.return_value(None)
        time.sleep(.1)
        self.assertEqual(self.bus.reads[key], reads)
        self.connected(False)
        current.return_value(None)
        self.assertTrue(self.result()['success'])

    def test_owner_loss_fails_inflight_operation(self):
        self.bus.device_mode = 'hold'
        self.start('connect')
        _, pending = self.bus.held_devices.get(timeout=2)
        self.bus.name('ReleaseName')
        result = self.result()
        self.assertFalse(result['success'])
        self.assertIn('disappeared', result['error'])
        pending.return_value(None)

    def test_pairing_and_direct_operations_are_serialized(self):
        self.bus.device_mode = 'hold'
        self.start('connect')
        _, pending = self.bus.held_devices.get(timeout=2)
        self.harness.send('pair', id=4, device=self.bus.device)
        self.assertIn('current Bluetooth operation', self.harness.wait('command-error')['message'])
        self.harness.send('cancel', id=3)
        self.harness.wait('cancel-command')
        self.result()
        pending.return_value(None)
        self.bus.hold_pair = True
        self.harness.send('pair', id=4, device=self.bus.device)
        self.harness.wait('pair-started')
        pair = self.bus.held_pairs.get(timeout=2)
        self.harness.send('disconnect', id=5, device=self.bus.device)
        self.assertIn('current Bluetooth operation', self.harness.wait('command-error')['message'])
        self.harness.send('cancel', id=4)
        self.harness.wait('cancel-command')
        self.harness.wait('pair-result', lambda value: value['id'] == 4)
        pair.return_value(None)

    def test_low_level_authorization_and_device_operation_are_serialized(self):
        self.harness.send('begin', id=4, device=self.bus.device)
        self.harness.wait('begun')
        self.harness.send('connect', id=5, device=self.bus.device)
        self.assertIn('current Bluetooth operation', self.harness.wait('command-error')['message'])
        self.harness.send('cancel', id=4)
        self.harness.wait('cancel-command')
        self.start('connect', request=5)
        self.assertTrue(self.result(5)['success'])
