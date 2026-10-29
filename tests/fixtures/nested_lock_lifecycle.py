#!/usr/bin/env python3
"""Exercise the real session-lock protocol in an isolated nested niri window."""
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


def run(command, **kwargs):
    return subprocess.run(command, capture_output=True, text=True, timeout=12, **kwargs)


def child(directory, parent_display, parent_socket):
    display = os.environ.get('WAYLAND_DISPLAY')
    address = os.environ.get('NIRI_SOCKET')
    if not display or display == parent_display or not address or address == parent_socket:
        raise RuntimeError('Refusing to test a non-isolated compositor')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.connect(address)
        pid, uid, _ = struct.unpack('3i', conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    token = ('MACSHELL_NESTED_TEST_TOKEN=' + os.environ['MACSHELL_NESTED_TEST_TOKEN']).encode()
    if uid != os.getuid() or token not in Path('/proc', str(pid), 'environ').read_bytes().split(b'\0'):
        raise RuntimeError('Nested niri socket does not belong to the test compositor')
    base = Path(directory)
    name = 'MacLock-test-' + uuid.uuid4().hex
    unit = 'macshell-test-lock-' + uuid.uuid4().hex
    shell = 'macshell-test-shell-' + uuid.uuid4().hex
    config = base / 'quickshell' / name
    shutil.copytree(ROOT / 'MacLock', config, symlinks=False)
    qml = config / 'shell.qml'
    text = qml.read_text().replace('    // the monitor that was focused', '''    IpcHandler {
        target: "testonly"
        function secure(): bool { return lock.secure; }
        function release(): void { lockState.unlock(); }
    }

    // the monitor that was focused''')
    qml.write_text(text)
    helper = base / 'lock-test.sh'
    helper.write_text((ROOT / 'MacLock/lock-via-ipc.sh').read_text().replace('MacLock-niri', name).replace('macshell-niri-lock.guard', unit + '.guard').replace('--unit=macshell-niri-lock', '--unit=' + unit))
    env = dict(os.environ, XDG_CONFIG_HOME=directory, XDG_CACHE_HOME=str(base / 'cache'),
               MACSHELL_SETTINGS_HOME=str(base / 'settings'), QT_QUICK_CONTROLS_STYLE='Basic')
    qs = os.environ.get('MACSHELL_QS_BIN', shutil.which('qs'))
    env['MACSHELL_QS_BIN'] = qs
    def ipc(method):
        return run([qs, '-c', name, 'ipc', 'call', 'testonly', method], env=env)
    def wait_for(predicate):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(.1)
        raise RuntimeError('Timed out waiting for nested lock')
    def value(service, prop):
        return run(['systemctl', '--user', 'show', service + '.service', '--property=' + prop, '--value'], check=True).stdout.strip()
    try:
        run(['systemd-run', '--user', '--unit=' + shell, '--property=Restart=on-failure', '--property=RestartSec=0.2s', '--property=RuntimeMaxSec=60s', '/usr/bin/sleep', '60'], check=True)
        result = run(['sh', str(helper)], env=env)
        if result.returncode:
            raise RuntimeError('Nested lock launch failed: ' + result.stderr)
        wait_for(lambda: ipc('secure').stdout.strip() == 'true')
        locker_pid = value(unit, 'MainPID')
        shell_pid = value(shell, 'MainPID')
        if locker_pid == '0' or shell_pid == '0': raise RuntimeError('Test services did not start')
        run(['systemctl', '--user', 'kill', '--kill-whom=main', '--signal=SIGKILL', shell + '.service'], check=True)
        wait_for(lambda: value(shell, 'MainPID') not in ('0', shell_pid))
        if value(unit, 'MainPID') != locker_pid or ipc('secure').stdout.strip() != 'true':
            raise RuntimeError('The lock did not survive the shell restart')
        run(['systemctl', '--user', 'stop', shell + '.service'], check=True)
        if value(unit, 'MainPID') != locker_pid or ipc('secure').stdout.strip() != 'true':
            raise RuntimeError('The lock did not survive the shell stop')
        result = ipc('release')
        if result.returncode: raise RuntimeError('Could not release nested lock: ' + result.stderr)
        wait_for(lambda: value(unit, 'ActiveState') in ('inactive', 'failed'))
        print('NESTED_LOCK_PASS: real lock survives shell crash and stop, then unlocks')
    finally:
        for service in (shell, unit):
            run(['systemctl', '--user', 'stop', service + '.service'])
        (Path(os.environ['XDG_RUNTIME_DIR']) / (unit + '.guard')).unlink(missing_ok=True)
        run(['niri', 'msg', 'action', 'quit', '--skip-confirmation'])


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--child':
        directory = Path(sys.argv[2])
        try:
            child(*sys.argv[2:])
        except Exception as error:
            (directory / 'result').write_text('ERROR: ' + repr(error))
            raise
        else:
            (directory / 'result').write_text('PASS')
        return
    if not os.environ.get('WAYLAND_DISPLAY') or not os.environ.get('NIRI_SOCKET'):
        raise RuntimeError('A parent Wayland/niri session is required')
    with tempfile.TemporaryDirectory(prefix='macshell-nested-lock-') as directory:
        config = Path(directory) / 'niri.kdl'
        config.write_text('')
        command = ['niri', '-c', str(config), '--', sys.executable, str(Path(__file__).resolve()), '--child', directory,
                   os.environ['WAYLAND_DISPLAY'], os.environ['NIRI_SOCKET']]
        log_path = Path(directory) / 'niri.log'
        with log_path.open('w') as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                       env=dict(os.environ, MACSHELL_NESTED_TEST_TOKEN=uuid.uuid4().hex))
            try:
                result_path = Path(directory) / 'result'
                deadline = time.monotonic() + 35
                while time.monotonic() < deadline and not result_path.exists() and process.poll() is None:
                    time.sleep(.1)
                if not result_path.exists() or result_path.read_text() != 'PASS':
                    raise RuntimeError('Nested compositor test failed: ' + (result_path.read_text() if result_path.exists() else 'no result') + '\n' + log_path.read_text()[-6000:])
                print('NESTED_LOCK_PASS: real lock survives shell crash and stop, then unlocks')
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)


if __name__ == '__main__':
    main()
