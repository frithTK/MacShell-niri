"""Stopwatch state transitions based on Linux boot time."""

import copy


class StopwatchError(ValueError):
    pass


def _int(value, name):
    if type(value) is not int or value < 0:
        raise StopwatchError('Invalid ' + name)
    return value


def validate(stopwatch):
    if not isinstance(stopwatch, dict) or stopwatch.get('state') not in ('idle', 'running', 'paused', 'recovery'):
        raise StopwatchError('Invalid stopwatch state')
    if not isinstance(stopwatch.get('sessionId'), str) or not stopwatch['sessionId']:
        raise StopwatchError('Invalid stopwatch session')
    elapsed = _int(stopwatch.get('elapsedCheckpointMs'), 'stopwatch elapsed time')
    _int(stopwatch.get('checkpointBootMs'), 'stopwatch checkpoint')
    if 'checkpointWallMs' in stopwatch:
        _int(stopwatch['checkpointWallMs'], 'stopwatch checkpoint wall time')
    laps = stopwatch.get('laps')
    if not isinstance(laps, list) or any(type(lap) is not int or lap < 0 or lap > elapsed for lap in laps):
        raise StopwatchError('Invalid stopwatch laps')
    if stopwatch['state'] == 'running':
        _int(stopwatch.get('startedBootMs'), 'stopwatch start')
        _int(stopwatch.get('accumulatedMs'), 'stopwatch accumulated time')
    elif 'startedBootMs' in stopwatch:
        raise StopwatchError('Unexpected stopwatch start')
    return stopwatch


def migrate_legacy(stopwatch, boot_now, wall_now, session_id):
    if not isinstance(stopwatch, dict) or type(stopwatch.get('running')) is not bool:
        raise StopwatchError('Invalid legacy stopwatch')
    acc = _int(stopwatch.get('acc'), 'legacy accumulated time')
    start = _int(stopwatch.get('startAt'), 'legacy start time')
    elapsed = acc + max(0, wall_now - start) if stopwatch['running'] else acc
    result = {'sessionId': session_id, 'state': 'running' if stopwatch['running'] else 'paused' if elapsed else 'idle',
              'elapsedCheckpointMs': elapsed, 'checkpointBootMs': boot_now,
              'checkpointWallMs': wall_now, 'laps': copy.deepcopy(stopwatch.get('laps', [])), 'provenance': 'legacy-wall-clock'}
    if stopwatch['running']:
        result.update(startedBootMs=boot_now, accumulatedMs=elapsed)
    validate(result)
    return result


def elapsed(stopwatch, boot_now):
    _int(boot_now, 'boot time')
    if stopwatch['state'] == 'running':
        if boot_now < stopwatch['startedBootMs']:
            raise StopwatchError('Boot clock moved backwards')
        return stopwatch['accumulatedMs'] + boot_now - stopwatch['startedBootMs']
    return stopwatch['elapsedCheckpointMs']


def restore(stopwatch, boot_changed):
    result = copy.deepcopy(stopwatch)
    if boot_changed and result['state'] in ('running', 'paused'):
        result['state'] = 'recovery'
        result.pop('startedBootMs', None)
        result.pop('accumulatedMs', None)
    return result


def checkpoint(stopwatch, boot_now, wall_now=None):
    result = copy.deepcopy(stopwatch)
    if wall_now is not None:
        _int(wall_now, 'wall time')
    if result['state'] == 'running':
        result['elapsedCheckpointMs'] = elapsed(result, boot_now)
        result['checkpointBootMs'] = boot_now
        if wall_now is not None:
            result['checkpointWallMs'] = wall_now
    return result


def command(stopwatch, action, boot_now, session_id, wall_now=None):
    result = copy.deepcopy(stopwatch)
    _int(boot_now, 'boot time')
    if not isinstance(session_id, str) or not session_id:
        raise StopwatchError('Invalid stopwatch session')
    if session_id != result['sessionId']:
        raise StopwatchError('Stopwatch session changed')
    state = result['state']
    if ((action == 'start' and state in ('idle', 'paused'))
            or (action == 'recover-resume' and state == 'recovery')):
        result['state'] = 'running'
        result['startedBootMs'] = boot_now
        result['accumulatedMs'] = result['elapsedCheckpointMs']
        result['checkpointBootMs'] = boot_now
    elif action == 'pause' and state == 'running':
        result = checkpoint(result, boot_now, wall_now)
        result['state'] = 'paused'
        result.pop('startedBootMs', None)
        result.pop('accumulatedMs', None)
    elif action == 'lap' and state == 'running':
        result = checkpoint(result, boot_now, wall_now)
        result['laps'].insert(0, result['elapsedCheckpointMs'])
    elif action == 'reset' and state in ('paused', 'recovery', 'idle'):
        result['state'] = 'idle'
        result['elapsedCheckpointMs'] = 0
        result['checkpointBootMs'] = boot_now
        result['laps'] = []
        result.pop('startedBootMs', None)
        result.pop('accumulatedMs', None)
    else:
        raise StopwatchError('Invalid stopwatch transition')
    if wall_now is not None:
        _int(wall_now, 'wall time')
        if result != stopwatch and result['checkpointBootMs'] == boot_now:
            result['checkpointWallMs'] = wall_now
    return result


def legacy_projection(stopwatch, boot_now, wall_now):
    value = elapsed(stopwatch, boot_now)
    running = stopwatch['state'] == 'running'
    result = {'running': running, 'startAt': wall_now if running else 0,
              'acc': value, 'laps': copy.deepcopy(stopwatch['laps'])}
    if stopwatch['state'] == 'recovery':
        result['recoveryRequired'] = True
    return result
