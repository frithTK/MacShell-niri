use serde_json::{json, Value};
use sha2::{Digest,Sha256};
use std::collections::HashSet;

type Result<T> = std::result::Result<T,String>;
pub const WINDOW_MS:u64=600000;
pub const MAX_RESULTS:usize=1024;

fn uuid(s:&str)->bool{s.len()==36 && s.bytes().enumerate().all(|(i,b)|if [8,13,18,23].contains(&i){b==b'-'}else{b.is_ascii_digit()||(b'a'..=b'f').contains(&b)})}
fn allowed(action:&str)->Option<&'static [&'static str]>{Some(match action{
    "start"=>&["sessionId","durationMs","label","replace","soundId","soundOptions"],
    "pause"|"resume"|"cancel"|"recover-remainder"|"recover-restart"|"stopwatch-start"|"stopwatch-pause"|"stopwatch-lap"|"stopwatch-reset"|"stopwatch-recover-resume"=>&["sessionId"],
    "claim-sound"|"dismiss-event"|"snooze"=>&["eventId"],
    "patch-settings"=>&["patch"],"recover-snooze"=>&["recoveryId","decision"],"repeat-timer"=>&["eventId","sessionId"],"ack-missed"=>&["kind","eventId"],_=>return None})}

pub struct Validated {pub id:String,pub issued:u64,pub revision:u64,pub action:String,pub args:Value,pub digest:String}
pub fn validate_envelope(envelope:&Value,boot_id:&str,boot_now:u64)->Result<Validated>{
    let object=envelope.as_object().ok_or("Invalid command envelope")?;
    if object.len()!=6 || ["id","bootId","issuedBootMs","revision","action","args"].iter().any(|key|!object.contains_key(*key)){return Err("Invalid command envelope".into());}
    let id=envelope["id"].as_str().filter(|s|uuid(s)).ok_or("Invalid command ID")?;
    let issued=envelope["issuedBootMs"].as_u64().ok_or("Command is outside its boot or delivery window")?;
    if boot_id.is_empty() || envelope["bootId"]!=boot_id || issued>boot_now || boot_now-issued>WINDOW_MS{return Err("Command is outside its boot or delivery window".into());}
    let revision=envelope["revision"].as_u64().ok_or("Invalid revision")?;
    let action=envelope["action"].as_str().ok_or("Invalid command action or arguments")?;
    let permitted=allowed(action).ok_or("Invalid command action or arguments")?;
    let args=envelope["args"].as_object().ok_or("Invalid command action or arguments")?;
    if args.keys().any(|key|!permitted.contains(&key.as_str())){return Err("Invalid command action or arguments".into());}
    if args.get("replace").is_some_and(|v|!v.is_boolean()){return Err("Invalid replacement flag".into());}
    let encoded=serde_json::to_vec(envelope).map_err(|_|"Invalid command data")?;
    Ok(Validated{id:id.into(),issued,revision,action:action.into(),args:envelope["args"].clone(),digest:format!("{:x}",Sha256::digest(encoded))})
}

pub struct Journal { pub active:Vec<Value>, pub replay:Option<Value> }
pub fn check_journal(journal:&Value,command:&Validated,boot_id:&str,boot_now:u64)->Result<Journal>{
    let records=journal.as_array().ok_or("Invalid command journal")?;let mut active=Vec::new();let mut seen=HashSet::new();
    for record in records {
        let id=record["id"].as_str().ok_or("Invalid command journal")?;
        let hash=record["hash"].as_str().ok_or("Invalid command journal")?;
        let result=record["result"].as_object().ok_or("Invalid command journal")?;
        let issued=record["issuedBootMs"].as_u64().ok_or("Invalid command journal")?;
        let boot=record["bootId"].as_str().ok_or("Invalid command journal")?;
        if boot==boot_id && issued>boot_now{return Err("Command journal is from a future boot time".into());}
        if boot==boot_id && boot_now-issued<=WINDOW_MS {
            if !seen.insert(id.to_owned()){return Err("Duplicate command journal ID".into());}
            active.push(record.clone());
            if id==command.id && hash!=command.digest{return Err("Command ID reused with different content".into());}
            let _=result;
        }
    }
    if let Some(record)=active.iter().find(|v|v["id"]==command.id){return Ok(Journal{replay:Some(record["result"].clone()),active});}
    if active.len()>=MAX_RESULTS{return Err("Command journal is full".into());}
    Ok(Journal{active,replay:None})
}
pub fn record(command:&Validated,boot_id:&str,result:&Value)->Value{json!({"id":command.id,"bootId":boot_id,"issuedBootMs":command.issued,"hash":command.digest,"result":result})}

