use serde_json::{json,Value};
use std::os::unix::process::CommandExt;
use std::path::{Path,PathBuf};
use std::process::{Child,Command,Stdio};
use std::time::{Duration,Instant};

type Result<T> = std::result::Result<T,String>;
const RING_LIMIT:u64=300000;
const PREVIEW_LIMIT:u64=15000;
const REPEAT_DELAY:u64=250;

#[derive(Clone)]
struct Options {volume:u64,fade:u64,start:u64,duration:u64,repeat:bool,raw:Value}
fn options(value:Option<&Value>)->Result<Options>{
    let empty=json!({});let value=value.filter(|v|!v.is_null()).unwrap_or(&empty);
    let object=value.as_object().ok_or("Invalid sound options")?;let mut raw=value.clone();
    let number=|key:&str,default:u64,max:u64|->Result<u64>{match object.get(key){None=>Ok(default),Some(v)=>v.as_u64().filter(|v|*v<=max).ok_or_else(||format!("Invalid sound {key}"))}};
    let volume=number("volume",90,100)?;let fade=number("fadeMs",0,60000)?;let start=number("startMs",0,600000)?;let duration=number("durationMs",0,600000)?;
    let repeat=match object.get("repeat"){None=>true,Some(v)=>v.as_bool().ok_or("Invalid sound repeat")?};
    raw["volume"]=json!(volume);raw["fadeMs"]=json!(fade);raw["startMs"]=json!(start);raw["durationMs"]=json!(duration);raw["repeat"]=json!(repeat);
    Ok(Options{volume,fade,start,duration,repeat,raw})
}
fn spawn(path:&Path,options:&Options,worker:&Path,elapsed:u64)->Result<(Child,bool)>{
    let advanced=options.fade>0||options.start>0||options.duration>0||path.extension().and_then(|v|v.to_str()).is_none_or(|v|!v.eq_ignore_ascii_case("wav"));
    let mut command=if advanced {let mut settings=options.raw.clone();settings["fadeElapsedMs"]=json!(elapsed);let mut c=Command::new(worker);c.arg(path).arg(settings.to_string());c}else{let mut c=Command::new("pw-play");c.arg(format!("--volume={}",options.volume as f64/100.0)).arg(path);c};
    command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    unsafe{command.pre_exec(||{if libc::prctl(libc::PR_SET_PDEATHSIG,libc::SIGTERM)!=0{return Err(std::io::Error::last_os_error());}if libc::getppid()==1{return Err(std::io::Error::other("parent exited"));}Ok(())});}
    Ok((command.spawn().map_err(|e|e.to_string())?,advanced))
}
fn stop_child(child:&mut Option<Child>){if let Some(mut child)=child.take(){if child.try_wait().ok().flatten().is_none(){unsafe{libc::kill(child.id() as i32,libc::SIGTERM)};let deadline=Instant::now()+Duration::from_secs(1);while Instant::now()<deadline{if child.try_wait().ok().flatten().is_some(){return;}std::thread::sleep(Duration::from_millis(10));}let _=child.kill();}let _=child.wait();}}

