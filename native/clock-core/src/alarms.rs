use chrono::{Datelike,Duration,LocalResult,NaiveDate,TimeZone,Utc};
use chrono_tz::Tz;
use serde_json::{json,Value};
use sha2::{Digest,Sha256};
use std::collections::HashSet;

type Result<T> = std::result::Result<T,String>;

fn resolve(zone:Tz,day:NaiveDate,hour:u32,minute:u32)->Result<chrono::DateTime<Utc>> {
    let local=day.and_hms_opt(hour,minute,0).ok_or("Invalid alarm time")?;
    let choose=|v|match zone.from_local_datetime(&v){LocalResult::Single(t)=>Some(t.with_timezone(&Utc)),LocalResult::Ambiguous(a,b)=>Some(a.with_timezone(&Utc).min(b.with_timezone(&Utc))),LocalResult::None=>None};
    if let Some(v)=choose(local){return Ok(v);}
    for offset in 1..=2880 {let candidate=local.checked_add_signed(Duration::minutes(offset)).ok_or("Invalid alarm date")?;if choose(candidate).is_some(){let previous=candidate.checked_sub_signed(Duration::minutes(1)).ok_or("Invalid alarm date")?;for second in 1..=60{if let Some(v)=choose(previous.checked_add_signed(Duration::seconds(second)).ok_or("Invalid alarm date")?){return Ok(v);}}}}
    Err("No valid local alarm time".into())
}
fn utc(ms:u64)->Result<chrono::DateTime<Utc>>{let ms=i64::try_from(ms).map_err(|_|"Invalid alarm evaluation time")?;Utc.timestamp_millis_opt(ms).single().ok_or_else(||"Invalid alarm evaluation time".into())}
pub fn evaluate(alarms:&Value,handled:&Value,since_ms:u64,now_ms:u64,system_zone:&str)->Result<(Value,Value,Value)>{
    if !alarms.is_array()||!handled.is_object(){return Err("Invalid alarm state".into());}
    let system:Tz=system_zone.parse().map_err(|_|"Invalid alarm time zone")?;let since=utc(since_ms)?;let now=utc(now_ms)?;
    if now<since{return Ok((alarms.clone(),handled.clone(),json!([])));}
    let mut alarms=alarms.clone();let mut handled=handled.clone();let mut events=Vec::new();let mut ids=HashSet::new();
    for alarm in alarms.as_array_mut().unwrap(){
        let id=alarm["id"].as_str().filter(|s|!s.is_empty()).ok_or("Invalid alarm ID")?.to_owned();if !ids.insert(id.clone()){return Err("Duplicate alarm ID".into());}
        let enabled=alarm["on"].as_bool().ok_or("Invalid alarm enabled flag")?;
        let days=alarm["days"].as_array().ok_or("Invalid alarm repeat days")?;let mut unique=HashSet::new();for day in days{let n=day.as_u64().filter(|n|*n<=6).ok_or("Invalid alarm repeat days")?;if !unique.insert(n){return Err("Duplicate alarm repeat day".into());}}
        let label=alarm.get("label").map_or(Some(""),Value::as_str).filter(|s|s.chars().count()<=200).ok_or("Invalid alarm label")?.to_owned();
        if !crate::snooze::sound_id(alarm.get("soundId").unwrap_or(&json!(""))){return Err("Invalid alarm sound".into());}if !crate::snooze::sound_options(alarm.get("soundOptions")){return Err("Invalid sound options".into());}
        let hour=alarm["h"].as_u64().filter(|n|*n<=23).ok_or("Invalid alarm time")? as u32;let minute=alarm["m"].as_u64().filter(|n|*n<=59).ok_or("Invalid alarm time")? as u32;
        let mut seen=HashSet::new();if let Some(stored)=handled.get(&id){for item in stored.as_array().ok_or("Invalid handled alarm dates")?{let s=item.as_str().ok_or("Invalid handled alarm dates")?;let date=NaiveDate::parse_from_str(s,"%Y-%m-%d").map_err(|_|"Invalid handled alarm dates")?;seen.insert(date);}}
        if !enabled{continue;}
        let (zone,key)=match alarm.get("zone"){None|Some(Value::Null)=>(system,system_zone.to_string()),Some(v)=>{let s=v.as_str().filter(|s|!s.is_empty()).ok_or("Invalid alarm time zone")?;(s.parse().map_err(|_|"Invalid alarm time zone")?,s.to_string())}};
        let weekly=!days.is_empty();let anchor=if weekly{now.with_timezone(&zone).date_naive()}else{since.with_timezone(&zone).date_naive()};
        let mut candidates=Vec::new();
        for offset in if weekly{-9..=0}else{-1..=2}{
            let day=anchor.checked_add_signed(Duration::days(offset)).ok_or("Invalid alarm date")?;
            if weekly&&!unique.contains(&(day.weekday().num_days_from_sunday() as u64)){continue;}
            let instant=resolve(zone,day,hour,minute)?;
            if since<instant&&instant<=now{candidates.push((instant,day));}
        }
        candidates.sort();
        let chosen=if weekly{candidates.pop()}else{candidates.into_iter().find(|(_,day)|!seen.contains(day))};
        let Some((instant,day))=chosen else{continue};if seen.contains(&day){continue;}
        let day_text=day.format("%Y-%m-%d").to_string();
        if handled.get(&id).is_none(){handled[&id]=json!([]);}handled[&id].as_array_mut().unwrap().push(json!(day_text));
        if !weekly{alarm["on"]=json!(false);}
        let identity=serde_json::to_vec(&json!([id,day_text,key,hour,minute])).map_err(|e|e.to_string())?;
        let event_id=format!("{:x}",Sha256::digest(identity));
        let scheduled=instant.format("%Y-%m-%dT%H:%M:%S+00:00").to_string();
        let mut event=json!({"eventId":event_id,"sessionId":id,"kind":"alarm","label":label,"localDate":day_text,"zone":key,"scheduledAt":scheduled,"status":if now.signed_duration_since(instant)<=Duration::minutes(15){"due"}else{"missed"},"hour":hour,"minute":minute,"time":format!("{hour:02}:{minute:02}"),"soundId":alarm.get("soundId").unwrap_or(&json!(""))});
        if let Some(options)=alarm.get("soundOptions").filter(|v|!v.is_null()){event["soundOptions"]=options.clone();}events.push(event);
    }
    events.sort_by(|a,b|a["scheduledAt"].as_str().cmp(&b["scheduledAt"].as_str()).then_with(||a["eventId"].as_str().cmp(&b["eventId"].as_str())));
    Ok((alarms,handled,json!(events)))
}
