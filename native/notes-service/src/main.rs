use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::fs;
use std::io::{self, BufRead, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const MAX_BODY: usize = 1024 * 1024;
const MAX_ATTACH_BYTES: u64 = 20 * 1024 * 1024;
const MAX_ATTACH_COUNT: i64 = 20;
const MAX_ATTACH_NAME: usize = 255;

type Result<T> = std::result::Result<T, String>;
fn now() -> i64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as i64 }
fn uuid(s: &str) -> bool { s.len() == 36 && s.bytes().enumerate().all(|(i, b)| if [8,13,18,23].contains(&i) { b == b'-' } else { b.is_ascii_digit() || (b'a'..=b'f').contains(&b) }) }
fn string<'a>(v: &'a Value, key: &str) -> Result<&'a str> { v.get(key).and_then(Value::as_str).ok_or_else(|| format!("Invalid {key}.")) }
fn body(v: &Value) -> Result<&str> { let b = v.get("body").and_then(Value::as_str).ok_or("Note is too large.")?; if b.len() > MAX_BODY { return Err("Note is too large.".into()); } Ok(b) }
fn revision(v: &Value) -> Result<i64> { v.get("revision").and_then(Value::as_i64).filter(|v| *v >= 0 && *v < i64::MAX).ok_or_else(|| "Invalid revision.".into()) }
fn db_err(e: rusqlite::Error) -> String { e.to_string() }
fn format_of(v: &Value, fallback: &str) -> Result<String> {
    match v.get("format").and_then(Value::as_str) {
        None => Ok(fallback.into()),
        Some("plain") | Some("html") => Ok(v.get("format").and_then(Value::as_str).unwrap().into()),
        _ => Err("Invalid note format.".into()),
    }
}

fn map_tag(tag: &str) -> &str {
    match tag { "strong" => "b", "em" => "i", other => other }
}
fn allowed(tag: &str) -> bool { matches!(tag, "b"|"i"|"u"|"ul"|"ol"|"li"|"br"|"p"|"span") }
fn skip_tag(tag: &str) -> bool { matches!(tag, "script"|"style"|"iframe") }
fn markup_tag(tag: &str) -> bool { matches!(tag, "b"|"i"|"u"|"ul"|"ol"|"li"|"span") }

fn parse_tag(rest: &str) -> Option<(bool, String, usize)> {
    let bytes = rest.as_bytes();
    if bytes.is_empty() { return None; }
    let mut i = 0;
    let closing = bytes[0] == b'/';
    if closing { i += 1; }
    let start = i;
    while i < bytes.len() && bytes[i].is_ascii_alphanumeric() { i += 1; }
    if i == start { return None; }
    let name = rest[start..i].to_ascii_lowercase();
    let mut quote = 0u8;
    while i < bytes.len() {
        let c = bytes[i];
        if quote != 0 { if c == quote { quote = 0; } }
        else if c == b'"' || c == b'\'' { quote = c; }
        else if c == b'>' { return Some((closing, name, i + 1)); }
        i += 1;
    }
    None
}

fn html_escape(text: &str, out: &mut String) {
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            _ => out.push(c),
        }
    }
}

