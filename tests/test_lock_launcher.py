import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'MacLock/lock-via-ipc.sh'


class LockLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.state = self.root / 'state'
        self.calls = self.root / 'calls'
        self.qs = self.bin / 'qs'
        self.qs.write_text('''#!/bin/sh
case "$*" in
  *'lockscreen state') [ ! -f "$STATE" ] || cat "$STATE" ;;
  *'lockscreen lock') printf 'lock\\n' >> "$CALLS"; printf busy > "$STATE" ;;
  *) exit 2 ;;
esac
''')
        self.qs.chmod(0o755)
        launcher = self.bin / 'systemd-run'
        launcher.write_text('''#!/bin/sh
printf 'systemd-run\\n' >> "$CALLS"
printf '%s\\n' "$@" > "$ARGS"
[ "${FAIL_START:-0}" = 0 ] || exit 1
printf ready > "$STATE"
sleep 0.1
''')
        launcher.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        XDG_RUNTIME_DIR=str(self.root), MACSHELL_QS_BIN=str(self.qs),
                        STATE=str(self.state), CALLS=str(self.calls), ARGS=str(self.root / 'args'),
                        WAYLAND_DISPLAY='wayland-test', MACSHELL_SETTINGS_HOME=str(self.root / 'settings'))

    def test_concurrent_requests_start_one_independent_service(self):
        children = [subprocess.Popen(['sh', str(SCRIPT)], env=self.env, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True) for _ in range(2)]
        for child in children:
            _out, error = child.communicate(timeout=5)
            self.assertEqual(child.returncode, 0, error)
        self.assertEqual(self.calls.read_text().splitlines(), ['systemd-run', 'lock'])
        args = (self.root / 'args').read_text().splitlines()
        self.assertIn('--unit=macshell-niri-lock', args)
        self.assertIn('--property=PartOf=niri-macshell.service graphical-session.target', args)
        self.assertIn('--setenv=WAYLAND_DISPLAY=wayland-test', args)
        self.assertIn('--setenv=MACSHELL_SETTINGS_HOME=' + str(self.root / 'settings'), args)
        self.assertEqual(args[-3:], [str(self.qs), '-c', 'MacLock-niri'])

    def test_start_failure_never_requests_a_lock(self):
        result = subprocess.run(['sh', str(SCRIPT)], env={**self.env, 'FAIL_START': '1'},
                                capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Could not start', result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ['systemd-run'])

    def test_busy_lock_is_left_alone(self):
        self.state.write_text('busy')
        result = subprocess.run(['sh', str(SCRIPT)], env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.calls.exists())


if __name__ == '__main__':
    unittest.main()
