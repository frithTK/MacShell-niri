use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::Path;
use std::sync::mpsc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

type Result<T> = std::result::Result<T, String>;
fn db_err(e: rusqlite::Error) -> String { e.to_string() }
fn now() -> i64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as i64 }
fn uuid(s: &str) -> bool { s.len() == 36 && s.bytes().enumerate().all(|(i,b)| if [8,13,18,23].contains(&i) { b == b'-' } else { b.is_ascii_digit() || (b'a'..=b'f').contains(&b) }) }
fn date(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len()!=10 || b[4]!=b'-' || b[7]!=b'-' || !b.iter().enumerate().all(|(i,b)| i==4 || i==7 || b.is_ascii_digit()) { return false; }
    let y: u32 = s[0..4].parse().unwrap_or(0); let m: usize = s[5..7].parse().unwrap_or(0); let d: u32 = s[8..10].parse().unwrap_or(0);
    if y==0 || !(1..=12).contains(&m) { return false; }
    let leap = y%4==0 && (y%100!=0 || y%400==0);
    d>0 && d <= [31,if leap {29} else {28},31,30,31,30,31,31,30,31,30,31][m-1]
}
struct Fields { title: String, all_day: i64, day: Option<String>, start: Option<i64>, end: Option<i64> }
fn fields(v: &Value) -> Result<Fields> {
    let title = v["title"].as_str().filter(|s| !s.trim().is_empty() && s.chars().count() <= 500 && !s.contains('\0')).ok_or("Enter a title of up to 500 characters.")?.trim().to_string();
    let all_day = v["allDay"].as_bool().ok_or("Invalid event type.")?;
    if all_day { let day = v["date"].as_str().filter(|s| date(s)).ok_or("Invalid event date.")?; Ok(Fields { title, all_day:1, day:Some(day.into()), start:None, end:None }) }
    else { let start = v["start"].as_i64().ok_or("The event end must be after its start.")?; let end = v["end"].as_i64().ok_or("The event end must be after its start.")?; if start<0 || start>=end || end>253402300799999 { return Err("The event end must be after its start.".into()); } Ok(Fields {title,all_day:0,day:None,start:Some(start),end:Some(end)}) }
}
fn open(path: &Path) -> Result<Connection> {
    let parent = path.parent().filter(|v| !v.as_os_str().is_empty()).unwrap_or(Path::new("."));
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(parent).map_err(|e|e.to_string())?;
    let db = Connection::open(path).map_err(db_err)?;
    std::fs::set_permissions(path,std::fs::Permissions::from_mode(0o600)).map_err(|e|e.to_string())?;
    db.busy_timeout(Duration::from_secs(5)).map_err(db_err)?;
    db.execute_batch("PRAGMA synchronous=FULL; BEGIN IMMEDIATE;").map_err(db_err)?;
    let version: i64 = db.query_row("PRAGMA user_version",[],|r|r.get(0)).map_err(db_err)?;
    if version>1 { return Err("This calendar database was created by a newer version.".into()); }
    if version==0 {
        let existing: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%')",[],|r|r.get(0)).map_err(db_err)?;
        if existing { return Err("Unrecognized calendar database.".into()); }
        db.execute_batch("CREATE TABLE events (id TEXT PRIMARY KEY, title TEXT NOT NULL, all_day INTEGER NOT NULL, day TEXT, start_ms INTEGER, end_ms INTEGER, deleted INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL DEFAULT 0, updated INTEGER NOT NULL); PRAGMA user_version=1;").map_err(db_err)?;
    }
    db.execute_batch("COMMIT;").map_err(db_err)?; Ok(db)
}
fn row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Value> { Ok(json!({"id":r.get::<_,String>(0)?,"title":r.get::<_,String>(1)?,"all_day":r.get::<_,i64>(2)?,"day":r.get::<_,Option<String>>(3)?,"start_ms":r.get::<_,Option<i64>>(4)?,"end_ms":r.get::<_,Option<i64>>(5)?,"deleted":r.get::<_,i64>(6)?,"revision":r.get::<_,i64>(7)?,"updated":r.get::<_,i64>(8)?})) }
fn event(db: &Connection,id: &str) -> Result<Value> { db.query_row("SELECT id,title,all_day,day,start_ms,end_ms,deleted,revision,updated FROM events WHERE id=?",[id],row).optional().map_err(db_err)?.ok_or_else(||"Event no longer exists.".into()) }
fn matches(v:&Value,f:&Fields)->bool { v["title"]==f.title && v["all_day"]==f.all_day && v["day"]==json!(f.day) && v["start_ms"]==json!(f.start) && v["end_ms"]==json!(f.end) }
fn handle(db: &Connection, action: &str, data: &Value) -> Result<Value> {
    if action=="load" {
        let mut stmt=db.prepare("SELECT id,title,all_day,day,start_ms,end_ms,deleted,revision,updated FROM events ORDER BY updated DESC,id").map_err(db_err)?;
        let rows=stmt.query_map([],row).map_err(db_err)?.collect::<std::result::Result<Vec<_>,_>>().map_err(db_err)?;
        let (deleted,events): (Vec<_>,Vec<_>)=rows.into_iter().partition(|v| v["deleted"]!=0);
        return Ok(json!({"events":events,"deleted":deleted}));
    }
    if !["create","update","delete"].contains(&action) { return Err("Unknown operation.".into()); }
    let id=data["id"].as_str().filter(|v|uuid(v)).ok_or("Invalid event identifier.")?;
    if action=="create" {
        let f=fields(data)?;
        db.execute("INSERT OR IGNORE INTO events(id,title,all_day,day,start_ms,end_ms,updated) VALUES(?,?,?,?,?,?,?)",params![id,f.title,f.all_day,f.day,f.start,f.end,now()]).map_err(db_err)?;
        let v=event(db,id)?; if v["deleted"]!=0 || !matches(&v,&f) { return Err("Event ID is already in use.".into()); } return Ok(v);
    }
    let rev=data["revision"].as_i64().filter(|v|*v>=0 && *v<i64::MAX).ok_or("Invalid event revision.")?;
    if action=="delete" {
        let deleted=data["deleted"].as_bool().ok_or("Invalid event state.")? as i64;
        let changed=db.execute("UPDATE events SET deleted=?,revision=revision+1,updated=? WHERE id=? AND revision=?",params![deleted,now(),id,rev]).map_err(db_err)?;
        let v=event(db,id)?; if changed==0 && !(v["revision"]==rev+1 && v["deleted"]==deleted) { return Err("Event changed elsewhere; reload and try again.".into()); } Ok(v)
    } else {
        let f=fields(data)?;
        let changed=db.execute("UPDATE events SET title=?,all_day=?,day=?,start_ms=?,end_ms=?,revision=revision+1,updated=? WHERE id=? AND revision=? AND deleted=0",params![f.title,f.all_day,f.day,f.start,f.end,now(),id,rev]).map_err(db_err)?;
        let v=event(db,id)?; if changed==0 && !(v["revision"]==rev+1 && v["deleted"]==0 && matches(&v,&f)) { return Err("Event changed elsewhere; reload and try again.".into()); } Ok(v)
    }
}
fn emit(v:Value) { println!("{v}"); let _=io::stdout().flush(); }
fn main() {
    let args:Vec<_>=std::env::args().skip(1).collect();
    if args==["--protocol-version"] { println!("macshell-calendar-service 1"); return; }
    if args.len()!=2 || args[0]!="--store" { eprintln!("Expected --store PATH"); std::process::exit(2); }
    let db=match open(Path::new(&args[1])) { Ok(v)=>v,Err(e)=>{emit(json!({"type":"unavailable","error":e}));std::process::exit(1);} };
    let mut version:i64=db.query_row("PRAGMA data_version",[],|r|r.get(0)).unwrap_or(0);
    let (tx,rx)=mpsc::channel(); std::thread::spawn(move || { for line in io::stdin().lock().lines() { match line { Ok(v)=>if tx.send(v).is_err(){break},Err(_)=>break } } });
    emit(json!({"type":"hello"}));
    loop {
        match rx.recv_timeout(Duration::from_secs(1)) {
            Ok(line)=>{ let request:Value=serde_json::from_str(&line).unwrap_or(Value::Null); let response=match handle(&db,request["action"].as_str().unwrap_or(""),&request["data"]) {Ok(v)=>json!({"type":"result","success":true,"result":v,"id":request["id"]}),Err(e)=>json!({"type":"result","success":false,"error":e,"id":request["id"]})}; emit(response); },
            Err(mpsc::RecvTimeoutError::Disconnected)=>break,
            Err(mpsc::RecvTimeoutError::Timeout)=>(),
        }
        if let Ok(next)=db.query_row("PRAGMA data_version",[],|r|r.get::<_,i64>(0)) { if next!=version {version=next;emit(json!({"type":"changed"}));} }
    }
}
