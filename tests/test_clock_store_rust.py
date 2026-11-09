import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'MacShell'))
from clock_store import ClockStore, ClockStoreBusy


class ClockStoreRustTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='clock-store-build-'); cls.addClassCleanup(cls.build.cleanup)
        subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path', str(ROOT / 'native/clock-core/Cargo.toml'), '--target-dir', cls.build.name, '--example', 'store'], check=True, timeout=120)
        cls.binary = Path(cls.build.name) / 'debug/examples/store'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'clock.json'

    def start(self):
        p = subprocess.Popen([str(self.binary), str(self.path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop, p)
        return p, json.loads(p.stdout.readline())

    @staticmethod
    def stop(p):
        if p.poll() is None: p.terminate()
        p.communicate(timeout=5)

    def command(self, p, **value):
        p.stdin.write(json.dumps(value) + '\n'); p.stdin.flush()
        return json.loads(p.stdout.readline())

    def test_python_rust_roundtrip_migration_and_exact_backup(self):
        original = b'{"timer":{"state":"paused"},"extension":{"text":"keep"}}\n'
        self.path.write_bytes(original)
        with ClockStore(self.path) as python:
            _, token = python.read()
        p, ready = self.start(); self.assertTrue(ready['ready'])
        rust = self.command(p, op='read'); self.assertEqual(rust['token'], token)
        result = self.command(p, op='commit', token=token, revision=0, patch={'timing': {'version': 1}})
        self.assertTrue(result['success'], result)
        self.assertEqual(result['document']['extension'], {'text': 'keep'})
        self.assertEqual(next(self.path.parent.glob('clock.before-v2-*.json')).read_bytes(), original)
        with self.assertRaises(ClockStoreBusy):
            with ClockStore(self.path): pass
        self.stop(p)
        with ClockStore(self.path) as python:
            document, token = python.read()
            self.assertEqual(token, result['token'])
            updated, _ = python.commit({'recents': [42]}, token, 1)
            self.assertEqual(updated['revision'], 2)

    def test_conflicts_and_invalid_data_are_not_overwritten(self):
        p, _ = self.start()
        result = self.command(p, op='commit', token='missing', revision=0, patch={'timing': {'version': 1}})
        before = self.path.read_bytes()
        self.assertFalse(self.command(p, op='commit', token=result['token'], revision=0, patch={'x': 1})['success'])
        self.assertEqual(self.path.read_bytes(), before)
        self.path.write_bytes(b'{broken')
        self.assertFalse(self.command(p, op='read')['success'])
        self.assertEqual(self.path.read_bytes(), b'{broken')

    def test_python_lock_blocks_rust(self):
        with ClockStore(self.path):
            p, response = self.start()
            self.assertFalse(response['success'])
            self.assertIn('owns the store', response['error'])
            self.stop(p)


if __name__ == '__main__': unittest.main()
