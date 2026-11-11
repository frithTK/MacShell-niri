from datetime import datetime, timezone
import json
import select
import time
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
        deadline = time.time() + 4
        saw = None
        while time.time() < deadline:
            if not select.select([p.stdout], [], [], max(0, deadline - time.time()))[0]:
                break
            saw = json.loads(p.stdout.readline())
            if saw.get('type') == 'changed':
                break
        self.assertEqual(saw and saw.get('type'), 'changed')
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

    def test_monthly_short_month_dst_and_restored_master(self):
        start = int(datetime(2026, 1, 31, 9, tzinfo=timezone.utc).timestamp() * 1000)
        end = start + 3600000
        p = self.start()
        created = self.request(p, 'create', id=self.id, title='Month end', allDay=False,
                               start=start, end=end, repeat='monthly', zone='UTC')
        self.assertTrue(created['success'], created)
        window = {'from': int(datetime(2026, 2, 1, tzinfo=timezone.utc).timestamp() * 1000),
                  'to': int(datetime(2026, 4, 1, tzinfo=timezone.utc).timestamp() * 1000)}
        loaded = self.request(p, 'load', **window)
        days = [item.get('start_ms') for item in loaded['result']['occurrences']]
        feb = int(datetime(2026, 2, 28, 9, tzinfo=timezone.utc).timestamp() * 1000)
        mar = int(datetime(2026, 3, 31, 9, tzinfo=timezone.utc).timestamp() * 1000)
        self.assertIn(feb, days)
        self.assertIn(mar, days)
        ny_start = int(datetime(2026, 3, 7, 7, 30, tzinfo=timezone.utc).timestamp() * 1000)
        ny_id = str(uuid.uuid4())
        gap = self.request(p, 'create', id=ny_id, title='DST', allDay=False,
                           start=ny_start, end=ny_start + 60000, repeat='daily', zone='America/New_York')
        self.assertTrue(gap['success'], gap)
        ny_load = self.request(p, 'load', **{
            'from': int(datetime(2026, 3, 8, tzinfo=timezone.utc).timestamp() * 1000),
            'to': int(datetime(2026, 3, 9, tzinfo=timezone.utc).timestamp() * 1000)})
        ny_days = [item['start_ms'] for item in ny_load['result']['occurrences'] if item['id'] == ny_id]
        self.assertEqual(ny_days, [int(datetime(2026, 3, 8, 7, tzinfo=timezone.utc).timestamp() * 1000)])
        deleted = self.request(p, 'delete', id=self.id, revision=created['result']['revision'], deleted=True)
        self.assertTrue(deleted['success'])
        gone = self.request(p, 'load', **window)
        self.assertFalse(any(item['id'] == self.id for item in gone['result']['occurrences']))
        restored = self.request(p, 'delete', id=self.id, revision=deleted['result']['revision'], deleted=False)
        self.assertTrue(restored['success'])
        back = self.request(p, 'load', **window)
        self.assertTrue(any(item['id'] == self.id for item in back['result']['occurrences']))
        first = created['result']['alert_next_ms']
        again = self.request(p, 'load')['result']['events']
        self.assertEqual([event['alert_next_ms'] for event in again if event['id'] == self.id][0], first)


if __name__ == '__main__': unittest.main()
