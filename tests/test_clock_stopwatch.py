import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'MacShell'))
import clock_stopwatch as stopwatch
from clock_timer import checkpoint, restore


class ClockStopwatchTests(unittest.TestCase):
    def setUp(self):
        self.idle = stopwatch.migrate_legacy({'running': False, 'startAt': 0, 'acc': 0, 'laps': []},
                                              100, 100000, 'sw-a')

    def test_start_laps_pause_resume_and_reset(self):
        running = stopwatch.command(self.idle, 'start', 1000, 'sw-a')
        lap = stopwatch.command(running, 'lap', 2400, 'sw-a')
        lap = stopwatch.command(lap, 'lap', 3100, 'sw-a')
        self.assertEqual(lap['laps'], [2100, 1400])
        paused = stopwatch.command(lap, 'pause', 3600, 'sw-a')
        self.assertEqual(paused['elapsedCheckpointMs'], 2600)
        resumed = stopwatch.command(paused, 'start', 5000, 'sw-a')
        self.assertEqual(stopwatch.elapsed(resumed, 6200), 3800)
        paused = stopwatch.command(resumed, 'pause', 6200, 'sw-a')
        reset = stopwatch.command(paused, 'reset', 6300, 'sw-a')
        self.assertEqual((reset['state'], reset['elapsedCheckpointMs'], reset['laps']), ('idle', 0, []))

    def test_wall_clock_projection_does_not_change_elapsed(self):
        running = stopwatch.command(self.idle, 'start', 1000, 'sw-a')
        first = stopwatch.legacy_projection(running, 3500, 90000)
        second = stopwatch.legacy_projection(running, 3500, 9000000)
        self.assertEqual((first['acc'], second['acc']), (2500, 2500))
        self.assertEqual((first['startAt'], second['startAt']), (90000, 9000000))

    def test_checkpoint_survives_reboot_and_requires_decision(self):
        running = stopwatch.command(self.idle, 'start', 1000, 'sw-a')
        running = stopwatch.command(running, 'lap', 1800, 'sw-a')
        timing = {'version': 1, 'bootId': 'boot-a', 'stopwatch': running,
                  'timer': {'state': 'idle', 'sessionId': 'timer', 'totalMs': 5000,
                            'remainingCheckpointMs': 5000, 'checkpointBootMs': 100,
                            'label': ''}, 'completion': None}
        timing = checkpoint(timing, 'boot-a', 3000)
        reboot = restore(timing, 'boot-b', 200)
        recovered = reboot['stopwatch']
        self.assertEqual((recovered['state'], recovered['elapsedCheckpointMs'], recovered['laps']),
                         ('recovery', 2000, [800]))
        self.assertTrue(stopwatch.legacy_projection(recovered, 200, 200000)['recoveryRequired'])
        resumed = stopwatch.command(recovered, 'recover-resume', 300, 'sw-a')
        self.assertEqual(stopwatch.elapsed(resumed, 700), 2400)
        reset = stopwatch.command(recovered, 'reset', 300, 'sw-a')
        self.assertEqual((reset['state'], reset['laps']), ('idle', []))

    def test_migration_and_stale_session(self):
        legacy = {'running': True, 'startAt': 10000, 'acc': 1200, 'laps': [800]}
        migrated = stopwatch.migrate_legacy(legacy, 1000, 13000, 'sw-a')
        self.assertEqual(stopwatch.elapsed(migrated, 1500), 4700)
        self.assertEqual(migrated['laps'], [800])
        with self.assertRaises(stopwatch.StopwatchError):
            stopwatch.command(migrated, 'pause', 1500, 'stale')
        with self.assertRaises(stopwatch.StopwatchError):
            stopwatch.elapsed(migrated, 999)

    def test_checkpoint_wall_time_is_metadata_only(self):
        running = stopwatch.command(self.idle, 'start', 1000, 'sw-a', 100000)
        saved = stopwatch.checkpoint(running, 2500, 900000)
        self.assertEqual(saved['checkpointWallMs'], 900000)
        self.assertEqual(saved['elapsedCheckpointMs'], 1500)
        self.assertEqual(stopwatch.elapsed(saved, 3000), 2000)


if __name__ == '__main__':
    unittest.main()
