import os
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'MacShell'))
from clock_store import ClockStore
from clock_source import boot_id, boot_time_ms, wall_time_ms
from clock_timer import migrate_legacy
from scripts.install_niri import quickshell


@unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
class ClockClientTests(unittest.TestCase):
    def run_client(self, crash_after_commit=False, action='start'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / 'MacShell', root / 'shell')
            shutil.copy(ROOT / 'tests/clock-client.qml', root / 'shell/shell.qml')
            if crash_after_commit:
                service = root / 'shell/clock_service.py'
                service.rename(root / 'shell/clock_service_impl.py')
                service.write_text('''import os
from pathlib import Path
import clock_service_impl as impl
original = impl.ClockService.emit
def emit(self, **data):
    marker = Path(os.environ['MACSHELL_CLOCK_TEST_CRASH_MARKER'])
    if data.get('type') == 'result' and data.get('success') and not marker.exists():
        marker.write_text('committed')
        os._exit(42)
    return original(self, **data)
impl.ClockService.emit = emit
raise SystemExit(impl.main())
''')
            for name in ('config', 'cache', 'runtime'):
                (root / name).mkdir()
            (root / 'runtime').chmod(0o700)
            store_path = root / 'config/macshell/clock.json'
            if action == 'claim-sound':
                with ClockStore(store_path) as store:
                    timing = migrate_legacy({'state': 'idle', 'total': 5000, 'left': 5000},
                                            boot_id(), boot_time_ms(), wall_time_ms(), 'timer')
                    timing['completion'] = {'eventId': 'event-a', 'sessionId': 'alarm-a',
                                            'kind': 'alarm', 'label': 'Wake'}
                    store.commit({'timing': timing}, 'missing', 0)
            environment = dict(os.environ, XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'),
                               XDG_RUNTIME_DIR=str(root / 'runtime'), QT_QPA_PLATFORM='offscreen',
                               QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic',
                               DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
                               MACSHELL_CLOCK_TEST_STORE=str(store_path), MACSHELL_CLOCK_TEST_ACTION=action,
                               MACSHELL_CLOCK_TEST_CRASH_MARKER=str(root / 'crashed'))
            environment.pop('DISPLAY', None)
            environment.pop('WAYLAND_DISPLAY', None)
            result = subprocess.run([quickshell(), '-p', str(root / 'shell')], env=environment,
                                    capture_output=True, text=True, timeout=12)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('CLOCK_CLIENT_PASS', output)
            document = json.loads(store_path.read_text())
            self.assertEqual(len(document['commandResults']), 1)
            if action == 'claim-sound':
                self.assertTrue(document['timing']['completion']['soundClaimed'])
            else:
                self.assertEqual(document['timer']['label'], 'Client test')
            if crash_after_commit:
                self.assertTrue((root / 'crashed').exists())

    def test_qml_client_sends_a_timer_command_to_the_service(self):
        self.run_client()

    def test_qml_client_retries_same_command_after_service_crash(self):
        self.run_client(crash_after_commit=True)

    def test_uncertain_sound_claim_is_not_replayed_after_crash(self):
        self.run_client(crash_after_commit=True, action='claim-sound')

    def test_playback_error_follows_active_event(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / 'MacShell', root / 'shell')
            shutil.copy(ROOT / 'tests/clock-client-playback-error.qml', root / 'shell/shell.qml')
            (root / 'shell/clock-service.sh').write_text('exec python3 -u "$(dirname "$0")/fake-clock.py"\n')
            (root / 'shell/fake-clock.py').write_text('''import json, sys
def emit(**value):
    print(json.dumps(value), flush=True)
def state(event, generation):
    emit(type='state', generation=generation, timing={'completion': {'eventId': event}})
emit(type='ready')
for line in sys.stdin:
    request = json.loads(line)
    generation = request['generation']
    if request['action'] == 'load':
        state('event-a', generation)
        emit(type='error', generation=generation, error='Clock sound playback failed')
        state('event-a', generation)
    elif request['action'] == 'prepare':
        emit(type='prepared', generation=generation, id=request['id'], commandId='command', sessionId='session', bootId='boot', issuedBootMs=1, revision=1)
    elif request['action'] == 'command':
        emit(type='result', generation=generation, id=request['id'], success=True, result={})
        state('event-b', generation)
''')
            for name in ('config', 'cache', 'runtime'):
                (root / name).mkdir()
            (root / 'runtime').chmod(0o700)
            environment = dict(os.environ, XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'),
                               XDG_RUNTIME_DIR=str(root / 'runtime'), QT_QPA_PLATFORM='offscreen',
                               QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic',
                               DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
                               MACSHELL_CLOCK_TEST_STORE=str(root / 'config/clock.json'))
            environment.pop('DISPLAY', None)
            environment.pop('WAYLAND_DISPLAY', None)
            result = subprocess.run([quickshell(), '-p', str(root / 'shell')], env=environment,
                                    capture_output=True, text=True, timeout=12)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('CLOCK_CLIENT_PASS', output)


if __name__ == '__main__':
    unittest.main()
