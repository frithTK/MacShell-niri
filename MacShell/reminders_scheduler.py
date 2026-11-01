"""One scheduler per database, with durable claims and explicit uncertain delivery."""
import fcntl
import os
from pathlib import Path
import subprocess
import uuid


def notify(title):
    try:
        result = subprocess.run(['notify-send', '-a', 'MacShell', '--', title],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        return 'delivered' if result.returncode == 0 else 'uncertain'
    except OSError:
        return 'not_started'
    except subprocess.TimeoutExpired:
        return 'uncertain'


class AlertScheduler:
    def __init__(self, store, path, sender=notify):
        self.store = store
        self.path = Path(str(path) + '.scheduler.lock')
        self.sender = sender
        self.fd = None
        self.owner = False
        self.recover_pending = False
        self.error = ''

    def acquire(self):
        if not self.owner:
            try:
                if self.fd is None: self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                self.error = ''
                return False
            except OSError:
                self.error = 'Reminder scheduler unavailable.'
                return False
            self.owner = True; self.recover_pending = True; self.error = ''
        if self.recover_pending:
            result = self.store.db.execute("UPDATE tasks SET alert_state='uncertain',alert_error='delivery_unknown' WHERE alert_state='claimed'")
            self.recover_pending = False
            return bool(result.rowcount)
        return False

    def tick(self, now_ms):
        changed = self.acquire()
        if not self.owner: return changed
        db = self.store.db
        db.execute('BEGIN IMMEDIATE')
        try:
            row = db.execute('''SELECT t.id,t.title,t.due_at FROM tasks t JOIN lists l ON l.id=t.list_id
                WHERE t.alert_state='pending' AND t.due_at IS NOT NULL AND t.due_at<=?
                AND t.alert_retry_at<=? AND t.done=0 AND t.deleted=0 AND l.deleted=0
                ORDER BY t.due_at,t.id LIMIT 1''', (now_ms, now_ms)).fetchone()
            if row is None:
                db.execute('COMMIT'); return changed
            token = uuid.uuid4().hex
            db.execute("UPDATE tasks SET alert_state='claimed',alert_token=? WHERE id=? AND alert_state='pending'", (token, row['id']))
            db.execute('COMMIT')
        except Exception:
            db.execute('ROLLBACK'); raise
        # Another client may have completed, deleted or rescheduled the task.
        current = db.execute('''SELECT t.*,l.deleted AS list_deleted FROM tasks t JOIN lists l ON l.id=t.list_id
                                WHERE t.id=?''', (row['id'],)).fetchone()
        if not current or current['alert_token'] != token or current['alert_state'] != 'claimed':
            return True
        if current['done'] or current['deleted'] or current['list_deleted']:
            db.execute("UPDATE tasks SET alert_state='pending',alert_token='' WHERE id=? AND alert_token=?", (row['id'], token))
            return True
        outcome = self.sender(current['title'])
        if outcome not in ('delivered', 'not_started', 'uncertain'): outcome = 'uncertain'
        state = {'delivered': 'delivered', 'not_started': 'pending', 'uncertain': 'uncertain'}[outcome]
        error = {'delivered': '', 'not_started': 'notification_failed', 'uncertain': 'delivery_unknown'}[outcome]
        db.execute('''UPDATE tasks SET alert_state=?,alert_token='',alert_retry_at=?,alert_error=?
                      WHERE id=? AND alert_state='claimed' AND alert_token=?''',
                   (state, now_ms + 30000 if outcome == 'not_started' else 0, error, row['id'], token))
        return True

    def close(self):
        if self.fd is not None:
            if self.owner: fcntl.flock(self.fd, fcntl.LOCK_UN)
            os.close(self.fd)
        self.fd = None; self.owner = False; self.recover_pending = False
