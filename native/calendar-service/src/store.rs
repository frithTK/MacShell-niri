use chrono::{Datelike, NaiveDate, TimeZone, Utc};
use chrono_tz::Tz;
use macshell_reminders_service::{next_occurrence, occurrence_instant, repeat_fields, Repeat, Rule};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub type Result<T> = std::result::Result<T, String>;
pub fn err(e: rusqlite::Error) -> String { e.to_string() }
pub fn now() -> i64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as i64 }
fn uuid(s: &str) -> bool { s.len()==36 && s.bytes().enumerate().all(|(i,b)| if [8,13,18,23].contains(&i) {b==b'-'} else {b.is_ascii_digit() || (b'a'..=b'f').contains(&b)}) }
fn date(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len()!=10 || b[4]!=b'-' || b[7]!=b'-' || !b.iter().enumerate().all(|(i,b)| i==4 || i==7 || b.is_ascii_digit()) { return false; }
    let y: u32 = s[0..4].parse().unwrap_or(0); let m: usize = s[5..7].parse().unwrap_or(0); let d: u32 = s[8..10].parse().unwrap_or(0);
    if y==0 || !(1..=12).contains(&m) { return false; }
    let leap = y%4==0 && (y%100!=0 || y%400==0);
    d>0 && d <= [31,if leap {29} else {28},31,30,31,30,31,31,30,31,30,31][m-1]
}

struct Fields {
    title: String, all_day: i64, day: Option<String>, start: Option<i64>, end: Option<i64>,
    rule: String, zone: String, date: String, day_n: i64, hour: i64, minute: i64, duration: Option<i64>,
    alert_next: Option<i64>, alert_state: String,
}

fn system_zone() -> Result<String> {
    if let Ok(tz)=std::env::var("TZ") {
        let tz=tz.trim_start_matches(':');
        if !tz.is_empty(){
            let zone=if tz.starts_with('/') {
                let canonical=std::fs::canonicalize(tz).map_err(|_| "Cannot determine the event time zone.")?;
                canonical.strip_prefix("/usr/share/zoneinfo").map_err(|_| "Cannot determine the event time zone.")?.to_string_lossy().into_owned()
            } else { tz.into() };
            return if zone.parse::<Tz>().is_ok() { Ok(zone) } else { Err("Cannot determine the event time zone.".into()) };
        }
    }
    if let Ok(path)=std::fs::read_link("/etc/localtime") {
        let s=path.to_string_lossy();
        if let Some((_,zone))=s.split_once("zoneinfo/") { if zone.parse::<Tz>().is_ok() { return Ok(zone.into()); } }
    }
    if let Ok(zone)=std::fs::read_to_string("/etc/timezone") {
        let zone=zone.trim();
        if zone.parse::<Tz>().is_ok() { return Ok(zone.into()); }
    }
    Err("Cannot determine the event time zone.".into())
}

fn parse_rule(v: &Value) -> Result<String> {
    match v.get("repeat").and_then(Value::as_str).unwrap_or("none") {
        "none" | "daily" | "weekly" | "monthly" => Ok(v.get("repeat").and_then(Value::as_str).unwrap_or("none").into()),
        _ => Err("Invalid repeat rule.".into()),
    }
}