pub struct ClockAudio {sound_dir:PathBuf,builtin_dir:PathBuf,worker:PathBuf,child:Option<Child>,event_id:Option<String>,kind:String,selected:Option<PathBuf>,options:Options,started:u64,next:u64,stop_at:u64,custom:bool,advanced:bool,pub failed:bool,pub fallback_used:bool,pub finished:bool}
impl ClockAudio {
    pub fn new(sound_dir:PathBuf,builtin_dir:PathBuf,worker:PathBuf)->Self{Self{sound_dir,builtin_dir,worker,child:None,event_id:None,kind:String::new(),selected:None,options:options(None).unwrap(),started:0,next:0,stop_at:0,custom:false,advanced:false,failed:false,fallback_used:false,finished:false}}
    pub fn default_path(&self,kind:&str)->PathBuf{self.sound_dir.join(format!("{kind}.wav"))}
    pub fn stop(&mut self){stop_child(&mut self.child);self.event_id=None;self.kind.clear();self.selected=None;self.failed=false;self.fallback_used=false;self.finished=false;}
    pub fn start(&mut self,event:&Value,boot:u64,path:Option<&Path>)->Result<()>{
        self.stop();let kind=event["kind"].as_str().filter(|v|["timer","alarm"].contains(v)).ok_or("Invalid sound event")?;
        let id=event["eventId"].as_str().filter(|v|!v.is_empty()).ok_or("Invalid sound event")?;
        self.options=options(event.get("soundOptions"))?;self.event_id=Some(id.into());self.kind=kind.into();self.selected=path.map(Path::to_path_buf);self.started=boot;self.stop_at=boot.saturating_add(RING_LIMIT);self.next=boot;self.tick(Some(event),boot);Ok(())
    }
    pub fn tick(&mut self,event:Option<&Value>,boot:u64){
        let Some(id)=self.event_id.as_deref() else{return};
        if event.is_none_or(|v|v["eventId"]!=id)||boot>=self.stop_at{self.stop();return;}
        if let Some(child)=self.child.as_mut(){match child.try_wait(){Ok(None)=>return,Err(_)=>{stop_child(&mut self.child);self.failed=true;return;},Ok(Some(status))=>{self.child=None;if !status.success(){if (self.custom||self.advanced)&&!self.fallback_used{self.fallback_used=true;self.next=boot;}else{self.failed=true;return;}}else if !self.options.repeat{self.finished=true;return;}else{self.next=boot.saturating_add(REPEAT_DELAY);}}}}
        if self.failed||self.finished||boot<self.next{return;}
        let filename=format!("{}.wav",self.kind);let initial=self.selected.clone().unwrap_or_else(||self.sound_dir.join(&filename));
        self.custom=initial.is_file()&&!self.fallback_used;let path=if self.custom{initial}else{self.builtin_dir.join(filename)};
        if !path.is_file(){self.failed=true;return;}
        let mut settings=self.options.clone();if self.fallback_used||(self.selected.is_some()&&!self.custom){settings.start=0;settings.duration=0;settings.fade=0;settings.raw["startMs"]=json!(0);settings.raw["durationMs"]=json!(0);settings.raw["fadeMs"]=json!(0);}
        match spawn(&path,&settings,&self.worker,boot.saturating_sub(self.started)){Ok((child,advanced))=>{self.child=Some(child);self.advanced=advanced;},Err(_)=>{
            let advanced=settings.fade>0||settings.start>0||settings.duration>0||path.extension().and_then(|v|v.to_str()).is_none_or(|v|!v.eq_ignore_ascii_case("wav"));
            if (self.custom||advanced)&&!self.fallback_used{self.fallback_used=true;self.next=boot;self.tick(event,boot);}else{self.failed=true;}
        }}
    }
    pub fn child_id(&self)->Option<u32>{self.child.as_ref().map(Child::id)}
    pub fn timeout_ms(&self,boot:u64)->Option<u64>{if self.event_id.is_none()||self.failed||self.finished{None}else if self.child.is_some(){Some(250.min(self.stop_at.saturating_sub(boot)))}else{Some(self.next.saturating_sub(boot).min(self.stop_at.saturating_sub(boot)))}}
}
impl Drop for ClockAudio{fn drop(&mut self){self.stop();}}

pub struct ClockPreview {worker:PathBuf,child:Option<Child>,pub sound_id:Option<String>,stop_at:u64}
impl ClockPreview {
    pub fn new(worker:PathBuf)->Self{Self{worker,child:None,sound_id:None,stop_at:0}}
    pub fn stop(&mut self){stop_child(&mut self.child);self.sound_id=None;}
    pub fn start(&mut self,id:&str,path:&Path,boot:u64,settings:Option<&Value>)->Result<()>{self.stop();if !path.is_file(){return Err("Sound is unavailable".into());}let options=options(settings)?;let(child,_)=spawn(path,&options,&self.worker,0)?;self.child=Some(child);self.sound_id=Some(id.into());self.stop_at=boot.saturating_add(PREVIEW_LIMIT);Ok(())}
    pub fn tick(&mut self,boot:u64)->bool{let Some(child)=self.child.as_mut() else{return false};let outcome=child.try_wait();let failed=matches!(&outcome,Ok(Some(s)) if !s.success())||outcome.is_err();if !matches!(outcome,Ok(None))||boot>=self.stop_at{self.stop();}failed}
    pub fn child_id(&self)->Option<u32>{self.child.as_ref().map(Child::id)}
}
impl Drop for ClockPreview{fn drop(&mut self){self.stop();}}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_default_sound_reports_failure_without_starting_a_player() {
        let root = std::env::temp_dir().join(format!("macshell-no-sounds-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let mut audio = ClockAudio::new(root.join("user"), root.join("builtin"), root.join("worker"));
        let event = json!({"kind":"timer","eventId":"test"});
        audio.start(&event, 1, None).unwrap();
        assert!(audio.failed);
        assert!(audio.child_id().is_none());
        let mut preview = ClockPreview::new(root.join("worker"));
        assert!(preview.start("default", &root.join("timer.wav"), 1, None).is_err());
        assert!(preview.child_id().is_none());
    }
}
