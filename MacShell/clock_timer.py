"""Pure timer transitions for Clock's CLOCK_BOOTTIME state."""

import copy
import uuid

import clock_snooze
import clock_stopwatch
from clock_sound_library import valid_sound_id
from clock_sound_options import normalize as normalize_sound_options


MAX_DURATION_MS = 7 * 24 * 60 * 60 * 1000


class TimerError(ValueError):
    pass


def _number(value, name, low=0, high=None):
    if type(value) is not int or value < low or (high is not None and value > high):
        raise TimerError('Invalid ' + name)
    return value


def _identity(value, name):
    if not isinstance(value, str) or not value:
        raise TimerError('Invalid ' + name)
    return value


def validate_timing(timing):
    """Reject unsupported or damaged canonical state before any mutation."""
    if not isinstance(timing, dict) or type(timing.get('version')) is not int or timing['version'] != 1:
        raise TimerError('Invalid timing version')
    _identity(timing.get('bootId'), 'boot ID')
    timer = timing.get('timer')
    if not isinstance(timer, dict) or timer.get('state') not in ('idle', 'running', 'paused', 'recovery'):
        raise TimerError('Invalid timer state')
    _identity(timer.get('sessionId'), 'session ID')
    total = _number(timer.get('totalMs'), 'duration', 1, MAX_DURATION_MS)
    _number(timer.get('remainingCheckpointMs'), 'remaining time', 0, total)
    _number(timer.get('checkpointBootMs'), 'checkpoint time')
    if 'checkpointWallMs' in timer:
        _number(timer['checkpointWallMs'], 'checkpoint wall time')
    if not isinstance(timer.get('label'), str) or len(timer['label']) > 200:
        raise TimerError('Invalid label')
    if not valid_sound_id(timer.get('soundId', '')):
        raise TimerError('Invalid timer sound')
    normalize_sound_options(timer.get('soundOptions'))
    if timer['state'] == 'running':
        _number(timer.get('deadlineBootMs'), 'deadline')
    elif 'deadlineBootMs' in timer:
        raise TimerError('Unexpected deadline')
    events = timing.get('completionQueue', [])
    if not isinstance(events, list):
        raise TimerError('Invalid completion queue')
    completion = timing.get('completion')
    if completion is None and events:
        raise TimerError('Completion queue has no current event')
    seen_events = set()
    for event in ([completion] if completion is not None else []) + events:
        if not isinstance(event, dict):
            raise TimerError('Invalid completion')
        _identity(event.get('eventId'), 'event ID')
        if event['eventId'] in seen_events:
            raise TimerError('Duplicate completion')
        seen_events.add(event['eventId'])
        _identity(event.get('sessionId'), 'session ID')
        if not isinstance(event.get('label'), str):
            raise TimerError('Invalid completion label')
        if 'kind' in event and event['kind'] not in ('timer', 'alarm'):
            raise TimerError('Invalid completion kind')
        if 'time' in event and not isinstance(event['time'], str):
            raise TimerError('Invalid completion time')
        if 'defaultLabel' in event and type(event['defaultLabel']) is not bool:
            raise TimerError('Invalid completion label flag')
        if 'occurredWallMs' in event:
            _number(event['occurredWallMs'], 'completion wall time')
        if 'soundClaimed' in event and type(event['soundClaimed']) is not bool:
            raise TimerError('Invalid sound claim')
        if not valid_sound_id(event.get('soundId', '')):
            raise TimerError('Invalid completion sound')
        normalize_sound_options(event.get('soundOptions'))
    if 'stopwatch' in timing:
        clock_stopwatch.validate(timing['stopwatch'])
    if 'snoozes' in timing:
        clock_snooze.validate(timing['snoozes'])
    if 'legacySnoozesRecovery' in timing:
        clock_snooze.validate_recovery(timing['legacySnoozesRecovery'])
    for field, id_key in (('missedAlarms', 'eventId'), ('missedSnoozes', 'id')):
        records = timing.get(field, [])
        if not isinstance(records, list):
            raise TimerError('Invalid missed event list')
        seen = set()
        for record in records:
            if (not isinstance(record, dict) or not isinstance(record.get(id_key), str)
                    or not record[id_key] or not isinstance(record.get('label'), str)):
                raise TimerError('Invalid missed event')
            if record[id_key] in seen:
                raise TimerError('Duplicate missed event')
            seen.add(record[id_key])
    return timing


