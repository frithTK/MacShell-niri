#!/usr/bin/env python3
"""Run one bridge against a verified nested niri and disposable shell data."""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.install_niri import quickshell


def descendant(pid, ancestor):
    visited = set()
    while pid > 1 and pid not in visited:
        if pid == ancestor: return True
        visited.add(pid)
        try: pid = int(Path('/proc', str(pid), 'stat').read_text().rsplit(') ', 1)[1].split()[1])
        except (OSError, ValueError, IndexError): return False
    return False


def measure_tree(root_pid):
    pending = [root_pid]; seen = set(); result = {}
    while pending:
        pid = pending.pop()
        if pid in seen: continue
        seen.add(pid)
        try:
            base = Path('/proc', str(pid))
            stat = (base / 'stat').read_text().rsplit(') ', 1)[1].split()
            pss = next(int(line.split()[1]) for line in (base / 'smaps_rollup').read_text().splitlines() if line.startswith('Pss:'))
            result[pid] = {'start': int(stat[19]), 'ticks': sum(int(stat[i]) for i in (11, 12, 13, 14)), 'pss': pss}
            for task in (base / 'task').iterdir():
                try: pending.extend(int(x) for x in (task / 'children').read_text().split())
                except (OSError, ValueError): pass
        except (OSError, ValueError, IndexError, StopIteration):
            continue
    return result


