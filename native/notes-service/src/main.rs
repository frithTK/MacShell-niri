use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::io::{self, BufRead, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

type Result<T> = std::result::Result<T, String>;
fn now() -> i64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as i64 }
fn uuid(s: &str) -> bool { s.len() == 36 && s.bytes().enumerate().all(|(i, b)| if [8,13,18,23].contains(&i) { b == b'-' } else { b.is_ascii_digit() || (b'a'..=b'f').contains(&b) }) }
fn string<'a>(v: &'a Value, key: &str) -> Result<&'a str> { v.get(key).and_then(Value::as_str).ok_or_else(|| format!("Invalid {key}.")) }
fn body(v: &Value) -> Result<&str> { let b = v.get("body").and_then(Value::as_str).ok_or("Note is too large.")?; if b.len() > 1024*1024 { return Err("Note is too large.".into()); } Ok(b) }
fn revision(v: &Value) -> Result<i64> { v.get("revision").and_then(Value::as_i64).filter(|v| *v >= 0 && *v < i64::MAX).ok_or_else(|| "Invalid revision.".into()) }
fn db_err(e: rusqlite::Error) -> String { e.to_string() }

fn open(path: &Path) -> Result<Connection> {
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or(Path::new("."));
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(parent).map_err(|e|e.to_string())?;
    let db = Connection::open(path).map_err(db_err)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).map_err(|e|e.to_string())?;
    db.busy_timeout(Duration::from_secs(5)).map_err(db_err)?;
    db.execute_batch("PRAGMA synchronous=FULL;").map_err(db_err)?;
    let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0)).map_err(db_err)?;
    if version > 1 { return Err("This notes database was created by a newer version.".into()); }
    if version == 0 { db.execute_batch("BEGIN IMMEDIATE; CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, body TEXT NOT NULL, revision INTEGER NOT NULL, updated INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0); PRAGMA user_version=1; COMMIT;").map_err(db_err)?; }
    db.execute_batch("CREATE TABLE IF NOT EXISTS sticky_session (id INTEGER PRIMARY KEY CHECK (id=1), windows TEXT NOT NULL);").map_err(db_err)?;
    Ok(db)
}