fn sanitize_html(source: &str) -> (String, String, bool) {
    let bytes = source.as_bytes();
    let mut html = String::new();
    let mut excerpt = String::new();
    let mut stack: Vec<String> = Vec::new();
    let mut skip = 0usize;
    let mut markup = false;
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] != b'<' { 
            let start = i;
            while i < bytes.len() && bytes[i] != b'<' { i += 1; }
            if skip == 0 {
                let chunk = &source[start..i];
                html_escape(chunk, &mut html);
                excerpt.push_str(chunk);
            }
            continue;
        }
        i += 1;
        if i >= bytes.len() { break; }
        if bytes[i] == b'!' {
            if source[i..].starts_with("!--") {
                if let Some(rel) = source[i+3..].find("-->") { i += 3 + rel + 3; continue; }
                break;
            }
            if let Some(rel) = source[i..].find('>') { i += rel + 1; continue; }
            break;
        }
        if bytes[i] == b'?' {
            if let Some(rel) = source[i..].find('>') { i += rel + 1; continue; }
            break;
        }
        let Some((closing, raw, consumed)) = parse_tag(&source[i..]) else { i += 1; continue; };
        i += consumed;
        let tag = map_tag(&raw).to_string();
        if skip_tag(&tag) {
            if closing { skip = skip.saturating_sub(1); } else { skip += 1; }
            continue;
        }
        if skip > 0 || !allowed(&tag) { continue; }
        if closing {
            if let Some(pos) = stack.iter().rposition(|t| t == &tag) {
                while stack.len() > pos {
                    if let Some(last) = stack.pop() { html.push_str("</"); html.push_str(&last); html.push('>'); }
                }
            }
            continue;
        }
        if markup_tag(&tag) { markup = true; }
        if tag == "br" {
            html.push_str("<br>");
            excerpt.push('\n');
            continue;
        }
        if (tag == "p" || tag == "li") && !excerpt.is_empty() && !excerpt.ends_with('\n') { excerpt.push('\n'); }
        html.push('<'); html.push_str(&tag); html.push('>');
        stack.push(tag);
    }
    while let Some(last) = stack.pop() { html.push_str("</"); html.push_str(&last); html.push('>'); }
    let excerpt = excerpt.trim_start_matches('\n').to_string();
    (html, excerpt, markup)
}

fn normalize_note(text: &str, fmt: &str) -> Result<(String, String, String)> {
    if fmt == "plain" {
        if text.len() > MAX_BODY { return Err("Note is too large.".into()); }
        return Ok((text.into(), text.into(), "plain".into()));
    }
    if fmt != "html" { return Err("Invalid note format.".into()); }
    let (html, excerpt, markup) = sanitize_html(text);
    if !markup {
        if excerpt.len() > MAX_BODY { return Err("Note is too large.".into()); }
        return Ok((excerpt.clone(), excerpt, "plain".into()));
    }
    if html.len() > MAX_BODY { return Err("Note is too large.".into()); }
    Ok((html, excerpt, "html".into()))
}

fn attachment_name(value: Option<&str>, fallback: &str) -> Result<String> {
    let raw = value.unwrap_or(fallback);
    let name = Path::new(raw).file_name().and_then(|s| s.to_str()).unwrap_or("");
    if name.is_empty() || name == "." || name == ".." || name.len() > MAX_ATTACH_NAME || name.contains('/') || name.contains('\0') {
        return Err("Invalid attachment name.".into());
    }
    Ok(name.into())
}

fn mime_for(name: &str) -> &'static str {
    match Path::new(name).extension().and_then(|s| s.to_str()).unwrap_or("").to_ascii_lowercase().as_str() {
        "png" => "image/png", "jpg" | "jpeg" => "image/jpeg", "gif" => "image/gif",
        "webp" => "image/webp", "svg" => "image/svg+xml", "pdf" => "application/pdf",
        "txt" => "text/plain", "md" => "text/markdown",
        _ => "application/octet-stream",
    }
}

struct Store { db: Connection, root: PathBuf }

fn open(path: &Path) -> Result<Store> {
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or(Path::new("."));
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(parent).map_err(|e|e.to_string())?;
    let db = Connection::open(path).map_err(db_err)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).map_err(|e|e.to_string())?;
    db.busy_timeout(Duration::from_secs(5)).map_err(db_err)?;
    db.execute_batch("PRAGMA synchronous=FULL;").map_err(db_err)?;
    let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0)).map_err(db_err)?;
    if version > 2 { return Err("This notes database was created by a newer version.".into()); }
    if version == 0 {
        db.execute_batch("BEGIN IMMEDIATE; CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, body TEXT NOT NULL, revision INTEGER NOT NULL, updated INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, format TEXT NOT NULL DEFAULT 'plain', excerpt TEXT NOT NULL DEFAULT ''); PRAGMA user_version=2; COMMIT;").map_err(db_err)?;
    } else if version == 1 {
        db.execute_batch("BEGIN IMMEDIATE; ALTER TABLE notes ADD COLUMN format TEXT NOT NULL DEFAULT 'plain'; ALTER TABLE notes ADD COLUMN excerpt TEXT NOT NULL DEFAULT ''; UPDATE notes SET excerpt=body; PRAGMA user_version=2; COMMIT;").map_err(db_err)?;
    }
    db.execute_batch("CREATE TABLE IF NOT EXISTS sticky_session (id INTEGER PRIMARY KEY CHECK (id=1), windows TEXT NOT NULL); CREATE TABLE IF NOT EXISTS attachments (id TEXT PRIMARY KEY, note_id TEXT NOT NULL, name TEXT NOT NULL, mime TEXT NOT NULL, size INTEGER NOT NULL, revision INTEGER NOT NULL);").map_err(db_err)?;
    Ok(Store { db, root: parent.to_path_buf() })
}

