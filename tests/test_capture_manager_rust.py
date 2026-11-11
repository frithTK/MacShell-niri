"""Combined preview manager with fake video and private ScreenCast D-Bus."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from urllib.parse import unquote, urlparse

from test_capture_session_rust import CaptureBus
from test_network_agent_rust import Harness
from scripts.install_niri import quickshell

BINARY = os.environ.get('MACSHELL_TEST_CAPTURE_MANAGER_HARNESS')
SERVICE = os.environ.get('MACSHELL_TEST_CAPTURE_SERVICE_BINARY')
ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_CAPTURE_MANAGER_HARNESS')
class CaptureManagerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='macshell-capture-test-')
        self.bus = CaptureBus()
        self.harness = Harness(self.bus.address, binary=BINARY, environment={
            'DBUS_SESSION_BUS_ADDRESS': self.bus.address,
            'MACSHELL_TEST_CAPTURE_PARENT': self.temp.name,
        })

    def tearDown(self):
        try:
            if self.harness: self.harness.close()
        finally:
            self.bus.close()
            self.temp.cleanup()

    def request(self, window):
        self.harness.process.stdin.write(json.dumps({'id': window}) + '\n')
        self.harness.process.stdin.flush()

    def frame(self, window):
        event = self.harness.wait(None, lambda v: v.get('id') == window and 'url' in v)
        return Path(unquote(urlparse(event['url']).path))

    def test_frames_are_private_and_old_window_is_evicted(self):
        self.request(1)
        first = self.frame(1)
        self.assertTrue(first.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'))
        self.assertEqual(first.stat().st_mode & 0o777, 0o600)
        self.assertEqual(first.parent.stat().st_mode & 0o777, 0o700)
        time.sleep(.85)
        self.request(2)
        second = self.frame(2)
        self.assertEqual(self.bus.stops, 1)
        self.assertFalse(first.exists())
        directory = second.parent
        self.harness.close()
        self.assertFalse(directory.exists())
        self.assertEqual(self.bus.stops, 2)
        # Avoid closing already-closed descriptors in tearDown.
        self.harness = None

    def test_stream_change_invalidates_frames_and_closes_session(self):
        self.request(7)
        first = self.frame(7)
        self.bus.signal_node(55)
        self.harness.wait(None, lambda v: v.get('id') == 7 and 'error' in v)
        self.assertFalse(first.exists())
        self.assertEqual(self.bus.stops, 1)

    def test_failed_start_is_cleaned_and_not_retried_during_cooldown(self):
        self.bus.mode = 'start_error'
        self.request(7)
        self.harness.wait(None, lambda v: v.get('id') == 7 and 'error' in v)
        self.assertEqual(self.bus.stops, 1)
        calls = len(self.bus.calls)
        self.request(7)
        time.sleep(.15)
        self.assertEqual(len(self.bus.calls), calls)

    def test_missing_first_frame_restarts_pipeline_within_same_session(self):
        self.harness.close()
        self.harness = Harness(self.bus.address, binary=BINARY, environment={
            'DBUS_SESSION_BUS_ADDRESS': self.bus.address,
            'MACSHELL_TEST_CAPTURE_PARENT': self.temp.name,
            'MACSHELL_TEST_CAPTURE_DELAY_FIRST_FRAME': '1',
        })
        deadline = time.monotonic() + 3.2
        while time.monotonic() < deadline:
            self.request(9)
            time.sleep(.15)
        self.assertTrue(self.frame(9).read_bytes().startswith(b'\x89PNG\r\n\x1a\n'))
        self.assertEqual(self.bus.stops, 0)

    @unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
    def test_qml_controller_loads_synthetic_png(self):
        self.harness.close()
        self.harness = None
        root = Path(self.temp.name)
        shell = root / 'shell'
        shutil.copytree(ROOT / 'MacShell', shell)
        shutil.copy(ROOT / 'tests/capture-rust.qml', shell / 'shell.qml')
        shutil.copy(BINARY, shell / 'capture-service-rust')
        (shell / 'niri_capture.py').write_text('raise SystemExit("unexpected Python fallback")\n')
        (shell / 'niri-bridge.sh').write_text('#!/bin/sh\nexec sleep 20\n')
        for name in ('runtime', 'config', 'cache'):
            (root / name).mkdir()
        (root / 'runtime').chmod(0o700)
        env = dict(os.environ, DBUS_SESSION_BUS_ADDRESS=self.bus.address,
            MACSHELL_TEST_CAPTURE_PARENT=str(root), XDG_RUNTIME_DIR=str(root / 'runtime'),
            XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'),
            QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='', QT_QUICK_BACKEND='software')
        env.pop('DISPLAY', None)
        env.pop('WAYLAND_DISPLAY', None)
        result = subprocess.run([quickshell(), '-p', str(shell)], env=env, capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('CAPTURE_RUST_QML_PASS', result.stdout + result.stderr)


@unittest.skipUnless(SERVICE, 'Set MACSHELL_TEST_CAPTURE_SERVICE_BINARY')
class CaptureLauncherTests(unittest.TestCase):
    def test_missing_plugins_refuse_native_protocol_and_launcher_falls_back(self):
        with tempfile.TemporaryDirectory(prefix='macshell-capture-launcher-') as temp:
            root = Path(temp)
            launcher = root / 'capture-service.sh'
            shutil.copy(ROOT / 'MacShell/capture-service.sh', launcher)
            (root / 'niri_capture.py').write_text('print("legacy")\n')
            binary = root / 'capture-service-rust'
            shutil.copy(SERVICE, binary)
            env = dict(os.environ, XDG_CACHE_HOME=str(root), GST_REGISTRY=str(root / 'registry.bin'),
                GST_PLUGIN_SYSTEM_PATH_1_0=str(root / 'missing'), GST_PLUGIN_PATH_1_0=str(root / 'missing'))
            check = subprocess.run([str(binary), '--protocol-version'], env=env, capture_output=True, text=True, timeout=5)
            self.assertNotEqual(check.returncode, 0)
            result = subprocess.run(['sh', str(launcher)], env=env, capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('legacy', result.stdout)
            self.assertIn('Rust', result.stderr)


if __name__ == '__main__':
    unittest.main()
