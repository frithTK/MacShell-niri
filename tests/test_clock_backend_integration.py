import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'MacShell'))
from clock_source import boot_id, boot_time_ms
from clock_store import ClockStore
from clock_timer import migrate_legacy
from scripts.install_niri import quickshell


@unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
class ClockBackendIntegrationTests(unittest.TestCase):
    def test_timer_and_stopwatch_share_the_service_and_kernel_clock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shell = root / 'shell'
            shutil.copytree(ROOT / 'MacShell', shell)
            rust_clock = os.environ.get('MACSHELL_TEST_BOOT_CLOCK_BINARY')
            if rust_clock:
                shutil.copy(rust_clock, shell / 'boot-clock-rust')
                (shell / 'boot_clock.py').write_text('raise SystemExit("unexpected Python fallback")\n')
            shutil.copy(ROOT / 'tests/clock-backend-integration.qml', shell / 'shell.qml')
            for name in ('config', 'cache', 'runtime'):
                (root / name).mkdir()
            (root / 'runtime').chmod(0o700)
            store = root / 'config/macshell/clock.json'
            env = dict(os.environ, XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'),
                       XDG_RUNTIME_DIR=str(root / 'runtime'), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='',
                       QT_QUICK_BACKEND='software', QT_QUICK_CONTROLS_STYLE='Basic',
                       DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
                       MACSHELL_CLOCK_TEST_STORE=str(store))
            env.pop('DISPLAY', None)
            env.pop('WAYLAND_DISPLAY', None)
            result = subprocess.run([quickshell(), '-p', str(shell)], env=env,
                                    capture_output=True, text=True, timeout=20)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('CLOCK_BACKEND_INTEGRATION_PASS', output)
            document = json.loads(store.read_text())
            self.assertEqual(document['timing']['timer']['state'], 'idle')
            self.assertEqual(document['timing']['stopwatch']['state'], 'idle')
            self.assertEqual(document['recents'], [5000])

    def test_stop_action_is_queued_while_a_command_is_in_flight(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shell = root / 'shell'
            shutil.copytree(ROOT / 'MacShell', shell)
            shutil.copy(ROOT / 'tests/clock-backend-queue.qml', shell / 'shell.qml')
            for name in ('config', 'cache', 'runtime'):
                (root / name).mkdir()
            (root / 'runtime').chmod(0o700)
            store = root / 'config/macshell/clock.json'
            now = int(time.time() * 1000)
            timing = migrate_legacy({'state': 'idle', 'total': 5000, 'left': 5000},
                                    boot_id(), boot_time_ms(), now, 'timer')
            timing['completion'] = {'eventId': 'event-a', 'sessionId': 'alarm-a', 'kind': 'alarm', 'label': 'Wake'}
            with ClockStore(store) as owner:
                owner.commit({'timing': timing}, 'missing', 0)
            env = dict(os.environ, XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'),
                       XDG_RUNTIME_DIR=str(root / 'runtime'), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='',
                       QT_QUICK_BACKEND='software', QT_QUICK_CONTROLS_STYLE='Basic',
                       DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
                       MACSHELL_CLOCK_TEST_STORE=str(store))
            env.pop('DISPLAY', None)
            env.pop('WAYLAND_DISPLAY', None)
            result = subprocess.run([quickshell(), '-p', str(shell)], env=env,
                                    capture_output=True, text=True, timeout=15)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('CLOCK_QUEUE_PASS', output)
            document = json.loads(store.read_text())
            self.assertIsNone(document['timing']['completion'])
            self.assertEqual(document['recents'], [60000])


if __name__ == '__main__':
    unittest.main()
