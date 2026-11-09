use macshell_clock_core::{audio::{ClockAudio,ClockPreview},commands,sound_catalog::SoundCatalog,store::ClockStore,timer};
use serde_json::{json,Value};
use std::io::{self,BufRead,Read,Write};
use std::path::{Path,PathBuf};
use std::sync::mpsc;
use std::sync::atomic::{AtomicBool,Ordering};
use std::time::{Duration,Instant,SystemTime,UNIX_EPOCH};

type Result<T> = std::result::Result<T,String>;
static STOP:AtomicBool=AtomicBool::new(false);
extern "C" fn stop_signal(_:libc::c_int){STOP.store(true,Ordering::Relaxed);}
fn times()->Result<(u64,u64)>{let mut ts:libc::timespec=unsafe{std::mem::zeroed()};if unsafe{libc::clock_gettime(libc::CLOCK_BOOTTIME,&mut ts)}!=0{return Err("Cannot read boot clock".into());}let boot=(ts.tv_sec as u64)*1000+(ts.tv_nsec as u64)/1_000_000;let wall=SystemTime::now().duration_since(UNIX_EPOCH).map_err(|e|e.to_string())?.as_millis() as u64;Ok((boot,wall))}
fn uuid()->Result<String>{let mut b=[0u8;16];std::fs::File::open("/dev/urandom").and_then(|mut f|f.read_exact(&mut b)).map_err(|e|e.to_string())?;b[6]=(b[6]&15)|0x40;b[8]=(b[8]&63)|0x80;Ok(format!("{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))}
fn emit(mut value:Value,generation:&Option<Value>){if let Some(g)=generation{value["generation"]=g.clone();}println!("{value}");let _=io::stdout().flush();}
fn state(doc:&Value,id:Value,boot_id:&str,boot:u64,wall:u64)->Result<Value>{let timing=&doc["timing"];Ok(json!({"type":"state","id":id,"revision":doc["revision"],"timing":timing,"bootId":boot_id,"bootNowMs":boot,"wallNowMs":wall,"timer":timer::legacy_projection(timing,boot,wall)?,"sw":macshell_clock_core::legacy_projection(&timing["stopwatch"],boot,wall)?,"ringing":timer::legacy_ringing(timing),"alarms":doc.get("alarms").unwrap_or(&json!([])),"cities":doc.get("cities").unwrap_or(&json!([{"name":"Cupertino","tz":"America/Los_Angeles"},{"name":"New York","tz":"America/New_York"},{"name":"London","tz":"Europe/London"},{"name":"Tokyo","tz":"Asia/Tokyo"}])),"recents":doc.get("recents").unwrap_or(&json!([])),"timerPresets":doc.get("timerPresets").unwrap_or(&json!({}))}))}
fn update(store:&ClockStore,boot_id:&str,boot:u64,wall:u64)->Result<bool>{
    let (doc,token)=store.read()?;let old=&doc["timing"];let mut timing=timer::advance_at(old,boot_id,boot,Some(wall))?;
    let checkpoint=|key:&str|timing[key]["state"]=="running"&&timing[key]["checkpointBootMs"].as_u64().is_some_and(|v|boot.saturating_sub(v)>=30000);
    if checkpoint("timer")||checkpoint("stopwatch"){timing=timer::checkpoint(&timing,boot_id,boot,Some(wall))?;}
    let mut alarms=doc.get("alarms").cloned().unwrap_or(json!([]));
    let list=alarms.as_array().ok_or("Invalid alarm state")?;
    if list.iter().any(|a|a["on"]==true){
        let cursor=timing.get("alarmCursorWallMs").map_or(Ok(wall),|v|v.as_u64().ok_or("Invalid alarm evaluation state"))?;
        let cursor_boot=timing.get("alarmCursorBootId").map_or(Ok(boot_id),|v|v.as_str().ok_or("Invalid alarm evaluation state"))?;
        let handled=timing.get("handledAlarmDates").cloned().unwrap_or(json!({}));
        if !handled.is_object(){return Err("Invalid alarm evaluation state".into());}
        let since=if cursor_boot!=boot_id||wall<cursor{wall}else{cursor};
        if timing.get("alarmCursorWallMs").is_none() || wall/60000>cursor/60000 || cursor_boot!=boot_id || wall<cursor {
            let zone=commands::system_zone()?;
            let (next_alarms,next_handled,events)=macshell_clock_core::alarms::evaluate(&alarms,&handled,since,wall,&zone)?;
            alarms=next_alarms;timing["handledAlarmDates"]=next_handled;timing["alarmCursorWallMs"]=json!(wall);timing["alarmCursorBootId"]=json!(boot_id);
            for event in events.as_array().ok_or("Invalid alarm events")? {
                if event["status"]=="missed" {if timing.get("missedAlarms").is_none(){timing["missedAlarms"]=json!([]);}timing["missedAlarms"].as_array_mut().ok_or("Invalid missed alarms")?.push(event.clone());}
                else if timing["completion"].is_null(){timing["completion"]=event.clone();}
                else {if timing.get("completionQueue").is_none(){timing["completionQueue"]=json!([]);}timing["completionQueue"].as_array_mut().ok_or("Invalid completion queue")?.push(event.clone());}
            }
        }
    }
    if timing==*old && alarms==doc.get("alarms").cloned().unwrap_or(json!([])){return Ok(false);}
    let patch=json!({"timing":timing,"alarms":alarms,"timer":timer::legacy_projection(&timing,boot,wall)?,"sw":macshell_clock_core::legacy_projection(&timing["stopwatch"],boot,wall)?,"ringing":timer::legacy_ringing(&timing)});store.commit(&patch,&token,doc["revision"].as_u64().ok_or("Invalid revision")?)?;Ok(true)
}
fn drive_audio(store:&ClockStore,audio:&mut ClockAudio,catalog:&SoundCatalog,boot_id:&str,boot:u64,wall:u64,generation:&Option<Value>)->Result<()>{
    let (doc,token)=store.read()?;let event=&doc["timing"]["completion"];
    if event.is_null(){audio.stop();return Ok(());}
    if event["soundClaimed"]==true{let failed=audio.failed;let fallback=audio.fallback_used;audio.tick(Some(event),boot);if !fallback&&audio.fallback_used{emit(json!({"type":"error","error":"Clock sound failed; using the built-in sound"}),generation);}if !failed&&audio.failed{emit(json!({"type":"error","error":"Clock sound playback failed"}),generation);}return Ok(());}
    audio.stop();let mut timing=doc["timing"].clone();timing["completion"]["soundClaimed"]=json!(true);
    let(saved,_)=store.commit(&json!({"timing":timing,"ringing":timer::legacy_ringing(&timing)}),&token,doc["revision"].as_u64().ok_or("Invalid revision")?)?;
    emit(state(&saved,Value::Null,boot_id,boot,wall)?,generation);
    let event=&saved["timing"]["completion"];if event["soundId"]=="silence"{return Ok(());}
    let id=event["soundId"].as_str().unwrap_or("");let selected=if id.is_empty(){None}else{match catalog.resolve(id){Ok(path)=>Some(path),Err(_)=>{emit(json!({"type":"error","error":"Clock sound failed; using the built-in sound"}),generation);Some(catalog.sounds.join(format!("{}.wav",event["kind"].as_str().ok_or("Invalid sound event")?)))}}};
    audio.start(event,boot,selected.as_deref())?;
    if audio.fallback_used{emit(json!({"type":"error","error":"Clock sound failed; using the built-in sound"}),generation);}
    if audio.failed{emit(json!({"type":"error","error":"Clock sound playback failed"}),generation);}
    Ok(())
}
fn sound_in_use(doc:&Value,id:&str)->bool{
    let timing=&doc["timing"];let timer=&timing["timer"];
    if timer["state"]!="idle"&&timer["soundId"]==id{return true;}
    if timing["completion"]["soundId"]==id{return true;}
    for list in [doc.get("alarms"),timing.get("completionQueue"),timing.get("snoozes")] {if list.and_then(Value::as_array).is_some_and(|values|values.iter().any(|v|v["soundId"]==id)){return true;}}
    false
}
fn validate_new_sounds(store:&ClockStore,catalog:Option<&SoundCatalog>,envelope:&Value,boot_id:&str,boot:u64)->Result<()> {
    let command=commands::validate_envelope(envelope,boot_id,boot)?;let(doc,_)=store.read()?;
    let empty=json!([]);let journal=commands::check_journal(doc.get("commandResults").unwrap_or(&empty),&command,boot_id,boot)?;
    if journal.replay.is_some(){return Ok(());}
    let args=&command.args;let mut ids=Vec::new();
    if command.action=="start"{ids.push(args.get("soundId").cloned().unwrap_or(json!("")));}
    if command.action=="patch-settings" {
        if let Some(alarms)=args["patch"]["alarms"].as_array(){for alarm in alarms{if let Some(id)=alarm["id"].as_str(){let previous=doc["alarms"].as_array().and_then(|v|v.iter().find(|old|old["id"]==id)).and_then(|old|old.get("soundId")).cloned().unwrap_or(json!(""));let selected=alarm.get("soundId").cloned().unwrap_or(json!(""));if selected!=previous{ids.push(selected);}}}}
    }
    for id in ids {let id=id.as_str().ok_or("Invalid sound ID")?;if id.is_empty()||id=="silence"{continue;}catalog.ok_or("Clock sounds are unavailable")?.resolve(id)?;}
    Ok(())
}
fn run(path:&Path,audio_paths:Option<(PathBuf,PathBuf,PathBuf)>)->Result<()>{
    let store=ClockStore::open(path)?;let boot_id=std::fs::read_to_string("/proc/sys/kernel/random/boot_id").map_err(|e|e.to_string())?.trim().to_string();let (boot,wall)=times()?;let (doc,token)=store.read()?;
    commands::validate_presets(doc.get("timerPresets").unwrap_or(&json!({})))?;
    let alarms=doc.get("alarms").unwrap_or(&json!([])).clone();let alarms=alarms.as_array().ok_or("Invalid alarm state")?;
    if !alarms.is_empty(){macshell_clock_core::alarms::evaluate(&json!(alarms),&json!({}),wall,wall,&commands::system_zone()?)?;}
    if token=="missing"{let mut timing=timer::migrate_legacy(&json!({"state":"idle","total":300000,"left":300000,"label":""}),&boot_id,boot,wall,&uuid()?)?;timing["stopwatch"]=macshell_clock_core::migrate_legacy(&json!({"running":false,"startAt":0,"acc":0,"laps":[]}),boot,wall,&uuid()?)?;timing["legacySnoozesRecovery"]=json!([]);store.set_initial(json!({"version":2,"revision":0,"timing":timing,"timer":timer::legacy_projection(&timing,boot,wall)?,"sw":macshell_clock_core::legacy_projection(&timing["stopwatch"],boot,wall)?,"ringing":null}));}
    else if doc.get("version").is_none()||doc["version"]==0 {
        let legacy_timer=doc.get("timer").cloned().unwrap_or(json!({"state":"idle","total":300000,"left":300000,"label":""}));
        let mut timing=timer::migrate_legacy(&legacy_timer,&boot_id,boot,wall,&uuid()?)?;
        let legacy_sw=doc.get("sw").cloned().unwrap_or(json!({"running":false,"startAt":0,"acc":0,"laps":[]}));
        timing["stopwatch"]=macshell_clock_core::migrate_legacy(&legacy_sw,boot,wall,&uuid()?)?;
        let snoozes=doc.get("snoozes").cloned().unwrap_or(json!([]));let mut recovered=Vec::new();
        for item in snoozes.as_array().ok_or("Invalid legacy snoozes")? {
            let at=item["at"].as_u64().ok_or("Invalid legacy snooze")?;let label=item.get("label").map_or(Some(""),Value::as_str).filter(|s|s.chars().count()<=200).ok_or("Invalid legacy snooze")?;
            if item.get("defaultLabel").is_some_and(|v|!v.is_boolean()){return Err("Invalid legacy snooze".into());}
            recovered.push(json!({"id":uuid()?,"sessionId":uuid()?,"sourceEventId":uuid()?,"label":label,"remainingMs":at.saturating_sub(wall).min(macshell_clock_core::snooze::SNOOZE_MS),"capturedWallMs":wall,"provenance":"legacy-wall-clock","legacy":item}));
        }
        timing["legacySnoozesRecovery"]=json!(recovered);
        if let Some(event)=doc.get("ringing").filter(|v|!v.is_null()) {
            let kind=event["kind"].as_str().filter(|v|["timer","alarm"].contains(v)).ok_or("Invalid legacy ringing event")?;
            let label=event.get("label").map_or(Some(""),Value::as_str).ok_or("Invalid legacy ringing event")?;
            let time=event.get("time").map_or(Some(""),Value::as_str).ok_or("Invalid legacy ringing event")?;
            let default=match event.get("defaultLabel"){None=>label.is_empty(),Some(v)=>v.as_bool().ok_or("Invalid legacy ringing event")?};
            timing["completion"]=json!({"eventId":uuid()?,"sessionId":uuid()?,"kind":kind,"label":label,"time":time,"defaultLabel":default,"soundClaimed":true});
        }
        timing["alarmCursorWallMs"]=json!(wall.saturating_sub(wall%60000).saturating_sub(1));timing["alarmCursorBootId"]=json!(boot_id);timing["handledAlarmDates"]=json!({});
        store.commit(&json!({"timing":timing,"timer":timer::legacy_projection(&timing,boot,wall)?,"sw":macshell_clock_core::legacy_projection(&timing["stopwatch"],boot,wall)?,"ringing":timer::legacy_ringing(&timing),"snoozes":[]}),&token,0)?;
    }
    else if doc["version"]!=2{return Err("Prototype requires migrated Clock data".into());}
    else if doc["timing"].get("stopwatch").is_none(){
        let mut timing=doc["timing"].clone();let mut legacy=doc.get("sw").cloned().unwrap_or(json!({"running":false,"startAt":0,"acc":0,"laps":[]}));
        let boot_changed=timing["bootId"]!=boot_id;let was_running=legacy["running"]==true;if boot_changed&&was_running{legacy["running"]=json!(false);}
        let mut stopwatch=macshell_clock_core::migrate_legacy(&legacy,boot,wall,&uuid()?)?;
        if boot_changed&&(was_running||stopwatch["state"]=="paused"){stopwatch["state"]=json!("recovery");}
        timing["stopwatch"]=stopwatch;store.commit(&json!({"timing":timing,"sw":macshell_clock_core::legacy_projection(&timing["stopwatch"],boot,wall)?}),&token,doc["revision"].as_u64().ok_or("Invalid revision")?)?;
    }
    let (validated,_)=store.read()?;timer::validate_timing(&validated["timing"])?;
    update(&store,&boot_id,boot,wall)?;
    let (tx,rx)=mpsc::channel();std::thread::spawn(move||{for line in io::stdin().lock().lines(){match line{Ok(v)=>if tx.send(v).is_err(){break},Err(_)=>break}}});
    let mut audio=audio_paths.map(|(sound,builtin,worker)|{let catalog=SoundCatalog{library:sound.join("library"),sounds:builtin.clone()};let preview=ClockPreview::new(worker.clone());(ClockAudio::new(sound,builtin,worker),catalog,preview)});
    let mut generation=None;emit(json!({"type":"ready"}),&generation);
    let interval=Duration::from_millis(200);let mut next_update=Instant::now()+interval;
    while !STOP.load(Ordering::Relaxed){
        if Instant::now()>=next_update {let(boot,wall)=times()?;if update(&store,&boot_id,boot,wall)?{let(doc,_)=store.read()?;emit(state(&doc,Value::Null,&boot_id,boot,wall)?,&generation);}next_update=Instant::now()+interval;}
        match rx.recv_timeout(next_update.saturating_duration_since(Instant::now())){
            Ok(line)=>{
                let request:Value=match serde_json::from_str(&line){Ok(v)=>v,Err(_)=>{emit(json!({"type":"error","error":"Invalid service request"}),&generation);continue;}};
                if !request.is_object()||!request.get("data").is_none_or(Value::is_object)||request.get("generation").is_none(){emit(json!({"type":"error","error":"Invalid service request"}),&generation);continue;}
                generation=request.get("generation").cloned();let id=request.get("id").cloned().unwrap_or(Value::Null);let (boot,wall)=times()?;
                let result:Result<Vec<Value>>=(||match request["action"].as_str().unwrap_or(""){
                    "load"=>{let(doc,_)=store.read()?;Ok(vec![state(&doc,id.clone(),&boot_id,boot,wall)?])},
                    "prepare"=>{let changed=update(&store,&boot_id,boot,wall)?;let(doc,_)=store.read()?;let mut messages=Vec::new();if changed{messages.push(state(&doc,Value::Null,&boot_id,boot,wall)?);}messages.push(json!({"type":"prepared","id":id,"commandId":uuid()?,"sessionId":uuid()?,"bootId":boot_id,"issuedBootMs":boot,"revision":doc["revision"]}));Ok(messages)},
                    "command"=>{validate_new_sounds(&store,audio.as_ref().map(|(_,catalog,_)|catalog),&request["data"],&boot_id,boot)?;let result=commands::execute(&store,&request["data"],&boot_id,boot,wall)?;let(doc,_)=store.read()?;Ok(vec![json!({"type":"result","id":id,"success":true,"result":result}),state(&doc,Value::Null,&boot_id,boot,wall)?])},
                    "sounds"=>{let(_,catalog,_)=audio.as_ref().ok_or("Clock sounds are unavailable")?;let mut value=catalog.state()?;value["type"]=json!("sounds");value["id"]=id.clone();Ok(vec![value])},
                    "set-builtins-visible"|"favorite-sound"=>{let(_,catalog,_)=audio.as_ref().ok_or("Clock sounds are unavailable")?;let data=&request["data"];if request["action"]=="set-builtins-visible"{catalog.set_visible(data["visible"].as_bool().ok_or("Invalid sound visibility")?)?;}else{catalog.set_favorite(data["soundId"].as_str().ok_or("Invalid sound ID")?,data["favorite"].as_bool().ok_or("Invalid favorite state")?)?;}let mut value=catalog.state()?;value["type"]=json!("sounds");value["id"]=id.clone();Ok(vec![value])},
                    "rename-sound"=>{let(_,catalog,_)=audio.as_ref().ok_or("Clock sounds are unavailable")?;let data=&request["data"];catalog.rename_imported(data["soundId"].as_str().ok_or("Invalid sound ID")?,data["name"].as_str().ok_or("Invalid sound name")?)?;let mut value=catalog.state()?;value["type"]=json!("sounds");value["id"]=id.clone();Ok(vec![value])},
                    "preview-sound"=>{let changed=update(&store,&boot_id,boot,wall)?;let(doc,_)=store.read()?;if changed{emit(state(&doc,Value::Null,&boot_id,boot,wall)?,&generation);}let(audio,catalog,preview)=audio.as_mut().ok_or("Clock sounds are unavailable")?;if !doc["timing"]["completion"].is_null(){return Err("An alert is active".into());}let data=&request["data"];let sound=data["soundId"].as_str().ok_or("Invalid sound ID")?;if sound=="silence"{preview.stop();return Ok(vec![json!({"type":"sound-preview","id":id,"soundId":"","playing":false})]);}let path=if sound.is_empty(){let kind=data["kind"].as_str().filter(|v|["timer","alarm"].contains(v)).ok_or("Invalid preview kind")?;let custom=audio.default_path(kind);if custom.is_file(){custom}else{catalog.sounds.join(format!("{kind}.wav"))}}else{catalog.resolve(sound)?};preview.start(if sound.is_empty(){"default"}else{sound},&path,boot,data.get("soundOptions"))?;Ok(vec![json!({"type":"sound-preview","id":id,"soundId":if sound.is_empty(){"default"}else{sound},"playing":true})])},
                    "stop-preview"=>{if let Some((_,_,preview))=audio.as_mut(){preview.stop();}Ok(vec![json!({"type":"sound-preview","id":id,"soundId":"","playing":false})])},
                    "delete-sound"=>{
                        let(_,catalog,preview)=audio.as_mut().ok_or("Clock sounds are unavailable")?;let sound=request["data"]["soundId"].as_str().ok_or("Invalid sound ID")?;let(doc,token)=store.read()?;if sound_in_use(&doc,sound){return Err("Sound is in use".into());}if preview.sound_id.as_deref()==Some(sound){preview.stop();emit(json!({"type":"sound-preview","soundId":"","playing":false}),&generation);}
                        let cleaned=catalog.delete_imported(sound)?;let mut timing=doc["timing"].clone();let mut presets=doc.get("timerPresets").cloned().unwrap_or(json!({}));let mut changed=false;
                        if timing["timer"]["state"]=="idle"&&timing["timer"]["soundId"]==sound{timing["timer"].as_object_mut().ok_or("Invalid timer")?.remove("soundId");changed=true;}
                        for preset in presets.as_object_mut().ok_or("Invalid timer sound presets")?.values_mut(){if preset["soundId"]==sound{preset["soundId"]=json!("");changed=true;}}
                        let mut messages=Vec::new();if changed{let(saved,_)=store.commit(&json!({"timing":timing,"timerPresets":presets}),&token,doc["revision"].as_u64().ok_or("Invalid revision")?)?;messages.push(state(&saved,Value::Null,&boot_id,boot,wall)?);}
                        let mut value=catalog.state()?;value["type"]=json!("sounds");value["id"]=id.clone();value["warning"]=json!(if cleaned{""}else{"Sound file cleanup failed"});messages.push(value);Ok(messages)
                    },
                    _=>Err("Prototype action not supported".into()),
                })();
                match result{Ok(messages)=>for message in messages{emit(message,&generation)},Err(e)=>emit(json!({"type":"result","id":id,"success":false,"error":e}),&generation)}
            },
            Err(mpsc::RecvTimeoutError::Disconnected)=>break,
            Err(mpsc::RecvTimeoutError::Timeout)=>{},
        }
        if let Some((audio,catalog,preview))=audio.as_mut(){let(boot,wall)=times()?;let(doc,_)=store.read()?;if !doc["timing"]["completion"].is_null()&&preview.sound_id.is_some(){preview.stop();emit(json!({"type":"sound-preview","soundId":"","playing":false}),&generation);}else if preview.sound_id.is_some(){let failed=preview.tick(boot);if preview.sound_id.is_none(){emit(json!({"type":"sound-preview","soundId":"","playing":false,"error":if failed{"Clock sound playback failed"}else{""}}),&generation);}}drive_audio(&store,audio,catalog,&boot_id,boot,wall,&generation)?;}
    }Ok(())
}
fn main(){unsafe{libc::signal(libc::SIGTERM,stop_signal as *const () as libc::sighandler_t);libc::signal(libc::SIGINT,stop_signal as *const () as libc::sighandler_t);libc::signal(libc::SIGHUP,stop_signal as *const () as libc::sighandler_t);}let args:Vec<_>=std::env::args().skip(1).collect();if args==["--protocol-version"]{println!("macshell-clock-service 1");return;}if !(args.len()==3||args.len()==9)||args[0]!="--prototype"||args[1]!="--store"{eprintln!("Usage: clock-service-prototype --prototype --store PATH [--audio-dir DIR --builtin-dir DIR --audio-worker PATH]");std::process::exit(2);}let audio=if args.len()==9&&args[3]=="--audio-dir"&&args[5]=="--builtin-dir"&&args[7]=="--audio-worker"{Some((PathBuf::from(&args[4]),PathBuf::from(&args[6]),PathBuf::from(&args[8])))}else if args.len()==3{None}else{std::process::exit(2)};if let Err(error)=run(Path::new(&args[2]),audio){emit(json!({"type":"unavailable","error":error}),&None);std::process::exit(1);}}
