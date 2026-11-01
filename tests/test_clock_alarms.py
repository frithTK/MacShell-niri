import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'MacShell'))
from clock_alarms import evaluate


def millis(year, month, day, hour=0, minute=0, second=0):
    return int(datetime(year, month, day, hour, minute, second, tzinfo=timezone.utc).timestamp() * 1000)


class ClockAlarmTests(unittest.TestCase):
    def test_daily_repeat_gap_fold_and_stable_handled_day(self):
        alarm = {'id': 'a', 'h': 2, 'm': 30, 'on': True, 'days': list(range(7)), 'label': 'Tea'}
        berlin = ZoneInfo('Europe/Berlin')
        _, handled, events = evaluate([alarm], {}, millis(2026, 3, 29, 0), millis(2026, 3, 29, 1, 5), berlin)
        self.assertEqual((events[0]['localDate'], events[0]['status'], events[0]['scheduledAt']),
                         ('2026-03-29', 'due', '2026-03-29T01:00:00+00:00'))
        _, _, repeat = evaluate([alarm], handled, millis(2026, 3, 29, 0), millis(2026, 3, 29, 1, 6), berlin)
        self.assertEqual(repeat, [])
        _, _, fold = evaluate([alarm], {}, millis(2026, 10, 25, 0), millis(2026, 10, 25, 0, 40), berlin)
        self.assertEqual(fold[0]['scheduledAt'], '2026-10-25T00:30:00+00:00')

    def test_latest_occurrence_and_one_shot_disable(self):
        weekly = {'id': 'weekly', 'h': 9, 'm': 0, 'on': True, 'days': [1], 'label': ''}
        once = {'id': 'once', 'h': 8, 'm': 0, 'on': True, 'days': [], 'label': 'Once'}
        alarms, handled, events = evaluate([weekly, once], {}, millis(2026, 9, 1),
                                           millis(2026, 10, 26, 9, 5), ZoneInfo('UTC'))
        self.assertEqual([(event['sessionId'], event['status']) for event in events],
                         [('once', 'missed'), ('weekly', 'due')])
        self.assertFalse(alarms[1]['on'])
        self.assertTrue(alarms[0]['on'])
        self.assertEqual(handled['once'], ['2026-09-01'])
        self.assertEqual(handled['weekly'], ['2026-10-26'])

    def test_rewind_and_zone_changes_do_not_repeat_handled_date(self):
        alarm = {'id': 'a', 'h': 9, 'm': 0, 'on': True, 'days': list(range(7)), 'label': ''}
        now = millis(2026, 10, 26, 10)
        _, handled, first = evaluate([alarm], {}, millis(2026, 10, 26, 7), now, ZoneInfo('UTC'))
        self.assertEqual(len(first), 1)
        _, _, rewind = evaluate([alarm], handled, now, millis(2026, 10, 26, 7), ZoneInfo('UTC'))
        self.assertEqual(rewind, [])
        _, _, changed = evaluate([alarm], handled, millis(2026, 10, 26, 6), now, ZoneInfo('Europe/Berlin'))
        self.assertEqual(changed, [])

    def test_invalid_alarm_data_is_rejected_without_mutation(self):
        alarms = [{'id': 'a', 'h': 9, 'm': 0, 'on': True, 'days': [0, 0], 'label': ''}]
        with self.assertRaises(ValueError):
            evaluate(alarms, {}, 0, 100000, ZoneInfo('UTC'))
        self.assertTrue(alarms[0]['on'])

    def test_alarm_event_keeps_selected_sound(self):
        alarm = {'id': 'a', 'h': 9, 'm': 0, 'on': True, 'days': [], 'label': 'Wake',
                 'soundId': 'builtin-melody-03', 'soundOptions': {'volume': 45, 'fadeMs': 5000, 'repeat': False}}
        _, _, events = evaluate([alarm], {}, millis(2026, 10, 26, 8, 59),
                                millis(2026, 10, 26, 9, 1), ZoneInfo('UTC'))
        self.assertEqual(events[0]['soundId'], 'builtin-melody-03')
        self.assertEqual(events[0]['soundOptions'], alarm['soundOptions'])
        alarm['soundId'] = '../invalid'
        with self.assertRaises(ValueError):
            evaluate([alarm], {}, millis(2026, 10, 26, 8, 59), millis(2026, 10, 26, 9, 1), ZoneInfo('UTC'))


if __name__ == '__main__':
    unittest.main()
