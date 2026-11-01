#!/usr/bin/env python3
"""Exercise the managed Clock window in an isolated nested niri session."""
import json
import argparse
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import wave

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'MacShell'))
import clock_snooze
import clock_stopwatch
from clock_store import ClockStore
from clock_timer import migrate_legacy
from scripts.install_niri import quickshell


def child(directory, parent_display, parent_socket):
    display, address = os.environ.get('WAYLAND_DISPLAY'), os.environ.get('NIRI_SOCKET')
    if not display or display == parent_display or not address or address == parent_socket:
        raise RuntimeError('Refusing to test a non-isolated compositor')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.connect(address)
        pid, uid, _ = struct.unpack('3i', conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    token = ('MACSHELL_NESTED_TEST_TOKEN=' + os.environ['MACSHELL_NESTED_TEST_TOKEN']).encode()
    if uid != os.getuid() or token not in Path('/proc', str(pid), 'environ').read_bytes().split(b'\0'):
        raise RuntimeError('Nested niri socket does not belong to the test compositor')
    root = Path(directory)
    try:
        for case, fixture in (('actions', 'tests/clock-app-managed.qml'), ('recovery', 'tests/clock-app-recovery.qml'),
                              ('recovery_light', 'tests/clock-app-recovery.qml'),
                              ('recovery_ru', 'tests/clock-app-recovery.qml'),
                              ('recovery_ru_light', 'tests/clock-app-recovery.qml'),
                              ('events', 'tests/clock-app-events.qml'),
                              ('sounds', 'tests/clock-app-sounds.qml')):
            case_dir = root / case
            case_dir.mkdir()
            shell = case_dir / 'shell'
            shutil.copytree(ROOT / 'MacShell', shell)
            shutil.copy(ROOT / fixture, shell / 'shell.qml')
            app = shell / 'ClockApp.qml'
            source = app.read_text().replace('    property string clockMessage: ""\n',
                '    property string clockMessage: ""\n    readonly property var testBackend: clockBackend\n    readonly property var testClockWindow: win\n    readonly property var testClockBanner: banner\n    readonly property var testSoundImporter: soundImporter\n', 1)
            app.write_text(source)
            for name in ('config', 'cache', 'settings', 'home'):
                (case_dir / name).mkdir()
            store = case_dir / 'settings/macshell/clock.json'
            store.parent.mkdir()
            if case in ('actions', 'events', 'sounds'):
                store.write_bytes(b'{"extension":{"keep":true}}\n')
            else:
                now = int(time.time() * 1000)
                timing = migrate_legacy({'state': 'running', 'total': 30000, 'left': 30000,
                                         'endAt': now + 30000, 'label': 'Tea'}, 'old-boot', 1000, now, 'timer-a')
                timing['stopwatch'] = clock_stopwatch.migrate_legacy({'running': True, 'startAt': now - 1000,
                                                                      'acc': 500, 'laps': [300]}, 1000, now, 'sw-a')
                timing['legacySnoozesRecovery'] = clock_snooze.migrate_legacy([{'at': now + 120000, 'label': 'Wake'}], now)
                timing['missedSnoozes'] = [{'id': 'missed-snooze', 'label': 'Old alert'}]
                with ClockStore(store) as owner:
                    owner.commit({'timing': timing}, 'missing', 0)
            env = dict(os.environ, HOME=str(case_dir / 'home'), XDG_CONFIG_HOME=str(case_dir / 'config'),
                       XDG_CACHE_HOME=str(case_dir / 'cache'), MACSHELL_SETTINGS_HOME=str(case_dir / 'settings'),
                       QT_QPA_PLATFORM='wayland', QT_QPA_PLATFORMTHEME='',
                       QT_QUICK_CONTROLS_STYLE='Basic', LANG='C.UTF-8',
                       DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(case_dir / 'no-bus'),
                       DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(case_dir / 'no-bus'))
            env.pop('MACSHELL_CLOCK_SERVICE', None)
            if case in ('recovery_light', 'recovery_ru_light'):
                env['MACSHELL_CLOCK_TEST_THEME'] = 'light'
            else:
                env.pop('MACSHELL_CLOCK_TEST_THEME', None)
            if case in ('recovery_ru', 'recovery_ru_light'):
                env['MACSHELL_CLOCK_TEST_LANGUAGE'] = 'ru'
            else:
                env.pop('MACSHELL_CLOCK_TEST_LANGUAGE', None)
            if case == 'events':
                bindir = case_dir / 'bin'
                bindir.mkdir()
                player = bindir / 'pw-play'
                player.write_text('''#!/usr/bin/env python3
import json, os
with open(os.environ['TEST_CLOCK_STORE']) as source:
    event = json.load(source)['timing']['completion']
if not event['soundClaimed']:
    raise SystemExit(9)
with open(os.environ['TEST_CLOCK_AUDIO_LOG'], 'a') as output:
    output.write(event['eventId'] + '\\n')
''')
                player.chmod(0o755)
                env['PATH'] = str(bindir) + os.pathsep + env.get('PATH', '')
                env['TEST_CLOCK_STORE'] = str(store)
                env['TEST_CLOCK_AUDIO_LOG'] = str(case_dir / 'audio.log')
            if case == 'sounds':
                source = case_dir / 'sound sample.wav'
                with wave.open(str(source), 'wb') as output:
                    output.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
                    output.writeframes(bytes(16000))
                bindir = case_dir / 'bin'
                bindir.mkdir()
                player = bindir / 'pw-play'
                player.write_text('#!/bin/sh\nprintf "%s\\n" "$2" >> "$CLOCK_SOUND_TEST_LOG"\nexec sleep 30\n')
                player.chmod(0o755)
                env['PATH'] = str(bindir) + os.pathsep + env.get('PATH', '')
                env['CLOCK_SOUND_TEST_FILE'] = str(source)
                env['CLOCK_SOUND_TEST_LOG'] = str(case_dir / 'audio.log')
            result = subprocess.run([quickshell(), '-p', str(shell)], env=env,
                                    capture_output=True, text=True, timeout=20)
            log = result.stdout + result.stderr
            expected = {'actions': 'CLOCK_APP_MANAGED_PASS', 'recovery': 'CLOCK_RECOVERY_APP_PASS',
                        'recovery_light': 'CLOCK_RECOVERY_APP_PASS', 'recovery_ru': 'CLOCK_RECOVERY_APP_PASS',
                        'recovery_ru_light': 'CLOCK_RECOVERY_APP_PASS',
                        'events': 'CLOCK_EVENTS_APP_PASS', 'sounds': 'CLOCK_SOUNDS_APP_PASS'}[case]
            if result.returncode or expected not in log or re.search(r'TypeError|ReferenceError|Binding loop|Unable to assign', log):
                raise RuntimeError(case + ' failed: ' + log[-8000:])
            document = json.loads(store.read_text())
            if document['timing']['timer']['state'] != 'idle':
                raise RuntimeError(case + ' left a timer running')
            if case in ('recovery', 'recovery_light', 'recovery_ru', 'recovery_ru_light') and (document['timing']['legacySnoozesRecovery'] or
                                       document['timing']['missedSnoozes'] or
                                       [item['label'] for item in document['timing']['snoozes']] != ['Wake']):
                raise RuntimeError('Recovery did not preserve the selected snooze')
            if case == 'events':
                log_file = case_dir / 'audio.log'
                events = log_file.read_text().splitlines() if log_file.exists() else []
                if len(set(events)) != 2:
                    raise RuntimeError('Expected two distinct claimed audio events: ' + repr(events))
            if case == 'sounds':
                played = (case_dir / 'audio.log').read_text().splitlines()
                if len(played) != 2 or played[0] != played[1] or Path(played[0]).exists():
                    raise RuntimeError('Imported sound was not previewed and played: ' + repr(played))
            print(expected)
        env = dict(os.environ)
        env.pop('MACSHELL_CLOCK_SERVICE', None)
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/check-calculator-native.py')], env=env,
                                capture_output=True, text=True, timeout=50)
        log = result.stdout + result.stderr
        if result.returncode or 'MACSHELL_CALCULATOR_PASS' not in log:
            raise RuntimeError('Full shell Clock integration failed: ' + log[-8000:])
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/check-timer-widget-integration.py')], env=env,
                                capture_output=True, text=True, timeout=55)
        log = result.stdout + result.stderr
        if result.returncode or 'TIMER_WIDGET_NATIVE_PASS' not in log:
            raise RuntimeError('Timer widget integration failed: ' + log[-10000:])
    finally:
        subprocess.run(['niri', 'msg', 'action', 'quit', '--skip-confirmation'], capture_output=True, timeout=8)


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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', type=Path)
    args = parser.parse_args()
    if args.capture:
        args.capture.mkdir(parents=True, exist_ok=True)
    if not os.environ.get('WAYLAND_DISPLAY') or not os.environ.get('NIRI_SOCKET'):
        raise RuntimeError('A parent Wayland/niri session is required')
    with tempfile.TemporaryDirectory(prefix='macshell-clock-nested-') as directory:
        root = Path(directory)
        config = root / 'niri.kdl'
        config.write_text('window-rule {\n    match title="^Clock$"\n    open-floating true\n}\n')
        command = ['niri', '-c', str(config), '--', sys.executable, str(Path(__file__).resolve()), '--child', directory,
                   os.environ['WAYLAND_DISPLAY'], os.environ['NIRI_SOCKET']]
        log_path = root / 'niri.log'
        with log_path.open('w') as output:
            env = dict(os.environ, MACSHELL_NESTED_TEST_TOKEN=uuid.uuid4().hex)
            if args.capture:
                env['MACSHELL_CLOCK_CAPTURE_DIR'] = str(args.capture.resolve())
            else:
                env.pop('MACSHELL_CLOCK_CAPTURE_DIR', None)
            process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, env=env)
            try:
                deadline = time.monotonic() + 140
                result_path = root / 'result'
                while time.monotonic() < deadline and not result_path.exists() and process.poll() is None:
                    time.sleep(.1)
                if not result_path.exists() or result_path.read_text() != 'PASS':
                    result = result_path.read_text() if result_path.exists() else 'no result'
                    raise RuntimeError('Nested Clock test failed: ' + result + '\n' + log_path.read_text()[-8000:])
                print('CLOCK_NATIVE_PASS: isolated niri, Clock actions, recovery, background signals and sound import/selection/deletion')
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)


if __name__ == '__main__':
    main()
