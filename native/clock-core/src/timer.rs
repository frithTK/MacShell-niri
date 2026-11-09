use serde_json::{json, Value};
use sha1::{Digest,Sha1};

type Result<T> = std::result::Result<T,String>;
const MAX:u64=7*24*60*60*1000;
fn num(v:&Value,key:&str)->Result<u64>{v.get(key).and_then(Value::as_u64).ok_or_else(||format!("Invalid {key}"))}
fn text<'a>(v:&'a Value,key:&str)->Result<&'a str>{v.get(key).and_then(Value::as_str).filter(|s|!s.is_empty()).ok_or_else(||format!("Invalid {key}"))}
fn put(v:&mut Value,key:&str,value:Value){v.as_object_mut().unwrap().insert(key.into(),value);}
fn remove(v:&mut Value,key:&str){v.as_object_mut().unwrap().remove(key);}
pub(crate) fn uuid5(name:&str)->String {
    let namespace=[0x6b,0xa7,0xb8,0x11,0x9d,0xad,0x11,0xd1,0x80,0xb4,0x00,0xc0,0x4f,0xd4,0x30,0xc8];
    let mut h=Sha1::new();h.update(namespace);h.update(name.as_bytes());let hash=h.finalize();let mut b=[0u8;16];b.copy_from_slice(&hash[..16]);b[6]=(b[6]&15)|0x50;b[8]=(b[8]&63)|0x80;
    format!("{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15])
}
fn deadline(boot:u64,left:u64)->Result<u64>{boot.checked_add(left).ok_or_else(||"Invalid deadline".into())}

pub fn validate_timing(timing:&Value)->Result<()> {
    if !timing.is_object() || timing["version"].as_u64()!=Some(1){return Err("Invalid timing version".into());}
    text(timing,"bootId")?;
    let timer=&timing["timer"];
    let state=timer["state"].as_str().filter(|s|["idle","running","paused","recovery"].contains(s)).ok_or("Invalid timer state")?;
    text(timer,"sessionId")?;
    let total=num(timer,"totalMs")?;
    if total==0||total>MAX||num(timer,"remainingCheckpointMs")?>total{return Err("Invalid remaining time".into());}
    num(timer,"checkpointBootMs")?;
    if timer.get("checkpointWallMs").is_some(){num(timer,"checkpointWallMs")?;}
    if !timer["label"].as_str().is_some_and(|v|v.chars().count()<=200){return Err("Invalid label".into());}
    if !crate::snooze::sound_id(timer.get("soundId").unwrap_or(&json!("")))||!crate::snooze::sound_options(timer.get("soundOptions")){return Err("Invalid timer sound".into());}
    if state=="running"{num(timer,"deadlineBootMs")?;}else if timer.get("deadlineBootMs").is_some(){return Err("Unexpected deadline".into());}
    let queue=timing.get("completionQueue").map_or(Some(&[][..]),|v|v.as_array().map(Vec::as_slice)).ok_or("Invalid completion queue")?;
    let completion=timing.get("completion").filter(|v|!v.is_null());
    if completion.is_none()&&!queue.is_empty(){return Err("Completion queue has no current event".into());}
    let mut seen=std::collections::HashSet::new();
    for event in completion.into_iter().chain(queue.iter()){
        let id=text(event,"eventId")?;if !seen.insert(id){return Err("Duplicate completion".into());}text(event,"sessionId")?;
        if !event["label"].is_string()||event.get("kind").is_some_and(|v|v!="timer"&&v!="alarm")||event.get("time").is_some_and(|v|!v.is_string())||event.get("defaultLabel").is_some_and(|v|!v.is_boolean())||event.get("soundClaimed").is_some_and(|v|!v.is_boolean())||event.get("occurredWallMs").is_some_and(|v|v.as_u64().is_none())||!crate::snooze::sound_id(event.get("soundId").unwrap_or(&json!("")))||!crate::snooze::sound_options(event.get("soundOptions")){return Err("Invalid completion".into());}
    }
    if let Some(v)=timing.get("stopwatch"){crate::validate(v)?;}
    if let Some(v)=timing.get("snoozes"){crate::snooze::validate(v)?;}
    if let Some(v)=timing.get("legacySnoozesRecovery"){crate::snooze::validate_recovery(v)?;}
    for (field,key) in [("missedAlarms","eventId"),("missedSnoozes","id")] {
        let mut ids=std::collections::HashSet::new();
        if let Some(records)=timing.get(field){for record in records.as_array().ok_or("Invalid missed event list")?{let id=text(record,key)?;if !ids.insert(id)||!record["label"].is_string(){return Err("Invalid missed event".into());}}}
    }
    Ok(())
}

pub fn migrate_legacy(timer:&Value,boot_id:&str,boot:u64,wall:u64,session:&str)->Result<Value>{
    if boot_id.is_empty() || session.is_empty(){return Err("Invalid identity".into());}
    let state=timer["state"].as_str().filter(|s|["idle","paused","running"].contains(s)).ok_or("Invalid legacy timer")?;
    let total=num(timer,"total")?;if total==0 || total>MAX{return Err("Invalid duration".into());}
    let label=timer.get("label").map_or(Some(""),Value::as_str).filter(|s|s.chars().count()<=200).ok_or("Invalid label")?;
    let left=if state=="running"{num(timer,"endAt")?.saturating_sub(wall).min(total)}else{let n=num(timer,"left")?;if n>total{return Err("Invalid remaining time".into());}n};
    let mut entry=json!({"sessionId":session,"state":state,"totalMs":total,"remainingCheckpointMs":left,"checkpointBootMs":boot,"checkpointWallMs":wall,"label":label,"provenance":"legacy-wall-clock"});
    if state=="running"{put(&mut entry,"deadlineBootMs",json!(deadline(boot,left)?));}
    Ok(json!({"version":1,"bootId":boot_id,"timer":entry,"completion":null}))
}

pub fn restore(timing:&Value,boot_id:&str)->Result<Value>{
    if boot_id.is_empty(){return Err("Invalid boot ID".into());}
    let mut out=timing.clone();if !out.is_object() || !out["timer"].is_object(){return Err("Invalid timer state".into());}
    if out["bootId"]!=boot_id {
        if out["timer"]["state"]=="running" || out["timer"]["state"]=="paused"{put(&mut out["timer"],"state",json!("recovery"));remove(&mut out["timer"],"deadlineBootMs");}
        if out.get("stopwatch").is_some(){out["stopwatch"]=crate::restore(&out["stopwatch"],true);}
        put(&mut out,"bootId",json!(boot_id));
    }
    Ok(out)
}

pub fn advance_at(timing:&Value,boot_id:&str,boot:u64,wall:Option<u64>)->Result<Value>{
    let mut out=restore(timing,boot_id)?;
    out=crate::snooze::advance(&out,boot_id,boot,wall)?;
    if out["timer"]["state"]=="running" && boot>=num(&out["timer"],"deadlineBootMs")? {
        let t=&out["timer"];let session=text(t,"sessionId")?.to_owned();let label=t["label"].clone();let total=num(t,"totalMs")?;
        let mut event=json!({"eventId":uuid5(&format!("macshell:timer:{session}")),"sessionId":session,"kind":"timer","label":label,"totalMs":total});
        if t.get("soundId").and_then(Value::as_str).is_some_and(|s|!s.is_empty()){put(&mut event,"soundId",t["soundId"].clone());}
        if let Some(options)=t.get("soundOptions").filter(|v|!v.is_null()){put(&mut event,"soundOptions",options.clone());}
        put(&mut out["timer"],"state",json!("idle"));put(&mut out["timer"],"remainingCheckpointMs",json!(total));put(&mut out["timer"],"checkpointBootMs",json!(boot));remove(&mut out["timer"],"deadlineBootMs");
        if out["completion"].is_null(){put(&mut out,"completion",event);}else{if out.get("completionQueue").is_none(){put(&mut out,"completionQueue",json!([]));}out["completionQueue"].as_array_mut().ok_or("Invalid completion queue")?.push(event);}
    }
    Ok(out)
}
pub fn advance(timing:&Value,boot_id:&str,boot:u64)->Result<Value>{advance_at(timing,boot_id,boot,None)}

pub struct Command<'a>{pub action:&'a str,pub boot_id:&'a str,pub boot:u64,pub wall:Option<u64>,pub session:Option<&'a str>,pub duration:Option<u64>,pub label:&'a str,pub replace:bool,pub sound:&'a str,pub sound_options:Option<Value>}
pub fn command(timing:&Value,c:Command<'_>)->Result<Value>{
    let mut out=advance_at(timing,c.boot_id,c.boot,c.wall)?;let state=out["timer"]["state"].as_str().ok_or("Invalid timer state")?.to_string();
    match c.action {
        "start"=>{
            if state!="idle" && !c.replace{return Err("A timer is already active".into());}
            let duration=c.duration.filter(|v|*v>0 && *v<=MAX).ok_or("Invalid duration")?;
            let session=c.session.filter(|s|!s.is_empty()).ok_or("Invalid session ID")?;
            if out["timer"]["sessionId"]==session{return Err("A new timer needs a new session ID".into());}
            if c.label.chars().count()>200{return Err("Invalid label".into());}
            let mut timer=json!({"sessionId":session,"state":"running","totalMs":duration,"deadlineBootMs":deadline(c.boot,duration)?,"remainingCheckpointMs":duration,"checkpointBootMs":c.boot,"label":c.label});
            if !c.sound.is_empty(){put(&mut timer,"soundId",json!(c.sound));}if let Some(options)=c.sound_options{put(&mut timer,"soundOptions",options);}
            out["timer"]=timer;
        },
        "cancel"=>{if state!="idle"{let session=c.session.filter(|s|!s.is_empty()).ok_or("Invalid session ID")?;if out["timer"]["sessionId"]!=session{return Err("Timer session changed".into());}let total=num(&out["timer"],"totalMs")?;put(&mut out["timer"],"state",json!("idle"));put(&mut out["timer"],"remainingCheckpointMs",json!(total));put(&mut out["timer"],"checkpointBootMs",json!(c.boot));remove(&mut out["timer"],"deadlineBootMs");}},
        "pause"|"resume"|"recover-remainder"|"recover-restart"=>{
            let session=c.session.filter(|s|!s.is_empty()).ok_or("Invalid session ID")?;if out["timer"]["sessionId"]!=session{return Err("Timer session changed".into());}
            if c.action=="pause" && state=="running" {let left=num(&out["timer"],"deadlineBootMs")?.checked_sub(c.boot).ok_or("Invalid remaining time")?;put(&mut out["timer"],"remainingCheckpointMs",json!(left));put(&mut out["timer"],"checkpointBootMs",json!(c.boot));put(&mut out["timer"],"state",json!("paused"));remove(&mut out["timer"],"deadlineBootMs");}
            else if (c.action=="resume" && state=="paused") || (c.action.starts_with("recover-") && state=="recovery") {let left=if c.action=="recover-restart"{num(&out["timer"],"totalMs")?}else{num(&out["timer"],"remainingCheckpointMs")?};if left>num(&out["timer"],"totalMs")?{return Err("Invalid remaining time".into());}put(&mut out["timer"],"state",json!("running"));put(&mut out["timer"],"deadlineBootMs",json!(deadline(c.boot,left)?));put(&mut out["timer"],"remainingCheckpointMs",json!(left));put(&mut out["timer"],"checkpointBootMs",json!(c.boot));}
            else if !(c.action=="pause" && state=="idle" && timing["bootId"]==c.boot_id && timing["timer"]["state"]=="running" && timing["timer"]["sessionId"]==session){return Err("Invalid timer transition".into());}
        },
        _=>return Err("Unknown timer action".into()),
    }
    if let Some(wall)=c.wall{if out["timer"]!=timing["timer"] && out["timer"]["checkpointBootMs"]==c.boot{put(&mut out["timer"],"checkpointWallMs",json!(wall));}}
    if out["timer"]["state"]=="running" && num(&out["timer"],"deadlineBootMs")?<=c.boot {out=advance_at(&out,c.boot_id,c.boot,c.wall)?;}
    Ok(out)
}
pub fn checkpoint(timing:&Value,boot_id:&str,boot:u64,wall:Option<u64>)->Result<Value>{
    let mut out=advance_at(timing,boot_id,boot,wall)?;
    if out["timer"]["state"]=="running"{let left=num(&out["timer"],"deadlineBootMs")?.checked_sub(boot).ok_or("Invalid remaining time")?;put(&mut out["timer"],"remainingCheckpointMs",json!(left));put(&mut out["timer"],"checkpointBootMs",json!(boot));if let Some(w)=wall{put(&mut out["timer"],"checkpointWallMs",json!(w));}}
    if out.get("stopwatch").is_some(){out["stopwatch"]=crate::checkpoint(&out["stopwatch"],boot,wall)?;}Ok(out)
}
pub fn legacy_projection(timing:&Value,boot:u64,wall:u64)->Result<Value>{
    let timer=&timing["timer"];let state=timer["state"].as_str().ok_or("Invalid timer state")?;
    let left=if state=="running"{num(timer,"deadlineBootMs")?.saturating_sub(boot)}else{num(timer,"remainingCheckpointMs")?};
    let mut out=json!({"state":if state=="recovery"{"paused"}else{state},"total":num(timer,"totalMs")?,"left":left,"endAt":if state=="running"{deadline(wall,left)?}else{0},"label":timer["label"]});
    if state=="recovery"{put(&mut out,"recoveryRequired",json!(true));}Ok(out)
}
pub fn legacy_ringing(timing:&Value)->Value{
    let event=&timing["completion"];if event.is_null(){return Value::Null;}
    let label=event.get("label").cloned().unwrap_or(json!(""));
    let mut result=json!({"kind":event.get("kind").unwrap_or(&json!("timer")),"label":label,"defaultLabel":event.get("defaultLabel").cloned().unwrap_or(json!(label.as_str().is_some_and(str::is_empty))),"time":event.get("time").unwrap_or(&json!("")),"eventId":event["eventId"]});
    for key in ["occurredWallMs","hour","minute"]{if let Some(value)=event.get(key){put(&mut result,key,value.clone());}}result
}
