use macshell_clock_core::{commands,store::ClockStore};
use serde_json::{json,Value};
use std::io::{self,BufRead,Write};
fn main(){let path=std::env::args().nth(1).unwrap();let store=ClockStore::open(path).unwrap();println!("{}",json!({"ready":true}));let _=io::stdout().flush();for line in io::stdin().lock().lines().map_while(std::result::Result::ok){let r:Value=serde_json::from_str(&line).unwrap();let value=commands::execute(&store,&r["envelope"],r["bootId"].as_str().unwrap(),r["boot"].as_u64().unwrap(),r["wall"].as_u64().unwrap());println!("{}",match value{Ok(v)=>json!({"success":true,"result":v}),Err(e)=>json!({"success":false,"error":e})});let _=io::stdout().flush();}}
