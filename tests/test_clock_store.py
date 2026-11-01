import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'MacShell'))
import clock_store
from clock_store import ClockStore, ClockStoreBusy, ClockStoreConflict, ClockStoreError


class ClockStoreTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'clock.json'

    def test_migration_preserves_original_bytes_and_unknown_fields(self):
        original = b'{"alarms":[{"id":"a"}],"timer":{"state":"paused","left":42},"extension":{"x":1}}\n'
        self.path.write_bytes(original)
        with ClockStore(self.path) as store:
            document, token = store.read()
            result, _ = store.commit({'timing': {'version': 1, 'timer': {'state': 'paused'}}}, token, 0)
            self.assertEqual(result['alarms'], document['alarms'])
            self.assertEqual(result['timer'], document['timer'])
            self.assertEqual(result['extension'], {'x': 1})
            self.assertEqual((result['version'], result['revision']), (2, 1))
            backups = list(self.path.parent.glob('clock.before-v2-*.json'))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_bytes(), original)
            _, token = store.read()
            store.commit({'recents': [42]}, token, 1)
            self.assertEqual(len(list(self.path.parent.glob('clock.before-v2-*.json'))), 1)

    def test_lock_survives_atomic_replace_and_is_released_on_close(self):
        with ClockStore(self.path) as store:
            _, token = store.read()
            store.commit({'timing': {'version': 1}}, token, 0)
            with self.assertRaises(ClockStoreBusy):
                with ClockStore(self.path):
                    pass
            # A separate process must also be unable to become the owner.
            code = ('from clock_store import ClockStore, ClockStoreBusy\n'
                    'import sys\n'
                    'try:\n'
                    '    with ClockStore(sys.argv[1]): pass\n'
                    'except ClockStoreBusy: sys.exit(23)\n')
            env = dict(os.environ, PYTHONPATH=str(Path(clock_store.__file__).parent))
            result = subprocess.run([sys.executable, '-c', code, str(self.path)], env=env, check=False)
            self.assertEqual(result.returncode, 23)
        with ClockStore(self.path) as replacement:
            self.assertEqual(replacement.read()[0]['revision'], 1)

    def test_revision_and_raw_content_conflicts_do_not_write(self):
        with ClockStore(self.path) as store:
            _, token = store.read()
            doc, token = store.commit({'timing': {'version': 1}, 'unknown': 'kept'}, token, 0)
            with self.assertRaises(ClockStoreConflict):
                store.commit({'x': 1}, token, 0)
            doc['external'] = True
            self.path.write_text(json.dumps(doc))
            external = self.path.read_bytes()
            with self.assertRaises(ClockStoreConflict):
                store.commit({'x': 1}, token, 1)
            self.assertEqual(self.path.read_bytes(), external)

    def test_corrupt_future_and_invalid_files_remain_untouched(self):
        examples = [b'{', b'[]', b'{"version":3}', b'{"version":2,"revision":0,"timing":{"version":2}}',
                    b'{"version":2,"revision":true,"timing":{"version":1}}', b'{"x":NaN}']
        for raw in examples:
            with self.subTest(raw=raw):
                self.path.write_bytes(raw)
                with ClockStore(self.path) as store:
                    with self.assertRaises(ClockStoreError):
                        store.read()
                    with self.assertRaises(ClockStoreError):
                        store.commit({'timing': {'version': 1}}, 'missing', 0)
                self.assertEqual(self.path.read_bytes(), raw)

    def test_interrupted_write_keeps_legacy_and_backup(self):
        original = b'{"timer":{"state":"running"}}'
        self.path.write_bytes(original)
        real_write = clock_store.atomic_write

        def fail_main(path, data):
            if path == self.path:
                raise OSError('simulated interruption')
            return real_write(path, data)

        with ClockStore(self.path) as store:
            _, token = store.read()
            with mock.patch.object(clock_store, 'atomic_write', side_effect=fail_main):
                with self.assertRaises(OSError):
                    store.commit({'timing': {'version': 1}}, token, 0)
        self.assertEqual(self.path.read_bytes(), original)
        self.assertEqual(next(self.path.parent.glob('clock.before-v2-*.json')).read_bytes(), original)

    def test_invalid_updates_do_not_create_a_document(self):
        with ClockStore(self.path) as store:
            with self.assertRaises(ClockStoreError):
                store.commit({'revision': 5, 'timing': {'version': 1}}, 'missing', 0)
            with self.assertRaises(ClockStoreError):
                store.commit({'timing': {'version': 1}, 'value': float('inf')}, 'missing', 0)
            with self.assertRaises(ClockStoreError):
                store.commit({}, 'missing', 0)
        self.assertFalse(self.path.exists())


if __name__ == '__main__':
    unittest.main()
