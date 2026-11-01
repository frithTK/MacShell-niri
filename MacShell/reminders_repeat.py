"""Calendar-based repeat rules for local reminders."""
from calendar import monthrange
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from clock_calendar import resolve_local_occurrence

RULES = ('none', 'daily', 'weekly', 'monthly')


def repeat_fields(due_at, zone):
    local = datetime.fromtimestamp(due_at / 1000, timezone.utc).astimezone(zone)
    return (zone.key, local.date().isoformat(), local.day, local.hour, local.minute)


def next_occurrence(row, now_ms):
    """Return the first future scheduled occurrence after completion.

    Keep the nominal date and original wall-clock components separately so
    a DST gap or a shorter month does not permanently shift later reminders.
    """
    rule = row['repeat_rule']
    if rule not in RULES[1:]:
        raise ValueError('Invalid repeat rule')
    zone = ZoneInfo(row['repeat_zone'])
    current_day = date.fromisoformat(row['repeat_date'])
    threshold = max(row['due_at'], now_ms)
    after_day = datetime.fromtimestamp(threshold / 1000, timezone.utc).astimezone(zone).date()
    if rule in ('daily', 'weekly'):
        period = 1 if rule == 'daily' else 7
        steps = max(1, (after_day - current_day).days // period)
        candidate = current_day + timedelta(days=steps * period)
        def advance(day): return day + timedelta(days=period)
    else:
        steps = max(1, (after_day.year - current_day.year) * 12 + after_day.month - current_day.month)
        def month_after(day, count):
            month_index = day.year * 12 + day.month - 1 + count
            year, month = divmod(month_index, 12)
            month += 1
            return date(year, month, min(row['repeat_day'], monthrange(year, month)[1]))
        candidate = month_after(current_day, steps)
        def advance(day): return month_after(day, 1)
    while True:
        instant = resolve_local_occurrence(candidate, row['repeat_hour'], row['repeat_minute'], zone)
        instant_ms = int(instant.timestamp() * 1000)
        if instant_ms > threshold:
            return candidate.isoformat(), instant_ms
        candidate = advance(candidate)
