use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::cell::RefCell;

const LIMIT: usize = 1024 * 1024;
type Result<T> = std::result::Result<T, String>;

pub struct ClockStore { path: PathBuf, _lock: File, initial: RefCell<Option<Value>> }

fn digest(bytes: &[u8]) -> String { format!("{:x}", Sha256::digest(bytes)) }
fn unique() -> Result<String> {
    let mut bytes=[0u8;16];File::open("/dev/urandom").and_then(|mut f|f.read_exact(&mut bytes)).map_err(|e|e.to_string())?;
    Ok(bytes.iter().map(|b|format!("{b:02x}")).collect())
}
fn atomic_write(path:&Path,data:&[u8])->Result<()> {
    let parent=path.parent().unwrap_or(Path::new("."));
    let stage=parent.join(format!(".{}-{}",path.file_name().unwrap_or_default().to_string_lossy(),unique()?));
    let result=(|| {
        let mut file=OpenOptions::new().write(true).create_new(true).mode(0o600).open(&stage).map_err(|e|e.to_string())?;
        file.write_all(data).and_then(|_|file.sync_all()).map_err(|e|e.to_string())?;
        fs::rename(&stage,path).map_err(|e|e.to_string())?;
        File::open(parent).and_then(|f|f.sync_all()).map_err(|e|e.to_string())
    })();
    if result.is_err(){let _=fs::remove_file(stage);}result
}
impl ClockStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path=path.as_ref().to_path_buf();let parent=path.parent().filter(|v|!v.as_os_str().is_empty()).unwrap_or(Path::new("."));
        fs::create_dir_all(parent).map_err(|e|e.to_string())?;
        let lock=OpenOptions::new().create(true).truncate(false).append(true).read(true).open(parent.join("clock.lock")).map_err(|e|e.to_string())?;
        if unsafe{libc::flock(lock.as_raw_fd(),libc::LOCK_EX|libc::LOCK_NB)}!=0 {let e=std::io::Error::last_os_error();return Err(if e.kind()==std::io::ErrorKind::WouldBlock {"Another Clock service owns the store".into()} else {e.to_string()});}
        Ok(Self{path,_lock:lock,initial:RefCell::new(None)})
    }
    pub fn set_initial(&self, document:Value) { *self.initial.borrow_mut()=Some(document); }
    pub fn read(&self)->Result<(Value,String)> {
        let file=match File::open(&self.path){Ok(f)=>f,Err(e) if e.kind()==std::io::ErrorKind::NotFound=>return Ok((self.initial.borrow().clone().unwrap_or(json!({})),"missing".into())),Err(_)=>return Err("Cannot read Clock data".into())};
        let mut raw=Vec::new();file.take((LIMIT+1) as u64).read_to_end(&mut raw).map_err(|_|"Cannot read Clock data")?;
        if raw.len()>LIMIT{return Err("Clock data exceeds the size limit".into());}
        let doc:Value=serde_json::from_slice(&raw).map_err(|_|"Invalid or unsupported Clock data")?;
        let object=doc.as_object().ok_or("Invalid or unsupported Clock data")?;
        let version=match object.get("version"){None=>0,Some(v)=>v.as_i64().ok_or("Invalid or unsupported Clock data")?};
        if version!=0 && version!=2{return Err("Invalid or unsupported Clock data".into());}
        if version==2 && (doc["revision"].as_u64().is_none() || !doc["timing"].is_object() || doc["timing"]["version"].as_i64()!=Some(1)){return Err("Invalid or unsupported Clock data".into());}
        Ok((doc,digest(&raw)))
    }
    pub fn commit(&self,patch:&Value,expected_token:&str,expected_revision:u64)->Result<(Value,String)> {
        let patch=patch.as_object().filter(|v|!v.contains_key("version") && !v.contains_key("revision")).ok_or("Invalid Clock update")?;
        let (mut doc,token)=self.read()?;
        let version=doc.get("version").and_then(Value::as_i64).unwrap_or(0);
        let revision=if version==2{doc["revision"].as_u64().unwrap()}else{0};
        if token!=expected_token || expected_revision!=revision{return Err("Clock data changed".into());}
        let next=revision.checked_add(1).ok_or("Invalid Clock update")?;
        for (key,value) in patch {doc[key]=value.clone();}
        doc["version"]=json!(2);doc["revision"]=json!(next);
        if !doc["timing"].is_object() || doc["timing"]["version"].as_i64()!=Some(1){return Err("Missing or unsupported timing data".into());}
        let mut data=serde_json::to_vec_pretty(&doc).map_err(|_|"Invalid Clock update")?;data.push(b'\n');
        if data.len()>LIMIT{return Err("Clock data exceeds the size limit".into());}
        if token!="missing" && version==0 {
            let raw=fs::read(&self.path).map_err(|e|e.to_string())?;
            if digest(&raw)!=token{return Err("Clock data changed during migration".into());}
            let backup=self.path.with_file_name(format!("clock.before-v2-{}.json",unique()?));atomic_write(&backup,&raw)?;
        }
        atomic_write(&self.path,&data)?;self.initial.borrow_mut().take();self.read()
    }
}
