#!/usr/bin/env python3
"""Local calendar events; this first version does not schedule notifications."""
import argparse
from datetime import date
import json
import os
from pathlib import Path
import sqlite3
import time
import uuid

from line_service import LineService

SCHEMA = 1
MAX_TIME = 253402300799999


class CalendarError(Exception):
    pass


def validate_id(value):
    try:
        if not isinstance(value, str) or str(uuid.UUID(value)) != value:
            raise ValueError()
    except (ValueError, AttributeError):
        raise CalendarError('Invalid event identifier.')


def event_fields(data):
    name = data.get('title')
    if not isinstance(name, str) or not name.strip() or len(name) > 500 or '\x00' in name:
        raise CalendarError('Enter a title of up to 500 characters.')
    all_day = data.get('allDay')
    if type(all_day) is not bool:
        raise CalendarError('Invalid event type.')
    if all_day:
        day = data.get('date')
        try:
            if not isinstance(day, str) or date.fromisoformat(day).isoformat() != day:
                raise ValueError()
        except ValueError:
            raise CalendarError('Invalid event date.')
        return name.strip(), 1, day, None, None
    start, end = data.get('start'), data.get('end')
    if type(start) is not int or type(end) is not int or not 0 <= start < end <= MAX_TIME:
        raise CalendarError('The event end must be after its start.')
    return name.strip(), 0, None, start, end


class CalendarStore:
    def __init__(self, path):
        path = Path(path)
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, timeout=5, isolation_level=None)
        try:
            os.chmod(path, 0o600)
            self.db.row_factory = sqlite3.Row
            self.db.execute('PRAGMA busy_timeout=5000')
            self.db.execute('PRAGMA synchronous=FULL')
            self.db.execute('BEGIN IMMEDIATE')
            version = self.db.execute('PRAGMA user_version').fetchone()[0]
            if version > SCHEMA:
                raise CalendarError('This calendar database was created by a newer version.')
            if version == 0:
                if self.db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' LIMIT 1").fetchone():
                    raise CalendarError('Unrecognized calendar database.')
                self.db.execute('''CREATE TABLE events (
                    id TEXT PRIMARY KEY, title TEXT NOT NULL, all_day INTEGER NOT NULL,
                    day TEXT, start_ms INTEGER, end_ms INTEGER, deleted INTEGER NOT NULL DEFAULT 0,
                    revision INTEGER NOT NULL DEFAULT 0, updated INTEGER NOT NULL)''')
                self.db.execute('PRAGMA user_version=1')
            self.db.execute('COMMIT')
        except Exception:
            if self.db.in_transaction:
                self.db.execute('ROLLBACK')
            self.db.close()
            raise

    def close(self):
        self.db.close()

    def event(self, event_id):
        row = self.db.execute('SELECT * FROM events WHERE id=?', (event_id,)).fetchone()
        if row is None:
            raise CalendarError('Event no longer exists.')
        return dict(row)

    def snapshot(self):
        rows = [dict(row) for row in self.db.execute('SELECT * FROM events ORDER BY updated DESC,id')]
        return {'events': [row for row in rows if not row['deleted']],
                'deleted': [row for row in rows if row['deleted']]}

    def create(self, data):
        event_id = data.get('id'); validate_id(event_id)
        fields = event_fields(data)
        self.db.execute('INSERT OR IGNORE INTO events(id,title,all_day,day,start_ms,end_ms,updated) VALUES(?,?,?,?,?,?,?)',
                        (event_id, *fields, time.time_ns() // 1000000))
        result = self.event(event_id)
        if result['deleted'] or tuple(result[key] for key in ('title', 'all_day', 'day', 'start_ms', 'end_ms')) != fields:
            raise CalendarError('Event ID is already in use.')
        return result

    def change(self, data, deletion=False):
        event_id = data.get('id'); validate_id(event_id)
        revision = data.get('revision')
        if type(revision) is not int or revision < 0:
            raise CalendarError('Invalid event revision.')
        if deletion:
            deleted = data.get('deleted')
            if type(deleted) is not bool:
                raise CalendarError('Invalid event state.')
            desired = int(deleted)
            changed = self.db.execute('UPDATE events SET deleted=?,revision=revision+1,updated=? WHERE id=? AND revision=?',
                                      (desired, time.time_ns() // 1000000, event_id, revision))
            current = self.event(event_id)
            already_applied = current['revision'] == revision + 1 and current['deleted'] == desired
        else:
            fields = event_fields(data)
            changed = self.db.execute('''UPDATE events SET title=?,all_day=?,day=?,start_ms=?,end_ms=?,revision=revision+1,updated=?
                                      WHERE id=? AND revision=? AND deleted=0''',
                                      (*fields, time.time_ns() // 1000000, event_id, revision))
            current = self.event(event_id)
            already_applied = (current['revision'] == revision + 1 and not current['deleted'] and
                               tuple(current[key] for key in ('title', 'all_day', 'day', 'start_ms', 'end_ms')) == fields)
        if not changed.rowcount and not already_applied:
            raise CalendarError('Event changed elsewhere; reload and try again.')
        return current


class CalendarService(LineService):
    def __init__(self, store):
        super().__init__()
        self.store = store
        self.version = store.db.execute('PRAGMA data_version').fetchone()[0]
        self.next_check = 0

    def command(self, request):
        try:
            action, data = request.get('action'), request.get('data') or {}
            if action == 'load': result = self.store.snapshot()
            elif action == 'create': result = self.store.create(data)
            elif action == 'update': result = self.store.change(data)
            elif action == 'delete': result = self.store.change(data, deletion=True)
            else: raise CalendarError('Unknown operation.')
            response = {'type': 'result', 'success': True, 'result': result}
        except (ValueError, TypeError, KeyError, CalendarError, sqlite3.Error, OSError) as error:
            response = {'type': 'result', 'success': False, 'error': str(error)}
        self.emit(id=request.get('id'), **response)

    def wait_timeout(self): return 1.0

    def tick(self):
        if time.monotonic() < self.next_check: return
        self.next_check = time.monotonic() + 1
        current = self.store.db.execute('PRAGMA data_version').fetchone()[0]
        if current != self.version:
            self.version = current
            self.emit(type='changed')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--store', required=True)
    args = parser.parse_args()
    try: store = CalendarStore(args.store)
    except (CalendarError, sqlite3.Error, OSError) as error:
        print(json.dumps({'type': 'unavailable', 'error': str(error)}), flush=True)
        return 1
    try: CalendarService(store).run()
    finally: store.close()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