fn fields(v: &Value) -> Result<Fields> {
    let title = v["title"].as_str().filter(|s| !s.trim().is_empty() && s.chars().count() <= 500 && !s.contains('\0')).ok_or("Enter a title of up to 500 characters.")?.trim().to_string();
    let all_day = v["allDay"].as_bool().ok_or("Invalid event type.")?;
    let rule = parse_rule(v)?;
    if all_day {
        let day = v["date"].as_str().filter(|s| date(s)).ok_or("Invalid event date.")?;
        if rule != "none" {
            let zone = v.get("zone").and_then(Value::as_str).map(str::to_string).filter(|s| s.parse::<Tz>().is_ok()).unwrap_or(system_zone()?);
            let parsed = NaiveDate::parse_from_str(day, "%Y-%m-%d").map_err(|_| "Invalid event date.")?;
            let tz: Tz = zone.parse().map_err(|_| "Cannot determine the event time zone.")?;
            let first = occurrence_instant(tz, parsed, 9, 0).ok_or("Cannot calculate the next event time.")?;
            return Ok(Fields { title, all_day: 1, day: Some(day.into()), start: None, end: None, rule, zone, date: day.into(), day_n: parsed.day() as i64, hour: 9, minute: 0, duration: None, alert_next: Some(first), alert_state: "pending".into() });
        }
        let zone = system_zone().unwrap_or_else(|_| "UTC".into());
        let tz: Tz = zone.parse().unwrap_or(chrono_tz::UTC);
        let parsed = NaiveDate::parse_from_str(day, "%Y-%m-%d").map_err(|_| "Invalid event date.")?;
        let first = occurrence_instant(tz, parsed, 9, 0);
        return Ok(Fields { title, all_day: 1, day: Some(day.into()), start: None, end: None, rule: "none".into(), zone, date: day.into(), day_n: parsed.day() as i64, hour: 9, minute: 0, duration: None, alert_next: first, alert_state: if first.is_some() { "pending".into() } else { "none".into() } });
    }
    let start = v["start"].as_i64().ok_or("The event end must be after its start.")?;
    let end = v["end"].as_i64().ok_or("The event end must be after its start.")?;
    if start<0 || start>=end || end>253402300799999 { return Err("The event end must be after its start.".into()); }
    let duration = end - start;
    if rule != "none" {
        let zone = v.get("zone").and_then(Value::as_str).map(str::to_string).filter(|s| s.parse::<Tz>().is_ok()).unwrap_or(system_zone()?);
        let tz: Tz = zone.parse().map_err(|_| "Cannot determine the event time zone.")?;
        let (date, day_n, hour, minute) = repeat_fields(start, tz).ok_or("Cannot calculate the next event time.")?;
        return Ok(Fields { title, all_day: 0, day: None, start: Some(start), end: Some(end), rule, zone, date: date.to_string(), day_n: day_n as i64, hour: hour as i64, minute: minute as i64, duration: Some(duration), alert_next: Some(start), alert_state: "pending".into() });
    }
    Ok(Fields { title, all_day: 0, day: None, start: Some(start), end: Some(end), rule: "none".into(), zone: String::new(), date: String::new(), day_n: 0, hour: 0, minute: 0, duration: Some(duration), alert_next: Some(start), alert_state: "pending".into() })
}

pub fn open(path: &Path) -> Result<Connection> {
    let parent = path.parent().filter(|v| !v.as_os_str().is_empty()).unwrap_or(Path::new("."));
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(parent).map_err(|e| e.to_string())?;
    let db = Connection::open(path).map_err(err)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
    db.busy_timeout(Duration::from_secs(5)).map_err(err)?;
    db.execute_batch("PRAGMA synchronous=FULL; BEGIN IMMEDIATE;").map_err(err)?;
    let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0)).map_err(err)?;
    if version > 2 { return Err("This calendar database was created by a newer version.".into()); }
    if version == 0 {
        let existing: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%')", [], |r| r.get(0)).map_err(err)?;
        if existing { return Err("Unrecognized calendar database.".into()); }
        db.execute_batch("CREATE TABLE events (id TEXT PRIMARY KEY, title TEXT NOT NULL, all_day INTEGER NOT NULL, day TEXT, start_ms INTEGER, end_ms INTEGER, deleted INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL DEFAULT 0, updated INTEGER NOT NULL, repeat_rule TEXT NOT NULL DEFAULT 'none', repeat_zone TEXT NOT NULL DEFAULT '', repeat_date TEXT NOT NULL DEFAULT '', repeat_day INTEGER NOT NULL DEFAULT 0, repeat_hour INTEGER NOT NULL DEFAULT 0, repeat_minute INTEGER NOT NULL DEFAULT 0, duration_ms INTEGER, alert_state TEXT NOT NULL DEFAULT 'none', alert_token TEXT NOT NULL DEFAULT '', alert_retry_at INTEGER NOT NULL DEFAULT 0, alert_error TEXT NOT NULL DEFAULT '', alert_next_ms INTEGER); PRAGMA user_version=2;").map_err(err)?;
    } else if version == 1 {
        db.execute_batch("ALTER TABLE events ADD COLUMN repeat_rule TEXT NOT NULL DEFAULT 'none'; ALTER TABLE events ADD COLUMN repeat_zone TEXT NOT NULL DEFAULT ''; ALTER TABLE events ADD COLUMN repeat_date TEXT NOT NULL DEFAULT ''; ALTER TABLE events ADD COLUMN repeat_day INTEGER NOT NULL DEFAULT 0; ALTER TABLE events ADD COLUMN repeat_hour INTEGER NOT NULL DEFAULT 0; ALTER TABLE events ADD COLUMN repeat_minute INTEGER NOT NULL DEFAULT 0; ALTER TABLE events ADD COLUMN duration_ms INTEGER; ALTER TABLE events ADD COLUMN alert_state TEXT NOT NULL DEFAULT 'none'; ALTER TABLE events ADD COLUMN alert_token TEXT NOT NULL DEFAULT ''; ALTER TABLE events ADD COLUMN alert_retry_at INTEGER NOT NULL DEFAULT 0; ALTER TABLE events ADD COLUMN alert_error TEXT NOT NULL DEFAULT ''; ALTER TABLE events ADD COLUMN alert_next_ms INTEGER; PRAGMA user_version=2;").map_err(err)?;
    }
    db.execute_batch("COMMIT;").map_err(err)?; Ok(db)
}

