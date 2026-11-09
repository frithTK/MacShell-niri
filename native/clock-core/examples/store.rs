use macshell_clock_core::store::ClockStore;
use serde_json::{json,Value};
use std::io::{self,BufRead,Write};

fn main(){
    let path=std::env::args().nth(1).unwrap();
    let store=match ClockStore::open(path){Ok(v)=>v,Err(e)=>{println!("{}",json!({"success":false,"error":e}));return;}};
    println!("{}",json!({"ready":true}));let _=io::stdout().flush();
    for line in io::stdin().lock().lines().map_while(std::result::Result::ok){
        let v:Value=serde_json::from_str(&line).unwrap();
        let result=match v["op"].as_str(){Some("read")=>store.read(),Some("commit")=>store.commit(&v["patch"],v["token"].as_str().unwrap(),v["revision"].as_u64().unwrap()),_=>Err("Unknown operation".into())};
        println!("{}",match result{Ok((document,token))=>json!({"success":true,"document":document,"token":token}),Err(e)=>json!({"success":false,"error":e})});let _=io::stdout().flush();
    }
}
