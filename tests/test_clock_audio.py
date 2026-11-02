import sys
import os
import shutil
import struct
import subprocess
import signal
import time
import tempfile
import unittest
from pathlib import Path
from unittest import mock
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'MacShell'))
from clock_audio import ClockAudio, ClockPreview, RING_LIMIT_MS


class Child:
    def __init__(self):
        self.code = None
        self.terminated = False

    def poll(self):
        return self.code

    def terminate(self):
        self.terminated = True
        self.code = -15

    def wait(self, timeout=None):
        return self.code


class ClockAudioTests(unittest.TestCase):
    def test_volume_repeat_and_fragment_options_are_applied(self):
        first, second = Child(), Child()
        event = {'eventId': 'a', 'kind': 'timer', 'soundOptions': {'volume': 35, 'repeat': False}}
        with tempfile.TemporaryDirectory() as directory, mock.patch('clock_audio.subprocess.Popen', side_effect=[first, second]) as launch:
            audio = ClockAudio(directory)
            audio.start(event, 1000)
            self.assertEqual(launch.call_args.args[0][1], '--volume=0.35')
            first.code = 0
            audio.tick(event, 1100)
            audio.tick(event, 5000)
            self.assertEqual(launch.call_count, 1)
            self.assertIsNone(audio.timeout(5000))
            event = {'eventId': 'b', 'kind': 'timer', 'soundOptions': {'fadeMs': 5000, 'startMs': 1000, 'durationMs': 3000}}
            audio.start(event, 6000)
            args = launch.call_args.args[0]
            self.assertTrue(args[1].endswith('clock_audio_player.py'))
            import json
            self.assertEqual(json.loads(args[3])['startMs'], 1000)
            self.assertEqual(json.loads(args[3])['fadeMs'], 5000)

    def test_failed_fragment_uses_builtin_without_invalid_offset(self):
        first, fallback = Child(), Child()
        with tempfile.TemporaryDirectory() as directory, mock.patch('clock_audio.subprocess.Popen', side_effect=[first, fallback]) as launch:
            audio = ClockAudio(directory)
            event = {'eventId': 'a', 'kind': 'timer', 'soundOptions': {'startMs': 5000}}
            audio.start(event, 1000)
            first.code = 1
            audio.tick(event, 1100)
            self.assertTrue(audio.fallback_used)
            self.assertEqual(launch.call_args.args[0][0], 'pw-play')
            self.assertTrue(launch.call_args.args[0][-1].endswith('/sounds/timer.wav'))

    def test_compressed_imports_are_decoded_before_pipewire_playback(self):
        with tempfile.TemporaryDirectory() as directory:
            for extension in ('flac', 'mp3', 'ogg', 'm4a', 'aac'):
                source = Path(directory) / ('audio.' + extension)
                source.write_bytes(b'fixture')
                with self.subTest(extension=extension), mock.patch('clock_audio.subprocess.Popen', return_value=Child()) as launch:
                    audio = ClockAudio(directory)
                    audio.start({'eventId': 'a', 'kind': 'alarm'}, 1000, source)
                    self.assertTrue(launch.call_args.args[0][1].endswith('clock_audio_player.py'))

    @unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'ffmpeg and ffprobe are required')
    def test_fragment_worker_decodes_and_applies_fade_without_system_volume_change(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            source = temp / 'input.wav'
            with wave.open(str(source), 'wb') as output:
                output.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
                output.writeframes(struct.pack('<8000h', *([10000] * 8000)))
            bindir = temp / 'bin'
            bindir.mkdir()
            player = bindir / 'pw-play'
            player.write_text('#!/usr/bin/env python3\nimport os, sys\nopen(os.environ["TEST_PCM"], "wb").write(sys.stdin.buffer.read())\n')
            player.chmod(0o755)
            import json
            options = {'volume': 80, 'startMs': 100, 'durationMs': 200, 'fadeMs': 200, 'fadeElapsedMs': 0}
            env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ.get('PATH', ''), TEST_PCM=str(temp / 'output.raw'))
            result = subprocess.run([sys.executable, str(root / 'MacShell/clock_audio_player.py'), str(source), json.dumps(options)],
                                    env=env, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            data = (temp / 'output.raw').read_bytes()
            self.assertEqual(len(data), 38400)
            self.assertLess(abs(struct.unpack_from('<h', data, 0)[0]), 100)
            # Some FFmpeg versions pad the final sample during resampling.
            # Measure the late fade over a window instead of one edge sample.
            early_end = int(len(data) * .15) & ~1
            early = struct.unpack('<' + 'h' * (early_end // 2), data[:early_end])
            start, end = int(len(data) * .75) & ~1, int(len(data) * .95) & ~1
            late = struct.unpack('<' + 'h' * ((end - start) // 2), data[start:end])
            early_level = sum(abs(sample) for sample in early) / len(early)
            late_level = sum(abs(sample) for sample in late) / len(late)
            self.assertGreater(late_level, 3000)
            self.assertGreater(late_level, early_level * 3)
            # A repeated fragment continues its fade from the elapsed time.
            options['fadeElapsedMs'] = 100
            result = subprocess.run([sys.executable, str(root / 'MacShell/clock_audio_player.py'), str(source), json.dumps(options)],
                                    env=env, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            data = (temp / 'output.raw').read_bytes()
            middle = struct.unpack('<' + 'h' * (early_end // 2), data[:early_end])
            middle_level = sum(abs(sample) for sample in middle) / len(middle)
            self.assertGreater(middle_level, 3000)
            self.assertLess(middle_level, 5000)

            # Once the fade has finished, another repeat stays at full level.
            options['fadeElapsedMs'] = 200
            result = subprocess.run([sys.executable, str(root / 'MacShell/clock_audio_player.py'), str(source), json.dumps(options)],
                                    env=env, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            data = (temp / 'output.raw').read_bytes()
            full = struct.unpack('<' + 'h' * (early_end // 2), data[:early_end])
            self.assertGreater(sum(abs(sample) for sample in full) / len(full), 6000)

    def test_stopping_fragment_worker_reaps_decoder_and_player(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            bindir = temp / 'bin'; bindir.mkdir()
            for name in ('ffmpeg', 'pw-play'):
                executable = bindir / name
                executable.write_text('#!/usr/bin/env python3\nimport os, time\nopen(os.path.join(os.environ["TEST_PID_DIR"], os.path.basename(__file__) + ".pid"), "w").write(str(os.getpid()))\ntime.sleep(30)\n')
                executable.chmod(0o755)
            env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ.get('PATH', ''), TEST_PID_DIR=directory)
            worker = subprocess.Popen([sys.executable, str(root / 'MacShell/clock_audio_player.py'),
                                       str(temp / 'unused.wav'), '{"fadeMs":1000}'], env=env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 5
                while not all((temp / (name + '.pid')).exists() for name in ('ffmpeg', 'pw-play')) and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(all((temp / (name + '.pid')).exists() for name in ('ffmpeg', 'pw-play')))
                pids = [int((temp / (name + '.pid')).read_text()) for name in ('ffmpeg', 'pw-play')]
                worker.send_signal(signal.SIGTERM)
                worker.wait(timeout=5)
                self.assertTrue(all(not Path('/proc', str(pid)).exists() for pid in pids))
            finally:
                if worker.poll() is None:
                    worker.kill(); worker.wait()
    def test_preview_stops_on_timeout_and_reports_player_failure(self):
        first, second = Child(), Child()
        with mock.patch('clock_audio.subprocess.Popen', side_effect=[first, second]):
            preview = ClockPreview()
            preview.start('first', '/sounds/one.wav', 1000)
            self.assertFalse(preview.tick(1000 + ClockPreview.LIMIT_MS))
            self.assertTrue(first.terminated)
            self.assertIsNone(preview.sound_id)
            preview.start('second', '/sounds/two.wav', 20000)
            second.code = 1
            self.assertTrue(preview.tick(20100))
            self.assertIsNone(preview.sound_id)

    def test_stop_tolerates_player_exit_between_poll_and_terminate(self):
        class ExitedChild(Child):
            def terminate(self):
                self.code = 0
                raise ProcessLookupError()
        for player in (ClockAudio('/sounds'), ClockPreview()):
            player.child = ExitedChild()
            player.stop()
            self.assertIsNone(player.child)

    def test_repetition_stop_and_time_limit_only_affect_owned_child(self):
        children = []
        def spawn(*args, **kwargs):
            child = Child()
            children.append(child)
            return child
        event = {'eventId': 'a', 'kind': 'alarm'}
        with tempfile.TemporaryDirectory() as directory, mock.patch('clock_audio.subprocess.Popen', side_effect=spawn) as launch:
            Path(directory, 'alarm.wav').write_bytes(b'custom')
            audio = ClockAudio(directory)
            audio.start(event, 1000)
            self.assertEqual(launch.call_args.args[0], ['pw-play', '--volume=0.9', str(Path(directory, 'alarm.wav'))])
            children[0].code = 0
            audio.tick(event, 1300)
            audio.tick(event, 1549)
            self.assertEqual(len(children), 1)
            audio.tick(event, 1550)
            self.assertEqual(len(children), 2)
            audio.tick({'eventId': 'other'}, 1600)
            self.assertTrue(children[1].terminated)
            audio.start({'eventId': 'b', 'kind': 'timer'}, 2000)
            audio.tick({'eventId': 'b'}, 2000 + RING_LIMIT_MS)
            self.assertTrue(children[2].terminated)
            self.assertIsNone(audio.event_id)

    def test_failed_player_does_not_restart_in_a_loop(self):
        child = Child()
        with mock.patch('clock_audio.subprocess.Popen', return_value=child) as launch:
            audio = ClockAudio('/sounds')
            audio.start({'eventId': 'a', 'kind': 'timer'}, 1000)
            child.code = 1
            audio.tick({'eventId': 'a'}, 1100)
            self.assertTrue(audio.failed)
            audio.tick({'eventId': 'a'}, 100000)
            self.assertEqual(launch.call_count, 1)
            self.assertIsNone(audio.timeout(100000))

    def test_bad_custom_sound_falls_back_once_and_keeps_using_builtin(self):
        children = []
        def spawn(*args, **kwargs):
            child = Child()
            children.append(child)
            return child
        with tempfile.TemporaryDirectory() as directory, mock.patch('clock_audio.subprocess.Popen', side_effect=spawn) as launch:
            Path(directory, 'alarm.wav').write_bytes(b'bad audio')
            audio = ClockAudio(directory)
            event = {'eventId': 'a', 'kind': 'alarm'}
            audio.start(event, 1000)
            children[0].code = 1
            audio.tick(event, 1100)
            self.assertTrue(audio.fallback_used)
            self.assertFalse(audio.failed)
            self.assertEqual(launch.call_args.args[0][-1], str(Path(__file__).resolve().parents[1] / 'MacShell/sounds/alarm.wav'))
            children[1].code = 0
            audio.tick(event, 1200)
            audio.tick(event, 1450)
            self.assertEqual(launch.call_count, 3)
            self.assertEqual(launch.call_args.args[0][-1], str(Path(__file__).resolve().parents[1] / 'MacShell/sounds/alarm.wav'))
            children[2].code = 1
            audio.tick(event, 1500)
            self.assertTrue(audio.failed)
            audio.tick(event, 1600)
            self.assertEqual(launch.call_count, 3)

    def test_packaged_sounds_are_valid_and_used_when_custom_files_are_missing(self):
        import clock_audio
        directory = Path(clock_audio.__file__).parent / 'sounds'
        for name in ('timer.wav', 'alarm.wav'):
            with wave.open(str(directory / name), 'rb') as sound:
                self.assertEqual((sound.getnchannels(), sound.getsampwidth(), sound.getframerate()), (1, 2, 24000))
                self.assertGreater(sound.getnframes(), 12000)
        with tempfile.TemporaryDirectory() as empty, mock.patch('clock_audio.subprocess.Popen', return_value=Child()) as launch:
            ClockAudio(empty).start({'eventId': 'a', 'kind': 'timer'}, 1000)
            self.assertEqual(launch.call_args.args[0][-1], str(directory / 'timer.wav'))


if __name__ == '__main__':
    unittest.main()
