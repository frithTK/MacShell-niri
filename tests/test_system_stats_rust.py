"""Protocol and QML checks for the optional built Rust system sampler."""
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
sys.path.insert(0, str(ROOT))
from scripts.install_niri import quickshell

BINARY = os.environ.get('MACSHELL_TEST_STATS_BINARY')


class Client:
    def __init__(self, command, env=None):
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b''

    def message(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                message = json.loads(line)
                if predicate(message):
                    return message
            if self.selector.select(max(0, deadline - time.monotonic())):
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    break
                self.buffer += chunk
        raise AssertionError('Timed out waiting for service response')

    def send(self, request):
        self.process.stdin.write(json.dumps(request).encode() + b'\n')
        self.process.stdin.flush()

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=5)
        self.selector.close()
        self.process.stdout.close()
        self.process.stderr.close()


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_STATS_BINARY to test Rust system stats')
class RustSystemStatsTests(unittest.TestCase):
    def test_launcher_prefers_compatible_binary_and_falls_back(self):
        with tempfile.TemporaryDirectory() as directory:
            shell = Path(directory)
            shutil.copy(ROOT / 'MacShell/system-stats.sh', shell / 'system-stats.sh')
            (shell / 'system_stats.py').write_text('print("legacy")\n')
            binary = shell / 'system-stats-rust'
            binary.write_text('#!/bin/sh\nif [ "${1-}" = --protocol-version ]; then echo "macshell-system-stats 1"; else echo rust; fi\n')
            binary.chmod(0o755)
            def launch():
                return subprocess.run(['sh', str(shell / 'system-stats.sh')], capture_output=True,
                                      text=True, timeout=5, check=True).stdout.strip()
            self.assertEqual(launch(), 'rust')
            binary.write_text('#!/bin/sh\necho incompatible\n')
            self.assertEqual(launch(), 'legacy')
            binary.unlink()
            self.assertEqual(launch(), 'legacy')

    def test_closed_output_exits_cleanly(self):
        process = subprocess.Popen([BINARY], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        process.stdout.close()
        try:
            self.assertEqual(process.wait(timeout=5), 0)
            self.assertEqual(process.stderr.read(), b'')
        finally:
            process.stdin.close()
            process.stderr.close()

    def test_protocol_reconfiguration_and_clean_eof(self):
        client = Client([BINARY])
        try:
            self.assertEqual(client.message(lambda m: m.get('type') == 'ready'), {'type': 'ready'})
            client.send({'action': 'configure', 'generation': 37, 'data': {'interval': 1, 'interface': 'missing-iface', 'device': 'missing-device'}})
            sample = client.message(lambda m: m.get('type') == 'sample' and m.get('generation') == 37)
            self.assertTrue(sample['gap'])
            self.assertIsNone(sample['cpu'])
            self.assertEqual(sample['interface'], '')
            self.assertEqual(sample['device'], '')
            self.assertIsNone(sample['network'])
            self.assertIsNone(sample['disk'])
            self.assertGreater(sample['memory']['total'], 0)
            following = client.message(lambda m: m.get('type') == 'sample' and m.get('generation') == 37)
            self.assertFalse(following['gap'])
            self.assertGreater(following['time'], sample['time'])
            client.send({'action': 'configure', 'generation': 38, 'data': {'interval': 2}})
            reset = client.message(lambda m: m.get('type') == 'sample' and m.get('generation') == 38)
            self.assertTrue(reset['gap'])
            self.assertIsNone(reset['cpu'])
            client.process.stdin.write(b'{invalid json}\n'); client.process.stdin.flush()
            error = client.message(lambda m: m.get('type') == 'error')
            self.assertEqual(error['generation'], 38)
        finally:
            client.close()
        self.assertEqual(client.process.returncode, 0)

    def test_live_sample_matches_python_shape_and_memory(self):
        clients = [Client([sys.executable, '-u', str(ROOT / 'MacShell/system_stats.py')]), Client([BINARY])]
        try:
            samples = []
            for client in clients:
                client.message(lambda m: m.get('type') == 'ready')
                client.send({'action': 'configure', 'generation': 1, 'data': {'interval': 1}})
                samples.append(client.message(lambda m: m.get('type') == 'sample' and m.get('generation') == 1))
            self.assertEqual(set(samples[0]), set(samples[1]))
            for key in ('interface', 'interfaces', 'device', 'devices', 'diskLabel'):
                self.assertEqual(samples[0][key], samples[1][key], key)
            self.assertEqual(samples[0]['memory']['total'], samples[1]['memory']['total'])
            self.assertEqual(samples[0]['memory']['swapTotal'], samples[1]['memory']['swapTotal'])
            if samples[0]['capacity'] is not None and samples[1]['capacity'] is not None:
                self.assertEqual(samples[0]['capacity']['total'], samples[1]['capacity']['total'])
        finally:
            for client in clients:
                client.close()

    @unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
    def test_qml_uses_rust_and_recovers_from_missing_devices(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); shell = root / 'shell'
            shutil.copytree(ROOT / 'MacShell', shell)
            shutil.copy(ROOT / 'tests/system-stats-rust.qml', shell / 'shell.qml')
            shutil.copy(BINARY, shell / 'system-stats-rust')
            (shell / 'system_stats.py').write_text('raise SystemExit("unexpected Python fallback")\n')
            for name in ('runtime', 'config', 'cache'):
                (root / name).mkdir()
            (root / 'runtime').chmod(0o700)
            env = dict(os.environ, XDG_RUNTIME_DIR=str(root / 'runtime'), XDG_CONFIG_HOME=str(root / 'config'),
                       XDG_CACHE_HOME=str(root / 'cache'), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='',
                       QT_QUICK_BACKEND='software', DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
            env.pop('DISPLAY', None); env.pop('WAYLAND_DISPLAY', None)
            result = subprocess.run([quickshell(), '-p', str(shell)], env=env, capture_output=True, text=True, timeout=16)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('STATS_RUST_QML_PASS', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
