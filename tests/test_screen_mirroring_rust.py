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

    def client(self, missing=False, **extra):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        folder = Path(temporary.name)
        fixture = (ROOT / 'tests/fixtures/airplay_backend.py').read_text()
        if not missing:
            for name in ('doubletake', 'uxplay'):
                executable = folder / name
                executable.write_text('#!' + sys.executable + '\n' + fixture)
                executable.chmod(0o755)
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