pub fn system_zone()->Result<String>{
    if let Ok(tz)=std::env::var("TZ") {let tz=tz.trim_start_matches(':');if !tz.is_empty(){let zone=if tz.starts_with('/') {let path=std::fs::canonicalize(tz).map_err(|_|"Invalid alarm time zone")?;path.strip_prefix("/usr/share/zoneinfo").map_err(|_|"Invalid alarm time zone")?.to_string_lossy().into_owned()}else{tz.into()};return if zone.parse::<chrono_tz::Tz>().is_ok(){Ok(zone)}else{Err("Invalid alarm time zone".into())};}}
    if let Ok(path)=std::fs::canonicalize("/etc/localtime"){if let Ok(zone)=path.strip_prefix("/usr/share/zoneinfo"){let zone=zone.to_string_lossy().into_owned();if zone.parse::<chrono_tz::Tz>().is_ok(){return Ok(zone);}}}
    let zone=std::fs::read_to_string("/etc/timezone").map_err(|_|"Invalid alarm time zone")?;let zone=zone.trim();if zone.parse::<chrono_tz::Tz>().is_ok(){Ok(zone.into())}else{Err("Invalid alarm time zone".into())}
}

pub fn validate_presets(value:&Value)->Result<()> {
    let presets=value.as_object().filter(|v|v.len()<=64).ok_or("Invalid timer sound presets")?;
    for (key,entry) in presets {
        let valid=key.parse::<u64>().ok().filter(|n|(1..=604800000).contains(n)).is_some_and(|n|n.to_string()==*key);
        if !valid||!entry.is_object()||!crate::snooze::sound_id(entry.get("soundId").unwrap_or(&json!("")))||!crate::snooze::sound_options(entry.get("soundOptions")){return Err("Invalid timer sound preset".into());}
    }
    Ok(())
}