def migrate_legacy(timer, boot_id, boot_now, wall_now, session_id):
    """Convert one legacy timer; callers persist the result exactly once."""
    _identity(boot_id, 'boot ID')
    _identity(session_id, 'session ID')
    _number(boot_now, 'boot time')
    _number(wall_now, 'wall time')
    if not isinstance(timer, dict) or timer.get('state') not in ('idle', 'paused', 'running'):
        raise TimerError('Invalid legacy timer')
    total = _number(timer.get('total'), 'duration', 1, MAX_DURATION_MS)
    label = timer.get('label', '')
    if not isinstance(label, str) or len(label) > 200:
        raise TimerError('Invalid label')
    state = timer['state']
    left = (max(0, min(total, _number(timer.get('endAt'), 'end time') - wall_now))
            if state == 'running' else _number(timer.get('left'), 'remaining time', 0, total))
    entry = {'sessionId': session_id, 'state': state, 'totalMs': total,
             'remainingCheckpointMs': left, 'checkpointBootMs': boot_now, 'label': label,
             'checkpointWallMs': wall_now, 'provenance': 'legacy-wall-clock'}
    if state == 'running':
        entry['deadlineBootMs'] = boot_now + left
    return {'version': 1, 'bootId': boot_id, 'timer': entry, 'completion': None}


def restore(timing, boot_id, boot_now, wall_now=None):
    """Restore in the same boot or require an explicit decision after reboot."""
    _identity(boot_id, 'boot ID')
    _number(boot_now, 'boot time')
    result = copy.deepcopy(timing)
    timer = result['timer']
    boot_changed = result['bootId'] != boot_id
    if boot_changed:
        if timer['state'] in ('running', 'paused'):
            timer['state'] = 'recovery'
            timer.pop('deadlineBootMs', None)
        if 'stopwatch' in result:
            result['stopwatch'] = clock_stopwatch.restore(result['stopwatch'], True)
        result['bootId'] = boot_id
    return clock_snooze.advance(result, boot_id, boot_now, wall_now)


def advance(timing, boot_id, boot_now, wall_now=None):
    """Finish an overdue session once; caller persists the result atomically."""
    result = restore(timing, boot_id, boot_now, wall_now)
    timer = result['timer']
    if timer['state'] == 'running' and boot_now >= timer['deadlineBootMs']:
        session_id = timer['sessionId']
        timer['state'] = 'idle'
        timer['remainingCheckpointMs'] = timer['totalMs']
        timer['checkpointBootMs'] = boot_now
        timer.pop('deadlineBootMs', None)
        event = {'eventId': str(uuid.uuid5(uuid.NAMESPACE_URL, 'macshell:timer:' + session_id)),
                 'sessionId': session_id, 'kind': 'timer', 'label': timer['label'],
                 'totalMs': timer['totalMs']}
        if timer.get('soundId'):
            event['soundId'] = timer['soundId']
        if timer.get('soundOptions') is not None:
            event['soundOptions'] = copy.deepcopy(timer['soundOptions'])
        if result.get('completion') is None:
            result['completion'] = event
        else:
            result.setdefault('completionQueue', []).append(event)
    return result


