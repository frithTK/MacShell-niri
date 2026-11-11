import sqlite3
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'MacShell'))
from notes_service import MAX_BODY, NotesError, NotesStore, normalize_note


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

    def test_sticky_layout_survives_reopen_and_invalid_write_preserves_it(self):
        self.store.create(self.note)
        layout = [{'id': self.note, 'width': 410, 'height': 320, 'x': 80, 'y': 100,
                   'output': 'test-output', 'workspace': 1}]
        self.store.save_stickies(layout)
        with self.assertRaises(NotesError):
            self.store.save_stickies([{'id': self.note, 'width': 410}, {'id': self.note}])
        with self.assertRaises(NotesError):
            self.store.save_stickies([{'id': 'invalid'}])
        reopened = NotesStore(self.path)
        try:
            self.assertEqual(reopened.list_stickies(), layout)
        finally:
            reopened.close()

    def test_sticky_color_rejects_unknown_and_keeps_palette_across_reopen(self):
        self.store.create(self.note)
        layout = [{'id': self.note, 'width': 410, 'height': 320, 'color': 'pink'}]
        self.assertEqual(self.store.save_stickies(layout), layout)
        missing = [{'id': self.note, 'width': 410, 'height': 320}]
        self.assertEqual(self.store.save_stickies(missing), missing)
        self.store.save_stickies(layout)
        with self.assertRaisesRegex(NotesError, 'color'):
            self.store.save_stickies([{'id': self.note, 'width': 410, 'color': 'red'}])
        with self.assertRaisesRegex(NotesError, 'color'):
            self.store.save_stickies([{'id': self.note, 'width': 410, 'color': '#ff00ff'}])
        reopened = NotesStore(self.path)
        try:
            self.assertEqual(reopened.list_stickies(), layout)
            note = reopened.get(self.note)
            self.assertNotIn('color', note)
        finally:
            reopened.close()

    def test_v1_migrates_body_to_plain_excerpt(self):
        self.store.close()
        db = sqlite3.connect(self.path)
        db.executescript('''DROP TABLE IF EXISTS notes; DROP TABLE IF EXISTS attachments;
            CREATE TABLE notes (id TEXT PRIMARY KEY, body TEXT NOT NULL, revision INTEGER NOT NULL,
                updated INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0);
            INSERT INTO notes VALUES ('%s', '<b>kept as text</b>', 1, 1, 0);
            PRAGMA user_version=1;''' % self.note)
        db.close()
        migrated = NotesStore(self.path)
        try:
            self.assertEqual(migrated.db.execute('PRAGMA user_version').fetchone()[0], 2)
            note = migrated.get(self.note)
            self.assertEqual(note['format'], 'plain')
            self.assertEqual(note['excerpt'], '<b>kept as text</b>')
            self.assertEqual(note['body'], '<b>kept as text</b>')
        finally:
            migrated.close()

    def test_html_is_sanitized_and_excerpted(self):
        self.assertEqual(normalize_note('plain', 'plain'), ('plain', 'plain', 'plain'))
        body, excerpt, fmt = normalize_note('<p>Hello <b>world</b><script>alert(1)</script></p>', 'html')
        self.assertEqual(fmt, 'html')
        self.assertEqual(excerpt, 'Hello world')
        self.assertIn('<b>world</b>', body)
        self.assertNotIn('script', body)
        self.assertNotIn('alert', body)
        stripped, text, fmt = normalize_note('<p>only text</p>', 'html')
        self.assertEqual((stripped, text, fmt), ('only text', 'only text', 'plain'))
        self.store.create(self.note)
        saved = self.store.save(self.note, '<p>Hi <i>there</i><iframe src="x"></iframe></p>', 0, 'html')
        self.assertEqual(saved['format'], 'html')
        self.assertEqual(saved['excerpt'], 'Hi there')
        self.assertNotIn('iframe', saved['body'])
        listed = self.store.list()[0]
        self.assertEqual(listed['excerpt'], 'Hi there')
        self.assertNotEqual(listed['body'], listed['excerpt'])

    def test_attachment_survives_reopen_and_stale_revision_is_rejected(self):
        self.store.create(self.note)
        source = Path(self.tmp.name) / 'photo.png'
        source.write_bytes(b'\x89PNG\r\n' + b'x' * 32)
        attached = self.store.attach(self.note, 0, str(uuid.uuid4()), source)
        self.assertEqual(len(attached['attachments']), 1)
        self.assertEqual(attached['attachments'][0]['name'], 'photo.png')
        self.assertEqual(attached['attachments'][0]['mime'], 'image/png')
        stored = self.store.attachment_path(self.note, attached['attachments'][0]['id'])
        self.assertEqual(stored.read_bytes()[:8], source.read_bytes()[:8])
        self.assertEqual(stored.stat().st_mode & 0o777, 0o600)
        with self.assertRaisesRegex(NotesError, 'elsewhere'):
            self.store.attach(self.note, 0, str(uuid.uuid4()), source)
        reopened = NotesStore(self.path)
        try:
            note = reopened.get(self.note)
            self.assertEqual(len(note['attachments']), 1)
            self.assertTrue(reopened.attachment_path(self.note, note['attachments'][0]['id']).is_file())
            reopened.detach(self.note, note['revision'], note['attachments'][0]['id'])
            self.assertEqual(reopened.get(self.note)['attachments'], [])
            self.assertFalse(reopened.attachment_path(self.note, note['attachments'][0]['id']).exists())
        finally:
            reopened.close()

    def test_oversize_attachment_is_rejected(self):
        self.store.create(self.note)
        source = Path(self.tmp.name) / 'huge.bin'
        source.write_bytes(b'a' * (20 * 1024 * 1024 + 1))
        with self.assertRaisesRegex(NotesError, 'too large'):
            self.store.attach(self.note, 0, str(uuid.uuid4()), source)
        self.assertEqual(self.store.get(self.note)['attachments'], [])


if __name__ == '__main__':
    unittest.main()
