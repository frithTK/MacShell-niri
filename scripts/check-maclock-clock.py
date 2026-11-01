#!/usr/bin/env python3
"""Exercise MacLock clock rendering in an isolated offscreen preview."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project))
from scripts.install_niri import quickshell


def main():
    with tempfile.TemporaryDirectory(prefix='maclock-clock-') as directory:
        root = Path(directory)
        lock = root / 'lock'
        shutil.copytree(project / 'MacLock', lock)
        path = lock / 'shell.qml'
        source = path.read_text().replace('import QtQuick\n', 'import QtQuick\nimport QtQuick.Window\n', 1)
        source = source.replace('        PanelWindow {\n            id: pw', '        Window {\n            width: 1000; height: 800; visible: true\n            id: pw')
        source = source.replace('            screen: modelData\n', '')
        for line in ('            anchors { top: true; bottom: true; left: true; right: true }\n',
                     '            exclusionMode: ExclusionMode.Ignore\n',
                     '            WlrLayershell.layer: WlrLayer.Overlay\n',
                     '            WlrLayershell.namespace: "maclock-preview"\n',
                     '            WlrLayershell.keyboardFocus: Quickshell.env("MACLOCK_PREVIEW_KB") === "1" && modelData.name === root.primary ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None\n'):
            source = source.replace(line, '')
        source = source.replace('ShellRoot {', 'ShellRoot {\n    Timer { interval: 100; repeat: true; running: true; onTriggered: if (!root.preview || lock.locked || pam.active) { console.error("MACLOCK_CLOCK_FAIL lock/auth"); Qt.exit(1); } }\n', 1)
        path.write_text(source)
        path = lock / 'LockScreen.qml'
        path.write_text(path.read_text().replace('    id: ls\n', '    id: ls\n' + (project / 'tests/maclock-clock.qml').read_text(), 1))
        for name in ('runtime', 'cache', 'config', 'home', 'settings'):
            (root / name).mkdir(mode=0o700)
        clock_path = root / 'settings/macshell/clock.json'
        clock_path.parent.mkdir()
        boot_id = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        boot_now = time.clock_gettime_ns(time.CLOCK_BOOTTIME) // 1_000_000
        timer = {'state': 'running', 'total': 60000, 'endAt': int(time.time() * 1000) + 99999999, 'left': 60000, 'label': 'Test'}
        state = {'version': 2, 'timer': timer, 'sw': {'running': False, 'acc': 0, 'startAt': 0, 'laps': []},
                 'timing': {'version': 1, 'bootId': boot_id, 'timer': {'state': 'running',
                            'deadlineBootMs': boot_now + 60000, 'remainingCheckpointMs': 42000}}}

        def write_state(value):
            pending = clock_path.with_suffix('.tmp')
            pending.write_text(json.dumps(value))
            pending.replace(clock_path)

        write_state(state)
        env = dict(os.environ, QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software', QT_QPA_PLATFORMTHEME='',
                   QT_QUICK_CONTROLS_STYLE='Basic', XDG_CACHE_HOME=str(root / 'cache'), XDG_CONFIG_HOME=str(root / 'config'),
                   XDG_RUNTIME_DIR=str(root / 'runtime'), MACSHELL_SETTINGS_HOME=str(root / 'settings'),
                   HOME=str(root / 'home'), USER='Demo', MACLOCK_PREVIEW='1', NIRI_SOCKET=str(root / 'no-session'),
                   DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
                   DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'), PIPEWIRE_REMOTE='macshell-no-audio')
        env.pop('DISPLAY', None)
        env.pop('WAYLAND_DISPLAY', None)
        log_path = root / 'preview.log'
        with log_path.open('w') as output:
            process = subprocess.Popen([quickshell(), '-p', str(lock)], env=env, stdout=output, stderr=subprocess.STDOUT)
            try:
                deadline, stage = time.monotonic() + 20, 0
                while process.poll() is None and time.monotonic() < deadline:
                    log = log_path.read_text()
                    if stage == 0 and 'MACLOCK_CLOCK_NORMAL' in log:
                        state['timing']['bootId'] = 'another-boot'
                        write_state(state)
                        stage = 1
                    elif stage == 1 and 'MACLOCK_CLOCK_RECOVERY' in log:
                        write_state({'timer': {'state': 'running', 'total': 20000,
                                               'endAt': int(time.time() * 1000) + 20000,
                                               'left': 20000, 'label': 'Legacy'}})
                        stage = 2
                    elif stage == 2 and 'MACLOCK_CLOCK_LEGACY' in log:
                        current_boot = time.clock_gettime_ns(time.CLOCK_BOOTTIME) // 1_000_000
                        state = {'version': 2, 'timer': {'state': 'idle', 'total': 60000, 'left': 60000},
                                 'sw': {'running': True, 'acc': 2000, 'startAt': int(time.time() * 1000) - 999999},
                                 'timing': {'version': 1, 'bootId': boot_id, 'timer': {'state': 'idle', 'remainingCheckpointMs': 60000},
                                            'stopwatch': {'state': 'running', 'accumulatedMs': 2000,
                                                          'startedBootMs': current_boot - 1000, 'elapsedCheckpointMs': 2400}}}
                        write_state(state)
                        stage = 3
                    elif stage == 3 and 'MACLOCK_CLOCK_STOPWATCH' in log:
                        state['timing']['bootId'] = 'another-boot'
                        write_state(state)
                        stage = 4
                    time.sleep(.05)
                if process.poll() is None:
                    raise RuntimeError('MacLock clock preview timed out')
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
        log = log_path.read_text()
        if process.returncode or 'MACLOCK_CLOCK_PASS' not in log or re.search(r'TypeError|ReferenceError|Binding loop|Unable to assign', log):
            print(log, file=sys.stderr)
            raise SystemExit(process.returncode or 1)
        print('MACLOCK_CLOCK_PASS: shared boot time, timer, stopwatch, reboot recovery and legacy timer')


if __name__ == '__main__':
    main()
