import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.install_niri import quickshell
from tests.service_launchers import copy_macshell_with_python_launchers


@unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
class CalendarStandaloneTests(unittest.TestCase):
    def test_independent_window_uses_own_data_and_exits_on_close(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('home', 'cache', 'config', 'data', 'runtime'):
                (root / name).mkdir()
            (root / 'runtime').chmod(0o700)
            env = dict(os.environ, HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'config'),
                       XDG_CACHE_HOME=str(root / 'cache'), XDG_RUNTIME_DIR=str(root / 'runtime'),
                       XDG_DATA_HOME=str(root / 'data'), MACSHELL_CALENDAR_DATA_HOME=str(root / 'data'),
                       QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic',
                       DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
            env.pop('DISPLAY', None); env.pop('WAYLAND_DISPLAY', None)
            config = str(copy_macshell_with_python_launchers(ROOT / 'MacShell', root / 'shell') / 'calendar-standalone.qml')
            process = subprocess.Popen([quickshell(), '-p', config], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            try:
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline and process.poll() is None:
                    result = subprocess.run([quickshell(), '-p', config, 'ipc', 'call', 'calendarPreview', 'state'],
                                            env=env, capture_output=True, text=True, timeout=2)
                    if result.returncode == 0:
                        try: state = json.loads(result.stdout)
                        except ValueError: state = {}
                        if state.get('ready') and state.get('visible') and not state.get('busy'):
                            break
                    time.sleep(.1)
                else:
                    detail = process.stdout.read() if process.poll() is not None else 'Timed out waiting for IPC'
                    self.fail('Standalone Calendar did not start: ' + detail)
                subprocess.run([quickshell(), '-p', config, 'ipc', 'call', 'calendarPreview', 'close'],
                               env=env, capture_output=True, text=True, timeout=3, check=True)
                output, _ = process.communicate(timeout=6)
                self.assertEqual(process.returncode, 0, output)
                self.assertNotIn('TypeError', output)
                store = root / 'data/macshell/calendar/events.sqlite3'
                with sqlite3.connect(store) as db:
                    self.assertEqual(db.execute('SELECT COUNT(*) FROM events').fetchone()[0], 0)
            finally:
                if process.poll() is None:
                    process.terminate(); process.communicate(timeout=5)
                elif process.stdout:
                    process.stdout.close()


if __name__ == '__main__':
    unittest.main()
