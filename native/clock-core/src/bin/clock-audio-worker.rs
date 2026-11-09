use serde_json::Value;
use std::os::unix::process::CommandExt;
use std::process::{Child,Command,Stdio};
use std::sync::atomic::{AtomicBool,Ordering};
use std::time::{Duration,Instant};

static STOP:AtomicBool=AtomicBool::new(false);
extern "C" fn signal(_:libc::c_int){STOP.store(true,Ordering::Relaxed);}
fn protect(command:&mut Command){unsafe{command.pre_exec(||{if libc::prctl(libc::PR_SET_PDEATHSIG,libc::SIGTERM)!=0{return Err(std::io::Error::last_os_error());}if libc::getppid()==1{return Err(std::io::Error::other("parent exited"));}Ok(())});}}
fn stop(child:&mut Child){if child.try_wait().ok().flatten().is_none(){unsafe{libc::kill(child.id() as i32,libc::SIGTERM)};let deadline=Instant::now()+Duration::from_secs(1);while Instant::now()<deadline{if child.try_wait().ok().flatten().is_some(){return;}std::thread::sleep(Duration::from_millis(10));}let _=child.kill();}let _=child.wait();}
fn number(v:&Value,key:&str,default:u64,max:u64)->Result<u64,()>{match v.get(key){None=>Ok(default),Some(v)=>v.as_u64().filter(|n|*n<=max).ok_or(())}}
fn run(path:&str,settings:&Value)->Result<(),()>{
    if !settings.is_object()&&!settings.is_null(){return Err(());}
    let volume=number(settings,"volume",90,100)?;let fade=number(settings,"fadeMs",0,60000)?;let start=number(settings,"startMs",0,600000)?;let duration=number(settings,"durationMs",0,600000)?;let elapsed=number(settings,"fadeElapsedMs",0,u64::MAX)?;
    if settings.get("repeat").is_some_and(|v|!v.is_boolean()){return Err(());}
    if start>0 {
        let mut probe=Command::new("ffprobe");probe.args(["-v","error","-protocol_whitelist","file,pipe","-show_entries","format=duration","-of","json",path]).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());protect(&mut probe);
        let mut child=probe.spawn().map_err(|_|())?;let deadline=Instant::now()+Duration::from_secs(10);
        while child.try_wait().map_err(|_|())?.is_none(){if STOP.load(Ordering::Relaxed)||Instant::now()>=deadline{stop(&mut child);return Err(());}std::thread::sleep(Duration::from_millis(10));}
        let output=child.wait_with_output().map_err(|_|())?;if !output.status.success(){return Err(());}let data:Value=serde_json::from_slice(&output.stdout).map_err(|_|())?;let length=data["format"]["duration"].as_str().and_then(|s|s.parse::<f64>().ok()).ok_or(())?;if length<=start as f64/1000.0{return Err(());}
    }
    let mut decoder=Command::new("ffmpeg");decoder.args(["-nostdin","-v","error","-xerror"]);
    if start>0{decoder.args(["-ss",&(start as f64/1000.0).to_string()]);}
    decoder.args(["-protocol_whitelist","file,pipe","-i",path,"-map","0:a:0"]);
    if duration>0{decoder.args(["-t",&(duration as f64/1000.0).to_string()]);}
    if fade>0{decoder.args(["-af",&format!("asetnsamples=n=128:p=0,volume='min(1,(t+{})/{})':eval=frame",elapsed as f64/1000.0,fade as f64/1000.0)]);}
    decoder.args(["-f","s16le","-ac","2","-ar","48000","pipe:1"]).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());protect(&mut decoder);
    let mut decoder=decoder.spawn().map_err(|_|())?;
    let mut player=Command::new("pw-play");player.args(["--raw","--rate=48000","--channels=2","--format=s16",&format!("--volume={}",volume as f64/100.0),"-"]).stdin(Stdio::from(decoder.stdout.take().ok_or(())?)).stdout(Stdio::null()).stderr(Stdio::null());protect(&mut player);
    let mut player=match player.spawn(){Ok(v)=>v,Err(_)=>{stop(&mut decoder);return Err(());}};
    let outcome=loop{if STOP.load(Ordering::Relaxed){break Err(());}match (player.try_wait(),decoder.try_wait()){(Ok(Some(p)),Ok(Some(d)))=>break if p.success()&&d.success(){Ok(())}else{Err(())},(Err(_),_)|(_,Err(_))=>break Err(()),_=>std::thread::sleep(Duration::from_millis(10))}};
    stop(&mut player);stop(&mut decoder);outcome
}
fn main(){unsafe{libc::signal(libc::SIGTERM,signal as *const () as libc::sighandler_t);libc::signal(libc::SIGHUP,signal as *const () as libc::sighandler_t);libc::signal(libc::SIGINT,signal as *const () as libc::sighandler_t);}let args:Vec<_>=std::env::args().skip(1).collect();if args.len()!=2{std::process::exit(2);}let settings=serde_json::from_str::<Value>(&args[1]).unwrap_or(Value::Bool(false));if run(&args[0],&settings).is_err(){std::process::exit(1);}}
