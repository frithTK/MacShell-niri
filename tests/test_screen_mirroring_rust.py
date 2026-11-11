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
            edid = bytearray(128)
            edid[77:85] = b'MacShell'
            (sysfs / 'card1-HDMI-A-1' / 'edid').write_bytes(bytes(edid))
            pkexec.write_text('#!' + sys.executable + '\n' + """
import os, pathlib, sys
sysfs = pathlib.Path(os.environ['MACSHELL_DRM_SYSFS'])
action = sys.argv[-2] if len(sys.argv) >= 2 else 'on'
status = 'connected\\n' if action == 'on' else 'disconnected\\n'
(sysfs / 'card1-HDMI-A-1' / 'status').write_text(status)
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

    def test_launcher_uses_compatible_rust_and_refuses_missing(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copy(ROOT / 'MacShell/screen-mirroring-service.sh', root)
            (root / 'screen_mirroring.py').write_text('print("python fallback")\n')
            binary = root / 'screen-mirroring-service-rust'
            launcher = ['sh', str(root / 'screen-mirroring-service.sh')]
            missing = subprocess.run(launcher, capture_output=True, text=True)
            self.assertNotEqual(missing.returncode, 0)
            self.assertNotIn('python fallback', missing.stdout)
            self.assertIn('Rust', missing.stderr)
            binary.write_text('#!/bin/sh\nif [ "$1" = --protocol-version ]; then printf "wrong\\n"; else printf "rust\\n"; fi\n')
            binary.chmod(0o755)
            incompatible = subprocess.run(launcher, capture_output=True, text=True)
            self.assertNotEqual(incompatible.returncode, 0)
            self.assertNotIn('python fallback', incompatible.stdout)
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

    def test_extend_preference_is_ignored_and_mirrors(self):
        client = self.client()
        state = self.discover(client)
        client.send('connect', key=state['devices'][0]['key'], layout='extend')
        connected = client.wait(lambda m: m.get('senderState') == 'pin_required')
        self.assertEqual(connected.get('layout'), 'mirror')
        self.assertTrue(any(line.get('request', {}).get('cmd') == 'connect' for line in self.trace(client)))

    def test_extend_does_not_create_a_virtual_output(self):
        client = self.client(virtual_niri=True)
        state = self.discover(client)
        self.assertTrue(state.get('virtualOutputsSupported'))
        client.send('connect', key=state['devices'][0]['key'], layout='extend')
        client.wait(lambda m: m.get('senderState') == 'pin_required')
        self.assertNotIn('MacShell-AirPlay', json.loads(client.niri_state.read_text())['outputs'])
        self.assertNotIn('create-virtual-output', client.niri_log.read_text())

    def test_extend_does_not_force_hdmi_dummy(self):
        client = self.client(dummy_hdmi=True)
        state = self.discover(client)
        client.send('connect', key=state['devices'][0]['key'], layout='extend')
        client.wait(lambda m: m.get('senderState') == 'pin_required')
        self.assertNotIn('HDMI-A-1', json.loads(client.niri_state.read_text())['outputs'])

    def test_mirror_turns_off_leftover_macshell_dummy(self):
        client = self.client(dummy_hdmi=True)
        sysfs = Path(client.niri_state).parent / 'drm-sysfs'
        (sysfs / 'card1-HDMI-A-1' / 'status').write_text('connected\n')
        client.niri_state.write_text(json.dumps({'outputs': {
            'eDP-1': {'logical': {'x': 0, 'y': 0, 'width': 1920, 'height': 1080}},
            'HDMI-A-1': {'logical': {'x': 1920, 'y': 0, 'width': 1920, 'height': 1080}},
        }, 'casts': []}))
        state = self.discover(client)
        client.send('connect', key=state['devices'][0]['key'], layout='mirror')
        client.wait(lambda m: m.get('senderState') == 'pin_required')
        self.assertNotIn('HDMI-A-1', json.loads(client.niri_state.read_text())['outputs'])
        self.assertEqual((sysfs / 'card1-HDMI-A-1' / 'status').read_text().strip(), 'disconnected')
