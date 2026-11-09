use serde_json::{json, Value};

pub mod store;
pub mod timer;
pub mod snooze;
pub mod alarms;
pub mod commands;
pub mod audio;
pub mod sound_catalog;

type Result<T> = std::result::Result<T, String>;
fn integer(value: Option<&Value>, name: &str) -> Result<u64> {
    value.and_then(Value::as_u64).ok_or_else(|| format!("Invalid {name}"))
}
fn add(a: u64, b: u64) -> Result<u64> { a.checked_add(b).ok_or_else(|| "Stopwatch time overflow".into()) }
fn put(value: &mut Value, key: &str, field: Value) { value.as_object_mut().unwrap().insert(key.into(), field); }
fn remove(value: &mut Value, key: &str) { value.as_object_mut().unwrap().remove(key); }

pub fn validate(value: &Value) -> Result<()> {
    let state = value.get("state").and_then(Value::as_str).filter(|s| ["idle","running","paused","recovery"].contains(s)).ok_or("Invalid stopwatch state")?;
    value.get("sessionId").and_then(Value::as_str).filter(|s| !s.is_empty()).ok_or("Invalid stopwatch session")?;
    let elapsed = integer(value.get("elapsedCheckpointMs"), "stopwatch elapsed time")?;
    integer(value.get("checkpointBootMs"), "stopwatch checkpoint")?;
    if value.get("checkpointWallMs").is_some() { integer(value.get("checkpointWallMs"), "stopwatch checkpoint wall time")?; }
    let laps = value.get("laps").and_then(Value::as_array).ok_or("Invalid stopwatch laps")?;
    if laps.iter().any(|v| !v.as_u64().is_some_and(|n| n <= elapsed)) { return Err("Invalid stopwatch laps".into()); }
    if state == "running" {
        integer(value.get("startedBootMs"), "stopwatch start")?;
        integer(value.get("accumulatedMs"), "stopwatch accumulated time")?;
    } else if value.get("startedBootMs").is_some() { return Err("Unexpected stopwatch start".into()); }
    Ok(())
}

pub fn migrate_legacy(value: &Value, boot: u64, wall: u64, session: &str) -> Result<Value> {
    let running = value.get("running").and_then(Value::as_bool).ok_or("Invalid legacy stopwatch")?;
    let acc = integer(value.get("acc"), "legacy accumulated time")?;
    let start = integer(value.get("startAt"), "legacy start time")?;
    let elapsed = if running { add(acc, wall.saturating_sub(start))? } else { acc };
    let mut result = json!({"sessionId":session,"state":if running {"running"} else if elapsed>0 {"paused"} else {"idle"},"elapsedCheckpointMs":elapsed,"checkpointBootMs":boot,"checkpointWallMs":wall,"laps":value.get("laps").cloned().unwrap_or(json!([])),"provenance":"legacy-wall-clock"});
    if running { put(&mut result,"startedBootMs",json!(boot));put(&mut result,"accumulatedMs",json!(elapsed)); }
    validate(&result)?; Ok(result)
}

pub fn elapsed(value: &Value, boot: u64) -> Result<u64> {
    if value["state"] == "running" {
        let start = integer(value.get("startedBootMs"), "stopwatch start")?;
        if boot < start { return Err("Boot clock moved backwards".into()); }
        add(integer(value.get("accumulatedMs"), "stopwatch accumulated time")?, boot-start)
    } else { integer(value.get("elapsedCheckpointMs"), "stopwatch elapsed time") }
}

pub fn restore(value: &Value, changed: bool) -> Value {
    let mut out=value.clone();
    if changed && (out["state"]=="running" || out["state"]=="paused") { put(&mut out,"state",json!("recovery"));remove(&mut out,"startedBootMs");remove(&mut out,"accumulatedMs"); }
    out
}

pub fn checkpoint(value: &Value, boot: u64, wall: Option<u64>) -> Result<Value> {
    let mut out=value.clone();
    if out["state"]=="running" { let n=elapsed(&out,boot)?;put(&mut out,"elapsedCheckpointMs",json!(n));put(&mut out,"checkpointBootMs",json!(boot));if let Some(w)=wall{put(&mut out,"checkpointWallMs",json!(w));} }
    Ok(out)
}

pub fn command(value: &Value, action: &str, boot: u64, session: &str, wall: Option<u64>) -> Result<Value> {
    validate(value)?;
    if session.is_empty(){return Err("Invalid stopwatch session".into());}
    if value["sessionId"]!=session{return Err("Stopwatch session changed".into());}
    let mut out=value.clone();let state=value["state"].as_str().unwrap();
    match (action,state) {
        ("start","idle"|"paused") | ("recover-resume","recovery") => {put(&mut out,"state",json!("running"));put(&mut out,"startedBootMs",json!(boot));put(&mut out,"accumulatedMs",value["elapsedCheckpointMs"].clone());put(&mut out,"checkpointBootMs",json!(boot));},
        ("pause","running") => {out=checkpoint(&out,boot,wall)?;put(&mut out,"state",json!("paused"));remove(&mut out,"startedBootMs");remove(&mut out,"accumulatedMs");},
        ("lap","running") => {out=checkpoint(&out,boot,wall)?;let lap=out["elapsedCheckpointMs"].clone();out["laps"].as_array_mut().unwrap().insert(0,lap);},
        ("reset","paused"|"recovery"|"idle") => {put(&mut out,"state",json!("idle"));put(&mut out,"elapsedCheckpointMs",json!(0));put(&mut out,"checkpointBootMs",json!(boot));put(&mut out,"laps",json!([]));remove(&mut out,"startedBootMs");remove(&mut out,"accumulatedMs");},
        _=>return Err("Invalid stopwatch transition".into()),
    }
    if let Some(w)=wall {if out!=*value && out["checkpointBootMs"]==boot {put(&mut out,"checkpointWallMs",json!(w));}}
    Ok(out)
}

pub fn legacy_projection(value:&Value,boot:u64,wall:u64)->Result<Value>{
    let running=value["state"]=="running";let mut out=json!({"running":running,"startAt":if running{wall}else{0},"acc":elapsed(value,boot)?,"laps":value["laps"]});if value["state"]=="recovery"{put(&mut out,"recoveryRequired",json!(true));}Ok(out)
}