fn get(db: &Connection, id: &str) -> Result<Value> {
    db.query_row("SELECT id,body,revision,updated,deleted FROM notes WHERE id=?", [id], |r| Ok(json!({"id":r.get::<_,String>(0)?,"body":r.get::<_,String>(1)?,"revision":r.get::<_,i64>(2)?,"updated":r.get::<_,i64>(3)?,"deleted":r.get::<_,i64>(4)?}))).optional().map_err(db_err)?.ok_or_else(|| "Note no longer exists.".into())
}
fn list(db: &Connection, deleted: i64) -> Result<Value> {
    let mut stmt = db.prepare("SELECT id,body,revision,updated FROM notes WHERE deleted=? ORDER BY updated DESC,id").map_err(db_err)?;
    let rows = stmt.query_map([deleted], |r| Ok(json!({"id":r.get::<_,String>(0)?,"body":r.get::<_,String>(1)?,"revision":r.get::<_,i64>(2)?,"updated":r.get::<_,i64>(3)?}))).map_err(db_err)?;
    Ok(Value::Array(rows.collect::<std::result::Result<Vec<_>,_>>().map_err(db_err)?))
}
fn sticky(v: &Value) -> Result<()> {
    let windows = v.as_array().filter(|w| w.len() <= 100).ok_or("Invalid sticky window layout.")?;
    let mut seen = HashSet::new();
    for w in windows {
        if !w.is_object() { return Err("Invalid sticky window layout.".into()); }
        let id = w.get("id").and_then(Value::as_str).filter(|s| uuid(s)).ok_or("Invalid sticky note ID.")?;
        if !seen.insert(id) { return Err("Invalid sticky note ID.".into()); }
        for key in ["width","height","x","y","workspace"] { if let Some(n) = w.get(key).filter(|v| !v.is_null()) { if !n.as_i64().is_some_and(|n| (-100000..=100000).contains(&n)) { return Err("Invalid sticky window geometry.".into()); } } }
        if let Some(output) = w.get("output") { if !output.as_str().is_some_and(|s| s.chars().count() <= 256) { return Err("Invalid sticky window output.".into()); } }
    }
    Ok(())
}
fn handle(db: &Connection, action: &str, data: &Value) -> Result<Value> {
    match action {
        "list" => list(db, 0), "list-deleted" => list(db, 1),
        "list-stickies" => {
            let value: Option<String> = db.query_row("SELECT windows FROM sticky_session WHERE id=1", [], |r| r.get(0)).optional().map_err(db_err)?;
            let Some(text) = value else { return Ok(json!([])); };
            let value: Value = serde_json::from_str(&text).map_err(|_| "Saved sticky window layout is invalid.")?;
            sticky(&value).map_err(|_| "Saved sticky window layout is invalid.")?; Ok(value)
        },
        "save-stickies" => { let value = data.get("windows").ok_or("Invalid sticky window layout.")?; sticky(value)?; db.execute("INSERT INTO sticky_session(id,windows) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET windows=excluded.windows", [value.to_string()]).map_err(db_err)?; Ok(value.clone()) },
        "create" | "save-copy" => {
            let id = string(data,"id")?; if !uuid(id) { return Err("Invalid note ID.".into()); }
            let text = if action == "create" { "" } else { body(data)? };
            db.execute("INSERT OR IGNORE INTO notes(id,body,revision,updated) VALUES(?,?,0,?)", params![id,text,now()]).map_err(db_err)?;
            let note = get(db,id)?;
            if action == "save-copy" && (note["deleted"] != 0 || note["body"] != text) { return Err("Copy ID is already in use.".into()); }
            Ok(note)
        },
        "save" => {
            let id = string(data,"id")?; let text = body(data)?; let rev = revision(data)?;
            let count = db.execute("UPDATE notes SET body=?,revision=revision+1,updated=? WHERE id=? AND revision=? AND deleted=0", params![text,now(),id,rev]).map_err(db_err)?;
            let note = get(db,id)?;
            if count == 0 && !(note["deleted"] == 0 && note["body"] == text) { return Err("Note changed elsewhere; your unsaved text is still in the editor.".into()); }
            Ok(note)
        },
        "delete" | "restore" => {
            let id = string(data,"id")?; let rev = revision(data)?; let deleted = i64::from(action == "delete");
            let count = db.execute("UPDATE notes SET deleted=?,revision=revision+1,updated=? WHERE id=? AND revision=? AND deleted=?", params![deleted,now(),id,rev,1-deleted]).map_err(db_err)?;
            let note = get(db,id)?;
            if count == 0 && !(note["deleted"] == deleted && note["revision"] == rev+1) { return Err("Note changed elsewhere; reload before changing it.".into()); }
            Ok(note)
        },
        _ => Err("Unknown operation.".into()),
    }
}
fn emit(v: Value) { println!("{v}"); let _ = io::stdout().flush(); }
fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args == ["--protocol-version"] { println!("macshell-notes-service 1"); return; }
    if args.len() != 2 || args[0] != "--store" { eprintln!("Expected --store PATH"); std::process::exit(2); }
    let db = match open(Path::new(&args[1])) { Ok(v) => v, Err(e) => { emit(json!({"type":"unavailable","error":e})); std::process::exit(1); } };
    emit(json!({"type":"hello"}));
    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break; };
        let request = serde_json::from_str::<Value>(&line).unwrap_or(Value::Null);
        let result = handle(&db, request["action"].as_str().unwrap_or(""), &request["data"]);
        let response = match result { Ok(v) => json!({"type":"result","success":true,"result":v,"id":request["id"],"generation":request["generation"]}), Err(e) => json!({"type":"result","success":false,"error":e,"id":request["id"],"generation":request["generation"]}) };
        emit(response);
    }
}
