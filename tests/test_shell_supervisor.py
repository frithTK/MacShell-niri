import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from scripts import shell_supervisor as supervisor


class ShellSupervisorTests(unittest.TestCase):
    def test_instance_guard_rejects_existing_or_invalid_list(self):
        for contents in ('[{"pid":123}]', '{}', 'not-json'):
            with self.subTest(contents=contents), patch.object(supervisor.subprocess, 'run',
                    return_value=subprocess.CompletedProcess([], 0, contents, '')):
                with self.assertRaises((RuntimeError, ValueError)):
                    supervisor.check_no_instance('/bin/qs')
        with patch.object(supervisor.subprocess, 'run',
                          return_value=subprocess.CompletedProcess([], 0, '[]', '')) as run:
            supervisor.check_no_instance('/bin/qs')
            self.assertEqual(run.call_args.args[0], ['/bin/qs', '-c', 'MacShell-niri', 'list', '--any-display', '--json'])
        with patch.object(supervisor.subprocess, 'run', return_value=subprocess.CompletedProcess(
                [], 0, 'No running instances for "/tmp/shell.qml"\nUse --all to list all instances.\n', '')):
            supervisor.check_no_instance('/bin/qs')

    def test_start_only_imports_matching_compositor_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / 'niri.sock')
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path); server.listen()
                commands = []
                def run(command, **kwargs):
                    commands.append(command)
                    if '--property=ActiveState' in command:
                        return subprocess.CompletedProcess(command, 0, 'activating\n', '')
                    if '--property=MainPID' in command:
                        return subprocess.CompletedProcess(command, 0, str(os.getpid()) + '\n', '')
                    return subprocess.CompletedProcess(command, 0, '', '')
                env = {'WAYLAND_DISPLAY': 'wayland-test', 'NIRI_SOCKET': path,
                       'MACSHELL_SESSION_TOKEN': 'test-token'}
                with patch.dict(os.environ, env, clear=True), patch.object(supervisor.subprocess, 'run', side_effect=run), \
                     patch.object(Path, 'read_bytes', return_value=b'MACSHELL_SESSION_TOKEN=test-token\0'):
                    supervisor.start()
                self.assertIn(['systemctl', '--user', 'start', 'macshell-niri-shell.service'], commands)
                self.assertIn(['systemctl', '--user', 'import-environment', 'WAYLAND_DISPLAY',
                               'NIRI_SOCKET', 'MACSHELL_SESSION_TOKEN'], commands)

    def test_missing_or_mismatched_session_never_starts_unit(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(supervisor.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'Missing compositor'):
                supervisor.start()
            run.assert_not_called()
        env = {'WAYLAND_DISPLAY': 'wayland-test', 'NIRI_SOCKET': '/not-used', 'MACSHELL_SESSION_TOKEN': 'ours'}
        def run(command, **kwargs):
            return subprocess.CompletedProcess(command, 0, 'active\n' if '--property=ActiveState' in command else str(os.getpid()), '')
        with patch.dict(os.environ, env, clear=True), patch.object(supervisor.subprocess, 'run', side_effect=run) as command, \
             patch.object(Path, 'read_bytes', return_value=b'MACSHELL_SESSION_TOKEN=other\0'):
            with self.assertRaisesRegex(RuntimeError, 'another session'):
                supervisor.start()
            self.assertFalse(any('start' in call.args[0] for call in command.call_args_list))


if __name__ == '__main__':
    unittest.main()
