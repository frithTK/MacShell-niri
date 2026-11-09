use chrono::NaiveDate;
use macshell_reminders_service::{next_occurrence, repeat_fields, Repeat, Rule};
use rusqlite::{params, types::ValueRef, Connection, OptionalExtension};
use serde_json::{json, Map, Value};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub type Result<T> = std::result::Result<T, String>;
pub fn err(e: rusqlite::Error) -> String { e.to_string() }
pub fn now() -> i64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as i64 }
fn uuid(s: &str) -> bool { s.len()==36 && s.bytes().enumerate().all(|(i,b)| if [8,13,18,23].contains(&i) {b==b'-'} else {b.is_ascii_digit() || (b'a'..=b'f').contains(&b)}) }
fn id(v: &Value) -> Result<&str> { v.as_str().filter(|s|uuid(s)).ok_or_else(||"Invalid identifier.".into()) }
fn title(v: &Value) -> Result<&str> { v.as_str().filter(|s|!s.trim().is_empty() && s.chars().count()<=500 && !s.contains('\0')).map(str::trim).ok_or_else(||"Enter a non-empty title of up to 500 characters.".into()) }
fn revision(v: &Value) -> Result<i64> { v.as_i64().filter(|n|*n>=0 && *n<i64::MAX).ok_or_else(||"Invalid revision.".into()) }
pub fn row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    let mut out=Map::new();
    for i in 0..row.as_ref().column_count() {
        let key=row.as_ref().column_name(i)?.to_string();
        let value=match row.get_ref(i)? { ValueRef::Null=>Value::Null,ValueRef::Integer(v)=>json!(v),ValueRef::Real(v)=>json!(v),ValueRef::Text(v)=>json!(String::from_utf8_lossy(v)),ValueRef::Blob(_)=>Value::Null };
        out.insert(key,value);
    }
    Ok(Value::Object(out))
}
pub fn open(path:&Path)->Result<Connection> {
    let parent=path.parent().filter(|p|!p.as_os_str().is_empty()).unwrap_or(Path::new("."));
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(parent).map_err(|e|e.to_string())?;
    let db=Connection::open(path).map_err(err)?;
    std::fs::set_permissions(path,std::fs::Permissions::from_mode(0o600)).map_err(|e|e.to_string())?;
    db.busy_timeout(Duration::from_secs(5)).map_err(err)?;
    db.execute_batch("PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;").map_err(err)?;
    let version:i64=db.query_row("PRAGMA user_version",[],|r|r.get(0)).map_err(err)?;
    if version>4 {return Err("This task database was created by a newer version.".into());}
    if version==0 {
        db.execute_batch("BEGIN IMMEDIATE; CREATE TABLE IF NOT EXISTS lists (id TEXT PRIMARY KEY, name TEXT NOT NULL, revision INTEGER NOT NULL, created INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0); CREATE TABLE IF NOT EXISTS tasks (id TEXT PRIMARY KEY,list_id TEXT NOT NULL REFERENCES lists(id),title TEXT NOT NULL,done INTEGER NOT NULL DEFAULT 0,deleted INTEGER NOT NULL DEFAULT 0,revision INTEGER NOT NULL,updated INTEGER NOT NULL,due_at INTEGER,alert_state TEXT NOT NULL DEFAULT 'none',alert_token TEXT NOT NULL DEFAULT '',alert_retry_at INTEGER NOT NULL DEFAULT 0,alert_error TEXT NOT NULL DEFAULT '',alert_resolution_id TEXT NOT NULL DEFAULT '',alert_resolution_retry INTEGER,repeat_rule TEXT NOT NULL DEFAULT 'none',repeat_zone TEXT NOT NULL DEFAULT '',repeat_date TEXT NOT NULL DEFAULT '',repeat_day INTEGER NOT NULL DEFAULT 0,repeat_hour INTEGER NOT NULL DEFAULT 0,repeat_minute INTEGER NOT NULL DEFAULT 0,repeat_completed_revision INTEGER NOT NULL DEFAULT -1); INSERT OR IGNORE INTO lists(id,name,revision,created,deleted) VALUES('inbox','',0,0,0); PRAGMA user_version=4; COMMIT;").map_err(err)?;
    } else if version<4 {
        db.execute_batch("BEGIN IMMEDIATE").map_err(err)?;
        let current:i64=db.query_row("PRAGMA user_version",[],|r|r.get(0)).map_err(err)?;
        if current==4 {db.execute_batch("COMMIT").map_err(err)?;return Ok(db);}
        if current!=version {return Err("Database version changed during migration.".into());}
        let suffix=format!("{}-{}",std::process::id(),now());
        let backup=path.with_file_name(format!("{}.v{}-{}.bak",path.file_name().unwrap_or_default().to_string_lossy(),version,suffix));
        std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&backup).map_err(|e|e.to_string())?;
        let source=Connection::open(path).map_err(err)?;
        let mut dest=Connection::open(&backup).map_err(err)?;
        {let backup=rusqlite::backup::Backup::new(&source,&mut dest).map_err(err)?;backup.run_to_completion(128,Duration::from_millis(10),None).map_err(err)?;}
        drop(dest);drop(source);
        std::fs::File::open(&backup).and_then(|f|f.sync_all()).map_err(|e|e.to_string())?;
        std::fs::File::open(parent).and_then(|f|f.sync_all()).map_err(|e|e.to_string())?;
        if version==1 {db.execute_batch("ALTER TABLE lists ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0;").map_err(err)?;}
        if version<=2 {db.execute_batch("ALTER TABLE tasks ADD COLUMN due_at INTEGER; ALTER TABLE tasks ADD COLUMN alert_state TEXT NOT NULL DEFAULT 'none'; ALTER TABLE tasks ADD COLUMN alert_token TEXT NOT NULL DEFAULT ''; ALTER TABLE tasks ADD COLUMN alert_retry_at INTEGER NOT NULL DEFAULT 0; ALTER TABLE tasks ADD COLUMN alert_error TEXT NOT NULL DEFAULT ''; ALTER TABLE tasks ADD COLUMN alert_resolution_id TEXT NOT NULL DEFAULT ''; ALTER TABLE tasks ADD COLUMN alert_resolution_retry INTEGER;").map_err(err)?;}
        db.execute_batch("ALTER TABLE tasks ADD COLUMN repeat_rule TEXT NOT NULL DEFAULT 'none'; ALTER TABLE tasks ADD COLUMN repeat_zone TEXT NOT NULL DEFAULT ''; ALTER TABLE tasks ADD COLUMN repeat_date TEXT NOT NULL DEFAULT ''; ALTER TABLE tasks ADD COLUMN repeat_day INTEGER NOT NULL DEFAULT 0; ALTER TABLE tasks ADD COLUMN repeat_hour INTEGER NOT NULL DEFAULT 0; ALTER TABLE tasks ADD COLUMN repeat_minute INTEGER NOT NULL DEFAULT 0; ALTER TABLE tasks ADD COLUMN repeat_completed_revision INTEGER NOT NULL DEFAULT -1; PRAGMA user_version=4; COMMIT;").map_err(err)?;
    }
    Ok(db)
}
fn get(db:&Connection,table:&str,id:&str)->Result<Value> {
    db.query_row(&format!("SELECT * FROM {table} WHERE id=?"),[id],row).optional().map_err(err)?.ok_or_else(||if table=="tasks" {"Task no longer exists."} else {"List no longer exists."}.into())
}
fn rows(db:&Connection,sql:&str)->Result<Value> {let mut s=db.prepare(sql).map_err(err)?;let values=s.query_map([],row).map_err(err)?.collect::<std::result::Result<Vec<_>,_>>().map_err(err)?;Ok(json!(values))}
fn system_zone()->Result<String> {
    if let Ok(tz)=std::env::var("TZ") {let tz=tz.trim_start_matches(':');if !tz.is_empty(){let zone=if tz.starts_with('/') {let canonical=std::fs::canonicalize(tz).map_err(|_|"Cannot determine the reminder time zone.")?;canonical.strip_prefix("/usr/share/zoneinfo").map_err(|_|"Cannot determine the reminder time zone.")?.to_string_lossy().into_owned()}else{tz.into()};return if zone.parse::<chrono_tz::Tz>().is_ok(){Ok(zone)}else{Err("Cannot determine the reminder time zone.".into())};}}
    if let Ok(path)=std::fs::read_link("/etc/localtime") {let s=path.to_string_lossy();if let Some((_,zone))=s.split_once("zoneinfo/"){if zone.parse::<chrono_tz::Tz>().is_ok(){return Ok(zone.into());}}}
    if let Ok(zone)=std::fs::read_to_string("/etc/timezone") {let zone=zone.trim();if zone.parse::<chrono_tz::Tz>().is_ok(){return Ok(zone.into());}}
    Err("Cannot determine the reminder time zone.".into())
}
fn repeated(db:&Connection,task_id:&str,rev:i64)->Result<Option<Value>> {
    db.execute_batch("BEGIN IMMEDIATE").map_err(err)?;
    let result=(|| {
        let current=db.query_row("SELECT t.*,l.deleted AS list_deleted FROM tasks t JOIN lists l ON l.id=t.list_id WHERE t.id=?",[task_id],row).optional().map_err(err)?.ok_or("Task no longer exists.")?;
        if current["revision"]!=rev {
            if current["revision"]==rev+1 && current["repeat_completed_revision"]==rev && current["deleted"]==0 && current["list_deleted"]==0 {return Ok(Some(get(db,"tasks",task_id)?));}
            if current["repeat_rule"]=="none" {return Ok(None);}
            return Err("Task changed elsewhere; reload and try again.".into());
        }
        if current["repeat_rule"]=="none" || current["done"]!=0 {return Ok(None);}
        if current["deleted"]!=0 || current["list_deleted"]!=0 {return Err("Task changed elsewhere; reload and try again.".into());}
        let invalid=||"Cannot calculate the next reminder time.".to_string();
        let rule=match current["repeat_rule"].as_str(){Some("daily")=>Rule::Daily,Some("weekly")=>Rule::Weekly,Some("monthly")=>Rule::Monthly,_=>return Err(invalid())};
        let repeat=Repeat {rule,zone:current["repeat_zone"].as_str().ok_or_else(invalid)?.parse().map_err(|_|invalid())?,date:NaiveDate::parse_from_str(current["repeat_date"].as_str().ok_or_else(invalid)?,"%Y-%m-%d").map_err(|_|invalid())?,day:current["repeat_day"].as_u64().ok_or_else(invalid)? as u32,hour:current["repeat_hour"].as_u64().ok_or_else(invalid)? as u32,minute:current["repeat_minute"].as_u64().ok_or_else(invalid)? as u32,due_ms:current["due_at"].as_i64().ok_or_else(invalid)?};
        let (day,due)=next_occurrence(&repeat,now()).ok_or_else(invalid)?;
        db.execute("UPDATE tasks SET due_at=?,repeat_date=?,repeat_completed_revision=?,alert_state='pending',alert_token='',alert_retry_at=0,alert_error='',alert_resolution_id='',alert_resolution_retry=NULL,revision=revision+1,updated=? WHERE id=?",params![due,day.to_string(),rev,now(),task_id]).map_err(err)?;
        Ok(Some(get(db,"tasks",task_id)?))
    })();
    match result {Ok(v)=>{db.execute_batch("COMMIT").map_err(err)?;Ok(v)},Err(e)=>{let _=db.execute_batch("ROLLBACK");Err(e)}}
}

