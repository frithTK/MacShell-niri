#!/usr/bin/env python3
"""Local task lists with transactional, versioned writes."""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import sys
import time
import uuid
from line_service import LineService
from reminders_scheduler import AlertScheduler
from reminders_repeat import RULES, next_occurrence, repeat_fields
from clock_source import system_zone

SCHEMA = 4
MAX_TITLE = 500


class RemindersError(Exception):
    pass


def identifier(value):
    if not isinstance(value, str) or str(uuid.UUID(value)) != value:
        raise RemindersError('Invalid identifier.')
    return value


def title(value):
    if not isinstance(value, str) or not value.strip() or len(value) > MAX_TITLE or '\x00' in value:
        raise RemindersError('Enter a non-empty title of up to 500 characters.')
    return value.strip()


class RemindersStore:
    def __init__(self, path):
        path = Path(path)
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, timeout=5, isolation_level=None)
        os.chmod(path, 0o600)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA foreign_keys=ON')
        self.db.execute('PRAGMA busy_timeout=5000')
        self.db.execute('PRAGMA synchronous=FULL')
        version = self.db.execute('PRAGMA user_version').fetchone()[0]
        if version > SCHEMA:
            self.db.close()
            raise RemindersError('This task database was created by a newer version.')
        if version == 0:
            self.db.executescript('''BEGIN IMMEDIATE;
                CREATE TABLE IF NOT EXISTS lists (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, revision INTEGER NOT NULL, created INTEGER NOT NULL,
                    deleted INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS tasks (
                    id TEXT PRIMARY KEY, list_id TEXT NOT NULL REFERENCES lists(id), title TEXT NOT NULL,
                    done INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0,
                    revision INTEGER NOT NULL, updated INTEGER NOT NULL, due_at INTEGER,
                    alert_state TEXT NOT NULL DEFAULT 'none', alert_token TEXT NOT NULL DEFAULT '',
                    alert_retry_at INTEGER NOT NULL DEFAULT 0, alert_error TEXT NOT NULL DEFAULT '',
                    alert_resolution_id TEXT NOT NULL DEFAULT '', alert_resolution_retry INTEGER,
                    repeat_rule TEXT NOT NULL DEFAULT 'none', repeat_zone TEXT NOT NULL DEFAULT '',
                    repeat_date TEXT NOT NULL DEFAULT '', repeat_day INTEGER NOT NULL DEFAULT 0,
                    repeat_hour INTEGER NOT NULL DEFAULT 0, repeat_minute INTEGER NOT NULL DEFAULT 0,
                    repeat_completed_revision INTEGER NOT NULL DEFAULT -1
                );
                INSERT OR IGNORE INTO lists(id,name,revision,created,deleted) VALUES('inbox','',0,0,0);
                PRAGMA user_version=4;
                COMMIT;''')
        elif version in (1, 2, 3):
            # Keep other writers out between the backup snapshot and migration.
            self.db.execute('BEGIN IMMEDIATE')
            try:
                current = self.db.execute('PRAGMA user_version').fetchone()[0]
                if current != SCHEMA:
                    if current != version: raise RemindersError('Database version changed during migration.')
                    backup = path.with_name(path.name + '.v' + str(version) + '-' + uuid.uuid4().hex + '.bak')
                    descriptor = os.open(backup, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                    os.close(descriptor)
                    with closing(sqlite3.connect(path)) as source, closing(sqlite3.connect(backup)) as old:
                        source.backup(old)
                    descriptor = os.open(backup, os.O_RDONLY)
                    try: os.fsync(descriptor)
                    finally: os.close(descriptor)
                    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
                    try: os.fsync(descriptor)
                    finally: os.close(descriptor)
                    if version == 1: self.db.execute('ALTER TABLE lists ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0')
                    if version in (1, 2):
                        self.db.execute('ALTER TABLE tasks ADD COLUMN due_at INTEGER')
                        self.db.execute("ALTER TABLE tasks ADD COLUMN alert_state TEXT NOT NULL DEFAULT 'none'")
                        self.db.execute("ALTER TABLE tasks ADD COLUMN alert_token TEXT NOT NULL DEFAULT ''")
                        self.db.execute('ALTER TABLE tasks ADD COLUMN alert_retry_at INTEGER NOT NULL DEFAULT 0')
                        self.db.execute("ALTER TABLE tasks ADD COLUMN alert_error TEXT NOT NULL DEFAULT ''")
                        self.db.execute("ALTER TABLE tasks ADD COLUMN alert_resolution_id TEXT NOT NULL DEFAULT ''")
                        self.db.execute('ALTER TABLE tasks ADD COLUMN alert_resolution_retry INTEGER')
                    self.db.execute("ALTER TABLE tasks ADD COLUMN repeat_rule TEXT NOT NULL DEFAULT 'none'")
                    self.db.execute("ALTER TABLE tasks ADD COLUMN repeat_zone TEXT NOT NULL DEFAULT ''")
                    self.db.execute("ALTER TABLE tasks ADD COLUMN repeat_date TEXT NOT NULL DEFAULT ''")
                    self.db.execute('ALTER TABLE tasks ADD COLUMN repeat_day INTEGER NOT NULL DEFAULT 0')
                    self.db.execute('ALTER TABLE tasks ADD COLUMN repeat_hour INTEGER NOT NULL DEFAULT 0')
                    self.db.execute('ALTER TABLE tasks ADD COLUMN repeat_minute INTEGER NOT NULL DEFAULT 0')
                    self.db.execute('ALTER TABLE tasks ADD COLUMN repeat_completed_revision INTEGER NOT NULL DEFAULT -1')
                    self.db.execute('PRAGMA user_version=4')
                self.db.execute('COMMIT')
            except Exception:
                self.db.execute('ROLLBACK')
                self.db.close()
                raise

    def close(self):
        self.db.close()

    def snapshot(self):
        lists = [dict(row) for row in self.db.execute('SELECT * FROM lists WHERE deleted=0 ORDER BY created,id')]
        tasks = [dict(row) for row in self.db.execute(
            'SELECT t.* FROM tasks t JOIN lists l ON l.id=t.list_id '
            'WHERE t.deleted=0 AND l.deleted=0 ORDER BY t.done,t.updated DESC,t.id')]
        deleted_lists = [dict(row) for row in self.db.execute('SELECT * FROM lists WHERE deleted=1 ORDER BY created,id')]
        deleted_tasks = [dict(row) for row in self.db.execute(
            'SELECT t.* FROM tasks t JOIN lists l ON l.id=t.list_id '
            'WHERE t.deleted=1 AND l.deleted=0 ORDER BY t.updated DESC,t.id')]
        return {'lists': lists, 'tasks': tasks, 'deletedLists': deleted_lists, 'deletedTasks': deleted_tasks}

    def create_list(self, list_id, name):
        identifier(list_id); name = title(name)
        self.db.execute('INSERT OR IGNORE INTO lists(id,name,revision,created,deleted) VALUES(?,?,0,?,0)', (list_id, name, time.time_ns() // 1000000))
        row = dict(self.db.execute('SELECT * FROM lists WHERE id=?', (list_id,)).fetchone())
        if row['name'] != name or row['deleted']:
            raise RemindersError('List ID is already in use.')
        return row

    def update_list(self, list_id, revision, field, value):
        if list_id == 'inbox': raise RemindersError('The default list cannot be changed.')
        if type(revision) is not int or revision < 0: raise RemindersError('Invalid revision.')
        if field == 'name': value = title(value)
        elif field == 'deleted':
            if type(value) is not bool: raise RemindersError('Invalid list state.')
            value = int(value)
        else: raise RemindersError('Unknown list field.')
        condition = ' AND deleted=0' if field == 'name' else ''
        changed = self.db.execute('UPDATE lists SET ' + field + '=?,revision=revision+1 WHERE id=? AND revision=?' + condition,
                                  (value, list_id, revision))
        row = self.db.execute('SELECT * FROM lists WHERE id=?', (list_id,)).fetchone()
        if row is None: raise RemindersError('List no longer exists.')
        current = dict(row)
        if changed.rowcount == 0 and not (current['revision'] == revision + 1 and current[field] == value):
            raise RemindersError('List changed elsewhere; reload and try again.')
        return current

    def task(self, task_id):
        row = self.db.execute('SELECT * FROM tasks WHERE id=?', (task_id,)).fetchone()
        if row is None:
            raise RemindersError('Task no longer exists.')
        return dict(row)

    def create_task(self, task_id, list_id, value):
        identifier(task_id); value = title(value)
        if not isinstance(list_id, str):
            raise RemindersError('Invalid list ID.')
        if not self.db.execute('SELECT 1 FROM lists WHERE id=? AND deleted=0', (list_id,)).fetchone():
            raise RemindersError('List no longer exists.')
        self.db.execute('INSERT OR IGNORE INTO tasks(id,list_id,title,done,deleted,revision,updated) '
                        'SELECT ?,id,?,0,0,0,? FROM lists WHERE id=? AND deleted=0',
                        (task_id, value, time.time_ns() // 1000000, list_id))
        row = self.task(task_id)
        if row['list_id'] != list_id or row['title'] != value or row['deleted']:
            raise RemindersError('Task ID is already in use.')
        return row

    def update(self, task_id, revision, field, value):
        if type(revision) is not int or revision < 0:
            raise RemindersError('Invalid revision.')
        if field == 'title': value = title(value)
        elif field in ('done', 'deleted'):
            if type(value) is not bool: raise RemindersError('Invalid task state.')
            if field == 'done' and value:
                repeated = self.complete_repeat(task_id, revision)
                if repeated is not None: return repeated
            value = int(value)
        else: raise RemindersError('Unknown task field.')
        # The field name is selected only from the fixed list above.
        condition = ('' if field == 'deleted' else ' AND deleted=0') + ' AND EXISTS '
        condition += '(SELECT 1 FROM lists WHERE lists.id=tasks.list_id AND lists.deleted=0)'
        changed = self.db.execute('UPDATE tasks SET ' + field + '=?,revision=revision+1,updated=? '
                                  'WHERE id=? AND revision=?' + condition,
                                  (value, time.time_ns() // 1000000, task_id, revision))
        current = self.task(task_id)
        if changed.rowcount == 0 and not (current['revision'] == revision + 1 and current[field] == value):
            raise RemindersError('Task changed elsewhere; reload and try again.')
        return current

    def complete_repeat(self, task_id, revision):
        self.db.execute('BEGIN IMMEDIATE')
        try:
            row = self.db.execute('''SELECT t.*,l.deleted AS list_deleted FROM tasks t
                                     JOIN lists l ON l.id=t.list_id WHERE t.id=?''', (task_id,)).fetchone()
            if row is None: raise RemindersError('Task no longer exists.')
            current = dict(row)
            if current['revision'] != revision:
                if (current['revision'] == revision + 1 and current['repeat_completed_revision'] == revision
                        and not current['deleted'] and not current['list_deleted']):
                    result = self.task(task_id)
                    self.db.execute('COMMIT'); return result
                if current['repeat_rule'] == 'none':
                    self.db.execute('COMMIT'); return None
                raise RemindersError('Task changed elsewhere; reload and try again.')
            if current['repeat_rule'] == 'none' or current['done']:
                self.db.execute('COMMIT'); return None
            if current['deleted'] or current['list_deleted']:
                raise RemindersError('Task changed elsewhere; reload and try again.')
            try:
                day, due_at = next_occurrence(current, time.time_ns() // 1000000)
            except (KeyError, ValueError, OverflowError, OSError) as error:
                raise RemindersError('Cannot calculate the next reminder time.') from error
            self.db.execute('''UPDATE tasks SET due_at=?,repeat_date=?,repeat_completed_revision=?,
                alert_state='pending',alert_token='',alert_retry_at=0,alert_error='',
                alert_resolution_id='',alert_resolution_retry=NULL,revision=revision+1,updated=? WHERE id=?''',
                (due_at, day, revision, time.time_ns() // 1000000, task_id))
            result = self.task(task_id)
            self.db.execute('COMMIT')
            return result
        except Exception:
            self.db.execute('ROLLBACK')
            raise

    def set_details(self, task_id, revision, value, due_at, repeat=None):
        value = title(value)
        if type(revision) is not int or revision < 0: raise RemindersError('Invalid revision.')
        if due_at is not None and (type(due_at) is not int or due_at < 0 or due_at > 253402300799999):
            raise RemindersError('Invalid due time.')
        if repeat is not None and repeat not in RULES: raise RemindersError('Invalid repeat rule.')
        current = self.task(task_id)
        rule = current['repeat_rule'] if repeat is None else repeat
        if due_at is None:
            if repeat is not None and repeat != 'none': raise RemindersError('A repeating reminder needs a due time.')
            rule = 'none'
        if rule == 'none':
            fields = ('', '', 0, 0, 0)
        elif current['due_at'] == due_at and current['repeat_rule'] == rule:
            fields = tuple(current[key] for key in ('repeat_zone', 'repeat_date', 'repeat_day', 'repeat_hour', 'repeat_minute'))
        else:
            try: fields = repeat_fields(due_at, system_zone())
            except (KeyError, ValueError, OverflowError, OSError) as error: raise RemindersError('Cannot determine the reminder time zone.') from error
        changed = self.db.execute('''UPDATE tasks SET title=?,
            alert_state=CASE WHEN due_at IS NOT ? THEN CASE WHEN ? IS NULL THEN 'none' ELSE 'pending' END ELSE alert_state END,
            alert_token=CASE WHEN due_at IS NOT ? THEN '' ELSE alert_token END,
            alert_error=CASE WHEN due_at IS NOT ? THEN '' ELSE alert_error END,
            alert_retry_at=CASE WHEN due_at IS NOT ? THEN 0 ELSE alert_retry_at END,
            alert_resolution_id=CASE WHEN due_at IS NOT ? THEN '' ELSE alert_resolution_id END,
            alert_resolution_retry=CASE WHEN due_at IS NOT ? THEN NULL ELSE alert_resolution_retry END,
            due_at=?,repeat_rule=?,repeat_zone=?,repeat_date=?,repeat_day=?,repeat_hour=?,repeat_minute=?,
            repeat_completed_revision=-1,revision=revision+1,updated=?
            WHERE id=? AND revision=? AND deleted=0 AND EXISTS
                (SELECT 1 FROM lists WHERE lists.id=tasks.list_id AND lists.deleted=0)''',
            (value, due_at, due_at, due_at, due_at, due_at, due_at, due_at, due_at, rule, *fields,
             time.time_ns() // 1000000, task_id, revision))
        current = self.task(task_id)
        if changed.rowcount == 0 and not (current['revision'] == revision + 1 and
                                           current['title'] == value and current['due_at'] == due_at
                                           and current['repeat_rule'] == rule and not current['deleted']):
            raise RemindersError('Task changed elsewhere; reload and try again.')
        return current

    def resolve_alert(self, task_id, revision, due_at, retry, command_id):
        if type(revision) is not int or type(due_at) is not int or type(retry) is not bool:
            raise RemindersError('Invalid alert request.')
        identifier(command_id)
        next_state = 'pending' if retry else 'delivered'
        changed = self.db.execute('''UPDATE tasks SET alert_state=?,alert_token='',alert_retry_at=0,alert_error='',
            alert_resolution_id=?,alert_resolution_retry=?,revision=revision+1
            WHERE id=? AND revision=? AND due_at=? AND alert_state='uncertain' AND deleted=0''',
            (next_state, command_id, int(retry), task_id, revision, due_at))
        current = self.task(task_id)
        if not changed.rowcount and not (current['due_at'] == due_at and current['alert_resolution_id'] == command_id
                                         and current['alert_resolution_retry'] == int(retry)):
            raise RemindersError('Reminder changed; reload before deciding.')
        return current


class RemindersService(LineService):
    def __init__(self, store, path):
        super().__init__()
        self.store = store
        self.scheduler = AlertScheduler(store, path)
        self.next_tick = 0
        self.data_version = store.db.execute('PRAGMA data_version').fetchone()[0]
        self.scheduler_state = None

    def command(self, request):
        try:
            action, data = request.get('action'), request.get('data') or {}
            if action == 'load': result = self.store.snapshot()
            elif action == 'create-list': result = self.store.create_list(data['id'], data['name'])
            elif action == 'create-task': result = self.store.create_task(data['id'], data['listId'], data['title'])
            elif action == 'update': result = self.store.update(data['id'], data['revision'], data['field'], data['value'])
            elif action == 'update-list': result = self.store.update_list(data['id'], data['revision'], data['field'], data['value'])
            elif action == 'set-details': result = self.store.set_details(data['id'], data['revision'], data['title'], data.get('dueAt'), data.get('repeat'))
            elif action == 'resolve-alert': result = self.store.resolve_alert(data['id'], data['revision'], data['dueAt'], data['retry'], data['commandId'])
            else: raise RemindersError('Unknown operation.')
            response = {'type': 'result', 'success': True, 'result': result}
        except (ValueError, KeyError, TypeError, RemindersError, sqlite3.Error, OSError) as error:
            response = {'type': 'result', 'success': False, 'error': str(error)}
        response['id'] = request.get('id')
        self.emit(**response)

    def wait_timeout(self):
        return 1.0

    def tick(self):
        if time.monotonic() < self.next_tick: return
        self.next_tick = time.monotonic() + 1.0
        try:
            changed = self.scheduler.tick(time.time_ns() // 1000000)
            version = self.store.db.execute('PRAGMA data_version').fetchone()[0]
            if version != self.data_version:
                self.data_version = version; changed = True
            state = 'unavailable' if self.scheduler.error else 'owner' if self.scheduler.owner else 'standby'
            if state != self.scheduler_state:
                self.scheduler_state = state; self.emit(type='scheduler', state=state)
            if changed: self.emit(type='changed')
        except (sqlite3.Error, OSError):
            if self.scheduler_state != 'unavailable':
                self.scheduler_state = 'unavailable'; self.emit(type='scheduler', state='unavailable')

    def close(self):
        self.scheduler.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--store', required=True)
    args = parser.parse_args()
    try: store = RemindersStore(args.store)
    except (RemindersError, sqlite3.Error, OSError) as error:
        print(json.dumps({'type': 'unavailable', 'error': str(error)}), flush=True)
        return 1
    try: RemindersService(store, args.store).run()
    finally: store.close()


if __name__ == '__main__':
    sys.exit(main())