def command(timing, action, boot_id, boot_now, *, session_id=None,
            duration_ms=None, label='', replace=False, wall_now=None, sound_id='', sound_options=None):
    """Apply one transition to a snapshot, without I/O or command deduplication."""
    result = advance(timing, boot_id, boot_now, wall_now)
    timer = result['timer']
    state = timer['state']
    if action == 'start':
        if state != 'idle' and not replace:
            raise TimerError('A timer is already active')
        _number(duration_ms, 'duration', 1, MAX_DURATION_MS)
        _identity(session_id, 'session ID')
        if session_id == timer.get('sessionId'):
            raise TimerError('A new timer needs a new session ID')
        if not isinstance(label, str) or len(label) > 200:
            raise TimerError('Invalid label')
        if not valid_sound_id(sound_id):
            raise TimerError('Invalid timer sound')
        if sound_options is not None:
            normalize_sound_options(sound_options)
        result['timer'] = {'sessionId': session_id, 'state': 'running', 'totalMs': duration_ms,
                           'deadlineBootMs': boot_now + duration_ms, 'remainingCheckpointMs': duration_ms,
                           'checkpointBootMs': boot_now, 'label': label}
        if sound_id:
            result['timer']['soundId'] = sound_id
        if sound_options is not None:
            result['timer']['soundOptions'] = copy.deepcopy(sound_options)
    elif action == 'cancel':
        if state != 'idle':
            _identity(session_id, 'session ID')
            if session_id != timer['sessionId']:
                raise TimerError('Timer session changed')
            timer['state'] = 'idle'
            timer['remainingCheckpointMs'] = timer['totalMs']
            timer['checkpointBootMs'] = boot_now
            timer.pop('deadlineBootMs', None)
    elif action in ('pause', 'resume', 'recover-remainder', 'recover-restart'):
        _identity(session_id, 'session ID')
        if session_id != timer['sessionId']:
            raise TimerError('Timer session changed')
        if action == 'pause' and state == 'running':
            timer['remainingCheckpointMs'] = timer['deadlineBootMs'] - boot_now
            timer['checkpointBootMs'] = boot_now
            timer['state'] = 'paused'
            timer.pop('deadlineBootMs', None)
        elif (action == 'resume' and state == 'paused') or (action.startswith('recover-') and state == 'recovery'):
            left = timer['totalMs'] if action == 'recover-restart' else timer['remainingCheckpointMs']
            _number(left, 'remaining time', 0, timer['totalMs'])
            timer['state'] = 'running'
            timer['deadlineBootMs'] = boot_now + left
            timer['remainingCheckpointMs'] = left
            timer['checkpointBootMs'] = boot_now
        elif (action == 'pause' and state == 'idle' and timing['bootId'] == boot_id
              and timing['timer']['state'] == 'running' and timing['timer']['sessionId'] == session_id):
            pass  # The deadline won the race with pause.
        else:
            raise TimerError('Invalid timer transition')
    else:
        raise TimerError('Unknown timer action')
    if wall_now is not None:
        _number(wall_now, 'wall time')
        if result['timer'] != timing['timer'] and result['timer']['checkpointBootMs'] == boot_now:
            result['timer']['checkpointWallMs'] = wall_now
    if result['timer']['state'] == 'running' and result['timer']['deadlineBootMs'] <= boot_now:
        result = advance(result, boot_id, boot_now, wall_now)
    return result


def checkpoint(timing, boot_id, boot_now, wall_now=None):
    result = advance(timing, boot_id, boot_now, wall_now)
    if wall_now is not None:
        _number(wall_now, 'wall time')
    timer = result['timer']
    if timer['state'] == 'running':
        timer['remainingCheckpointMs'] = timer['deadlineBootMs'] - boot_now
        timer['checkpointBootMs'] = boot_now
        if wall_now is not None:
            timer['checkpointWallMs'] = wall_now
    if 'stopwatch' in result:
        result['stopwatch'] = clock_stopwatch.checkpoint(result['stopwatch'], boot_now, wall_now)
    return result


def legacy_projection(timing, boot_now, wall_now):
    """Project a snapshot for readers that still consume the old timer shape."""
    _number(boot_now, 'boot time')
    _number(wall_now, 'wall time')
    timer = timing['timer']
    state = timer['state']
    left = max(0, timer['deadlineBootMs'] - boot_now) if state == 'running' else timer['remainingCheckpointMs']
    projected = {'state': 'paused' if state == 'recovery' else state, 'total': timer['totalMs'],
                 'left': left, 'endAt': wall_now + left if state == 'running' else 0,
                 'label': timer['label']}
    if state == 'recovery':
        projected['recoveryRequired'] = True
    return projected


def legacy_ringing(timing):
    event = timing.get('completion')
    if event is None:
        return None
    kind = event.get('kind', 'timer')
    result = {'kind': kind, 'label': event['label'], 'defaultLabel': event.get('defaultLabel', not event['label']),
              'time': event.get('time', ''), 'eventId': event['eventId']}
    for key in ('occurredWallMs', 'hour', 'minute'):
        if key in event:
            result[key] = event[key]
    return result
