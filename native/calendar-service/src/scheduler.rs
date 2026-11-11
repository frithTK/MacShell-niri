use crate::store::{err, skip_stale_alerts, Result};
use rusqlite::{params, Connection, OptionalExtension};
use std::fs::{File, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub struct Scheduler { file: Option<File>, pub owner: bool, recover: bool, pub error: bool, lock_path: String, primed: bool }
impl Scheduler {
    pub fn new(path: &Path) -> Self {
        Self { file: None, owner: false, recover: false, error: false, lock_path: format!("{}.scheduler.lock", path.display()), primed: false }
    }
    pub fn tick(&mut self, db: &Connection, now: i64) -> Result<bool> {
        if !self.owner {
            if self.file.is_none() {
                match OpenOptions::new().read(true).write(true).create(true).truncate(false).mode(0o600).open(&self.lock_path) {
                    Ok(f) => self.file = Some(f),
                    Err(_) => { self.error = true; return Ok(false); }
                }
            }
            if unsafe { libc::flock(self.file.as_ref().unwrap().as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
                let e = std::io::Error::last_os_error();
                self.error = e.kind() != std::io::ErrorKind::WouldBlock;
                return Ok(false);
            }
            self.owner = true; self.recover = true; self.error = false;
        }
        let mut changed = false;
        if self.recover {
            changed = db.execute("UPDATE events SET alert_state='uncertain', alert_error='delivery_unknown' WHERE alert_state='claimed'", []).map_err(err)? > 0;
            self.recover = false;
        }
        if !self.primed {
            skip_stale_alerts(db, now)?;
            self.primed = true;
            changed = true;
        }
        db.execute_batch("BEGIN IMMEDIATE").map_err(err)?;
        let claim = (|| {
            let item = db.query_row("SELECT id, title, alert_next_ms FROM events WHERE alert_state='pending' AND alert_next_ms IS NOT NULL AND alert_next_ms<=? AND alert_retry_at<=? AND deleted=0 ORDER BY alert_next_ms,id LIMIT 1", params![now, now], |r| Ok((r.get::<_,String>(0)?, r.get::<_,String>(1)?, r.get::<_,i64>(2)?))).optional().map_err(err)?;
            if let Some((id, _, due)) = item {
                let token = format!("{:x}-{:x}", std::process::id(), due);
                db.execute("UPDATE events SET alert_state='claimed', alert_token=? WHERE id=? AND alert_state='pending' AND alert_next_ms=?", params![token, id, due]).map_err(err)?;
                return Ok(Some((id, token, due)));
            }
            Ok(None)
        })();
        let claim = match claim { Ok(v) => { db.execute_batch("COMMIT").map_err(err)?; v }, Err(e) => { let _ = db.execute_batch("ROLLBACK"); return Err(e); } };
        let Some((id, token, due)) = claim else { return Ok(changed) };
        let current = db.query_row("SELECT title, deleted, alert_token, alert_state, repeat_rule FROM events WHERE id=?", [&id], json_row).optional().map_err(err)?;
        let Some(v) = current else { return Ok(true) };
        if v["alert_token"] != token || v["alert_state"] != "claimed" { return Ok(true); }
        if v["deleted"] != 0 {
            db.execute("UPDATE events SET alert_state='pending', alert_token='' WHERE id=? AND alert_token=?", params![id, token]).map_err(err)?;
            return Ok(true);
        }
        let outcome = notify(v["title"].as_str().unwrap_or("Calendar"));
        let (state, error, retry) = match outcome {
            0 => ("delivered", "", 0i64),
            1 => ("pending", "notification_failed", now + 30_000),
            _ => ("uncertain", "delivery_unknown", 0),
        };
        if state == "delivered" {
            if v["repeat_rule"] == "none" {
                db.execute("UPDATE events SET alert_state='delivered', alert_token='', alert_retry_at=0, alert_error='', alert_next_ms=NULL WHERE id=? AND alert_token=?", params![id, token]).map_err(err)?;
            } else {
                let master = db.query_row("SELECT id,title,all_day,day,start_ms,end_ms,deleted,revision,updated,repeat_rule,repeat_zone,repeat_date,repeat_day,repeat_hour,repeat_minute,duration_ms,alert_state,alert_token,alert_retry_at,alert_error,alert_next_ms FROM events WHERE id=?", [&id], |r| Ok(serde_json::json!({
                    "id": r.get::<_,String>(0)?, "title": r.get::<_,String>(1)?, "all_day": r.get::<_,i64>(2)?,
                    "day": r.get::<_,Option<String>>(3)?, "start_ms": r.get::<_,Option<i64>>(4)?, "end_ms": r.get::<_,Option<i64>>(5)?,
                    "deleted": r.get::<_,i64>(6)?, "repeat_rule": r.get::<_,String>(9)?, "repeat_zone": r.get::<_,String>(10)?,
                    "repeat_date": r.get::<_,String>(11)?, "repeat_day": r.get::<_,i64>(12)?, "repeat_hour": r.get::<_,i64>(13)?,
                    "repeat_minute": r.get::<_,i64>(14)?, "duration_ms": r.get::<_,Option<i64>>(15)?
                }))).map_err(err)?;
                let next_ms = crate::store::next_alert(&master, due);
                db.execute("UPDATE events SET alert_state='pending', alert_token='', alert_retry_at=0, alert_error='', alert_next_ms=? WHERE id=? AND alert_token=?", params![next_ms, id, token]).map_err(err)?;
            }
        } else {
            db.execute("UPDATE events SET alert_state=?, alert_token='', alert_retry_at=?, alert_error=? WHERE id=? AND alert_state='claimed' AND alert_token=?", params![state, retry, error, id, token]).map_err(err)?;
        }
        Ok(true)
    }
}

fn json_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<serde_json::Value> {
    Ok(serde_json::json!({"title": r.get::<_,String>(0)?, "deleted": r.get::<_,i64>(1)?, "alert_token": r.get::<_,String>(2)?, "alert_state": r.get::<_,String>(3)?, "repeat_rule": r.get::<_,String>(4)?}))
}

fn notify(title: &str) -> u8 {
    let mut child = match Command::new("notify-send").args(["-a", "MacShell", "--", title]).stdout(Stdio::null()).stderr(Stdio::null()).spawn() { Ok(c) => c, Err(_) => return 1 };
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return if status.success() { 0 } else { 2 },
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            _ => { let _ = child.kill(); let _ = child.wait(); return 2 }
        }
    }
}