fn attachments_dir(store: &Store, note_id: &str) -> PathBuf { store.root.join("attachments").join(note_id) }

fn list_attachments(store: &Store, note_id: &str) -> Result<Value> {
    let mut stmt = store.db.prepare("SELECT id,note_id,name,mime,size,revision FROM attachments WHERE note_id=? ORDER BY name,id").map_err(db_err)?;
    let rows = stmt.query_map([note_id], |r| Ok(json!({"id":r.get::<_,String>(0)?,"note_id":r.get::<_,String>(1)?,"name":r.get::<_,String>(2)?,"mime":r.get::<_,String>(3)?,"size":r.get::<_,i64>(4)?,"revision":r.get::<_,i64>(5)?}))).map_err(db_err)?;
    Ok(Value::Array(rows.collect::<std::result::Result<Vec<_>,_>>().map_err(db_err)?))
}

fn get(store: &Store, id: &str) -> Result<Value> {
    let mut note = store.db.query_row("SELECT id,body,revision,updated,deleted,format,excerpt FROM notes WHERE id=?", [id], |r| Ok(json!({"id":r.get::<_,String>(0)?,"body":r.get::<_,String>(1)?,"revision":r.get::<_,i64>(2)?,"updated":r.get::<_,i64>(3)?,"deleted":r.get::<_,i64>(4)?,"format":r.get::<_,String>(5)?,"excerpt":r.get::<_,String>(6)?}))).optional().map_err(db_err)?.ok_or_else(|| "Note no longer exists.".to_string())?;
    note["attachments"] = list_attachments(store, id)?;
    Ok(note)
}
fn list(store: &Store, deleted: i64) -> Result<Value> {
    let mut stmt = store.db.prepare("SELECT id,body,revision,updated,format,excerpt FROM notes WHERE deleted=? ORDER BY updated DESC,id").map_err(db_err)?;
    let rows = stmt.query_map([deleted], |r| Ok(json!({"id":r.get::<_,String>(0)?,"body":r.get::<_,String>(1)?,"revision":r.get::<_,i64>(2)?,"updated":r.get::<_,i64>(3)?,"format":r.get::<_,String>(4)?,"excerpt":r.get::<_,String>(5)?}))).map_err(db_err)?;
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
        if let Some(color) = w.get("color") {
            if !color.as_str().is_some_and(|s| ["yellow","pink","blue","green","orange","purple"].contains(&s)) {
                return Err("Invalid sticky window color.".into());
            }
        }
    }
    Ok(())
}

