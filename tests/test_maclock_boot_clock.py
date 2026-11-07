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


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'MacLock/boot_clock.py'
RUST_BINARY = os.environ.get('MACSHELL_TEST_BOOT_CLOCK_BINARY')
sys.path.insert(0, str(ROOT))
from scripts.install_niri import quickshell


class MacLockBootClockTests(unittest.TestCase):
    def test_launcher_chooses_compatible_binary_and_falls_back(self):
        with tempfile.TemporaryDirectory() as directory:
            shell = Path(directory)
            shutil.copy(ROOT / 'MacLock/boot-clock.sh', shell / 'boot-clock.sh')
            (shell / 'boot_clock.py').write_text('print("legacy")\n')
            binary = shell / 'boot-clock-rust'
            binary.write_text('#!/bin/sh\nif [ "$1" = --protocol-version ]; then echo "macshell-boot-clock 1"; else echo rust; fi\n')
            binary.chmod(0o755)
            def launch():
                return subprocess.run(['sh', str(shell / 'boot-clock.sh'), '--once'],
                                      check=True, capture_output=True, text=True, timeout=5).stdout.strip()
            self.assertEqual(launch(), 'rust')
            binary.write_text('#!/bin/sh\necho incompatible\n')
            self.assertEqual(launch(), 'legacy')
            binary.unlink()
            self.assertEqual(launch(), 'legacy')

    @unittest.skipUnless(RUST_BINARY, 'Set MACSHELL_TEST_BOOT_CLOCK_BINARY to test Rust clock')
    def test_rust_clock_once_and_stream(self):
        once = subprocess.run([RUST_BINARY, '--once'], capture_output=True, text=True, timeout=3, check=True)
        samples = [json.loads(line) for line in once.stdout.splitlines()]
        self.assertEqual(len(samples), 1)
        self.assertEqual(samples[0]['bootId'], Path('/proc/sys/kernel/random/boot_id').read_text().strip())
        now = time.clock_gettime_ns(time.CLOCK_BOOTTIME) // 1_000_000
        self.assertLess(abs(now - samples[0]['bootMs']), 2000)
        process = subprocess.Popen([RUST_BINARY], stdout=subprocess.PIPE, text=True)
        try:
            first = json.loads(process.stdout.readline())
            second = json.loads(process.stdout.readline())
            self.assertEqual(first['bootId'], second['bootId'])
            self.assertGreater(second['bootMs'], first['bootMs'])
        finally:
            process.terminate()
            process.wait(timeout=3)
            process.stdout.close()

    def test_stream_reports_current_boot_and_advancing_boottime(self):
        process = subprocess.Popen([sys.executable, '-u', str(SCRIPT)], stdout=subprocess.PIPE)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        try:
            samples = []
            buffer = b''
            deadline = time.monotonic() + 3
            while len(samples) < 2 and time.monotonic() < deadline:
                if not selector.select(max(0, deadline - time.monotonic())):
                    break
                chunk = os.read(process.stdout.fileno(), 4096)
                if not chunk:
                    break
                buffer += chunk
                while b'\n' in buffer:
                    line, buffer = buffer.split(b'\n', 1)
                    samples.append(json.loads(line))
            self.assertGreaterEqual(len(samples), 2)
            boot_id = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
            self.assertEqual(samples[0]['bootId'], boot_id)
            self.assertEqual(samples[1]['bootId'], boot_id)
            self.assertGreater(samples[1]['bootMs'], samples[0]['bootMs'])
            now = time.clock_gettime_ns(time.CLOCK_BOOTTIME) // 1_000_000
            self.assertLess(abs(now - samples[1]['bootMs']), 2000)
        finally:
            process.terminate()
            process.wait(timeout=3)
            selector.close()
            process.stdout.close()

    @unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
    def test_stalled_provider_is_marked_unavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shell = root / 'shell'
            shell.mkdir()
            shutil.copy(ROOT / 'MacLock/BootClock.qml', shell / 'BootClock.qml')
            shutil.copy(ROOT / 'MacLock/boot-clock.sh', shell / 'boot-clock.sh')
            shutil.copy(ROOT / 'tests/boot-clock-watchdog.qml', shell / 'shell.qml')
            (shell / 'boot_clock.py').write_text('import time\nprint(\'{"bootId":"boot-a","bootMs":1000}\', flush=True)\ntime.sleep(20)\n')
            for name in ('runtime', 'config', 'cache'):
                (root / name).mkdir()
            (root / 'runtime').chmod(0o700)
            env = dict(os.environ, XDG_RUNTIME_DIR=str(root / 'runtime'), XDG_CONFIG_HOME=str(root / 'config'),
                       XDG_CACHE_HOME=str(root / 'cache'), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='',
                       QT_QUICK_BACKEND='software', DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
            env.pop('DISPLAY', None)
            env.pop('WAYLAND_DISPLAY', None)
            result = subprocess.run([quickshell(), '-p', str(shell)], env=env, capture_output=True, text=True, timeout=9)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('MACLOCK_BOOT_WATCHDOG_PASS', output)

    @unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
    def test_paused_clock_reads_boot_identity_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shell = root / 'shell'
            shell.mkdir()
            shutil.copy(ROOT / 'MacLock/BootClock.qml', shell / 'BootClock.qml')
            shutil.copy(ROOT / 'MacLock/boot-clock.sh', shell / 'boot-clock.sh')
            shutil.copy(SCRIPT, shell / 'boot_clock.py')
            if RUST_BINARY:
                shutil.copy(RUST_BINARY, shell / 'boot-clock-rust')
            shutil.copy(ROOT / 'tests/boot-clock-once.qml', shell / 'shell.qml')
            for name in ('runtime', 'config', 'cache'):
                (root / name).mkdir()
            (root / 'runtime').chmod(0o700)
            env = dict(os.environ, XDG_RUNTIME_DIR=str(root / 'runtime'), XDG_CONFIG_HOME=str(root / 'config'),
                       XDG_CACHE_HOME=str(root / 'cache'), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='',
                       QT_QUICK_BACKEND='software', DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
            env.pop('DISPLAY', None)
            env.pop('WAYLAND_DISPLAY', None)
            result = subprocess.run([quickshell(), '-p', str(shell)], env=env, capture_output=True, text=True, timeout=9)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('MACLOCK_BOOT_ONCE_PASS', output)

    @unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
    def test_provider_switches_between_paused_and_running_modes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shell = root / 'shell'
            shell.mkdir()
            shutil.copy(ROOT / 'MacLock/BootClock.qml', shell / 'BootClock.qml')
            shutil.copy(ROOT / 'MacLock/boot-clock.sh', shell / 'boot-clock.sh')
            shutil.copy(SCRIPT, shell / 'boot_clock.py')
            if RUST_BINARY:
                shutil.copy(RUST_BINARY, shell / 'boot-clock-rust')
            shutil.copy(ROOT / 'tests/boot-clock-modes.qml', shell / 'shell.qml')
            for name in ('runtime', 'config', 'cache'):
                (root / name).mkdir()
            (root / 'runtime').chmod(0o700)
            env = dict(os.environ, XDG_RUNTIME_DIR=str(root / 'runtime'), XDG_CONFIG_HOME=str(root / 'config'),
                       XDG_CACHE_HOME=str(root / 'cache'), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='',
                       QT_QUICK_BACKEND='software', DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
            env.pop('DISPLAY', None)
            env.pop('WAYLAND_DISPLAY', None)
            result = subprocess.run([quickshell(), '-p', str(shell)], env=env, capture_output=True, text=True, timeout=12)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('MACLOCK_BOOT_MODES_PASS', output)


if __name__ == '__main__':
    unittest.main()
