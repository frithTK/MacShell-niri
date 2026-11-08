import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

from MacShell import currency_fetch


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'native/currency-fetch/Cargo.toml'


class CurrencyRustCompatibilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='macshell-currency-build-')
        cls.addClassCleanup(cls.build.cleanup)
        env = dict(os.environ)
        env.pop('MACSHELL_CURRENCY_TEST_API', None)
        subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path', str(MANIFEST), '--target-dir', cls.build.name], env=env, check=True, timeout=180)
        cls.binary = Path(cls.build.name) / 'debug/macshell-currency-fetch'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / 'cache/rates.json'
        self.snapshot = {'version': 1, 'provider': 'frankfurter-v2', 'fetchedAt': int(time.time() * 1000),
                         'rates': {'USD': 1, 'EUR': .9}, 'dates': {'USD': '2026-01-01', 'EUR': '2026-01-01'},
                         'names': {'USD': 'US Dollar', 'EUR': 'Euro'}}

    def run_rust(self, path):
        result = subprocess.run([str(self.binary), '17', '--cache', str(path)], capture_output=True, text=True, check=True, timeout=10)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_python_cache_read_by_rust_without_network(self):
        currency_fetch.save_cache(self.path, self.snapshot)
        before = self.path.read_bytes()
        messages = self.run_rust(self.path)
        self.assertEqual([m['type'] for m in messages], ['cache', 'result'])
        self.assertEqual(messages[-1]['snapshot'], self.snapshot)
        self.assertEqual(messages[-1]['epoch'], 17)
        self.assertEqual(self.path.read_bytes(), before)

    def test_launcher_selects_rust_and_fallback(self):
        shell = self.root / 'shell'
        shell.mkdir()
        shutil.copy(ROOT / 'MacShell/currency-fetch.sh', shell)
        shutil.copy(ROOT / 'MacShell/currency_fetch.py', shell)
        shutil.copy(self.binary, shell / 'currency-fetch-rust')
        check = subprocess.run(['sh', str(shell / 'currency-fetch.sh'), '--protocol-version'], capture_output=True, text=True, check=True, timeout=5)
        self.assertEqual(check.stdout.strip(), 'macshell-currency-fetch 1')
        (shell / 'currency-fetch-rust').unlink()
        currency_fetch.save_cache(self.path, self.snapshot)
        result = subprocess.run(['sh', str(shell / 'currency-fetch.sh'), '22', '--cache', str(self.path)], capture_output=True, text=True, check=True, timeout=5)
        self.assertEqual(json.loads(result.stdout.splitlines()[-1])['snapshot'], self.snapshot)


if __name__ == '__main__':
    unittest.main()