def child(directory, parent_display, parent_socket, binary, crash):
    display, address = os.environ.get('WAYLAND_DISPLAY'), os.environ.get('NIRI_SOCKET')
    if not display or display == parent_display or not address or address == parent_socket:
        raise RuntimeError('Refusing to test a non-isolated compositor')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.connect(address)
        pid, uid, _ = struct.unpack('3i', conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    token = ('MACSHELL_NESTED_TEST_TOKEN=' + os.environ['MACSHELL_NESTED_TEST_TOKEN']).encode()
    if uid != os.getuid() or token not in Path('/proc', str(pid), 'environ').read_bytes().split(b'\0'):
        raise RuntimeError('Nested niri socket does not belong to the test compositor')
    root = Path(directory); shell = root / 'shell'
    shutil.copytree(ROOT / 'MacShell', shell)
    if binary != 'python':
        shutil.copy2(binary, shell / 'niri-bridge-rust')
    path = shell / 'shell.qml'
    source = path.read_text().replace('import QtQuick\n', 'import QtQuick\nimport QtQuick.Window\n', 1)
    path.write_text(source.replace('ShellRoot {', 'ShellRoot {\n' + (ROOT / 'tests/niri-bridge-native.qml').read_text(), 1))
    for name in ('home', 'cache', 'config', 'data', 'settings/macbar', 'settings/macdock'):
        (root / name).mkdir(parents=True)
    (root / 'settings/macbar/settings.json').write_text(json.dumps(dict(barEnabled=False, spotlightEnabled=False,
        ccEnabled=False, notificationsEnabled=False, clipHistory=False, autoContrast=False, barGlass=False, statsMetrics=[])))
    (root / 'settings/macdock/settings.json').write_text(json.dumps(dict(dockEnabled=False, windowCapture=False)))
    env = dict(os.environ, HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'),
        XDG_DATA_HOME=str(root / 'data'), MACSHELL_SETTINGS_HOME=str(root / 'settings'),
        QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic',
        DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'), DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
        MACSHELL_NIRI_BRIDGE_BACKEND='python' if binary == 'python' else 'rust',
        MACSHELL_TEST_BRIDGE_CRASH='1' if crash == 'crash' else '0',
        MACSHELL_TEST_BRIDGE_MEASURE='1' if crash == 'measure' else '0')
    try:
        log_path = root / 'shell.log'
        with log_path.open('w') as output:
            process = subprocess.Popen([quickshell(), '-p', str(shell)], env=env, stdout=output, stderr=subprocess.STDOUT)
            crashed = False
            ready_at = None; samples = []
            try:
                deadline = time.monotonic() + 40
                while process.poll() is None and time.monotonic() < deadline:
                    if crash == 'crash' and not crashed and 'MACSHELL_NIRI_BRIDGE_REQUEST_CRASH' in log_path.read_text():
                        candidates = []
                        for entry in Path('/proc').iterdir():
                            if not entry.name.isdigit(): continue
                            pid = int(entry.name)
                            try: args = (entry / 'cmdline').read_bytes().split(b'\0')
                            except OSError: continue
                            target = str(shell / 'niri_ipc.py').encode() if binary == 'python' else str(shell / 'niri-bridge-rust').encode()
                            if target in args and descendant(pid, process.pid): candidates.append(pid)
                        if len(candidates) == 1:
                            os.kill(candidates[0], signal.SIGKILL); crashed = True
                        elif len(candidates) > 1:
                            raise RuntimeError('More than one bridge in test process tree')
                    if crash == 'measure':
                        now = time.monotonic()
                        if ready_at is None and 'MACSHELL_NIRI_BRIDGE_MEASURE_READY' in log_path.read_text(): ready_at = now
                        if ready_at is not None and now >= ready_at + 6 and len(samples) < 9:
                            if not samples or now - samples[-1][0] >= .95:
                                samples.append((now, measure_tree(process.pid)))
                    time.sleep(.1)
                if process.poll() is None: raise RuntimeError('Nested shell timed out')
            finally:
                if process.poll() is None:
                    process.terminate(); process.wait(timeout=5)
        log = log_path.read_text()
        Path('/tmp/macshell-niri-bridge-native.log').write_text(log)
        if (crash == 'crash' and not crashed) or process.returncode or 'MACSHELL_NIRI_BRIDGE_NATIVE_PASS' not in log or re.search(r'TypeError|ReferenceError|Binding loop|Unable to assign', log):
            raise RuntimeError(log[-10000:])
        if crash == 'measure':
            if len(samples) != 9 or any(not data or process.pid not in data for _, data in samples):
                raise RuntimeError('Incomplete process-tree measurement')
            start_time, first = samples[0]; end_time, last = samples[-1]
            stable = all(set(data) == set(first) and all(data[p]['start'] == first[p]['start'] for p in first) for _, data in samples)
            ticks = sum(row['ticks'] for row in last.values()) - sum(row['ticks'] for row in first.values())
            report = {'scenario': 'isolated nested niri, one synthetic window, shell process tree; compositor excluded',
                      'implementation': 'python' if binary == 'python' else 'rust', 'seconds': round(end_time-start_time, 3),
                      'cpu_estimate_one_core_pct': round(ticks / os.sysconf('SC_CLK_TCK') / (end_time-start_time) * 100, 3),
                      'pss_mib_samples': [round(sum(row['pss'] for row in data.values()) / 1024, 2) for _, data in samples],
                      'process_counts': [len(data) for _, data in samples], 'stable_processes': stable,
                      'cpu_note': 'includes reaped child ticks; process churn can make endpoint accounting incomplete'}
            (root / 'measurement.json').write_text(json.dumps(report, indent=2) + '\n')
    finally:
        subprocess.run(['niri', 'msg', 'action', 'quit', '--skip-confirmation'], capture_output=True, timeout=8)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--child':
        root = Path(sys.argv[2])
        try: child(*sys.argv[2:])
        except Exception as error: (root / 'result').write_text('ERROR: ' + repr(error)); raise
        else: (root / 'result').write_text('PASS')
        return
    if len(sys.argv) not in (2, 3, 4) or (len(sys.argv) == 3 and sys.argv[2] != '--crash') or (len(sys.argv) == 4 and sys.argv[2] != '--measure'):
        raise SystemExit('Usage: check-niri-bridge-native.py python|ABSOLUTE_RUST_BINARY [--crash | --measure OUTPUT]')
    binary = sys.argv[1]
    crash = 'crash' if len(sys.argv) == 3 else 'measure' if len(sys.argv) == 4 else 'normal'
    if binary != 'python' and (not Path(binary).is_absolute() or not os.access(binary, os.X_OK)):
        raise SystemExit('Rust bridge must be an absolute executable path')
    if not os.environ.get('WAYLAND_DISPLAY') or not os.environ.get('NIRI_SOCKET'):
        raise RuntimeError('A parent Wayland/niri session is required')
    with tempfile.TemporaryDirectory(prefix='macshell-niri-bridge-nested-') as directory:
        root = Path(directory); config = root / 'niri.kdl'; config.write_text('hotkey-overlay { skip-at-startup; }\n')
        command = ['niri', '-c', str(config), '--', sys.executable, str(Path(__file__).resolve()), '--child', directory,
                   os.environ['WAYLAND_DISPLAY'], os.environ['NIRI_SOCKET'], binary, crash]
        with (root / 'niri.log').open('w') as output:
            process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                env=dict(os.environ, MACSHELL_NESTED_TEST_TOKEN=uuid.uuid4().hex))
            try:
                deadline = time.monotonic() + 55; result = root / 'result'
                while time.monotonic() < deadline and not result.exists() and process.poll() is None: time.sleep(.1)
                if not result.exists() or result.read_text() != 'PASS':
                    raise RuntimeError((result.read_text() if result.exists() else 'no result') + '\n' + (root / 'niri.log').read_text()[-8000:])
                print('MACSHELL_NIRI_BRIDGE_NATIVE_PASS: isolated niri and synthetic windows')
                if crash == 'measure':
                    report = (root / 'measurement.json').read_text()
                    Path(sys.argv[3]).write_text(report)
                    print(report)
            finally:
                if process.poll() is None: process.terminate()
                process.wait(timeout=5)


if __name__ == '__main__': main()
