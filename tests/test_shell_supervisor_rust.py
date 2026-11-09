"""Supervisor process checks with a synthetic compositor and systemctl."""
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get('MACSHELL_TEST_PREFLIGHT_BINARY')


@unittest.skipUnless(BINARY, 'Set MACSHELL_TEST_PREFLIGHT_BINARY')
class ShellSupervisorRustTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.calls = self.root / 'calls'
        systemctl = self.bin / 'systemctl'
        systemctl.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\ncase "$*" in *ActiveState*) printf "active\\n";; *MainPID*) printf "%s\\n" "$TEST_PID";; esac\n')
        systemctl.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ.get('PATH', ''), CALLS=str(self.calls), WAYLAND_DISPLAY='test-display')

    def invoke(self, *args, **env):
        return subprocess.run([BINARY, *args], env=dict(self.env, **env), capture_output=True, text=True, timeout=10)

    def test_instance_list_rejects_active_and_malformed(self):
        qs = self.bin / 'qs'
        for output, expected in [('[]', 0), ('[{"pid":1}]', 1), ('{}', 1), ('not-json', 1), ('No running instances for "x"\nUse --all to list all instances.', 0)]:
            with self.subTest(output=output):
                qs.write_text('#!/bin/sh\nprintf "%s" "$TEST_OUTPUT"\n')
                qs.chmod(0o755)
                result = self.invoke('--supervisor-check', str(qs), TEST_OUTPUT=output)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_start_requires_compositor_token_and_socket_peer(self):
        path = self.root / 'niri.sock'
        token = 'synthetic-session-token'
        server_code = 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(); print("ready",flush=True); time.sleep(30)'
        server = subprocess.Popen([sys.executable, '-u', '-c', server_code, str(path)], stdout=subprocess.PIPE, env=dict(os.environ, MACSHELL_SESSION_TOKEN=token))
        self.addCleanup(server.wait)
        self.addCleanup(lambda: server.poll() is None and server.kill())
        self.addCleanup(server.stdout.close)
        self.assertEqual(server.stdout.readline(), b'ready\n')
        common = dict(NIRI_SOCKET=str(path), TEST_PID=str(server.pid))
        result = self.invoke('--supervisor-start', MACSHELL_SESSION_TOKEN='wrong', **common)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('another session', result.stderr)
        self.assertNotIn('start macshell-niri-shell.service', self.calls.read_text())
        result = self.invoke('--supervisor-start', MACSHELL_SESSION_TOKEN=token, **common)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text()
        self.assertIn('import-environment WAYLAND_DISPLAY NIRI_SOCKET MACSHELL_SESSION_TOKEN', calls)
        self.assertIn('start macshell-niri-shell.service', calls)

    def test_start_rejects_a_different_socket_owner(self):
        path = self.root / 'niri.sock'
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(str(path)); listener.listen()
            token = 'synthetic-session-token'
            server = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], env=dict(os.environ, MACSHELL_SESSION_TOKEN=token))
            self.addCleanup(server.wait)
            self.addCleanup(lambda: server.poll() is None and server.kill())
            result = self.invoke('--supervisor-start', NIRI_SOCKET=str(path), TEST_PID=str(server.pid), MACSHELL_SESSION_TOKEN=token)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('socket belongs to another compositor', result.stderr)
            self.assertNotIn('start macshell-niri-shell.service', self.calls.read_text())

    def test_launcher_selects_only_supervisor_protocol(self):
        folder = self.root / 'profile'; folder.mkdir()
        shutil.copy(ROOT / 'scripts/shell-supervisor.sh', folder / 'shell-supervisor.sh')
        (folder / 'shell-supervisor.py').write_text('print("legacy", *__import__("sys").argv[1:])\n')
        binary = folder / 'session-preflight-rust'
        binary.write_text('#!/bin/sh\nif [ "$1" = --supervisor-protocol-version ]; then echo "macshell-shell-supervisor 1"; else echo "rust $*"; fi\n')
        binary.chmod(0o755)
        def launch():
            return subprocess.run(['sh', str(folder / 'shell-supervisor.sh'), 'check', 'qs path'], capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual(launch(), 'rust --supervisor-check qs path')
        binary.write_text('#!/bin/sh\necho "macshell-session-preflight 1"\n')
        self.assertEqual(launch(), 'legacy check qs path')
