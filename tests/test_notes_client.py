import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0, str(ROOT))
from scripts.install_niri import quickshell


@unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
class NotesClientTests(unittest.TestCase):
    def run_client(self, crash):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shell = root / 'shell'
            shutil.copytree(ROOT / 'MacShell', shell)
            shutil.copy(ROOT / 'tests/notes-client.qml', shell / 'shell.qml')
            service = shell / 'notes_service.py'
            service.rename(shell / 'notes_service_impl.py')
            service.write_text('''import os
from pathlib import Path
import notes_service_impl as impl
original = impl.NotesStore.save
def save(self, *args):
    marker = Path(os.environ['MACSHELL_NOTES_TEST_MARKER'])
    if not marker.exists() and os.environ['MACSHELL_NOTES_TEST_CRASH'] == 'before':
        marker.write_text('before commit'); os._exit(42)
    result = original(self, *args)
    if not marker.exists() and os.environ['MACSHELL_NOTES_TEST_CRASH'] == 'after':
        marker.write_text('after commit'); os._exit(42)
    return result
impl.NotesStore.save = save
raise SystemExit(impl.main())
''')
            for name in ('config', 'cache', 'runtime'):
                (root / name).mkdir()
            (root / 'runtime').chmod(0o700)
            store = root / 'data/notes.sqlite3'
            env = dict(os.environ, XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'),
                       XDG_RUNTIME_DIR=str(root / 'runtime'), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='',
                       QT_QUICK_CONTROLS_STYLE='Basic', DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
                       MACSHELL_NOTES_TEST_STORE=str(store), MACSHELL_NOTES_TEST_MARKER=str(root / 'crashed'),
                       MACSHELL_NOTES_TEST_CRASH=crash)
            env.pop('DISPLAY', None); env.pop('WAYLAND_DISPLAY', None)
            result = subprocess.run([quickshell(), '-p', str(shell)], env=env, capture_output=True, text=True, timeout=16)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('NOTES_CLIENT_PASS', output)
            self.assertEqual((root / 'crashed').read_text(), crash + ' commit')
            with sqlite3.connect(store) as db:
                self.assertEqual(db.execute('SELECT body, revision FROM notes').fetchall(), [('Последнее изменение 🌍', 2)])

    def test_retry_after_crash_before_commit(self):
        self.run_client('before')

    def test_retry_after_crash_after_commit_without_losing_new_edits(self):
        self.run_client('after')


if __name__ == '__main__':
    unittest.main()
