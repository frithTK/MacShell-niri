from datetime import datetime, timezone
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'MacShell'))
from reminders_repeat import next_occurrence


class RepeatCompatibilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='reminders-repeat-build-')
        cls.addClassCleanup(cls.temp.cleanup)
        subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path', str(ROOT / 'native/reminders-service/Cargo.toml'), '--target-dir', cls.temp.name, '--example', 'repeat'], check=True, timeout=120)
        cls.binary = Path(cls.temp.name) / 'debug/examples/repeat'

    def test_matches_python_for_dst_month_ends_and_late_completion(self):
        cases = [
            ('daily', 'America/New_York', '2026-03-07', 7, 2, 30, '2026-03-07T07:30:00', '2026-03-07T07:30:00'),
            ('daily', 'America/New_York', '2026-10-31', 31, 1, 30, '2026-10-31T05:30:00', '2026-10-31T05:30:00'),
            ('daily', 'Pacific/Apia', '2011-12-29', 29, 12, 0, '2011-12-29T22:00:00', '2011-12-29T22:00:00'),
            ('monthly', 'Europe/Berlin', '2026-01-31', 31, 9, 0, '2026-01-31T08:00:00', '2026-02-28T10:00:00'),
            ('weekly', 'UTC', '2026-01-01', 1, 9, 0, '2026-01-01T09:00:00', '2026-02-01T12:00:00'),
        ]
        for rule, zone, day, anchor, hour, minute, due, current in cases:
            with self.subTest(rule=rule, zone=zone, day=day):
                to_ms = lambda value: int(datetime.fromisoformat(value).replace(tzinfo=timezone.utc).timestamp() * 1000)
                row = {'repeat_rule': rule, 'repeat_zone': zone, 'repeat_date': day, 'repeat_day': anchor, 'repeat_hour': hour, 'repeat_minute': minute, 'due_at': to_ms(due)}
                expected_day, expected_ms = next_occurrence(row, to_ms(current))
                result = subprocess.run([str(self.binary), rule, zone, day, str(anchor), str(hour), str(minute), str(row['due_at']), str(to_ms(current))], text=True, capture_output=True, check=True, timeout=5)
                self.assertEqual(result.stdout.strip(), f'{expected_day} {expected_ms}')


if __name__ == '__main__': unittest.main()
