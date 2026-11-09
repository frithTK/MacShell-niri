use macshell_clock_core::timer::{self,Command};
use serde_json::{json,Value};
use std::io::{self,BufRead};
fn main(){for line in io::stdin().lock().lines().map_while(std::result::Result::ok){let r:Value=serde_json::from_str(&line).unwrap();let boot=r["boot"].as_u64().unwrap_or(0);let boot_id=r["bootId"].as_str().unwrap_or("");let wall=r.get("wall").and_then(Value::as_u64);let value=&r["value"];
let result=match r["op"].as_str().unwrap_or(""){
"migrate"=>timer::migrate_legacy(value,boot_id,boot,wall.unwrap(),r["session"].as_str().unwrap()),
"advance"=>timer::advance(value,boot_id,boot),
"checkpoint"=>timer::checkpoint(value,boot_id,boot,wall),
"command"=>timer::command(value,Command{action:r["action"].as_str().unwrap(),boot_id,boot,wall,session:r["session"].as_str(),duration:r["duration"].as_u64(),label:r["label"].as_str().unwrap_or(""),replace:r["replace"].as_bool().unwrap_or(false),sound:r["sound"].as_str().unwrap_or(""),sound_options:r.get("soundOptions").filter(|v|!v.is_null()).cloned()}),
_=>Err("Unknown operation".into())};println!("{}",match result{Ok(v)=>json!({"success":true,"result":v}),Err(e)=>json!({"success":false,"error":e})});}}
