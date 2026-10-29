"""Calendar calculations for the future Clock service.

This module has no side effects and is not yet connected to ClockApp.  Duration
timers and snoozes must use CLOCK_BOOTTIME, not these wall-clock functions.
"""

from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
import hashlib
import json
from zoneinfo import ZoneInfo


UTC = timezone.utc
CATCH_UP = timedelta(minutes=15)


def _validate_alarm_time(hour, minute):
    if type(hour) is not int or type(minute) is not int or not 0 <= hour <= 23 or not 0 <= minute <= 59:
        raise ValueError("invalid alarm time")


@dataclass(frozen=True)
class Occurrence:
    event_id: str
    alarm_id: str
    local_date: date
    zone: str
    at_utc: datetime
    status: str  # "due" or "missed"


def _valid_instants(local, zone):
    """Return the UTC instants that round-trip to this naive local time."""
    instants = set()
    for fold in (0, 1):
        instant = local.replace(tzinfo=zone, fold=fold).astimezone(UTC)
        if instant.astimezone(zone).replace(tzinfo=None) == local:
            instants.add(instant)
    return sorted(instants)


def resolve_local_occurrence(day, hour, minute, zone):
    """Resolve an alarm's local time, choosing the first fold or gap boundary.

    A skipped time is moved to the first valid local instant following the
    gap, including historical zone transitions that occurred between minutes.
    """
    if not isinstance(day, date) or isinstance(day, datetime):
        raise ValueError("day must be a date")
    _validate_alarm_time(hour, minute)
    if not isinstance(zone, ZoneInfo):
        raise ValueError("zone must be a ZoneInfo")
    local = datetime.combine(day, time(hour, minute))
    valid = _valid_instants(local, zone)
    if valid:
        return valid[0]

    # Gaps can span a whole day (for example, a change of date line). Search
    # forward by minute, then find the first valid second in the last minute.
    for offset in range(1, 2 * 24 * 60 + 1):
        candidate = local + timedelta(minutes=offset)
        valid = _valid_instants(candidate, zone)
        if valid:
            previous = candidate - timedelta(minutes=1)
            for second in range(1, 61):
                valid = _valid_instants(previous + timedelta(seconds=second), zone)
                if valid:
                    return valid[0]
    raise ValueError("no valid local time within two days")


def latest_due_occurrence(alarm_id, hour, minute, zone, local_dates,
                          since_utc, now_utc, handled_dates=()):
    """Find the latest occurrence in (since, now], unless already handled.

    The caller supplies the local dates matching the alarm's repeat rule and
    persists handled dates per alarm. The date remains the deduplication key
    across zone or rule changes; event IDs additionally identify the zone and
    requested local time. No prior occurrence is selected after a clock rewind.
    """
    if not isinstance(alarm_id, str) or not alarm_id:
        raise ValueError("alarm_id must be a nonempty string")
    _validate_alarm_time(hour, minute)
    if not isinstance(zone, ZoneInfo) or not zone.key:
        raise ValueError("zone must have a persistent key")
    if (not isinstance(since_utc, datetime) or since_utc.utcoffset() is None
            or not isinstance(now_utc, datetime) or now_utc.utcoffset() is None):
        raise ValueError("timestamps must be timezone-aware")
    since = since_utc.astimezone(UTC)
    now = now_utc.astimezone(UTC)
    if now < since:
        raise ValueError("clock rewind requires a new evaluation interval")
    best = None
    for day in set(local_dates):
        instant = resolve_local_occurrence(day, hour, minute, zone)
        if since < instant <= now and (best is None or (instant, day) > (best[0], best[1])):
            best = instant, day
    if best is None or best[1] in set(handled_dates):
        return None
    instant, day = best
    identity = json.dumps([alarm_id, day.isoformat(), zone.key, hour, minute],
                          ensure_ascii=False, separators=(",", ":"))
    event_id = hashlib.sha256(identity.encode("utf-8")).hexdigest()
    return Occurrence(event_id, alarm_id, day, zone.key, instant,
                      "due" if now - instant <= CATCH_UP else "missed")
