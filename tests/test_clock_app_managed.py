import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import wave

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'MacShell'))
import clock_snooze
import clock_stopwatch
from clock_store import ClockStore
from clock_timer import migrate_legacy
from scripts.install_niri import quickshell


@unittest.skipUnless(shutil.which(quickshell()), 'Quickshell is required')
class ManagedClockAppTests(unittest.TestCase):
    def prepare_shell(self, root, fixture):
        shell = root / 'shell'
        shutil.copytree(ROOT / 'MacShell', shell)
        shutil.copy(ROOT / fixture, shell / 'shell.qml')
        app = shell / 'ClockApp.qml'
        source = app.read_text()
        source = source.replace('    property string clockMessage: ""\n',
                                '    property string clockMessage: ""\n    readonly property var testBackend: clockBackend\n    readonly property var testClockWindow: win\n    readonly property var testSoundImporter: soundImporter\n', 1)
        start = source.index('    PanelWindow {\n        id: banner')
        visible = source.index('        visible: root.appEnabled', start)
        source = source[:start] + '    Window {\n        id: banner\n' + source[visible:]
        for line in ('        anchors { top: true; right: true }\n',
                     '        margins { top: 38; right: 12 }\n',
                     '        exclusionMode: ExclusionMode.Ignore\n',
                     '        WlrLayershell.layer: WlrLayer.Overlay\n',
                     '        WlrLayershell.namespace: "macshell-clock-alert"\n'):
            source = source.replace(line, '', 1)
        source = source.replace('        implicitWidth: 372; implicitHeight: 96\n', '        width: 372; height: 96\n', 1)
        app.write_text(source)
        return shell

    def environment(self, root):
        for name in ('config', 'cache', 'runtime', 'settings', 'home'):
            (root / name).mkdir()
        (root / 'runtime').chmod(0o700)
        env = dict(os.environ, HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'config'),
                   XDG_CACHE_HOME=str(root / 'cache'), XDG_RUNTIME_DIR=str(root / 'runtime'),
                   MACSHELL_SETTINGS_HOME=str(root / 'settings'),
                   QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='', QT_QUICK_BACKEND='software',
                   QT_QUICK_CONTROLS_STYLE='Basic', NIRI_SOCKET=str(root / 'no-session'),
                   DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
                   DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'), LANG='C.UTF-8')
        env.pop('DISPLAY', None)
        env.pop('WAYLAND_DISPLAY', None)
        env.pop('MACSHELL_CLOCK_SERVICE', None)
        env.pop('MACSHELL_CLOCK_CAPTURE_DIR', None)
        env.pop('MACSHELL_CLOCK_TEST_THEME', None)
        env.pop('MACSHELL_CLOCK_TEST_LANGUAGE', None)
        return env

    def test_existing_clock_actions_use_one_service_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shell = self.prepare_shell(root, 'tests/clock-app-managed.qml')
            env = self.environment(root)
            store = root / 'settings/macshell/clock.json'
            store.parent.mkdir()
            original = b'{"extension":{"keep":true}}\n'
            store.write_bytes(original)
            result = subprocess.run([quickshell(), '-p', str(shell)], env=env,
                                    capture_output=True, text=True, timeout=20)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('CLOCK_APP_MANAGED_PASS', output)
            document = json.loads(store.read_text())
            self.assertEqual(document['version'], 2)
            self.assertEqual(document['extension'], {'keep': True})
            self.assertEqual(document['timing']['timer']['state'], 'idle')
            self.assertEqual(document['timing']['stopwatch']['state'], 'paused')
            self.assertEqual(document['recents'], [30000])
            self.assertEqual(len(document['alarms']), 1)
            self.assertEqual(next(store.parent.glob('clock.before-v2-*.json')).read_bytes(), original)

    @unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'ffmpeg and ffprobe are required')
    def test_sound_panel_imports_and_previews_a_local_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shell = self.prepare_shell(root, 'tests/clock-app-sounds.qml')
            env = self.environment(root)
            source = root / 'sound sample.wav'
            with wave.open(str(source), 'wb') as output:
                output.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
                output.writeframes(bytes(16000))
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            player = bin_dir / 'pw-play'
            player.write_text('#!/bin/sh\nprintf "%s\\n" "$2" >> "$CLOCK_SOUND_TEST_LOG"\nexec sleep 30\n')
            player.chmod(0o755)
            env['PATH'] = str(bin_dir) + os.pathsep + env.get('PATH', '')
            env['CLOCK_SOUND_TEST_FILE'] = str(source)
            env['CLOCK_SOUND_TEST_LOG'] = str(root / 'audio.log')
            result = subprocess.run([quickshell(), '-p', str(shell)], env=env,
                                    capture_output=True, text=True, timeout=20)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('CLOCK_SOUNDS_APP_PASS', output)
            self.assertNotIn('TypeError', output)
            library = root / 'home/.local/share/sounds/macshell/library'
            entries = list(library.glob('user-*/metadata.json'))
            self.assertEqual(entries, [])
            played = (root / 'audio.log').read_text().splitlines()
            self.assertEqual(len(played), 2)
            self.assertEqual(played[0], played[1])
            self.assertFalse(Path(played[0]).exists())

    def test_import_cancel_stops_decoder_and_skips_queued_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shell = self.prepare_shell(root, 'tests/clock-sound-import-cancel.qml')
            env = self.environment(root)
            source = root / 'sound.wav'
            with wave.open(str(source), 'wb') as output:
                output.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
                output.writeframes(bytes(16000))
            bindir = root / 'bin'
            bindir.mkdir()
            probe = bindir / 'ffprobe'
            probe.write_text('#!/usr/bin/env python3\nimport os, time\nopen(os.environ["CLOCK_TEST_PID"], "w").write(str(os.getpid()))\ntime.sleep(30)\n')
            probe.chmod(0o755)
            decoder = bindir / 'ffmpeg'
            decoder.write_text('#!/bin/sh\nprintf " A....D aac                  AAC decoder\\n"\n')
            decoder.chmod(0o755)
            env['PATH'] = str(bindir) + os.pathsep + env.get('PATH', '')
            env['CLOCK_TEST_FILE'] = str(source)
            env['CLOCK_TEST_LIBRARY'] = str(root / 'library')
            env['CLOCK_TEST_PID'] = str(root / 'decoder.pid')
            result = subprocess.run([quickshell(), '-p', str(shell)], env=env,
                                    capture_output=True, text=True, timeout=15)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('CLOCK_IMPORT_CANCEL_PASS', output)
            self.assertTrue((root / 'decoder.pid').exists())
            self.assertFalse(Path('/proc', (root / 'decoder.pid').read_text()).exists())
            self.assertFalse(any((root / 'library').glob('.import-*')))
            self.assertFalse(any((root / 'library').glob('user-*')))

    def test_recent_timer_reuses_its_sound_and_playback_options(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shell = self.prepare_shell(root, 'tests/clock-app-presets.qml')
            env = self.environment(root)
            result = subprocess.run([quickshell(), '-p', str(shell)], env=env,
                                    capture_output=True, text=True, timeout=15)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('CLOCK_PRESETS_PASS', output)
            document = json.loads((root / 'settings/macshell/clock.json').read_text())
            self.assertEqual(document['timerPresets']['5000']['soundOptions']['volume'], 42)

    def test_recovery_actions_in_the_clock_window(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shell = self.prepare_shell(root, 'tests/clock-app-recovery.qml')
            env = self.environment(root)
            store = root / 'settings/macshell/clock.json'
            now = int(time.time() * 1000)
            timing = migrate_legacy({'state': 'running', 'total': 30000, 'left': 30000,
                                     'endAt': now + 30000, 'label': 'Tea'}, 'old-boot', 1000, now, 'timer-a')
            timing['stopwatch'] = clock_stopwatch.migrate_legacy({'running': True, 'startAt': now - 1000,
                                                                   'acc': 500, 'laps': [300]}, 1000, now, 'sw-a')
            timing['legacySnoozesRecovery'] = clock_snooze.migrate_legacy([{'at': now + 120000, 'label': 'Wake'}], now)
            timing['missedSnoozes'] = [{'id': 'missed-snooze', 'label': 'Old alert'}]
            with ClockStore(store) as owner:
                owner.commit({'timing': timing}, 'missing', 0)
            result = subprocess.run([quickshell(), '-p', str(shell)], env=env,
                                    capture_output=True, text=True, timeout=20)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('CLOCK_RECOVERY_APP_PASS', output)
            document = json.loads(store.read_text())
            self.assertEqual(document['timing']['legacySnoozesRecovery'], [])
            self.assertEqual([item['label'] for item in document['timing']['snoozes']], ['Wake'])
            self.assertEqual(document['timing']['timer']['state'], 'idle')
            self.assertEqual(document['timing']['stopwatch']['state'], 'idle')
            self.assertEqual(document['timing']['missedSnoozes'], [])

    def test_legacy_mode_cannot_overwrite_versioned_clock_data(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shell = self.prepare_shell(root, 'tests/clock-app-legacy-blocked.qml')
            env = self.environment(root)
            env['MACSHELL_CLOCK_SERVICE'] = '0'
            store = root / 'settings/macshell/clock.json'
            store.parent.mkdir()
            original = b'{"version":2,"revision":7,"timing":{"version":1,"future":"preserve"}}\n'
            store.write_bytes(original)
            result = subprocess.run([quickshell(), '-p', str(shell)], env=env,
                                    capture_output=True, text=True, timeout=12)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('CLOCK_LEGACY_GUARD_PASS', output)
            self.assertEqual(store.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
