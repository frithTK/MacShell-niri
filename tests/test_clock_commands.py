import copy
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'MacShell'))
from clock_commands import ClockCommandError, WINDOW_MS, execute
from clock_store import ClockStore, ClockStoreConflict
from clock_timer import migrate_legacy


class ClockCommandTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'clock.json'
        with ClockStore(self.path) as store:
            timing = migrate_legacy({'state': 'idle', 'total': 5000, 'left': 5000},
                                     'boot-a', 1000, 100000, 'legacy')
            store.commit({'timing': timing}, 'missing', 0)
        self.envelope = {'id': str(uuid.uuid4()), 'bootId': 'boot-a', 'issuedBootMs': 1100,
                         'revision': 1, 'action': 'start',
                         'args': {'sessionId': 'timer-a', 'durationMs': 5000, 'label': 'Tea'}}

    def test_replay_survives_owner_restart_without_restarting_timer(self):
        with ClockStore(self.path) as store:
            first = execute(store, self.envelope, 'boot-a', 1200, 100000)
        with ClockStore(self.path) as store:
            replay = execute(store, self.envelope, 'boot-a', 3000, 900000)
            doc, _ = store.read()
        self.assertEqual(replay, first)
        self.assertEqual(doc['revision'], 2)
        self.assertEqual(doc['timing']['timer']['deadlineBootMs'], 6200)
        self.assertEqual(doc['recents'], [5000])

    def test_recent_timer_preserves_its_own_sound_settings(self):
        options = {'volume': 35, 'fadeMs': 5000, 'startMs': 2000, 'durationMs': 10000, 'repeat': False}
        self.envelope['args'].update(soundId='builtin-chime-01', soundOptions=options)
        with ClockStore(self.path) as store:
            execute(store, self.envelope, 'boot-a', 1200, 100000)
            doc, _ = store.read()
            self.assertEqual(doc['timerPresets']['5000']['soundId'], 'builtin-chime-01')
            self.assertEqual(doc['timerPresets']['5000']['soundOptions'], options)

    def test_sound_options_reject_invalid_values_without_mutation(self):
        for bad in ({'volume': 101}, {'startMs': -1}, {'fadeMs': True}, {'repeat': 1}, {'durationMs': 600001}):
            with self.subTest(options=bad), ClockStore(self.path) as store:
                self.envelope['args']['soundOptions'] = bad
                with self.assertRaises(ValueError):
                    execute(store, self.envelope, 'boot-a', 1200, 100000)
                self.assertEqual(store.read()[0]['revision'], 1)

    def test_id_reuse_conflict_and_revision_conflict(self):
        with ClockStore(self.path) as store:
            execute(store, self.envelope, 'boot-a', 1200, 100000)
            changed = copy.deepcopy(self.envelope)
            changed['args']['durationMs'] = 10000
            with self.assertRaises(ClockCommandError):
                execute(store, changed, 'boot-a', 1300, 100000)
            changed['id'] = str(uuid.uuid4())
            with self.assertRaises(ClockStoreConflict):
                execute(store, changed, 'boot-a', 1300, 100000)
            self.assertEqual(store.read()[0]['revision'], 2)

    def test_old_or_other_boot_command_never_executes(self):
        with ClockStore(self.path) as store:
            with self.assertRaises(ClockCommandError):
                execute(store, self.envelope, 'boot-a', 1100 + WINDOW_MS + 1, 100000)
            with self.assertRaises(ClockCommandError):
                execute(store, self.envelope, 'boot-b', 1200, 100000)
            with self.assertRaises(ClockCommandError):
                execute(store, self.envelope, 'boot-a', 1099, 100000)
            self.assertEqual(store.read()[0]['revision'], 1)

    def test_full_journal_rejects_without_evicting_live_results(self):
        with ClockStore(self.path) as store:
            document, token = store.read()
            record = {'id': '', 'bootId': 'boot-a', 'issuedBootMs': 1000, 'hash': 'x', 'result': {}}
            journal = [dict(record, id=str(uuid.uuid4())) for _ in range(1024)]
            store.commit({'commandResults': journal}, token, document['revision'])
            self.envelope['revision'] = 2
            with self.assertRaises(ClockCommandError):
                execute(store, self.envelope, 'boot-a', 1200, 100000)
            document, _ = store.read()
            self.assertEqual(len(document['commandResults']), 1024)
            self.assertEqual(document['revision'], 2)

    def test_expired_journal_entries_are_pruned(self):
        with ClockStore(self.path) as store:
            execute(store, self.envelope, 'boot-a', 1200, 100000)
            next_command = {'id': str(uuid.uuid4()), 'bootId': 'boot-a',
                            'issuedBootMs': 1101 + WINDOW_MS, 'revision': 2,
                            'action': 'cancel', 'args': {'sessionId': 'timer-a'}}
            execute(store, next_command, 'boot-a', 1101 + WINDOW_MS, 900000)
            document, _ = store.read()
            self.assertEqual([entry['id'] for entry in document['commandResults']], [next_command['id']])

    def test_expiry_and_command_result_are_persisted_together(self):
        with ClockStore(self.path) as store:
            execute(store, self.envelope, 'boot-a', 1200, 100000)
            pause = {'id': str(uuid.uuid4()), 'bootId': 'boot-a', 'issuedBootMs': 6200,
                     'revision': 2, 'action': 'pause', 'args': {'sessionId': 'timer-a'}}
            result = execute(store, pause, 'boot-a', 6200, 105000)
            self.assertEqual(result['timer']['state'], 'idle')
            self.assertEqual(result['timing']['completion']['sessionId'], 'timer-a')
        with ClockStore(self.path) as store:
            replay = execute(store, pause, 'boot-a', 6300, 999999)
            document, _ = store.read()
            self.assertEqual(replay, result)
            self.assertEqual(document['timing']['completion'], result['timing']['completion'])
            self.assertEqual(document['revision'], 3)

    def test_sound_claim_and_ordered_dismissal_are_persistent(self):
        with ClockStore(self.path) as store:
            document, token = store.read()
            timing = document['timing']
            timing['completion'] = {'eventId': 'event-a', 'sessionId': 'timer-a', 'label': 'A'}
            timing['completionQueue'] = [{'eventId': 'event-b', 'sessionId': 'timer-b', 'label': 'B'}]
            store.commit({'timing': timing}, token, document['revision'])
            claim = {'id': str(uuid.uuid4()), 'bootId': 'boot-a', 'issuedBootMs': 1100,
                     'revision': 2, 'action': 'claim-sound', 'args': {'eventId': 'event-a'}}
            result = execute(store, claim, 'boot-a', 1200, 100000)
            self.assertTrue(result['soundGranted'])
        with ClockStore(self.path) as store:
            self.assertEqual(execute(store, claim, 'boot-a', 1300, 100000), result)
            again = dict(claim, id=str(uuid.uuid4()), revision=3)
            self.assertFalse(execute(store, again, 'boot-a', 1400, 100000)['soundGranted'])
            dismiss = {'id': str(uuid.uuid4()), 'bootId': 'boot-a', 'issuedBootMs': 1400,
                       'revision': 4, 'action': 'dismiss-event', 'args': {'eventId': 'event-a'}}
            next_event = execute(store, dismiss, 'boot-a', 1500, 100000)['timing']['completion']
            self.assertEqual(next_event['eventId'], 'event-b')
            stale = dict(dismiss, id=str(uuid.uuid4()), revision=5)
            with self.assertRaises(ClockCommandError):
                execute(store, stale, 'boot-a', 1600, 100000)
            self.assertEqual(store.read()[0]['timing']['completion']['eventId'], 'event-b')

    def test_snooze_command_replays_without_adding_a_second_snooze(self):
        with ClockStore(self.path) as store:
            document, token = store.read()
            timing = document['timing']
            timing['completion'] = {'eventId': 'alarm-event', 'sessionId': 'alarm-a',
                                    'kind': 'alarm', 'label': 'Wake'}
            store.commit({'timing': timing}, token, document['revision'])
            envelope = {'id': str(uuid.uuid4()), 'bootId': 'boot-a', 'issuedBootMs': 1100,
                        'revision': 2, 'action': 'snooze', 'args': {'eventId': 'alarm-event'}}
            result = execute(store, envelope, 'boot-a', 1200, 100000)
            self.assertIsNone(result['timing']['completion'])
            self.assertEqual(len(result['timing']['snoozes']), 1)
        with ClockStore(self.path) as store:
            self.assertEqual(execute(store, envelope, 'boot-a', 1300, 100000), result)
            self.assertEqual(len(store.read()[0]['timing']['snoozes']), 1)

    def test_repeat_timer_acknowledges_event_and_starts_once(self):
        with ClockStore(self.path) as store:
            document, token = store.read()
            timing = document['timing']
            timing['timer']['soundId'] = 'builtin-chime-01'
            timing['timer']['soundOptions'] = {'volume': 40, 'fadeMs': 3000, 'repeat': False}
            timing['completion'] = {'eventId': 'timer-done', 'sessionId': 'old', 'kind': 'timer', 'label': 'Tea'}
            timing['completionQueue'] = [{'eventId': 'next', 'sessionId': 'alarm', 'kind': 'alarm', 'label': 'Wake'}]
            store.commit({'timing': timing}, token, document['revision'])
            envelope = {'id': str(uuid.uuid4()), 'bootId': 'boot-a', 'issuedBootMs': 1100,
                        'revision': 2, 'action': 'repeat-timer',
                        'args': {'eventId': 'timer-done', 'sessionId': 'repeat'}}
            result = execute(store, envelope, 'boot-a', 1200, 100000)
            self.assertEqual(result['timing']['timer']['sessionId'], 'repeat')
            self.assertEqual(result['timing']['timer']['deadlineBootMs'], 6200)
            self.assertEqual(result['timing']['timer']['soundId'], 'builtin-chime-01')
            self.assertEqual(result['timing']['timer']['soundOptions'], {'volume': 40, 'fadeMs': 3000, 'repeat': False})
            self.assertEqual(result['timing']['completion']['eventId'], 'next')
            self.assertEqual(execute(store, envelope, 'boot-a', 1300, 100001), result)
            self.assertEqual(store.read()[0]['revision'], 3)

    def test_missed_events_are_acknowledged_individually_and_idempotently(self):
        with ClockStore(self.path) as store:
            document, token = store.read()
            timing = document['timing']
            timing['missedAlarms'] = [{'eventId': 'missed-alarm', 'label': 'Meeting'}]
            timing['missedSnoozes'] = [{'id': 'missed-snooze', 'label': 'Wake'}]
            store.commit({'timing': timing}, token, document['revision'])
            envelope = {'id': str(uuid.uuid4()), 'bootId': 'boot-a', 'issuedBootMs': 1100,
                        'revision': 2, 'action': 'ack-missed',
                        'args': {'kind': 'alarm', 'eventId': 'missed-alarm'}}
            result = execute(store, envelope, 'boot-a', 1200, 100000)
            self.assertEqual(result['timing']['missedAlarms'], [])
            self.assertEqual(result['timing']['missedSnoozes'][0]['id'], 'missed-snooze')
            self.assertEqual(execute(store, envelope, 'boot-a', 1300, 100001), result)
            second = {'id': str(uuid.uuid4()), 'bootId': 'boot-a', 'issuedBootMs': 1200,
                      'revision': 3, 'action': 'ack-missed',
                      'args': {'kind': 'snooze', 'eventId': 'missed-snooze'}}
            self.assertEqual(execute(store, second, 'boot-a', 1300, 100001)['timing']['missedSnoozes'], [])

    def test_settings_patch_is_versioned_and_preserves_other_fields(self):
        with ClockStore(self.path) as store:
            document, token = store.read()
            store.commit({'extension': {'keep': 1}}, token, document['revision'])
            alarm = {'id': 'a', 'h': 9, 'm': 0, 'on': True, 'days': [1], 'label': ''}
            envelope = {'id': str(uuid.uuid4()), 'bootId': 'boot-a', 'issuedBootMs': 1100,
                        'revision': 2, 'action': 'patch-settings',
                        'args': {'patch': {'alarms': [alarm], 'cities': [{'name': 'London', 'tz': 'Europe/London'}],
                                           'recents': [60000]}}}
            result = execute(store, envelope, 'boot-a', 1200, 100000)
            document, _ = store.read()
            self.assertEqual(result['settings']['alarms'], [alarm])
            self.assertEqual(document['extension'], {'keep': 1})
            self.assertEqual(document['timing']['alarmCursorWallMs'], 100000)
            self.assertEqual(execute(store, envelope, 'boot-a', 1300, 200000), result)

    def test_pending_alarm_prevents_edit_from_dropping_occurrence(self):
        with ClockStore(self.path) as store:
            document, token = store.read()
            timing = document['timing']
            timing.update(alarmCursorWallMs=1793005199000, alarmCursorBootId='boot-a', handledAlarmDates={})
            alarm = {'id': 'a', 'h': 9, 'm': 0, 'on': True, 'days': [], 'label': ''}
            store.commit({'timing': timing, 'alarms': [alarm]}, token, document['revision'])
            envelope = {'id': str(uuid.uuid4()), 'bootId': 'boot-a', 'issuedBootMs': 1100,
                        'revision': 2, 'action': 'patch-settings', 'args': {'patch': {'alarms': []}}}
            with mock.patch('clock_commands.system_zone', return_value=ZoneInfo('UTC')):
                with self.assertRaises(ClockStoreConflict):
                    execute(store, envelope, 'boot-a', 1200, 1793005230000)
            document, _ = store.read()
            self.assertEqual(document['alarms'], [alarm])
            self.assertEqual(document['revision'], 2)


if __name__ == '__main__':
    unittest.main()
