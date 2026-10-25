import importlib.util
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parents[1] / 'MacShell'))

spec = importlib.util.spec_from_file_location('modes', Path(__file__).parents[1] / 'MacShell/timed_modes.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


class TimedTests(unittest.TestCase):
    def test_duration_ignores_wall_clock_but_counts_suspend(self):
        value = m.create('60', 1000, 100, 'boot', 'session')
        self.assertEqual(m.remaining(value, 99999999, 160, 'boot'), 3540)
        self.assertEqual(m.remaining(value, -999999, 3701, 'boot'), 0)

    def test_focus_restores_across_boot_and_does_not_gain_time(self):
        value = m.create('60', 1000, 100, 'boot', 'session')
        restored = m.restore(value, 'focus', 2000, 10, 'boot2', 'session2')
        self.assertEqual(m.remaining(restored, 2000, 10, 'boot2'), 2600)
        self.assertEqual(m.restore(value, 'focus', 5000, 10, 'boot2', 'session2')['mode'], 'off')

    def test_awake_requires_same_confirmed_session(self):
        value = m.create('manual', 1000, 100, 'boot', 'session')
        for boot, session in [('boot', ''), ('boot', 'other'), ('other', 'session')]:
            self.assertEqual(m.restore(value, 'awake', 1000, 100, boot, session)['mode'], 'off')
        self.assertEqual(m.restore(value, 'awake', 1000, 100, 'boot', 'session')['mode'], 'manual')
        self.assertEqual(m.restore({'mode': 'manual'}, 'awake', 1000, 100, 'boot', 'session')['mode'], 'off')

    def test_evening_is_calendar_deadline(self):
        now = m.dt.datetime(2026, 10, 18, 20, 1).timestamp()
        self.assertEqual(m.dt.datetime.fromtimestamp(m.until_evening(now)), m.dt.datetime(2026, 10, 19, 20))
        value = m.create('evening', now, 1, 'boot', 'session')
        self.assertEqual(m.remaining(value, value['utc'] + 1, 2, 'boot'), 0)

    def test_unknown_state_is_off(self):
        for value in (None, True, {}, {'mode': 'garbage'}):
            self.assertEqual(m.restore(value, 'focus', 1, 1, 'b', 's')['mode'], 'off')

    def test_calendar_evening_obeys_dst_and_fixed_durations_do_not(self):
        import os
        import time
        from unittest.mock import patch
        with patch.dict(os.environ, {'TZ': 'Europe/Berlin'}):
            time.tzset()
            try:
                for month, day, hours in [(3, 28, 23), (10, 24, 25)]:
                    now = m.dt.datetime(2026, month, day, 20).timestamp()
                    self.assertEqual(m.until_evening(now) - now, hours * 3600)
                    duration = m.create('60', now, 50, 'b', 's')
                    self.assertEqual(m.remaining(duration, now + 100000, 51, 'b'), 3599)
            finally:
                pass
        time.tzset()

    def test_corrupt_deadlines_do_not_enable_a_mode(self):
        for value in ({'mode': '60', 'boot': 'b', 'utc': 'oops', 'deadline': 99}, {'mode': '60', 'boot': 'b', 'utc': 999, 'deadline': float('nan')}, {'mode': 'evening'}):
            self.assertEqual(m.restore(value, 'focus', 1, 1, 'b', 's')['mode'], 'off')
