//! Bounded read-only probes for the experimental recorder.
use macshell_recording_core::owned::OwnedChild;
use serde_json::{json, Value};
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

pub fn program(name: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .map(|p| p.join(name))
            .find(|p| {
                std::fs::metadata(p)
                    .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
            })
    })
}

pub fn json_command(name: &str, args: &[&str], timeout: Duration) -> Result<Value, &'static str> {
    let mut command = Command::new(name);
    command
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut child = OwnedChild::spawn(&mut command).map_err(|_| "Audio service is unavailable.")?;
    let stdout = child
        .child_mut()
        .stdout
        .take()
        .ok_or("Audio service is unavailable.")?;
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let mut data = Vec::new();
        let result = stdout.take(16_777_217).read_to_end(&mut data);
        let _ = tx.send((result, data));
    });
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => {
                let (read, data) = rx
                    .recv_timeout(Duration::from_secs(1))
                    .map_err(|_| "Audio service is unavailable.")?;
                if read.is_err() || data.len() > 16_777_216 {
                    return Err("Invalid audio service response.");
                }
                return serde_json::from_slice(&data)
                    .map_err(|_| "Invalid audio service response.");
            }
            Ok(Some(_)) | Err(_) => return Err("Audio service is unavailable."),
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(20)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("Audio service timed out.");
            }
        }
    }
}
pub fn graph() -> Result<Value, &'static str> {
    json_command("pw-dump", &[], Duration::from_secs(3))
}

pub fn choices(objects: &Value) -> Result<Value, &'static str> {
    let values = objects
        .as_array()
        .ok_or("Invalid audio service response.")?;
    let mut microphones = Vec::new();
    let mut sinks = Vec::new();
    for object in values {
        let props = &object["info"]["props"];
        let Some(name) = props["node.name"]
            .as_str()
            .filter(|n| !n.is_empty() && !n.starts_with("macshell_record_"))
        else {
            continue;
        };
        let label = props["node.description"].as_str().unwrap_or(name);
        let Some(id) = object["id"].as_u64() else {
            return Err("Invalid audio service response.");
        };
        let row = json!({"name": name, "label":label, "id":id});
        match props["media.class"].as_str() {
            Some("Audio/Source") => microphones.push(row),
            Some("Audio/Sink") => sinks.push(row),
            _ => (),
        }
    }
    for values in [&mut microphones, &mut sinks] {
        values.sort_by_key(|v| {
            (
                v["label"].as_str().unwrap_or("").to_lowercase(),
                v["name"].as_str().unwrap_or("").to_owned(),
            )
        });
    }
    Ok(json!({"microphones": microphones, "sinks": sinks}))
}

pub fn backend() -> Result<&'static str, &'static str> {
    let path = program("wf-recorder").ok_or("Cannot identify the recorder audio backend.")?;
    let file =
        std::fs::File::open(path).map_err(|_| "Cannot identify the recorder audio backend.")?;
    let mut data = Vec::new();
    file.take(16 * 1024 * 1024)
        .read_to_end(&mut data)
        .map_err(|_| "Cannot identify the recorder audio backend.")?;
    if !data.starts_with(b"\x7fELF") {
        return Err("Cannot identify the recorder audio backend.");
    }
    if data
        .windows(b"libpipewire-0.3.so".len())
        .any(|v| v == b"libpipewire-0.3.so")
    {
        Ok("pipewire")
    } else if data
        .windows(b"libpulse-simple.so".len())
        .any(|v| v == b"libpulse-simple.so")
    {
        Ok("pulse")
    } else {
        Err("Cannot identify the recorder audio backend.")
    }
}
pub fn pulse_source(target: &str, is_sink: bool) -> Result<String, &'static str> {
    let sources = json_command(
        "pactl",
        &["-f", "json", "list", "sources"],
        Duration::from_secs(3),
    )?;
    let found: Vec<_> = sources
        .as_array()
        .ok_or("Invalid audio service response.")?
        .iter()
        .filter(|source| {
            source["properties"]["node.name"].as_str() == Some(target)
                && source.get("monitor_source").is_some_and(|v| match v {
                    Value::Null => false,
                    Value::Bool(b) => *b,
                    Value::Number(n) => n.as_i64().is_some_and(|i| i != 0),
                    Value::String(s) => !s.is_empty(),
                    _ => true,
                }) == is_sink
        })
        .filter_map(|source| source["name"].as_str())
        .filter(|v| !v.is_empty())
        .collect();
    if found.len() == 1 {
        Ok(found[0].to_owned())
    } else {
        Err("The selected audio device is not uniquely available through pipewire-pulse.")
    }
}
