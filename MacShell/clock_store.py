"""Exclusive, versioned storage for the Clock service."""

import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import uuid

from preference_store import atomic_write, decode


LIMIT = 1024 * 1024
VERSION = 2


class ClockStoreError(Exception):
    pass


class ClockStoreBusy(ClockStoreError):
    pass


class ClockStoreConflict(ClockStoreError):
    pass


class ClockStore:
    """Hold the sidecar lock for the entire lifetime of the Clock owner.

    Existing ClockApp does not cooperate with this lock. This store must only
    be activated once ClockApp's independent writer has been removed.
    """

    def __init__(self, path):
        self.path = Path(path)
        self._lock = None

    def __enter__(self):
        if self._lock is not None:
            raise ClockStoreError('Clock store is already open')
        self.path.parent.mkdir(parents=True, exist_ok=True)
        lock_path = self.path.with_name('clock.lock')
        lock = lock_path.open('a+b')
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            lock.close()
            raise ClockStoreBusy('Another Clock service owns the store') from exc
        except BaseException:
            lock.close()
            raise
        self._lock = lock
        return self

    def __exit__(self, exc_type, exc, tb):
        self._lock.close()
        self._lock = None

    def _require_lock(self):
        if self._lock is None:
            raise ClockStoreError('Clock store is not open')

    def read(self):
        self._require_lock()
        try:
            with self.path.open('rb') as stream:
                raw = stream.read(LIMIT + 1)
        except FileNotFoundError:
            return {}, 'missing'
        except OSError as exc:
            raise ClockStoreError('Cannot read Clock data') from exc
        if len(raw) > LIMIT:
            raise ClockStoreError('Clock data exceeds the size limit')
        try:
            document = decode(raw)
            if not isinstance(document, dict):
                raise ValueError('Expected an object')
            version = document.get('version', 0)
            if type(version) is not int or version not in (0, VERSION):
                raise ValueError('Unsupported version')
            if version == VERSION:
                if type(document.get('revision')) is not int or document['revision'] < 0:
                    raise ValueError('Invalid revision')
                timing = document.get('timing')
                if not isinstance(timing, dict) or type(timing.get('version')) is not int or timing['version'] != 1:
                    raise ValueError('Unsupported timing version')
        except (ValueError, UnicodeError) as exc:
            raise ClockStoreError('Invalid or unsupported Clock data') from exc
        return document, hashlib.sha256(raw).hexdigest()

    def commit(self, patch, expected_token, expected_revision):
        """Merge top-level changes and atomically write a new revision.

        A legacy document requires the caller to supply the migrated timing
        data. An exact backup is made before its first replacement.
        """
        self._require_lock()
        if not isinstance(patch, dict) or 'version' in patch or 'revision' in patch:
            raise ClockStoreError('Invalid Clock update')
        document, token = self.read()
        revision = document.get('revision', 0) if document.get('version', 0) == VERSION else 0
        if token != expected_token or type(expected_revision) is not int or expected_revision != revision:
            raise ClockStoreConflict('Clock data changed')
        candidate = copy.deepcopy(document)
        candidate.update(copy.deepcopy(patch))
        candidate['version'] = VERSION
        candidate['revision'] = revision + 1
        timing = candidate.get('timing')
        if not isinstance(timing, dict) or type(timing.get('version')) is not int or timing['version'] != 1:
            raise ClockStoreError('Missing or unsupported timing data')
        try:
            data = (json.dumps(candidate, ensure_ascii=False, indent=2, allow_nan=False) + '\n').encode('utf-8')
        except (TypeError, ValueError, UnicodeError) as exc:
            raise ClockStoreError('Invalid Clock update') from exc
        if len(data) > LIMIT:
            raise ClockStoreError('Clock data exceeds the size limit')
        if token != 'missing' and document.get('version', 0) == 0:
            # Verify that the bytes saved in the backup are exactly those read.
            raw = self.path.read_bytes()
            if hashlib.sha256(raw).hexdigest() != token:
                raise ClockStoreConflict('Clock data changed during migration')
            backup = self.path.with_name('clock.before-v2-' + uuid.uuid4().hex + '.json')
            atomic_write(backup, raw)
        atomic_write(self.path, data)
        return self.read()