pub fn handle(db:&Connection,action:&str,d:&Value)->Result<Value> {
    match action {
        "load" => Ok(json!({"lists":rows(db,"SELECT * FROM lists WHERE deleted=0 ORDER BY created,id")?,"tasks":rows(db,"SELECT t.* FROM tasks t JOIN lists l ON l.id=t.list_id WHERE t.deleted=0 AND l.deleted=0 ORDER BY t.done,t.updated DESC,t.id")?,"deletedLists":rows(db,"SELECT * FROM lists WHERE deleted=1 ORDER BY created,id")?,"deletedTasks":rows(db,"SELECT t.* FROM tasks t JOIN lists l ON l.id=t.list_id WHERE t.deleted=1 AND l.deleted=0 ORDER BY t.updated DESC,t.id")?})),
        "create-list"=>{let id=id(&d["id"])?;let name=title(&d["name"])?;db.execute("INSERT OR IGNORE INTO lists(id,name,revision,created,deleted) VALUES(?,?,0,?,0)",params![id,name,now()]).map_err(err)?;let v=get(db,"lists",id)?;if v["name"]!=name || v["deleted"]!=0{return Err("List ID is already in use.".into());}Ok(v)},
        "create-task"=>{let task=id(&d["id"])?;let list=d["listId"].as_str().ok_or("Invalid list ID.")?;let name=title(&d["title"])?;let exists:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM lists WHERE id=? AND deleted=0)",[list],|r|r.get(0)).map_err(err)?;if !exists{return Err("List no longer exists.".into());}db.execute("INSERT OR IGNORE INTO tasks(id,list_id,title,done,deleted,revision,updated) SELECT ?,id,?,0,0,0,? FROM lists WHERE id=? AND deleted=0",params![task,name,now(),list]).map_err(err)?;let v=get(db,"tasks",task)?;if v["list_id"]!=list || v["title"]!=name || v["deleted"]!=0{return Err("Task ID is already in use.".into());}Ok(v)},
        "update-list"=>{
            let list=d["id"].as_str().ok_or("List no longer exists.")?;if list=="inbox"{return Err("The default list cannot be changed.".into());}let rev=revision(&d["revision"])?;
            let field=d["field"].as_str().unwrap_or("");let value=match field {"name"=>json!(title(&d["value"])?),"deleted"=>json!(d["value"].as_bool().ok_or("Invalid list state.")? as i64),_=>return Err("Unknown list field.".into())};
            let sql=format!("UPDATE lists SET {field}=?,revision=revision+1 WHERE id=? AND revision=?{}",if field=="name"{" AND deleted=0"}else{""});
            let count=if field=="name"{db.execute(&sql,params![value.as_str(),list,rev])}else{db.execute(&sql,params![value.as_i64(),list,rev])}.map_err(err)?;
            let v=get(db,"lists",list)?;if count==0 && !(v["revision"]==rev+1 && v[field]==value){return Err("List changed elsewhere; reload and try again.".into());}Ok(v)
        },
        "update"=>{
            let task=d["id"].as_str().ok_or("Task no longer exists.")?;let rev=revision(&d["revision"])?;let field=d["field"].as_str().unwrap_or("");
            let value=match field {"title"=>json!(title(&d["value"])?),"done"|"deleted"=>json!(d["value"].as_bool().ok_or("Invalid task state.")? as i64),_=>return Err("Unknown task field.".into())};
            if field=="done" && value==1 {if let Some(v)=repeated(db,task,rev)?{return Ok(v);}}
            let sql=format!("UPDATE tasks SET {field}=?,revision=revision+1,updated=? WHERE id=? AND revision=?{} AND EXISTS (SELECT 1 FROM lists WHERE lists.id=tasks.list_id AND lists.deleted=0)",if field=="deleted"{""}else{" AND deleted=0"});
            let count=if field=="title"{db.execute(&sql,params![value.as_str(),now(),task,rev])}else{db.execute(&sql,params![value.as_i64(),now(),task,rev])}.map_err(err)?;
            let v=get(db,"tasks",task)?;if count==0 && !(v["revision"]==rev+1 && v[field]==value){return Err("Task changed elsewhere; reload and try again.".into());}Ok(v)
        },
        "set-details"=>{
            let task=d["id"].as_str().ok_or("Task no longer exists.")?;let rev=revision(&d["revision"])?;let name=title(&d["title"])?;
            let due=if d["dueAt"].is_null(){None}else{Some(d["dueAt"].as_i64().filter(|v|(0..=253402300799999).contains(v)).ok_or("Invalid due time.")?)};
            let current=get(db,"tasks",task)?;let specified=d.get("repeat").filter(|v|!v.is_null()).map(|v|v.as_str().ok_or("Invalid repeat rule.")).transpose()?;
            if specified.is_some_and(|v| !["none","daily","weekly","monthly"].contains(&v)){return Err("Invalid repeat rule.".into());}
            let mut rule=specified.unwrap_or(current["repeat_rule"].as_str().unwrap_or("none"));
            if due.is_none(){if specified.is_some_and(|v|v!="none"){return Err("A repeating reminder needs a due time.".into());}rule="none";}
            let (zone,date,day,hour,minute)=if rule=="none"{(String::new(),String::new(),0,0,0)}else if current["due_at"]==json!(due) && current["repeat_rule"]==rule {(current["repeat_zone"].as_str().unwrap_or("").into(),current["repeat_date"].as_str().unwrap_or("").into(),current["repeat_day"].as_u64().unwrap_or(0) as u32,current["repeat_hour"].as_u64().unwrap_or(0) as u32,current["repeat_minute"].as_u64().unwrap_or(0) as u32)}else{let zone=system_zone()?;let tz=zone.parse().map_err(|_|"Cannot determine the reminder time zone.")?;let (date,day,hour,minute)=repeat_fields(due.unwrap(),tz).ok_or("Cannot determine the reminder time zone.")?;(zone,date.to_string(),day,hour,minute)};
            let changed=db.execute("UPDATE tasks SET title=?,alert_state=CASE WHEN due_at IS NOT ? THEN CASE WHEN ? IS NULL THEN 'none' ELSE 'pending' END ELSE alert_state END,alert_token=CASE WHEN due_at IS NOT ? THEN '' ELSE alert_token END,alert_error=CASE WHEN due_at IS NOT ? THEN '' ELSE alert_error END,alert_retry_at=CASE WHEN due_at IS NOT ? THEN 0 ELSE alert_retry_at END,alert_resolution_id=CASE WHEN due_at IS NOT ? THEN '' ELSE alert_resolution_id END,alert_resolution_retry=CASE WHEN due_at IS NOT ? THEN NULL ELSE alert_resolution_retry END,due_at=?,repeat_rule=?,repeat_zone=?,repeat_date=?,repeat_day=?,repeat_hour=?,repeat_minute=?,repeat_completed_revision=-1,revision=revision+1,updated=? WHERE id=? AND revision=? AND deleted=0 AND EXISTS (SELECT 1 FROM lists WHERE lists.id=tasks.list_id AND lists.deleted=0)",params![name,due,due,due,due,due,due,due,due,rule,zone,date,day,hour,minute,now(),task,rev]).map_err(err)?;
            let v=get(db,"tasks",task)?;if changed==0 && !(v["revision"]==rev+1 && v["title"]==name && v["due_at"]==json!(due) && v["repeat_rule"]==rule && v["deleted"]==0){return Err("Task changed elsewhere; reload and try again.".into());}Ok(v)
        },
        "resolve-alert"=>{
            let task=d["id"].as_str().ok_or("Task no longer exists.")?;let rev=d["revision"].as_i64().ok_or("Invalid alert request.")?;let due=d["dueAt"].as_i64().ok_or("Invalid alert request.")?;let retry=d["retry"].as_bool().ok_or("Invalid alert request.")?;let command=id(&d["commandId"])?;
            let changed=db.execute("UPDATE tasks SET alert_state=?,alert_token='',alert_retry_at=0,alert_error='',alert_resolution_id=?,alert_resolution_retry=?,revision=revision+1 WHERE id=? AND revision=? AND due_at=? AND alert_state='uncertain' AND deleted=0",params![if retry{"pending"}else{"delivered"},command,retry as i64,task,rev,due]).map_err(err)?;
            let v=get(db,"tasks",task)?;if changed==0 && !(v["due_at"]==due && v["alert_resolution_id"]==command && v["alert_resolution_retry"]==retry as i64){return Err("Reminder changed; reload before deciding.".into());}Ok(v)
        },
        _=>Err("Unknown operation.".into()),
    }
}
