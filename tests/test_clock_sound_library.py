import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import signal
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'MacShell'))
from clock_sound_library import SoundLibrary, SoundLibraryError


@unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'ffmpeg and ffprobe are required')
class ClockSoundLibraryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.library = SoundLibrary(self.root / 'library')
        self.source = self.root / 'sound.wav'
        with wave.open(str(self.source), 'wb') as output:
            output.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
            output.writeframes(struct.pack('<8000h', *([300] * 8000)))

    def test_builtins_are_distinct_valid_assets(self):
        sounds = self.library.list_builtin()
        self.assertEqual(len(sounds), 40)
        self.assertEqual({item['category'] for item in sounds}, {'chime', 'melody', 'gentle', 'urgent'})
        directory = Path(__file__).resolve().parents[1] / 'MacShell/sounds'
        digests = set()
        for item in sounds:
            path = directory / item['file']
            digests.add(hashlib.sha256(path.read_bytes()).hexdigest())
            with wave.open(str(path), 'rb') as audio:
                self.assertAlmostEqual(audio.getnframes() / audio.getframerate() * 1000, item['durationMs'], delta=1)
        self.assertEqual(len(digests), 40)

    def test_import_copies_decoded_audio_deduplicates_and_survives_source_removal(self):
        record, created = self.library.import_file(self.source, 'Wake up')
        self.assertTrue(created)
        self.assertEqual(record['name'], 'Wake up')
        self.assertEqual(record['durationMs'], 1000)
        same, created = self.library.import_file(self.source, 'Another name')
        self.assertFalse(created)
        self.assertEqual(same, record)
        self.source.unlink()
        self.assertEqual(self.library.list_imported(), [record])
        with wave.open(str(self.library.directory / record['id'] / record['file']), 'rb') as audio:
            self.assertEqual(audio.getnframes(), 8000)

    def test_favorites_survive_restart_and_preserve_unrecognized_fields(self):
        imported, _ = self.library.import_file(self.source)
        self.library.set_favorite(imported['id'], True)
        self.library.set_favorite('builtin-chime-01', True)
        favorites = self.library.directory / 'favorites.json'
        data = json.loads(favorites.read_text())
        data['futureField'] = {'preserve': True}
        favorites.write_text(json.dumps(data))
        reloaded = SoundLibrary(self.library.directory)
        self.assertEqual({sound['id'] for sound in reloaded.catalog() if sound['favorite']},
                         {imported['id'], 'builtin-chime-01'})
        reloaded.set_favorite(imported['id'], False)
        self.assertEqual(json.loads(favorites.read_text())['futureField'], {'preserve': True})
        self.assertEqual({sound['id'] for sound in reloaded.catalog() if sound['favorite']}, {'builtin-chime-01'})

    def test_invalid_favorites_are_never_overwritten(self):
        self.library.directory.mkdir()
        favorites = self.library.directory / 'favorites.json'
        original = b'{"version": 100, "favorites": []}'
        favorites.write_bytes(original)
        with self.assertRaises(SoundLibraryError):
            self.library.set_favorite('builtin-chime-01', True)
        self.assertEqual(favorites.read_bytes(), original)

    def test_builtin_visibility_is_persistent_and_preserves_references(self):
        imported, _ = self.library.import_file(self.source)
        self.library.set_favorite('builtin-chime-01', True)
        self.library.set_favorite(imported['id'], True)
        self.library.set_builtins_visible(False)
        reloaded = SoundLibrary(self.library.directory)
        state = reloaded.catalog_state()
        self.assertFalse(state['showBuiltins'])
        self.assertEqual([item['id'] for item in state['sounds']], [imported['id']])
        self.assertTrue(state['sounds'][0]['favorite'])
        self.assertTrue(reloaded.resolve('builtin-chime-01').is_file())
        reloaded.set_favorite(imported['id'], False)
        self.assertFalse(reloaded.catalog_state()['showBuiltins'])
        reloaded.set_builtins_visible(True)
        self.assertEqual(len(reloaded.catalog()), 41)
        self.assertTrue(next(x for x in reloaded.catalog() if x['id'] == 'builtin-chime-01')['favorite'])
        with self.assertRaises(SoundLibraryError): reloaded.set_builtins_visible('false')

    def test_only_imported_sounds_can_be_deleted(self):
        imported, _ = self.library.import_file(self.source)
        with self.assertRaises(SoundLibraryError):
            self.library.delete_imported('builtin-chime-01')
        self.library.delete_imported(imported['id'])
        self.assertEqual(self.library.list_imported(), [])
        self.assertFalse((self.library.directory / imported['id']).exists())

    def test_rename_keeps_identity_audio_and_metadata_extensions(self):
        imported, _ = self.library.import_file(self.source)
        directory = self.library.directory / imported['id']
        path = directory / 'metadata.json'
        metadata = json.loads(path.read_text())
        metadata['extra'] = {'keep': True}
        path.write_text(json.dumps(metadata))
        self.library.rename_imported(imported['id'], ' Новое имя ')
        changed = self.library.list_imported()[0]
        self.assertEqual((changed['id'], changed['name'], changed['extra']), (imported['id'], 'Новое имя', {'keep': True}))
        self.assertEqual((directory / changed['file']).read_bytes(), self.source.read_bytes())
        with self.assertRaises(SoundLibraryError):
            self.library.rename_imported(imported['id'], '\n')
        self.assertEqual(self.library.list_imported()[0], changed)
        with self.assertRaises(SoundLibraryError):
            self.library.rename_imported('builtin-chime-01', 'Forbidden')

    def test_cleanup_failure_reports_that_unpublished_audio_remains(self):
        imported, _ = self.library.import_file(self.source)
        with mock.patch('clock_sound_library.shutil.rmtree', side_effect=OSError('disk error')):
            self.assertFalse(self.library.delete_imported(imported['id']))
        self.assertEqual(self.library.list_imported(), [])
        self.assertEqual(len(list(self.library.directory.glob('.deleted-*'))), 1)

    def test_invalid_input_and_failed_decode_leave_no_published_entry(self):
        bad = self.root / 'broken.wav'
        bad.write_bytes(b'not a sound')
        with self.assertRaises(SoundLibraryError):
            self.library.import_file(bad)
        self.assertEqual(self.library.list_imported(), [])
        self.assertFalse(any(path.name.startswith('.import-') for path in self.library.directory.iterdir()))
        with self.assertRaises(SoundLibraryError):
            self.library.import_file(self.root / 'playlist.m3u')
        fifo = self.root / 'pipe.wav'
        os.mkfifo(fifo)
        with self.assertRaises(SoundLibraryError):
            self.library.import_file(fifo)
        with self.assertRaises(SoundLibraryError):
            self.library.import_file(self.source, '\n')

    def test_common_compressed_formats_are_decoded_before_import(self):
        for extension in ('flac', 'mp3', 'ogg'):
            with self.subTest(extension=extension):
                source = self.root / ('compressed.' + extension)
                subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(self.source), str(source)],
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=10)
                record, created = self.library.import_file(source)
                self.assertTrue(created)
                self.assertGreater(record['durationMs'], 0)
                self.assertEqual((self.library.directory / record['id'] / record['file']).read_bytes(), source.read_bytes())

    def test_aac_formats_import_when_the_encoder_is_available(self):
        for extension in ('m4a', 'aac'):
            with self.subTest(extension=extension):
                source = self.root / ('extra.' + extension)
                result = subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(self.source), str(source)],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=10)
                if result.returncode:
                    self.skipTest('AAC encoder is unavailable')
                record, created = self.library.import_file(source)
                self.assertTrue(created)
                self.assertGreater(record['durationMs'], 0)

    def test_concurrent_duplicate_imports_publish_exactly_one_complete_entry(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(self.library.import_file, [self.source, self.source]))
        self.assertEqual(sum(created for _, created in results), 1)
        self.assertEqual(results[0][0], results[1][0])
        self.assertEqual(len(self.library.list_imported()), 1)

    def test_decode_timeout_does_not_publish_or_leave_staging(self):
        with mock.patch.object(self.library, '_decode', side_effect=SoundLibraryError('timeout')):
            with self.assertRaises(SoundLibraryError):
                self.library.import_file(self.source)
        self.assertEqual(self.library.list_imported(), [])
        self.assertFalse(any(path.name.startswith('.import-') for path in self.library.directory.iterdir()))

    def test_failed_publication_does_not_expose_a_partial_sound(self):
        with mock.patch('clock_sound_library.os.rename', side_effect=OSError('disk error')):
            with self.assertRaises(SoundLibraryError):
                self.library.import_file(self.source)
        self.assertEqual(self.library.list_imported(), [])
        self.assertFalse(any(path.name.startswith('.import-') for path in self.library.directory.iterdir()))

    def test_stopped_worker_releases_decoder_and_cleans_staging(self):
        bindir = self.root / 'bin'
        bindir.mkdir()
        pid_file = self.root / 'decoder.pid'
        probe = bindir / 'ffprobe'
        probe.write_text('#!/usr/bin/env python3\nimport os, time\nopen(os.environ["TEST_SOUND_PID"], "w").write(str(os.getpid()))\ntime.sleep(30)\n')
        probe.chmod(0o755)
        env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ.get('PATH', ''), TEST_SOUND_PID=str(pid_file))
        worker = subprocess.Popen([sys.executable, str(Path(__file__).resolve().parents[1] / 'MacShell/clock_sound_import.py'),
                                   '--library', str(self.library.directory), str(self.source)], env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue(pid_file.exists(), 'decoder did not start')
            decoder_pid = int(pid_file.read_text())
            worker.send_signal(signal.SIGTERM)
            worker.communicate(timeout=5)
            self.assertNotEqual(worker.returncode, 0)
            self.assertFalse(Path('/proc', str(decoder_pid)).exists())
            self.assertEqual(self.library.list_imported(), [])
            self.assertFalse(any(path.name.startswith('.import-') for path in self.library.directory.iterdir()))
        finally:
            if worker.poll() is None:
                worker.kill()
                worker.communicate(timeout=5)

    def test_size_and_duration_limits_reject_without_publishing(self):
        with mock.patch('clock_sound_library.MAX_BYTES', 100):
            with self.assertRaises(SoundLibraryError):
                self.library.import_file(self.source)
        long_audio = self.root / 'long.wav'
        with wave.open(str(long_audio), 'wb') as output:
            output.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
            for _ in range(601):
                output.writeframesraw(bytes(16000))
        with self.assertRaisesRegex(SoundLibraryError, 'duration'):
            self.library.import_file(long_audio)
        self.assertEqual(self.library.list_imported(), [])


if __name__ == '__main__':
    unittest.main()