fn attach(store: &Store, data: &Value) -> Result<Value> {
    let id = string(data, "id")?; if !uuid(id) { return Err("Invalid note ID.".into()); }
    let attachment_id = string(data, "attachmentId")?; if !uuid(attachment_id) { return Err("Invalid attachment ID.".into()); }
    let rev = revision(data)?;
    let source = Path::new(string(data, "path")?).canonicalize().map_err(|_| "Attachment file is missing.".to_string())?;
    let meta = source.metadata().map_err(|_| "Attachment file is missing.".to_string())?;
    if !meta.is_file() { return Err("Attachment file is missing.".into()); }
    if meta.len() > MAX_ATTACH_BYTES { return Err("Attachment is too large.".into()); }
    let name = attachment_name(data.get("name").and_then(Value::as_str), source.file_name().and_then(|s| s.to_str()).unwrap_or(""))?;
    let dest_dir = attachments_dir(store, id);
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&dest_dir).map_err(|e| e.to_string())?;
    if let Some(parent) = dest_dir.parent() { let _ = fs::set_permissions(parent, fs::Permissions::from_mode(0o700)); }
    let dest = dest_dir.join(attachment_id);
    let tmp = dest_dir.join(format!("{attachment_id}.part"));
    fs::copy(&source, &tmp).map_err(|_| "Attachment file is missing.".to_string())?;
    let _ = fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600));
    let tx = store.db.unchecked_transaction().map_err(db_err);
    let result = (|| -> Result<Value> {
        let tx = tx?;
        let row = tx.query_row("SELECT revision,deleted FROM notes WHERE id=?", [id], |r| Ok((r.get::<_,i64>(0)?, r.get::<_,i64>(1)?))).optional().map_err(db_err)?.ok_or_else(|| "Note no longer exists.".to_string())?;
        if row.1 != 0 || row.0 != rev { return Err("Note changed elsewhere; reload before changing it.".into()); }
        let count: i64 = tx.query_row("SELECT COUNT(*) FROM attachments WHERE note_id=?", [id], |r| r.get(0)).map_err(db_err)?;
        if count >= MAX_ATTACH_COUNT { return Err("Too many attachments.".into()); }
        let exists: Option<String> = tx.query_row("SELECT id FROM attachments WHERE id=?", [attachment_id], |r| r.get(0)).optional().map_err(db_err)?;
        if exists.is_some() { return Err("Attachment ID is already in use.".into()); }
        tx.execute("INSERT INTO attachments(id,note_id,name,mime,size,revision) VALUES(?,?,?,?,?,?)",
            params![attachment_id, id, name, mime_for(&name), meta.len() as i64, rev + 1]).map_err(db_err)?;
        let updated = tx.execute("UPDATE notes SET revision=revision+1,updated=? WHERE id=? AND revision=? AND deleted=0", params![now(), id, rev]).map_err(db_err)?;
        if updated != 1 { return Err("Note changed elsewhere; reload before changing it.".into()); }
        tx.commit().map_err(db_err)?;
        Ok(json!(null))
    })();
    match result {
        Ok(_) => { let _ = fs::rename(&tmp, &dest); get(store, id) }
        Err(e) => { let _ = fs::remove_file(&tmp); Err(e) }
    }
}

fn detach(store: &Store, data: &Value) -> Result<Value> {
    let id = string(data, "id")?;
    let attachment_id = string(data, "attachmentId")?;
    let rev = revision(data)?;
    let path = attachments_dir(store, id).join(attachment_id);
    let tx = store.db.unchecked_transaction().map_err(db_err)?;
    let row = tx.query_row("SELECT revision,deleted FROM notes WHERE id=?", [id], |r| Ok((r.get::<_,i64>(0)?, r.get::<_,i64>(1)?))).optional().map_err(db_err)?.ok_or_else(|| "Note no longer exists.".to_string())?;
    if row.1 != 0 || row.0 != rev { return Err("Note changed elsewhere; reload before changing it.".into()); }
    let exists: Option<String> = tx.query_row("SELECT id FROM attachments WHERE id=? AND note_id=?", [attachment_id, id], |r| r.get(0)).optional().map_err(db_err)?;
    if exists.is_none() { return Err("Attachment no longer exists.".into()); }
    tx.execute("DELETE FROM attachments WHERE id=? AND note_id=?", [attachment_id, id]).map_err(db_err)?;
    let updated = tx.execute("UPDATE notes SET revision=revision+1,updated=? WHERE id=? AND revision=? AND deleted=0", params![now(), id, rev]).map_err(db_err)?;
    if updated != 1 { return Err("Note changed elsewhere; reload before changing it.".into()); }
    tx.commit().map_err(db_err)?;
    let _ = fs::remove_file(path);
    get(store, id)
}

