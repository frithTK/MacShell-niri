"""End-to-end Rust pairing transport against synthetic BlueZ on a private bus."""
import os
import queue
import time
import unittest

from gi.repository import Gio, GLib
from test_bluez_session_rust import Harness, SessionBus
import bluetooth_service as bluetooth

BINARY = os.environ.get('MACSHELL_TEST_BLUEZ_SESSION_HARNESS')


class PairBus(SessionBus):
    def __init__(self):
        self.trust_mode = 'normal'
        self.trust_sets = 0
        self.pair_calls = 0
        self.connect_calls = 0
        self.cancel_calls = 0
        self.hold_pair = False
        self.pair_without_confirmation = False
        self.pair_error = False
        self.connect_mode = 'normal'
        self.held_pairs = queue.Queue()
        super().__init__()

    def register(self, path, interface, methods, properties=None):
        if interface != bluetooth.DEVICE:
            return super().register(path, interface, methods, properties)
        properties = dict(properties or {})
        properties['Bonded'] = ('b', False)
        self.props[(path, interface)] = {key: GLib.Variant(sig, value) for key, (sig, value) in properties.items()}
        xml = '<node><interface name="' + interface + '">' + methods + ''.join(
            '<property name="' + key + '" type="' + sig + '" access="readwrite"/>'
            for key, (sig, _) in properties.items()) + '</interface></node>'
        def get_prop(bus, sender, object_path, iface, name):
            key = (object_path, iface, name)
            self.reads[key] = self.reads.get(key, 0) + 1
            return self.props[(object_path, iface)][name]
        def set_prop(bus, sender, object_path, iface, name, value):
            if name == 'Trusted':
                self.trust_sets += 1
                if self.trust_mode == 'reject':
                    return False
                if self.trust_mode == 'ignore':
                    return True
            self.props[(object_path, iface)][name] = value
            return True
        self.ids.append(self.connection.register_object(path, Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], self.method, get_prop, set_prop))

    def method(self, bus, sender, path, iface, method, parameters, invocation):
        if iface == bluetooth.DEVICE:
            if method == 'Pair':
                self.pair_calls += 1
                if self.hold_pair:
                    self.held_pairs.put(invocation)
                    return
                if self.pair_error:
                    error = 'org.bluez.Error.InProgress' if self.pair_error == 'in-progress' else 'org.bluez.Error.AuthenticationFailed'
                    invocation.return_dbus_error(error, 'synthetic failure')
                    return
                if self.pair_without_confirmation:
                    invocation.return_value(None)
                    return
            if method == 'CancelPairing':
                self.cancel_calls += 1
                invocation.return_value(None)
                return
            if method == 'Connect':
                self.connect_calls += 1
                if self.connect_mode == 'ignore':
                    invocation.return_value(None)
                    return
                if self.connect_mode == 'already':
                    invocation.return_dbus_error('org.bluez.Error.AlreadyConnected', 'synthetic already connected')
                    return
        super().method(bus, sender, path, iface, method, parameters, invocation)


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_BLUEZ_SESSION_HARNESS')
class BluezPairTests(unittest.TestCase):
    def setUp(self):
        self.bus = PairBus()
        environment = {'MACSHELL_TEST_PAIR_TIMEOUT_MS': '500'} if self._testMethodName == 'test_local_pair_timeout_cancels_ongoing_operation' else None
        self.harness = Harness(self.bus.address, environment=environment)
        self.harness.wait('owner', lambda value: value['unique'])
        self.assertTrue(self.harness.wait('registration')['success'])
        self.harness.wait('snapshot')

    def tearDown(self):
        try:
            self.harness.close()
        finally:
            self.bus.close()

    def pair(self, request=7):
        self.harness.send('pair', id=request, device=self.bus.device)
        self.harness.wait('pair-started')

    def accept(self):
        prompt = self.harness.wait('prompt')
        self.assertEqual(prompt['code'], '000042')
        self.harness.send('respond', prompt=prompt['id'], accept=True)
        self.harness.wait('response')

    def result(self, request=7):
        return self.harness.wait('pair-result', lambda value: value['id'] == request)

    def prop(self, name):
        return self.bus.props[(self.bus.device, bluetooth.DEVICE)][name].unpack()

    def wait_canceled(self):
        deadline = time.monotonic() + 2
        while not self.bus.cancel_calls and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertGreater(self.bus.cancel_calls, 0)

    def test_pair_prompt_verify_trust_connect_and_confirm(self):
        self.pair()
        self.accept()
        result = self.result()
        self.assertTrue(result['success'])
        self.assertEqual(result['phase'], 'connected')
        self.assertTrue(self.prop('Paired'))
        self.assertTrue(self.prop('Trusted'))
        self.assertTrue(self.prop('Connected'))
        self.assertEqual((self.bus.pair_calls, self.bus.trust_sets, self.bus.connect_calls), (1, 1, 1))

    def test_pair_reply_without_paired_state_never_trusts(self):
        self.bus.pair_without_confirmation = True
        self.pair()
        result = self.result()
        self.assertFalse(result['success'])
        self.assertIn('did not confirm pairing', result['error'])
        self.assertEqual((self.bus.trust_sets, self.bus.connect_calls), (0, 0))

    def test_pair_error_never_trusts(self):
        self.bus.pair_error = True
        self.pair()
        result = self.result()
        self.assertFalse(result['success'])
        self.assertIn('AuthenticationFailed', result['error'])
        self.assertEqual((self.bus.trust_sets, self.bus.connect_calls), (0, 0))

    def test_other_clients_in_progress_pair_is_not_canceled(self):
        self.bus.pair_error = 'in-progress'
        self.pair()
        result = self.result()
        self.assertFalse(result['success'])
        self.assertIn('InProgress', result['error'])
        time.sleep(.1)
        self.assertEqual(self.bus.cancel_calls, 0)

    def test_existing_pair_is_verified_without_repeating_pair(self):
        self.bus.props[(self.bus.device, bluetooth.DEVICE)]['Paired'] = GLib.Variant('b', True)
        self.pair()
        self.assertTrue(self.result()['success'])
        self.assertEqual((self.bus.pair_calls, self.bus.trust_sets, self.bus.connect_calls), (0, 1, 1))

    def test_bonded_state_is_accepted_without_repeating_pair(self):
        self.bus.props[(self.bus.device, bluetooth.DEVICE)]['Bonded'] = GLib.Variant('b', True)
        self.pair()
        self.assertTrue(self.result()['success'])
        self.assertEqual((self.bus.pair_calls, self.bus.trust_sets, self.bus.connect_calls), (0, 1, 1))

    def test_connect_reply_without_connected_state_fails(self):
        self.bus.connect_mode = 'ignore'
        self.pair()
        self.accept()
        result = self.result()
        self.assertFalse(result['success'])
        self.assertEqual(result['phase'], 'paired')
        self.assertIn('did not confirm connection', result['error'])

    def test_already_connected_error_is_checked_against_device_state(self):
        self.bus.props[(self.bus.device, bluetooth.DEVICE)]['Paired'] = GLib.Variant('b', True)
        self.bus.props[(self.bus.device, bluetooth.DEVICE)]['Connected'] = GLib.Variant('b', True)
        self.bus.connect_mode = 'already'
        self.pair()
        self.assertTrue(self.result()['success'])

    def test_already_connected_error_without_connected_state_fails(self):
        self.bus.props[(self.bus.device, bluetooth.DEVICE)]['Paired'] = GLib.Variant('b', True)
        self.bus.connect_mode = 'already'
        self.pair()
        result = self.result()
        self.assertFalse(result['success'])
        self.assertEqual(result['phase'], 'paired')

    def test_unconfirmed_trust_never_connects(self):
        self.bus.trust_mode = 'ignore'
        self.pair()
        self.accept()
        result = self.result()
        self.assertFalse(result['success'])
        self.assertEqual(result['phase'], 'paired')
        self.assertFalse(self.prop('Trusted'))
        self.assertEqual(self.bus.connect_calls, 0)

    def test_trust_rejection_never_connects(self):
        self.bus.trust_mode = 'reject'
        self.pair()
        self.accept()
        result = self.result()
        self.assertFalse(result['success'])
        self.assertEqual(result['phase'], 'paired')
        self.assertEqual(self.bus.connect_calls, 0)

    def test_user_cancel_during_prompt_cancels_pairing(self):
        self.pair()
        self.harness.wait('prompt')
        self.harness.send('cancel', id=7)
        self.harness.wait('cancel-command')
        result = self.result()
        self.assertTrue(result['success'])
        self.assertEqual(result['phase'], 'canceled')
        self.wait_canceled()
        self.assertEqual((self.bus.trust_sets, self.bus.connect_calls), (0, 0))

    def test_rejected_prompt_cancels_pairing(self):
        self.pair()
        prompt = self.harness.wait('prompt')
        self.harness.send('respond', prompt=prompt['id'], accept=False)
        self.harness.wait('response')
        self.assertEqual(self.result()['phase'], 'canceled')
        self.wait_canceled()
        self.assertEqual((self.bus.trust_sets, self.bus.connect_calls), (0, 0))

    def test_deadline_cancels_pending_pairing(self):
        self.pair()
        self.harness.wait('prompt')
        self.harness.send('tick', now=65001)
        self.harness.wait('ticked')
        self.assertEqual(self.result()['phase'], 'canceled')
        self.harness.wait('error', lambda value: 'timed out' in value['message'])
        self.wait_canceled()

    def test_local_pair_timeout_cancels_ongoing_operation(self):
        self.bus.hold_pair = True
        self.pair()
        pending = self.bus.held_pairs.get(timeout=2)
        result = self.result()
        self.assertFalse(result['success'])
        self.assertIn('tim', result['error'].lower())
        self.wait_canceled()
        pending.return_value(None)
        time.sleep(.1)
        self.assertEqual((self.bus.trust_sets, self.bus.connect_calls), (0, 0))

    def test_session_drop_cancels_inflight_pair(self):
        self.pair()
        self.harness.wait('prompt')
        self.harness.send('drop')
        self.harness.wait('dropped')
        self.wait_canceled()
        self.assertEqual((self.bus.trust_sets, self.bus.connect_calls), (0, 0))

    def test_owner_disappearance_fails_once_without_trust(self):
        self.pair()
        self.harness.wait('prompt')
        self.bus.name('ReleaseName')
        result = self.result()
        self.assertFalse(result['success'])
        self.assertIn('disappeared', result['error'])
        self.assertEqual((self.bus.trust_sets, self.bus.connect_calls), (0, 0))

    def test_late_pair_reply_does_not_advance_reused_request_id(self):
        self.bus.hold_pair = True
        self.pair()
        previous = self.bus.held_pairs.get(timeout=2)
        self.harness.send('cancel', id=7)
        self.harness.wait('cancel-command')
        self.assertEqual(self.result()['phase'], 'canceled')
        self.pair()
        current = self.bus.held_pairs.get(timeout=2)
        previous.return_value(None)
        time.sleep(.1)
        self.assertEqual((self.bus.trust_sets, self.bus.connect_calls), (0, 0))
        self.bus.props[(self.bus.device, bluetooth.DEVICE)]['Paired'] = GLib.Variant('b', True)
        current.return_value(None)
        self.assertTrue(self.result()['success'])
        self.assertEqual((self.bus.trust_sets, self.bus.connect_calls), (1, 1))
