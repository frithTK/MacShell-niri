mod scheduler;
mod store;
use serde_json::{json,Value};
use std::io::{self,BufRead,Write};
use std::path::Path;
use std::sync::mpsc;
use std::time::{Duration,Instant};

fn emit(value:Value){println!("{value}");let _=io::stdout().flush();}
fn main(){
    let args:Vec<_>=std::env::args().skip(1).collect();
    if args==["--protocol-version"]{println!("macshell-reminders-service 1");return;}
    if args.len()!=2 || args[0]!="--store"{eprintln!("Expected --store PATH");std::process::exit(2);}
    let path=Path::new(&args[1]);let db=match store::open(path){Ok(v)=>v,Err(e)=>{emit(json!({"type":"unavailable","error":e}));std::process::exit(1);}};
    let mut scheduler=scheduler::Scheduler::new(path);let mut state="";let mut version:i64=db.query_row("PRAGMA data_version",[],|r|r.get(0)).unwrap_or(0);let mut next=Instant::now();
    let (tx,rx)=mpsc::channel();std::thread::spawn(move||{for line in io::stdin().lock().lines(){match line{Ok(v)=>if tx.send(v).is_err(){break},Err(_)=>break}}});
    emit(json!({"type":"hello"}));
    loop {
        match rx.recv_timeout(next.saturating_duration_since(Instant::now())) {
            Ok(line)=>{let request:Value=serde_json::from_str(&line).unwrap_or(Value::Null);let response=match store::handle(&db,request["action"].as_str().unwrap_or(""),&request["data"]){Ok(v)=>json!({"type":"result","success":true,"result":v,"id":request["id"]}),Err(e)=>json!({"type":"result","success":false,"error":e,"id":request["id"]})};emit(response);},
            Err(mpsc::RecvTimeoutError::Disconnected)=>break,
            Err(mpsc::RecvTimeoutError::Timeout)=>(),
        }
        if Instant::now()>=next {
            next=Instant::now()+Duration::from_secs(1);
            match scheduler.tick(&db,store::now()) {
                Ok(mut changed)=>{if let Ok(v)=db.query_row("PRAGMA data_version",[],|r|r.get::<_,i64>(0)){if v!=version{version=v;changed=true;}}let new=if scheduler.error{"unavailable"}else if scheduler.owner{"owner"}else{"standby"};if new!=state{state=new;emit(json!({"type":"scheduler","state":state}));}if changed{emit(json!({"type":"changed"}));}},
                Err(_)=>{let _=db.execute_batch("ROLLBACK");if state!="unavailable"{state="unavailable";emit(json!({"type":"scheduler","state":state}));}}
            }
        }
    }
}
