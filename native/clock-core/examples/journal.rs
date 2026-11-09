use macshell_clock_core::commands::{validate_envelope,check_journal,record};
use serde_json::{json,Value};
use std::io::{self,BufRead};
fn main(){for line in io::stdin().lock().lines().map_while(std::result::Result::ok){let r:Value=serde_json::from_str(&line).unwrap();let boot=r["bootId"].as_str().unwrap();let now=r["now"].as_u64().unwrap();let result=validate_envelope(&r["envelope"],boot,now).and_then(|c|{let journal=check_journal(&r["journal"],&c,boot,now)?;Ok(json!({"digest":c.digest,"active":journal.active,"replay":journal.replay,"record":record(&c,boot,&json!({}))}))});println!("{}",match result{Ok(v)=>json!({"success":true,"result":v}),Err(e)=>json!({"success":false,"error":e})});}}
