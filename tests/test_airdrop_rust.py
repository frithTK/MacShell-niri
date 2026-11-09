import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading

from test_dbus_protocol import Client
import test_airdrop as original

ROOT = Path(__file__).resolve().parents[1]


class RustAirDropTests(original.AirDropTests):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path',
                        str(ROOT / 'native/airdrop-service/Cargo.toml'), '--target-dir', cls.build.name], check=True)
        cls.binary = Path(cls.build.name) / 'debug/macshell-airdrop-service'

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def client(self, missing=False, **extra):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        folder = Path(temporary.name)
        if not missing:
            executable = folder / 'owly'
            executable.write_text('#!' + sys.executable + '\n' + (ROOT / 'tests/fixtures/owly_backend.py').read_text())
            executable.chmod(0o755)
        environment = dict(os.environ, PATH=str(folder), XDG_CONFIG_HOME=str(folder / 'config'),
                           XDG_DATA_HOME=str(folder / 'data'), MACSHELL_AIRDROP_DOWNLOADS=str(folder / 'downloads'),
                           AIRDROP_TEST_TRACE=str(folder / 'trace'), **extra)
        client = Client.__new__(Client)
        client.process = subprocess.Popen([str(self.binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, env=environment, text=True)
        client.queue = queue.Queue(); client.lines = []; client.sequence = 0
        def read():
            for line in client.process.stdout:
                client.queue.put(json.loads(line))
        client.thread = threading.Thread(target=read, daemon=True); client.thread.start()
        self.addCleanup(client.close); client.folder = folder
        client.wait(lambda state: state.get('type') == 'ready')
        return client

    def test_local_file_validation_rejects_remote_missing_and_directories(self):
        client = self.client()
        path = client.folder / 'фото #1.jpg'; path.write_bytes(b'test')
        client.send('files', paths=[path.as_uri(), str(path)])
        self.assertEqual(len(client.wait(lambda s: s.get('files'))['files']), 1)
        for value in ('https://example.org/file', 'file://other-host/file', str(client.folder), str(path) + '.missing'):
            client.send('files', paths=[value])
            client.wait(lambda s: s.get('type') == 'error')

    def test_launcher_selects_compatible_rust_or_python_fallback(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copy(ROOT / 'MacShell/airdrop-service.sh', root)
            (root / 'airdrop_service.py').write_text('print("python fallback")\n')
            binary = root / 'airdrop-service-rust'
            launcher = ['sh', str(root / 'airdrop-service.sh')]
            self.assertEqual(subprocess.check_output(launcher, text=True).strip(), 'python fallback')
            binary.write_text('#!/bin/sh\nprintf "wrong\\n"\n'); binary.chmod(0o755)
            self.assertEqual(subprocess.check_output(launcher, text=True).strip(), 'python fallback')
            shutil.copy(self.binary, binary)
            result = subprocess.run(launcher, input='', capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout.splitlines()[0])['type'], 'ready')
