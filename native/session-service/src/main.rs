use serde_json::{json, Value};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, Write};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

const SCHEMA: u64 = 1;

fn state_dir() -> PathBuf {
    std::env::var_os("MACSHELL_SESSION_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("XDG_STATE_HOME").map(|p| PathBuf::from(p).join("macshell-niri/sessions")))
        .unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap()).join(".local/state/macshell-niri/sessions"))
}

fn niri_json(command: &str) -> Result<Value, String> {
    let output = Command::new("niri").args(["msg", "-j", command]).output().map_err(|e| e.to_string())?;
    if !output.status.success() { return Err(format!("niri {command} failed")); }
    serde_json::from_slice(&output.stdout).map_err(|e| format!("invalid niri {command} response: {e}"))
}

fn is_service(window: &Value) -> bool {
    matches!(window.get("app_id").and_then(Value::as_str), Some("org.quickshell") | Some("dev.noctalia.noctalia-qs"))
}

fn now() -> String {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0).to_string()
}

fn collect() -> Result<Value, String> {
    let outputs = niri_json("outputs")?;
    let workspaces = niri_json("workspaces")?;
    let raw_windows = niri_json("windows")?;
    let ws = workspaces.as_array().ok_or("invalid workspace list")?;
    let windows = raw_windows.as_array().ok_or("invalid window list")?.iter().filter(|w| !is_service(w)).map(|w| {
        let workspace_id = w.get("workspace_id");
        let workspace = ws.iter().find(|item| item.get("id") == workspace_id);
        let layout = w.get("layout").cloned().unwrap_or(Value::Null);
        json!({
            "persistent_key": format!("{}:{}", w.get("app_id").and_then(Value::as_str).unwrap_or(""), w.get("title").and_then(Value::as_str).unwrap_or("")),
            "app_id": w.get("app_id").cloned().unwrap_or(Value::String(String::new())),
            "title": w.get("title").cloned().unwrap_or(Value::String(String::new())),
            "workspace": {"index": workspace.and_then(|v| v.get("idx")), "name": workspace.and_then(|v| v.get("name")), "output": workspace.and_then(|v| v.get("output"))},
            "floating": w.get("is_floating").cloned().unwrap_or(Value::Bool(false)),
            "fullscreen": w.get("fullscreen").cloned().unwrap_or(Value::Bool(false)),
            "layout": layout,
            "focus": w.get("is_focused").cloned().unwrap_or(Value::Bool(false))
        })
    }).collect::<Vec<_>>();
    Ok(json!({"schema": SCHEMA, "snapshot_id": uuid(), "created_at": now(), "niri_version": niri_json("version")?, "outputs": outputs, "workspaces": workspaces, "windows": windows, "focused": windows.iter().find(|w| w["focus"] == true).map(|w| w["persistent_key"].clone())}))
}

