import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'MacShell'))
import clock_snooze
from clock_timer import advance, migrate_legacy


class ClockSnoozeTests(unittest.TestCase):
    def setUp(self):
        self.timing = migrate_legacy({'state': 'idle', 'total': 5000, 'left': 5000},
                                     'boot-a', 1000, 900000, 'timer')
        self.event = {'eventId': 'alarm-event', 'sessionId': 'alarm-a', 'kind': 'alarm', 'label': 'Wake'}

    def test_due_uses_boot_time_and_fires_once(self):
        self.event['soundId'] = 'builtin-gentle-02'
        self.event['soundOptions'] = {'volume': 42, 'startMs': 3000}
        clock_snooze.schedule(self.timing, self.event, 'snooze-a', 'boot-a', 1000)
        early = advance(self.timing, 'boot-a', 1000 + clock_snooze.SNOOZE_MS - 1)
        self.assertIsNone(early['completion'])
        done = advance(early, 'boot-a', 1000 + clock_snooze.SNOOZE_MS, 1700000000000)
        self.assertEqual(done['completion']['label'], 'Wake')
        self.assertEqual(done['completion']['soundId'], 'builtin-gentle-02')
        self.assertEqual(done['completion']['soundOptions'], self.event['soundOptions'])
        self.assertEqual(done['completion']['occurredWallMs'], 1700000000000)
        self.assertEqual(done['snoozes'], [])
        self.assertEqual(advance(done, 'boot-a', 999999)['completion'], done['completion'])

    def test_reboot_records_missed_instead_of_ringing(self):
        clock_snooze.schedule(self.timing, self.event, 'snooze-a', 'boot-a', 1000)
        recovered = advance(self.timing, 'boot-b', 5000000)
        self.assertIsNone(recovered['completion'])
        self.assertEqual(recovered['snoozes'], [])
        self.assertEqual(recovered['missedSnoozes'][0]['id'], 'snooze-a')

    def test_snooze_cannot_replace_a_timer_event(self):
        with self.assertRaises(ValueError):
            clock_snooze.schedule(self.timing, {'kind': 'timer'}, 'id', 'boot-a', 1000)

    def test_legacy_recovery_keeps_unknown_fields_and_never_starts_automatically(self):
        originals = [{'at': 1100000, 'label': 'Wake', 'extra': {'keep': True}},
                     {'at': 0, 'label': 'Past'}]
        recovered = clock_snooze.migrate_legacy(originals, 1000000)
        self.assertEqual([entry['remainingMs'] for entry in recovered], [100000, 0])
        self.assertEqual(recovered[0]['legacy']['extra'], {'keep': True})
        self.timing['legacySnoozesRecovery'] = recovered
        after_reboot = advance(self.timing, 'boot-b', 2000)
        self.assertIsNone(after_reboot['completion'])
        self.assertEqual(len(after_reboot['legacySnoozesRecovery']), 2)
        resolved = clock_snooze.resolve_recovery(after_reboot, recovered[0]['id'], 'resume',
                                                 'command-a', 'boot-b', 2000)
        self.assertEqual(resolved['snoozes'][0]['deadlineBootMs'], 102000)
        self.assertEqual(resolved['snoozes'][0]['provenance'], 'legacy-wall-clock')
        discarded = clock_snooze.resolve_recovery(resolved, recovered[1]['id'], 'discard',
                                                  'command-b', 'boot-b', 2000)
        self.assertEqual(discarded['legacySnoozesRecovery'], [])
        self.assertIsNone(discarded['completion'])
        with self.assertRaises(ValueError):
            clock_snooze.resolve_recovery(discarded, recovered[1]['id'], 'resume', 'command-c', 'boot-b', 2000)

    def test_legacy_recovery_clamps_unreliable_wall_time(self):
        recovered = clock_snooze.migrate_legacy([{'at': 10**15}, {'at': 1}], 500000)
        self.assertEqual([entry['remainingMs'] for entry in recovered], [clock_snooze.SNOOZE_MS, 0])
        with self.assertRaises(ValueError):
            clock_snooze.migrate_legacy([{'at': True}], 500000)


if __name__ == '__main__':
    unittest.main()
