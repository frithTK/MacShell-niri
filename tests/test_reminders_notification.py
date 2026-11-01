import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.install_niri import quickshell


@unittest.skipUnless(shutil.which(quickshell()) and shutil.which('dbus-run-session') and shutil.which('notify-send') and importlib.util.find_spec('gi'), 'Quickshell, notify-send, D-Bus and PyGObject are required')
class RemindersNotificationTests(unittest.TestCase):
    def test_real_notification_with_private_bus_and_closed_window(self):
        env = dict(os.environ, MACSHELL_TEST_PARENT_BUS=os.environ.get('DBUS_SESSION_BUS_ADDRESS', ''))
        result = subprocess.run(['dbus-run-session', '--', sys.executable, str(ROOT / 'tests/fixtures/reminders_notification_dbus.py')],
                                env=env, capture_output=True, text=True, timeout=35)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('REMINDERS_DBUS_PASS', result.stdout)


if __name__ == '__main__': unittest.main()
