#!/usr/bin/env python3
"""Local calendar events with expanded repeats. Notifications require the Rust helper."""
import argparse
from datetime import date, datetime, timezone
import json
import os
from pathlib import Path
import sqlite3
import time
import uuid
from zoneinfo import ZoneInfo

from clock_calendar import resolve_local_occurrence
from line_service import LineService
from reminders_repeat import next_occurrence, repeat_fields

SCHEMA = 2
MAX_TIME = 253402300799999
DAY_MS = 86_400_000
EXPAND_CAP = 62


class CalendarError(Exception):
    pass


def validate_id(value):
    try:
        if not isinstance(value, str) or str(uuid.UUID(value)) != value:
            raise ValueError()
    except (ValueError, AttributeError):
        raise CalendarError('Invalid event identifier.')


def local_zone():
    name = os.environ.get('TZ', '').lstrip(':')
    if name.startswith('/'):
        marker = 'zoneinfo/'
        if marker in name:
            name = name.split(marker, 1)[1]
    if name:
        try:
            return ZoneInfo(name)
        except Exception:
            raise CalendarError('Cannot determine the event time zone.')
    try:
        with open('/etc/timezone', encoding='utf-8') as file:
            return ZoneInfo(file.read().strip())
    except Exception:
        pass
    try:
        link = os.readlink('/etc/localtime')
        if 'zoneinfo/' in link:
            return ZoneInfo(link.split('zoneinfo/', 1)[1])
    except Exception:
        pass
    return ZoneInfo('UTC')


def zone_of(data, required=False):
    name = data.get('zone')
    if isinstance(name, str) and name:
        try:
            return ZoneInfo(name)
        except Exception:
            raise CalendarError('Cannot determine the event time zone.')
    if required:
        return local_zone()
    return None


def event_record(data):
    name = data.get('title')
    if not isinstance(name, str) or not name.strip() or len(name) > 500 or '\x00' in name:
        raise CalendarError('Enter a title of up to 500 characters.')
    all_day = data.get('allDay')
    if type(all_day) is not bool:
        raise CalendarError('Invalid event type.')
    rule = data.get('repeat', 'none')
    if rule not in ('none', 'daily', 'weekly', 'monthly'):
        raise CalendarError('Invalid repeat rule.')
    title = name.strip()
    if all_day:
        day = data.get('date')
        try:
            if not isinstance(day, str) or date.fromisoformat(day).isoformat() != day:
                raise ValueError()
        except ValueError:
            raise CalendarError('Invalid event date.')
        parsed = date.fromisoformat(day)
        zone = zone_of(data, required=True)
        instant = resolve_local_occurrence(parsed, 9, 0, zone)
        alert = int(instant.timestamp() * 1000)
        return {
            'title': title, 'all_day': 1, 'day': day, 'start': None, 'end': None, 'rule': rule,
            'zone': zone.key, 'date': day, 'day_n': parsed.day, 'hour': 9, 'minute': 0,
            'duration': None, 'alert_next': alert, 'alert_state': 'pending',
        }
    start, end = data.get('start'), data.get('end')
    if type(start) is not int or type(end) is not int or not 0 <= start < end <= MAX_TIME:
        raise CalendarError('The event end must be after its start.')
    duration = end - start
    if rule == 'none':
        return {
            'title': title, 'all_day': 0, 'day': None, 'start': start, 'end': end, 'rule': rule,
            'zone': '', 'date': '', 'day_n': 0, 'hour': 0, 'minute': 0,
            'duration': duration, 'alert_next': start, 'alert_state': 'pending',
        }
    zone = zone_of(data, required=True)
    zone_key, date_iso, day_n, hour, minute = repeat_fields(start, zone)
    return {
        'title': title, 'all_day': 0, 'day': None, 'start': start, 'end': end, 'rule': rule,
        'zone': zone_key, 'date': date_iso, 'day_n': day_n, 'hour': hour, 'minute': minute,
        'duration': duration, 'alert_next': start, 'alert_state': 'pending',
    }


