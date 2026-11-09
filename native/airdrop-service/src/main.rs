use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::env;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Sender};
use std::time::{Duration, Instant};

static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn stop_signal(_: libc::c_int) {
    STOP.store(true, Ordering::Relaxed);
}
enum Event {
    Input(Vec<u8>),
    Eof,
    Child(u64, String, Vec<u8>),
    End(u64, String),
}
struct Process {
    child: Child,
    id: u64,
    error: String,
    terminal: bool,
    started: Instant,
    streams: u8,
}

fn text(s: &str, limit: usize) -> String {
    s.chars()
        .filter(|c| *c >= ' ' && *c != '\u{7f}')
        .take(limit)
        .collect()
}
fn executable() -> Option<PathBuf> {
    let home = env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let runtime = env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or(home.join(".local/share"))
        .join("macshell-niri/runtime/bin/owly");
    let check = |p: &Path| {
        fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    };
    if check(&runtime) {
        return Some(runtime);
    }
    env::var_os("PATH").and_then(|paths| {
        env::split_paths(&paths)
            .map(|p| p.join("owly"))
            .find(|p| check(p))
    })
}
fn owned(command: &mut Command) {
    unsafe {
        command.pre_exec(|| {
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGINT) != 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::getppid() == 1 {
                return Err(io::Error::other("parent exited"));
            }
            Ok(())
        });
    }
}
fn stop_child(mut child: Child, seconds: u64) {
    if matches!(child.try_wait(), Ok(None)) {
        unsafe {
            libc::kill(child.id() as i32, libc::SIGINT);
        }
        let end = Instant::now() + Duration::from_secs(seconds);
        while Instant::now() < end {
            if !matches!(child.try_wait(), Ok(None)) {
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let _ = child.kill();
    }
    let _ = child.wait();
}
fn local_files(values: &Value) -> Result<Vec<PathBuf>, String> {
    let items = values
        .as_array()
        .filter(|v| !v.is_empty() && v.len() <= 100)
        .ok_or("Choose between 1 and 100 files.")?;
    let mut out = Vec::new();
    for value in items {
        let s = value
            .as_str()
            .filter(|s| s.chars().count() <= 8192 && !s.contains('\0'))
            .ok_or("Invalid file path.")?;
        let path = if s.starts_with("file:") {
            let url = url::Url::parse(s).map_err(|_| "Choose local files.")?;
            if !matches!(url.host_str(), None | Some("localhost")) {
                return Err("Choose local files.".into());
            }
            url.to_file_path().map_err(|_| "Choose local files.")?
        } else if url::Url::parse(s).is_ok() {
            return Err("Choose local files.".into());
        } else if s == "~" || s.starts_with("~/") {
            PathBuf::from(env::var_os("HOME").unwrap_or_default())
                .join(s.trim_start_matches("~/").trim_start_matches('~'))
        } else {
            PathBuf::from(s)
        };
        let path = fs::canonicalize(path)
            .map_err(|_| "A selected file is unavailable. Choose files again.")?;
        if !path.is_file() || fs::File::open(&path).is_err() {
            return Err("A selected file is unavailable. Choose files again.".into());
        }
        if !out.contains(&path) {
            out.push(path);
        }
    }
    Ok(out)
}
fn uid() -> io::Result<String> {
    let mut bytes = [0u8; 16];
    fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
fn run_probe(program: &Path, args: &[&str], timeout: u64) -> Result<Value, String> {
    let mut command = Command::new(program);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    owned(&mut command);
    let mut child = command.spawn().map_err(|e| e.to_string())?;
    let stdout = child.stdout.take().unwrap();
    let handle = std::thread::spawn(move || {
        let mut data = Vec::new();
        let _ = stdout.take(1048577).read_to_end(&mut data);
        data
    });
    let end = Instant::now() + Duration::from_secs(timeout);
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Ok(None) if Instant::now() < end => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = handle.join();
                return Err("AirDrop backend probe timed out.".into());
            }
        }
    };
    let data = handle.join().unwrap_or_default();
    if data.len() > 1048576 {
        return Err("Invalid AirDrop backend response.".into());
    }
    let result: Value =
        serde_json::from_slice(&data).map_err(|_| "Invalid AirDrop backend response.")?;
    if args.first() == Some(&"macshell") && !status.success() {
        return Err("The installed Owly needs the MacShell machine interface.".into());
    }
    Ok(result)
}
struct Service {
    tx: Sender<Event>,
    generation: Option<Value>,
    last: Option<Value>,
    program: Option<PathBuf>,
    available: bool,
    configured: bool,
    mode: String,
    status: String,
    error: String,
    notice: String,
    interface: String,
    name: String,
    devices: BTreeMap<String, Value>,
    files: Vec<PathBuf>,
    pending: Option<(Value, Instant)>,
    receive_id: Option<Value>,
    transfer: String,
    progress: Value,
    results: Vec<String>,
    receiving: bool,
    scanning: bool,
    blocked: bool,
    deadline: Option<Instant>,
    epoch: String,
    processes: HashMap<String, Process>,
    next_id: u64,
    folder: PathBuf,
}
impl Drop for Service {
    fn drop(&mut self) {
        for kind in ["browse", "send", "receive", "radio"] {
            self.stop_process(kind);
        }
    }
}
impl Service {
    fn new(tx: Sender<Event>) -> Self {
        let home = env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
        let folder = env::var_os("MACSHELL_AIRDROP_DOWNLOADS")
            .map(PathBuf::from)
            .unwrap_or(home.join("Downloads/AirDrop"));
        Self {
            tx,
            generation: None,
            last: None,
            program: None,
            available: false,
            configured: false,
            mode: String::new(),
            status: "off".into(),
            error: String::new(),
            notice: String::new(),
            interface: String::new(),
            name: "MacShell".into(),
            devices: BTreeMap::new(),
            files: Vec::new(),
            pending: None,
            receive_id: None,
            transfer: "idle".into(),
            progress: json!({"sent":0,"total":0}),
            results: vec![],
            receiving: false,
            scanning: false,
            blocked: false,
            deadline: None,
            epoch: String::new(),
            processes: HashMap::new(),
            next_id: 0,
            folder,
        }
    }
    fn emit(&self, mut v: Value) {
        if let Some(g) = &self.generation {
            v["generation"] = g.clone();
        }
        if writeln!(io::stdout().lock(), "{v}").is_err() {
            STOP.store(true, Ordering::Relaxed);
        }
    }
    fn publish(&mut self) {
        let files:Vec<Value>=self.files.iter().map(|p|json!({"name":p.file_name().unwrap_or_default().to_string_lossy(),"size":fs::metadata(p).map(|m|m.len()).unwrap_or(0)})).collect();
        let pending = self.pending.as_ref().map(|p| p.0.clone());
        let state = json!({"type":"state","available":self.available,"configured":self.configured,"mode":self.mode,"canStart":self.configured&&self.mode=="shared","status":self.status,"error":self.error,"notice":self.notice,"devices":self.devices.values().collect::<Vec<_>>(),"files":files,"pending":pending,"transfer":self.transfer,"progress":self.progress,"results":self.results,"receiving":self.receiving,"scanning":self.scanning,"folder":self.folder.to_string_lossy(),"blocked":self.blocked});
        if self.last.as_ref() != Some(&state) {
            self.emit(state.clone());
            self.last = Some(state);
        }
    }
    fn probe(&mut self) {
        if !self.processes.is_empty() {
            return;
        }
        self.program = executable();
        self.available = false;
        self.configured = false;
        self.error.clear();
        self.notice.clear();
        let Some(p) = self.program.as_ref() else {
            self.notice = "Install the MacShell Owly backend to use AirDrop.".into();
            return;
        };
        let result = (|| -> Result<(), String> {
            let caps = run_probe(p, &["macshell", "capabilities"], 5)?;
            if caps["protocol"] != 1 {
                return Err("The installed Owly needs the MacShell machine interface.".into());
            }
            self.available = true;
            let report = run_probe(p, &["doctor", "--json"], 8)?;
            self.mode = report["mode"].as_str().unwrap_or("").into();
            let missing = report["missing"].as_array().cloned().unwrap_or_default();
            self.configured = report["hardware"] == true
                && ["shared", "exclusive", "active-monitor"].contains(&self.mode.as_str())
                && missing.is_empty();
            self.notice = missing
                .iter()
                .take(3)
                .map(|v| {
                    if v["id"] == "backend" {
                        "Complete AirDrop system-service setup, then try again.".into()
                    } else {
                        text(v["say"].as_str().unwrap_or(""), 200)
                    }
                })
                .collect::<Vec<String>>()
                .join(" ");
            if self.configured && self.mode != "shared" {
                self.notice="AirDrop on this adapter disconnects Wi-Fi and interrupts internet calls. MacShell blocks this mode.".into();
            }
            if report["hardware"] != true && self.notice.is_empty() {
                self.notice = "This Wi-Fi adapter is not supported by Owly.".into();
            }
            Ok(())
        })();
        if let Err(e) = result {
            self.notice = text(&e, 200);
        }
    }
    fn spawn(&mut self, kind: &str, args: Vec<String>) -> Result<(), String> {
        if self.processes.contains_key(kind) {
            return Err("Wait for the current AirDrop operation.".into());
        }
        let mut c = Command::new(self.program.as_ref().ok_or("AirDrop backend unavailable")?);
        c.arg("macshell")
            .args(args)
            .env("TOKIO_WORKER_THREADS", "2")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        owned(&mut c);
        let mut child = c.spawn().map_err(|e| e.to_string())?;
        self.next_id += 1;
        let id = self.next_id;
        for (stream, output) in [
            (
                "stdout",
                child
                    .stdout
                    .take()
                    .map(|v| Box::new(v) as Box<dyn Read + Send>),
            ),
            (
                "stderr",
                child
                    .stderr
                    .take()
                    .map(|v| Box::new(v) as Box<dyn Read + Send>),
            ),
        ] {
            if let Some(output) = output {
                let tx = self.tx.clone();
                let stream = stream.to_string();
                std::thread::spawn(move || {
                    let mut reader = BufReader::new(output);
                    loop {
                        let mut bytes = Vec::new();
                        match reader.by_ref().take(1048577).read_until(b'\n', &mut bytes) {
                            Ok(0) | Err(_) => break,
                            Ok(_) => {
                                if tx.send(Event::Child(id, stream.clone(), bytes)).is_err() {
                                    return;
                                }
                            }
                        }
                    }
                    let _ = tx.send(Event::End(id, stream));
                });
            }
        }
        self.processes.insert(
            kind.into(),
            Process {
                child,
                id,
                error: String::new(),
                terminal: false,
                started: Instant::now(),
                streams: 2,
            },
        );
        Ok(())
    }
    fn stop_process(&mut self, kind: &str) {
        if let Some(p) = self.processes.remove(kind) {
            stop_child(p.child, if kind == "radio" { 10 } else { 2 });
        }
    }
    fn stop(&mut self) {
        self.status = "stopping".into();
        self.publish();
        for kind in ["browse", "send", "receive", "radio"] {
            self.stop_process(kind);
        }
        self.status = "off".into();
        self.pending = None;
        self.receive_id = None;
        self.receiving = false;
        self.scanning = false;
        self.deadline = None;
        self.devices.clear();
        if ["waiting", "sending", "receiving"].contains(&self.transfer.as_str()) {
            self.transfer = "cancelled".into();
        }
    }
    fn fail(&mut self, error: &str) {
        self.stop();
        self.status = "error".into();
        self.error = text(error, 200);
    }
    fn common(&self) -> Vec<String> {
        vec![
            "--iface".into(),
            self.interface.clone(),
            "--name".into(),
            self.name.clone(),
        ]
    }
    fn scan(&mut self) -> Result<(), String> {
        if self.status != "ready"
            || self.processes.contains_key("browse")
            || self.processes.contains_key("send")
        {
            return Ok(());
        }
        self.devices.clear();
        self.scanning = true;
        let mut args = vec!["browse".into()];
        args.extend(self.common());
        args.extend(["--seconds".into(), "10".into()]);
        self.spawn("browse", args)
    }
    fn write_receive(&mut self, id: &Value, accept: bool) -> Result<(), String> {
        let child = &mut self
            .processes
            .get_mut("receive")
            .ok_or("AirDrop receiver stopped")?
            .child;
        let stdin = child.stdin.as_mut().ok_or("AirDrop receiver stopped")?;
        writeln!(stdin, "{}", json!({"id":id,"accept":accept}))
            .and_then(|_| stdin.flush())
            .map_err(|e| e.to_string())
    }
    fn event(&mut self, kind: &str, m: Value) -> Result<(), String> {
        let event = m["event"].as_str().unwrap_or("");
        match (kind, event) {
            ("radio", "radio_ready") if self.status == "starting" => {
                let interface = m["interface"]
                    .as_str()
                    .filter(|s| {
                        !s.is_empty()
                            && s.len() <= 15
                            && s.bytes()
                                .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
                    })
                    .ok_or("Invalid AirDrop interface")?;
                self.interface = interface.into();
                self.status = "ready".into();
                fs::create_dir_all(&self.folder).map_err(|e| e.to_string())?;
                let mut args = vec!["receive".into()];
                args.extend(self.common());
                args.push("--dir".into());
                args.push(self.folder.to_string_lossy().into());
                self.spawn("receive", args)?;
                self.scan()?;
            }
            ("radio", "radio_stopped") | ("browse", "scan_done") => {
                if kind == "browse" {
                    self.scanning = false;
                }
                if let Some(p) = self.processes.get_mut(kind) {
                    p.terminal = true;
                }
            }
            ("browse", "device") => {
                let key = m["key"]
                    .as_str()
                    .filter(|s| s.len() <= 150)
                    .ok_or("Invalid AirDrop device")?;
                let Some((address, port)) = key.strip_prefix('[').and_then(|s| s.split_once("]:"))
                else {
                    return Err("Invalid AirDrop device".into());
                };
                if !address.starts_with("fe80:")
                    || !address
                        .bytes()
                        .all(|b| b.is_ascii_hexdigit() || b":%._-".contains(&b))
                    || port.is_empty()
                    || port.len() > 5
                    || !port.bytes().all(|b| b.is_ascii_digit())
                {
                    return Err("Invalid AirDrop device".into());
                }
                let flags = m["flags"]
                    .as_u64()
                    .filter(|v| *v <= u32::MAX as u64)
                    .ok_or("Invalid AirDrop flags")?;
                if self.devices.len() < 100 {
                    let name = text(m["name"].as_str().unwrap_or(""), 200);
                    self.devices.insert(key.into(),json!({"key":key,"name":if name.is_empty(){"Apple device"}else{&name},"flags":flags}));
                }
            }
            ("receive", "receiver_ready") => self.receiving = true,
            ("receive", "request") => {
                let id = m["id"]
                    .as_u64()
                    .filter(|v| *v <= 9007199254740991)
                    .ok_or("Invalid request")?;
                if self.receive_id.is_some() || self.pending.is_some() {
                    self.write_receive(&json!(id), false)?;
                    return Ok(());
                }
                let files = m["files"].as_array().cloned().unwrap_or_default();
                let urls = m["urls"].as_array().cloned().unwrap_or_default();
                if files.len() + urls.len() > 100 {
                    return Err("Too many items".into());
                }
                let pending = json!({"key":format!("{}:{id}",self.epoch),"id":id,"name":text(m["name"].as_str().unwrap_or(""),200),"files":files.iter().map(|v|json!({"name":text(v["name"].as_str().unwrap_or(""),200)})).collect::<Vec<_>>(),"urls":urls.iter().map(|v|text(v.as_str().unwrap_or(""),500)).collect::<Vec<_>>(),"expires":0});
                self.pending = Some((pending, Instant::now() + Duration::from_secs(14)));
            }
            ("receive", "answered" | "withdrawn") => {
                if self.pending.as_ref().is_some_and(|p| p.0["id"] == m["id"]) {
                    if event == "answered" && m["accepted"] == true {
                        self.receive_id = Some(m["id"].clone());
                        self.transfer = "receiving".into();
                    }
                    self.pending = None;
                }
                if self.receive_id.as_ref() == Some(&m["id"])
                    && (event == "withdrawn" || m["accepted"] == false)
                {
                    self.receive_id = None;
                    self.transfer = "cancelled".into();
                }
            }
            ("receive", "received" | "received_urls" | "receive_failed") => {
                if self.receive_id.as_ref() == Some(&m["id"]) {
                    self.receive_id = None;
                }
                if event == "receive_failed" {
                    self.transfer = "failed".into();
                    self.error = text(
                        m["reason"]
                            .as_str()
                            .filter(|s| !s.is_empty())
                            .unwrap_or("AirDrop could not receive this transfer."),
                        200,
                    );
                } else {
                    self.transfer = "received".into();
                    let key = if event == "received" { "paths" } else { "urls" };
                    self.results = m[key]
                        .as_array()
                        .map(|v| {
                            v.iter()
                                .take(100)
                                .map(|v| {
                                    let s = v.as_str().unwrap_or("");
                                    if event == "received" {
                                        text(
                                            Path::new(s)
                                                .file_name()
                                                .unwrap_or_default()
                                                .to_string_lossy()
                                                .as_ref(),
                                            200,
                                        )
                                    } else {
                                        text(s, 500)
                                    }
                                })
                                .collect()
                        })
                        .unwrap_or_default();
                }
            }
            ("send", "accepted") => self.transfer = "sending".into(),
            ("send", "progress") => {
                let sent = m["sent"]
                    .as_u64()
                    .filter(|v| *v <= 9007199254740991)
                    .ok_or("Invalid progress")?;
                let total = m["total"]
                    .as_u64()
                    .filter(|v| *v <= 9007199254740991)
                    .ok_or("Invalid progress")?;
                if sent > total {
                    return Err("Invalid progress".into());
                }
                self.progress = json!({"sent":sent,"total":total});
            }
            ("send", "delivered" | "declined" | "failed") => {
                self.transfer = event.into();
                if let Some(p) = self.processes.get_mut(kind) {
                    p.terminal = true;
                }
                if event == "failed" {
                    self.error = text(
                        m["reason"]
                            .as_str()
                            .filter(|s| !s.is_empty())
                            .unwrap_or("AirDrop could not send these files."),
                        200,
                    );
                }
            }
            _ => {}
        }
        Ok(())
    }
    fn command(&mut self, req: Value) -> Result<(), String> {
        if !req.is_object()
            || req.get("generation").is_none()
            || !req.get("data").unwrap_or(&json!({})).is_object()
        {
            return Err("Invalid service request".into());
        }
        self.generation = req.get("generation").cloned();
        let data = &req["data"];
        match req["action"].as_str().unwrap_or("") {
            "probe" => self.probe(),
            "blocked" => self.blocked = data["enabled"] == true,
            "start" => {
                if self.blocked {
                    return Err("Stop AirPlay before enabling AirDrop.".into());
                }
                if !self.processes.is_empty() {
                    return Err("AirDrop is already enabled.".into());
                }
                self.probe();
                if !self.configured {
                    return Err(if self.notice.is_empty() {
                        "The AirDrop backend is not ready.".into()
                    } else {
                        self.notice.clone()
                    });
                }
                if self.mode != "shared" {
                    return Err("AirDrop would disconnect Wi-Fi and interrupt calls on this adapter. This mode is disabled.".into());
                }
                self.name = text(data["name"].as_str().unwrap_or(""), 200)
                    .trim()
                    .chars()
                    .take(60)
                    .collect();
                if self.name.is_empty() {
                    return Err("Choose an AirDrop name.".into());
                }
                self.epoch = uid().map_err(|e| e.to_string())?;
                self.error.clear();
                self.transfer = "idle".into();
                self.status = "starting".into();
                self.deadline = Some(Instant::now() + Duration::from_secs(600));
                if self
                    .spawn(
                        "radio",
                        vec!["radio".into(), "--seconds".into(), "600".into()],
                    )
                    .is_err()
                {
                    self.status = "error".into();
                    self.deadline = None;
                    self.error =
                        "AirDrop could not start. Check the backend setup and try again.".into();
                    return Err(self.error.clone());
                }
            }
            "stop" => self.stop(),
            "scan" => self.scan()?,
            "files" => {
                if self.processes.contains_key("send") {
                    return Err("Wait for the transfer or cancel it first.".into());
                }
                self.files = if data["paths"].as_array().is_none_or(|v| v.is_empty()) {
                    vec![]
                } else {
                    local_files(&data["paths"])?
                };
            }
            "send" => {
                if self.status != "ready" || self.pending.is_some() || self.receive_id.is_some() {
                    return Err("AirDrop is not ready for a new transfer.".into());
                }
                let key = data["key"]
                    .as_str()
                    .ok_or("Choose a discovered device. Search again if it disappeared.")?;
                let device = self
                    .devices
                    .get(key)
                    .ok_or("Choose a discovered device. Search again if it disappeared.")?
                    .clone();
                let paths = Value::Array(
                    self.files
                        .iter()
                        .map(|p| json!(p.to_string_lossy()))
                        .collect(),
                );
                self.files = local_files(&paths)?;
                self.error.clear();
                self.transfer = "waiting".into();
                self.results.clear();
                self.progress = json!({"sent":0,"total":0});
                self.stop_process("browse");
                self.scanning = false;
                let mut args = vec!["send".into()];
                args.extend(self.common());
                args.extend([
                    "--address".into(),
                    key.into(),
                    "--flags".into(),
                    device["flags"].to_string(),
                    "--".into(),
                ]);
                args.extend(self.files.iter().map(|p| p.to_string_lossy().into_owned()));
                self.spawn("send", args)?;
            }
            "answer" => {
                let (pending, expiry) = self.pending.as_ref().ok_or("This request has expired.")?;
                if data["key"] != pending["key"] || Instant::now() >= *expiry {
                    return Err("This request has expired.".into());
                }
                let id = pending["id"].clone();
                let accept = data["accept"] == true;
                self.write_receive(&id, accept)?;
                if accept {
                    self.receive_id = Some(id);
                    self.transfer = "receiving".into();
                    self.results.clear();
                }
                self.pending = None;
            }
            "cancel" => {
                self.stop_process("send");
                self.transfer = "cancelled".into();
            }
            "status" => {}
            _ => return Err("Unknown AirDrop action.".into()),
        }
        self.publish();
        Ok(())
    }
    fn tick(&mut self) {
        let now = Instant::now();
        if self.pending.as_ref().is_some_and(|p| now >= p.1) {
            self.pending = None;
        }
        let kinds: Vec<String> = self.processes.keys().cloned().collect();
        for kind in kinds {
            let Some(p) = self.processes.get_mut(&kind) else {
                continue;
            };
            if kind == "radio"
                && self.status == "starting"
                && now.duration_since(p.started) > Duration::from_secs(90)
            {
                self.fail("AirDrop did not start. Check the authorization dialog and try again.");
                break;
            }
            let code = match p.child.try_wait() {
                Ok(Some(s)) if p.streams == 0 => s,
                _ => continue,
            };
            let terminal = p.terminal;
            let error = p.error.clone();
            if kind == "radio" {
                if terminal {
                    self.stop();
                } else {
                    self.fail(if error.is_empty() {
                        "AirDrop radio stopped; Wi-Fi is being restored."
                    } else {
                        &error
                    });
                }
                break;
            }
            self.stop_process(&kind);
            match kind.as_str() {
                "browse" => {
                    self.scanning = false;
                    if !code.success() {
                        self.error = if error.is_empty() {
                            "AirDrop search failed.".into()
                        } else {
                            error
                        };
                    }
                }
                "receive" => {
                    self.receiving = false;
                    self.pending = None;
                    self.error = if error.is_empty() {
                        "AirDrop receiver stopped. Disable and enable AirDrop to retry.".into()
                    } else {
                        error
                    };
                }
                "send" if !terminal => {
                    self.transfer = "failed".into();
                    self.error = if error.is_empty() {
                        "The transfer ended without delivery confirmation.".into()
                    } else {
                        error
                    };
                }
                _ => {}
            }
        }
        if self.deadline.is_some_and(|v| now >= v) && !self.processes.is_empty() {
            self.stop();
        }
        self.publish();
    }
}
fn main() -> io::Result<()> {
    if env::args().nth(1).as_deref() == Some("--protocol-version") {
        println!("macshell-airdrop-service 1");
        return Ok(());
    }
    unsafe {
        libc::umask(0o077);
        for sig in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP] {
            libc::signal(sig, stop_signal as *const () as libc::sighandler_t);
        }
    }
    let (tx, rx) = mpsc::channel();
    let input_tx = tx.clone();
    std::thread::spawn(move || {
        let stdin = io::stdin();
        let mut input = stdin.lock();
        loop {
            let mut bytes = Vec::new();
            match input.by_ref().take(1048577).read_until(b'\n', &mut bytes) {
                Ok(0) | Err(_) => break,
                Ok(n) if n > 1048576 => break,
                Ok(_) => {
                    if input_tx.send(Event::Input(bytes)).is_err() {
                        return;
                    }
                }
            }
        }
        let _ = input_tx.send(Event::Eof);
    });
    let mut service = Service::new(tx);
    service.emit(json!({"type":"ready"}));
    while !STOP.load(Ordering::Relaxed) {
        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(Event::Input(bytes)) => {
                let r = serde_json::from_slice(&bytes)
                    .map_err(|_| "Invalid service request".to_string())
                    .and_then(|v| service.command(v));
                if let Err(e) = r {
                    service.emit(json!({"type":"error","error":text(&e,200)}));
                }
            }
            Ok(Event::Eof) => break,
            Ok(Event::Child(id, stream, bytes)) => {
                let kind = service
                    .processes
                    .iter()
                    .find(|(_, p)| p.id == id)
                    .map(|(k, _)| k.clone());
                if let Some(kind) = kind {
                    if stream == "stderr" {
                        if let Some(p) = service.processes.get_mut(&kind) {
                            p.error = text(&String::from_utf8_lossy(&bytes), 500);
                        }
                    } else {
                        let result = if bytes.len() > 1048576 {
                            Err("invalid".into())
                        } else {
                            serde_json::from_slice::<Value>(&bytes)
                                .map_err(|_| "invalid".to_string())
                                .and_then(|v| {
                                    if v.is_object() {
                                        service.event(&kind, v)
                                    } else {
                                        Err("invalid".into())
                                    }
                                })
                        };
                        if result.is_err() {
                            service.fail("AirDrop returned an invalid response.");
                        }
                    }
                    service.publish();
                }
            }
            Ok(Event::End(id, _stream)) => {
                if let Some(p) = service.processes.values_mut().find(|p| p.id == id) {
                    p.streams = p.streams.saturating_sub(1);
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
        service.tick();
    }
    Ok(())
}
