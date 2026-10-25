import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

from test_dbus_protocol import Client
from airdrop_service import local_files


class AirDropTests(unittest.TestCase):
    def client(self, missing=False, **extra):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        folder = Path(temporary.name)
        if not missing:
            fixture = Path(__file__).with_name('fixtures').joinpath('owly_backend.py').read_text()
            executable = folder / 'owly'
            executable.write_text('#!' + sys.executable + '\n' + fixture)
            executable.chmod(0o755)
        environment = dict(PATH=str(folder), XDG_CONFIG_HOME=str(folder / 'config'), XDG_DATA_HOME=str(folder / 'data'),
                           MACSHELL_AIRDROP_DOWNLOADS=str(folder / 'downloads'), AIRDROP_TEST_TRACE=str(folder / 'trace'), **extra)
        client = Client('airdrop_service.py', environment=environment)
        self.addCleanup(client.close)
        client.folder = folder
        client.wait(lambda state: state.get('type') == 'ready')
        return client

    def start(self, client):
        client.send('start', name='Test MacShell')
        return client.wait(lambda state: state.get('status') == 'ready' and state.get('devices'))

    def trace(self, client):
        path = client.folder / 'trace'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_probe_is_read_only_and_missing_backend_is_actionable(self):
        client = self.client()
        client.send('probe')
        state = client.wait(lambda state: state.get('configured'))
        self.assertEqual(state['status'], 'off')
        self.assertEqual(state['mode'], 'shared')
        self.assertTrue(state['canStart'])
        self.assertFalse(any('radio' in row['args'] for row in self.trace(client)))
        missing = self.client(missing=True)
        missing.send('probe')
        state = missing.wait(lambda state: state.get('type') == 'state')
        self.assertFalse(state['available'])
        self.assertIn('Install', state['notice'])

    def test_disruptive_modes_cannot_start_even_with_legacy_consent(self):
        for mode in ('exclusive', 'active-monitor'):
            client = self.client(AIRDROP_TEST_MODE=mode)
            client.send('probe')
            state = client.wait(lambda state: state.get('configured'))
            self.assertFalse(state['canStart'])
            for consent in (None, False, True):
                client.send('start', name='Test', wifiConsent=consent)
                error = client.wait(lambda state: state.get('type') == 'error')
                self.assertIn('disconnect Wi-Fi', error['error'])
            self.assertFalse(any('radio' in row['args'] for row in self.trace(client)))

    def test_airplay_blocks_start_on_a_shared_adapter(self):
        client = self.client()
        client.send('blocked', enabled=True)
        client.wait(lambda state: state.get('blocked'))
        client.send('start', name='Test')
        self.assertIn('AirPlay', client.wait(lambda state: state.get('type') == 'error')['error'])
        self.assertFalse(any('radio' in row['args'] for row in self.trace(client)))

    def test_send_uses_only_discovered_devices_and_delivery_requires_confirmation(self):
        client = self.client()
        state = self.start(client)
        path = client.folder / 'photo with spaces;$(nothing).jpg'
        path.write_bytes(b'test')
        client.send('files', paths=[path.as_uri()])
        client.wait(lambda state: state.get('files'))
        client.send('send', key='[fe80::evil]:8770')
        client.wait(lambda state: state.get('type') == 'error')
        client.send('send', key=state['devices'][0]['key'])
        sent = client.wait(lambda state: state.get('transfer') == 'delivered')
        self.assertEqual(sent['progress'], dict(sent=100, total=100))
        command = next(row['args'] for row in self.trace(client) if row['args'][:2] == ['macshell', 'send'])
        self.assertEqual(command[-2:], ['--', str(path)])
        self.assertEqual(command[command.index('--address') + 1], '[fe80::2%8]:8770')

    def test_successful_exit_without_delivery_is_a_failure(self):
        client = self.client(AIRDROP_TEST_SEND='silent')
        state = self.start(client)
        path = client.folder / 'photo.jpg'; path.write_bytes(b'test')
        client.send('files', paths=[str(path)])
        client.wait(lambda state: state.get('files'))
        client.send('send', key=state['devices'][0]['key'])
        failed = client.wait(lambda state: state.get('transfer') == 'failed')
        self.assertIn('without delivery confirmation', failed['error'])

    def test_incoming_file_waits_for_current_request_approval(self):
        client = self.client(AIRDROP_TEST_OFFER='1')
        self.start(client)
        pending = client.wait(lambda state: state.get('pending'))['pending']
        self.assertFalse((client.folder / 'downloads/photo.jpg').exists())
        client.send('answer', key='old-session:1', accept=True)
        client.wait(lambda state: state.get('type') == 'error')
        self.assertFalse((client.folder / 'downloads/photo.jpg').exists())
        client.send('answer', key=pending['key'], accept=True)
        client.wait(lambda state: state.get('transfer') == 'received')
        self.assertEqual((client.folder / 'downloads/photo.jpg').read_bytes(), b'test')

    def test_old_request_cannot_accept_a_new_session_and_stop_releases_children(self):
        client = self.client(AIRDROP_TEST_OFFER='1')
        self.start(client)
        first = client.wait(lambda state: state.get('pending'))['pending']['key']
        client.send('stop')
        client.wait(lambda state: state.get('status') == 'off')
        self.start(client)
        second = client.wait(lambda state: state.get('pending'))['pending']['key']
        self.assertNotEqual(first, second)
        client.send('answer', key=first, accept=True)
        client.wait(lambda state: state.get('type') == 'error')
        client.send('answer', key=second, accept=False)
        client.wait(lambda state: state.get('pending') is None and state.get('receiving'))
        self.assertFalse((client.folder / 'downloads/photo.jpg').exists())
        client.send('stop'); client.wait(lambda state: state.get('status') == 'off')
        for row in self.trace(client):
            with self.assertRaises(ProcessLookupError):
                os.kill(row['pid'], 0)

    def test_helper_exit_releases_its_owned_radio(self):
        client = self.client()
        self.start(client)
        pid = next(row['pid'] for row in self.trace(client) if row['args'][:2] == ['macshell', 'radio'])
        client.process.terminate()
        self.assertEqual(client.process.wait(timeout=5), 0)
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_local_file_validation_rejects_remote_missing_and_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'фото #1.jpg'
            path.write_bytes(b'test')
            self.assertEqual(local_files([path.as_uri(), str(path)]), [str(path)])
            for paths in ([], ['https://example.org/file'], ['file://other-host/file'], [directory], [str(path) + '.missing']):
                with self.assertRaises((ValueError, OSError)):
                    local_files(paths)


if __name__ == '__main__':
    unittest.main()