pub fn next_alert(master: &Value, after_ms: i64) -> Option<i64> {
    if master["repeat_rule"] == "none" { return None; }
    let repeat = master_repeat(master)?;
    next_occurrence(&repeat, after_ms).map(|(_, ms)| ms)
}

fn row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    Ok(json!({
        "id": r.get::<_,String>(0)?, "title": r.get::<_,String>(1)?, "all_day": r.get::<_,i64>(2)?,
        "day": r.get::<_,Option<String>>(3)?, "start_ms": r.get::<_,Option<i64>>(4)?, "end_ms": r.get::<_,Option<i64>>(5)?,
        "deleted": r.get::<_,i64>(6)?, "revision": r.get::<_,i64>(7)?, "updated": r.get::<_,i64>(8)?,
        "repeat_rule": r.get::<_,String>(9)?, "repeat_zone": r.get::<_,String>(10)?, "repeat_date": r.get::<_,String>(11)?,
        "repeat_day": r.get::<_,i64>(12)?, "repeat_hour": r.get::<_,i64>(13)?, "repeat_minute": r.get::<_,i64>(14)?,
        "duration_ms": r.get::<_,Option<i64>>(15)?, "alert_state": r.get::<_,String>(16)?,
        "alert_next_ms": r.get::<_,Option<i64>>(20)?
    }))
}
const SELECT: &str = "SELECT id,title,all_day,day,start_ms,end_ms,deleted,revision,updated,repeat_rule,repeat_zone,repeat_date,repeat_day,repeat_hour,repeat_minute,duration_ms,alert_state,alert_token,alert_retry_at,alert_error,alert_next_ms FROM events";

fn event(db: &Connection, id: &str) -> Result<Value> {
    db.query_row(&format!("{SELECT} WHERE id=?"), [id], row).optional().map_err(err)?.ok_or_else(|| "Event no longer exists.".into())
}
fn matches(v: &Value, f: &Fields) -> bool {
    v["title"]==f.title && v["all_day"]==f.all_day && v["day"]==json!(f.day) && v["start_ms"]==json!(f.start) && v["end_ms"]==json!(f.end) && v["repeat_rule"]==f.rule
}

fn master_repeat(v: &Value) -> Option<Repeat> {
    let rule = match v["repeat_rule"].as_str()? { "daily" => Rule::Daily, "weekly" => Rule::Weekly, "monthly" => Rule::Monthly, _ => return None };
    Some(Repeat {
        rule,
        zone: v["repeat_zone"].as_str()?.parse().ok()?,
        date: NaiveDate::parse_from_str(v["repeat_date"].as_str()?, "%Y-%m-%d").ok()?,
        day: v["repeat_day"].as_i64()? as u32,
        hour: v["repeat_hour"].as_i64()? as u32,
        minute: v["repeat_minute"].as_i64()? as u32,
        due_ms: if v["all_day"]==1 { occurrence_instant(v["repeat_zone"].as_str()?.parse().ok()?, NaiveDate::parse_from_str(v["repeat_date"].as_str()?, "%Y-%m-%d").ok()?, 9, 0)? } else { v["start_ms"].as_i64()? },
    })
}

