import json
import select
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'MacShell'))
from calendar_service import CalendarStore


class CalendarRustTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='calendar-rust-build-')
        cls.addClassCleanup(cls.build.cleanup)
        subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path', str(ROOT / 'native/calendar-service/Cargo.toml'), '--target-dir', cls.build.name], check=True, timeout=120)
        cls.binary = Path(cls.build.name) / 'debug/macshell-calendar-service'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'data/calendar.sqlite3'
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
        p.stdin.write(json.dumps({'id': 3, 'action': action, 'data': data}) + '\n'); p.stdin.flush()
        while True:
            result = json.loads(p.stdout.readline())
            if result['type'] == 'result': return result

    def test_cross_implementation_conflicts_and_retries(self):
        store = CalendarStore(self.path)
        store.create({'id': self.id, 'title': 'Привет', 'allDay': True, 'date': '2026-11-08'})
        store.close()
        p = self.start()
        self.assertEqual(self.request(p, 'load')['result']['events'][0]['title'], 'Привет')
        data = dict(id=self.id, revision=0, title=' Updated ', allDay=False, start=1000, end=2000)
        self.assertEqual(self.request(p, 'update', **data)['result']['title'], 'Updated')
        self.assertTrue(self.request(p, 'update', **data)['success'])
        self.assertFalse(self.request(p, 'update', **dict(data, title='conflict'))['success'])
        deleted = self.request(p, 'delete', id=self.id, revision=1, deleted=True)
        self.assertTrue(deleted['success'])
        self.assertTrue(self.request(p, 'delete', id=self.id, revision=1, deleted=True)['success'])
        self.stop(p)
        store = CalendarStore(self.path)
        try:
            self.assertEqual(store.snapshot()['deleted'][0]['title'], 'Updated')
            self.assertEqual(store.change({'id': self.id, 'revision': 2, 'deleted': False}, deletion=True)['deleted'], 0)
        finally: store.close()
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_external_change_notifies(self):
        p = self.start()
        store = CalendarStore(self.path)
        try: store.create({'id': self.id, 'title': 'external', 'allDay': True, 'date': '2026-11-08'})
        finally: store.close()
        self.assertTrue(select.select([p.stdout], [], [], 4)[0])
        self.assertEqual(json.loads(p.stdout.readline())['type'], 'changed')
        self.assertEqual(self.request(p, 'load')['result']['events'][0]['title'], 'external')

    def test_invalid_dates_and_unrecognized_database(self):
        p = self.start()
        for day in ('2025-02-29', '0000-01-01', '2026-2-01'):
            self.assertFalse(self.request(p, 'create', id=self.id, title='x', allDay=True, date=day)['success'])
        self.stop(p)
        other = self.path.parent / 'foreign.sqlite3'
        db = sqlite3.connect(other); db.execute('CREATE TABLE existing (x)'); db.close()
        result = subprocess.run([str(self.binary), '--store', str(other)], capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unrecognized', json.loads(result.stdout)['error'])
        db = sqlite3.connect(other)
        try: self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], 0)
        finally: db.close()


if __name__ == '__main__': unittest.main()
