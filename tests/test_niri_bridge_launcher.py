"""Exercise bridge selection using only temporary executables."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BridgeLauncherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copy2(ROOT / 'MacShell/niri-bridge.sh', self.root / 'niri-bridge.sh')
        (self.root / 'niri_ipc.py').write_text('# unused fixture\n')
        bindir = self.root / 'bin'; bindir.mkdir()
        python = bindir / 'python3'; python.write_text('#!/bin/sh\necho PYTHON_BRIDGE\n'); python.chmod(0o755)
        self.env = dict(os.environ, PATH=str(bindir) + ':/usr/bin:/bin')
        self.env.pop('MACSHELL_NIRI_BRIDGE_BACKEND', None)

    def binary(self, version):
        path = self.root / 'niri-bridge-rust'
        path.write_text('#!/bin/sh\nif [ "${1:-}" = --protocol-version ]; then echo ' + version + '; else echo RUST_BRIDGE; fi\n')
        path.chmod(0o755)

    def launch(self, selection=None):
        env = dict(self.env)
        if selection is not None: env['MACSHELL_NIRI_BRIDGE_BACKEND'] = selection
        return subprocess.run(['sh', str(self.root / 'niri-bridge.sh')], env=env, text=True, capture_output=True, timeout=5)

    def test_auto_prefers_compatible_rust_and_can_force_python(self):
        self.binary('"macshell-niri-bridge 1"')
        self.assertEqual(self.launch().stdout.strip(), 'RUST_BRIDGE')
        self.assertEqual(self.launch('rust').stdout.strip(), 'RUST_BRIDGE')
        self.assertEqual(self.launch('python').stdout.strip(), 'PYTHON_BRIDGE')

    def test_missing_or_incompatible_binary_falls_back_only_in_auto(self):
        self.assertEqual(self.launch().stdout.strip(), 'PYTHON_BRIDGE')
        self.assertNotEqual(self.launch('rust').returncode, 0)
        self.binary('"wrong protocol"')
        self.assertEqual(self.launch().stdout.strip(), 'PYTHON_BRIDGE')
        self.assertNotEqual(self.launch('rust').returncode, 0)
        self.assertNotEqual(self.launch('invalid').returncode, 0)


if __name__ == '__main__': unittest.main()