def _utc_midnight(day):
    parsed = date.fromisoformat(day)
    return int(datetime(parsed.year, parsed.month, parsed.day, tzinfo=timezone.utc).timestamp() * 1000)


def occurrence_payload(row, start, day=None):
    item = dict(row)
    if row.get('all_day'):
        item['day'] = day
        item['start_ms'] = None
        item['end_ms'] = None
        item['occurrence'] = day
    else:
        duration = row.get('duration_ms') or ((row.get('end_ms') or start) - (row.get('start_ms') or start))
        item['start_ms'] = start
        item['end_ms'] = start + duration
        item['occurrence'] = start
    return item


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
                    revision INTEGER NOT NULL DEFAULT 0, updated INTEGER NOT NULL,
                    repeat_rule TEXT NOT NULL DEFAULT 'none', repeat_zone TEXT NOT NULL DEFAULT '',
                    repeat_date TEXT NOT NULL DEFAULT '', repeat_day INTEGER NOT NULL DEFAULT 0,
                    repeat_hour INTEGER NOT NULL DEFAULT 0, repeat_minute INTEGER NOT NULL DEFAULT 0,
                    duration_ms INTEGER, alert_state TEXT NOT NULL DEFAULT 'none',
                    alert_token TEXT NOT NULL DEFAULT '', alert_retry_at INTEGER NOT NULL DEFAULT 0,
                    alert_error TEXT NOT NULL DEFAULT '', alert_next_ms INTEGER)''')
                self.db.execute('PRAGMA user_version=2')
            elif version == 1:
                self.db.execute("ALTER TABLE events ADD COLUMN repeat_rule TEXT NOT NULL DEFAULT 'none'")
                self.db.execute("ALTER TABLE events ADD COLUMN repeat_zone TEXT NOT NULL DEFAULT ''")
                self.db.execute("ALTER TABLE events ADD COLUMN repeat_date TEXT NOT NULL DEFAULT ''")
                self.db.execute("ALTER TABLE events ADD COLUMN repeat_day INTEGER NOT NULL DEFAULT 0")
                self.db.execute("ALTER TABLE events ADD COLUMN repeat_hour INTEGER NOT NULL DEFAULT 0")
                self.db.execute("ALTER TABLE events ADD COLUMN repeat_minute INTEGER NOT NULL DEFAULT 0")
                self.db.execute("ALTER TABLE events ADD COLUMN duration_ms INTEGER")
                self.db.execute("ALTER TABLE events ADD COLUMN alert_state TEXT NOT NULL DEFAULT 'none'")
                self.db.execute("ALTER TABLE events ADD COLUMN alert_token TEXT NOT NULL DEFAULT ''")
                self.db.execute("ALTER TABLE events ADD COLUMN alert_retry_at INTEGER NOT NULL DEFAULT 0")
                self.db.execute("ALTER TABLE events ADD COLUMN alert_error TEXT NOT NULL DEFAULT ''")
                self.db.execute("ALTER TABLE events ADD COLUMN alert_next_ms INTEGER")
                self.db.execute('PRAGMA user_version=2')
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

    def snapshot(self, from_ms=None, to_ms=None):
        now = time.time_ns() // 1000000
        if type(from_ms) is not int:
            from_ms = now - 40 * DAY_MS
        if type(to_ms) is not int:
            to_ms = now + 400 * DAY_MS
        if from_ms > to_ms:
            from_ms, to_ms = to_ms, from_ms
        rows = [dict(row) for row in self.db.execute('SELECT * FROM events ORDER BY updated DESC,id')]
        events = [row for row in rows if not row['deleted']]
        deleted = [row for row in rows if row['deleted']]
        occurrences = []
        for row in events:
            occurrences.extend(self.expand(row, from_ms, to_ms))
        return {'events': events, 'deleted': deleted, 'occurrences': occurrences}

    @staticmethod
    def expand(row, from_ms, to_ms, cap=EXPAND_CAP):
        if row.get('deleted'):
            return []
        duration = DAY_MS if row.get('all_day') else (row.get('duration_ms') or 0)
        rule = row.get('repeat_rule') or 'none'
        if rule == 'none':
            if row.get('all_day'):
                day = row.get('day')
                if not day:
                    return []
                start = _utc_midnight(day)
                if start < to_ms and start + duration > from_ms:
                    return [occurrence_payload(row, start, day)]
                return []
            start, end = row.get('start_ms'), row.get('end_ms')
            if start is None or end is None:
                return []
            if start < to_ms and end > from_ms:
                return [occurrence_payload(row, start)]
            return []
        try:
            zone = ZoneInfo(row.get('repeat_zone') or 'UTC')
            current_day = date.fromisoformat(row['repeat_date'])
            if row.get('all_day'):
                due = int(resolve_local_occurrence(current_day, 9, 0, zone).timestamp() * 1000)
            else:
                due = row.get('start_ms')
            if due is None:
                return []
            repeat = {
                'repeat_rule': rule, 'repeat_zone': zone.key, 'repeat_date': row['repeat_date'],
                'repeat_day': row['repeat_day'], 'repeat_hour': row['repeat_hour'],
                'repeat_minute': row['repeat_minute'], 'due_at': due,
            }
        except (ValueError, KeyError, TypeError):
            return []
        out = []
        if due < to_ms and due + duration > from_ms:
            out.append(occurrence_payload(row, due, current_day.isoformat() if row.get('all_day') else None))
        guard = 0
        threshold = max(due, from_ms - 1)
        while len(out) < cap and guard < cap + 8:
            guard += 1
            try:
                day, ms = next_occurrence(repeat, threshold)
            except ValueError:
                break
            if ms >= to_ms:
                break
            if ms + duration > from_ms:
                out.append(occurrence_payload(row, ms, day if row.get('all_day') else None))
            repeat = dict(repeat, repeat_date=day, due_at=ms)
            threshold = ms
        return out

    def create(self, data):
        event_id = data.get('id'); validate_id(event_id)
        record = event_record(data)
        self.db.execute('''INSERT OR IGNORE INTO events(
                id,title,all_day,day,start_ms,end_ms,updated,repeat_rule,repeat_zone,repeat_date,
                repeat_day,repeat_hour,repeat_minute,duration_ms,alert_state,alert_next_ms)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
            (event_id, record['title'], record['all_day'], record['day'], record['start'], record['end'],
             time.time_ns() // 1000000, record['rule'], record['zone'], record['date'], record['day_n'],
             record['hour'], record['minute'], record['duration'], record['alert_state'], record['alert_next']))
        result = self.event(event_id)
        fields = (record['title'], record['all_day'], record['day'], record['start'], record['end'])
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
            record = event_record(data)
            fields = (record['title'], record['all_day'], record['day'], record['start'], record['end'])
            changed = self.db.execute('''UPDATE events SET title=?,all_day=?,day=?,start_ms=?,end_ms=?,repeat_rule=?,
                                      repeat_zone=?,repeat_date=?,repeat_day=?,repeat_hour=?,repeat_minute=?,
                                      duration_ms=?,alert_state=?,alert_token='',alert_retry_at=0,alert_error='',
                                      alert_next_ms=?,revision=revision+1,updated=?
                                      WHERE id=? AND revision=? AND deleted=0''',
                                      (record['title'], record['all_day'], record['day'], record['start'], record['end'],
                                       record['rule'], record['zone'], record['date'], record['day_n'], record['hour'],
                                       record['minute'], record['duration'], record['alert_state'], record['alert_next'],
                                       time.time_ns() // 1000000, event_id, revision))
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
            if action == 'load': result = self.store.snapshot(data.get('from'), data.get('to'))
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
