import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import uuid
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'MacShell'))
from reminders_service import RemindersError, RemindersStore
from reminders_scheduler import AlertScheduler, notify


class ReminderSchedulerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'tasks.sqlite3'
        self.store = RemindersStore(self.path); self.addCleanup(self.store.close)
        self.task = str(uuid.uuid4())
        self.store.create_task(self.task, 'inbox', 'Test reminder')
        self.sent = []
        self.scheduler = AlertScheduler(self.store, self.path, lambda text: self.sent.append(text) or 'delivered')
        self.addCleanup(self.scheduler.close)

    def due(self, timestamp=10000):
        return self.store.set_details(self.task, 0, 'Test reminder', timestamp)

    def test_delivers_only_once_and_catches_up_after_absence(self):
        self.due()
        self.scheduler.tick(9999); self.assertEqual(self.sent, [])
        self.scheduler.tick(20000); self.assertEqual(self.sent, ['Test reminder'])
        self.scheduler.tick(30000); self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.store.task(self.task)['alert_state'], 'delivered')
        self.scheduler.close()
        other = AlertScheduler(self.store, self.path, lambda text: self.sent.append(text) or 'delivered')
        try: other.tick(40000); self.assertEqual(len(self.sent), 1)
        finally: other.close()

    def test_completed_or_deleted_task_does_not_notify(self):
        row = self.due()
        self.store.update(self.task, row['revision'], 'done', True)
        self.scheduler.tick(20000); self.assertEqual(self.sent, [])
        current = self.store.task(self.task)
        self.store.update(self.task, current['revision'], 'done', False)
        self.scheduler.tick(21000); self.assertEqual(len(self.sent), 1)

    def test_only_one_scheduler_and_crash_yields_explicit_uncertain_state(self):
        row = self.due(); self.scheduler.tick(1)
        other_store = RemindersStore(self.path)
        other = AlertScheduler(other_store, self.path, lambda text: self.sent.append(text) or 'delivered')
        try:
            other.tick(20000); self.assertEqual(self.sent, [])
            self.store.db.execute("UPDATE tasks SET alert_state='claimed',alert_token='dead' WHERE id=?", (self.task,))
            self.scheduler.close(); other.tick(20000)
            self.assertEqual(other_store.task(self.task)['alert_state'], 'uncertain')
            self.assertEqual(self.sent, [])
            other_store.resolve_alert(self.task, row['revision'], 10000, True, str(uuid.uuid4()))
            other.tick(20001); self.assertEqual(self.sent, ['Test reminder'])
        finally:
            other.close(); other_store.close()

    def test_standby_takes_over_pending_reminder_when_owner_exits(self):
        self.due(); self.scheduler.tick(1)
        other_store = RemindersStore(self.path)
        other = AlertScheduler(other_store, self.path, lambda text: self.sent.append(text) or 'delivered')
        try:
            other.tick(20000); self.assertEqual(self.sent, [])
            self.scheduler.close(); other.tick(20000)
            self.assertEqual(self.sent, ['Test reminder'])
            self.assertEqual(other_store.task(self.task)['alert_state'], 'delivered')
        finally:
            other.close(); other_store.close()

    def test_deleted_list_suppresses_alert_until_it_is_restored(self):
        list_id, task_id = str(uuid.uuid4()), str(uuid.uuid4())
        self.store.create_list(list_id, 'List')
        self.store.create_task(task_id, list_id, 'Other task')
        self.store.set_details(task_id, 0, 'Other task', 10000)
        deleted = self.store.update_list(list_id, 0, 'deleted', True)
        self.scheduler.tick(20000); self.assertEqual(self.sent, [])
        self.store.update_list(list_id, deleted['revision'], 'deleted', False)
        self.scheduler.tick(21000); self.assertEqual(self.sent, ['Other task'])

    def test_delivery_failure_waits_before_retry(self):
        self.due(); attempts = []
        self.scheduler.sender = lambda text: (attempts.append(text), 'delivered' if len(attempts) > 1 else 'not_started')[1]
        self.scheduler.tick(10000); self.assertEqual(len(attempts), 1)
        self.assertEqual(self.store.task(self.task)['alert_error'], 'notification_failed')
        self.scheduler.tick(39999); self.assertEqual(len(attempts), 1)
        self.scheduler.tick(40000); self.assertEqual(len(attempts), 2)
        self.assertEqual(self.store.task(self.task)['alert_state'], 'delivered')

    def test_rescheduling_during_send_does_not_mark_new_schedule_delivered(self):
        row = self.due()
        other = RemindersStore(self.path)
        try:
            self.scheduler.sender = lambda text: (other.set_details(self.task, row['revision'], text, 50000), 'delivered')[1]
            self.scheduler.tick(10000)
            current = self.store.task(self.task)
            self.assertEqual((current['due_at'], current['alert_state']), (50000, 'pending'))
        finally: other.close()

    def test_rename_does_not_rearm_delivery_but_new_due_does(self):
        row = self.due(); self.scheduler.tick(10000)
        renamed = self.store.set_details(self.task, row['revision'], 'Changed title', 10000)
        self.assertEqual(renamed['alert_state'], 'delivered')
        changed = self.store.set_details(self.task, renamed['revision'], 'Changed title', 20000)
        self.assertEqual(changed['alert_state'], 'pending')
        with self.assertRaises(RemindersError): self.store.set_details(self.task, row['revision'], 'Stale', 30000)

    def test_notification_title_is_a_single_argument_not_a_shell_command(self):
        with patch('reminders_scheduler.subprocess.run') as run:
            run.return_value.returncode = 0
            self.assertEqual(notify('-- $(do-not-run)'), 'delivered')
            command = run.call_args.args[0]
            self.assertEqual(command[-2:], ['--', '-- $(do-not-run)'])
            self.assertNotIn('shell', run.call_args.kwargs)

    def test_timeout_or_error_does_not_blindly_repeat_an_uncertain_delivery(self):
        self.due(); attempts = []
        self.scheduler.sender = lambda text: attempts.append(text) or 'uncertain'
        self.scheduler.tick(10000); self.scheduler.tick(50000)
        self.assertEqual(len(attempts), 1)
        self.assertEqual(self.store.task(self.task)['alert_state'], 'uncertain')
        with patch('reminders_scheduler.subprocess.run', side_effect=subprocess.TimeoutExpired('notify-send', 5)):
            self.assertEqual(notify('x'), 'uncertain')
        with patch('reminders_scheduler.subprocess.run', side_effect=FileNotFoundError()):
            self.assertEqual(notify('x'), 'not_started')

    def test_transient_recovery_error_is_retried_before_claiming_more(self):
        self.due()
        self.store.db.execute("UPDATE tasks SET alert_state='claimed',alert_token='dead' WHERE id=?", (self.task,))
        db = self.store.db
        class Flaky:
            failed = False
            def execute(self, sql, *args):
                if "SET alert_state='uncertain'" in sql and not self.failed:
                    self.failed = True
                    raise sqlite3.OperationalError('temporary error')
                return db.execute(sql, *args)
        self.scheduler.store = SimpleNamespace(db=Flaky())
        with self.assertRaises(sqlite3.OperationalError): self.scheduler.tick(20000)
        self.scheduler.tick(21000)
        self.assertEqual(self.store.task(self.task)['alert_state'], 'uncertain')
        self.assertEqual(self.sent, [])

    def test_replayed_user_decision_never_rearms_a_later_uncertain_delivery(self):
        row = self.due(); command = str(uuid.uuid4())
        self.scheduler.sender = lambda text: 'uncertain'
        self.scheduler.tick(10000)
        first = self.store.resolve_alert(self.task, row['revision'], 10000, True, command)
        self.scheduler.tick(11000)
        self.assertEqual(self.store.task(self.task)['alert_state'], 'uncertain')
        replay = self.store.resolve_alert(self.task, row['revision'], 10000, True, command)
        self.assertEqual((replay['revision'], replay['alert_state']), (first['revision'], 'uncertain'))
        next_command = str(uuid.uuid4())
        second = self.store.resolve_alert(self.task, replay['revision'], 10000, True, next_command)
        self.scheduler.tick(12000)
        with self.assertRaises(RemindersError):
            self.store.resolve_alert(self.task, row['revision'], 10000, True, command)
        self.assertEqual((self.store.task(self.task)['revision'], self.store.task(self.task)['alert_state']),
                         (second['revision'], 'uncertain'))

    def test_repeating_task_delivers_once_per_completed_occurrence(self):
        due = int(datetime(2030, 1, 1, 9, tzinfo=timezone.utc).timestamp() * 1000)
        next_due = int(datetime(2030, 1, 2, 9, tzinfo=timezone.utc).timestamp() * 1000)
        with patch('reminders_service.system_zone', return_value=ZoneInfo('UTC')):
            row = self.store.set_details(self.task, 0, 'Test reminder', due, 'daily')
        self.scheduler.tick(due); self.scheduler.tick(due + 1)
        self.assertEqual(len(self.sent), 1)
        with patch('reminders_service.time.time_ns', return_value=(due + 1000) * 1000000):
            completed = self.store.update(self.task, row['revision'], 'done', True)
            self.store.update(self.task, row['revision'], 'done', True)
        self.assertEqual((completed['due_at'], completed['alert_state']), (next_due, 'pending'))
        self.scheduler.tick(next_due - 1); self.assertEqual(len(self.sent), 1)
        self.scheduler.tick(next_due); self.scheduler.tick(next_due + 1)
        self.assertEqual(len(self.sent), 2)

    def test_completing_during_delivery_does_not_consume_next_occurrence(self):
        due = int(datetime(2030, 1, 1, 9, tzinfo=timezone.utc).timestamp() * 1000)
        next_due = int(datetime(2030, 1, 2, 9, tzinfo=timezone.utc).timestamp() * 1000)
        with patch('reminders_service.system_zone', return_value=ZoneInfo('UTC')):
            row = self.store.set_details(self.task, 0, 'Test reminder', due, 'daily')
        other = RemindersStore(self.path)
        try:
            def completing_sender(text):
                other.update(self.task, row['revision'], 'done', True)
                return 'delivered'
            self.scheduler.sender = completing_sender
            with patch('reminders_service.time.time_ns', return_value=(due + 1000) * 1000000):
                self.scheduler.tick(due)
            current = self.store.task(self.task)
            self.assertEqual((current['due_at'], current['alert_state'], current['alert_token']), (next_due, 'pending', ''))
        finally:
            other.close()


if __name__ == '__main__': unittest.main()
