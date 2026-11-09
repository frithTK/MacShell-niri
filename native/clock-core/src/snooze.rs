use serde_json::{json,Value};
use std::collections::HashSet;

type Result<T> = std::result::Result<T,String>;
pub const SNOOZE_MS:u64=540000;
fn put(v:&mut Value,key:&str,value:Value){v.as_object_mut().unwrap().insert(key.into(),value);}
fn nonempty(v:&Value,key:&str)->bool{v.get(key).and_then(Value::as_str).is_some_and(|s|!s.is_empty())}
pub(crate) fn sound_id(v:&Value)->bool {
    let Some(s)=v.as_str() else{return false};
    if s.is_empty()||s=="silence"{return true;}
    if let Some(hex)=s.strip_prefix("user-"){return hex.len()==64 && hex.bytes().all(|b|b.is_ascii_digit()||(b'a'..=b'f').contains(&b));}
    for prefix in ["builtin-chime-","builtin-melody-","builtin-gentle-","builtin-urgent-"] {if let Some(n)=s.strip_prefix(prefix){return n=="10" || (n.len()==2 && n.starts_with('0') && n.as_bytes()[1]>=b'1' && n.as_bytes()[1]<=b'9');}}
    false
}
pub(crate) fn sound_options(v:Option<&Value>)->bool {
    let Some(v)=v.filter(|v|!v.is_null()) else{return true};
    let Some(map)=v.as_object() else{return false};
    for (name,max) in [("volume",100),("fadeMs",60000),("startMs",600000),("durationMs",600000)] {if let Some(v)=map.get(name){if !v.as_u64().is_some_and(|n|n<=max){return false;}}}
    map.get("repeat").is_none_or(Value::is_boolean)
}
pub fn validate(value:&Value)->Result<()> {
    let items=value.as_array().ok_or("Invalid snoozes")?;let mut ids=HashSet::new();
    for v in items {
        if !v.is_object() || !nonempty(v,"id") || !nonempty(v,"bootId") || v["deadlineBootMs"].as_u64().is_none() || !nonempty(v,"sessionId") || !v["label"].is_string() || !nonempty(v,"sourceEventId"){return Err("Invalid snooze".into());}
        if !ids.insert(v["id"].as_str().unwrap()){return Err("Duplicate snooze ID".into());}
        if v.get("time").is_some_and(|v|!v.is_string()){return Err("Invalid snooze time".into());}
        if !sound_id(v.get("soundId").unwrap_or(&json!(""))){return Err("Invalid snooze sound".into());}
        if !sound_options(v.get("soundOptions")){return Err("Invalid sound options".into());}
    }Ok(())
}
pub fn validate_recovery(value:&Value)->Result<()> {
    let items=value.as_array().ok_or("Invalid snooze recovery data")?;let mut ids=HashSet::new();
    for v in items {
        if !v.is_object() || !nonempty(v,"id") || !nonempty(v,"sessionId") || !nonempty(v,"sourceEventId") || !v["label"].as_str().is_some_and(|s|s.chars().count()<=200) || !v["remainingMs"].as_u64().is_some_and(|n|n<=SNOOZE_MS) || v["capturedWallMs"].as_u64().is_none() || !nonempty(v,"provenance") || !v["legacy"].is_object(){return Err("Invalid snooze recovery entry".into());}
        if !ids.insert(v["id"].as_str().unwrap()){return Err("Duplicate snooze recovery ID".into());}
    }Ok(())
}
pub fn schedule(timing:&Value,event:&Value,id:&str,boot_id:&str,boot:u64)->Result<Value>{
    if event["kind"]!="alarm"{return Err("Only alarm events can be snoozed".into());}
    let deadline=boot.checked_add(SNOOZE_MS).ok_or("Invalid snooze")?;
    let mut item=json!({"id":id,"bootId":boot_id,"deadlineBootMs":deadline,"sessionId":event["sessionId"],"label":event["label"],"sourceEventId":event["eventId"],"time":event.get("time").unwrap_or(&json!("")),"soundId":event.get("soundId").unwrap_or(&json!(""))});
    if let Some(options)=event.get("soundOptions").filter(|v|!v.is_null()){put(&mut item,"soundOptions",options.clone());}
    let mut out=timing.clone();if !out.is_object(){return Err("Invalid timing".into());}if out.get("snoozes").is_none(){put(&mut out,"snoozes",json!([]));}out["snoozes"].as_array_mut().ok_or("Invalid snoozes")?.push(item);validate(&out["snoozes"])?;Ok(out)
}
pub fn advance(timing:&Value,boot_id:&str,boot:u64,wall:Option<u64>)->Result<Value>{
    let mut out=timing.clone();let Some(items)=timing.get("snoozes") else{return Ok(out)};validate(items)?;let mut remaining=Vec::new();
    for item in items.as_array().unwrap(){
        if item["bootId"]!=boot_id {if out.get("missedSnoozes").is_none(){put(&mut out,"missedSnoozes",json!([]));}out["missedSnoozes"].as_array_mut().ok_or("Invalid missed event list")?.push(item.clone());}
        else if item["deadlineBootMs"].as_u64().unwrap()<=boot {
            let mut event=json!({"eventId":crate::timer::uuid5(&format!("macshell:snooze:{}",item["id"].as_str().unwrap())),"sessionId":item["sessionId"],"kind":"alarm","label":item["label"],"sourceEventId":item["sourceEventId"],"time":item.get("time").unwrap_or(&json!("")),"soundId":item.get("soundId").unwrap_or(&json!(""))});
            if let Some(options)=item.get("soundOptions").filter(|v|!v.is_null()){put(&mut event,"soundOptions",options.clone());}if let Some(w)=wall{put(&mut event,"occurredWallMs",json!(w));}
            if out["completion"].is_null(){put(&mut out,"completion",event);}else{if out.get("completionQueue").is_none(){put(&mut out,"completionQueue",json!([]));}out["completionQueue"].as_array_mut().ok_or("Invalid completion queue")?.push(event);}
        }else{remaining.push(item.clone());}
    }
    put(&mut out,"snoozes",json!(remaining));Ok(out)
}
pub fn resolve_recovery(timing:&Value,recovery_id:&str,decision:&str,command_id:&str,boot_id:&str,boot:u64,wall:Option<u64>)->Result<Value>{
    let mut out=timing.clone();let empty=json!([]);validate_recovery(out.get("legacySnoozesRecovery").unwrap_or(&empty))?;
    if recovery_id.is_empty() || !["resume","discard"].contains(&decision){return Err("Invalid snooze recovery decision".into());}
    let entries=out.get_mut("legacySnoozesRecovery").and_then(Value::as_array_mut).ok_or("Snooze recovery entry changed")?;
    let index=entries.iter().position(|v|v["id"]==recovery_id).ok_or("Snooze recovery entry changed")?;let item=entries.remove(index);
    if decision=="resume" {let deadline=boot.checked_add(item["remainingMs"].as_u64().unwrap()).ok_or("Invalid snooze")?;let entry=json!({"id":command_id,"bootId":boot_id,"deadlineBootMs":deadline,"sessionId":item["sessionId"],"label":item["label"],"sourceEventId":item["sourceEventId"],"time":"","provenance":item["provenance"]});if out.get("snoozes").is_none(){put(&mut out,"snoozes",json!([]));}out["snoozes"].as_array_mut().ok_or("Invalid snoozes")?.push(entry);validate(&out["snoozes"])?;}
    advance(&out,boot_id,boot,wall)
}
