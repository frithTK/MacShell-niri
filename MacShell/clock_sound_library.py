"""Local Clock sound catalog and atomic, bounded audio imports.

The Clock owner is responsible for exposing this library and tracking references.
Each imported asset and its metadata are published as one directory.
"""
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import uuid
from line_service import protect_child
from preference_store import atomic_write

MAX_BYTES = 50 * 1024 * 1024
MAX_SECONDS = 600
PROBE_TIMEOUT = 10
DECODE_TIMEOUT = 30
EXTENSIONS = {'.wav', '.flac', '.mp3', '.ogg', '.m4a', '.aac'}
DEMUXERS = {'.wav': 'wav', '.flac': 'flac', '.mp3': 'mp3', '.ogg': 'ogg', '.m4a': 'mov', '.aac': 'aac'}


def valid_sound_id(identifier):
    return (identifier in ('', 'silence') or isinstance(identifier, str) and
            (re.fullmatch(r'builtin-(chime|melody|gentle|urgent)-(0[1-9]|10)', identifier) is not None
             or re.fullmatch(r'user-[0-9a-f]{64}', identifier) is not None))


class SoundLibraryError(Exception):
    pass


def sound_name(value):
    if not isinstance(value, str) or not value.strip() or len(value) > 200 or any(ord(c) < 32 for c in value):
        raise SoundLibraryError('Invalid sound name')
    return value.strip()


