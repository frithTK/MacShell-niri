"""NetworkManager SecretAgent on a private bus, with synthetic secrets only."""
import json
import os
import queue
import subprocess
import threading
import time
import unittest

from gi.repository import Gio, GLib
from test_dbus_protocol import PrivateBus

BINARY = os.environ.get('MACSHELL_TEST_NETWORK_AGENT_HARNESS')
PATH = '/org/freedesktop/NetworkManager/SecretAgent'
IFACE = 'org.freedesktop.NetworkManager.SecretAgent'
PROFILE = '/org/freedesktop/NetworkManager/Settings/1'
OTHER = '/org/freedesktop/NetworkManager/Settings/2'
SETTING = '802-11-wireless-security'


class Harness:
    def __init__(self, address, binary=None, environment=None):
        self.process = subprocess.Popen([binary or BINARY], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True,
                                        env=dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=address, **(environment or {})))
        self.queue = queue.Queue()
        self.backlog = []
        self.seen = []
        def read():
            for line in self.process.stdout:
                self.queue.put(json.loads(line))
        self.thread = threading.Thread(target=read, daemon=True)
        self.thread.start()
        self.ready = self.wait('ready')

    def send(self, action, **values):
        self.process.stdin.write(json.dumps({'action': action, **values}) + '\n')
        self.process.stdin.flush()

    def wait(self, kind, predicate=lambda _: True, timeout=4):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for index, value in enumerate(self.backlog):
                if value.get('type') == kind and predicate(value):
                    return self.backlog.pop(index)
            try:
                value = self.queue.get(timeout=.1)
            except queue.Empty:
                continue
            self.seen.append(value)
            self.backlog.append(value)
        raise AssertionError('No expected event: ' + repr(self.seen[-8:]))

    def close(self):
        if not self.process.stdin.closed:
            self.process.stdin.close()
        self.process.wait(timeout=5)
        self.thread.join(timeout=2)
        error = self.process.stderr.read()
        self.process.stdout.close()
        self.process.stderr.close()
        if error or self.process.returncode:
            raise AssertionError(f'agent exit {self.process.returncode}: {error}')


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_NETWORK_AGENT_HARNESS')
class NetworkAgentRustTests(unittest.TestCase):
    def setUp(self):
        self.bus = PrivateBus()
        self.harness = Harness(self.bus.address)

    def tearDown(self):
        try:
            self.harness.close()
        finally:
            self.bus.close()

    def begin(self, request=7, uuid='test-uuid', profile=PROFILE, provided=False):
        self.harness.send('begin', id=request, uuid=uuid, profile=profile, provided=provided)
        self.harness.wait('begun')

    def call(self, connection, method, signature, args):
        finished = queue.Queue()
        def done(bus, result):
            try:
                finished.put(('ok', bus.call_finish(result).unpack()))
            except GLib.Error as error:
                finished.put(('error', str(error)))
        connection.call(self.harness.ready['unique'], PATH, IFACE, method,
                        GLib.Variant(signature, args), None, Gio.DBusCallFlags.NONE, 4000, None, done)
        return finished

    def secrets(self, connection=None, uuid='test-uuid', path=PROFILE, setting=SETTING, flags=1):
        settings = {'connection': {'uuid': GLib.Variant('s', uuid)}}
        return self.call(connection or self.bus.connection, 'GetSecrets', '(a{sa{sv}}osasu)',
                         (settings, path, setting, [], flags))

    def reply(self, delivery, password='synthetic-password', **options):
        self.harness.send('reply', delivery=delivery, password=password, **options)
        return self.harness.wait('reply')

    def test_initial_secret_and_prompt_never_appear_in_events(self):
        self.begin(provided=True)
        pending = self.secrets(flags=0)
        event = self.harness.wait('need')
        self.assertTrue(event['provided'])
        self.assertEqual(event['request'], 7)
        self.assertFalse(self.reply(event['delivery'] + 1)['accepted'])
        self.assertTrue(pending.empty())
        self.harness.send('reply', delivery=event['delivery'], password='\0invalid')
        self.harness.wait('error')
        self.assertTrue(pending.empty())
        self.assertTrue(self.reply(event['delivery'], 'synthetic-secret-42')['accepted'])
        value = pending.get(timeout=3)
        self.assertEqual(value, ('ok', ({SETTING: {'psk': 'synthetic-secret-42'}},)))
        self.assertNotIn('synthetic-secret-42', json.dumps(self.harness.seen))
        second = self.secrets(flags=1)
        prompt = self.harness.wait('need', lambda m: m['delivery'] != event['delivery'])
        self.assertFalse(prompt['provided'])
        self.assertTrue(self.reply(prompt['delivery'], 'new-synthetic-secret')['accepted'])
        self.assertEqual(second.get(timeout=3), ('ok', ({SETTING: {'psk': 'new-synthetic-secret'}},)))

    def test_attacker_wrong_identity_and_interaction_flags_are_rejected(self):
        self.begin(provided=False)
        attacker = Gio.DBusConnection.new_for_address_sync(self.bus.address,
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        try:
            calls = [(dict(connection=attacker), 'NotAuthorized'),
                     (dict(uuid='wrong'), 'NoSecrets'), (dict(path=OTHER), 'NoSecrets'),
                     (dict(setting='802-1x'), 'NoSecrets'), (dict(flags=0), 'NoSecrets'),
                     (dict(flags=0x80000001), 'NoSecrets')]
            for arguments, code in calls:
                result = self.secrets(**arguments).get(timeout=3)
                self.assertEqual(result[0], 'error')
                self.assertIn(code, result[1])
            self.assertFalse(any(message.get('type') == 'need' for message in self.harness.seen))
        finally:
            attacker.close_sync(None)

    def test_request_new_does_not_return_previously_provided_password(self):
        self.begin(provided=True)
        pending = self.secrets(flags=2)
        event = self.harness.wait('need')
        self.assertFalse(event['provided'])
        self.assertTrue(event['discard'])
        self.assertTrue(self.reply(event['delivery'], 'fresh-test-password')['accepted'])
        self.assertEqual(pending.get(timeout=3)[1][0][SETTING]['psk'], 'fresh-test-password')

    def test_cancel_is_owner_and_profile_scoped(self):
        self.begin()
        pending = self.secrets()
        event = self.harness.wait('need')
        duplicate = self.secrets().get(timeout=3)
        self.assertIn('NoSecrets', duplicate[1])
        other = self.call(self.bus.connection, 'CancelGetSecrets', '(os)', (OTHER, SETTING))
        self.assertEqual(other.get(timeout=3), ('ok', ()))
        self.assertTrue(pending.empty())
        attacker = Gio.DBusConnection.new_for_address_sync(self.bus.address,
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        try:
            denied = self.call(attacker, 'CancelGetSecrets', '(os)', (PROFILE, SETTING)).get(timeout=3)
            self.assertIn('NotAuthorized', denied[1])
            self.assertTrue(pending.empty())
        finally:
            attacker.close_sync(None)
        cancel = self.call(self.bus.connection, 'CancelGetSecrets', '(os)', (PROFILE, SETTING))
        self.assertEqual(cancel.get(timeout=3), ('ok', ()))
        self.assertIn('AgentCanceled', pending.get(timeout=3)[1])
        self.assertEqual(self.harness.wait('canceled')['delivery'], event['delivery'])
        self.assertFalse(self.reply(event['delivery'])['accepted'])

    def test_owner_reset_cancels_initial_and_rejects_stale_replies(self):
        self.begin(provided=True)
        pending = self.secrets(flags=0)
        first = self.harness.wait('need')
        self.harness.send('reset', owner=self.harness.ready['owner'])
        reset = self.harness.wait('reset')
        self.assertEqual(reset['request'], 7)
        self.assertIn('AgentCanceled', pending.get(timeout=3)[1])
        self.harness.send('register', epoch=self.harness.ready['epoch'])
        self.assertFalse(self.harness.wait('registered')['accepted'])
        self.harness.send('register', epoch=reset['epoch'])
        self.assertTrue(self.harness.wait('registered')['accepted'])
        self.begin(request=7)
        pending2 = self.secrets()
        second = self.harness.wait('need', lambda v: v['delivery'] != first['delivery'])
        self.assertFalse(self.reply(second['delivery'], stale=True)['accepted'])
        self.assertTrue(pending2.empty())
        self.assertTrue(self.reply(second['delivery'])['accepted'])
        self.assertEqual(pending2.get(timeout=3)[0], 'ok')

    def test_user_cancel_and_shutdown_finish_pending_invocations(self):
        self.begin()
        pending = self.secrets()
        self.harness.wait('need')
        self.harness.send('finish', user=True)
        self.assertTrue(self.harness.wait('finished')['found'])
        self.assertIn('UserCanceled', pending.get(timeout=3)[1])
        self.begin(request=8)
        pending = self.secrets()
        self.harness.wait('need')
        self.harness.send('drop')
        self.harness.wait('dropped')
        self.assertIn('AgentCanceled', pending.get(timeout=3)[1])

    def test_agent_does_not_claim_to_persist_secrets(self):
        settings = {'connection': {'uuid': GLib.Variant('s', 'test-uuid')}}
        saved = self.call(self.bus.connection, 'SaveSecrets', '(a{sa{sv}}o)', (settings, PROFILE)).get(timeout=3)
        self.assertIn('InternalError', saved[1])
        deleted = self.call(self.bus.connection, 'DeleteSecrets', '(a{sa{sv}}o)', (settings, PROFILE)).get(timeout=3)
        self.assertEqual(deleted, ('ok', ()))

    def test_cancel_initial_secret_cannot_answer_a_later_prompt(self):
        self.begin(provided=True)
        initial = self.secrets(flags=0)
        first = self.harness.wait('need')
        self.assertTrue(first['provided'])
        cancel = self.call(self.bus.connection, 'CancelGetSecrets', '(os)', (PROFILE, SETTING))
        self.assertEqual(cancel.get(timeout=3), ('ok', ()))
        self.assertIn('AgentCanceled', initial.get(timeout=3)[1])
        self.harness.wait('canceled')
        later = self.secrets(flags=1)
        prompt = self.harness.wait('need', lambda event: event['delivery'] != first['delivery'])
        self.assertFalse(prompt['provided'])
        self.assertFalse(self.reply(first['delivery'])['accepted'])
        self.assertTrue(later.empty())
        self.assertTrue(self.reply(prompt['delivery'])['accepted'])
        self.assertEqual(later.get(timeout=3)[0], 'ok')

    def test_new_connection_root_path_requires_matching_uuid(self):
        self.begin(profile=None, provided=True)
        wrong = self.secrets(uuid='other-uuid', path='/', flags=0).get(timeout=3)
        self.assertIn('NoSecrets', wrong[1])
        pending = self.secrets(path='/', flags=0)
        event = self.harness.wait('need')
        self.assertTrue(event['provided'])
        self.assertTrue(self.reply(event['delivery'])['accepted'])
        self.assertEqual(pending.get(timeout=3)[0], 'ok')

    def test_missing_event_consumer_rejects_pending_invocation(self):
        self.begin(provided=True)
        self.harness.send('drop-events')
        self.harness.wait('events-dropped')
        result = self.secrets(flags=0).get(timeout=3)
        self.assertEqual(result[0], 'error')
        self.assertIn('AgentCanceled', result[1])
        self.harness.send('finish')
        self.assertTrue(self.harness.wait('finished')['found'])


if __name__ == '__main__':
    unittest.main()
