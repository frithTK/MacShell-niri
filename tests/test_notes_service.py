import sqlite3
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'MacShell'))
from notes_service import MAX_BODY, NotesError, NotesStore


class NotesStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'notes' / 'notes.sqlite3'
        self.store = NotesStore(self.path)
        self.addCleanup(self.store.close)
        self.note = str(uuid.uuid4())

    def test_unicode_reopens_and_create_is_idempotent(self):
        self.store.create(self.note)
        self.store.save(self.note, 'Привет 🌍\nsecond line', 0)
        self.assertEqual(self.store.create(self.note)['body'], 'Привет 🌍\nsecond line')
        other = NotesStore(self.path)
        try:
            self.assertEqual(other.list()[0]['body'], 'Привет 🌍\nsecond line')
            self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        finally:
            other.close()

    def test_conflict_preserves_both_writer_and_retry_after_lost_response(self):
        self.store.create(self.note)
        other = NotesStore(self.path)
        try:
            first = self.store.save(self.note, 'first', 0)
            self.assertEqual(other.save(self.note, 'first', 0)['revision'], first['revision'])
            with self.assertRaises(NotesError):
                other.save(self.note, 'other edit', 0)
            self.assertEqual(self.store.get(self.note)['body'], 'first')
        finally:
            other.close()

    def test_soft_delete_restore_and_stale_write(self):
        self.store.create(self.note)
        note = self.store.save(self.note, 'content', 0)
        deleted = self.store.deleted(self.note, note['revision'], True)
        self.assertEqual(self.store.deleted(self.note, note['revision'], True)['revision'], deleted['revision'])
        self.assertEqual(self.store.list(), [])
        with self.assertRaises(NotesError): self.store.save(self.note, 'old edit', note['revision'])
        restored = self.store.deleted(self.note, deleted['revision'], False)
        self.assertEqual(self.store.deleted(self.note, deleted['revision'], False)['revision'], restored['revision'])
        self.assertEqual(restored['body'], 'content')
        self.assertEqual(len(self.store.list()), 1)

    def test_conflict_copy_is_atomic_and_retry_safe(self):
        self.store.create(self.note)
        self.store.save(self.note, 'original', 0)
        copy_id = str(uuid.uuid4())
        self.assertEqual(self.store.save_copy(copy_id, 'unsaved edit')['body'], 'unsaved edit')
        self.assertEqual(self.store.save_copy(copy_id, 'unsaved edit')['revision'], 0)
        with self.assertRaises(NotesError): self.store.save_copy(copy_id, 'different')
        self.assertEqual(self.store.get(self.note)['body'], 'original')

    def test_deleted_notes_can_be_recovered_after_reopening(self):
        self.store.create(self.note)
        saved = self.store.save(self.note, 'recover me', 0)
        self.store.deleted(self.note, saved['revision'], True)
        reopened = NotesStore(self.path)
        try:
            deleted = reopened.list_deleted()
            self.assertEqual([(n['id'], n['body']) for n in deleted], [(self.note, 'recover me')])
            reopened.deleted(self.note, deleted[0]['revision'], False)
            self.assertEqual(reopened.list_deleted(), [])
            self.assertEqual(reopened.list()[0]['body'], 'recover me')
        finally:
            reopened.close()

    def test_oversize_does_not_overwrite(self):
        self.store.create(self.note)
        with self.assertRaises(NotesError): self.store.save(self.note, 'я' * MAX_BODY, 0)
        self.assertEqual(self.store.get(self.note)['body'], '')

    def test_newer_schema_is_not_modified(self):
        self.store.db.execute('PRAGMA user_version=999')
        with self.assertRaisesRegex(NotesError, 'newer version'): NotesStore(self.path)
        self.assertEqual(self.store.db.execute('PRAGMA user_version').fetchone()[0], 999)

    def test_incomplete_transaction_is_rolled_back_on_reopen(self):
        self.store.create(self.note)
        db = sqlite3.connect(self.path, isolation_level=None)
        db.execute('BEGIN IMMEDIATE')
        db.execute('UPDATE notes SET body=? WHERE id=?', ('uncommitted', self.note))
        db.close()
        self.assertEqual(self.store.get(self.note)['body'], '')


if __name__ == '__main__':
    unittest.main()