class SoundLibrary:
    def __init__(self, directory, protect_decoders=False):
        self.directory = Path(directory)
        self.protect_decoders = protect_decoders

    def _decode(self, path):
        # A private copy is probed and decoded; no playlists or remote protocols.
        common = ['-v', 'error', '-protocol_whitelist', 'file,pipe']
        try:
            probe = subprocess.run(['ffprobe', *common, '-f', DEMUXERS[path.suffix], '-show_entries', 'format=duration:stream=codec_type',
                                    '-of', 'json', str(path)], stdin=subprocess.DEVNULL,
                                   capture_output=True, timeout=PROBE_TIMEOUT, check=True,
                                   preexec_fn=protect_child if self.protect_decoders else None)
            data = json.loads(probe.stdout)
            duration = float(data['format']['duration'])
            if not math.isfinite(duration) or duration <= 0 or duration > MAX_SECONDS:
                raise SoundLibraryError('Audio duration is outside the allowed range')
            if not any(stream.get('codec_type') == 'audio' for stream in data.get('streams', [])):
                raise SoundLibraryError('File does not contain audio')
            subprocess.run(['ffmpeg', '-nostdin', '-xerror', *common, '-f', DEMUXERS[path.suffix], '-i', str(path),
                            '-map', '0:a:0', '-f', 'null', '-'], stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=DECODE_TIMEOUT, check=True,
                           preexec_fn=protect_child if self.protect_decoders else None)
        except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as exc:
            raise SoundLibraryError('Audio cannot be decoded') from exc
        return round(duration * 1000)

    def import_file(self, source, name=None):
        source = Path(source)
        extension = source.suffix.lower()
        if extension not in EXTENSIONS:
            raise SoundLibraryError('Unsupported audio format')
        title = source.stem if name is None else name
        title = sound_name(title)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            descriptor = os.open(source, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
            with os.fdopen(descriptor, 'rb') as incoming:
                info = os.fstat(incoming.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size <= 0 or info.st_size > MAX_BYTES:
                    raise SoundLibraryError('Audio file is empty, too large, or not a regular file')
                with tempfile.TemporaryDirectory(prefix='.import-', dir=self.directory) as staging_name:
                    staging = Path(staging_name)
                    target = staging / ('audio' + extension)
                    digest = hashlib.sha256()
                    size = 0
                    with target.open('xb') as outgoing:
                        while chunk := incoming.read(1024 * 1024):
                            size += len(chunk)
                            if size > MAX_BYTES:
                                raise SoundLibraryError('Audio file is too large')
                            digest.update(chunk)
                            outgoing.write(chunk)
                        outgoing.flush()
                        os.fsync(outgoing.fileno())
                    if not size:
                        raise SoundLibraryError('Audio file is empty')
                    identifier = 'user-' + digest.hexdigest()
                    duration = self._decode(target)
                    metadata = {'version': 1, 'id': identifier, 'name': title,
                                'durationMs': duration, 'file': target.name}
                    with (staging / 'metadata.json').open('x', encoding='utf-8') as output:
                        json.dump(metadata, output, ensure_ascii=False, allow_nan=False)
                        output.write('\n')
                        output.flush()
                        os.fsync(output.fileno())
                    directory_fd = os.open(staging, os.O_RDONLY | os.O_DIRECTORY)
                    try:
                        os.fsync(directory_fd)
                    finally:
                        os.close(directory_fd)
                    with (self.directory / '.lock').open('a+b') as lock:
                        fcntl.flock(lock, fcntl.LOCK_EX)
                        destination = self.directory / identifier
                        if destination.exists():
                            return self._read(destination), False
                        os.rename(staging, destination)
                        directory_fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
                        try:
                            os.fsync(directory_fd)
                        finally:
                            os.close(directory_fd)
                        return metadata, True
        except SoundLibraryError:
            raise
        except OSError as exc:
            raise SoundLibraryError('Cannot import audio file') from exc

    def _read(self, directory):
        try:
            with (directory / 'metadata.json').open(encoding='utf-8') as source:
                data = json.load(source)
            filename = data['file']
            if (data.get('version') != 1 or data.get('id') != directory.name or
                    not isinstance(data.get('name'), str) or not data['name'] or
                    type(data.get('durationMs')) is not int or not 0 < data['durationMs'] <= MAX_SECONDS * 1000 or
                    not isinstance(filename, str) or filename not in {'audio' + ext for ext in EXTENSIONS} or
                    not (directory / filename).is_file()):
                raise ValueError('Invalid metadata')
            return data
        except (OSError, ValueError, KeyError, TypeError) as exc:
            raise SoundLibraryError('Invalid imported sound') from exc

    def list_imported(self):
        if not self.directory.exists():
            return []
        return [self._read(path) for path in sorted(self.directory.iterdir())
                if path.is_dir() and path.name.startswith('user-')]

    def _favorite_document(self):
        try:
            with (self.directory / 'favorites.json').open('rb') as source:
                raw = source.read(1024 * 1024 + 1)
            if len(raw) > 1024 * 1024:
                raise ValueError('Favorites too large')
            document = json.loads(raw)
            if (not isinstance(document, dict) or type(document.get('version')) is not int or
                    document['version'] != 1 or not isinstance(document.get('favorites'), list) or
                    any(not isinstance(item, str) or item in ('', 'silence') or not valid_sound_id(item)
                        for item in document['favorites']) or
                    len(set(document['favorites'])) != len(document['favorites']) or
                    ('showBuiltins' in document and type(document['showBuiltins']) is not bool)):
                raise ValueError('Invalid favorites')
            return document
        except FileNotFoundError:
            return {'version': 1, 'favorites': []}
        except (OSError, ValueError, TypeError, UnicodeError) as exc:
            raise SoundLibraryError('Invalid sound favorites') from exc

    def catalog(self):
        return self.catalog_state()['sounds']

    def catalog_state(self):
        document = self._favorite_document()
        favorites = set(document['favorites'])
        show_builtins = document.get('showBuiltins', False)
        imported = self.list_imported()
        imported_ids = {item['id'] for item in imported}
        packaged = self.list_apple()
        apple_ids = {item['id'] for item in packaged}
        apple = [dict(item, imported=False) for item in packaged if item['id'] not in imported_ids]
        imported = [dict(item, imported=True, category='apple') if item['id'] in apple_ids else
                    dict(item, imported=True) for item in imported]
        sounds = apple + (self.list_builtin() if show_builtins else []) + imported
        return {'showBuiltins': show_builtins,
                'sounds': [dict(item, favorite=item['id'] in favorites) for item in sounds]}

    def set_builtins_visible(self, visible):
        if type(visible) is not bool:
            raise SoundLibraryError('Invalid sound visibility')
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            with (self.directory / '.lock').open('a+b') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                document = self._favorite_document()
                if document.get('showBuiltins', False) == visible:
                    return
                document['showBuiltins'] = visible
                atomic_write(self.directory / 'favorites.json',
                             (json.dumps(document, ensure_ascii=False, allow_nan=False) + '\n').encode('utf-8'))
        except SoundLibraryError:
            raise
        except OSError as exc:
            raise SoundLibraryError('Cannot save sound visibility') from exc

    def set_favorite(self, identifier, favorite):
        if type(favorite) is not bool:
            raise SoundLibraryError('Invalid favorite state')
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            with (self.directory / '.lock').open('a+b') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                self.resolve(identifier)
                document = self._favorite_document()
                current = set(document['favorites'])
                if (identifier in current) == favorite:
                    return
                if favorite:
                    current.add(identifier)
                else:
                    current.discard(identifier)
                document['favorites'] = sorted(current)
                atomic_write(self.directory / 'favorites.json',
                             (json.dumps(document, ensure_ascii=False, allow_nan=False) + '\n').encode('utf-8'))
        except SoundLibraryError:
            raise
        except (OSError, ValueError, TypeError) as exc:
            raise SoundLibraryError('Cannot save sound favorites') from exc

    def delete_imported(self, identifier):
        if not isinstance(identifier, str) or not re.fullmatch(r'user-[0-9a-f]{64}', identifier):
            raise SoundLibraryError('Only imported sounds can be deleted')
        try:
            with (self.directory / '.lock').open('a+b') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                self.resolve(identifier)
                destination = self.directory / identifier
                tombstone = self.directory / ('.deleted-' + uuid.uuid4().hex)
                os.rename(destination, tombstone)
                directory_fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
            try:
                shutil.rmtree(tombstone)
                return True
            except OSError:
                # The item is already unpublished; report that disk cleanup remains.
                return False
        except SoundLibraryError:
            raise
        except OSError as exc:
            raise SoundLibraryError('Cannot delete imported sound') from exc

    def rename_imported(self, identifier, name):
        if not isinstance(identifier, str) or not re.fullmatch(r'user-[0-9a-f]{64}', identifier):
            raise SoundLibraryError('Only imported sounds can be renamed')
        name = sound_name(name)
        try:
            with (self.directory / '.lock').open('a+b') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                directory = self.directory / identifier
                metadata = self._read(directory)
                if metadata['name'] == name:
                    return
                metadata['name'] = name
                atomic_write(directory / 'metadata.json',
                             (json.dumps(metadata, ensure_ascii=False, allow_nan=False) + '\n').encode('utf-8'))
        except SoundLibraryError:
            raise
        except (OSError, ValueError, TypeError) as exc:
            raise SoundLibraryError('Cannot rename imported sound') from exc

    def resolve(self, identifier):
        if not isinstance(identifier, str):
            raise SoundLibraryError('Invalid sound ID')
        if identifier.startswith('builtin-'):
            for sound in self.list_builtin():
                if sound['id'] == identifier:
                    return Path(__file__).with_name('sounds') / sound['file']
        elif re.fullmatch(r'user-[0-9a-f]{64}', identifier):
            directory = self.directory / identifier
            if directory.exists():
                sound = self._read(directory)
                return directory / sound['file']
            for sound in self.list_apple():
                if sound['id'] == identifier:
                    return Path(__file__).with_name('sounds') / 'apple' / sound['file']
        raise SoundLibraryError('Sound is unavailable')

    @staticmethod
    def list_apple():
        directory = Path(__file__).with_name('sounds') / 'apple'
        try:
            with (directory / 'catalog.json').open(encoding='utf-8') as source:
                catalog = json.load(source)
            if not isinstance(catalog, dict) or catalog.get('version') != 1 or not isinstance(catalog.get('sounds'), list):
                raise ValueError('Invalid Apple sound catalog')
            ids = set()
            for sound in catalog['sounds']:
                identifier, filename = sound['id'], sound['file']
                if (not isinstance(identifier, str) or not re.fullmatch(r'user-[0-9a-f]{64}', identifier) or
                        identifier in ids or not isinstance(filename, str) or
                        not re.fullmatch(r'[A-Za-z0-9 ._-]+\.m4a', filename) or
                        not isinstance(sound.get('name'), str) or not sound['name'] or
                        sound.get('category') != 'apple' or type(sound.get('durationMs')) is not int or
                        not 0 < sound['durationMs'] <= MAX_SECONDS * 1000 or not (directory / filename).is_file()):
                    raise ValueError('Invalid Apple sound catalog entry')
                ids.add(identifier)
            return catalog['sounds']
        except (OSError, ValueError, KeyError, TypeError) as exc:
            raise SoundLibraryError('Invalid Apple sound catalog') from exc

    @staticmethod
    def list_builtin():
        directory = Path(__file__).with_name('sounds')
        try:
            with (directory / 'catalog.json').open(encoding='utf-8') as source:
                catalog = json.load(source)
            if not isinstance(catalog, dict) or catalog.get('version') != 1 or not isinstance(catalog.get('sounds'), list):
                raise ValueError('Invalid catalog')
            ids = set()
            for sound in catalog['sounds']:
                identifier, filename = sound['id'], sound['file']
                if (not isinstance(identifier, str) or not re.fullmatch(r'builtin-[a-z]+-[0-9]{2}', identifier) or
                        identifier in ids or filename != identifier.removeprefix('builtin-') + '.wav' or
                        not isinstance(sound.get('name'), str) or not sound['name'] or
                        sound.get('category') not in ('chime', 'melody', 'gentle', 'urgent') or
                        type(sound.get('durationMs')) is not int or sound['durationMs'] <= 0 or
                        not (directory / filename).is_file()):
                    raise ValueError('Invalid built-in sound')
                ids.add(identifier)
            return catalog['sounds']
        except (OSError, ValueError, KeyError, TypeError) as exc:
            raise SoundLibraryError('Invalid built-in sound catalog') from exc
