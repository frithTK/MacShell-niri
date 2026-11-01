import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'MacShell'))
from clock_timer import TimerError, advance, checkpoint, command, legacy_projection, migrate_legacy, restore


class ClockTimerTests(unittest.TestCase):
    def setUp(self):
        self.initial = migrate_legacy({'state': 'idle', 'total': 5000, 'left': 5000, 'label': ''},
                                      'boot-a', 100, 100000, 'legacy')

    def start(self):
        return command(self.initial, 'start', 'boot-a', 1000, session_id='session-a',
                       duration_ms=5000, label='Tea')

    def test_pause_resume_uses_boottime_and_rejects_stale_session(self):
        started = self.start()
        paused = command(started, 'pause', 'boot-a', 2200, session_id='session-a')
        self.assertEqual(paused['timer']['remainingCheckpointMs'], 3800)
        resumed = command(paused, 'resume', 'boot-a', 10000, session_id='session-a')
        self.assertEqual(resumed['timer']['deadlineBootMs'], 13800)
        self.assertEqual(legacy_projection(resumed, 11000, 500000)['endAt'], 502800)
        self.assertEqual(legacy_projection(resumed, 11000, 200000)['left'], 2800)
        with self.assertRaises(TimerError):
            command(resumed, 'cancel', 'boot-a', 11000, session_id='old-session')

    def test_selected_sound_survives_pause_and_reboot_recovery(self):
        started = command(self.initial, 'start', 'boot-a', 1000, session_id='session-a',
                          duration_ms=5000, sound_id='builtin-chime-01', sound_options={'volume': 50, 'fadeMs': 10000})
        paused = command(started, 'pause', 'boot-a', 2000, session_id='session-a')
        recovered = restore(paused, 'boot-b', 200)
        resumed = command(recovered, 'recover-remainder', 'boot-b', 300, session_id='session-a')
        finished = advance(resumed, 'boot-b', 4300)
        self.assertEqual(finished['completion']['soundId'], 'builtin-chime-01')
        self.assertEqual(finished['completion']['soundOptions'], {'volume': 50, 'fadeMs': 10000})
        with self.assertRaises(TimerError):
            command(self.initial, 'start', 'boot-a', 1000, session_id='session-b', duration_ms=5000, sound_id='../bad')

    def test_expiry_wins_pause_race_and_event_is_stable(self):
        started = self.start()
        finished = command(started, 'pause', 'boot-a', 6000, session_id='session-a')
        self.assertEqual(finished['timer']['state'], 'idle')
        self.assertEqual(finished['completion']['sessionId'], 'session-a')
        self.assertEqual(advance(finished, 'boot-a', 9000)['completion'], finished['completion'])
        self.assertEqual(advance(started, 'boot-a', 7000)['completion'], finished['completion'])

    def test_unacknowledged_completion_is_not_overwritten(self):
        finished = advance(self.start(), 'boot-a', 6000)
        second = command(finished, 'start', 'boot-a', 7000, session_id='session-b', duration_ms=1000)
        second = command(second, 'pause', 'boot-a', 8000, session_id='session-b')
        self.assertEqual(second['completion']['sessionId'], 'session-a')
        self.assertEqual([event['sessionId'] for event in second['completionQueue']], ['session-b'])
        self.assertEqual(len(advance(second, 'boot-a', 9000)['completionQueue']), 1)

    def test_restart_same_boot_and_reboot_recovery(self):
        started = checkpoint(self.start(), 'boot-a', 2500)
        self.assertEqual(restore(started, 'boot-a', 3000)['timer']['deadlineBootMs'], 6000)
        recovered = restore(started, 'boot-b', 200)
        self.assertEqual(recovered['timer']['state'], 'recovery')
        self.assertEqual(recovered['timer']['remainingCheckpointMs'], 3500)
        self.assertTrue(legacy_projection(recovered, 200, 900000)['recoveryRequired'])
        resumed = command(recovered, 'recover-remainder', 'boot-b', 300, session_id='session-a')
        self.assertEqual(resumed['timer']['deadlineBootMs'], 3800)
        restarted = command(recovered, 'recover-restart', 'boot-b', 300, session_id='session-a')
        self.assertEqual(restarted['timer']['deadlineBootMs'], 5300)
        cancelled = command(recovered, 'cancel', 'boot-b', 300, session_id='session-a')
        self.assertEqual(cancelled['timer']['state'], 'idle')
        self.assertIsNone(cancelled['completion'])

    def test_checkpoint_records_wall_time_without_using_it_for_elapsed(self):
        started = command(self.initial, 'start', 'boot-a', 1000, session_id='session-a',
                          duration_ms=5000, wall_now=100000)
        saved = checkpoint(started, 'boot-a', 2500, 900000)
        self.assertEqual(saved['timer']['remainingCheckpointMs'], 3500)
        self.assertEqual(saved['timer']['checkpointWallMs'], 900000)
        self.assertEqual(restore(saved, 'boot-b', 100)['timer']['checkpointWallMs'], 900000)
        paused = command(started, 'pause', 'boot-a', 2500, session_id='session-a', wall_now=200000)
        self.assertEqual(paused['timer']['checkpointWallMs'], 200000)
        self.assertEqual(paused['timer']['remainingCheckpointMs'], 3500)

    def test_expired_recovery_finishes_only_after_explicit_resume(self):
        legacy = {'state': 'paused', 'total': 5000, 'left': 0, 'label': 'Tea'}
        timing = migrate_legacy(legacy, 'boot-a', 1000, 100000, 'saved')
        recovery = restore(timing, 'boot-b', 100)
        self.assertEqual(recovery['timer']['state'], 'recovery')
        self.assertIsNone(recovery['completion'])
        resumed = command(recovery, 'recover-remainder', 'boot-b', 200, session_id='saved', wall_now=200000)
        self.assertEqual(resumed['timer']['state'], 'idle')
        self.assertEqual(resumed['completion']['sessionId'], 'saved')

    def test_legacy_migration_clamps_once_and_retains_paused_remainder(self):
        legacy = {'state': 'running', 'total': 5000, 'endAt': 105000, 'left': 5000, 'label': 'Old'}
        timing = migrate_legacy(legacy, 'boot-a', 1000, 102000, 'migration')
        self.assertEqual(timing['timer']['deadlineBootMs'], 4000)
        self.assertEqual(timing['timer']['provenance'], 'legacy-wall-clock')
        self.assertEqual(restore(timing, 'boot-a', 2000)['timer']['deadlineBootMs'], 4000)
        expired = migrate_legacy(legacy, 'boot-a', 1000, 200000, 'migration')
        self.assertEqual(advance(expired, 'boot-a', 1000)['timer']['state'], 'idle')
        paused = migrate_legacy({'state': 'paused', 'total': 5000, 'left': 1500}, 'boot-a', 100, 900, 'p')
        self.assertEqual(paused['timer']['remainingCheckpointMs'], 1500)

    def test_explicit_replacement_validation_and_cancel(self):
        started = self.start()
        with self.assertRaises(TimerError):
            command(started, 'start', 'boot-a', 1200, session_id='b', duration_ms=1000)
        replacement = command(started, 'start', 'boot-a', 1200, session_id='b', duration_ms=1000, replace=True)
        self.assertEqual(replacement['timer']['sessionId'], 'b')
        with self.assertRaises(TimerError):
            command(started, 'start', 'boot-a', 1200, session_id='b', duration_ms=True, replace=True)
        with self.assertRaises(TimerError):
            command(started, 'start', 'boot-a', 1200, session_id='session-a', duration_ms=1000, replace=True)
        cancelled = command(started, 'cancel', 'boot-a', 1200, session_id='session-a')
        self.assertEqual(cancelled['timer']['state'], 'idle')
        self.assertIsNone(cancelled['completion'])
        self.assertEqual(command(cancelled, 'cancel', 'boot-a', 1300), cancelled)


if __name__ == '__main__':
    unittest.main()
