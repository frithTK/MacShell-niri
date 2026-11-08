use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

fn valid(value: Option<&str>) -> Option<&str> {
    value.filter(|s| !s.is_empty() && !s.contains(['\n', '\r', '\t']) && Path::new(s).is_file())
}

fn json_file(path: &Path, result: &mut BTreeMap<String, String>) {
    let Some(data) = fs::read(path).ok().and_then(|data| serde_json::from_slice::<Value>(&data).ok()) else { return; };
    if let Some(monitors) = data.get("wallpapers").and_then(Value::as_object) {
        for (output, modes) in monitors {
            let image = if let Some(modes) = modes.as_object() { modes.get("dark").and_then(Value::as_str).filter(|s| !s.is_empty()).or_else(|| modes.get("light").and_then(Value::as_str)) } else { modes.as_str() };
            if let Some(image) = valid(image) {
                let key = if output.is_empty() { "wallpaper.default".to_string() } else { format!("wallpaper.monitors.{output}") };
                if !key.contains(['\n', '\r', '\t']) { result.insert(key, image.to_owned()); }
            }
        }
    }
    if let Some(image) = valid(data.get("defaultWallpaper").and_then(Value::as_str)) { result.entry("wallpaper.default".into()).or_insert_with(|| image.into()); }
}

fn toml_file(path: &Path, result: &mut BTreeMap<String, String>) {
    let Some(data) = fs::read_to_string(path).ok().and_then(|v| v.parse::<toml::Value>().ok()) else { return; };
    let Some(wallpaper) = data.get("wallpaper") else { return; };
    for key in ["last", "default"] {
        if let Some(image) = valid(wallpaper.get(key).and_then(|v| v.get("path")).and_then(toml::Value::as_str)) { result.entry(format!("wallpaper.{key}")).or_insert_with(|| image.into()); }
    }
    if let Some(monitors) = wallpaper.get("monitors").and_then(toml::Value::as_table) {
        for (output, value) in monitors {
            if let Some(image) = valid(value.get("path").and_then(toml::Value::as_str)) {
                if !output.contains(['\n', '\r', '\t']) { result.entry(format!("wallpaper.monitors.{output}")).or_insert_with(|| image.into()); }
            }
        }
    }
}

fn query(tool: &str) -> Option<String> {
    // Drain the pipe while the child runs, so a verbose tool cannot block before exit.
    let mut child = Command::new(tool).arg("query").stdout(Stdio::piped()).stderr(Stdio::null()).spawn().ok()?;
    let mut stdout = child.stdout.take()?;
    let reader = std::thread::spawn(move || { use std::io::Read; let mut output = Vec::new(); let _ = stdout.by_ref().take(1024 * 1024).read_to_end(&mut output); output });
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            _ => { let _ = child.kill(); let _ = child.wait(); break; }
        }
    }
    if !reader.is_finished() { return None; }
    String::from_utf8(reader.join().ok()?).ok()
}

fn main() {
    if std::env::args().nth(1).as_deref() == Some("--protocol-version") { println!("macshell-wallpaper-discovery 1"); return; }
    let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
    let config = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".config"));
    let cache = std::env::var_os("MACSHELL_WALLPAPER_CACHE_HOME").or_else(|| std::env::var_os("XDG_CACHE_HOME")).map(PathBuf::from).unwrap_or_else(|| home.join(".cache"));
    let mut result = BTreeMap::new();
    for path in [cache.join("noctalia/wallpapers.json"), config.join("noctalia/wallpapers.json")] { json_file(&path, &mut result); }
    for name in ["settings.toml", "config.toml"] { toml_file(&config.join("noctalia").join(name), &mut result); }
    if result.is_empty() {
        for tool in ["awww", "swww"] {
            if let Some(output) = query(tool) {
                for line in output.lines() {
                    if let Some(image) = valid(line.split_once("image: ").map(|(_, image)| image)) { result.entry("wallpaper.default".into()).or_insert_with(|| image.into()); }
                }
            }
        }
    }
    for (key, image) in result { println!("{key}\t{image}"); }
}
