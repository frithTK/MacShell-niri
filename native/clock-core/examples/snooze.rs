use macshell_clock_core::{snooze,timer};
use serde_json::{json,Value};
use std::io::{self,BufRead};
fn main(){for line in io::stdin().lock().lines().map_while(std::result::Result::ok){let r:Value=serde_json::from_str(&line).unwrap();let value=&r["value"];let boot=r["boot"].as_u64().unwrap_or(0);let boot_id=r["bootId"].as_str().unwrap_or("");let wall=r.get("wall").and_then(Value::as_u64);let result=match r["op"].as_str().unwrap_or(""){
"schedule"=>snooze::schedule(value,&r["event"],r["id"].as_str().unwrap(),boot_id,boot),
"advance"=>timer::advance_at(value,boot_id,boot,wall),
"resolve"=>snooze::resolve_recovery(value,r["id"].as_str().unwrap(),r["decision"].as_str().unwrap(),r["commandId"].as_str().unwrap(),boot_id,boot,wall),
"validate"=>snooze::validate(value).map(|_|value.clone()),
_=>Err("Unknown operation".into())};println!("{}",match result{Ok(v)=>json!({"success":true,"result":v}),Err(e)=>json!({"success":false,"error":e})});}}
