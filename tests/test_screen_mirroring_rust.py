import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import unittest

from test_dbus_protocol import Client
import test_screen_mirroring as original

ROOT = Path(__file__).resolve().parents[1]


class RustScreenMirroringTests(original.ScreenMirroringTests):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path',
                        str(ROOT / 'native/screen-mirroring/Cargo.toml'), '--target-dir', cls.build.name], check=True)
        cls.binary = Path(cls.build.name) / 'debug/macshell-screen-mirroring'

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def client(self, missing=False, virtual_niri=False, dummy_hdmi=False, **extra):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        folder = Path(temporary.name)
        fixture = (ROOT / 'tests/fixtures/airplay_backend.py').read_text()
        if not missing:
            for name in ('doubletake', 'uxplay'):
                executable = folder / name
                executable.write_text('#!' + sys.executable + '\n' + fixture)
                executable.chmod(0o755)
        sysfs = folder / 'drm-sysfs'
        debugfs = folder / 'drm-debugfs'
        sysfs.mkdir()
        debugfs.mkdir()
        extra.setdefault('MACSHELL_DRM_SYSFS', str(sysfs))
        extra.setdefault('MACSHELL_DRM_DEBUGFS', str(debugfs))
        pkexec = folder / 'pkexec'
        if dummy_hdmi:
            (sysfs / 'card1-HDMI-A-1').mkdir()
            (sysfs / 'card1-HDMI-A-1' / 'status').write_text('disconnected\n')
            (sysfs / 'card1-eDP-1').mkdir()
            (sysfs / 'card1-eDP-1' / 'status').write_text('connected\n')
        if virtual_niri or dummy_hdmi:
            state = folder / 'niri-state.json'
            state.write_text(json.dumps({'outputs': {
                'eDP-1': {'logical': {'x': 0, 'y': 0, 'width': 1920, 'height': 1080}},
            }, 'casts': []}))
            niri = folder / 'niri'
            script = (ROOT / 'tests/fixtures/niri_airplay.py').read_text().split('\n', 1)[-1]
            niri.write_text('#!' + sys.executable + '\n' + script)
            niri.chmod(0o755)
            extra.setdefault('NIRI_FAKE_STATE', str(state))
            extra.setdefault('NIRI_FAKE_LOG', str(folder / 'niri.log'))
            if virtual_niri:
                extra.setdefault('NIRI_FAKE_VIRTUAL', '1')
        if dummy_hdmi:
            pkexec.write_text('#!' + sys.executable + '\n' + """
import os, pathlib, sys
sysfs = pathlib.Path(os.environ['MACSHELL_DRM_SYSFS'])
(sysfs / 'card1-HDMI-A-1' / 'status').write_text('connected\\n')
sys.exit(0)
""")
            pkexec.chmod(0o755)
        elif not pkexec.exists():
            pkexec.write_text('#!/bin/sh\necho denied >&2; exit 1\n')
            pkexec.chmod(0o755)
        extra.setdefault('MACSHELL_PKEXEC', str(pkexec))
        environment = dict(os.environ, PATH=str(folder), XDG_CONFIG_HOME=str(folder / 'config'),
                           XDG_DATA_HOME=str(folder / 'data'), AIRPLAY_TEST_TRACE=str(folder / 'trace'), **extra)
        client = Client.__new__(Client)
        client.process = subprocess.Popen([str(self.binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, env=environment, text=True)
        client.queue = queue.Queue(); client.lines = []; client.sequence = 0
        def read():
            for line in client.process.stdout:
                client.queue.put(json.loads(line))
        client.thread = threading.Thread(target=read, daemon=True); client.thread.start()
        self.addCleanup(client.close)
        client.trace = folder / 'trace'
        client.niri_state = folder / 'niri-state.json'
        client.niri_log = folder / 'niri.log'
        client.wait(lambda m: m.get('type') == 'ready')
        return client

    def test_launcher_uses_compatible_rust_and_falls_back(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copy(ROOT / 'MacShell/screen-mirroring-service.sh', root)
            (root / 'screen_mirroring.py').write_text('print("python fallback")\n')
            binary = root / 'screen-mirroring-service-rust'
            launcher = ['sh', str(root / 'screen-mirroring-service.sh')]
            self.assertEqual(subprocess.check_output(launcher, text=True).strip(), 'python fallback')
            binary.write_text('#!/bin/sh\nif [ "$1" = --protocol-version ]; then printf "wrong\\n"; else printf "rust\\n"; fi\n')
            binary.chmod(0o755)
            self.assertEqual(subprocess.check_output(launcher, text=True).strip(), 'python fallback')
            shutil.copy(self.binary, binary)
            result = subprocess.run(launcher, input='', capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout.splitlines()[0])['type'], 'ready')

    def test_rust_sender_starts_at_60_fps_and_volume_20(self):
        client = self.client()
        self.discover(client)
        start = next(line for line in client.trace.read_text().splitlines() if 'doubletake' in line)
        data = json.loads(start)
        self.assertEqual(data['arguments'][data['arguments'].index('-fps') + 1], '60')
        self.assertEqual(data['arguments'][data['arguments'].index('-volume-percent') + 1], '20')

    def test_rust_old_doubletake_is_refused_instead_of_resetting_tv_to_100_percent(self):
        client = self.client(AIRPLAY_TEST_VOLUME_SUPPORT='0')
        client.send('watch', enabled=True)
        state = client.wait(lambda m: m.get('senderState') == 'error')
        self.assertIn('-volume-percent', state['senderError'])
        self.assertFalse(client.trace.exists())

    def test_extend_without_virtual_output_is_refused(self):
        client = self.client()
        state = self.discover(client)
        self.assertFalse(state.get('extendAvailable'))
        client.send('connect', key=state['devices'][0]['key'], layout='extend')
        error = client.wait(lambda m: m.get('type') == 'error')
        self.assertIn('virtual display', error['error'])
        self.assertFalse(any(line.get('request', {}).get('cmd') == 'connect' for line in self.trace(client)))

    def test_extend_creates_virtual_output_and_releases_it(self):
        client = self.client(virtual_niri=True)
        state = self.discover(client)
        self.assertTrue(state.get('virtualOutputsSupported'))
        self.assertTrue(state.get('extendAvailable'))
        self.assertEqual(state.get('extendOutput'), 'MacShell-AirPlay')
        client.send('connect', key=state['devices'][0]['key'], layout='extend')
        client.wait(lambda m: m.get('senderState') == 'pin_required')
        outputs = json.loads(client.niri_state.read_text())['outputs']
        self.assertIn('MacShell-AirPlay', outputs)
        self.assertGreater(outputs['MacShell-AirPlay']['logical']['x'], 0)
        log = client.niri_log.read_text()
        self.assertIn('create-virtual-output', log)
        client.send('disconnect')
        client.wait(lambda m: m.get('senderState') in ('ready', 'off'))
        self.assertNotIn('MacShell-AirPlay', json.loads(client.niri_state.read_text())['outputs'])
        self.assertIn('remove-virtual-output', client.niri_log.read_text())

    def test_extend_forces_disconnected_hdmi_through_authorization(self):
        client = self.client(dummy_hdmi=True)
        state = self.discover(client)
        self.assertFalse(state.get('virtualOutputsSupported'))
        self.assertTrue(state.get('extendAvailable'))
        self.assertEqual(state.get('extendMethod'), 'dummy')
        self.assertEqual(state.get('extendOutput'), 'HDMI-A-1')
        client.send('connect', key=state['devices'][0]['key'], layout='extend')
        client.wait(lambda m: m.get('senderState') == 'pin_required')
        self.assertIn('HDMI-A-1', json.loads(client.niri_state.read_text())['outputs'])
        client.send('disconnect')
        client.wait(lambda m: m.get('senderState') in ('ready', 'off'))
