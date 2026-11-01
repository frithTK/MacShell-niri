"""Transactional timer command handling for a single Clock store owner."""

import copy
import hashlib
import json
import uuid
from zoneinfo import ZoneInfo

import clock_alarms
import clock_snooze
import clock_stopwatch
from clock_source import system_zone
from clock_sound_options import validate_presets
from clock_store import ClockStoreConflict, ClockStoreError
from clock_timer import advance, command as timer_command, legacy_projection, legacy_ringing, validate_timing


WINDOW_MS = 10 * 60 * 1000
MAX_RESULTS = 1024


class ClockCommandError(ValueError):
    pass


def execute(store, envelope, boot_id, boot_now, wall_now, initial_document=None):
    """Apply and persist a command, or replay its previously saved result."""
    if not isinstance(envelope, dict) or set(envelope) != {'id', 'bootId', 'issuedBootMs', 'revision', 'action', 'args'}:
        raise ClockCommandError('Invalid command envelope')
    try:
        if not isinstance(envelope['id'], str) or str(uuid.UUID(envelope['id'])) != envelope['id']:
            raise ValueError('UUID must be canonical')
    except (ValueError, AttributeError) as exc:
        raise ClockCommandError('Invalid command ID') from exc
    issued = envelope['issuedBootMs']
    if (not isinstance(boot_id, str) or not boot_id or envelope['bootId'] != boot_id
            or type(boot_now) is not int or type(issued) is not int or issued < 0
            or issued > boot_now or boot_now - issued > WINDOW_MS):
        raise ClockCommandError('Command is outside its boot or delivery window')
    if type(envelope['revision']) is not int or envelope['revision'] < 0:
        raise ClockCommandError('Invalid revision')
    action, args = envelope['action'], envelope['args']
    allowed = {'start': {'sessionId', 'durationMs', 'label', 'replace', 'soundId', 'soundOptions'},
               'pause': {'sessionId'}, 'resume': {'sessionId'}, 'cancel': {'sessionId'},
               'recover-remainder': {'sessionId'}, 'recover-restart': {'sessionId'},
               'stopwatch-start': {'sessionId'}, 'stopwatch-pause': {'sessionId'},
               'stopwatch-lap': {'sessionId'}, 'stopwatch-reset': {'sessionId'},
               'stopwatch-recover-resume': {'sessionId'},
               'claim-sound': {'eventId'}, 'dismiss-event': {'eventId'}, 'snooze': {'eventId'},
               'patch-settings': {'patch'}, 'recover-snooze': {'recoveryId', 'decision'},
               'repeat-timer': {'eventId', 'sessionId'}, 'ack-missed': {'kind', 'eventId'}}
    if not isinstance(action, str) or action not in allowed or not isinstance(args, dict) or set(args) - allowed[action]:
        raise ClockCommandError('Invalid command action or arguments')
    if 'replace' in args and type(args['replace']) is not bool:
        raise ClockCommandError('Invalid replacement flag')
    try:
        encoded = json.dumps(envelope, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                             allow_nan=False).encode('utf-8')
    except (TypeError, ValueError, UnicodeError) as exc:
        raise ClockCommandError('Invalid command data') from exc
    digest = hashlib.sha256(encoded).hexdigest()
    document, token = store.read()
    if token == 'missing' and initial_document is not None:
        document = copy.deepcopy(initial_document)
    if document.get('version') != 2:
        raise ClockStoreError('Clock data has not been migrated')
    validate_timing(document['timing'])
    journal = document.get('commandResults', [])
    if not isinstance(journal, list):
        raise ClockStoreError('Invalid command journal')
    active = []
    seen = set()
    for record in journal:
        if (not isinstance(record, dict) or not isinstance(record.get('id'), str)
                or not isinstance(record.get('hash'), str) or not isinstance(record.get('result'), dict)
                or type(record.get('issuedBootMs')) is not int or record['issuedBootMs'] < 0
                or not isinstance(record.get('bootId'), str)):
            raise ClockStoreError('Invalid command journal')
        if record['bootId'] == boot_id and record['issuedBootMs'] > boot_now:
            raise ClockStoreError('Command journal is from a future boot time')
        if record['bootId'] == boot_id and boot_now - record['issuedBootMs'] <= WINDOW_MS:
            if record['id'] in seen:
                raise ClockStoreError('Duplicate command journal ID')
            seen.add(record['id'])
            active.append(record)
    for record in active:
        if record['id'] == envelope['id']:
            if record['hash'] != digest:
                raise ClockCommandError('Command ID reused with different content')
            return copy.deepcopy(record['result'])
    if len(active) >= MAX_RESULTS:
        raise ClockCommandError('Command journal is full')
    if envelope['revision'] != document['revision']:
        raise ClockStoreConflict('Clock revision changed')
    sound_granted = None
    settings_patch = {}
    if action == 'ack-missed':
        timing = advance(document['timing'], boot_id, boot_now, wall_now)
        kind, event_id = args.get('kind'), args.get('eventId')
        if kind not in ('alarm', 'snooze') or not isinstance(event_id, str) or not event_id:
            raise ClockCommandError('Invalid missed event')
        field, key = ('missedAlarms', 'eventId') if kind == 'alarm' else ('missedSnoozes', 'id')
        records = timing.get(field, [])
        remaining = [item for item in records if item[key] != event_id]
        if len(remaining) != len(records) - 1:
            raise ClockCommandError('Missed event changed')
        timing[field] = remaining
    elif action == 'repeat-timer':
        timing = advance(document['timing'], boot_id, boot_now, wall_now)
        event = timing.get('completion')
        if (not isinstance(args.get('eventId'), str) or not event
                or event['eventId'] != args['eventId'] or event.get('kind', 'timer') != 'timer'):
            raise ClockCommandError('Timer event changed')
        if timing['timer']['state'] != 'idle':
            raise ClockCommandError('A timer is already active')
        queue = timing.get('completionQueue', [])
        timing['completion'] = queue.pop(0) if queue else None
        previous = timing['timer']
        timing = timer_command(timing, 'start', boot_id, boot_now, session_id=args.get('sessionId'),
                               duration_ms=previous['totalMs'], label=previous['label'], wall_now=wall_now,
                               sound_id=previous.get('soundId', ''), sound_options=previous.get('soundOptions'))
    elif action == 'recover-snooze':
        timing = advance(document['timing'], boot_id, boot_now, wall_now)
        timing = clock_snooze.resolve_recovery(timing, args.get('recoveryId'), args.get('decision'),
                                                envelope['id'], boot_id, boot_now, wall_now)
    elif action == 'patch-settings':
        settings_patch = args.get('patch')
        if (not isinstance(settings_patch, dict) or not settings_patch
                or set(settings_patch) - {'alarms', 'cities', 'recents'}):
            raise ClockCommandError('Invalid Clock settings')
        timing = advance(document['timing'], boot_id, boot_now, wall_now)
        if 'alarms' in settings_patch:
            old_alarms = document.get('alarms', [])
            cursor = timing.get('alarmCursorWallMs', wall_now)
            if (old_alarms and timing.get('alarmCursorBootId', boot_id) == boot_id
                    and type(cursor) is int and 0 <= cursor <= wall_now):
                _, _, pending = clock_alarms.evaluate(old_alarms, timing.get('handledAlarmDates', {}),
                                                      cursor, wall_now, system_zone())
                if pending:
                    raise ClockStoreConflict('Pending alarm must be processed before editing')
            clock_alarms.evaluate(settings_patch['alarms'], {}, wall_now, wall_now, ZoneInfo('UTC'))
            timing['alarmCursorWallMs'] = wall_now
            timing['alarmCursorBootId'] = boot_id
        if 'cities' in settings_patch:
            cities = settings_patch['cities']
            if (not isinstance(cities, list) or len(cities) > 256
                    or any(not isinstance(city, dict) or not isinstance(city.get('name'), str)
                           or not city['name'] or len(city['name']) > 200
                           or not isinstance(city.get('tz'), str) or not city['tz'] for city in cities)):
                raise ClockCommandError('Invalid Clock cities')
            for city in cities:
                ZoneInfo(city['tz'])
        if 'recents' in settings_patch:
            recents = settings_patch['recents']
            if (not isinstance(recents, list) or len(recents) > 6
                    or any(type(value) is not int or not 1 <= value <= 604800000 for value in recents)):
                raise ClockCommandError('Invalid recent timer durations')
        settings_patch = copy.deepcopy(settings_patch)
    elif action in ('claim-sound', 'dismiss-event', 'snooze'):
        timing = advance(document['timing'], boot_id, boot_now, wall_now)
        event = timing.get('completion')
        if not isinstance(args.get('eventId'), str) or not event or event['eventId'] != args['eventId']:
            raise ClockCommandError('Clock event changed')
        if action == 'claim-sound':
            sound_granted = not event.get('soundClaimed', False)
            event['soundClaimed'] = True
        else:
            if action == 'snooze':
                clock_snooze.schedule(timing, event, envelope['id'], boot_id, boot_now)
            queue = timing.get('completionQueue', [])
            timing['completion'] = queue.pop(0) if queue else None
    elif action.startswith('stopwatch-'):
        timing = advance(document['timing'], boot_id, boot_now, wall_now)
        if 'stopwatch' not in timing:
            raise ClockStoreError('Stopwatch data has not been migrated')
        timing['stopwatch'] = clock_stopwatch.command(timing['stopwatch'], action[len('stopwatch-'):],
                                                       boot_now, args.get('sessionId'), wall_now)
    else:
        timing = timer_command(document['timing'], action, boot_id, boot_now,
                               session_id=args.get('sessionId'), duration_ms=args.get('durationMs'),
                               label=args.get('label', ''), replace=args.get('replace', False), wall_now=wall_now,
                               sound_id=args.get('soundId', ''), sound_options=args.get('soundOptions'))
        if action == 'start':
            recents = document.get('recents', [])
            if (not isinstance(recents, list) or len(recents) > 6
                    or any(type(value) is not int or not 1 <= value <= 604800000 for value in recents)):
                raise ClockStoreError('Invalid recent timer durations')
            duration = args['durationMs']
            new_recents = ([duration] + [value for value in recents if value != duration])[:6]
            presets = copy.deepcopy(validate_presets(document.get('timerPresets', {})))
            presets = {str(value): presets[str(value)] for value in new_recents if str(value) in presets}
            preset = presets.get(str(duration), {})
            preset['soundId'] = args.get('soundId', '')
            preset['soundOptions'] = copy.deepcopy(args.get('soundOptions'))
            presets[str(duration)] = preset
            settings_patch = {'recents': new_recents, 'timerPresets': presets}
    projection = legacy_projection(timing, boot_now, wall_now)
    result = {'revision': document['revision'] + 1, 'timer': projection,
              'timing': copy.deepcopy(timing)}
    if sound_granted is not None:
        result['soundGranted'] = sound_granted
    active.append({'id': envelope['id'], 'bootId': boot_id, 'issuedBootMs': issued,
                   'hash': digest, 'result': copy.deepcopy(result)})
    patch = {'timing': timing, 'timer': projection, 'ringing': legacy_ringing(timing), 'commandResults': active}
    patch.update(settings_patch)
    if settings_patch:
        result['settings'] = copy.deepcopy(settings_patch)
        active[-1]['result'] = copy.deepcopy(result)
    if 'stopwatch' in timing:
        patch['sw'] = clock_stopwatch.legacy_projection(timing['stopwatch'], boot_now, wall_now)
        result['sw'] = copy.deepcopy(patch['sw'])
        active[-1]['result'] = copy.deepcopy(result)
    store.commit(patch, token, document['revision'])
    return result
