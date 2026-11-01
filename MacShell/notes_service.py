#!/usr/bin/env python3
"""Transactional, local plain-text Notes storage and JSON-lines service."""
import argparse
import json
import os
from pathlib import Path
import sqlite3
import sys
import time
import uuid

MAX_BODY = 1024 * 1024
SCHEMA = 1


class NotesError(Exception):
    pass


class NotesStore:
    def __init__(self, path):
        path = Path(path)
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, timeout=5, isolation_level=None)
        os.chmod(path, 0o600)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA busy_timeout=5000')
        self.db.execute('PRAGMA synchronous=FULL')
        version = self.db.execute('PRAGMA user_version').fetchone()[0]
        if version > SCHEMA:
            self.db.close()
            raise NotesError('This notes database was created by a newer version.')
        if version == 0:
            self.db.executescript('''BEGIN IMMEDIATE;
                CREATE TABLE IF NOT EXISTS notes (
                    id TEXT PRIMARY KEY, body TEXT NOT NULL, revision INTEGER NOT NULL,
                    updated INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0
                );
                PRAGMA user_version=1;
                COMMIT;''')

    def close(self):
        self.db.close()

    def list(self):
        return [dict(row) for row in self.db.execute(
            'SELECT id, body, revision, updated FROM notes WHERE deleted=0 ORDER BY updated DESC, id')]

    def list_deleted(self):
        return [dict(row) for row in self.db.execute(
            'SELECT id, body, revision, updated FROM notes WHERE deleted=1 ORDER BY updated DESC, id')]

    def create(self, note_id):
        if not isinstance(note_id, str) or str(uuid.UUID(note_id)) != note_id:
            raise NotesError('Invalid note ID.')
        with self.db:
            self.db.execute('INSERT OR IGNORE INTO notes(id,body,revision,updated) VALUES(?,?,0,?)',
                            (note_id, '', time.time_ns() // 1000000))
        return self.get(note_id)

    def get(self, note_id):
        row = self.db.execute('SELECT id,body,revision,updated,deleted FROM notes WHERE id=?', (note_id,)).fetchone()
        if row is None:
            raise NotesError('Note no longer exists.')
        return dict(row)

    def save_copy(self, note_id, body):
        if not isinstance(note_id, str) or str(uuid.UUID(note_id)) != note_id:
            raise NotesError('Invalid note ID.')
        if not isinstance(body, str) or len(body.encode('utf-8')) > MAX_BODY:
            raise NotesError('Note is too large.')
        self.db.execute('INSERT OR IGNORE INTO notes(id,body,revision,updated) VALUES(?,?,0,?)',
                        (note_id, body, time.time_ns() // 1000000))
        note = self.get(note_id)
        if note['deleted'] or note['body'] != body:
            raise NotesError('Copy ID is already in use.')
        return note

    def save(self, note_id, body, revision):
        if not isinstance(body, str) or len(body.encode('utf-8')) > MAX_BODY:
            raise NotesError('Note is too large.')
        if type(revision) is not int or revision < 0:
            raise NotesError('Invalid revision.')
        now = time.time_ns() // 1000000
        result = self.db.execute('UPDATE notes SET body=?,revision=revision+1,updated=? '
                                 'WHERE id=? AND revision=? AND deleted=0', (body, now, note_id, revision))
        if result.rowcount != 1:
            current = self.get(note_id)
            if not current['deleted'] and current['body'] == body:
                return current  # the previous response may have been lost after commit
            raise NotesError('Note changed elsewhere; your unsaved text is still in the editor.')
        return self.get(note_id)

    def deleted(self, note_id, revision, deleted):
        result = self.db.execute('UPDATE notes SET deleted=?,revision=revision+1,updated=? '
                                 'WHERE id=? AND revision=? AND deleted=?',
                                 (int(deleted), time.time_ns() // 1000000, note_id, revision, int(not deleted)))
        if result.rowcount != 1:
            current = self.get(note_id)
            if current['deleted'] == int(deleted) and current['revision'] == revision + 1:
                return current
            raise NotesError('Note changed elsewhere; reload before changing it.')
        return self.get(note_id)


def serve(store):
    print(json.dumps({'type': 'hello'}), flush=True)
    for line in sys.stdin:
        request = {}
        try:
            request = json.loads(line)
            action, data = request.get('action'), request.get('data') or {}
            if action == 'list': result = store.list()
            elif action == 'list-deleted': result = store.list_deleted()
            elif action == 'create': result = store.create(data['id'])
            elif action == 'save': result = store.save(data['id'], data['body'], data['revision'])
            elif action == 'save-copy': result = store.save_copy(data['id'], data['body'])
            elif action == 'delete': result = store.deleted(data['id'], data['revision'], True)
            elif action == 'restore': result = store.deleted(data['id'], data['revision'], False)
            else: raise NotesError('Unknown operation.')
            response = {'type': 'result', 'success': True, 'result': result}
        except (ValueError, KeyError, TypeError, NotesError, sqlite3.Error, OSError) as error:
            response = {'type': 'result', 'success': False, 'error': str(error)}
        response.update(id=request.get('id'), generation=request.get('generation'))
        print(json.dumps(response, ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--store', required=True)
    args = parser.parse_args()
    try:
        store = NotesStore(args.store)
    except (NotesError, sqlite3.Error, OSError) as error:
        print(json.dumps({'type': 'unavailable', 'error': str(error)}), flush=True)
        return 1
    try:
        serve(store)
    finally:
        store.close()


if __name__ == '__main__':
    sys.exit(main())
