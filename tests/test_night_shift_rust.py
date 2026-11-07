"""Exercise the Rust Night Shift owner with a synthetic wlsunset only."""
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.install_niri import quickshell

BINARY = os.environ.get('MACSHELL_TEST_NIGHT_SHIFT_BINARY')
TRACE = '[123] -> zwlr_gamma_control_v1#9.set_gamma(fd 4)'


class Client:
    def __init__(self, command, environment):
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env=dict(os.environ, **environment))
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b''
        self.lines = []

    def wait(self, predicate, timeout=7):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                message = json.loads(line); self.lines.append(message)
                if predicate(message): return message
            if self.selector.select(max(0, deadline - time.monotonic())):
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk: break
                self.buffer += chunk
        raise AssertionError('Timed out waiting for Night Shift response')

    def send(self, **data):
        self.process.stdin.write(json.dumps({'action': 'configure', 'generation': 7, 'data': data}).encode() + b'\n')
        self.process.stdin.flush()

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            self.process.kill(); self.process.wait(timeout=3)
            raise
        finally:
            self.selector.close()
            self.process.stdout.close()
            self.process.stderr.close()


def fake_wlsunset(folder, trace, delay=0, close_stderr=False, late_failure=False, exit_after_trace=False, flood=False):
    script = ('#!' + sys.executable + '\n'
              'import json, os, signal, sys, time\n'
              'signal.signal(signal.SIGINT, lambda *_: sys.exit(0))\n'
              'with open(os.environ["NIGHT_TEST_STARTS"], "a") as log: '
              'log.write(json.dumps({"pid": os.getpid(), "args": sys.argv}) + "\\n")\n'
              f'time.sleep({delay!r})\n'
              f'print({trace!r}, file=sys.stderr, flush=True)\n'
              + ('os.close(2)\n' if close_stderr else '')
              + ('time.sleep(1.5)\nprint("zwlr_gamma_control_v1#9.failed()", file=sys.stderr, flush=True)\n' if late_failure else '')
              + ('sys.exit(0)\n' if exit_after_trace else
                 'while True: os.write(2, b"x" * 8192)\n' if flood else 'time.sleep(30)\n'))
    path = folder / 'wlsunset'; path.write_text(script); path.chmod(0o755)


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_NIGHT_SHIFT_BINARY to test Rust Night Shift')
class NightShiftRustTests(unittest.TestCase):
    def test_launcher_prefers_compatible_binary_and_falls_back(self):
        with tempfile.TemporaryDirectory() as directory:
            shell = Path(directory)
            shutil.copy(ROOT / 'MacShell/night-shift.sh', shell / 'night-shift.sh')
            (shell / 'night_shift.py').write_text('print("legacy")\n')
            binary = shell / 'night-shift-rust'
            binary.write_text('#!/bin/sh\nif [ "${1-}" = --protocol-version ]; then echo "macshell-night-shift 1"; else echo rust; fi\n')
            binary.chmod(0o755)
            def launch():
                return subprocess.run(['sh', str(shell / 'night-shift.sh')], capture_output=True,
                                      text=True, timeout=5, check=True).stdout.strip()
            self.assertEqual(launch(), 'rust')
            binary.write_text('#!/bin/sh\necho incompatible\n')
            self.assertEqual(launch(), 'legacy')
            binary.unlink()
            self.assertEqual(launch(), 'legacy')

    def client(self, trace=TRACE, delay=0, close_stderr=False, late_failure=False, exit_after_trace=False, flood=False):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        folder = Path(temp.name)
        if trace is not None: fake_wlsunset(folder, trace, delay, close_stderr, late_failure, exit_after_trace, flood)
        client = Client([BINARY], {'PATH': str(folder), 'NIGHT_TEST_STARTS': str(folder / 'starts')})
        client.starts = folder / 'starts'
        self.addCleanup(client.close)
        client.wait(lambda m: m.get('type') == 'ready')
        return client

    def test_missing_program_reports_unavailable(self):
        client = self.client(None)
        client.send(enabled=True, temperature=4000)
        state = client.wait(lambda m: m.get('state') == 'unavailable')
        self.assertFalse(state['available'])
        self.assertIn('Install wlsunset', state['error'])

    def test_idle_sigterm_wakes_service_and_exits(self):
        client = self.client(None)
        client.process.terminate()
        self.assertEqual(client.process.wait(timeout=3), 0)

    def test_fragmented_request_and_invalid_input(self):
        client = self.client(None)
        request = json.dumps({'action': 'configure', 'generation': 13,
                              'data': {'enabled': True, 'temperature': 4000}}).encode() + b'\n'
        client.process.stdin.write(request[:17]); client.process.stdin.flush()
        time.sleep(.05)
        client.process.stdin.write(request[17:]); client.process.stdin.flush()
        self.assertEqual(client.wait(lambda m: m.get('state') == 'unavailable')['generation'], 13)
        client.process.stdin.write(b'{invalid json}\n'); client.process.stdin.flush()
        self.assertEqual(client.wait(lambda m: m.get('type') == 'error')['generation'], 13)

    def test_gamma_confirmation_reconfiguration_and_stop(self):
        client = self.client(delay=.1)
        client.send(enabled=True, temperature=4100)
        on = client.wait(lambda m: m.get('state') == 'on')
        self.assertEqual(on['generation'], 7)
        self.assertEqual(on['appliedTemperature'], 4100)
        client.send(enabled=True, temperature=4100)
        client.wait(lambda m: m.get('state') == 'on')
        self.assertEqual(len(client.starts.read_text().splitlines()), 1)
        client.send(enabled=True, temperature=3500)
        pending = client.wait(lambda m: m.get('temperature') == 3500)
        self.assertEqual(pending['state'], 'starting')
        client.wait(lambda m: m.get('state') == 'on' and m.get('appliedTemperature') == 3500)
        entries = [json.loads(line) for line in client.starts.read_text().splitlines()]
        self.assertEqual(len(entries), 2)
        self.assertIn('3500', entries[-1]['args'])
        client.send(enabled=False, temperature=3500)
        off = client.wait(lambda m: m.get('state') == 'off')
        self.assertIsNone(off['appliedTemperature'])

    def test_failed_gamma_never_becomes_on(self):
        client = self.client('[123] zwlr_gamma_control_v1#9.failed()')
        client.send(enabled=True, temperature=4000)
        error = client.wait(lambda m: m.get('state') == 'error')
        self.assertIn('another color manager', error['error'])
        self.assertFalse(any(m.get('state') == 'on' for m in client.lines))

    def test_temperature_message_without_gamma_request_never_becomes_on(self):
        client = self.client('setting temperature 4000')
        client.send(enabled=True, temperature=4000)
        error = client.wait(lambda m: m.get('state') == 'error', timeout=8)
        self.assertIsNone(error['appliedTemperature'])
        self.assertIn('No gamma request', error['error'])
        self.assertFalse(any(m.get('state') == 'on' for m in client.lines))

    def test_late_gamma_failure_disables_an_active_process(self):
        client = self.client(late_failure=True)
        client.send(enabled=True, temperature=4000)
        client.wait(lambda m: m.get('state') == 'on')
        error = client.wait(lambda m: m.get('state') == 'error')
        self.assertIsNone(error['appliedTemperature'])
        self.assertIn('another color manager', error['error'])

    def test_child_exit_is_reported_and_not_signalled_again(self):
        client = self.client(exit_after_trace=True)
        client.send(enabled=True, temperature=4000)
        error = client.wait(lambda m: m.get('state') == 'error')
        self.assertIsNone(error['appliedTemperature'])
        self.assertFalse(any(m.get('state') == 'on' for m in client.lines))

    def test_flooding_log_does_not_block_off_command(self):
        client = self.client(trace='setting temperature', flood=True)
        client.send(enabled=True, temperature=4000)
        client.wait(lambda m: m.get('state') == 'starting')
        deadline = time.monotonic() + 4
        while not client.starts.exists() and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertTrue(client.starts.exists())
        time.sleep(.15)
        client.send(enabled=False, temperature=4000)
        self.assertEqual(client.wait(lambda m: m.get('state') == 'off', timeout=3)['state'], 'off')

    def test_temperature_is_clamped(self):
        client = self.client()
        client.send(enabled=True, temperature=9000)
        on = client.wait(lambda m: m.get('state') == 'on')
        self.assertEqual(on['temperature'], 6000)
        args = json.loads(client.starts.read_text().splitlines()[0])['args']
        self.assertIn('6000', args)
        self.assertIn('6001', args)

    def test_off_cancels_pending_activation(self):
        client = self.client(delay=1)
        client.send(enabled=True, temperature=4000)
        client.wait(lambda m: m.get('state') == 'starting')
        client.send(enabled=False, temperature=4000)
        off = client.wait(lambda m: m.get('state') == 'off')
        self.assertIsNone(off['appliedTemperature'])
        self.assertFalse(any(m.get('state') == 'on' for m in client.lines))

    def test_closed_log_pipe_does_not_stop_confirmation(self):
        client = self.client(close_stderr=True)
        client.send(enabled=True, temperature=4000)
        self.assertEqual(client.wait(lambda m: m.get('state') == 'on')['appliedTemperature'], 4000)

    def test_child_exits_when_owner_is_killed(self):
        client = self.client()
        client.send(enabled=True, temperature=4000)
        client.wait(lambda m: m.get('state') == 'on')
        pid = json.loads(client.starts.read_text().splitlines()[0])['pid']
        client.process.kill(); client.process.wait(timeout=3)
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            stat = Path(f'/proc/{pid}/stat')
            try:
                if stat.read_text().split(') ', 1)[1].startswith('Z '): break
            except FileNotFoundError: break
            time.sleep(.05)
        else:
            self.fail('Synthetic wlsunset survived its owner')

    def test_sigterm_cleans_up_child(self):
        client = self.client()
        client.send(enabled=True, temperature=4000)
        client.wait(lambda m: m.get('state') == 'on')
        pid = json.loads(client.starts.read_text().splitlines()[0])['pid']
        client.process.terminate()
        self.assertEqual(client.process.wait(timeout=4), 0)
        self.assertFalse(Path(f'/proc/{pid}').exists())

    @unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
    def test_qml_uses_rust_with_fake_child(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); shell = root / 'shell'; fake = root / 'bin'
            fake.mkdir(); fake_wlsunset(fake, TRACE)
            shutil.copytree(ROOT / 'MacShell', shell)
            shutil.copy(ROOT / 'tests/night-shift-rust.qml', shell / 'shell.qml')
            shutil.copy(BINARY, shell / 'night-shift-rust')
            (shell / 'night_shift.py').write_text('raise SystemExit("unexpected Python fallback")\n')
            for name in ('runtime', 'config', 'cache'): (root / name).mkdir()
            (root / 'runtime').chmod(0o700)
            env = dict(os.environ, PATH=str(fake) + os.pathsep + os.environ.get('PATH', ''),
                       NIGHT_TEST_STARTS=str(root / 'starts'), XDG_RUNTIME_DIR=str(root / 'runtime'),
                       XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'),
                       QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='', QT_QUICK_BACKEND='software',
                       DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
            env.pop('DISPLAY', None); env.pop('WAYLAND_DISPLAY', None)
            result = subprocess.run([quickshell(), '-p', str(shell)], env=env, capture_output=True, text=True, timeout=16)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('NIGHT_RUST_QML_PASS', result.stdout + result.stderr)


if __name__ == '__main__': unittest.main()