fn handle(store: &Store, action: &str, data: &Value) -> Result<Value> {
    match action {
        "list" => list(store, 0), "list-deleted" => list(store, 1),
        "list-stickies" => {
            let value: Option<String> = store.db.query_row("SELECT windows FROM sticky_session WHERE id=1", [], |r| r.get(0)).optional().map_err(db_err)?;
            let Some(text) = value else { return Ok(json!([])); };
            let value: Value = serde_json::from_str(&text).map_err(|_| "Saved sticky window layout is invalid.")?;
            sticky(&value).map_err(|_| "Saved sticky window layout is invalid.")?; Ok(value)
        },
        "save-stickies" => { let value = data.get("windows").ok_or("Invalid sticky window layout.")?; sticky(value)?; store.db.execute("INSERT INTO sticky_session(id,windows) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET windows=excluded.windows", [value.to_string()]).map_err(db_err)?; Ok(value.clone()) },
        "create" | "save-copy" => {
            let id = string(data,"id")?; if !uuid(id) { return Err("Invalid note ID.".into()); }
            let (text, excerpt, fmt) = if action == "create" { (String::new(), String::new(), "plain".into()) } else {
                let fmt = format_of(data, "plain")?;
                normalize_note(body(data)?, &fmt)?
            };
            store.db.execute("INSERT OR IGNORE INTO notes(id,body,revision,updated,format,excerpt) VALUES(?,?,0,?,?,?)", params![id,text,now(),fmt,excerpt]).map_err(db_err)?;
            let note = get(store,id)?;
            if action == "save-copy" && (note["deleted"] != 0 || note["body"] != text || note["format"] != fmt) { return Err("Copy ID is already in use.".into()); }
            Ok(note)
        },
        "save" => {
            let id = string(data,"id")?; let text = body(data)?; let rev = revision(data)?;
            let current: Option<String> = store.db.query_row("SELECT format FROM notes WHERE id=?", [id], |r| r.get(0)).optional().map_err(db_err)?;
            let current = current.ok_or_else(|| "Note no longer exists.".to_string())?;
            let fmt = format_of(data, &current)?;
            let (text, excerpt, fmt) = normalize_note(text, &fmt)?;
            let count = store.db.execute("UPDATE notes SET body=?,excerpt=?,format=?,revision=revision+1,updated=? WHERE id=? AND revision=? AND deleted=0", params![text,excerpt,fmt,now(),id,rev]).map_err(db_err)?;
            let note = get(store,id)?;
            if count == 0 && !(note["deleted"] == 0 && note["body"] == text) { return Err("Note changed elsewhere; your unsaved text is still in the editor.".into()); }
            Ok(note)
        },
        "delete" | "restore" => {
            let id = string(data,"id")?; let rev = revision(data)?; let deleted = i64::from(action == "delete");
            let count = store.db.execute("UPDATE notes SET deleted=?,revision=revision+1,updated=? WHERE id=? AND revision=? AND deleted=?", params![deleted,now(),id,rev,1-deleted]).map_err(db_err)?;
            let note = get(store,id)?;
            if count == 0 && !(note["deleted"] == deleted && note["revision"] == rev+1) { return Err("Note changed elsewhere; reload before changing it.".into()); }
            Ok(note)
        },
        "list-attachments" => { let id = string(data,"id")?; list_attachments(store, id) },
        "attach" => attach(store, data),
        "detach" => detach(store, data),
        _ => Err("Unknown operation.".into()),
    }
}
fn emit(v: Value) { println!("{v}"); let _ = io::stdout().flush(); }
fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args == ["--protocol-version"] { println!("macshell-notes-service 1"); return; }
    if args.len() != 2 || args[0] != "--store" { eprintln!("Expected --store PATH"); std::process::exit(2); }
    let store = match open(Path::new(&args[1])) { Ok(v) => v, Err(e) => { emit(json!({"type":"unavailable","error":e})); std::process::exit(1); } };
    emit(json!({"type":"hello"}));
    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break; };
        let request = serde_json::from_str::<Value>(&line).unwrap_or(Value::Null);
        let result = handle(&store, request["action"].as_str().unwrap_or(""), &request["data"]);
        let response = match result { Ok(v) => json!({"type":"result","success":true,"result":v,"id":request["id"],"generation":request["generation"]}), Err(e) => json!({"type":"result","success":false,"error":e,"id":request["id"],"generation":request["generation"]}) };
        emit(response);
    }
}
