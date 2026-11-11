import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
import uuid

from MacShell.notes_service import NotesStore


ROOT = Path(__file__).resolve().parents[1]


class NotesRustTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='notes-rust-build-')
        cls.addClassCleanup(cls.build.cleanup)
        subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path', str(ROOT / 'native/notes-service/Cargo.toml'), '--target-dir', cls.build.name], check=True, timeout=120)
        cls.binary = Path(cls.build.name) / 'debug/macshell-notes-service'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'data/notes.sqlite3'
        self.id = str(uuid.uuid4())

    def start(self):
        p = subprocess.Popen([str(self.binary), '--store', str(self.path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop, p)
        self.assertEqual(json.loads(p.stdout.readline())['type'], 'hello')
        return p

    @staticmethod
    def stop(p):
        if p.poll() is None: p.terminate()
        p.communicate(timeout=5)

    def request(self, p, action, **data):
        p.stdin.write(json.dumps({'id': 7, 'generation': 3, 'action': action, 'data': data}) + '\n'); p.stdin.flush()
        result = json.loads(p.stdout.readline())
        self.assertEqual((result['id'], result['generation']), (7, 3))
        return result

    def test_python_database_roundtrip_conflicts_and_stickies(self):
        python = NotesStore(self.path)
        python.create(self.id); python.save(self.id, 'Привет 🌍', 0)
        python.close()
        p = self.start()
        self.assertEqual(self.request(p, 'list')['result'][0]['body'], 'Привет 🌍')
        saved = self.request(p, 'save', id=self.id, body='новый текст', revision=1)
        self.assertEqual(saved['result']['revision'], 2)
        self.assertTrue(self.request(p, 'save', id=self.id, body='новый текст', revision=1)['success'])
        self.assertFalse(self.request(p, 'save', id=self.id, body='конфликт', revision=1)['success'])
        layout = [{'id': self.id, 'width': 410, 'workspace': 1, 'output': 'test', 'color': 'green'}]
        self.assertTrue(self.request(p, 'save-stickies', windows=layout)['success'])
        self.assertFalse(self.request(p, 'save-stickies', windows=layout * 2)['success'])
        self.assertFalse(self.request(p, 'save-stickies', windows=[{'id': self.id, 'color': 'red'}])['success'])
        self.assertEqual(self.request(p, 'list-stickies')['result'], layout)
        deleted = self.request(p, 'delete', id=self.id, revision=2)['result']
        self.assertTrue(self.request(p, 'restore', id=self.id, revision=deleted['revision'])['success'])
        self.stop(p)
        python = NotesStore(self.path)
        try:
            self.assertEqual(python.get(self.id)['body'], 'новый текст')
            self.assertEqual(python.list_stickies(), layout)
        finally: python.close()
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_newer_database_rejected_without_schema_changes(self):
        self.path.parent.mkdir()
        db = sqlite3.connect(self.path); db.execute('PRAGMA user_version=999'); db.close()
        result = subprocess.run([str(self.binary), '--store', str(self.path)], capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('newer version', json.loads(result.stdout)['error'])
        db = sqlite3.connect(self.path)
        try: self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], 999)
        finally: db.close()

    def test_copy_and_body_limits(self):
        p = self.start()
        self.assertTrue(self.request(p, 'save-copy', id=self.id, body='hello')['success'])
        self.assertTrue(self.request(p, 'save-copy', id=self.id, body='hello')['success'])
        self.assertFalse(self.request(p, 'save-copy', id=self.id, body='different')['success'])
        self.assertFalse(self.request(p, 'save', id=self.id, body='я' * 524289, revision=0)['success'])
        self.assertEqual(self.request(p, 'list')['result'][0]['body'], 'hello')

    def test_html_sanitize_excerpt_and_attachments(self):
        p = self.start()
        self.assertTrue(self.request(p, 'create', id=self.id)['success'])
        saved = self.request(p, 'save', id=self.id, body='<p>Hi <b>there</b><script>x()</script></p>', revision=0, format='html')
        self.assertTrue(saved['success'])
        self.assertEqual(saved['result']['format'], 'html')
        self.assertEqual(saved['result']['excerpt'], 'Hi there')
        self.assertNotIn('script', saved['result']['body'])
        source = Path(self.temp.name) / 'note.txt'
        source.write_text('hello', encoding='utf-8')
        attached = self.request(p, 'attach', id=self.id, revision=saved['result']['revision'],
                                attachmentId=str(uuid.uuid4()), path=str(source))
        self.assertTrue(attached['success'], attached)
        self.assertEqual(attached['result']['attachments'][0]['name'], 'note.txt')
        self.stop(p)
        python = NotesStore(self.path)
        try:
            note = python.get(self.id)
            self.assertEqual(note['excerpt'], 'Hi there')
            self.assertEqual(len(note['attachments']), 1)
        finally:
            python.close()


if __name__ == '__main__': unittest.main()
