use serde_json::{json, Value};
use std::io::{self, BufRead};

fn main() {
    for line in io::stdin().lock().lines().map_while(std::result::Result::ok) {
        let request:Value=serde_json::from_str(&line).unwrap();
        let value=&request["value"];let boot=request["boot"].as_u64().unwrap_or(0);let wall=request.get("wall").and_then(Value::as_u64);
        let result=match request["op"].as_str().unwrap_or("") {
            "validate"=>macshell_clock_core::validate(value).map(|_|value.clone()),
            "migrate"=>macshell_clock_core::migrate_legacy(value,boot,wall.unwrap(),request["session"].as_str().unwrap()),
            "elapsed"=>macshell_clock_core::elapsed(value,boot).map(|v|json!(v)),
            "restore"=>Ok(macshell_clock_core::restore(value,request["changed"].as_bool().unwrap_or(false))),
            "checkpoint"=>macshell_clock_core::checkpoint(value,boot,wall),
            "command"=>macshell_clock_core::command(value,request["action"].as_str().unwrap(),boot,request["session"].as_str().unwrap(),wall),
            "projection"=>macshell_clock_core::legacy_projection(value,boot,wall.unwrap()),
            _=>Err("Unknown operation".into()),
        };
        println!("{}",match result{Ok(v)=>json!({"success":true,"result":v}),Err(e)=>json!({"success":false,"error":e})});
    }
}
