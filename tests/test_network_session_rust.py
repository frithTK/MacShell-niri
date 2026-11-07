"""Combined NetworkManager session on a private synthetic D-Bus only."""
import os
import queue
import time
import unittest

from gi.repository import Gio, GLib
from test_network_activate_rust import ActivationBus
from test_network_agent_rust import Harness, PATH, IFACE, PROFILE, SETTING
import network_control as net

BINARY = os.environ.get('MACSHELL_TEST_NETWORK_SESSION_HARNESS')
NEW_UUID = 'd4ac1208-0a7b-4012-8abc-381d6ca41234'


class HoldingBus(ActivationBus):
    def __init__(self):
        self.activation = None
        self.is_new = False
        self.disconnects = []
        self.deactivations = []
        self.cancel_mode = 'complete'
        self.hold_list = False
        self.list_invocation = None
        self.list_calls = 0
        super().__init__()

    def method(self, bus, sender, path, iface, method, parameters, invocation):
        if method == 'ListConnections':
            self.list_calls += 1
            if self.hold_list:
                self.list_invocation = invocation
            else:
                super().method(bus, sender, path, iface, method, parameters, invocation)
        elif method == 'Disconnect' and iface == net.DEV:
            self.disconnects.append(path)
            invocation.return_value(None)
        elif method == 'DeactivateConnection':
            self.deactivations.append(parameters.unpack()[0])
            if self.cancel_mode == 'deny':
                invocation.return_dbus_error(net.NM + '.Error.Failed', 'synthetic refusal')
            else:
                if self.cancel_mode == 'complete':
                    self.props[(self.active_path, net.ACTIVE)]['State'] = GLib.Variant('u', 4)
                invocation.return_value(None)
        elif method in ('ActivateConnection', 'AddAndActivateConnection2'):
            self.is_new = method == 'AddAndActivateConnection2'
            self.calls.append(parameters.unpack())
            self.activation = invocation
            self.entered.set()
        else:
            super().method(bus, sender, path, iface, method, parameters, invocation)

    def release_activation(self):
        invocation, self.activation = self.activation, None
        if invocation:
            reply = GLib.Variant('(ooa{sv})', (self.profile, self.active_path, {})) if self.is_new else GLib.Variant('(o)', (self.active_path,))
            GLib.idle_add(lambda: (invocation.return_value(reply), False)[1])

    def release_list(self):
        invocation, self.list_invocation = self.list_invocation, None
        self.hold_list = False
        if invocation:
            reply = GLib.Variant('(ao)', ([self.profile] if self.settings else [],))
            GLib.idle_add(lambda: (invocation.return_value(reply), False)[1])

    def close(self):
        self.release_activation()
        self.release_list()
        super().close()


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_NETWORK_SESSION_HARNESS')
class NetworkSessionTests(unittest.TestCase):
    def setUp(self):
        self.bus = HoldingBus()
        self.harness = Harness(self.bus.address, binary=BINARY)
        self.harness.wait('owner', lambda event: event['unique'])
        self.assertTrue(self.harness.wait('registration')['success'])

    def tearDown(self):
        try:
            self.bus.release_activation()
            self.harness.close()
        finally:
            self.bus.close()

    def request_secret(self, uuid='test-id'):
        result = queue.Queue()
        def done(bus, reply):
            try:
                result.put(('ok', bus.call_finish(reply).unpack()))
            except GLib.Error as error:
                result.put(('error', str(error)))
        settings = {'connection': {'uuid': GLib.Variant('s', uuid)}}
        self.bus.connection.call(self.harness.ready['unique'], PATH, IFACE, 'GetSecrets',
            GLib.Variant('(a{sa{sv}}osasu)', (settings, PROFILE, SETTING, [], 1)),
            None, Gio.DBusCallFlags.NONE, 4000, None, done)
        return result

    def test_snapshot_and_activation_share_owner_and_secret_agent(self):
        self.harness.send('refresh')
        self.assertTrue(self.harness.wait('refresh')['ok'])
        state = self.harness.wait('snapshot')['state']
        self.assertEqual(state['networks'][0]['uuid'], 'test-id')
        self.harness.send('begin')
        self.harness.wait('begun')
        self.assertTrue(self.bus.entered.wait(3))
        pending = self.request_secret()
        prompt = self.harness.wait('need')
        self.harness.send('reply', delivery=prompt['delivery'], password='synthetic-only')
        self.assertTrue(self.harness.wait('reply')['accepted'])
        self.assertEqual(pending.get(timeout=3), ('ok', ({SETTING: {'psk': 'synthetic-only'}},)))
        self.bus.release_activation()
        self.assertIn('Observe', self.harness.wait('activation')['action'])
        self.assertEqual(len(self.bus.calls), 1)
        self.assertNotIn('synthetic-only', repr(self.harness.seen))

    def test_cancel_rejects_password_and_waits_for_late_activation(self):
        self.bus.cancel_mode = 'deny'
        self.harness.send('begin')
        self.harness.wait('begun')
        self.assertTrue(self.bus.entered.wait(3))
        pending = self.request_secret()
        prompt = self.harness.wait('need')
        self.harness.send('cancel')
        self.assertEqual(self.harness.wait('cancel')['action'], 'Wait')
        self.assertIn('UserCanceled', pending.get(timeout=3)[1])
        self.harness.send('reply', delivery=prompt['delivery'], password='synthetic-only')
        self.assertFalse(self.harness.wait('reply')['accepted'])
        self.bus.release_activation()
        self.assertIn('InspectForCancel', self.harness.wait('activation')['action'])
        self.assertEqual(self.harness.wait('activation', lambda e: e['action'] == 'CloseUncertain', timeout=7)['action'], 'CloseUncertain')
        self.assertEqual(len(self.bus.calls), 1)

    def test_owner_loss_clears_prompt_and_closes_session(self):
        self.harness.send('begin')
        self.harness.wait('begun')
        self.assertTrue(self.bus.entered.wait(3))
        pending = self.request_secret()
        self.harness.wait('need')
        self.bus.connection.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus',
            'org.freedesktop.DBus', 'ReleaseName', GLib.Variant('(s)', (net.NM,)),
            None, Gio.DBusCallFlags.NONE, 1000, None)
        self.harness.wait('close')
        self.assertIn('AgentCanceled', pending.get(timeout=3)[1])
        self.harness.send('begin')
        self.assertIn('unavailable', self.harness.wait('error')['error'])

    def test_new_profile_cancellation_rejects_secret_before_late_reply(self):
        self.bus.cancel_mode = 'deny'
        self.bus.settings = None
        self.harness.send('create')
        self.harness.wait('begun')
        self.assertTrue(self.bus.entered.wait(3))
        pending = self.request_secret(NEW_UUID)
        self.harness.wait('need')
        self.harness.send('cancel')
        self.assertEqual(self.harness.wait('cancel')['action'], 'Wait')
        self.assertIn('UserCanceled', pending.get(timeout=3)[1])
        self.bus.release_activation()
        self.assertIn('InspectForCancel', self.harness.wait('activation')['action'])
        self.harness.wait('activation', lambda e: e['action'] == 'CloseUncertain', timeout=7)
        self.assertEqual(len(self.bus.calls), 1)
        self.assertEqual(self.bus.calls[0][0]['connection']['uuid'], NEW_UUID)

    def test_connected_only_after_inspecting_active_state(self):
        self.harness.send('begin')
        self.harness.wait('begun')
        self.assertTrue(self.bus.entered.wait(3))
        self.bus.props[(self.bus.active_path, net.ACTIVE)]['State'] = GLib.Variant('u', 2)
        self.bus.release_activation()
        self.harness.wait('activation', lambda e: e['action'].startswith('Observe'))
        self.harness.wait('activation', lambda e: e['action'] == 'Connected')

    def test_scan_is_serialized_with_activation(self):
        self.harness.send('scan')
        self.harness.wait('scan_started')
        radio = self.harness.wait('radio')
        self.assertEqual(radio['result'], 'Ok(1)')
        self.harness.send('begin')
        self.harness.wait('begun')
        self.assertTrue(self.bus.entered.wait(3))
        self.harness.send('scan')
        self.assertIn('already in progress', self.harness.wait('error')['error'])
        self.assertEqual(len(self.bus.calls), 1)

    def test_cancel_after_start_inspects_without_disconnect(self):
        self.bus.cancel_mode = 'deny'
        self.harness.send('begin')
        self.harness.wait('begun')
        self.assertTrue(self.bus.entered.wait(3))
        self.bus.release_activation()
        self.harness.wait('activation', lambda e: e['action'].startswith('Observe'))
        self.harness.send('cancel')
        self.assertIn('InspectForCancel', self.harness.wait('cancel')['action'])
        self.harness.wait('activation', lambda e: e['action'] == 'CloseUncertain', timeout=7)
        self.assertEqual(len(self.bus.calls), 1)

    def test_disconnect_only_selected_active_access_point(self):
        self.harness.send('disconnect')
        self.harness.wait('disconnect_started')
        self.assertEqual(self.harness.wait('radio')['result'], 'Err(Stale)')
        self.assertEqual(self.bus.disconnects, [])
        self.bus.props[(net.ROOT + '/Devices/1', net.WIFI)]['ActiveAccessPoint'] = GLib.Variant('o', self.bus.ap)
        self.harness.send('disconnect')
        self.harness.wait('disconnect_started')
        self.assertEqual(self.harness.wait('radio')['result'], 'Ok(0)')
        self.assertEqual(self.bus.disconnects, [net.ROOT + '/Devices/1'])

    def test_refresh_requests_coalesce_without_starving_snapshot(self):
        self.bus.hold_list = True
        self.harness.send('refresh')
        self.assertTrue(self.harness.wait('refresh')['ok'])
        deadline = time.monotonic() + 3
        while self.bus.list_invocation is None and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertIsNotNone(self.bus.list_invocation)
        self.harness.send('refresh')
        self.harness.send('refresh')
        self.assertTrue(self.harness.wait('refresh')['ok'])
        self.assertTrue(self.harness.wait('refresh')['ok'])
        self.bus.release_list()
        self.harness.wait('snapshot')
        self.harness.wait('snapshot')
        self.assertEqual(self.bus.list_calls, 2)


if __name__ == '__main__':
    unittest.main()
