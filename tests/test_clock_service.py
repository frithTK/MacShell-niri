import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
import wave

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'MacShell'))
from clock_source import boot_id, boot_time_ms
from clock_store import ClockStore
from clock_timer import migrate_legacy
from clock_sound_library import SoundLibrary
from clock_service import ClockService


class ProcessClient:
    def __init__(self, path, wall_ms=None, fake_clock=None, sound_dir=None, extra_env=None):
        if fake_clock is not None:
            script = ('import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); import clock_service; '
                      'directory = Path(sys.argv[2]); store = sys.argv[3]; '
                      'clock_service.boot_id = lambda: (directory / "boot-id").read_text().strip(); '
                      'clock_service.boot_time_ms = lambda: int((directory / "boot-ms").read_text()); '
                      'clock_service.wall_time_ms = lambda: int((directory / "wall-ms").read_text()); '
                      'sys.argv = ["clock_service", "--store", store]; sys.exit(clock_service.main())')
            command = [sys.executable, '-u', '-c', script, str(ROOT / 'MacShell'), str(fake_clock), str(path)]
        elif wall_ms is None:
            command = [sys.executable, '-u', str(ROOT / 'MacShell/clock_service.py'), '--store', str(path)]
            if sound_dir is not None:
                command.extend(['--audio-dir', str(sound_dir)])
        else:
            script = ('import sys; sys.path.insert(0, sys.argv[1]); import clock_service; '
                      'clock_service.wall_time_ms = lambda value=int(sys.argv[2]): value; '
                      'sys.argv = ["clock_service", "--store", sys.argv[3]]; '
                      'sys.exit(clock_service.main())')
            command = [sys.executable, '-u', '-c', script, str(ROOT / 'MacShell'), str(wall_ms), str(path)]
        env = dict(os.environ, TZ='UTC')
        env.update(extra_env or {})
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=env)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b''

    def read(self, timeout=4):
        deadline = time.monotonic() + timeout
        while b'\n' not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise AssertionError('Timed out waiting for service output')
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise AssertionError('Service exited before emitting a response')
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b'\n', 1)
        return json.loads(line)

    def send(self, action, data=None, request_id=1):
        request = {'action': action, 'data': data or {}, 'id': request_id, 'generation': 7}
        self.process.stdin.write((json.dumps(request) + '\n').encode())
        self.process.stdin.flush()

    def close(self):
        if self.process.stdin:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.selector.close()
        self.process.stdout.close()
        self.process.stderr.close()


class ClockServiceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'clock.json'

    def client(self, wall_ms=None, fake_clock=None, sound_dir=None, extra_env=None):
        client = ProcessClient(self.path, wall_ms, fake_clock, sound_dir, extra_env)
        self.addCleanup(client.close)
        return client

    @unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'ffmpeg and ffprobe are required')
    def test_favorites_and_safe_deletion_through_service(self):
        root = Path(self.directory.name)
        source = root / 'custom.wav'
        with wave.open(str(source), 'wb') as output:
            output.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
            output.writeframes(bytes(16000))
        imported, _ = SoundLibrary(root / 'library').import_file(source)
        identifier = imported['id']
        client = self.client(sound_dir=root)
        self.assertEqual(client.read()['type'], 'ready')
        client.send('favorite-sound', {'soundId': identifier, 'favorite': True})
        catalog = client.read()
        self.assertTrue(next(sound for sound in catalog['sounds'] if sound['id'] == identifier)['favorite'])
        client.close()
        client = self.client(sound_dir=root)
        self.assertEqual(client.read()['type'], 'ready')
        client.send('sounds')
        self.assertTrue(next(sound for sound in client.read()['sounds'] if sound['id'] == identifier)['favorite'])
        client.send('set-builtins-visible', {'visible': False})
        hidden = client.read()
        self.assertFalse(hidden['showBuiltins'])
        self.assertEqual(len(hidden['sounds']), len(SoundLibrary(root / 'library').list_apple()) + 1)
        self.assertIn(identifier, [item['id'] for item in hidden['sounds']])
        self.assertFalse(any(item['id'].startswith('builtin-') for item in hidden['sounds']))
        client.send('sounds')
        self.assertFalse(client.read()['showBuiltins'])
        client.send('set-builtins-visible', {'visible': True})
        self.assertTrue(client.read()['showBuiltins'])
        client.send('load')
        state = client.read()
        alarm = {'id': 'alarm-a', 'h': (time.gmtime().tm_hour + 2) % 24, 'm': 0,
                 'on': False, 'days': [], 'label': '', 'soundId': identifier}
        envelope = {'id': str(uuid.uuid4()), 'bootId': boot_id(), 'issuedBootMs': boot_time_ms(),
                    'revision': state['revision'], 'action': 'patch-settings', 'args': {'patch': {'alarms': [alarm]}}}
        client.send('command', envelope)
        saved = client.read()
        self.assertTrue(saved['success'])
        state = client.read()
        client.send('delete-sound', {'soundId': identifier})
        self.assertEqual(client.read()['error'], 'Sound is in use')
        self.assertTrue((root / 'library' / identifier).is_dir())
        remove_alarm = {'id': str(uuid.uuid4()), 'bootId': boot_id(), 'issuedBootMs': boot_time_ms(),
                        'revision': state['revision'], 'action': 'patch-settings', 'args': {'patch': {'alarms': []}}}
        client.send('command', remove_alarm)
        self.assertTrue(client.read()['success'])
        state = client.read()
        session_id = str(uuid.uuid4())
        begin = {'id': str(uuid.uuid4()), 'bootId': boot_id(), 'issuedBootMs': boot_time_ms(),
                 'revision': state['revision'], 'action': 'start',
                 'args': {'sessionId': session_id, 'durationMs': 10000, 'soundId': identifier}}
        client.send('command', begin)
        self.assertTrue(client.read()['success'])
        state = client.read()
        client.send('delete-sound', {'soundId': identifier})
        self.assertEqual(client.read()['error'], 'Sound is in use')
        cancel = {'id': str(uuid.uuid4()), 'bootId': boot_id(), 'issuedBootMs': boot_time_ms(),
                  'revision': state['revision'], 'action': 'cancel', 'args': {'sessionId': session_id}}
        client.send('command', cancel)
        self.assertTrue(client.read()['success'])
        state = client.read()
        self.assertEqual(state['timing']['timer']['soundId'], identifier)
        client.send('delete-sound', {'soundId': identifier})
        state = client.read()
        self.assertNotIn('soundId', state['timing']['timer'])
        self.assertEqual(state['timerPresets']['10000']['soundId'], '')
        self.assertFalse(any(sound['id'] == identifier for sound in client.read()['sounds']))
        self.assertFalse((root / 'library' / identifier).exists())
        start = {'id': str(uuid.uuid4()), 'bootId': boot_id(), 'issuedBootMs': boot_time_ms(),
                 'revision': state['revision'], 'action': 'start',
                 'args': {'sessionId': str(uuid.uuid4()), 'durationMs': 10000, 'soundId': identifier}}
        client.send('command', start)
        self.assertFalse(client.read()['success'])
        client.send('command', envelope)
        self.assertEqual(client.read()['result'], saved['result'])
        self.assertEqual(client.read()['alarms'], [])

    def test_packaged_apple_sound_can_be_saved_and_reopened(self):
        root = Path(self.directory.name)
        if not SoundLibrary(root / 'library').list_apple():
            self.skipTest('Optional packaged sound collection is not present')
        client = self.client(sound_dir=root)
        self.assertEqual(client.read()['type'], 'ready')
        client.send('sounds')
        sounds = client.read()['sounds']
        apple = next(sound for sound in sounds if sound.get('category') == 'apple' and not sound.get('imported', True))
        client.send('load')
        state = client.read()
        alarm = {'id': 'apple-alarm', 'h': 12, 'm': 0, 'on': False, 'days': [],
                 'label': '', 'soundId': apple['id']}
        envelope = {'id': str(uuid.uuid4()), 'bootId': boot_id(), 'issuedBootMs': boot_time_ms(),
                    'revision': state['revision'], 'action': 'patch-settings', 'args': {'patch': {'alarms': [alarm]}}}
        client.send('command', envelope)
        self.assertTrue(client.read()['success'])
        self.assertEqual(client.read()['alarms'][0]['soundId'], apple['id'])
        client.close()
        client = self.client(sound_dir=root)
        self.assertEqual(client.read()['type'], 'ready')
        client.send('load')
        self.assertEqual(client.read()['alarms'][0]['soundId'], apple['id'])

    @unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'ffmpeg and ffprobe are required')
    def test_deleting_a_previewed_sound_stops_its_owned_player(self):
        root = Path(self.directory.name)
        source = root / 'custom.wav'
        with wave.open(str(source), 'wb') as output:
            output.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
            output.writeframes(bytes(16000))
        imported, _ = SoundLibrary(root / 'library').import_file(source)
        bindir = root / 'bin'
        bindir.mkdir()
        player = bindir / 'pw-play'
        player.write_text('''#!/usr/bin/env python3
import os, signal, sys
def write(value):
    with open(os.environ['TEST_CLOCK_AUDIO_LOG'], 'a') as log: log.write(value + '\\n')
def stop(*unused):
    write('stop')
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
write('start')
while True: signal.pause()
''')
        player.chmod(0o755)
        log_path = root / 'audio.log'
        env = {'PATH': str(bindir) + os.pathsep + os.environ.get('PATH', ''), 'TEST_CLOCK_AUDIO_LOG': str(log_path)}
        client = self.client(sound_dir=root, extra_env=env)
        self.assertEqual(client.read()['type'], 'ready')
        client.send('preview-sound', {'soundId': imported['id']})
        self.assertTrue(client.read()['playing'])
        deadline = time.monotonic() + 4
        while not log_path.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertTrue(log_path.exists())
        client.send('delete-sound', {'soundId': imported['id']})
        self.assertFalse(client.read()['playing'])
        self.assertFalse(any(sound['id'] == imported['id'] for sound in client.read()['sounds']))
        self.assertEqual(log_path.read_text().splitlines(), ['start', 'stop'])

    def test_timer_process_restart_replay_and_single_completion(self):
        client = self.client()
        self.assertEqual(client.read()['type'], 'ready')
        client.send('load')
        state = client.read()
        self.assertEqual(state['timer']['state'], 'idle')
        envelope = {'id': str(uuid.uuid4()), 'bootId': boot_id(), 'issuedBootMs': boot_time_ms(),
                    'revision': state['revision'], 'action': 'start',
                    'args': {'sessionId': str(uuid.uuid4()), 'durationMs': 1200, 'label': 'Tea'}}
        client.send('command', envelope)
        first = client.read()
        self.assertTrue(first['success'])
        self.assertEqual(client.read()['timer']['state'], 'running')
        client.close()

        replacement = self.client()
        self.assertEqual(replacement.read()['type'], 'ready')
        replacement.send('command', envelope)
        replay = replacement.read()
        self.assertTrue(replay['success'])
        self.assertEqual(first['result'], replay['result'])
        replacement.read()  # current state
        completed = replacement.read(timeout=4)
        self.assertEqual(completed['timer']['state'], 'idle')
        self.assertEqual(completed['timing']['completion']['sessionId'], envelope['args']['sessionId'])
        event = completed['timing']['completion']
        replacement.send('load')
        self.assertEqual(replacement.read()['timing']['completion'], event)

    def test_idle_startup_does_not_create_a_clock_document(self):
        client = self.client()
        self.assertEqual(client.read()['type'], 'ready')
        client.send('load')
        state = client.read()
        self.assertEqual((state['revision'], state['timer']['state']), (0, 'idle'))
        self.assertFalse(self.path.exists())
        client.close()
        self.assertFalse(self.path.exists())

    def test_used_sound_checks_all_live_references(self):
        service = ClockService.__new__(ClockService)
        identifier = 'user-' + 'a' * 64
        service.document = {'alarms': [], 'timing': {'timer': {'state': 'idle'}, 'completion': None}}
        self.assertFalse(service._sound_in_use(identifier))
        for state in ('running', 'paused', 'recovery'):
            service.document['timing']['timer'] = {'state': state, 'soundId': identifier}
            self.assertTrue(service._sound_in_use(identifier), state)
        service.document['timing']['timer'] = {'state': 'idle', 'soundId': identifier}
        for field, value in [('alarms', [{'soundId': identifier}]),
                             ('completion', {'soundId': identifier}),
                             ('completionQueue', [{'soundId': identifier}]),
                             ('snoozes', [{'soundId': identifier}])]:
            owner = service.document if field == 'alarms' else service.document['timing']
            old = owner.get(field)
            owner[field] = value
            self.assertTrue(service._sound_in_use(identifier), field)
            if old is None:
                owner.pop(field, None)
            else:
                owner[field] = old
    def test_prepare_provides_command_identity_and_boot_time(self):
        client = self.client()
        self.assertEqual(client.read()['type'], 'ready')
        client.send('prepare', request_id=55)
        prepared = client.read()
        self.assertEqual((prepared['type'], prepared['id'], prepared['generation']), ('prepared', 55, 7))
        self.assertEqual(prepared['bootId'], boot_id())
        self.assertLessEqual(prepared['issuedBootMs'], boot_time_ms())
        envelope = {'id': prepared['commandId'], 'bootId': prepared['bootId'],
                    'issuedBootMs': prepared['issuedBootMs'], 'revision': prepared['revision'],
                    'action': 'start', 'args': {'sessionId': prepared['sessionId'], 'durationMs': 10000}}
        client.send('command', envelope)
        self.assertTrue(client.read()['success'])
        self.assertEqual(client.read()['timing']['timer']['sessionId'], prepared['sessionId'])

    def test_concurrent_owner_is_rejected(self):
        client = self.client()
        self.assertEqual(client.read()['type'], 'ready')
        other = self.client()
        self.assertEqual(other.read()['type'], 'error')
        self.assertNotEqual(other.process.wait(timeout=4), 0)
        client.send('load')
        self.assertEqual(client.read()['type'], 'state')

    def test_corrupt_existing_file_is_not_overwritten(self):
        original = b'{"version":2,"revision":1,"timing":{"version":1}}'
        self.path.write_bytes(original)
        client = self.client()
        self.assertEqual(client.read()['type'], 'error')
        self.assertNotEqual(client.process.wait(timeout=4), 0)
        self.assertEqual(self.path.read_bytes(), original)

    def test_legacy_snoozes_require_explicit_recovery_without_data_loss(self):
        wall_ms = 1793010030000
        original = json.dumps({'snoozes': [{'at': wall_ms + 120000, 'label': 'Wake', 'extension': 'kept'},
                                           {'at': wall_ms - 5000, 'label': 'Past'}]}).encode()
        self.path.write_bytes(original)
        client = self.client(wall_ms)
        self.assertEqual(client.read()['type'], 'ready')
        client.send('load')
        state = client.read()
        pending = state['timing']['legacySnoozesRecovery']
        self.assertEqual([item['remainingMs'] for item in pending], [120000, 0])
        self.assertEqual(pending[0]['legacy']['extension'], 'kept')
        self.assertEqual(next(self.path.parent.glob('clock.before-v2-*.json')).read_bytes(), original)
        document = json.loads(self.path.read_text())
        self.assertEqual(document['snoozes'], [])
        self.assertIsNone(state['timing']['completion'])
        envelope = {'id': str(uuid.uuid4()), 'bootId': boot_id(), 'issuedBootMs': boot_time_ms(),
                    'revision': state['revision'], 'action': 'recover-snooze',
                    'args': {'recoveryId': pending[0]['id'], 'decision': 'resume'}}
        client.send('command', envelope)
        result = client.read()
        self.assertTrue(result['success'])
        updated = client.read()
        self.assertEqual(len(updated['timing']['snoozes']), 1)
        self.assertEqual(len(updated['timing']['legacySnoozesRecovery']), 1)
        client.close()
        replacement = self.client(wall_ms)
        self.assertEqual(replacement.read()['type'], 'ready')
        replacement.send('command', envelope)
        self.assertEqual(replacement.read()['result'], result['result'])
        updated = replacement.read()
        self.assertEqual(len(updated['timing']['snoozes']), 1)
        overdue = {'id': str(uuid.uuid4()), 'bootId': boot_id(), 'issuedBootMs': boot_time_ms(),
                   'revision': updated['revision'], 'action': 'recover-snooze',
                   'args': {'recoveryId': pending[1]['id'], 'decision': 'resume'}}
        replacement.send('command', overdue)
        self.assertTrue(replacement.read()['success'])
        state = replacement.read()
        self.assertEqual(state['timing']['completion']['label'], 'Past')
        self.assertEqual(state['timing']['legacySnoozesRecovery'], [])

    def test_stopwatch_commands_and_laps_survive_restart(self):
        client = self.client()
        self.assertEqual(client.read()['type'], 'ready')
        client.send('load')
        state = client.read()
        session = state['timing']['stopwatch']['sessionId']
        start = {'id': str(uuid.uuid4()), 'bootId': boot_id(), 'issuedBootMs': boot_time_ms(),
                 'revision': state['revision'], 'action': 'stopwatch-start', 'args': {'sessionId': session}}
        client.send('command', start)
        result = client.read()
        self.assertTrue(result['success'])
        state = client.read()
        self.assertTrue(state['sw']['running'])
        lap = {'id': str(uuid.uuid4()), 'bootId': boot_id(), 'issuedBootMs': boot_time_ms(),
               'revision': state['revision'], 'action': 'stopwatch-lap', 'args': {'sessionId': session}}
        client.send('command', lap)
        self.assertTrue(client.read()['success'])
        state = client.read()
        self.assertEqual(len(state['sw']['laps']), 1)
        client.close()
        replacement = self.client()
        self.assertEqual(replacement.read()['type'], 'ready')
        replacement.send('load')
        restored = replacement.read()
        self.assertTrue(restored['sw']['running'])
        self.assertEqual(restored['sw']['laps'], state['sw']['laps'])

    def test_legacy_alarm_is_durable_and_does_not_fire_twice(self):
        wall_ms = 1793010030000  # 2026-10-26 10:20:30 UTC
        legacy = {'alarms': [{'id': 'wake', 'h': 10, 'm': 20, 'on': True, 'days': [], 'label': 'Wake'}]}
        original = json.dumps(legacy).encode()
        self.path.write_bytes(original)
        client = self.client(wall_ms)
        self.assertEqual(client.read()['type'], 'ready')
        client.send('load')
        state = client.read()
        self.assertFalse(state['alarms'][0]['on'])
        self.assertEqual(state['timing']['completion']['label'], 'Wake')
        event = state['timing']['completion']
        self.assertEqual(next(self.path.parent.glob('clock.before-v2-*.json')).read_bytes(), original)
        client.close()
        replacement = self.client(wall_ms)
        self.assertEqual(replacement.read()['type'], 'ready')
        replacement.send('load')
        state = replacement.read()
        self.assertEqual(state['timing']['completion'], event)
        self.assertEqual(state['timing'].get('completionQueue', []), [])

    def test_snooze_survives_service_restart_without_duplicate(self):
        wall_ms = 1793010030000
        self.path.write_text(json.dumps({'alarms': [{'id': 'wake', 'h': 10, 'm': 20,
                                                      'on': True, 'days': [], 'label': 'Wake'}]}))
        client = self.client(wall_ms)
        self.assertEqual(client.read()['type'], 'ready')
        client.send('load')
        state = client.read()
        envelope = {'id': str(uuid.uuid4()), 'bootId': boot_id(), 'issuedBootMs': boot_time_ms(),
                    'revision': state['revision'], 'action': 'snooze',
                    'args': {'eventId': state['timing']['completion']['eventId']}}
        client.send('command', envelope)
        result = client.read()
        self.assertTrue(result['success'])
        self.assertEqual(len(client.read()['timing']['snoozes']), 1)
        client.close()
        replacement = self.client(wall_ms)
        self.assertEqual(replacement.read()['type'], 'ready')
        replacement.send('command', envelope)
        replay = replacement.read()
        self.assertEqual(replay['result'], result['result'])
        state = replacement.read()
        self.assertIsNone(state['timing']['completion'])
        self.assertEqual(len(state['timing']['snoozes']), 1)

    def test_legacy_ringing_is_preserved_without_reclaiming_sound(self):
        legacy = {'ringing': {'kind': 'alarm', 'label': 'Wake', 'time': '09:00'}}
        self.path.write_text(json.dumps(legacy))
        client = self.client()
        self.assertEqual(client.read()['type'], 'ready')
        client.send('load')
        state = client.read()
        event = state['timing']['completion']
        self.assertEqual((event['kind'], event['label'], event['time']), ('alarm', 'Wake', '09:00'))
        self.assertTrue(event['soundClaimed'])
        self.assertEqual(json.loads(self.path.read_text())['ringing']['eventId'], event['eventId'])

    def test_simulated_clock_jumps_and_reboot_recovery(self):
        directory = Path(self.directory.name) / 'clock'
        directory.mkdir()
        def set_clock(boot, wall, identity):
            for name, value in (('boot-ms', boot), ('wall-ms', wall), ('boot-id', identity)):
                path = directory / name
                pending = path.with_suffix('.tmp')
                pending.write_text(str(value))
                pending.replace(path)
        set_clock(1000, 1000000, 'boot-a')
        client = self.client(fake_clock=directory)
        self.assertEqual(client.read()['type'], 'ready')
        client.send('load')
        state = client.read()
        start = {'id': str(uuid.uuid4()), 'bootId': 'boot-a', 'issuedBootMs': 1000,
                 'revision': state['revision'], 'action': 'start',
                 'args': {'sessionId': 'timer-a', 'durationMs': 5000}}
        client.send('command', start)
        started = client.read()
        self.assertTrue(started['success'])
        start_revision = started['result']['revision']
        client.read()
        set_clock(2000, 8000000, 'boot-a')
        client.send('load')
        updated = client.read()
        while updated.get('type') == 'state' and updated['revision'] <= start_revision:
            self.assertEqual(updated['timer']['left'], 4000)
            updated = client.read()
        self.assertEqual(updated['type'], 'state')
        self.assertEqual(updated['timer']['left'], 4000)
        self.assertEqual(updated['timer']['endAt'], 8004000)
        client.close()
        set_clock(500, 200000, 'boot-b')
        replacement = self.client(fake_clock=directory)
        self.assertEqual(replacement.read()['type'], 'ready')
        replacement.send('load')
        state = replacement.read()
        self.assertTrue(state['timer']['recoveryRequired'])
        self.assertEqual(state['timer']['left'], 5000)
        self.assertIsNone(state['timing']['completion'])
        resume = {'id': str(uuid.uuid4()), 'bootId': 'boot-b', 'issuedBootMs': 500,
                  'revision': state['revision'], 'action': 'recover-remainder',
                  'args': {'sessionId': 'timer-a'}}
        replacement.send('command', resume)
        self.assertTrue(replacement.read()['success'])
        self.assertEqual(replacement.read()['timer']['state'], 'running')
        set_clock(5500, 100, 'boot-b')
        replacement.send('load')
        complete = replacement.read()
        while complete.get('type') == 'state' and complete['timer']['state'] != 'idle':
            complete = replacement.read()
        self.assertEqual(complete['type'], 'state')
        self.assertEqual(complete['timer']['state'], 'idle')
        self.assertEqual(complete['timing']['completion']['sessionId'], 'timer-a')

    def test_audio_is_claimed_before_playback_and_is_not_replayed_after_crash(self):
        root = Path(self.directory.name)
        bindir = root / 'bin'
        bindir.mkdir()
        log_path = root / 'audio.log'
        player = bindir / 'pw-play'
        player.write_text('''#!/usr/bin/env python3
import json, os, time
with open(os.environ['TEST_CLOCK_STORE']) as source:
    event = json.load(source)['timing']['completion']
if not event['soundClaimed']:
    raise SystemExit(9)
with open(os.environ['TEST_CLOCK_AUDIO_LOG'], 'a') as log:
    log.write(event['eventId'] + '\\n')
    log.flush()
time.sleep(.15)
''')
        player.chmod(0o755)
        with ClockStore(self.path) as store:
            timing = migrate_legacy({'state': 'idle', 'total': 5000, 'left': 5000},
                                     boot_id(), boot_time_ms(), int(time.time() * 1000), 'timer')
            timing['completion'] = {'eventId': 'first', 'sessionId': 'timer-a', 'kind': 'timer', 'label': ''}
            store.commit({'timing': timing}, 'missing', 0)
        env = {'PATH': str(bindir) + os.pathsep + os.environ.get('PATH', ''),
               'TEST_CLOCK_STORE': str(self.path), 'TEST_CLOCK_AUDIO_LOG': str(log_path)}
        client = self.client(sound_dir=root, extra_env=env)
        self.assertEqual(client.read()['type'], 'state')
        self.assertEqual(client.read()['type'], 'ready')
        deadline = time.monotonic() + 4
        while not log_path.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertTrue(log_path.exists(), 'audio player did not start')
        self.assertEqual(log_path.read_text().splitlines()[0], 'first')
        client.process.kill()
        client.process.wait(timeout=4)
        client.close()
        count = len(log_path.read_text().splitlines())
        replacement = self.client(sound_dir=root, extra_env=env)
        self.assertEqual(replacement.read()['type'], 'ready')
        time.sleep(.5)
        self.assertEqual(len(log_path.read_text().splitlines()), count)
        replacement.send('load')
        state = replacement.read()
        self.assertTrue(state['timing']['completion']['soundClaimed'])

    def test_audio_events_play_in_order_and_stop_only_the_owned_player(self):
        root = Path(self.directory.name)
        bindir = root / 'bin'
        bindir.mkdir()
        log_path = root / 'audio.log'
        player = bindir / 'pw-play'
        player.write_text('''#!/usr/bin/env python3
import json, os, signal, sys
with open(os.environ['TEST_CLOCK_STORE']) as source:
    event = json.load(source)['timing']['completion']
def write(value):
    with open(os.environ['TEST_CLOCK_AUDIO_LOG'], 'a') as log:
        log.write(value + ' ' + event['eventId'] + '\\n')
def stop(*unused):
    write('stop')
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
write('start')
while True:
    signal.pause()
''')
        player.chmod(0o755)
        with ClockStore(self.path) as store:
            timing = migrate_legacy({'state': 'idle', 'total': 5000, 'left': 5000},
                                     boot_id(), boot_time_ms(), int(time.time() * 1000), 'timer')
            timing['completion'] = {'eventId': 'first', 'sessionId': 'timer-a', 'kind': 'timer', 'label': ''}
            timing['completionQueue'] = [{'eventId': 'second', 'sessionId': 'alarm-b', 'kind': 'alarm', 'label': 'Wake'}]
            store.commit({'timing': timing}, 'missing', 0)
        env = {'PATH': str(bindir) + os.pathsep + os.environ.get('PATH', ''),
               'TEST_CLOCK_STORE': str(self.path), 'TEST_CLOCK_AUDIO_LOG': str(log_path)}
        client = self.client(sound_dir=root, extra_env=env)
        state = client.read()
        self.assertEqual(state['type'], 'state')
        self.assertEqual(client.read()['type'], 'ready')
        deadline = time.monotonic() + 4
        while (not log_path.exists() or 'start first' not in log_path.read_text()) and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertTrue(log_path.exists(), 'first sound did not start')
        dismiss = {'id': str(uuid.uuid4()), 'bootId': boot_id(), 'issuedBootMs': boot_time_ms(),
                   'revision': state['revision'], 'action': 'dismiss-event', 'args': {'eventId': 'first'}}
        client.send('command', dismiss)
        self.assertTrue(client.read()['success'])
        deadline = time.monotonic() + 4
        while 'start second' not in log_path.read_text() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertEqual(log_path.read_text().splitlines()[:3], ['start first', 'stop first', 'start second'])

    def test_failed_custom_audio_reports_fallback_and_retains_event(self):
        root = Path(self.directory.name)
        bindir = root / 'bin'
        bindir.mkdir()
        (root / 'timer.wav').write_bytes(b'bad audio')
        log_path = root / 'audio.log'
        player = bindir / 'pw-play'
        player.write_text('''#!/usr/bin/env python3
import os, signal, sys
with open(os.environ['TEST_CLOCK_AUDIO_LOG'], 'a') as log:
    log.write(sys.argv[-1] + '\\n')
if sys.argv[-1] == os.environ['TEST_CLOCK_CUSTOM_SOUND']:
    sys.exit(1)
signal.pause()
''')
        player.chmod(0o755)
        with ClockStore(self.path) as store:
            timing = migrate_legacy({'state': 'idle', 'total': 5000, 'left': 5000},
                                     boot_id(), boot_time_ms(), int(time.time() * 1000), 'timer')
            timing['completion'] = {'eventId': 'sound-fallback', 'sessionId': 'timer-a', 'kind': 'timer', 'label': ''}
            store.commit({'timing': timing}, 'missing', 0)
        env = {'PATH': str(bindir) + os.pathsep + os.environ.get('PATH', ''),
               'TEST_CLOCK_AUDIO_LOG': str(log_path), 'TEST_CLOCK_CUSTOM_SOUND': str(root / 'timer.wav')}
        client = self.client(sound_dir=root, extra_env=env)
        state = client.read()
        self.assertEqual(state['type'], 'state')
        self.assertEqual(client.read()['type'], 'ready')
        error = client.read()
        self.assertEqual((error['type'], error['error']),
                         ('error', 'Clock sound failed; using the built-in sound'))
        deadline = time.monotonic() + 4
        while len(log_path.read_text().splitlines()) < 2 and time.monotonic() < deadline:
            time.sleep(.02)
        paths = log_path.read_text().splitlines()
        self.assertEqual(paths, [str(root / 'timer.wav'), str(Path(__file__).resolve().parents[1] / 'MacShell/sounds/timer.wav')])
        self.assertEqual(state['timing']['completion']['eventId'], 'sound-fallback')

    def test_sound_catalog_preview_yields_to_timer_alert(self):
        root = Path(self.directory.name)
        bindir = root / 'bin'
        bindir.mkdir()
        log_path = root / 'preview.log'
        player = bindir / 'pw-play'
        player.write_text('''#!/usr/bin/env python3
import os, signal, sys
path = sys.argv[-1]
def write(action):
    with open(os.environ['TEST_CLOCK_AUDIO_LOG'], 'a') as log:
        log.write(action + ' ' + path + '\\n')
def stop(*unused):
    write('stop')
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
write('start')
while True:
    signal.pause()
''')
        player.chmod(0o755)
        env = {'PATH': str(bindir) + os.pathsep + os.environ.get('PATH', ''),
               'TEST_CLOCK_AUDIO_LOG': str(log_path)}
        client = self.client(sound_dir=root, extra_env=env)
        self.assertEqual(client.read()['type'], 'ready')
        client.send('sounds')
        catalog = client.read()
        self.assertEqual(catalog['type'], 'sounds')
        self.assertEqual(len(catalog['sounds']), len(SoundLibrary(root / 'library').list_apple()))
        client.send('preview-sound', {'soundId': 'builtin-chime-01'})
        self.assertEqual(client.read()['soundId'], 'builtin-chime-01')
        deadline = time.monotonic() + 4
        while (not log_path.exists() or 'start ' not in log_path.read_text()) and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertIn('chime-01.wav', log_path.read_text())
        client.send('load')
        state = client.read()
        envelope = {'id': str(uuid.uuid4()), 'bootId': boot_id(), 'issuedBootMs': boot_time_ms(),
                    'revision': state['revision'], 'action': 'start',
                    'args': {'sessionId': str(uuid.uuid4()), 'durationMs': 1000}}
        client.send('command', envelope)
        self.assertTrue(client.read()['success'])
        client.read()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            lines = log_path.read_text().splitlines()
            if len(lines) >= 3:
                break
            time.sleep(.02)
        self.assertEqual(len(lines), 3)
        self.assertIn('start ', lines[0]); self.assertIn('chime-01.wav', lines[0])
        self.assertIn('stop ', lines[1]); self.assertIn('chime-01.wav', lines[1])
        self.assertIn('start ', lines[2]); self.assertIn('timer.wav', lines[2])

    def test_missing_selected_sound_uses_bundled_fallback(self):
        root = Path(self.directory.name)
        bindir = root / 'bin'
        bindir.mkdir()
        (root / 'timer.wav').write_bytes(b'legacy custom sound')
        player = bindir / 'pw-play'
        player.write_text('#!/bin/sh\nprintf "%s\\n" "$2" >> "$TEST_CLOCK_AUDIO_LOG"\nexec sleep 30\n')
        player.chmod(0o755)
        with ClockStore(self.path) as store:
            timing = migrate_legacy({'state': 'idle', 'total': 5000, 'left': 5000},
                                     boot_id(), boot_time_ms(), int(time.time() * 1000), 'timer')
            timing['completion'] = {'eventId': 'missing-sound', 'sessionId': 'timer-a', 'kind': 'timer',
                                    'label': '', 'soundId': 'user-' + 'a' * 64}
            store.commit({'timing': timing}, 'missing', 0)
        log_path = root / 'audio.log'
        env = {'PATH': str(bindir) + os.pathsep + os.environ.get('PATH', ''), 'TEST_CLOCK_AUDIO_LOG': str(log_path)}
        client = self.client(sound_dir=root, extra_env=env)
        self.assertEqual(client.read()['type'], 'state')
        warning = client.read()
        self.assertEqual(warning['error'], 'Clock sound failed; using the built-in sound')
        self.assertEqual(client.read()['type'], 'ready')
        deadline = time.monotonic() + 4
        while not log_path.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertEqual(log_path.read_text().strip(), str(ROOT / 'MacShell/sounds/timer.wav'))

    def test_silence_keeps_the_visual_alert_without_starting_a_player(self):
        root = Path(self.directory.name)
        bindir = root / 'bin'
        bindir.mkdir()
        player = bindir / 'pw-play'
        player.write_text('#!/bin/sh\ntouch "$TEST_CLOCK_AUDIO_LOG"\n')
        player.chmod(0o755)
        with ClockStore(self.path) as store:
            timing = migrate_legacy({'state': 'idle', 'total': 5000, 'left': 5000},
                                     boot_id(), boot_time_ms(), int(time.time() * 1000), 'timer')
            timing['completion'] = {'eventId': 'silent', 'sessionId': 'timer-a', 'kind': 'timer',
                                    'label': '', 'soundId': 'silence'}
            store.commit({'timing': timing}, 'missing', 0)
        log_path = root / 'audio.log'
        env = {'PATH': str(bindir) + os.pathsep + os.environ.get('PATH', ''), 'TEST_CLOCK_AUDIO_LOG': str(log_path)}
        client = self.client(sound_dir=root, extra_env=env)
        state = client.read()
        self.assertEqual(state['timing']['completion']['eventId'], 'silent')
        self.assertTrue(state['timing']['completion']['soundClaimed'])
        self.assertEqual(client.read()['type'], 'ready')
        time.sleep(.25)
        self.assertFalse(log_path.exists())

    def test_failed_audio_is_reported_and_event_remains_visible(self):
        root = Path(self.directory.name)
        bindir = root / 'bin'
        bindir.mkdir()
        player = bindir / 'pw-play'
        player.write_text('#!/bin/sh\nexit 1\n')
        player.chmod(0o755)
        with ClockStore(self.path) as store:
            timing = migrate_legacy({'state': 'idle', 'total': 5000, 'left': 5000},
                                     boot_id(), boot_time_ms(), int(time.time() * 1000), 'timer')
            timing['completion'] = {'eventId': 'sound-error', 'sessionId': 'timer-a', 'kind': 'timer', 'label': ''}
            store.commit({'timing': timing}, 'missing', 0)
        env = {'PATH': str(bindir) + os.pathsep + os.environ.get('PATH', '')}
        client = self.client(sound_dir=root, extra_env=env)
        state = client.read()
        self.assertEqual(state['type'], 'state')
        self.assertEqual(client.read()['type'], 'ready')
        error = client.read()
        self.assertEqual((error['type'], error['error']), ('error', 'Clock sound playback failed'))
        self.assertEqual(state['timing']['completion']['eventId'], 'sound-error')
        self.assertTrue(state['timing']['completion']['soundClaimed'])


if __name__ == '__main__':
    unittest.main()
