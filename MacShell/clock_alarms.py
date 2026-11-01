"""Evaluate calendar alarms over an explicit wall-clock interval."""

import copy
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from clock_calendar import latest_due_occurrence
from clock_sound_library import valid_sound_id
from clock_sound_options import normalize as normalize_sound_options


UTC = timezone.utc
EPOCH = datetime(1970, 1, 1, tzinfo=UTC)


def _instant(milliseconds):
    if type(milliseconds) is not int or milliseconds < 0:
        raise ValueError('Invalid alarm evaluation time')
    return EPOCH + timedelta(milliseconds=milliseconds)


def evaluate(alarms, handled, since_ms, now_ms, system_zone):
    """Return updated alarms, handled dates and ordered due/missed events.

    The caller persists these results with its evaluation cursor before acting
    on a due event. Repeat days use the existing Clock convention: Sunday=0.
    """
    if not isinstance(alarms, list) or not isinstance(handled, dict) or not isinstance(system_zone, ZoneInfo):
        raise ValueError('Invalid alarm state')
    since, now = _instant(since_ms), _instant(now_ms)
    if now < since:
        return copy.deepcopy(alarms), copy.deepcopy(handled), []
    new_alarms, new_handled, events = copy.deepcopy(alarms), copy.deepcopy(handled), []
    ids = set()
    for alarm in new_alarms:
        if not isinstance(alarm, dict) or not isinstance(alarm.get('id'), str) or not alarm['id']:
            raise ValueError('Invalid alarm ID')
        alarm_id = alarm['id']
        if alarm_id in ids:
            raise ValueError('Duplicate alarm ID')
        ids.add(alarm_id)
        if type(alarm.get('on')) is not bool:
            raise ValueError('Invalid alarm enabled flag')
        days = alarm.get('days')
        if not isinstance(days, list) or any(type(day) is not int or not 0 <= day <= 6 for day in days):
            raise ValueError('Invalid alarm repeat days')
        if len(days) != len(set(days)):
            raise ValueError('Duplicate alarm repeat day')
        label = alarm.get('label', '')
        if not isinstance(label, str) or len(label) > 200:
            raise ValueError('Invalid alarm label')
        if not valid_sound_id(alarm.get('soundId', '')):
            raise ValueError('Invalid alarm sound')
        normalize_sound_options(alarm.get('soundOptions'))
        hour, minute = alarm.get('h'), alarm.get('m')
        if type(hour) is not int or not 0 <= hour <= 23 or type(minute) is not int or not 0 <= minute <= 59:
            raise ValueError('Invalid alarm time')
        stored = new_handled.get(alarm_id, [])
        if not isinstance(stored, list) or any(not isinstance(value, str) for value in stored):
            raise ValueError('Invalid handled alarm dates')
        try:
            handled_dates = [date.fromisoformat(value) for value in stored]
        except ValueError as exc:
            raise ValueError('Invalid handled alarm dates') from exc
        if not alarm['on']:
            continue
        zone_key = alarm.get('zone')
        if zone_key is not None and (not isinstance(zone_key, str) or not zone_key):
            raise ValueError('Invalid alarm time zone')
        zone = ZoneInfo(zone_key) if zone_key else system_zone
        if days:
            today = now.astimezone(zone).date()
            # A weekly rule always has a candidate within seven days.
            dates = [today - timedelta(days=offset) for offset in range(10)]
            dates = [day for day in dates if (day.weekday() + 1) % 7 in days]
            occurrence = latest_due_occurrence(alarm_id, hour, minute, zone, dates, since, now, handled_dates)
        else:
            # A one-shot alarm can occur only once, at its first opportunity.
            first_day = since.astimezone(zone).date()
            candidates = [latest_due_occurrence(alarm_id, hour, minute, zone,
                                                [first_day + timedelta(days=offset)], since, now, handled_dates)
                          for offset in range(-1, 3)]
            occurrence = min((item for item in candidates if item),
                             key=lambda item: (item.at_utc, item.local_date), default=None)
        if occurrence is None:
            continue
        new_handled.setdefault(alarm_id, []).append(occurrence.local_date.isoformat())
        if not days:
            alarm['on'] = False
        events.append({'eventId': occurrence.event_id, 'sessionId': alarm_id, 'kind': 'alarm',
                       'label': label, 'localDate': occurrence.local_date.isoformat(),
                       'zone': occurrence.zone, 'scheduledAt': occurrence.at_utc.isoformat(),
                       'status': occurrence.status, 'hour': hour, 'minute': minute,
                       'time': f'{hour:02d}:{minute:02d}', 'soundId': alarm.get('soundId', '')})
        if alarm.get('soundOptions') is not None:
            events[-1]['soundOptions'] = copy.deepcopy(alarm['soundOptions'])
    events.sort(key=lambda event: (event['scheduledAt'], event['eventId']))
    return new_alarms, new_handled, events
