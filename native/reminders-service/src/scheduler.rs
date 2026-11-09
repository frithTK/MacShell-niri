use crate::store::{err, row, Result};
use rusqlite::{params, Connection, OptionalExtension};
use std::fs::{File, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub struct Scheduler { file: Option<File>, pub owner: bool, recover: bool, pub error: bool, lock_path: String }
impl Scheduler {
    pub fn new(path:&Path)->Self {Self {file:None,owner:false,recover:false,error:false,lock_path:format!("{}.scheduler.lock",path.display())}}
    pub fn tick(&mut self,db:&Connection,now:i64)->Result<bool> {
        if !self.owner {
            if self.file.is_none() { match OpenOptions::new().read(true).write(true).create(true).truncate(false).mode(0o600).open(&self.lock_path) {Ok(f)=>self.file=Some(f),Err(_)=>{self.error=true;return Ok(false)}} }
            if unsafe {libc::flock(self.file.as_ref().unwrap().as_raw_fd(),libc::LOCK_EX|libc::LOCK_NB)}!=0 {
                let e=std::io::Error::last_os_error();self.error=e.kind()!=std::io::ErrorKind::WouldBlock;return Ok(false);
            }
            self.owner=true;self.recover=true;self.error=false;
        }
        let mut changed=false;
        if self.recover {changed=db.execute("UPDATE tasks SET alert_state='uncertain',alert_error='delivery_unknown' WHERE alert_state='claimed'",[]).map_err(err)?>0;self.recover=false;}
        db.execute_batch("BEGIN IMMEDIATE").map_err(err)?;
        let claim=(|| {
            let item=db.query_row("SELECT t.id,t.title,t.due_at FROM tasks t JOIN lists l ON l.id=t.list_id WHERE t.alert_state='pending' AND t.due_at IS NOT NULL AND t.due_at<=? AND t.alert_retry_at<=? AND t.done=0 AND t.deleted=0 AND l.deleted=0 ORDER BY t.due_at,t.id LIMIT 1",params![now,now],row).optional().map_err(err)?;
            if let Some(ref v)=item {let token=format!("{:x}-{:x}",std::process::id(),now);db.execute("UPDATE tasks SET alert_state='claimed',alert_token=? WHERE id=? AND alert_state='pending'",params![token,v["id"].as_str()]).map_err(err)?;return Ok(Some((v["id"].as_str().unwrap().to_string(),token)));}Ok(None)
        })();
        let claim=match claim {Ok(v)=>{db.execute_batch("COMMIT").map_err(err)?;v},Err(e)=>{let _=db.execute_batch("ROLLBACK");return Err(e)}};
        let Some((id,token))=claim else{return Ok(changed)};
        let current=db.query_row("SELECT t.*,l.deleted AS list_deleted FROM tasks t JOIN lists l ON l.id=t.list_id WHERE t.id=?",[&id],row).optional().map_err(err)?;
        let Some(v)=current else{return Ok(true)};
        if v["alert_token"]!=token || v["alert_state"]!="claimed" {return Ok(true);}
        if v["done"]!=0 || v["deleted"]!=0 || v["list_deleted"]!=0 {db.execute("UPDATE tasks SET alert_state='pending',alert_token='' WHERE id=? AND alert_token=?",params![id,token]).map_err(err)?;return Ok(true);}
        let outcome=notify(v["title"].as_str().unwrap_or(""));
        let (state,error,retry)=match outcome {0=>("delivered","",0),1=>("pending","notification_failed",now+30000),_=>("uncertain","delivery_unknown",0)};
        db.execute("UPDATE tasks SET alert_state=?,alert_token='',alert_retry_at=?,alert_error=? WHERE id=? AND alert_state='claimed' AND alert_token=?",params![state,retry,error,id,token]).map_err(err)?;
        Ok(true)
    }
}
fn notify(title:&str)->u8 {
    let mut child=match Command::new("notify-send").args(["-a","MacShell","--",title]).stdout(Stdio::null()).stderr(Stdio::null()).spawn(){Ok(c)=>c,Err(_)=>return 1};
    let deadline=Instant::now()+Duration::from_secs(5);
    loop { match child.try_wait() {Ok(Some(status))=>return if status.success(){0}else{2},Ok(None) if Instant::now()<deadline=>std::thread::sleep(Duration::from_millis(20)),_=>{let _=child.kill();let _=child.wait();return 2}} }
}
