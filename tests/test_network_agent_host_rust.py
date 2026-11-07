"""NetworkManager agent registration and owner changes on a private bus."""
import os
import queue
import subprocess
import threading
import time
import unittest

from gi.repository import Gio, GLib
from test_dbus_protocol import PrivateBus
from test_network_agent_rust import Harness, PATH, IFACE, PROFILE, SETTING
import network_control as net

BINARY = os.environ.get('MACSHELL_TEST_NETWORK_AGENT_HOST_HARNESS')


class RegistrationBus(PrivateBus):
    def __init__(self, mode='normal'):
        self.mode = mode
        self.entered = threading.Event()
        self.pending = None
        self.register_calls = 0
        super().__init__()

    def method(self, bus, sender, path, iface, method, parameters, invocation):
        if method == 'Register':
            self.register_calls += 1
            self.entered.set()
            if self.mode == 'hold':
                self.pending = invocation
                return
            if self.mode == 'deny':
                invocation.return_dbus_error('org.freedesktop.NetworkManager.AgentManager.PermissionDenied', 'Denied')
                return
        super().method(bus, sender, path, iface, method, parameters, invocation)

    def release_registration(self):
        invocation, self.pending = self.pending, None
        GLib.idle_add(lambda: (invocation.return_value(None), False)[1])

    def lose_owner(self):
        self.connection.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                                  'ReleaseName', GLib.Variant('(s)', (net.NM,)), None, Gio.DBusCallFlags.NONE, 1000, None)


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_NETWORK_AGENT_HOST_HARNESS')
class NetworkAgentHostRustTests(unittest.TestCase):
    def setUp(self):
        self.bus = None
        self.harness = None

    def tearDown(self):
        try:
            if self.harness:
                self.harness.close()
        finally:
            if self.bus:
                self.bus.close()

    def start(self, mode='normal', timeout=5000):
        self.bus = RegistrationBus(mode)
        self.harness = Harness(self.bus.address, binary=BINARY,
                               environment={'MACSHELL_TEST_NM_REGISTER_TIMEOUT': str(timeout)})

    def begin(self, request=7):
        self.harness.send('begin', id=request, uuid='test-uuid', profile=PROFILE)

    def get_secrets(self):
        result = queue.Queue()
        def done(bus, reply):
            try:
                result.put(('ok', bus.call_finish(reply).unpack()))
            except GLib.Error as error:
                result.put(('error', str(error)))
        settings = {'connection': {'uuid': GLib.Variant('s', 'test-uuid')}}
        self.bus.connection.call(self.harness.ready['unique'], PATH, IFACE, 'GetSecrets',
                                 GLib.Variant('(a{sa{sv}}osasu)', (settings, PROFILE, SETTING, [], 1)),
                                 None, Gio.DBusCallFlags.NONE, 4000, None, done)
        return result

    def test_registration_and_secret_request(self):
        self.start()
        owner = self.harness.wait('owner', lambda event: event['unique'])
        registration = self.harness.wait('registration')
        self.assertTrue(registration['success'])
        self.assertEqual(registration['epoch'], owner['epoch'])
        self.assertIn('wifi', self.bus.agents)
        self.begin()
        self.harness.wait('begun')
        result = self.get_secrets()
        prompt = self.harness.wait('need')
        self.harness.send('reply', delivery=prompt['delivery'], password='synthetic-only')
        self.assertTrue(self.harness.wait('reply')['accepted'])
        self.assertEqual(result.get(timeout=3), ('ok', ({SETTING: {'psk': 'synthetic-only'}},)))

    def test_explicit_registration_rejection_keeps_agent_unavailable(self):
        self.start(mode='deny')
        self.assertFalse(self.harness.wait('registration')['success'])
        self.begin()
        self.assertIn('unavailable', self.harness.wait('error')['error'])
        self.assertFalse(any(event.get('type') == 'close' for event in self.harness.seen))

    def test_timeout_requires_connection_close_and_ignores_late_reply(self):
        self.start(mode='hold', timeout=200)
        self.assertTrue(self.bus.entered.wait(2))
        self.harness.wait('close')
        self.bus.release_registration()
        time.sleep(.1)
        self.begin()
        self.assertIn('unavailable', self.harness.wait('error')['error'])
        self.assertFalse(any(event.get('type') == 'registration' and event['success'] for event in self.harness.seen))

    def test_owner_loss_during_registration_requires_close(self):
        self.start(mode='hold')
        self.assertTrue(self.bus.entered.wait(2))
        self.bus.lose_owner()
        self.harness.wait('close')
        self.bus.release_registration()
        self.begin()
        self.assertIn('unavailable', self.harness.wait('error')['error'])

    def test_owner_loss_cancels_active_prompt_and_identifies_operation(self):
        self.start()
        self.assertTrue(self.harness.wait('registration')['success'])
        self.begin()
        self.harness.wait('begun')
        pending = self.get_secrets()
        prompt = self.harness.wait('need')
        self.bus.lose_owner()
        owner = self.harness.wait('owner', lambda event: event['unique'] is None and event['abandoned'] == 7)
        self.assertEqual(owner['abandoned'], 7)
        self.harness.wait('close')
        self.assertIn('AgentCanceled', pending.get(timeout=3)[1])
        self.harness.send('reply', delivery=prompt['delivery'], password='synthetic')
        self.assertFalse(self.harness.wait('reply')['accepted'])

    def test_same_unique_owner_reacquisition_never_reuses_registration(self):
        self.start()
        self.assertTrue(self.harness.wait('registration')['success'])
        self.bus.lose_owner()
        self.harness.wait('close')
        self.bus.connection.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                                      'RequestName', GLib.Variant('(su)', (net.NM, 0)), None,
                                      Gio.DBusCallFlags.NONE, 1000, None)
        time.sleep(.1)
        self.begin()
        self.assertIn('unavailable', self.harness.wait('error')['error'])
        self.assertEqual(self.bus.register_calls, 1)

    def test_private_bus_is_mandatory(self):
        environment = dict(os.environ)
        environment.pop('DBUS_SYSTEM_BUS_ADDRESS', None)
        result = subprocess.run([BINARY], env=environment, capture_output=True, text=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