fn pop_event(timing:&mut Value)->Result<()> {
    let next=if let Some(queue)=timing.get_mut("completionQueue"){let queue=queue.as_array_mut().ok_or("Invalid completion queue")?;if queue.is_empty(){Value::Null}else{queue.remove(0)}}else{Value::Null};
    timing["completion"]=next;Ok(())
}
pub fn execute(store:&crate::store::ClockStore,envelope:&Value,boot_id:&str,boot:u64,wall:u64)->Result<Value>{
    let command=validate_envelope(envelope,boot_id,boot)?;
    let (document,token)=store.read()?;
    if document["version"]!=2{return Err("Clock data has not been migrated".into());}
    crate::timer::validate_timing(&document["timing"])?;
    let journal_value=document.get("commandResults").cloned().unwrap_or(json!([]));
    let journal=check_journal(&journal_value,&command,boot_id,boot)?;
    if let Some(replay)=journal.replay{return Ok(replay);}
    let revision=document["revision"].as_u64().ok_or("Invalid revision")?;
    if command.revision!=revision{return Err("Clock revision changed".into());}
    let args=&command.args;let action=command.action.as_str();
    let mut timing=crate::timer::advance_at(&document["timing"],boot_id,boot,Some(wall))?;
    let mut settings=Value::Null;
    let mut granted=None;
    match action {
        "stopwatch-start"|"stopwatch-pause"|"stopwatch-lap"|"stopwatch-reset"|"stopwatch-recover-resume"=>{
            if timing.get("stopwatch").is_none(){return Err("Stopwatch data has not been migrated".into());}
            timing["stopwatch"]=crate::command(&timing["stopwatch"],&action[10..],boot,args["sessionId"].as_str().unwrap_or(""),Some(wall))?;
        },
        "claim-sound"|"dismiss-event"|"snooze"=>{
            let id=args["eventId"].as_str().ok_or("Clock event changed")?;
            if !timing["completion"].is_object() || timing["completion"]["eventId"]!=id{return Err("Clock event changed".into());}
            if action=="claim-sound"{granted=Some(timing["completion"]["soundClaimed"]!=true);timing["completion"]["soundClaimed"]=json!(true);}
            else {if action=="snooze"{timing=crate::snooze::schedule(&timing,&timing["completion"],&command.id,boot_id,boot)?;}pop_event(&mut timing)?;}
        },
        "recover-snooze"=>{timing=crate::snooze::resolve_recovery(&timing,args["recoveryId"].as_str().unwrap_or(""),args["decision"].as_str().unwrap_or(""),&command.id,boot_id,boot,Some(wall))?;},
        "ack-missed"=>{
            let (field,key)=match args["kind"].as_str(){Some("alarm")=>("missedAlarms","eventId"),Some("snooze")=>("missedSnoozes","id"),_=>return Err("Invalid missed event".into())};
            let id=args["eventId"].as_str().filter(|v|!v.is_empty()).ok_or("Invalid missed event")?;
            let mut records=timing.get(field).cloned().unwrap_or(json!([]));let values=records.as_array_mut().ok_or("Invalid missed event list")?;let before=values.len();values.retain(|v|v[key]!=id);if values.len()+1!=before{return Err("Missed event changed".into());}timing[field]=records;
        },
        "patch-settings"=>{
            let patch=args["patch"].as_object().filter(|p|!p.is_empty() && p.keys().all(|k|["alarms","cities","recents"].contains(&k.as_str()))).ok_or("Invalid Clock settings")?;
            if let Some(alarms)=patch.get("alarms") {
                let empty=json!([]);let old=document.get("alarms").unwrap_or(&empty);
                let cursor=timing.get("alarmCursorWallMs").and_then(Value::as_u64).unwrap_or(wall);
                if old.as_array().is_some_and(|v|!v.is_empty()) && timing.get("alarmCursorBootId").and_then(Value::as_str).unwrap_or(boot_id)==boot_id && cursor<=wall {
                    let zone=system_zone()?;let handled=timing.get("handledAlarmDates").cloned().unwrap_or(json!({}));
                    let (_,_,events)=crate::alarms::evaluate(old,&handled,cursor,wall,&zone)?;
                    if !events.as_array().unwrap().is_empty(){return Err("Pending alarm must be processed before editing".into());}
                }
                crate::alarms::evaluate(alarms,&json!({}),wall,wall,"UTC")?;
                timing["alarmCursorWallMs"]=json!(wall);timing["alarmCursorBootId"]=json!(boot_id);
            }
            if let Some(cities)=patch.get("cities") {
                let cities=cities.as_array().filter(|v|v.len()<=256).ok_or("Invalid Clock cities")?;
                for city in cities {let name=city["name"].as_str().filter(|s|!s.is_empty()&&s.chars().count()<=200).ok_or("Invalid Clock cities")?;let _=name;let zone=city["tz"].as_str().filter(|s|!s.is_empty()).ok_or("Invalid Clock cities")?;zone.parse::<chrono_tz::Tz>().map_err(|_|"Invalid Clock cities")?;}
            }
            if let Some(recents)=patch.get("recents") {let recents=recents.as_array().filter(|v|v.len()<=6).ok_or("Invalid recent timer durations")?;if recents.iter().any(|v|!v.as_u64().is_some_and(|n|(1..=604800000).contains(&n))){return Err("Invalid recent timer durations".into());}}
            settings=args["patch"].clone();
        },
        "repeat-timer"=>{
            let event=args["eventId"].as_str().ok_or("Timer event changed")?;
            if !timing["completion"].is_object() || timing["completion"]["eventId"]!=event || timing["completion"].get("kind").is_some_and(|v|v!="timer"){return Err("Timer event changed".into());}
            if timing["timer"]["state"]!="idle"{return Err("A timer is already active".into());}
            let previous=timing["timer"].clone();pop_event(&mut timing)?;
            timing=crate::timer::command(&timing,crate::timer::Command{action:"start",boot_id,boot,wall:Some(wall),session:args["sessionId"].as_str(),duration:previous["totalMs"].as_u64(),label:previous["label"].as_str().unwrap_or(""),replace:false,sound:previous["soundId"].as_str().unwrap_or(""),sound_options:previous.get("soundOptions").filter(|v|!v.is_null()).cloned()})?;
        },
        "start"=>{
            let default_sound=json!("");let sound=args.get("soundId").unwrap_or(&default_sound);if !crate::snooze::sound_id(sound){return Err("Invalid timer sound".into());}
            if !crate::snooze::sound_options(args.get("soundOptions")){return Err("Invalid sound options".into());}
            timing=crate::timer::command(&document["timing"],crate::timer::Command{action,boot_id,boot,wall:Some(wall),session:args["sessionId"].as_str(),duration:args["durationMs"].as_u64(),label:args.get("label").map_or(Some(""),Value::as_str).ok_or("Invalid label")?,replace:args["replace"].as_bool().unwrap_or(false),sound:sound.as_str().unwrap(),sound_options:args.get("soundOptions").filter(|v|!v.is_null()).cloned()})?;
            let duration=args["durationMs"].as_u64().ok_or("Invalid duration")?;
            let empty=json!([]);let recents=document.get("recents").unwrap_or(&empty).as_array().ok_or("Invalid recent timer durations")?;
            if recents.len()>6 || recents.iter().any(|v|!v.as_u64().is_some_and(|n|(1..=604800000).contains(&n))){return Err("Invalid recent timer durations".into());}
            let mut new=vec![json!(duration)];for value in recents{if value!=duration&&new.len()<6{new.push(value.clone());}}
            let blank=json!({});let old=document.get("timerPresets").unwrap_or(&blank);validate_presets(old)?;let old=old.as_object().unwrap();
            let mut presets=serde_json::Map::new();for value in &new{let key=value.to_string();if let Some(preset)=old.get(&key){presets.insert(key,preset.clone());}}
            let key=duration.to_string();let mut preset=presets.remove(&key).unwrap_or(json!({}));preset["soundId"]=sound.clone();preset["soundOptions"]=args.get("soundOptions").cloned().unwrap_or(Value::Null);presets.insert(key,preset);
            settings=json!({"recents":new,"timerPresets":presets});
        },
        "pause"|"resume"|"cancel"|"recover-remainder"|"recover-restart"=>{
            timing=crate::timer::command(&document["timing"],crate::timer::Command{action,boot_id,boot,wall:Some(wall),session:args["sessionId"].as_str(),duration:None,label:"",replace:false,sound:"",sound_options:None})?;
        },
        _=>return Err("Clock command not yet supported".into()),
    }
    let projection=crate::timer::legacy_projection(&timing,boot,wall)?;
    let next=revision.checked_add(1).ok_or("Invalid revision")?;
    let mut result=json!({"revision":next,"timer":projection,"timing":timing});
    if let Some(v)=granted{result["soundGranted"]=json!(v);}
    let mut patch=json!({"timing":timing,"timer":projection,"ringing":crate::timer::legacy_ringing(&timing)});
    if settings.is_object(){for (key,value) in settings.as_object().unwrap(){patch[key]=value.clone();}result["settings"]=settings;}
    if timing.get("stopwatch").is_some(){let sw=crate::legacy_projection(&timing["stopwatch"],boot,wall)?;patch["sw"]=sw.clone();result["sw"]=sw;}
    let mut active=journal.active;active.push(record(&command,boot_id,&result));patch["commandResults"]=json!(active);
    store.commit(&patch,&token,revision)?;Ok(result)
}