fn occurrence_payload(master: &Value, start: i64, date: Option<&str>) -> Value {
    let mut item = master.clone();
    if master["all_day"]==1 {
        item["day"] = json!(date);
        item["start_ms"] = Value::Null;
        item["end_ms"] = Value::Null;
        item["occurrence"] = json!(date);
    } else {
        let duration = master["duration_ms"].as_i64().unwrap_or_else(|| master["end_ms"].as_i64().unwrap_or(start) - master["start_ms"].as_i64().unwrap_or(start));
        item["start_ms"] = json!(start);
        item["end_ms"] = json!(start + duration);
        item["occurrence"] = json!(start);
    }
    item
}

pub fn expand(master: &Value, from_ms: i64, to_ms: i64, cap: usize) -> Vec<Value> {
    let mut out = Vec::new();
    if master["deleted"] != 0 { return out; }
    let duration = if master["all_day"] == 1 { 86_400_000 } else { master["duration_ms"].as_i64().unwrap_or(0) };
    if master["repeat_rule"] == "none" {
        if master["all_day"] == 1 {
            if let Some(day) = master["day"].as_str() {
                if let Ok(parsed) = NaiveDate::parse_from_str(day, "%Y-%m-%d") {
                    if let Some(naive) = parsed.and_hms_opt(0, 0, 0) {
                        let start = Utc.from_utc_datetime(&naive).timestamp_millis();
                        if start < to_ms && start + duration > from_ms { out.push(occurrence_payload(master, start, Some(day))); }
                    }
                }
            }
        } else if let (Some(start), Some(end)) = (master["start_ms"].as_i64(), master["end_ms"].as_i64()) {
            if start < to_ms && end > from_ms { out.push(occurrence_payload(master, start, None)); }
        }
        return out;
    }
    let Some(mut current) = master_repeat(master) else { return out; };
    if current.due_ms < to_ms && current.due_ms + duration > from_ms {
        let date = if master["all_day"] == 1 { Some(current.date.to_string()) } else { None };
        out.push(occurrence_payload(master, current.due_ms, date.as_deref()));
    }
    let mut guard = 0;
    while out.len() < cap && guard < cap + 8 {
        guard += 1;
        let Some((day, ms)) = next_occurrence(&current, current.due_ms.max(from_ms.saturating_sub(1))) else { break; };
        if ms >= to_ms { break; }
        if ms + duration > from_ms {
            let date = if master["all_day"] == 1 { Some(day.to_string()) } else { None };
            out.push(occurrence_payload(master, ms, date.as_deref()));
        }
        current.date = day;
        current.due_ms = ms;
    }
    out
}

fn range(data: &Value) -> (i64, i64) {
    let now = now();
    let from = data.get("from").and_then(Value::as_i64).unwrap_or(now.saturating_sub(40 * 86_400_000));
    let to = data.get("to").and_then(Value::as_i64).unwrap_or(now.saturating_add(400 * 86_400_000));
    (from.min(to), from.max(to))
}

