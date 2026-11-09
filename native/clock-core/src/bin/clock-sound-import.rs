use macshell_clock_core::sound_catalog::SoundCatalog;
use serde_json::{json,Value};
use sha2::{Digest,Sha256};
use std::fs::{self,File,OpenOptions};
use std::io::{Read,Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt,OpenOptionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path,PathBuf};
use std::process::{Command,Stdio};
use std::sync::atomic::{AtomicBool,Ordering};
use std::time::{Duration,Instant};

static STOP:AtomicBool=AtomicBool::new(false);
extern "C" fn signal(_:libc::c_int){STOP.store(true,Ordering::Relaxed);}
type Result<T> = std::result::Result<T,String>;
struct Stage(PathBuf);
impl Drop for Stage{fn drop(&mut self){let _=fs::remove_dir_all(&self.0);}}
fn unique()->Result<String>{let mut b=[0u8;16];File::open("/dev/urandom").and_then(|mut f|f.read_exact(&mut b)).map_err(|_|"Cannot import audio file")?;Ok(b.iter().map(|v|format!("{v:02x}")).collect())}
fn child(command:&mut Command,timeout:u64)->Result<Vec<u8>>{
    command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());unsafe{command.pre_exec(||{if libc::prctl(libc::PR_SET_PDEATHSIG,libc::SIGTERM)!=0{return Err(std::io::Error::last_os_error());}if libc::getppid()==1{return Err(std::io::Error::other("parent exited"));}Ok(())});}
    let mut child=command.spawn().map_err(|_|"Audio cannot be decoded")?;let mut pipe=child.stdout.take().unwrap();
    let reader=std::thread::spawn(move||{let mut data=Vec::new();let _=pipe.by_ref().take(1024*1024+1).read_to_end(&mut data);data});
    let deadline=Instant::now()+Duration::from_secs(timeout);
    let status=loop{match child.try_wait(){Ok(Some(s))=>break Some(s),Ok(None) if !STOP.load(Ordering::Relaxed)&&Instant::now()<deadline=>std::thread::sleep(Duration::from_millis(10)),_=>{let _=child.kill();let _=child.wait();break None;}}};
    if !reader.is_finished(){return Err("Audio cannot be decoded".into());}let bytes=reader.join().map_err(|_|"Audio cannot be decoded")?;
    if bytes.len()>1024*1024||!status.is_some_and(|s|s.success()){return Err("Audio cannot be decoded".into());}Ok(bytes)
}
fn import(library:&Path,source:&Path)->Result<(Value,bool)>{
    let extension=source.extension().and_then(|s|s.to_str()).unwrap_or("").to_ascii_lowercase();
    let demuxer=match extension.as_str(){"wav"=>"wav","flac"=>"flac","mp3"=>"mp3","ogg"=>"ogg","m4a"=>"mov","aac"=>"aac",_=>return Err("Unsupported audio format".into())};
    let name=source.file_stem().and_then(|v|v.to_str()).filter(|s|!s.trim().is_empty()&&s.chars().count()<=200&&!s.chars().any(|c|c<' ')).ok_or("Invalid sound name")?.trim();
    fs::DirBuilder::new().recursive(true).mode(0o700).create(library).map_err(|_|"Cannot import audio file")?;
    let mut input=OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK|libc::O_CLOEXEC).open(source).map_err(|_|"Cannot import audio file")?;
    let metadata=input.metadata().map_err(|_|"Cannot import audio file")?;if !metadata.is_file()||metadata.len()==0||metadata.len()>50*1024*1024{return Err("Audio file is empty, too large, or not a regular file".into());}
    let stage=Stage(library.join(format!(".import-{}",unique()?)));fs::DirBuilder::new().mode(0o700).create(&stage.0).map_err(|_|"Cannot import audio file")?;
    let filename=format!("audio.{extension}");let target=stage.0.join(&filename);let mut output=OpenOptions::new().write(true).create_new(true).mode(0o600).open(&target).map_err(|_|"Cannot import audio file")?;
    let mut hash=Sha256::new();let mut size=0usize;let mut buffer=[0u8;65536];loop{if STOP.load(Ordering::Relaxed){return Err("Import cancelled".into());}let n=input.read(&mut buffer).map_err(|_|"Cannot import audio file")?;if n==0{break;}size+=n;if size>50*1024*1024{return Err("Audio file is too large".into());}hash.update(&buffer[..n]);output.write_all(&buffer[..n]).map_err(|_|"Cannot import audio file")?;}if size==0{return Err("Audio file is empty".into());}output.sync_all().map_err(|_|"Cannot import audio file")?;drop(output);
    let path=target.to_str().ok_or("Cannot import audio file")?;
    let mut probe=Command::new("ffprobe");probe.args(["-v","error","-protocol_whitelist","file,pipe","-f",demuxer,"-show_entries","format=duration:stream=codec_type","-of","json",path]);let value:Value=serde_json::from_slice(&child(&mut probe,10)?).map_err(|_|"Audio cannot be decoded")?;
    let duration=value["format"]["duration"].as_str().and_then(|v|v.parse::<f64>().ok()).filter(|v|v.is_finite()&&*v>0.0&&*v<=600.0).ok_or("Audio duration is outside the allowed range")?;
    if !value["streams"].as_array().is_some_and(|v|v.iter().any(|s|s["codec_type"]=="audio")){return Err("File does not contain audio".into());}
    let mut decode=Command::new("ffmpeg");decode.args(["-nostdin","-xerror","-v","error","-protocol_whitelist","file,pipe","-f",demuxer,"-i",path,"-map","0:a:0","-f","null","-"]);child(&mut decode,30)?;
    let id=format!("user-{:x}",hash.finalize());let record=json!({"version":1,"id":id,"name":name,"durationMs":(duration*1000.0).round() as u64,"file":filename});
    let mut file=OpenOptions::new().write(true).create_new(true).mode(0o600).open(stage.0.join("metadata.json")).map_err(|_|"Cannot import audio file")?;file.write_all(record.to_string().as_bytes()).and_then(|_|file.write_all(b"\n")).and_then(|_|file.sync_all()).map_err(|_|"Cannot import audio file")?;File::open(&stage.0).and_then(|f|f.sync_all()).map_err(|_|"Cannot import audio file")?;
    let lock=OpenOptions::new().create(true).append(true).read(true).open(library.join(".lock")).map_err(|_|"Cannot import audio file")?;if unsafe{libc::flock(lock.as_raw_fd(),libc::LOCK_EX)}!=0{return Err("Cannot import audio file".into());}
    let dest=library.join(&id);if dest.exists(){let catalog=SoundCatalog{library:library.into(),sounds:PathBuf::new()};let path=catalog.resolve(&id)?;let record:Value=serde_json::from_slice(&fs::read(path.parent().unwrap().join("metadata.json")).map_err(|_|"Invalid imported sound")?).map_err(|_|"Invalid imported sound")?;return Ok((record,false));}
    if STOP.load(Ordering::Relaxed){return Err("Import cancelled".into());}fs::rename(&stage.0,&dest).map_err(|_|"Cannot import audio file")?;File::open(library).and_then(|f|f.sync_all()).map_err(|_|"Cannot import audio file")?;Ok((record,true))
}
fn main(){unsafe{libc::signal(libc::SIGTERM,signal as *const () as libc::sighandler_t);libc::signal(libc::SIGHUP,signal as *const () as libc::sighandler_t);}let args:Vec<_>=std::env::args().skip(1).collect();if args==["--protocol-version"]{println!("macshell-clock-import 1");return;}if args.len()!=3||args[0]!="--library"{std::process::exit(2);}match import(Path::new(&args[1]),Path::new(&args[2])){Ok((sound,created))=>println!("{}",json!({"success":true,"sound":sound,"created":created})),Err(error)=>{println!("{}",json!({"success":false,"error":error}));std::process::exit(1);}}}
