"""Opt-in real Rust session install and rollback with no Python on PATH."""
import os
import json
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.environ.get('MACSHELL_TEST_INSTALL_NO_PYTHON') == '1', 'Opt-in real offline build')
class NoPythonInstallTests(unittest.TestCase):
    def test_real_session_install_preflight_and_rollback(self):
        with tempfile.TemporaryDirectory(prefix='macshell-no-python-') as temporary:
            root = Path(temporary)
            tools = root / 'tools'; tools.mkdir()
            for source in Path('/usr/bin').iterdir():
                if source.name.startswith(('python', 'pypy')) or source.name in ('niri', 'systemctl', 'qs', 'desktop-file-validate'):
                    continue
                try:
                    (tools / source.name).symlink_to(source)
                except FileExistsError:
                    pass
            def fake(name, body):
                path = tools / name
                path.write_text('#!/bin/sh\n' + body + '\n'); path.chmod(0o755)
                return path
            fake('niri', 'exit 0')
            fake('systemctl', 'case "$*" in *show*) echo inactive;; esac\nexit 0')
            real_qs = os.environ.get('MACSHELL_TEST_QS_BIN', str(Path.home() / '.local/share/macshell-niri/runtime/bin/qs'))
            qs = fake('qs', 'case "$*" in *list*) echo "[]";; *"ipc call"*) echo ready;; *) exec "$MACSHELL_TEST_REAL_QS" "$@";; esac')
            fake('desktop-file-validate', 'exit 0')
            runtime = root / 'runtime'; runtime.mkdir(mode=0o700)
            config = root / 'config'; (config / 'niri').mkdir(parents=True)
            (config / 'niri/config.kdl').write_text('// isolated original\n')
            shell = config / 'quickshell/MacShell-niri'; shell.mkdir(parents=True)
            (shell / 'previous').write_text('original')
            env = dict(os.environ, HOME=str(root), XDG_CONFIG_HOME=str(config),
                       XDG_CACHE_HOME=str(root / 'cache'), XDG_DATA_HOME=str(root / 'data'),
                       XDG_RUNTIME_DIR=str(runtime), PATH=str(tools), MACSHELL_QS_BIN=str(qs),
                       MACSHELL_BIN_DIR=str(root / 'bin'),
                       MACSHELL_TEST_REAL_QS=real_qs,
                       CARGO_HOME=os.environ.get('CARGO_HOME', str(Path.home() / '.cargo')),
                       RUSTUP_HOME=os.environ.get('RUSTUP_HOME', str(Path.home() / '.rustup')))
            for key in ('WAYLAND_DISPLAY', 'DISPLAY', 'MACSHELL_NIRI_BRIDGE_BACKEND'):
                env.pop(key, None)
            build = root / 'installer-build'
            subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path',
                            str(ROOT / 'native/installer/Cargo.toml'), '--target-dir', str(build)],
                           env=env, check=True, timeout=180)
            binary = build / 'debug/macshell-installer'
            command = [str(binary), 'cli', str(ROOT)]
            result = subprocess.run(command + ['--session'], env=env, capture_output=True, text=True, timeout=1800)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((shell / '.macshell-rust-only').is_file())
            self.assertTrue((config / 'macshell-niri/.macshell-rust-only').is_file())
            for launcher, expected in [('airdrop-service.sh', 'macshell-airdrop-service 1'),
                                       ('screen-mirroring-service.sh', 'macshell-screen-mirroring 1'),
                                       ('capture-service.sh', 'macshell-capture 1'),
                                       ('recording-service.sh', 'macshell-recording 1')]:
                output = subprocess.check_output(['/bin/sh', str(shell / launcher), '--protocol-version'], env=env, text=True, timeout=10)
                self.assertEqual(output.strip(), expected)
            check = subprocess.run([str(root / 'bin/niri-macshell-session'), '--check'], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
            self.check_nested_shell(root, shell, env, real_qs)
            rollback = subprocess.run(command + ['--rollback'], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(rollback.returncode, 0, rollback.stdout + rollback.stderr)
            self.assertEqual((shell / 'previous').read_text(), 'original')
            self.assertFalse((config / 'macshell-niri/.macshell-rust-only').exists())

    def check_nested_shell(self, root, shell, env, real_qs):
        parent_display = os.environ.get('WAYLAND_DISPLAY')
        parent_socket = os.environ.get('NIRI_SOCKET')
        if not parent_display or not parent_socket:
            self.skipTest('Nested niri requires a parent Wayland session')
        script = shell / 'shell.qml'
        source = script.read_text().replace('import QtQuick\n', 'import QtQuick\nimport QtQuick.Window\n', 1)
        script.write_text(source.replace('ShellRoot {', 'ShellRoot {\n' + (ROOT / 'tests/niri-bridge-native.qml').read_text(), 1))
        config = root / 'nested.kdl'; config.write_text('hotkey-overlay { skip-at-startup; }\n')
        child = root / 'nested-child.sh'
        child.write_text('#!/bin/sh\nprintf "%s\\n%s\\n" "$WAYLAND_DISPLAY" "$NIRI_SOCKET" > "$MACSHELL_NESTED_ENV"\nexec /usr/bin/sleep 120\n')
        child.chmod(0o755)
        token = uuid.uuid4().hex
        nested_env = dict(env, WAYLAND_DISPLAY=parent_display, MACSHELL_NESTED_TEST_TOKEN=token,
                          MACSHELL_NESTED_ENV=str(root / 'nested.env'))
        parent_wayland = Path(parent_display)
        if not parent_wayland.is_absolute():
            parent_wayland = Path(os.environ['XDG_RUNTIME_DIR']) / parent_wayland
        nested_env['WAYLAND_DISPLAY'] = str(parent_wayland)
        nested_env.pop('NIRI_SOCKET', None)
        with (root / 'nested.log').open('w+') as nested_log:
          nested = subprocess.Popen(['/usr/bin/niri', '--config', str(config), '--', str(child)],
                                    env=nested_env, stdout=nested_log, stderr=subprocess.STDOUT)
          try:
            deadline = time.monotonic() + 15
            while not (root / 'nested.env').exists() and nested.poll() is None and time.monotonic() < deadline:
                time.sleep(.05)
            nested_log.flush()
            self.assertTrue((root / 'nested.env').exists(), 'nested compositor did not start: ' + (root / 'nested.log').read_text())
            display, address = (root / 'nested.env').read_text().splitlines()
            nested_display = Path(display)
            if not nested_display.is_absolute():
                nested_display = Path(env['XDG_RUNTIME_DIR']) / nested_display
            self.assertNotEqual(nested_display, parent_wayland)
            self.assertNotEqual(address, parent_socket)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.connect(address)
                pid, uid, _ = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
            self.assertEqual(uid, os.getuid())
            self.assertEqual(pid, nested.pid)
            self.assertIn(('MACSHELL_NESTED_TEST_TOKEN=' + token).encode(), Path('/proc', str(pid), 'environ').read_bytes().split(b'\0'))
            settings = root / 'settings'; (settings / 'macbar').mkdir(parents=True); (settings / 'macdock').mkdir()
            (settings / 'macbar/settings.json').write_text(json.dumps(dict(barEnabled=False, spotlightEnabled=False, ccEnabled=False, notificationsEnabled=False, clipHistory=False, autoContrast=False, barGlass=False, statsMetrics=[])))
            (settings / 'macdock/settings.json').write_text(json.dumps(dict(dockEnabled=False, windowCapture=False)))
            shell_env = dict(env, WAYLAND_DISPLAY=display, NIRI_SOCKET=address, MACSHELL_SETTINGS_HOME=str(settings),
                             QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic',
                             DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
                             DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'))
            result = subprocess.run([real_qs, '-p', str(shell)], env=shell_env, capture_output=True, text=True, timeout=45)
            log = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, log[-10000:])
            self.assertIn('MACSHELL_NIRI_BRIDGE_NATIVE_PASS', log)
          finally:
            nested.terminate()
            try: nested.wait(timeout=8)
            except subprocess.TimeoutExpired:
                nested.kill(); nested.wait(timeout=8)
