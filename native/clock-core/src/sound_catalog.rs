use serde_json::{json,Value};
use std::collections::HashSet;
use std::fs;
use std::io::Read;
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt,OpenOptionsExt};
use std::path::{Path,PathBuf};

type Result<T> = std::result::Result<T,String>;
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absent_packaged_collection_is_empty() {
        let path=std::env::temp_dir().join(format!("macshell-absent-sound-catalog-{}",std::process::id()));
        assert!(!path.exists());
        assert!(packaged(&path,true).unwrap().is_empty());
        assert!(packaged(&path,false).is_err());
    }
}
const LIMIT:u64=1024*1024;
fn read(path:&Path,error:&str)->Result<Value>{let mut data=Vec::new();fs::File::open(path).and_then(|f|f.take(LIMIT+1).read_to_end(&mut data)).map_err(|_|error.to_string())?;if data.len() as u64>LIMIT{return Err(error.into());}serde_json::from_slice(&data).map_err(|_|error.into())}
fn user_id(s:&str)->bool{s.strip_prefix("user-").is_some_and(|s|s.len()==64&&s.bytes().all(|b|b.is_ascii_digit()||(b'a'..=b'f').contains(&b)))}
fn packaged(path:&Path,apple:bool)->Result<Vec<Value>> {
    if apple && !path.exists(){return Ok(Vec::new());}
    let error=if apple{"Invalid Apple sound catalog"}else{"Invalid built-in sound catalog"};let doc=read(&path.join("catalog.json"),error)?;
    if doc["version"].as_u64()!=Some(1){return Err(error.into());}let mut seen=HashSet::new();let mut result=Vec::new();
    for v in doc["sounds"].as_array().ok_or(error)? {
        let id=v["id"].as_str().ok_or(error)?;let file=v["file"].as_str().ok_or(error)?;
        let name=v["name"].as_str().filter(|s|!s.is_empty()).ok_or(error)?;let _=name;
        let duration=v["durationMs"].as_u64().filter(|v|*v>0).ok_or(error)?;
        let valid=if apple{user_id(id)&&v["category"]=="apple"&&duration<=600000&&file.ends_with(".m4a")&&file.bytes().all(|b|b.is_ascii_alphanumeric()||b" ._-".contains(&b))}else{
            let part=id.strip_prefix("builtin-");let category=v["category"].as_str().unwrap_or("");
            part.is_some_and(|p|{let Some((kind,num))=p.rsplit_once('-')else{return false};!kind.is_empty()&&kind.bytes().all(|b|b.is_ascii_lowercase())&&num.len()==2&&num.bytes().all(|b|b.is_ascii_digit())&&file==format!("{p}.wav")})&&["chime","melody","gentle","urgent"].contains(&category)
        };
        if !valid||!seen.insert(id.to_owned())||!path.join(file).is_file(){return Err(error.into());}result.push(v.clone());
    }Ok(result)
}
fn imported(path:&Path)->Result<Value>{
    let error="Invalid imported sound";let doc=read(&path.join("metadata.json"),error)?;let id=path.file_name().and_then(|s|s.to_str()).ok_or(error)?;
    let file=doc["file"].as_str().ok_or(error)?;
    if doc["version"].as_u64()!=Some(1)||doc["id"]!=id||!doc["name"].as_str().is_some_and(|s|!s.is_empty())||!doc["durationMs"].as_u64().is_some_and(|v|(1..=600000).contains(&v))||!["audio.wav","audio.flac","audio.mp3","audio.ogg","audio.m4a","audio.aac"].contains(&file)||!path.join(file).is_file(){return Err(error.into());}Ok(doc)
}
pub struct SoundCatalog{pub library:PathBuf,pub sounds:PathBuf}
impl SoundCatalog {
    fn lock(&self)->Result<fs::File>{
        fs::DirBuilder::new().recursive(true).mode(0o700).create(&self.library).map_err(|e|e.to_string())?;
        let file=fs::OpenOptions::new().create(true).append(true).read(true).open(self.library.join(".lock")).map_err(|e|e.to_string())?;
        if unsafe{libc::flock(file.as_raw_fd(),libc::LOCK_EX)}!=0{return Err(std::io::Error::last_os_error().to_string());}Ok(file)
    }
    fn write(&self,path:&Path,value:&Value)->Result<()> {
        let parent=path.parent().ok_or("Invalid sound path")?;let mut bytes=[0u8;16];fs::File::open("/dev/urandom").and_then(|mut f|f.read_exact(&mut bytes)).map_err(|e|e.to_string())?;
        let suffix:String=bytes.iter().map(|b|format!("{b:02x}")).collect();let stage=parent.join(format!(".{}-{suffix}",path.file_name().unwrap_or_default().to_string_lossy()));
        let result=(||{let mut file=fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&stage).map_err(|e|e.to_string())?;let mut data=serde_json::to_vec(value).map_err(|e|e.to_string())?;data.push(b'\n');file.write_all(&data).and_then(|_|file.sync_all()).map_err(|e|e.to_string())?;fs::rename(&stage,path).map_err(|e|e.to_string())?;fs::File::open(parent).and_then(|f|f.sync_all()).map_err(|e|e.to_string())})();
        if result.is_err(){let _=fs::remove_file(stage);}result
    }
    fn favorites(&self)->Result<Value>{
        let path=self.library.join("favorites.json");if !path.exists(){return Ok(json!({"version":1,"favorites":[]}));}
        let doc=read(&path,"Invalid sound favorites")?;let mut seen=HashSet::new();
        if doc["version"].as_u64()!=Some(1)||!doc["favorites"].as_array().is_some_and(|values|values.iter().all(|v|v.as_str().is_some_and(|s|s!=""&&s!="silence"&&crate::snooze::sound_id(v)&&seen.insert(s.to_owned()))))||doc.get("showBuiltins").is_some_and(|v|!v.is_boolean()){return Err("Invalid sound favorites".into());}Ok(doc)
    }
    fn imports(&self)->Result<Vec<Value>> {
        if !self.library.exists(){return Ok(Vec::new());}let mut paths=fs::read_dir(&self.library).map_err(|_|"Invalid imported sound")?.collect::<std::result::Result<Vec<_>,_>>().map_err(|_|"Invalid imported sound")?;paths.sort_by_key(|v|v.file_name());
        let mut result=Vec::new();for path in paths{if path.path().is_dir()&&path.file_name().to_string_lossy().starts_with("user-"){result.push(imported(&path.path())?);}}Ok(result)
    }
    pub fn state(&self)->Result<Value>{
        let favorites=self.favorites()?;let show=favorites["showBuiltins"].as_bool().unwrap_or(false);let imports=self.imports()?;let apple=packaged(&self.sounds.join("apple"),true)?;
        let imported_ids:HashSet<String>=imports.iter().filter_map(|v|v["id"].as_str().map(str::to_owned)).collect();let apple_ids:HashSet<String>=apple.iter().filter_map(|v|v["id"].as_str().map(str::to_owned)).collect();
        let mut sounds=Vec::new();for mut sound in apple{if !imported_ids.contains(sound["id"].as_str().unwrap()){sound["imported"]=json!(false);sounds.push(sound);}}
        if show{sounds.extend(packaged(&self.sounds,false)?);}
        for mut sound in imports{sound["imported"]=json!(true);if apple_ids.contains(sound["id"].as_str().unwrap()){sound["category"]=json!("apple");}sounds.push(sound);}
        for sound in &mut sounds{sound["favorite"]=json!(favorites["favorites"].as_array().unwrap().contains(&sound["id"]));}
        Ok(json!({"showBuiltins":show,"sounds":sounds}))
    }
    pub fn resolve(&self,id:&str)->Result<PathBuf>{
        if id.starts_with("builtin-"){for sound in packaged(&self.sounds,false)?{if sound["id"]==id{return Ok(self.sounds.join(sound["file"].as_str().unwrap()));}}}
        else if user_id(id){let dir=self.library.join(id);if dir.exists(){let sound=imported(&dir)?;return Ok(dir.join(sound["file"].as_str().unwrap()));}for sound in packaged(&self.sounds.join("apple"),true)?{if sound["id"]==id{return Ok(self.sounds.join("apple").join(sound["file"].as_str().unwrap()));}}}
        Err("Sound is unavailable".into())
    }
    pub fn set_visible(&self,visible:bool)->Result<()> {
        let _lock=self.lock().map_err(|_|"Cannot save sound visibility")?;let mut document=self.favorites()?;
        if document["showBuiltins"].as_bool().unwrap_or(false)!=visible{document["showBuiltins"]=json!(visible);self.write(&self.library.join("favorites.json"),&document).map_err(|_|"Cannot save sound visibility")?;}Ok(())
    }
    pub fn set_favorite(&self,id:&str,favorite:bool)->Result<()> {
        let _lock=self.lock().map_err(|_|"Cannot save sound favorites")?;self.resolve(id)?;let mut document=self.favorites()?;
        let mut values:Vec<String>=document["favorites"].as_array().unwrap().iter().map(|v|v.as_str().unwrap().to_owned()).collect();
        if values.iter().any(|v|v==id)==favorite{return Ok(());}if favorite{values.push(id.into());}else{values.retain(|v|v!=id);}values.sort();document["favorites"]=json!(values);self.write(&self.library.join("favorites.json"),&document).map_err(|_|"Cannot save sound favorites")?;Ok(())
    }
    pub fn rename_imported(&self,id:&str,name:&str)->Result<()> {
        if !user_id(id){return Err("Only imported sounds can be renamed".into());}
        if name.trim().is_empty()||name.chars().count()>200||name.chars().any(|c|c<' '){return Err("Invalid sound name".into());}
        let _lock=self.lock().map_err(|_|"Cannot rename imported sound")?;let path=self.library.join(id);let mut metadata=imported(&path)?;
        if metadata["name"]!=name.trim(){metadata["name"]=json!(name.trim());self.write(&path.join("metadata.json"),&metadata).map_err(|_|"Cannot rename imported sound")?;}Ok(())
    }
    pub fn delete_imported(&self,id:&str)->Result<bool>{
        if !user_id(id){return Err("Only imported sounds can be deleted".into());}
        let _lock=self.lock().map_err(|_|"Cannot delete imported sound")?;self.resolve(id)?;
        let source=self.library.join(id);let mut bytes=[0u8;16];fs::File::open("/dev/urandom").and_then(|mut f|f.read_exact(&mut bytes)).map_err(|_|"Cannot delete imported sound")?;
        let suffix:String=bytes.iter().map(|b|format!("{b:02x}")).collect();let tombstone=self.library.join(format!(".deleted-{suffix}"));
        fs::rename(&source,&tombstone).map_err(|_|"Cannot delete imported sound")?;
        fs::File::open(&self.library).and_then(|f|f.sync_all()).map_err(|_|"Cannot delete imported sound")?;
        drop(_lock);Ok(fs::remove_dir_all(tombstone).is_ok())
    }
}
