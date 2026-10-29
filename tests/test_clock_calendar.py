import sys
import unittest
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "MacShell"))
from clock_calendar import latest_due_occurrence, resolve_local_occurrence


UTC = timezone.utc


class ClockCalendarTests(unittest.TestCase):
    def test_spring_gap_moves_to_first_valid_time(self):
        zone = ZoneInfo("Europe/Berlin")
        self.assertEqual(resolve_local_occurrence(date(2026, 3, 29), 2, 45, zone),
                         datetime(2026, 3, 29, 1, 0, tzinfo=UTC))

    def test_fall_fold_uses_first_instant(self):
        zone = ZoneInfo("Europe/Berlin")
        self.assertEqual(resolve_local_occurrence(date(2026, 10, 25), 2, 30, zone),
                         datetime(2026, 10, 25, 0, 30, tzinfo=UTC))

    def test_non_hour_gap_and_skipped_day(self):
        self.assertEqual(resolve_local_occurrence(date(2026, 10, 4), 2, 15, ZoneInfo("Australia/Lord_Howe")),
                         datetime(2026, 10, 3, 15, 30, tzinfo=UTC))
        self.assertEqual(resolve_local_occurrence(date(2011, 12, 30), 12, 0, ZoneInfo("Pacific/Apia")),
                         datetime(2011, 12, 30, 10, 0, tzinfo=UTC))
        self.assertEqual(resolve_local_occurrence(date(1972, 1, 7), 0, 0, ZoneInfo("Africa/Monrovia")),
                         datetime(1972, 1, 7, 0, 44, 30, tzinfo=UTC))

    def test_catch_up_boundary_and_latest_of_multiple_misses(self):
        zone = ZoneInfo("UTC")
        dates = [date(2026, 10, 27), date(2026, 10, 28), date(2026, 10, 29)]
        since = datetime(2026, 10, 26, tzinfo=UTC)
        due_time = datetime(2026, 10, 29, 9, tzinfo=UTC)
        result = latest_due_occurrence("alarm", 9, 0, zone, dates, since, due_time + timedelta(minutes=15))
        self.assertEqual((result.local_date, result.status), (dates[-1], "due"))
        missed = latest_due_occurrence("alarm", 9, 0, zone, dates, since,
                                       due_time + timedelta(minutes=15, microseconds=1))
        self.assertEqual((missed.local_date, missed.status), (dates[-1], "missed"))
        self.assertEqual(result.event_id, missed.event_id)
        self.assertIsNone(latest_due_occurrence("alarm", 9, 0, zone, dates, since,
                                                due_time + timedelta(minutes=15), [dates[-1]]))

    def test_handled_date_survives_zone_or_time_change(self):
        day = date(2026, 10, 29)
        since = datetime(2026, 10, 28, tzinfo=UTC)
        now = datetime(2026, 10, 30, tzinfo=UTC)
        first = latest_due_occurrence("alarm", 9, 0, ZoneInfo("UTC"), [day], since, now)
        changed = latest_due_occurrence("alarm", 10, 0, ZoneInfo("Europe/Berlin"), [day], since, now)
        self.assertNotEqual(first.event_id, changed.event_id)
        self.assertIsNone(latest_due_occurrence("alarm", 10, 0, ZoneInfo("Europe/Berlin"),
                                                [day], since, now, handled_dates=[day]))

    def test_interval_boundaries_and_clock_rewind(self):
        day = date(2026, 10, 29)
        instant = datetime(2026, 10, 29, 9, tzinfo=UTC)
        zone = ZoneInfo("UTC")
        self.assertIsNone(latest_due_occurrence("a", 9, 0, zone, [day], instant, instant))
        self.assertIsNotNone(latest_due_occurrence("a", 9, 0, zone, [day], instant - timedelta(seconds=1), instant))
        with self.assertRaises(ValueError):
            latest_due_occurrence("a", 9, 0, zone, [day], instant, instant - timedelta(seconds=1))

    def test_rejects_invalid_input(self):
        with self.assertRaises(ValueError):
            resolve_local_occurrence(date(2026, 1, 1), True, 0, ZoneInfo("UTC"))
        with self.assertRaises(ValueError):
            latest_due_occurrence("a", 9, 0, ZoneInfo("UTC"), [], datetime(2026, 1, 1),
                                  datetime(2026, 1, 2, tzinfo=UTC))
        with self.assertRaises(ValueError):
            latest_due_occurrence("a", 24, 0, ZoneInfo("UTC"), [],
                                  datetime(2026, 1, 1, tzinfo=UTC), datetime(2026, 1, 2, tzinfo=UTC))


if __name__ == "__main__":
    unittest.main()
