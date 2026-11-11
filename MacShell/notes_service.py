#!/usr/bin/env python3
"""Transactional, local Notes storage and JSON-lines service."""
import argparse
from html import escape
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import shutil
import sqlite3
import sys
import time
import uuid

MAX_BODY = 1024 * 1024
MAX_ATTACH_BYTES = 20 * 1024 * 1024
MAX_ATTACH_COUNT = 20
MAX_ATTACH_NAME = 255
SCHEMA = 2
ALLOWED_TAGS = frozenset(('b', 'i', 'u', 'ul', 'ol', 'li', 'br', 'p', 'span'))
SKIP_TAGS = frozenset(('script', 'style', 'iframe'))
VOID_TAGS = frozenset(('br',))
MARKUP_TAGS = frozenset(('b', 'i', 'u', 'ul', 'ol', 'li', 'span'))
TAG_MAP = {'strong': 'b', 'em': 'i'}
MIME_BY_EXT = {
    '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif',
    '.webp': 'image/webp', '.svg': 'image/svg+xml', '.pdf': 'application/pdf',
    '.txt': 'text/plain', '.md': 'text/markdown',
}


class NotesError(Exception):
    pass


class _Sanitizer(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.html = []
        self.excerpt = []
        self.stack = []
        self.skip = 0
        self.markup = False

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if TAG_MAP.get(tag, tag) not in VOID_TAGS:
            self.handle_endtag(tag)

    def handle_starttag(self, tag, attrs):
        tag = TAG_MAP.get(tag, tag)
        if tag in SKIP_TAGS:
            self.skip += 1
            return
        if self.skip or tag not in ALLOWED_TAGS:
            return
        if tag in MARKUP_TAGS:
            self.markup = True
        if tag == 'br':
            self.html.append('<br>')
            self.excerpt.append('\n')
            return
        if tag in ('p', 'li') and self.excerpt and not self.excerpt[-1].endswith('\n'):
            self.excerpt.append('\n')
        self.html.append('<' + tag + '>')
        self.stack.append(tag)

    def handle_endtag(self, tag):
        tag = TAG_MAP.get(tag, tag)
        if tag in SKIP_TAGS:
            if self.skip:
                self.skip -= 1
            return
        if self.skip or tag in VOID_TAGS:
            return
        if tag in self.stack:
            while self.stack:
                last = self.stack.pop()
                self.html.append('</' + last + '>')
                if last == tag:
                    break

    def handle_data(self, data):
        if self.skip or not data:
            return
        self.html.append(escape(data, quote=False))
        self.excerpt.append(data)

    def close_open(self):
        while self.stack:
            self.html.append('</' + self.stack.pop() + '>')


def sanitize_html(source):
    parser = _Sanitizer()
    parser.feed(source or '')
    parser.close()
    parser.close_open()
    html = ''.join(parser.html)
    excerpt = ''.join(parser.excerpt)
    while excerpt.startswith('\n'):
        excerpt = excerpt[1:]
    return html, excerpt, parser.markup


def normalize_note(body, fmt):
    if not isinstance(body, str):
        raise NotesError('Note is too large.')
    if fmt not in ('plain', 'html'):
        raise NotesError('Invalid note format.')
    if fmt == 'plain':
        if len(body.encode('utf-8')) > MAX_BODY:
            raise NotesError('Note is too large.')
        return body, body, 'plain'
    html, excerpt, markup = sanitize_html(body)
    if not markup:
        if len(excerpt.encode('utf-8')) > MAX_BODY:
            raise NotesError('Note is too large.')
        return excerpt, excerpt, 'plain'
    if len(html.encode('utf-8')) > MAX_BODY:
        raise NotesError('Note is too large.')
    return html, excerpt, 'html'


def attachment_name(value, fallback=''):
    name = os.path.basename(str(value or fallback or ''))
    name = name.replace('\0', '')
    if not name or name in ('.', '..') or len(name) > MAX_ATTACH_NAME or '/' in name:
        raise NotesError('Invalid attachment name.')
    return name


def mime_for(name):
    ext = Path(name).suffix.lower()
    return MIME_BY_EXT.get(ext, 'application/octet-stream')


class NotesStore:
    def __init__(self, path):
        path = Path(path)
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.path = path
        self.attachments_root = path.parent / 'attachments'
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
                    updated INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
                    format TEXT NOT NULL DEFAULT 'plain', excerpt TEXT NOT NULL DEFAULT ''
                );
                PRAGMA user_version=2;
                COMMIT;''')
        elif version == 1:
            self.db.executescript('''BEGIN IMMEDIATE;
                ALTER TABLE notes ADD COLUMN format TEXT NOT NULL DEFAULT 'plain';
                ALTER TABLE notes ADD COLUMN excerpt TEXT NOT NULL DEFAULT '';
                UPDATE notes SET excerpt=body;
                PRAGMA user_version=2;
                COMMIT;''')
        self.db.execute('CREATE TABLE IF NOT EXISTS sticky_session (id INTEGER PRIMARY KEY CHECK (id=1), windows TEXT NOT NULL)')
        self.db.execute('''CREATE TABLE IF NOT EXISTS attachments (
            id TEXT PRIMARY KEY, note_id TEXT NOT NULL, name TEXT NOT NULL,
            mime TEXT NOT NULL, size INTEGER NOT NULL, revision INTEGER NOT NULL)''')

    def close(self):
        self.db.close()

    def _now(self):
        return time.time_ns() // 1000000

    def _note_row(self, row):
        note = dict(row)
        note['attachments'] = self.list_attachments(note['id'])
        return note

    def list(self):
        return [dict(row) for row in self.db.execute(
            'SELECT id, body, revision, updated, format, excerpt FROM notes WHERE deleted=0 ORDER BY updated DESC, id')]

    def list_deleted(self):
        return [dict(row) for row in self.db.execute(
            'SELECT id, body, revision, updated, format, excerpt FROM notes WHERE deleted=1 ORDER BY updated DESC, id')]

    def list_stickies(self):
        row = self.db.execute('SELECT windows FROM sticky_session WHERE id=1').fetchone()
        if row is None:
            return []
        try:
            return self.validate_stickies(json.loads(row['windows']))
        except (ValueError, TypeError, NotesError):
            raise NotesError('Saved sticky window layout is invalid.')

    @staticmethod
    def validate_stickies(windows):
        if not isinstance(windows, list) or len(windows) > 100:
            raise NotesError('Invalid sticky window layout.')
        seen = set()
        for window in windows:
            if not isinstance(window, dict):
                raise NotesError('Invalid sticky window layout.')
            note_id = window.get('id')
            try:
                valid_id = isinstance(note_id, str) and str(uuid.UUID(note_id)) == note_id
            except (ValueError, AttributeError):
                valid_id = False
            if not valid_id or note_id in seen:
                raise NotesError('Invalid sticky note ID.')
            seen.add(note_id)
            for key in ('width', 'height', 'x', 'y', 'workspace'):
                value = window.get(key)
                if value is not None and (type(value) is not int or abs(value) > 100000):
                    raise NotesError('Invalid sticky window geometry.')
            if not isinstance(window.get('output', ''), str) or len(window.get('output', '')) > 256:
                raise NotesError('Invalid sticky window output.')
            if 'color' in window and window['color'] not in ('yellow', 'pink', 'blue', 'green', 'orange', 'purple'):
                raise NotesError('Invalid sticky window color.')
        return windows

    def save_stickies(self, windows):
        windows = self.validate_stickies(windows)
        self.db.execute('INSERT INTO sticky_session(id, windows) VALUES(1, ?) '
                        'ON CONFLICT(id) DO UPDATE SET windows=excluded.windows',
                        (json.dumps(windows, ensure_ascii=False, separators=(',', ':')),))
        return windows

    def create(self, note_id):
        if not isinstance(note_id, str) or str(uuid.UUID(note_id)) != note_id:
            raise NotesError('Invalid note ID.')
        with self.db:
            self.db.execute('INSERT OR IGNORE INTO notes(id,body,revision,updated,format,excerpt) VALUES(?,?,0,?,?,?)',
                            (note_id, '', self._now(), 'plain', ''))
        return self.get(note_id)

    def get(self, note_id):
        row = self.db.execute('SELECT id,body,revision,updated,deleted,format,excerpt FROM notes WHERE id=?', (note_id,)).fetchone()
        if row is None:
            raise NotesError('Note no longer exists.')
        return self._note_row(row)

    def save_copy(self, note_id, body, fmt='plain'):
        if not isinstance(note_id, str) or str(uuid.UUID(note_id)) != note_id:
            raise NotesError('Invalid note ID.')
        text, excerpt, fmt = normalize_note(body, fmt or 'plain')
        self.db.execute('INSERT OR IGNORE INTO notes(id,body,revision,updated,format,excerpt) VALUES(?,?,0,?,?,?)',
                        (note_id, text, self._now(), fmt, excerpt))
        note = self.get(note_id)
        if note['deleted'] or note['body'] != text or note['format'] != fmt:
            raise NotesError('Copy ID is already in use.')
        return note

    def save(self, note_id, body, revision, fmt=None):
        if type(revision) is not int or revision < 0:
            raise NotesError('Invalid revision.')
        current = self.db.execute('SELECT format FROM notes WHERE id=?', (note_id,)).fetchone()
        if current is None:
            raise NotesError('Note no longer exists.')
        if fmt is None:
            fmt = current['format']
        text, excerpt, fmt = normalize_note(body, fmt)
        now = self._now()
        result = self.db.execute('UPDATE notes SET body=?,excerpt=?,format=?,revision=revision+1,updated=? '
                                 'WHERE id=? AND revision=? AND deleted=0',
                                 (text, excerpt, fmt, now, note_id, revision))
        if result.rowcount != 1:
            stored = self.get(note_id)
            if not stored['deleted'] and stored['body'] == text:
                return stored
            raise NotesError('Note changed elsewhere; your unsaved text is still in the editor.')
        return self.get(note_id)

    def deleted(self, note_id, revision, deleted):
        result = self.db.execute('UPDATE notes SET deleted=?,revision=revision+1,updated=? '
                                 'WHERE id=? AND revision=? AND deleted=?',
                                 (int(deleted), self._now(), note_id, revision, int(not deleted)))
        if result.rowcount != 1:
            current = self.get(note_id)
            if current['deleted'] == int(deleted) and current['revision'] == revision + 1:
                return current
            raise NotesError('Note changed elsewhere; reload before changing it.')
        return self.get(note_id)

    def list_attachments(self, note_id):
        return [dict(row) for row in self.db.execute(
            'SELECT id, note_id, name, mime, size, revision FROM attachments WHERE note_id=? ORDER BY name, id',
            (note_id,))]

    def attachment_path(self, note_id, attachment_id):
        return self.attachments_root / note_id / attachment_id

    def attach(self, note_id, revision, attachment_id, source, name=None):
        if not isinstance(note_id, str) or str(uuid.UUID(note_id)) != note_id:
            raise NotesError('Invalid note ID.')
        if not isinstance(attachment_id, str) or str(uuid.UUID(attachment_id)) != attachment_id:
            raise NotesError('Invalid attachment ID.')
        if type(revision) is not int or revision < 0:
            raise NotesError('Invalid revision.')
        source = Path(os.path.realpath(source))
        if not source.is_file():
            raise NotesError('Attachment file is missing.')
        size = source.stat().st_size
        if size > MAX_ATTACH_BYTES:
            raise NotesError('Attachment is too large.')
        stored_name = attachment_name(name, source.name)
        dest_dir = self.attachments_root / note_id
        dest_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.attachments_root, 0o700)
        dest = dest_dir / attachment_id
        tmp = dest_dir / (attachment_id + '.part')
        shutil.copyfile(source, tmp)
        os.chmod(tmp, 0o600)
        try:
            with self.db:
                note = self.db.execute('SELECT revision, deleted FROM notes WHERE id=?', (note_id,)).fetchone()
                if note is None:
                    raise NotesError('Note no longer exists.')
                if note['deleted'] or note['revision'] != revision:
                    raise NotesError('Note changed elsewhere; reload before changing it.')
                count = self.db.execute('SELECT COUNT(*) FROM attachments WHERE note_id=?', (note_id,)).fetchone()[0]
                if count >= MAX_ATTACH_COUNT:
                    raise NotesError('Too many attachments.')
                existing = self.db.execute('SELECT id FROM attachments WHERE id=?', (attachment_id,)).fetchone()
                if existing:
                    raise NotesError('Attachment ID is already in use.')
                self.db.execute('INSERT INTO attachments(id,note_id,name,mime,size,revision) VALUES(?,?,?,?,?,?)',
                                (attachment_id, note_id, stored_name, mime_for(stored_name), size, revision + 1))
                updated = self.db.execute('UPDATE notes SET revision=revision+1,updated=? WHERE id=? AND revision=? AND deleted=0',
                                          (self._now(), note_id, revision))
                if updated.rowcount != 1:
                    raise NotesError('Note changed elsewhere; reload before changing it.')
            os.replace(tmp, dest)
        except Exception:
            if tmp.exists():
                tmp.unlink()
            raise
        return self.get(note_id)

    def detach(self, note_id, revision, attachment_id):
        if type(revision) is not int or revision < 0:
            raise NotesError('Invalid revision.')
        path = self.attachment_path(note_id, attachment_id)
        with self.db:
            note = self.db.execute('SELECT revision, deleted FROM notes WHERE id=?', (note_id,)).fetchone()
            if note is None:
                raise NotesError('Note no longer exists.')
            if note['deleted'] or note['revision'] != revision:
                raise NotesError('Note changed elsewhere; reload before changing it.')
            row = self.db.execute('SELECT id FROM attachments WHERE id=? AND note_id=?', (attachment_id, note_id)).fetchone()
            if row is None:
                raise NotesError('Attachment no longer exists.')
            self.db.execute('DELETE FROM attachments WHERE id=? AND note_id=?', (attachment_id, note_id))
            updated = self.db.execute('UPDATE notes SET revision=revision+1,updated=? WHERE id=? AND revision=? AND deleted=0',
                                      (self._now(), note_id, revision))
            if updated.rowcount != 1:
                raise NotesError('Note changed elsewhere; reload before changing it.')
        if path.exists():
            path.unlink()
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
            elif action == 'list-stickies': result = store.list_stickies()
            elif action == 'save-stickies': result = store.save_stickies(data['windows'])
            elif action == 'create': result = store.create(data['id'])
            elif action == 'save': result = store.save(data['id'], data['body'], data['revision'], data.get('format'))
            elif action == 'save-copy': result = store.save_copy(data['id'], data['body'], data.get('format') or 'plain')
            elif action == 'delete': result = store.deleted(data['id'], data['revision'], True)
            elif action == 'restore': result = store.deleted(data['id'], data['revision'], False)
            elif action == 'list-attachments': result = store.list_attachments(data['id'])
            elif action == 'attach': result = store.attach(data['id'], data['revision'], data['attachmentId'], data['path'], data.get('name'))
            elif action == 'detach': result = store.detach(data['id'], data['revision'], data['attachmentId'])
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