pub fn handle(db: &Connection, action: &str, data: &Value) -> Result<Value> {
    if action=="load" {
        let mut stmt=db.prepare(&format!("{SELECT} ORDER BY updated DESC,id")).map_err(err)?;
        let rows=stmt.query_map([],row).map_err(err)?.collect::<std::result::Result<Vec<_>,_>>().map_err(err)?;
        let (deleted,events): (Vec<_>,Vec<_>) = rows.into_iter().partition(|v| v["deleted"]!=0);
        let (from, to) = range(data);
        let mut occurrences = Vec::new();
        for event in &events { occurrences.extend(expand(event, from, to, 62)); }
        return Ok(json!({"events":events,"deleted":deleted,"occurrences":occurrences}));
    }
    if !["create","update","delete"].contains(&action) { return Err("Unknown operation.".into()); }
    let id=data["id"].as_str().filter(|v|uuid(v)).ok_or("Invalid event identifier.")?;
    if action=="create" {
        let f=fields(data)?;
        db.execute("INSERT OR IGNORE INTO events(id,title,all_day,day,start_ms,end_ms,updated,repeat_rule,repeat_zone,repeat_date,repeat_day,repeat_hour,repeat_minute,duration_ms,alert_state,alert_next_ms) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            params![id,f.title,f.all_day,f.day,f.start,f.end,now(),f.rule,f.zone,f.date,f.day_n,f.hour,f.minute,f.duration,f.alert_state,f.alert_next]).map_err(err)?;
        let v=event(db,id)?; if v["deleted"]!=0 || !matches(&v,&f) { return Err("Event ID is already in use.".into()); } return Ok(v);
    }
    let rev=data["revision"].as_i64().filter(|v|*v>=0 && *v<i64::MAX).ok_or("Invalid event revision.")?;
    if action=="delete" {
        let deleted=data["deleted"].as_bool().ok_or("Invalid event state.")? as i64;
        let changed=db.execute("UPDATE events SET deleted=?,revision=revision+1,updated=? WHERE id=? AND revision=?",params![deleted,now(),id,rev]).map_err(err)?;
        let v=event(db,id)?; if changed==0 && !(v["revision"]==rev+1 && v["deleted"]==deleted) { return Err("Event changed elsewhere; reload and try again.".into()); } Ok(v)
    } else {
        let f=fields(data)?;
        let changed=db.execute("UPDATE events SET title=?,all_day=?,day=?,start_ms=?,end_ms=?,repeat_rule=?,repeat_zone=?,repeat_date=?,repeat_day=?,repeat_hour=?,repeat_minute=?,duration_ms=?,alert_state=?,alert_token='',alert_retry_at=0,alert_error='',alert_next_ms=?,revision=revision+1,updated=? WHERE id=? AND revision=? AND deleted=0",
            params![f.title,f.all_day,f.day,f.start,f.end,f.rule,f.zone,f.date,f.day_n,f.hour,f.minute,f.duration,f.alert_state,f.alert_next,now(),id,rev]).map_err(err)?;
        let v=event(db,id)?; if changed==0 && !(v["revision"]==rev+1 && v["deleted"]==0 && matches(&v,&f)) { return Err("Event changed elsewhere; reload and try again.".into()); } Ok(v)
    }
}

pub fn skip_stale_alerts(db: &Connection, now_ms: i64) -> Result<()> {
    let cutoff = now_ms.saturating_sub(15 * 60 * 1000);
    let mut stmt = db.prepare("SELECT id, repeat_rule, repeat_zone, repeat_date, repeat_day, repeat_hour, repeat_minute, all_day, start_ms, day, duration_ms, alert_next_ms FROM events WHERE deleted=0 AND alert_state IN ('pending','none') AND alert_next_ms IS NOT NULL AND alert_next_ms < ?").map_err(err)?;
    let rows: Vec<(String, Option<i64>, Value)> = stmt.query_map(params![cutoff], |r| {
        let id: String = r.get(0)?;
        let next: Option<i64> = r.get(11)?;
        let master = json!({
            "id": id, "repeat_rule": r.get::<_,String>(1)?, "repeat_zone": r.get::<_,String>(2)?,
            "repeat_date": r.get::<_,String>(3)?, "repeat_day": r.get::<_,i64>(4)?, "repeat_hour": r.get::<_,i64>(5)?,
            "repeat_minute": r.get::<_,i64>(6)?, "all_day": r.get::<_,i64>(7)?, "start_ms": r.get::<_,Option<i64>>(8)?,
            "day": r.get::<_,Option<String>>(9)?, "duration_ms": r.get::<_,Option<i64>>(10)?, "deleted": 0
        });
        Ok((id, next, master))
    }).map_err(err)?.collect::<std::result::Result<Vec<_>,_>>().map_err(err)?;
    drop(stmt);
    for (id, next, master) in rows {
        let Some(due) = next else { continue; };
        if due >= cutoff { continue; }
        if master["repeat_rule"]=="none" {
            db.execute("UPDATE events SET alert_state='none', alert_next_ms=NULL WHERE id=? AND alert_next_ms=?", params![id, due]).map_err(err)?;
            continue;
        }
        if let Some(repeat) = master_repeat(&master) {
            if let Some((_, ms)) = next_occurrence(&repeat, now_ms.saturating_sub(1)) {
                db.execute("UPDATE events SET alert_next_ms=?, alert_state='pending' WHERE id=?", params![ms, id]).map_err(err)?;
            } else {
                db.execute("UPDATE events SET alert_state='none', alert_next_ms=NULL WHERE id=?", params![id]).map_err(err)?;
            }
        }
    }
    Ok(())
}