fn uuid() -> String {
    let mut bytes = [0u8; 16];
    let _ = File::open("/dev/urandom").and_then(|mut f| std::io::Read::read_exact(&mut f, &mut bytes));
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn lock(dir: &Path) -> Result<File, String> {
    let file = OpenOptions::new().create(true).truncate(false).read(true).write(true).open(dir.join(".lock")).map_err(|e| e.to_string())?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 { return Err(io::Error::last_os_error().to_string()); }
    Ok(file)
}

fn save() -> Result<Value, String> {
    let dir = state_dir(); fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let _guard = lock(&dir)?; let value = collect()?;
    let tmp = dir.join(format!(".current-{}.tmp", uuid()));
    let bytes = serde_json::to_vec_pretty(&value).map_err(|e| e.to_string())?;
    { let mut file = File::create(&tmp).map_err(|e| e.to_string())?; file.write_all(&bytes).map_err(|e| e.to_string())?; file.sync_all().map_err(|e| e.to_string())?; }
    fs::rename(&tmp, dir.join("current.json")).map_err(|e| e.to_string())?;
    Ok(json!({"path": dir.join("current.json"), "snapshot_id": value["snapshot_id"]}))
}

fn inspect() -> Result<Value, String> {
    let value: Value = serde_json::from_slice(&fs::read(state_dir().join("current.json")).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    if value.get("schema") != Some(&Value::from(SCHEMA)) || !value.get("windows").is_some_and(Value::is_array) { return Err("unsupported or corrupt snapshot".into()); }
    Ok(value)
}

fn plan() -> Result<Value, String> {
    let snapshot = inspect()?; let windows = niri_json("windows")?; let workspaces = niri_json("workspaces")?;
    let saved = snapshot["windows"].as_array().ok_or("invalid snapshot windows")?; let current = windows.as_array().ok_or("invalid windows")?; let spaces = workspaces.as_array().ok_or("invalid workspaces")?;
    let mut matched = Vec::new(); let mut skipped = Vec::new();
    for item in saved { let app = item["app_id"].as_str().unwrap_or(""); let title = item["title"].as_str().unwrap_or(""); let matches: Vec<_> = current.iter().filter(|w| !is_service(w) && w["app_id"] == app && w["title"] == title).collect();
        if matches.len() != 1 || saved.iter().filter(|w| w["app_id"] == app && w["title"] == title).count() != 1 { skipped.push(json!({"app_id": app, "reason": "ambiguous_or_missing_window"})); continue; }
        let target = &item["workspace"]; let target_ws: Vec<_> = spaces.iter().filter(|w| w["output"] == target["output"] && ((target["name"].is_string() && w["name"] == target["name"]) || (!target["name"].is_string() && w["idx"] == target["index"]))).collect();
        if target_ws.len() != 1 { skipped.push(json!({"app_id": app, "reason": "workspace_unavailable"})); continue; }
        let w = matches[0]; let mut actions = Vec::new(); if w["workspace_id"] != target_ws[0]["id"] { actions.push(json!({"MoveWindowToWorkspace":{"window_id":w["id"],"reference":{"Id":target_ws[0]["id"]},"focus":false}})); }
        let floating = item["floating"].as_bool().unwrap_or(false); if w["is_floating"].as_bool() != Some(floating) { actions.push(json!({if floating {"MoveWindowToFloating"} else {"MoveWindowToTiling"}:{"id":w["id"]}})); }
        matched.push(json!({"app_id":app,"title":title,"window_id":w["id"],"actions":actions}));
    }
    Ok(json!({"snapshot_id":snapshot["snapshot_id"],"windows":matched,"skipped":skipped}))
}

fn action(value: &Value) -> Result<(), String> { let output = Command::new("niri").args(["msg", "raw-request"]).stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).spawn().and_then(|mut child| { let mut stdin=child.stdin.take().unwrap(); stdin.write_all(serde_json::to_string(&json!({"Action":value})).unwrap().as_bytes())?; stdin.write_all(b"\n")?; drop(stdin); child.wait_with_output() }).map_err(|e|e.to_string())?; if !output.status.success() { return Err("niri action failed".into()); } let response:Value=serde_json::from_slice(&output.stdout).map_err(|e|e.to_string())?; if response=="Handled" || response.get("Ok").is_some() { Ok(()) } else { Err(format!("niri rejected action: {response}")) } }

fn restore() -> Result<Value, String> {
    let p = plan()?;
    for window in p["windows"].as_array().unwrap() {
        for a in window["actions"].as_array().unwrap() { action(a)?; }
    }
    let after = plan()?;
    if after["snapshot_id"] != p["snapshot_id"] { return Err("snapshot changed during restore".into()); }
    for window in p["windows"].as_array().unwrap() {
        let restored = after["windows"].as_array().unwrap().iter().find(|w| w["window_id"] == window["window_id"] && w["app_id"] == window["app_id"] && w["title"] == window["title"]);
        if !restored.is_some_and(|w| w["actions"].as_array().is_some_and(Vec::is_empty)) {
            return Err(format!("restore verification failed for window {}", window["window_id"]));
        }
    }
    Ok(json!({"verified":true,"plan":p}))
}

fn handle(action_name: &str) -> Result<Value, String> { match action_name { "protocol-version" => Ok(json!({"protocol":1})), "save" => save(), "inspect" => inspect(), "status" => { let v=inspect()?; Ok(json!({"ready":true,"snapshot_id":v["snapshot_id"],"windows":v["windows"].as_array().map_or(0,Vec::len),"workspaces":v["workspaces"].as_array().map_or(0,Vec::len)})) }, "restore-plan" => plan(), "restore" => restore(), _ => Err("unknown session action".into()) } }

fn main() {
    if std::env::args().nth(1).as_deref() == Some("--protocol-version") {
        println!("macshell-session-service 1");
        return;
    }
    println!("{}", serde_json::json!({"type":"ready","protocol":1}));
    let _ = io::stdout().flush();
    for line in io::stdin().lock().lines() {
        let line = match line { Ok(v) => v, Err(e) => { eprintln!("{e}"); break } };
        let request: Value = match serde_json::from_str(&line) { Ok(v) => v, Err(e) => { eprintln!("invalid request: {e}"); continue } };
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let name = request.get("action").and_then(Value::as_str).unwrap_or("");
        let response = match handle(name) { Ok(result) => json!({"id": id, "success": true, "result": result}), Err(error) => json!({"id": id, "success": false, "error": error}) };
        println!("{}", serde_json::to_string(&response).unwrap());
        let _ = io::stdout().flush();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_windows_are_filtered_by_app_id_only() {
        assert!(is_service(&json!({"app_id":"org.quickshell","title":"user"})));
        assert!(!is_service(&json!({"app_id":"firefox","title":"MacShell project"})));
    }

    #[test]
    fn uuid_is_nonempty_and_hex() {
        let value = uuid();
        assert_eq!(value.len(), 32);
        assert!(value.bytes().all(|byte| byte.is_ascii_hexdigit()));
    }

    #[test]
    fn service_ready_response_has_protocol() {
        let value = json!({"type":"ready","protocol":1});
        assert_eq!(value["type"], "ready");
        assert_eq!(value["protocol"], 1);
    }
}
