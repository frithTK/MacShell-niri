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
from scripts.install_niri import quickshell
from tests.service_launchers import point_copied_launchers_at_python


@unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
class ClockRecoveryIntegrationTests(unittest.TestCase):
    def test_real_buttons_restore_and_discard_individual_snoozes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shell = root / 'shell'
            shutil.copytree(ROOT / 'MacShell', shell)
            point_copied_launchers_at_python(shell)
            shutil.copy(ROOT / 'tests/clock-recovery-integration.qml', shell / 'shell.qml')
            for name in ('config', 'cache', 'runtime'):
                (root / name).mkdir()
            (root / 'runtime').chmod(0o700)
            store = root / 'config/macshell/clock.json'
            store.parent.mkdir()
            wall_now = int(time.time() * 1000)
            legacy = {'snoozes': [{'at': wall_now + 120000, 'label': 'Tea'},
                                  {'at': wall_now + 180000, 'label': 'Meeting'}]}
            original = json.dumps(legacy).encode()
            store.write_bytes(original)
            environment = dict(os.environ, XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'),
                               XDG_RUNTIME_DIR=str(root / 'runtime'), QT_QPA_PLATFORM='offscreen',
                               QT_QPA_PLATFORMTHEME='', QT_QUICK_BACKEND='software', QT_QUICK_CONTROLS_STYLE='Basic',
                               DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
                               MACSHELL_CLOCK_TEST_STORE=str(store))
            environment.pop('DISPLAY', None)
            environment.pop('WAYLAND_DISPLAY', None)
            result = subprocess.run([quickshell(), '-p', str(shell)], env=environment,
                                    capture_output=True, text=True, timeout=15)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('CLOCK_RECOVERY_INTEGRATION_PASS', output)
            document = json.loads(store.read_text())
            self.assertEqual(document['timing']['legacySnoozesRecovery'], [])
            self.assertEqual([item['label'] for item in document['timing']['snoozes']], ['Tea'])
            self.assertEqual(next(store.parent.glob('clock.before-v2-*.json')).read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
