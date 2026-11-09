import json
import os
from pathlib import Path
import select
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'MacShell'))
from reminders_service import RemindersStore


class RustRemindersTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='reminders-rust-build-'); cls.addClassCleanup(cls.build.cleanup)
        subprocess.run(['cargo', 'build', '--offline', '--locked', '--manifest-path', str(ROOT / 'native/reminders-service/Cargo.toml'), '--target-dir', cls.build.name], check=True, timeout=120)
        cls.binary = Path(cls.build.name) / 'debug/macshell-reminders-service'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.path = self.root / 'data/tasks.sqlite3'
        self.bin = self.root / 'bin'; self.bin.mkdir()
        tool = self.bin / 'notify-send'; tool.write_text('#!/bin/sh\nprintf "%s\\n" "$4" >> "$TEST_ALERTS"\n'); tool.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin), TEST_ALERTS=str(self.root / 'alerts'), TZ='UTC')
        self.task = str(uuid.uuid4())

    def start(self):
        p = subprocess.Popen([str(self.binary), '--store', str(self.path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.env)
        self.addCleanup(self.stop, p)
        self.assertEqual(json.loads(p.stdout.readline())['type'], 'hello')
        return p

    @staticmethod
    def stop(p):
        if p.poll() is None: p.terminate()
        p.communicate(timeout=5)

    def request(self, p, action, **data):
        p.stdin.write(json.dumps({'id': 7, 'action': action, 'data': data}) + '\n'); p.stdin.flush()
        while True:
            value = json.loads(p.stdout.readline())
            if value['type'] == 'result': return value

    def test_python_database_roundtrip_and_repeating_task(self):
        store = RemindersStore(self.path); store.create_task(self.task, 'inbox', 'Задача'); store.close()
        p = self.start()
        self.assertEqual(self.request(p, 'load')['result']['tasks'][0]['title'], 'Задача')
        due = int(time.time() * 1000) + 3600000
        v = self.request(p, 'set-details', id=self.task, revision=0, title='Test', dueAt=due, repeat='daily')
        self.assertTrue(v['success'], v)
        completed = self.request(p, 'update', id=self.task, revision=1, field='done', value=True)
        self.assertTrue(completed['success'], completed)
        self.assertGreater(completed['result']['due_at'], due)
        retry = self.request(p, 'update', id=self.task, revision=1, field='done', value=True)
        self.assertEqual(retry['result']['revision'], completed['result']['revision'])
        self.stop(p)
        store = RemindersStore(self.path)
        try: self.assertEqual(store.task(self.task)['repeat_rule'], 'daily')
        finally: store.close()

    def test_scheduler_delivers_once_and_recovers_claims(self):
        store = RemindersStore(self.path); store.create_task(self.task, 'inbox', 'Test alert'); store.set_details(self.task, 0, 'Test alert', 1000); store.close()
        p = self.start()
        end = time.monotonic() + 5
        while time.monotonic() < end and not (self.root / 'alerts').exists(): time.sleep(.05)
        self.assertEqual((self.root / 'alerts').read_text().splitlines(), ['Test alert'])
        time.sleep(1.2)
        self.assertEqual((self.root / 'alerts').read_text().splitlines(), ['Test alert'])
        self.stop(p)
        db = sqlite3.connect(self.path); db.execute("UPDATE tasks SET alert_state='claimed',alert_token='old'"); db.commit(); db.close()
        p = self.start(); end = time.monotonic() + 5
        while time.monotonic() < end:
            result = self.request(p, 'load')['result']['tasks'][0]
            if result['alert_state'] == 'uncertain': break
            time.sleep(.1)
        self.assertEqual(result['alert_state'], 'uncertain')

    def test_migration_backups_and_future_schema(self):
        self.path.parent.mkdir()
        db = sqlite3.connect(self.path)
        db.executescript("CREATE TABLE lists(id TEXT PRIMARY KEY,name TEXT NOT NULL,revision INTEGER NOT NULL,created INTEGER NOT NULL); CREATE TABLE tasks(id TEXT PRIMARY KEY,list_id TEXT NOT NULL,title TEXT NOT NULL,done INTEGER NOT NULL DEFAULT 0,deleted INTEGER NOT NULL DEFAULT 0,revision INTEGER NOT NULL,updated INTEGER NOT NULL); INSERT INTO lists VALUES('inbox','',0,0); PRAGMA user_version=1;"); db.close()
        p = self.start(); self.assertEqual(self.request(p, 'load')['result']['lists'][0]['id'], 'inbox'); self.stop(p)
        backups = list(self.path.parent.glob('tasks.sqlite3.v1-*.bak')); self.assertEqual(len(backups), 1)
        old = sqlite3.connect(backups[0]); self.assertEqual(old.execute('PRAGMA user_version').fetchone()[0], 1); old.close()
        db = sqlite3.connect(self.path); db.execute('PRAGMA user_version=999'); db.close()
        result = subprocess.run([str(self.binary), '--store', str(self.path)], capture_output=True, text=True, env=self.env, timeout=5)
        self.assertIn('newer version', json.loads(result.stdout)['error'])


if __name__ == '__main__': unittest.main()
