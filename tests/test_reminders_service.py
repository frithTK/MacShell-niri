import os
import sqlite3
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid
from contextlib import closing
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'MacShell'))
from reminders_service import RemindersError, RemindersStore


class RemindersStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'reminders/tasks.sqlite3'
        self.store = RemindersStore(self.path)
        self.addCleanup(self.store.close)
        self.task = str(uuid.uuid4())
        self.list_id = str(uuid.uuid4())

    def test_lists_tasks_and_completion_survive_restart(self):
        self.store.create_list(self.list_id, 'Работа')
        row = self.store.create_task(self.task, self.list_id, 'Купить чай 🌿')
        self.store.update(self.task, row['revision'], 'done', True)
        again = RemindersStore(self.path)
        try:
            data = again.snapshot()
            self.assertEqual([x['name'] for x in data['lists']], ['', 'Работа'])
            self.assertEqual((data['tasks'][0]['title'], data['tasks'][0]['done']), ('Купить чай 🌿', 1))
            self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        finally: again.close()

    def test_retries_after_commit_do_not_duplicate_or_toggle_twice(self):
        self.store.create_list(self.list_id, 'Личное')
        self.store.create_list(self.list_id, 'Личное')
        self.store.create_task(self.task, self.list_id, 'Тест')
        self.store.create_task(self.task, self.list_id, 'Тест')
        first = self.store.update(self.task, 0, 'done', True)
        self.assertEqual(self.store.update(self.task, 0, 'done', True)['revision'], first['revision'])
        self.assertEqual(len(self.store.snapshot()['tasks']), 1)

    def test_stale_update_does_not_overwrite_newer_edit(self):
        self.store.create_task(self.task, 'inbox', 'Исходная')
        other = RemindersStore(self.path)
        try:
            other.update(self.task, 0, 'title', 'Новое название')
            with self.assertRaises(RemindersError): self.store.update(self.task, 0, 'title', 'Старый черновик')
            self.assertEqual(self.store.task(self.task)['title'], 'Новое название')
        finally: other.close()

    def test_deleted_task_can_be_restored_and_stale_writes_fail(self):
        self.store.create_task(self.task, 'inbox', 'Задача')
        deleted = self.store.update(self.task, 0, 'deleted', True)
        self.assertEqual(self.store.snapshot()['tasks'], [])
        self.assertEqual(self.store.snapshot()['deletedTasks'][0]['id'], self.task)
        with self.assertRaises(RemindersError): self.store.update(self.task, 0, 'done', True)
        restored = self.store.update(self.task, deleted['revision'], 'deleted', False)
        self.assertEqual(restored['title'], 'Задача')
        self.assertEqual(len(self.store.snapshot()['tasks']), 1)

    def test_invalid_input_and_future_version_do_not_overwrite(self):
        with self.assertRaises(RemindersError): self.store.create_task(self.task, 'inbox', '   ')
        with self.assertRaises(RemindersError): self.store.create_task(self.task, 'missing', 'Task')
        self.assertEqual(self.store.snapshot()['tasks'], [])
        self.store.db.execute('PRAGMA user_version=999')
        with self.assertRaises(RemindersError): RemindersStore(self.path)
        self.assertEqual(self.store.db.execute('PRAGMA user_version').fetchone()[0], 999)

    def test_deleted_list_retains_tasks_and_can_be_restored(self):
        lst = self.store.create_list(self.list_id, 'Дом')
        self.store.create_task(self.task, self.list_id, 'Вода')
        renamed = self.store.update_list(self.list_id, lst['revision'], 'name', 'Дела')
        deleted = self.store.update_list(self.list_id, renamed['revision'], 'deleted', True)
        self.assertEqual(self.store.snapshot()['tasks'], [])
        self.assertEqual(self.store.snapshot()['deletedLists'][0]['id'], self.list_id)
        with self.assertRaises(RemindersError): self.store.update(self.task, 0, 'done', True)
        self.store.update_list(self.list_id, deleted['revision'], 'deleted', False)
        self.assertEqual(self.store.snapshot()['tasks'][0]['title'], 'Вода')
        with self.assertRaises(RemindersError): self.store.update_list('inbox', 0, 'deleted', True)

    def test_v1_migration_preserves_lists_and_tasks(self):
        legacy = Path(self.temp.name) / 'legacy.sqlite3'
        db = sqlite3.connect(legacy)
        db.executescript('''CREATE TABLE lists(id TEXT PRIMARY KEY, name TEXT NOT NULL, revision INTEGER NOT NULL, created INTEGER NOT NULL);
                            CREATE TABLE tasks(id TEXT PRIMARY KEY, list_id TEXT NOT NULL REFERENCES lists(id), title TEXT NOT NULL,
                                               done INTEGER NOT NULL, deleted INTEGER NOT NULL, revision INTEGER NOT NULL, updated INTEGER NOT NULL);
                            INSERT INTO lists VALUES('inbox','',0,0);
                            INSERT INTO tasks VALUES('existing','inbox','keep',1,0,2,5);
                            PRAGMA user_version=1;''')
        db.close()
        migrated = RemindersStore(legacy)
        try:
            self.assertEqual(migrated.snapshot()['tasks'][0]['title'], 'keep')
            self.assertEqual(migrated.db.execute('PRAGMA user_version').fetchone()[0], 4)
        finally: migrated.close()
        backups = list(legacy.parent.glob('legacy.sqlite3.v1-*.bak'))
        self.assertEqual(len(backups), 1)
        with closing(sqlite3.connect(backups[0])) as saved, saved:
            self.assertEqual(saved.execute('PRAGMA user_version').fetchone()[0], 1)
            self.assertEqual(saved.execute('SELECT title FROM tasks').fetchone()[0], 'keep')

    def test_deleted_items_remain_recoverable_after_service_restart(self):
        self.store.create_list(self.list_id, 'Дом')
        self.store.create_task(self.task, 'inbox', 'Вернуть')
        self.store.update(self.task, 0, 'deleted', True)
        self.store.update_list(self.list_id, 0, 'deleted', True)
        reopened = RemindersStore(self.path)
        try:
            snapshot = reopened.snapshot()
            self.assertEqual(snapshot['deletedLists'][0]['id'], self.list_id)
            self.assertEqual(snapshot['deletedTasks'][0]['id'], self.task)
            reopened.update_list(self.list_id, snapshot['deletedLists'][0]['revision'], 'deleted', False)
            reopened.update(self.task, snapshot['deletedTasks'][0]['revision'], 'deleted', False)
            self.assertEqual(reopened.snapshot()['tasks'][0]['title'], 'Вернуть')
        finally: reopened.close()

    def test_migration_stops_if_backup_cannot_be_synced(self):
        legacy = Path(self.temp.name) / 'unsynced.sqlite3'
        with closing(sqlite3.connect(legacy)) as db, db:
            db.executescript('''CREATE TABLE lists(id TEXT PRIMARY KEY, name TEXT NOT NULL, revision INTEGER NOT NULL, created INTEGER NOT NULL);
                                CREATE TABLE tasks(id TEXT PRIMARY KEY, list_id TEXT NOT NULL, title TEXT NOT NULL,
                                                   done INTEGER NOT NULL, deleted INTEGER NOT NULL, revision INTEGER NOT NULL, updated INTEGER NOT NULL);
                                INSERT INTO lists VALUES('inbox','',0,0);
                                INSERT INTO tasks VALUES('existing','inbox','keep',0,0,0,0);
                                PRAGMA user_version=1;''')
        with patch('reminders_service.os.fsync', side_effect=OSError('disk failure')):
            with self.assertRaisesRegex(OSError, 'disk failure'): RemindersStore(legacy)
        with closing(sqlite3.connect(legacy)) as db, db:
            self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], 1)
            self.assertEqual(db.execute('SELECT title FROM tasks').fetchone()[0], 'keep')

    def test_v2_backup_and_migration_exclude_concurrent_writers(self):
        legacy = Path(self.temp.name) / 'v2.sqlite3'
        with closing(sqlite3.connect(legacy)) as db, db:
            db.executescript('''CREATE TABLE lists(id TEXT PRIMARY KEY, name TEXT NOT NULL, revision INTEGER NOT NULL, created INTEGER NOT NULL, deleted INTEGER NOT NULL);
                                CREATE TABLE tasks(id TEXT PRIMARY KEY, list_id TEXT NOT NULL, title TEXT NOT NULL,
                                                   done INTEGER NOT NULL, deleted INTEGER NOT NULL, revision INTEGER NOT NULL, updated INTEGER NOT NULL);
                                INSERT INTO lists VALUES('inbox','',0,0,0);
                                INSERT INTO tasks VALUES('existing','inbox','before',0,0,0,0);
                                PRAGMA user_version=2;''')
        entered = threading.Event(); release = threading.Event(); writer_done = threading.Event(); errors = []
        real_fsync = os.fsync
        def held_fsync(fd):
            if not entered.is_set():
                entered.set()
                if not release.wait(5): raise RuntimeError('migration test timed out')
            real_fsync(fd)
        def migrate():
            try:
                store = RemindersStore(legacy); store.close()
            except Exception as error: errors.append(error)
        def write():
            try:
                with closing(sqlite3.connect(legacy, timeout=5)) as db, db:
                    db.execute("UPDATE tasks SET title='after' WHERE id='existing'")
            except Exception as error: errors.append(error)
            finally: writer_done.set()
        with patch('reminders_service.os.fsync', side_effect=held_fsync):
            migration = threading.Thread(target=migrate); migration.start()
            try:
                self.assertTrue(entered.wait(5))
                writer = threading.Thread(target=write); writer.start()
                self.assertFalse(writer_done.wait(.15), 'writer must wait until backup and migration finish')
            finally:
                release.set(); migration.join(5)
            writer.join(5)
        self.assertFalse(errors, errors)
        self.assertTrue(writer_done.is_set())
        with closing(sqlite3.connect(legacy)) as db, db:
            self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], 4)
            self.assertEqual(db.execute('SELECT title FROM tasks').fetchone()[0], 'after')
            self.assertEqual(db.execute('SELECT due_at,alert_state FROM tasks').fetchone(), (None, 'none'))
        backup = next(legacy.parent.glob('v2.sqlite3.v2-*.bak'))
        with closing(sqlite3.connect(backup)) as db, db:
            self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], 2)
            self.assertEqual(db.execute('SELECT title FROM tasks').fetchone()[0], 'before')

    def test_due_time_validation_and_idempotent_update(self):
        self.store.create_task(self.task, 'inbox', 'Task')
        for invalid in (True, -1, 253402300800000, 'soon'):
            with self.assertRaises(RemindersError): self.store.set_details(self.task, 0, 'Task', invalid)
        self.assertEqual(self.store.task(self.task)['revision'], 0)
        saved = self.store.set_details(self.task, 0, 'Task', 10000)
        self.assertEqual(self.store.set_details(self.task, 0, 'Task', 10000)['revision'], saved['revision'])
        with self.assertRaises(RemindersError): self.store.set_details(self.task, 0, 'Other', 10000)
        cleared = self.store.set_details(self.task, saved['revision'], 'Task', None)
        self.assertEqual((cleared['due_at'], cleared['alert_state']), (None, 'none'))

    def test_monthly_repeat_keeps_original_day_and_is_retry_safe(self):
        zone = ZoneInfo('America/New_York')
        ms = lambda y, m, d, h: int(datetime(y, m, d, h, tzinfo=zone).timestamp() * 1000)
        self.store.create_task(self.task, 'inbox', 'Rent')
        with patch('reminders_service.system_zone', return_value=zone):
            saved = self.store.set_details(self.task, 0, 'Rent', ms(2028, 1, 31, 9), 'monthly')
        with patch('reminders_service.time.time_ns', return_value=ms(2028, 1, 31, 10) * 1000000):
            feb = self.store.update(self.task, saved['revision'], 'done', True)
            retried = self.store.update(self.task, saved['revision'], 'done', True)
        self.assertEqual((feb['due_at'], feb['done'], feb['alert_state']), (ms(2028, 2, 29, 9), 0, 'pending'))
        self.assertEqual(retried['revision'], feb['revision'])
        with patch('reminders_service.time.time_ns', return_value=ms(2028, 2, 29, 10) * 1000000):
            march = self.store.update(self.task, feb['revision'], 'done', True)
        self.assertEqual(march['due_at'], ms(2028, 3, 31, 9))
        with self.assertRaises(RemindersError): self.store.update(self.task, saved['revision'], 'done', True)

    def test_daily_repeat_handles_dst_gap_without_permanent_shift(self):
        zone = ZoneInfo('America/New_York')
        ms = lambda y, m, d, h, minute: int(datetime(y, m, d, h, minute, tzinfo=zone).timestamp() * 1000)
        self.store.create_task(self.task, 'inbox', 'Morning')
        with patch('reminders_service.system_zone', return_value=zone):
            saved = self.store.set_details(self.task, 0, 'Morning', ms(2026, 3, 7, 2, 30), 'daily')
        with patch('reminders_service.time.time_ns', return_value=ms(2026, 3, 7, 3, 0) * 1000000):
            gap = self.store.update(self.task, saved['revision'], 'done', True)
        self.assertEqual(gap['due_at'], ms(2026, 3, 8, 3, 0))
        with patch('reminders_service.time.time_ns', return_value=ms(2026, 3, 8, 4, 0) * 1000000):
            normal = self.store.update(self.task, gap['revision'], 'done', True)
        self.assertEqual(normal['due_at'], ms(2026, 3, 9, 2, 30))

    def test_repeat_skips_overdue_occurrences_and_preserves_zone_on_rename(self):
        zone = ZoneInfo('UTC')
        ms = lambda y, m, d: int(datetime(y, m, d, 9, tzinfo=zone).timestamp() * 1000)
        self.store.create_task(self.task, 'inbox', 'Weekly')
        with patch('reminders_service.system_zone', return_value=zone):
            saved = self.store.set_details(self.task, 0, 'Weekly', ms(2025, 1, 1), 'weekly')
        with patch('reminders_service.system_zone', return_value=ZoneInfo('Asia/Tokyo')):
            renamed = self.store.set_details(self.task, saved['revision'], 'Renamed', saved['due_at'], 'weekly')
        self.assertEqual(renamed['repeat_zone'], 'UTC')
        with patch('reminders_service.time.time_ns', return_value=ms(2025, 2, 15) * 1000000):
            next_task = self.store.update(self.task, renamed['revision'], 'done', True)
        self.assertEqual(next_task['due_at'], ms(2025, 2, 19))

    def test_repeat_requires_due_time_and_old_client_preserves_rule(self):
        self.store.create_task(self.task, 'inbox', 'Task')
        with self.assertRaises(RemindersError): self.store.set_details(self.task, 0, 'Task', None, 'daily')
        with self.assertRaises(RemindersError): self.store.set_details(self.task, 0, 'Task', 10000, 'hourly')
        with patch('reminders_service.system_zone', return_value=ZoneInfo('UTC')):
            saved = self.store.set_details(self.task, 0, 'Task', 10000, 'daily')
        old_client_edit = self.store.set_details(self.task, saved['revision'], 'New name', 10000)
        self.assertEqual(old_client_edit['repeat_rule'], 'daily')
        removed = self.store.set_details(self.task, old_client_edit['revision'], 'New name', None)
        self.assertEqual((removed['repeat_rule'], removed['due_at']), ('none', None))

    def test_v3_migration_preserves_pending_alert_and_creates_backup(self):
        legacy = Path(self.temp.name) / 'v3.sqlite3'
        with closing(sqlite3.connect(legacy)) as db, db:
            db.executescript('''CREATE TABLE lists(id TEXT PRIMARY KEY, name TEXT NOT NULL, revision INTEGER NOT NULL,
                                                   created INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE tasks(id TEXT PRIMARY KEY, list_id TEXT NOT NULL REFERENCES lists(id), title TEXT NOT NULL,
                    done INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL,
                    updated INTEGER NOT NULL, due_at INTEGER, alert_state TEXT NOT NULL DEFAULT 'none',
                    alert_token TEXT NOT NULL DEFAULT '', alert_retry_at INTEGER NOT NULL DEFAULT 0,
                    alert_error TEXT NOT NULL DEFAULT '', alert_resolution_id TEXT NOT NULL DEFAULT '', alert_resolution_retry INTEGER);
                INSERT INTO lists VALUES('inbox','',0,0,0);
                INSERT INTO tasks(id,list_id,title,revision,updated,due_at,alert_state) VALUES('existing','inbox','keep',2,5,9000,'pending');
                PRAGMA user_version=3;''')
        with closing(sqlite3.connect(legacy, isolation_level=None)) as old_service:
            migrated = RemindersStore(legacy)
            try:
                task = migrated.task('existing')
                self.assertEqual((task['due_at'], task['alert_state'], task['repeat_rule']), (9000, 'pending', 'none'))
                self.assertEqual(migrated.db.execute('PRAGMA quick_check').fetchone()[0], 'ok')
                old_service.execute("UPDATE tasks SET title='old client' WHERE id='existing'")
                self.assertEqual(migrated.task('existing')['title'], 'old client')
            finally: migrated.close()
        backup = next(legacy.parent.glob('v3.sqlite3.v3-*.bak'))
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        with closing(sqlite3.connect(backup)) as db, db:
            self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], 3)
            self.assertEqual(db.execute('SELECT title,due_at,alert_state FROM tasks').fetchone(), ('keep', 9000, 'pending'))
            self.assertEqual(db.execute('PRAGMA quick_check').fetchone()[0], 'ok')

    def test_repeat_dst_fold_uses_first_occurrence(self):
        zone = ZoneInfo('America/New_York')
        start = int(datetime(2026, 10, 31, 1, 30, tzinfo=zone).timestamp() * 1000)
        expected = int(datetime(2026, 11, 1, 1, 30, tzinfo=zone, fold=0).timestamp() * 1000)
        self.store.create_task(self.task, 'inbox', 'Morning')
        with patch('reminders_service.system_zone', return_value=zone):
            saved = self.store.set_details(self.task, 0, 'Morning', start, 'daily')
        with patch('reminders_service.time.time_ns', return_value=(start + 3600000) * 1000000):
            next_task = self.store.update(self.task, saved['revision'], 'done', True)
        self.assertEqual(next_task['due_at'], expected)

    def test_repeat_concurrent_clients_cannot_advance_twice(self):
        zone = ZoneInfo('UTC')
        start = int(datetime(2030, 1, 1, 9, tzinfo=zone).timestamp() * 1000)
        self.store.create_task(self.task, 'inbox', 'Concurrent')
        with patch('reminders_service.system_zone', return_value=zone):
            saved = self.store.set_details(self.task, 0, 'Concurrent', start, 'weekly')
        other = RemindersStore(self.path)
        try:
            with patch('reminders_service.time.time_ns', return_value=(start + 1000) * 1000000):
                first = self.store.update(self.task, saved['revision'], 'done', True)
                second = other.update(self.task, saved['revision'], 'done', True)
            self.assertEqual(first['due_at'], second['due_at'])
            self.assertEqual(first['revision'], second['revision'])
            self.assertEqual(first['repeat_date'], '2030-01-08')
        finally: other.close()


if __name__ == '__main__': unittest.main()
