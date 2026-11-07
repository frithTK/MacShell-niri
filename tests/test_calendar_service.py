import os
from contextlib import closing
import json
from pathlib import Path
import select
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'MacShell'))
from calendar_service import CalendarError, CalendarStore


class CalendarStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'calendar' / 'events.sqlite3'
        self.store = CalendarStore(self.path)
        self.event_id = str(uuid.uuid4())

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def timed(self, **changes):
        return dict({'id': self.event_id, 'title': 'Meeting', 'allDay': False,
                     'start': 1793880000000, 'end': 1793883600000}, **changes)

    def test_persistence_retry_and_restore(self):
        created = self.store.create(self.timed())
        self.assertEqual(self.store.create(self.timed()), created)
        edit = self.timed(revision=0, title='Updated')
        changed = self.store.change(edit)
        self.assertEqual(self.store.change(edit), changed)
        self.store.change({'id': self.event_id, 'revision': 1, 'deleted': True}, deletion=True)
        self.assertEqual(self.store.snapshot()['events'], [])
        self.assertEqual(self.store.snapshot()['deleted'][0]['title'], 'Updated')
        self.store.change({'id': self.event_id, 'revision': 2, 'deleted': False}, deletion=True)
        self.store.close()
        self.store = CalendarStore(self.path)
        self.assertEqual(self.store.snapshot()['events'][0]['title'], 'Updated')
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)

    def test_conflict_is_not_overwritten(self):
        self.store.create(self.timed())
        other = CalendarStore(self.path)
        try:
            other.change(self.timed(revision=0, title='Other window'))
            with self.assertRaises(CalendarError):
                self.store.change(self.timed(revision=0, title='My unsaved edit'))
            self.assertEqual(self.store.event(self.event_id)['title'], 'Other window')
        finally:
            other.close()

    def test_all_day_and_invalid_event_times(self):
        self.store.create({'id': self.event_id, 'title': 'Day off', 'allDay': True, 'date': '2028-02-29'})
        self.assertEqual(self.store.event(self.event_id)['day'], '2028-02-29')
        for changes in ({'start': 1, 'end': 1}, {'start': True}, {'title': ''}):
            with self.subTest(changes=changes), self.assertRaises(CalendarError):
                self.store.create(self.timed(id=str(uuid.uuid4()), **changes))
        with self.assertRaises(CalendarError):
            self.store.create({'id': str(uuid.uuid4()), 'title': 'Bad date', 'allDay': True, 'date': '2027-02-29'})

    def test_unknown_future_schema_is_not_modified(self):
        future = Path(self.temp.name) / 'future.db'
        with closing(sqlite3.connect(future)) as db:
            db.execute('CREATE TABLE evidence (value TEXT)')
            db.execute("INSERT INTO evidence VALUES ('untouched')")
            db.execute('PRAGMA user_version=99')
            db.commit()
        with self.assertRaises(CalendarError):
            CalendarStore(future)
        with closing(sqlite3.connect(future)) as db:
            self.assertEqual(db.execute('SELECT value FROM evidence').fetchone()[0], 'untouched')

    def test_service_notifies_another_writer(self):
        helper = Path(__file__).resolve().parents[1] / 'MacShell' / 'calendar_service.py'
        process = subprocess.Popen([sys.executable, '-u', str(helper), '--store', str(self.path)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        def receive():
            deadline = time.monotonic() + 5
            data = bytearray()
            while time.monotonic() < deadline:
                ready, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
                if not ready: break
                byte = os.read(process.stdout.fileno(), 1)
                if not byte: break
                if byte == b'\n': return json.loads(data)
                data.extend(byte)
            self.fail('Calendar service did not respond')

        def send(request_id):
            request = {'generation': 1, 'id': request_id, 'action': 'load', 'data': {}}
            process.stdin.write((json.dumps(request) + '\n').encode())
            process.stdin.flush()

        try:
            self.assertEqual(receive()['type'], 'ready')
            send(1)
            self.assertEqual(receive()['result']['events'], [])
            self.store.create(self.timed())
            self.assertEqual(receive()['type'], 'changed')
            send(2)
            self.assertEqual(receive()['result']['events'][0]['title'], 'Meeting')
        finally:
            process.stdin.close()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
            process.stdout.close(); process.stderr.close()


if __name__ == '__main__': unittest.main()
