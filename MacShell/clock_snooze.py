"""Boot-clock snoozes derived from acknowledged alarm events."""

import copy
import uuid
from clock_sound_library import valid_sound_id
from clock_sound_options import normalize as normalize_sound_options


SNOOZE_MS = 9 * 60 * 1000


def migrate_legacy(snoozes, wall_now):
    """Keep old wall-clock snoozes for an explicit recovery decision."""
    if not isinstance(snoozes, list) or type(wall_now) is not int or wall_now < 0:
        raise ValueError('Invalid legacy snoozes')
    recovered = []
    for item in snoozes:
        if (not isinstance(item, dict) or type(item.get('at')) is not int or item['at'] < 0
                or not isinstance(item.get('label', ''), str) or len(item.get('label', '')) > 200
                or ('defaultLabel' in item and type(item['defaultLabel']) is not bool)):
            raise ValueError('Invalid legacy snooze')
        recovered.append({'id': str(uuid.uuid4()), 'sessionId': str(uuid.uuid4()),
                          'sourceEventId': str(uuid.uuid4()), 'label': item.get('label', ''),
                          'remainingMs': max(0, min(SNOOZE_MS, item['at'] - wall_now)),
                          'capturedWallMs': wall_now, 'provenance': 'legacy-wall-clock',
                          'legacy': copy.deepcopy(item)})
    return recovered


def validate_recovery(recovered):
    if not isinstance(recovered, list):
        raise ValueError('Invalid snooze recovery data')
    seen = set()
    for item in recovered:
        if (not isinstance(item, dict) or not isinstance(item.get('id'), str) or not item['id']
                or not isinstance(item.get('sessionId'), str) or not item['sessionId']
                or not isinstance(item.get('sourceEventId'), str) or not item['sourceEventId']
                or not isinstance(item.get('label'), str) or len(item['label']) > 200
                or type(item.get('remainingMs')) is not int or not 0 <= item['remainingMs'] <= SNOOZE_MS
                or type(item.get('capturedWallMs')) is not int or item['capturedWallMs'] < 0
                or not isinstance(item.get('provenance'), str) or not item['provenance']
                or not isinstance(item.get('legacy'), dict)):
            raise ValueError('Invalid snooze recovery entry')
        if item['id'] in seen:
            raise ValueError('Duplicate snooze recovery ID')
        seen.add(item['id'])
    return recovered


def resolve_recovery(timing, recovery_id, decision, command_id, boot_id, boot_now, wall_now=None):
    recovered = timing.get('legacySnoozesRecovery', [])
    validate_recovery(recovered)
    if not isinstance(recovery_id, str) or not recovery_id or decision not in ('resume', 'discard'):
        raise ValueError('Invalid snooze recovery decision')
    index = next((index for index, item in enumerate(recovered) if item['id'] == recovery_id), None)
    if index is None:
        raise ValueError('Snooze recovery entry changed')
    item = recovered.pop(index)
    if decision == 'resume':
        snoozes = timing.setdefault('snoozes', [])
        snoozes.append({'id': command_id, 'bootId': boot_id,
                        'deadlineBootMs': boot_now + item['remainingMs'],
                        'sessionId': item['sessionId'], 'label': item['label'],
                        'sourceEventId': item['sourceEventId'], 'time': '',
                        'provenance': item['provenance']})
        validate(snoozes)
    return advance(timing, boot_id, boot_now, wall_now)


def validate(snoozes):
    if not isinstance(snoozes, list):
        raise ValueError('Invalid snoozes')
    ids = set()
    for item in snoozes:
        if (not isinstance(item, dict) or not isinstance(item.get('id'), str) or not item['id']
                or not isinstance(item.get('bootId'), str) or not item['bootId']
                or type(item.get('deadlineBootMs')) is not int or item['deadlineBootMs'] < 0
                or not isinstance(item.get('sessionId'), str) or not item['sessionId']
                or not isinstance(item.get('label'), str)
                or not isinstance(item.get('sourceEventId'), str) or not item['sourceEventId']):
            raise ValueError('Invalid snooze')
        if item['id'] in ids:
            raise ValueError('Duplicate snooze ID')
        if 'time' in item and not isinstance(item['time'], str):
            raise ValueError('Invalid snooze time')
        if not valid_sound_id(item.get('soundId', '')):
            raise ValueError('Invalid snooze sound')
        normalize_sound_options(item.get('soundOptions'))
        ids.add(item['id'])
    return snoozes


def schedule(timing, event, snooze_id, boot_id, boot_now):
    if event.get('kind') != 'alarm':
        raise ValueError('Only alarm events can be snoozed')
    snoozes = timing.setdefault('snoozes', [])
    snoozes.append({'id': snooze_id, 'bootId': boot_id, 'deadlineBootMs': boot_now + SNOOZE_MS,
                    'sessionId': event['sessionId'], 'label': event['label'],
                    'sourceEventId': event['eventId'], 'time': event.get('time', ''),
                    'soundId': event.get('soundId', '')})
    if event.get('soundOptions') is not None:
        snoozes[-1]['soundOptions'] = copy.deepcopy(event['soundOptions'])
    validate(snoozes)


def advance(timing, boot_id, boot_now, wall_now=None):
    result = copy.deepcopy(timing)
    if 'snoozes' not in result:
        return result
    validate(result['snoozes'])
    remaining = []
    for item in result['snoozes']:
        if item['bootId'] != boot_id:
            result.setdefault('missedSnoozes', []).append(item)
        elif item['deadlineBootMs'] <= boot_now:
            event = {'eventId': str(uuid.uuid5(uuid.NAMESPACE_URL, 'macshell:snooze:' + item['id'])),
                     'sessionId': item['sessionId'], 'kind': 'alarm', 'label': item['label'],
                     'sourceEventId': item['sourceEventId'], 'time': item.get('time', ''),
                     'soundId': item.get('soundId', '')}
            if item.get('soundOptions') is not None:
                event['soundOptions'] = copy.deepcopy(item['soundOptions'])
            if wall_now is not None:
                if type(wall_now) is not int or wall_now < 0:
                    raise ValueError('Invalid wall time')
                event['occurredWallMs'] = wall_now
            if result.get('completion') is None:
                result['completion'] = event
            else:
                result.setdefault('completionQueue', []).append(event)
        else:
            remaining.append(item)
    result['snoozes'] = remaining
    return result
