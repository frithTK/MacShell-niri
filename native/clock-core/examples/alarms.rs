use serde_json::{json,Value};
use std::io::{self,BufRead};
fn main(){for line in io::stdin().lock().lines().map_while(std::result::Result::ok){let r:Value=serde_json::from_str(&line).unwrap();let value=macshell_clock_core::alarms::evaluate(&r["alarms"],&r["handled"],r["since"].as_u64().unwrap(),r["now"].as_u64().unwrap(),r["zone"].as_str().unwrap());println!("{}",match value{Ok((alarms,handled,events))=>json!({"success":true,"alarms":alarms,"handled":handled,"events":events}),Err(error)=>json!({"success":false,"error":error})});}}
