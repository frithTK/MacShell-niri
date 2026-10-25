"""Versioned JSON preferences with one cooperating writer, CAS and backups."""
import contextlib
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import tempfile
import uuid

LIMIT = 262144


def decode(raw):
    def invalid_constant(value):
        raise ValueError('Non-finite JSON value')
    return json.loads(raw, parse_constant=invalid_constant)


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(name)


class PreferenceStore:
    # Optional owned fields roundtrip without injecting defaults into old files.
    optional_keys = ()

    def __init__(self, path):
        self.path = Path(path)

    def source_values(self, document):
        return document.get('values', document if document.get('version', 0) == 0 else {})

    def read(self):
        raw, document, corrupt = None, {}, False
        notice = ''
        try:
            with self.path.open('rb') as stream:
                raw = stream.read(LIMIT + 1)
            if len(raw) > LIMIT:
                raise ValueError('Preferences exceed size limit')
            document = decode(raw)
            if not isinstance(document, dict):
                raise ValueError('Expected object')
            version = document.get('version', 0)
            if type(version) is not int or version < 0:
                raise ValueError('Invalid version')
            # A later schema may use a different document shape. Its version
            # guard takes precedence over validation of our current layout.
            if version <= self.version:
                if 'values' in document and not isinstance(document['values'], dict):
                    raise ValueError('Invalid values')
                if version > 0 and 'values' not in document:
                    raise ValueError('Missing values')
                if 'revision' in document and (type(document['revision']) is not int or document['revision'] < 0):
                    raise ValueError('Invalid revision')
        except FileNotFoundError:
            pass
        except (OSError, ValueError, UnicodeError):
            corrupt = True
            notice = self.label + ' settings could not be read. Restore defaults to edit them; the original file will be kept.'
            document = {}
        version = document.get('version', 0)
        future = version > self.version
        source = self.source_values(document)
        values, errors = self.normalize(source)
        if future:
            notice = 'These ' + self.label + ' settings were saved by a newer MacShell. Update MacShell to edit them.'
        elif errors and not corrupt:
            notice = 'Some saved ' + self.label + ' values were invalid. Defaults are shown for those fields; Apply saves the corrected values.'
        if corrupt and (raw is None or len(raw) > LIMIT):
            notice = self.label + ' settings could not be read. Check file access and size, or restore a backup.'
        token = hashlib.sha256(raw).hexdigest() if raw is not None else 'missing'
        revision = document.get('revision', 0)
        if type(revision) is not int or revision < 0:
            revision = 0
        return dict(values=values, token=token, revision=revision,
                    readOnly=corrupt or future, canRecover=corrupt and raw is not None and len(raw) <= LIMIT,
                    notice=notice, migrationPending=raw is not None and version < self.version and not corrupt,
                    needsRepair=bool(errors), document=document, raw=raw)

    @staticmethod
    def public(state):
        return {key: value for key, value in state.items() if key not in ('document', 'raw')}

    def load(self):
        return self.public(self.read())

    def commit(self, candidate, expected, recover=False):
        # All service instances cooperate on this lock. CAS also catches manual
        # file edits, including ones which did not update the numeric revision.
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.with_name('.' + self.path.name + '.lock').open('a+b') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            state = self.read()
            if state['token'] != expected:
                return dict(success=False, conflict=True, error=self.label + ' settings changed elsewhere. Reload before applying.', state=self.public(state))
            if state['readOnly'] and not (recover and state['canRecover']):
                return dict(success=False, error=state['notice'], state=self.public(state))
            if recover and not state['canRecover']:
                return dict(success=False, error='There is no recoverable ' + self.label + ' file.', state=self.public(state))
            if not isinstance(candidate, dict):
                return dict(success=False, error='Invalid ' + self.label + ' settings.', state=self.public(state))
            values, errors = self.normalize(candidate, strict=True)
            if errors:
                return dict(success=False, error=next(iter(errors.values())), errors=errors, state=self.public(state))
            keys = tuple(self.defaults) + tuple(key for key in self.optional_keys if key in values or key in state['values'])
            if not recover and not state['migrationPending'] and not state['needsRepair'] and all(state['values'].get(key) == values.get(key) for key in keys):
                return dict(success=True, changed=False, state=self.public(state))
            document = copy.deepcopy(state['document'])
            stored = copy.deepcopy(document.get('values', document if state['migrationPending'] else {}))
            for key in keys:
                if key in values:
                    stored[key] = values[key]
                else:
                    stored.pop(key, None)
            document.update(version=self.version, revision=state['revision'] + 1, values=stored)
            data = (json.dumps(document, ensure_ascii=False, indent=2, allow_nan=False) + '\n').encode()
            if len(data) > LIMIT:
                return dict(success=False, error=self.label + ' settings are too large.', state=self.public(state))
            if state['raw'] is not None:
                suffix = '.recovery-' + uuid.uuid4().hex + '.json' if recover else '.before-v' + str(self.version) + '-' + uuid.uuid4().hex + '.json' if state['migrationPending'] else '.previous.json'
                atomic_write(self.path.with_name(self.path.stem + suffix), state['raw'])
            atomic_write(self.path, data)
            return dict(success=True, changed=True, state=self.load())
