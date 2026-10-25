import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

from test_dbus_protocol import Client
from screen_mirroring import devices_from_response


class ScreenMirroringTests(unittest.TestCase):
    def client(self, missing=False, **extra):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        folder = Path(temporary.name)
        fixture = (Path(__file__).parent / 'fixtures/airplay_backend.py').read_text()
        if not missing:
            for name in ('doubletake', 'uxplay'):
                executable = folder / name
                executable.write_text('#!' + sys.executable + '\n' + fixture)
                executable.chmod(0o755)
        environment = dict(PATH=str(folder), XDG_CONFIG_HOME=str(folder / 'config'),
                           XDG_DATA_HOME=str(folder / 'data'), AIRPLAY_TEST_TRACE=str(folder / 'trace'), **extra)
        client = Client('screen_mirroring.py', environment=environment)
        self.addCleanup(client.close)
        client.trace = folder / 'trace'
        client.wait(lambda m: m.get('type') == 'ready')
        return client

    def discover(self, client):
        client.send('watch', enabled=True)
        return client.wait(lambda m: len(m.get('devices', [])) == 1)

    def connect(self, client):
        state = self.discover(client)
        client.send('connect', key=state['devices'][0]['key'])
        return client.wait(lambda m: m.get('senderState') == 'pin_required')

    def trace(self, client):
        return [json.loads(line) for line in client.trace.read_text().splitlines()] if client.trace.exists() else []

    def test_capabilities_do_not_start_or_advertise_without_user_action(self):
        client = self.client()
        client.send('watch', enabled=False)
        state = client.wait(lambda m: m.get('type') == 'state')
        self.assertTrue(state['senderAvailable'])
        self.assertTrue(state['receiverAvailable'])
        self.assertEqual((state['senderState'], state['receiverState']), ('off', 'off'))
        self.assertFalse(client.trace.exists())

    def test_missing_backends_are_actionable_and_never_report_connected(self):
        client = self.client(missing=True)
        client.send('watch', enabled=True)
        state = client.wait(lambda m: m.get('senderState') == 'unavailable')
        self.assertIn('Install doubletake', state['senderError'])
        client.send('receive', enabled=True)
        state = client.wait(lambda m: m.get('receiverState') == 'unavailable')
        self.assertIn('Install uxplay', state['receiverError'])
        self.assertEqual(state['streams'], [])

    def test_discovered_endpoint_port_and_leading_zero_pin_reach_the_daemon(self):
        client = self.client()
        state = self.connect(client)
        self.assertEqual(state['streams'][0]['credentialKind'], 'pin')
        self.assertFalse(any(m.get('senderState') == 'streaming' for m in client.lines))
        client.send('credential', value='0042')
        state = client.wait(lambda m: m.get('senderState') == 'streaming')
        self.assertTrue(state['streams'][0]['hasAudio'])
        requests = [line['request'] for line in self.trace(client) if 'request' in line]
        self.assertIn(dict(cmd='connect', target='127.0.0.42', port=7100), requests)
        self.assertIn(dict(cmd='connect', target='127.0.0.42', pin='0042'), requests)
        self.assertNotIn('0042', json.dumps(client.lines))

    def test_configured_password_has_a_distinct_prompt_and_wrong_value_can_retry(self):
        client = self.client(AIRPLAY_TEST_CREDENTIAL='password')
        state = self.connect(client)
        self.assertEqual(state['streams'][0]['credentialKind'], 'password')
        client.send('credential', value='wrong password')
        state = client.wait(lambda m: m.get('senderError') == 'Incorrect code' and m.get('senderState') == 'pin_required')
        self.assertEqual(state['senderState'], 'pin_required')
        client.send('credential', value='0042')
        client.wait(lambda m: m.get('senderState') == 'streaming')
        client.send('audio', enabled=False)
        client.wait(lambda m: m.get('streams') and m['streams'][0]['muted'])
        client.send('audio', enabled=True)
        client.wait(lambda m: m.get('streams') and not m['streams'][0]['muted'])

    def test_invalid_target_and_unsolicited_credentials_never_connect(self):
        client = self.client()
        self.discover(client)
        client.send('connect', key='127.0.0.1;echo bad')
        client.wait(lambda m: m.get('type') == 'error')
        client.send('credential', value='0042')
        client.wait(lambda m: m.get('type') == 'error')
        self.assertFalse(any(line.get('request', {}).get('cmd') == 'connect' for line in self.trace(client)))

    def test_closing_menu_preserves_pairing_but_disconnect_releases_owned_daemon(self):
        client = self.client()
        self.connect(client)
        client.send('watch', enabled=False)
        time.sleep(.2)
        client.send('status')
        client.send('disconnect')
        client.wait(lambda m: m.get('senderState') == 'off')
        pid = next(line['pid'] for line in self.trace(client) if line.get('program') == 'doubletake')
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_receiver_readiness_is_separate_from_streaming_and_stop_clears_pin(self):
        client = self.client(AIRPLAY_TEST_RECEIVER='pin')
        client.send('receive', enabled=True, name='Test MacShell')
        state = client.wait(lambda m: m.get('receiverState') == 'waiting')
        self.assertEqual(state['senderState'], 'off')
        state = client.wait(lambda m: m.get('receiverPin') == '0042')
        self.assertEqual(state['receiverClient'], 'Test iPhone')
        state = client.wait(lambda m: m.get('receiverState') == 'streaming')
        self.assertEqual(state['receiverPin'], '')
        client.wait(lambda m: m.get('receiverState') == 'waiting' and not m.get('receiverClient'))
        client.send('receive', enabled=False)
        state = client.wait(lambda m: m.get('receiverState') == 'off')
        self.assertEqual(state['receiverPin'], '')
        start = next(line for line in self.trace(client) if line.get('program') == 'uxplay')
        self.assertIn('-pin', start['arguments'])
        self.assertEqual(start['arguments'][start['arguments'].index('-p') + 1], '7100')
        self.assertIn('Test MacShell', start['arguments'])
        with self.assertRaises(ProcessLookupError):
            os.kill(start['pid'], 0)

    def test_failed_receiver_never_claims_network_availability(self):
        client = self.client(AIRPLAY_TEST_RECEIVER='fail')
        client.send('receive', enabled=True, name='Test MacShell')
        client.wait(lambda m: m.get('receiverState') == 'error')
        self.assertFalse(any(m.get('receiverState') in ('waiting', 'streaming') for m in client.lines))

    def test_busy_ports_are_actionable_and_never_fall_back_to_an_unapproved_port(self):
        client = self.client(AIRPLAY_TEST_RECEIVER='port-busy')
        client.send('receive', enabled=True, name='Test MacShell')
        state = client.wait(lambda m: m.get('receiverState') == 'error')
        self.assertIn('7100–7102', state['receiverError'])
        self.assertFalse(any(m.get('receiverState') in ('waiting', 'streaming') for m in client.lines))
        starts = [line for line in self.trace(client) if line.get('program') == 'uxplay']
        self.assertEqual(len(starts), 1)

    def test_receiver_restart_keeps_the_firewall_ports_and_pairing_key(self):
        client = self.client()
        for _ in range(2):
            client.send('receive', enabled=True, name='Test MacShell')
            client.wait(lambda m: m.get('receiverState') == 'waiting')
            client.send('receive', enabled=False)
            client.wait(lambda m: m.get('receiverState') == 'off')
        starts = [line['arguments'] for line in self.trace(client) if line.get('program') == 'uxplay']
        self.assertEqual(len(starts), 2)
        self.assertEqual(starts[0], starts[1])
        self.assertEqual(starts[0][starts[0].index('-p') + 1], '7100')
        self.assertIn('-key', starts[0])
        self.assertIn('-pin', starts[0])

    def test_ending_helper_cleans_up_its_receiver(self):
        client = self.client()
        client.send('receive', enabled=True, name='Test MacShell')
        client.wait(lambda m: m.get('receiverState') == 'waiting')
        pid = next(line['pid'] for line in self.trace(client) if line.get('program') == 'uxplay')
        client.process.terminate()
        self.assertEqual(client.process.wait(timeout=5), 0)
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_discovery_filters_malformed_endpoints_and_deduplicates(self):
        items = [None, 'bad', {}, dict(ip='invalid'), dict(ip='127.0.0.1', port=0),
                 dict(ip='127.0.0.1', port=7000, name='TV'), dict(ip='127.0.0.1', port=7000, name='TV')]
        self.assertEqual(len(devices_from_response(items)), 1)
        self.assertEqual(devices_from_response(items)[0]['key'], '127.0.0.1|7000')


if __name__ == '__main__':
    unittest.main()
