#!/usr/bin/env python3
"""JSON-lines timer service. The desktop integration owns activation."""

import argparse
import copy
import json
from pathlib import Path
import sys
import uuid

import clock_alarms
import clock_snooze
import clock_stopwatch
from clock_audio import ClockAudio, ClockPreview
from clock_sound_library import SoundLibrary, SoundLibraryError
from clock_sound_options import validate_presets
from clock_commands import ClockCommandError, WINDOW_MS, execute
from clock_source import boot_id, boot_time_ms, system_zone, wall_time_ms
from clock_store import ClockStore, ClockStoreError
from clock_timer import (TimerError, advance, checkpoint, legacy_projection, legacy_ringing,
                         migrate_legacy, validate_timing)
from line_service import LineService


CHECKPOINT_MS = 30000
WALL_CHANGE_MS = 1000
DEFAULT_CITIES = [{'name': 'Cupertino', 'tz': 'America/Los_Angeles'},
                  {'name': 'New York', 'tz': 'America/New_York'},
                  {'name': 'London', 'tz': 'Europe/London'},
                  {'name': 'Tokyo', 'tz': 'Asia/Tokyo'}]


class ClockService(LineService):
    def __init__(self, store, sound_dir=None):
        super().__init__()
        self.store = store
        self.boot_id = boot_id()
        self.document = None
        self.token = None
        self.wall_offset = None
        self.audio = ClockAudio(sound_dir) if sound_dir is not None else None
        self.preview = ClockPreview() if sound_dir is not None else None
        self.sound_library = SoundLibrary(Path(sound_dir) / 'library') if sound_dir is not None else None
        self._open_document()

    def _open_document(self):
        boot_now, wall_now = boot_time_ms(), wall_time_ms()
        document, token = self.store.read()
        validate_presets(document.get('timerPresets', {}))
        alarms = document.get('alarms', [])
        if not isinstance(alarms, list):
            raise ValueError('Invalid alarm state')
        if alarms:
            clock_alarms.evaluate(alarms, {}, wall_now, wall_now, system_zone())
        if token == 'missing':
            timer = {'state': 'idle', 'total': 300000, 'left': 300000, 'label': ''}
            timing = migrate_legacy(timer, self.boot_id, boot_now, wall_now, str(uuid.uuid4()))
            timing['stopwatch'] = clock_stopwatch.migrate_legacy({'running': False, 'startAt': 0, 'acc': 0, 'laps': []},
                                                                 boot_now, wall_now, str(uuid.uuid4()))
            timing['legacySnoozesRecovery'] = []
            document = {'version': 2, 'revision': 0, 'timing': timing,
                        'timer': legacy_projection(timing, boot_now, wall_now),
                        'sw': clock_stopwatch.legacy_projection(timing['stopwatch'], boot_now, wall_now),
                        'ringing': None}
        elif document.get('version', 0) == 0:
            recovered_snoozes = clock_snooze.migrate_legacy(document.get('snoozes', []), wall_now)
            timer = document.get('timer', {'state': 'idle', 'total': 300000, 'left': 300000, 'label': ''})
            timing = migrate_legacy(timer, self.boot_id, boot_now, wall_now, str(uuid.uuid4()))
            sw = document.get('sw', {'running': False, 'startAt': 0, 'acc': 0, 'laps': []})
            timing['stopwatch'] = clock_stopwatch.migrate_legacy(sw, boot_now, wall_now, str(uuid.uuid4()))
            ringing = document.get('ringing')
            if ringing is not None:
                if (not isinstance(ringing, dict) or ringing.get('kind') not in ('timer', 'alarm')
                        or not isinstance(ringing.get('label', ''), str)
                        or not isinstance(ringing.get('time', ''), str)
                        or ('defaultLabel' in ringing and type(ringing['defaultLabel']) is not bool)):
                    raise ValueError('Invalid legacy ringing event')
                timing['completion'] = {'eventId': str(uuid.uuid4()), 'sessionId': str(uuid.uuid4()),
                                        'kind': ringing['kind'], 'label': ringing.get('label', ''),
                                        'time': ringing.get('time', ''),
                                        'defaultLabel': ringing.get('defaultLabel', not ringing.get('label')),
                                        'soundClaimed': True}
            timing['alarmCursorWallMs'] = max(0, wall_now - wall_now % 60000 - 1)
            timing['alarmCursorBootId'] = self.boot_id
            timing['handledAlarmDates'] = {}
            timing['legacySnoozesRecovery'] = recovered_snoozes
            document, token = self.store.commit({'timing': timing, 'timer': legacy_projection(timing, boot_now, wall_now),
                                                  'ringing': legacy_ringing(timing),
                                                  'snoozes': [],
                                                  'sw': clock_stopwatch.legacy_projection(timing['stopwatch'], boot_now, wall_now)}, token, 0)
        validate_timing(document['timing'])
        if 'stopwatch' not in document['timing']:
            timing = copy.deepcopy(document['timing'])
            sw = copy.deepcopy(document.get('sw', {'running': False, 'startAt': 0, 'acc': 0, 'laps': []}))
            boot_changed = timing['bootId'] != self.boot_id
            was_running = sw.get('running') is True
            if boot_changed and was_running:
                sw['running'] = False
            timing['stopwatch'] = clock_stopwatch.migrate_legacy(sw, boot_now, wall_now, str(uuid.uuid4()))
            if boot_changed and (was_running or timing['stopwatch']['state'] == 'paused'):
                timing['stopwatch']['state'] = 'recovery'
            document, token = self.store.commit({'timing': timing, 'sw': clock_stopwatch.legacy_projection(timing['stopwatch'], boot_now, wall_now)}, token, document['revision'])
        self.document, self.token = document, token
        self.wall_offset = wall_now - boot_now
        self._update(boot_now, wall_now, force_projection=True, force_alarms=True)

    def _update(self, boot_now, wall_now, force_projection=False, force_alarms=False):
        old = self.document['timing']
        timing = advance(old, self.boot_id, boot_now, wall_now)
        timer = timing['timer']
        stopwatch = timing['stopwatch']
        if ((timer['state'] == 'running' and boot_now - timer['checkpointBootMs'] >= CHECKPOINT_MS)
                or (stopwatch['state'] == 'running' and boot_now - stopwatch['checkpointBootMs'] >= CHECKPOINT_MS)):
            timing = checkpoint(timing, self.boot_id, boot_now, wall_now)
        wall_offset = wall_now - boot_now
        wall_changed = abs(wall_offset - self.wall_offset) >= WALL_CHANGE_MS
        alarms = self.document.get('alarms', [])
        if not isinstance(alarms, list):
            raise ValueError('Invalid alarm state')
        alarm_changed = False
        if any(isinstance(alarm, dict) and alarm.get('on') for alarm in alarms):
            cursor = timing.get('alarmCursorWallMs', wall_now)
            cursor_boot = timing.get('alarmCursorBootId', self.boot_id)
            handled = timing.get('handledAlarmDates', {})
            if type(cursor) is not int or cursor < 0 or not isinstance(cursor_boot, str) or not isinstance(handled, dict):
                raise ValueError('Invalid alarm evaluation state')
            if cursor_boot != self.boot_id:
                cursor = wall_now
            if force_alarms or wall_changed or wall_now < cursor or wall_now // 60000 > cursor // 60000 or cursor_boot != self.boot_id:
                alarms, handled, events = clock_alarms.evaluate(alarms, handled, cursor, wall_now, system_zone())
                timing['alarmCursorWallMs'] = wall_now
                timing['alarmCursorBootId'] = self.boot_id
                timing['handledAlarmDates'] = handled
                for event in events:
                    if event['status'] == 'missed':
                        timing.setdefault('missedAlarms', []).append(event)
                    elif timing.get('completion') is None:
                        timing['completion'] = event
                    else:
                        timing.setdefault('completionQueue', []).append(event)
                alarm_changed = alarms != self.document.get('alarms', [])
        changed = timing != old
        live = timer['state'] == 'running' or stopwatch['state'] == 'running'
        if not changed and not alarm_changed and not (live and (force_projection or wall_changed)):
            return False
        projection = legacy_projection(timing, boot_now, wall_now)
        sw_projection = clock_stopwatch.legacy_projection(timing['stopwatch'], boot_now, wall_now)
        if not changed and not alarm_changed and projection == self.document.get('timer') and sw_projection == self.document.get('sw'):
            self.wall_offset = wall_offset
            return False
        self.document, self.token = self.store.commit({'timing': timing, 'timer': projection, 'sw': sw_projection,
                                                       'ringing': legacy_ringing(timing), 'alarms': alarms},
                                                       self.token, self.document['revision'])
        self.wall_offset = wall_offset
        return True

    def _state(self, request_id=None):
        timing = copy.deepcopy(self.document['timing'])
        boot_now, wall_now = boot_time_ms(), wall_time_ms()
        self.emit(type='state', id=request_id, revision=self.document['revision'], timing=timing,
                  bootId=self.boot_id, bootNowMs=boot_now, wallNowMs=wall_now,
                  timer=legacy_projection(timing, boot_now, wall_now),
                  sw=clock_stopwatch.legacy_projection(timing['stopwatch'], boot_now, wall_now),
                  ringing=legacy_ringing(timing),
                  alarms=copy.deepcopy(self.document.get('alarms', [])),
                  cities=copy.deepcopy(self.document.get('cities', DEFAULT_CITIES)),
                  recents=copy.deepcopy(self.document.get('recents', [])),
                  timerPresets=copy.deepcopy(self.document.get('timerPresets', {})))

    def _sound_in_use(self, identifier):
        timing = self.document['timing']
        timer = timing.get('timer', {})
        references = list(self.document.get('alarms', []))
        if timer.get('state') != 'idle':
            references.append(timer)
        references.extend(timing.get('completionQueue', []))
        references.extend(timing.get('snoozes', []))
        if timing.get('completion'):
            references.append(timing['completion'])
        return any(isinstance(entry, dict) and entry.get('soundId') == identifier for entry in references)

    def _validate_new_sound_references(self, envelope):
        if not isinstance(envelope, dict):
            return
        # Replays must return their journaled result even if the asset later disappeared.
        now = boot_time_ms()
        journal = self.document.get('commandResults', [])
        if isinstance(journal, list) and any(record.get('id') == envelope.get('id') and record.get('bootId') == self.boot_id and
               type(record.get('issuedBootMs')) is int and 0 <= now - record['issuedBootMs'] <= WINDOW_MS
               for record in journal if isinstance(record, dict)):
            return
        action, args = envelope.get('action'), envelope.get('args')
        if not isinstance(args, dict):
            return
        candidates = []
        if action == 'start':
            candidates.append(args.get('soundId', ''))
        elif action == 'patch-settings':
            patch = args.get('patch')
            alarms = patch.get('alarms') if isinstance(patch, dict) else None
            if isinstance(alarms, list):
                existing = {item.get('id'): item.get('soundId', '') for item in self.document.get('alarms', [])
                            if isinstance(item, dict) and isinstance(item.get('id'), str)}
                for item in alarms:
                    if (isinstance(item, dict) and isinstance(item.get('id'), str) and
                            item.get('soundId', '') != existing.get(item['id'], '')):
                        candidates.append(item.get('soundId', ''))
        for identifier in candidates:
            if identifier in ('', 'silence'):
                continue
            if self.sound_library is None:
                raise SoundLibraryError('Clock sounds are unavailable')
            self.sound_library.resolve(identifier)

    def command(self, request):
        action = request.get('action')
        try:
            if action == 'load':
                self._state(request.get('id'))
            elif action == 'prepare':
                if self._update(boot_time_ms(), wall_time_ms(), force_alarms=True):
                    self._state()
                self.emit(type='prepared', id=request.get('id'), commandId=str(uuid.uuid4()),
                          sessionId=str(uuid.uuid4()), bootId=self.boot_id,
                          issuedBootMs=boot_time_ms(), revision=self.document['revision'])
            elif action == 'command':
                self._validate_new_sound_references(request.get('data'))
                result = execute(self.store, request['data'], self.boot_id, boot_time_ms(), wall_time_ms(),
                                 self.document if self.token == 'missing' else None)
                self.document, self.token = self.store.read()
                self.emit(type='result', id=request.get('id'), success=True, result=result)
                self._state()
            elif action == 'sounds':
                if self.sound_library is None:
                    raise ValueError('Clock sounds are unavailable')
                self.emit(type='sounds', id=request.get('id'),
                          sounds=self.sound_library.catalog())
            elif action == 'favorite-sound':
                if self.sound_library is None:
                    raise ValueError('Clock sounds are unavailable')
                data = request.get('data', {})
                self.sound_library.set_favorite(data.get('soundId'), data.get('favorite'))
                self.emit(type='sounds', id=request.get('id'), sounds=self.sound_library.catalog())
            elif action == 'rename-sound':
                if self.sound_library is None:
                    raise ValueError('Clock sounds are unavailable')
                data = request.get('data', {})
                self.sound_library.rename_imported(data.get('soundId'), data.get('name'))
                self.emit(type='sounds', id=request.get('id'), sounds=self.sound_library.catalog())
            elif action == 'delete-sound':
                if self.sound_library is None:
                    raise ValueError('Clock sounds are unavailable')
                identifier = request.get('data', {}).get('soundId')
                if self._sound_in_use(identifier):
                    raise ValueError('Sound is in use')
                if self.preview is not None and self.preview.sound_id == identifier:
                    self.preview.stop()
                    self.emit(type='sound-preview', soundId='', playing=False)
                cleaned = self.sound_library.delete_imported(identifier)
                timer = self.document['timing']['timer']
                presets = copy.deepcopy(validate_presets(self.document.get('timerPresets', {})))
                changed_presets = False
                for preset in presets.values():
                    if preset.get('soundId') == identifier:
                        preset['soundId'] = ''
                        changed_presets = True
                patch = {}
                if timer['state'] == 'idle' and timer.get('soundId') == identifier:
                    timing = copy.deepcopy(self.document['timing'])
                    timing['timer'].pop('soundId', None)
                    patch['timing'] = timing
                if changed_presets:
                    patch['timerPresets'] = presets
                if patch:
                    self.document, self.token = self.store.commit(patch, self.token, self.document['revision'])
                    self._state()
                self.emit(type='sounds', id=request.get('id'), sounds=self.sound_library.catalog(),
                          warning='' if cleaned else 'Sound file cleanup failed')
            elif action == 'preview-sound':
                if self.preview is None:
                    raise ValueError('Clock sounds are unavailable')
                if self._update(boot_time_ms(), wall_time_ms(), force_alarms=True):
                    self._state()
                if self.document['timing'].get('completion') is not None:
                    raise ValueError('An alert is active')
                data = request.get('data', {})
                identifier = data.get('soundId')
                if identifier == 'silence':
                    self.preview.stop()
                    self.emit(type='sound-preview', id=request.get('id'), soundId='', playing=False)
                    return
                if identifier == '':
                    kind = data.get('kind')
                    if kind not in ('alarm', 'timer'):
                        raise ValueError('Invalid preview kind')
                    path = self.audio.sound_dir / (kind + '.wav')
                    if not path.is_file():
                        path = Path(__file__).with_name('sounds') / (kind + '.wav')
                else:
                    path = self.sound_library.resolve(identifier)
                self.preview.start(identifier or 'default', path, boot_time_ms(), data.get('soundOptions'))
                self.emit(type='sound-preview', id=request.get('id'), soundId=identifier or 'default', playing=True)
            elif action == 'stop-preview':
                if self.preview is not None:
                    self.preview.stop()
                self.emit(type='sound-preview', id=request.get('id'), soundId='', playing=False)
            else:
                raise ClockCommandError('Unknown Clock action')
        except (ClockStoreError, SoundLibraryError, ValueError, OSError, KeyError) as error:
            self.emit(type='result', id=request.get('id'), success=False, error=str(error)[:200])

    def wait_timeout(self):
        timer = self.document['timing']['timer']
        stopwatch = self.document['timing']['stopwatch']
        deadlines = []
        if timer['state'] == 'running':
            deadlines.extend((timer['deadlineBootMs'], timer['checkpointBootMs'] + CHECKPOINT_MS))
        if stopwatch['state'] == 'running':
            deadlines.append(stopwatch['checkpointBootMs'] + CHECKPOINT_MS)
        for snooze in self.document['timing'].get('snoozes', []):
            if snooze['bootId'] == self.boot_id:
                deadlines.append(snooze['deadlineBootMs'])
        alarms = self.document.get('alarms', [])
        if any(isinstance(alarm, dict) and alarm.get('on') for alarm in alarms):
            wall_now = wall_time_ms()
            deadlines.append(boot_time_ms() + 60000 - wall_now % 60000)
        now = boot_time_ms()
        # The periodic wake also detects wall-clock changes for old readers.
        clock_wait = max(0, min(1, (min(deadlines) - now) / 1000)) if deadlines else None
        audio_wait = self.audio.timeout(now) if self.audio else None
        preview_wait = self.preview.timeout(now) if self.preview else None
        waits = [wait for wait in (clock_wait, audio_wait, preview_wait) if wait is not None]
        return min(waits) if waits else None

    def _drive_audio(self, boot_now):
        if self.audio is None:
            return
        event = self.document['timing'].get('completion')
        if event is None:
            self.audio.stop()
            return
        if event.get('soundClaimed') is True:
            failed = self.audio.failed
            fallback_used = self.audio.fallback_used
            self.audio.tick(event, boot_now)
            if self.audio.fallback_used and not fallback_used:
                self.emit(type='error', error='Clock sound failed; using the built-in sound')
            if self.audio.failed and not failed:
                self.emit(type='error', error='Clock sound playback failed')
            return
        self.audio.stop()
        timing = copy.deepcopy(self.document['timing'])
        timing['completion']['soundClaimed'] = True
        self.document, self.token = self.store.commit({'timing': timing, 'ringing': legacy_ringing(timing)},
                                                       self.token, self.document['revision'])
        self._state()
        sound_path = None
        sound_id = timing['completion'].get('soundId', '')
        if sound_id == 'silence':
            return
        if sound_id:
            try:
                sound_path = self.sound_library.resolve(sound_id)
            except SoundLibraryError:
                sound_path = Path(__file__).with_name('sounds') / (timing['completion'].get('kind', 'timer') + '.wav')
                self.emit(type='error', error='Clock sound failed; using the built-in sound')
        self.audio.start(dict(timing['completion'], kind=timing['completion'].get('kind', 'timer')),
                         boot_now, sound_path)
        if self.audio.failed:
            self.emit(type='error', error='Clock sound playback failed')

    def run(self):
        self._drive_audio(boot_time_ms())
        super().run()

    def tick(self):
        try:
            if self._update(boot_time_ms(), wall_time_ms()):
                self._state()
            if self.preview is not None and self.preview.sound_id is not None:
                preview_failed = False
                if self.document['timing'].get('completion') is not None:
                    self.preview.stop()
                else:
                    preview_failed = self.preview.tick(boot_time_ms())
                if self.preview.sound_id is None:
                    self.emit(type='sound-preview', soundId='', playing=False,
                              error='Sound preview failed' if preview_failed else '')
            self._drive_audio(boot_time_ms())
        except (ClockStoreError, OSError, ValueError, KeyError) as error:
            self.emit(type='error', error=str(error)[:200])
            self.running = False

    def close(self):
        if self.preview is not None:
            self.preview.stop()
        if self.audio is not None:
            self.audio.stop()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--store', type=Path, required=True)
    parser.add_argument('--audio-dir', type=Path)
    args = parser.parse_args()
    try:
        with ClockStore(args.store) as store:
            ClockService(store, args.audio_dir).run()
    except (ClockStoreError, OSError, ValueError, KeyError) as error:
        print(json.dumps({'type': 'error', 'error': str(error)[:200]}), flush=True)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
