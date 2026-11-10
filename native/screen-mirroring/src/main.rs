use macshell_screen_mirroring::drm_dummy;
use macshell_screen_mirroring::niri::{self, Caps, CastMatch};
use macshell_screen_mirroring::{devices_from_response, valid_receiver_name, ReceiverState};
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixStream;
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
    Log(u64, String),
    Rpc(u64, Value, Result<Value, String>),
}

fn backend(name: &str) -> Option<PathBuf> {
    let executable = |p: &Path| {
        fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    };
    let home = env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let data = env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or(home.join(".local/share"));
    let p = data.join("macshell-niri/runtime/bin").join(name);
    if name == "doubletake" && executable(&p) {
        return Some(p);
    }
    if let Some(paths) = env::var_os("PATH") {
        for dir in env::split_paths(&paths) {
            let p = dir.join(name);
            if executable(&p) {
                return Some(p);
            }
        }
    }
    executable(&p).then_some(p)
}
fn config_dir() -> io::Result<PathBuf> {
    let home = env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let path = env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or(home.join(".config"))
        .join("macshell-niri/airplay");
    fs::create_dir_all(&path)?;
    Ok(path)
}
fn temp_dir() -> io::Result<PathBuf> {
    let mut bytes = [0u8; 16];
    fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    let name: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    let path = env::temp_dir().join(format!("macshell-airplay-{name}"));
    fs::create_dir(&path)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
    Ok(path)
}
fn spawn_owned(mut command: Command, log_id: u64, tx: Sender<Event>) -> io::Result<Child> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
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
    let mut child = command.spawn()?;
    for output in [
        child
            .stdout
            .take()
            .map(|v| Box::new(v) as Box<dyn Read + Send>),
        child
            .stderr
            .take()
            .map(|v| Box::new(v) as Box<dyn Read + Send>),
    ]
    .into_iter()
    .flatten()
    {
        let tx = tx.clone();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(output);
            loop {
                let mut bytes = Vec::new();
                match reader.by_ref().take(16385).read_until(b'\n', &mut bytes) {
                    Ok(0) | Err(_) => break,
                    _ => {
                        let _ = tx.send(Event::Log(
                            log_id,
                            String::from_utf8_lossy(&bytes).into_owned(),
                        ));
                    }
                }
            }
        });
    }
    Ok(child)
}
fn doubletake_supports_volume(binary: &Path) -> bool {
    Command::new(binary)
        .arg("-help")
        .output()
        .map(|output| {
            let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
            text.push_str(&String::from_utf8_lossy(&output.stderr));
            text.contains("volume-percent")
        })
        .unwrap_or(false)
}
fn stop_child(child: &mut Option<Child>) {
    if let Some(mut child) = child.take() {
        if matches!(child.try_wait(), Ok(None)) {
            unsafe {
                libc::kill(child.id() as i32, libc::SIGINT);
            }
            let end = Instant::now() + Duration::from_secs(2);
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
}

struct Service {
    tx: Sender<Event>,
    folder: PathBuf,
    generation: Option<Value>,
    last: Option<Value>,
    sender: Option<Child>,
    receiver: Option<Child>,
    sender_started: Instant,
    receiver_started: Instant,
    sender_state: String,
    sender_error: String,
    receiver_state: ReceiverState,
    receiver_name: String,
    watching: bool,
    scan_until: Instant,
    next_poll: Instant,
    devices: Vec<Value>,
    streams: Vec<Value>,
    queue: VecDeque<Value>,
    rpc_id: u64,
    rpc_active: bool,
    receiver_id: u64,
    credentials: VecDeque<String>,
    fps: u32,
    volume_percent: u32,
    layout: String,
    caps: Caps,
    owned_virtual: Option<String>,
    owned_dummy: Option<String>,
    extend_target: String,
    extend_capture: String,
    extend_cast_tries: u8,
    next_caps: Instant,
    next_cast: Instant,
}
impl Drop for Service {
    fn drop(&mut self) {
        stop_child(&mut self.sender);
        stop_child(&mut self.receiver);
        self.release_owned_virtual();
        let _ = fs::remove_dir_all(&self.folder);
    }
}
impl Service {
    fn new(tx: Sender<Event>) -> io::Result<Self> {
        let now = Instant::now();
        Ok(Self {
            tx,
            folder: temp_dir()?,
            generation: None,
            last: None,
            sender: None,
            receiver: None,
            sender_started: now,
            receiver_started: now,
            sender_state: "off".into(),
            sender_error: String::new(),
            receiver_state: ReceiverState {
                state: "off".into(),
                error: String::new(),
                pin: String::new(),
                client: String::new(),
            },
            receiver_name: "MacShell".into(),
            watching: false,
            scan_until: now,
            next_poll: now,
            devices: vec![],
            streams: vec![],
            queue: VecDeque::new(),
            rpc_id: 0,
            rpc_active: false,
            receiver_id: 0,
            credentials: VecDeque::new(),
            fps: 60,
            volume_percent: 20,
            layout: "mirror".into(),
            caps: Caps::default(),
            owned_virtual: None,
            owned_dummy: None,
            extend_target: String::new(),
            extend_capture: String::new(),
            extend_cast_tries: 0,
            next_caps: now,
            next_cast: now,
        })
    }
    fn emit(&self, mut message: Value) {
        if let Some(g) = &self.generation {
            message["generation"] = g.clone();
        }
        let mut out = io::stdout().lock();
        if writeln!(out, "{message}").is_err() {
            STOP.store(true, Ordering::Relaxed);
        }
    }
    fn publish(&mut self) {
        let state = json!({"type":"state","senderAvailable":backend("doubletake").is_some(),"receiverAvailable":backend("uxplay").is_some(),"senderState":self.sender_state,"senderError":self.sender_error,"receiverState":self.receiver_state.state,"receiverError":self.receiver_state.error,"receiverName":self.receiver_name,"receiverPin":self.receiver_state.pin,"receiverClient":self.receiver_state.client,"devices":self.devices,"streams":self.streams,"scanning":Instant::now()<self.scan_until,"layout":self.layout,"extendAvailable":self.caps.extend_available(),"extendOutput":self.caps.planned_output(),"virtualOutputsSupported":self.caps.virtual_create,"extendMethod":self.caps.extend_method(),"extendCapture":self.extend_capture});
        if self.last.as_ref() != Some(&state) {
            self.emit(state.clone());
            self.last = Some(state);
        }
    }
    fn refresh_caps(&mut self) {
        self.caps = niri::probe();
        self.next_caps = Instant::now() + Duration::from_secs(2);
    }
    fn release_owned_virtual(&mut self) {
        if let Some(name) = self.owned_virtual.take() {
            niri::remove_virtual(&name);
        }
        if let Some(name) = self.owned_dummy.take() {
            let _ = drm_dummy::disable(&name);
        }
        self.extend_target.clear();
        self.extend_capture.clear();
        self.extend_cast_tries = 0;
    }
    fn release_extend_if_idle(&mut self) {
        if ["starting", "connecting", "pin_required", "streaming"]
            .contains(&self.sender_state.as_str())
            || !self.streams.is_empty()
        {
            return;
        }
        self.release_owned_virtual();
    }
    fn retarget_extend(&mut self) {
        if self.layout != "extend"
            || self.extend_target.is_empty()
            || self.sender_state != "streaming"
        {
            return;
        }
        if self.extend_cast_tries >= 10 || Instant::now() < self.next_cast {
            return;
        }
        self.next_cast = Instant::now() + Duration::from_millis(500);
        self.extend_cast_tries = self.extend_cast_tries.saturating_add(1);
        match niri::match_casts(&niri::current_casts(), &self.extend_target) {
            CastMatch::Target => {
                self.extend_capture = "ok".into();
                self.extend_cast_tries = 10;
            }
            CastMatch::Dynamic | CastMatch::None => {
                niri::set_dynamic_cast(&self.extend_target);
                self.extend_capture = "pending".into();
            }
            CastMatch::Other => self.extend_capture = "wrong".into(),
        }
    }
    fn sender_stop(&mut self) {
        self.rpc_id += 1;
        self.rpc_active = false;
        self.queue.clear();
        stop_child(&mut self.sender);
        self.streams.clear();
        self.scan_until = Instant::now();
        self.release_owned_virtual();
    }
    fn sender_fail(&mut self, error: &str) {
        self.sender_stop();
        self.sender_state = "error".into();
        self.sender_error = error.into();
        self.devices.clear();
    }
    fn start_sender(&mut self) -> Result<(), String> {
        if self.sender.is_some() {
            return Ok(());
        }
        let Some(binary) = backend("doubletake") else {
            self.sender_state = "unavailable".into();
            self.sender_error =
                "Install doubletake to mirror this screen to an AirPlay display.".into();
            return Ok(());
        };
        let config = config_dir().map_err(|e| e.to_string())?;
        let socket = self.folder.join("sender.sock");
        let _ = fs::remove_file(&socket);
        let supports_volume = doubletake_supports_volume(&binary);
        if self.volume_percent != 100 && !supports_volume {
            self.sender_state = "error".into();
            self.sender_error =
                "This Doubletake runtime cannot set the TV volume. Install the patched runtime with -volume-percent.".into();
            return Ok(());
        }
        let mut cmd = Command::new(&binary);
        cmd.arg("-daemonize")
            .arg("-socket")
            .arg(socket)
            .arg("-fps")
            .arg(self.fps.to_string())
            .arg("-creds")
            .arg(config.join("credentials.json"));
        if supports_volume {
            cmd.arg("-volume-percent")
                .arg(self.volume_percent.to_string());
        }
        self.sender = Some(spawn_owned(cmd, 0, self.tx.clone()).map_err(|e| e.to_string())?);
        self.sender_started = Instant::now();
        self.sender_state = "starting".into();
        self.sender_error.clear();
        self.next_poll = Instant::now();
        Ok(())
    }
    fn start_receiver(&mut self, name: &str) -> Result<(), String> {
        if self.receiver.is_some() {
            return Ok(());
        }
        let Some(binary) = backend("uxplay") else {
            self.receiver_state.state = "unavailable".into();
            self.receiver_state.error =
                "Install uxplay to receive an iPhone, iPad or Mac screen.".into();
            return Ok(());
        };
        let name = valid_receiver_name(name)
            .ok_or("Use an AirPlay name of 1–60 UTF-8 bytes without control characters.")?;
        let rc = self.folder.join("uxplayrc");
        OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(&rc)
            .map_err(|e| e.to_string())?;
        let config = config_dir().map_err(|e| e.to_string())?;
        let mut cmd = if let Some(stdbuf) = backend("stdbuf") {
            let mut c = Command::new(stdbuf);
            c.args(["-oL", "-eL"]).arg(binary);
            c
        } else {
            Command::new(binary)
        };
        cmd.args(["-n", name, "-nh", "-pin", "-key"])
            .arg(config.join("receiver.pem"))
            .args([
                "-p",
                "7100",
                "-d",
                "1",
                "-vs",
                "waylandsink",
                "-as",
                "pipewiresink",
            ])
            .env("UXPLAYRC", rc)
            .env("LC_ALL", "C");
        self.receiver_id += 1;
        self.receiver =
            Some(spawn_owned(cmd, self.receiver_id, self.tx.clone()).map_err(|e| e.to_string())?);
        self.receiver_started = Instant::now();
        self.receiver_name = name.into();
        self.receiver_state = ReceiverState {
            state: "starting".into(),
            error: String::new(),
            pin: String::new(),
            client: String::new(),
        };
        Ok(())
    }
    fn enqueue(&mut self, v: Value) -> Result<(), String> {
        if self.sender.is_none() {
            return Err("Open Screen Mirroring and wait for AirPlay discovery first.".into());
        }
        if self.queue.len() >= 8 {
            return Err("Wait for the current AirPlay operation.".into());
        }
        self.queue.push_back(v);
        self.next_poll = Instant::now();
        Ok(())
    }
    fn begin_rpc(&mut self, request: Value) {
        self.rpc_id += 1;
        let id = self.rpc_id;
        self.rpc_active = true;
        let path = self.folder.join("sender.sock");
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let result = (|| -> Result<Value, String> {
                let mut s = UnixStream::connect(path)
                    .map_err(|_| "Could not contact the AirPlay sender.")?;
                s.set_read_timeout(Some(Duration::from_secs(3)))
                    .map_err(|e| e.to_string())?;
                s.set_write_timeout(Some(Duration::from_secs(3)))
                    .map_err(|e| e.to_string())?;
                writeln!(s, "{request}").map_err(|_| "Could not contact the AirPlay sender.")?;
                let mut data = Vec::new();
                let n = BufReader::new(s)
                    .take(1048577)
                    .read_until(b'\n', &mut data)
                    .map_err(|e| {
                        if matches!(
                            e.kind(),
                            io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                        ) {
                            "AirPlay sender did not respond. Try searching again."
                        } else {
                            "AirPlay sender returned an invalid response. Try searching again."
                        }
                    })?;
                if n > 1048576 {
                    return Err(
                        "AirPlay sender returned an invalid response. Try searching again.".into(),
                    );
                }
                serde_json::from_slice(&data).map_err(|_| {
                    "AirPlay sender returned an invalid response. Try searching again.".into()
                })
            })();
            let _ = tx.send(Event::Rpc(id, request, result));
        });
    }
    fn clean_error(&self, s: &str) -> String {
        let mut s: String = s.chars().take(400).collect();
        for secret in &self.credentials {
            s = s.replace(secret, "[hidden]");
        }
        s.chars().take(240).collect()
    }
    fn apply_rpc(&mut self, req: Value, res: Value) -> Result<(), String> {
        if !res.is_object() {
            return Err("AirPlay sender returned an invalid response. Try searching again.".into());
        }
        if res["ok"] != true {
            self.sender_error = self.clean_error(
                res["error"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .unwrap_or("AirPlay operation failed."),
            );
        }
        match req["cmd"].as_str().unwrap_or("") {
            "devices" => self.devices = devices_from_response(&res["devices"]),
            "status" => {
                if self.queue.iter().any(|v| v["cmd"] == "connect") {
                    return Ok(());
                }
                let state = res["state"].as_str().unwrap_or("idle");
                if ![
                    "idle",
                    "discovering",
                    "connecting",
                    "pin_required",
                    "streaming",
                ]
                .contains(&state)
                {
                    return Err(
                        "AirPlay sender returned an invalid response. Try searching again.".into(),
                    );
                }
                self.sender_state = if state == "idle" { "ready" } else { state }.into();
                self.streams=res["streams"].as_array().map(|items|items.iter().take(16).filter(|v|v.is_object()).map(|s|json!({"device":s["device"].as_str().or_else(||s["device_ip"].as_str()).filter(|v|!v.is_empty()).unwrap_or("AirPlay").chars().take(120).collect::<String>(),"address":s["device_ip"].as_str().unwrap_or(""),"state":s["state"].as_str().unwrap_or(""),"hasAudio":s["has_audio"]==true,"muted":s["audio_muted"]==true,"credentialKind":if s["credential_kind"]=="password"{"password"}else{"pin"}})).collect()).unwrap_or_default();
                self.sender_error = self.clean_error(
                    res["error"]
                        .as_str()
                        .filter(|v| !v.is_empty())
                        .unwrap_or(&self.sender_error),
                );
                if self.sender_state == "streaming" {
                    self.retarget_extend();
                } else {
                    self.release_extend_if_idle();
                }
            }
            _ => {}
        }
        Ok(())
    }
    fn command(&mut self, req: Value) -> Result<(), String> {
        if !req.is_object()
            || !req.get("data").unwrap_or(&json!({})).is_object()
            || req.get("generation").is_none()
        {
            return Err("Invalid service request".into());
        }
        self.generation = req.get("generation").cloned();
        let data = &req["data"];
        match req["action"].as_str().unwrap_or("") {
            "watch" => {
                self.watching = data["enabled"] == true;
                self.apply_preferences(data)?;
                self.refresh_caps();
                if self.watching {
                    self.start_sender()?;
                    self.scan_until = Instant::now() + Duration::from_secs(6);
                }
            }
            "refresh" => {
                self.sender_error.clear();
                self.apply_preferences(data)?;
                self.refresh_caps();
                self.start_sender()?;
                self.scan_until = Instant::now() + Duration::from_secs(6);
                self.next_poll = Instant::now();
            }
            "connect" => {
                if !self.streams.is_empty()
                    || ["starting", "connecting", "pin_required", "streaming"]
                        .contains(&self.sender_state.as_str())
                {
                    return Err("Stop the current mirror before choosing another display.".into());
                }
                self.apply_preferences(data)?;
                let key = data["key"].as_str().ok_or(
                    "The AirPlay display is no longer in the discovered list. Search again.",
                )?;
                let device = self
                    .devices
                    .iter()
                    .find(|d| d["key"] == key)
                    .ok_or(
                        "The AirPlay display is no longer in the discovered list. Search again.",
                    )?
                    .clone();
                if self.layout == "extend" {
                    let target = niri::ensure_extend()?;
                    self.extend_target = target.name.clone();
                    self.extend_capture.clear();
                    self.extend_cast_tries = 0;
                    self.next_cast = Instant::now();
                    if target.owned {
                        self.owned_virtual = Some(target.name.clone());
                    }
                    if target.dummy {
                        self.owned_dummy = Some(target.name);
                    }
                    self.refresh_caps();
                }
                self.sender_error.clear();
                if let Err(error) = self.enqueue(
                    json!({"cmd":"connect","target":device["address"],"port":device["port"]}),
                ) {
                    self.release_owned_virtual();
                    return Err(error);
                }
                self.sender_state = "connecting".into();
            }
            "credential" => {
                let stream=self.streams.iter().position(|s|s["state"]=="pin_required").ok_or("There is no pending AirPlay PIN/password request, or the value is invalid.")?;
                let credential=data["value"].as_str().filter(|s|!s.is_empty()&&s.chars().count()<=128&&!s.contains('\0')).ok_or("There is no pending AirPlay PIN/password request, or the value is invalid.")?.to_owned();
                self.sender_error.clear();
                self.credentials.push_back(credential.clone());
                if self.credentials.len() > 4 {
                    self.credentials.pop_front();
                }
                self.enqueue(json!({"cmd":"connect","target":self.streams[stream]["address"],"pin":credential}))?;
                self.sender_state = "connecting".into();
                self.streams[stream]["state"] = json!("connecting");
            }
            "disconnect" => {
                self.queue.clear();
                if self.sender.is_some() {
                    self.enqueue(json!({"cmd":"disconnect"}))?;
                }
                self.sender_error.clear();
            }
            "audio" => {
                if !self
                    .streams
                    .iter()
                    .any(|s| s["state"] == "streaming" && s["hasAudio"] == true)
                {
                    return Err("The AirPlay display has no active audio stream.".into());
                }
                self.enqueue(json!({"cmd":if data["enabled"]==true{"unmute"}else{"mute"}}))?;
            }
            "receive" => {
                if data["enabled"] == true {
                    self.start_receiver(data["name"].as_str().unwrap_or("MacShell"))?;
                } else {
                    stop_child(&mut self.receiver);
                    self.receiver_id += 1;
                    self.receiver_state = ReceiverState {
                        state: "off".into(),
                        error: String::new(),
                        pin: String::new(),
                        client: String::new(),
                    };
                }
            }
            "status" => {}
            _ => return Err("Unknown screen mirroring action.".into()),
        }
        self.publish();
        Ok(())
    }
    fn apply_preferences(&mut self, data: &Value) -> Result<(), String> {
        if let Some(value) = data["fps"].as_u64() {
            if !(1..=60).contains(&value) {
                return Err("AirPlay FPS must be between 1 and 60.".into());
            }
            if self.sender.is_some() && self.fps != value as u32 {
                return Err("Stop Screen Mirroring before changing FPS.".into());
            }
            self.fps = value as u32;
        }
        if let Some(value) = data["volumePercent"].as_u64() {
            if !(1..=100).contains(&value) {
                return Err("AirPlay volume must be between 1 and 100 percent.".into());
            }
            self.volume_percent = value as u32;
        }
        if let Some(value) = data["layout"].as_str() {
            if value != "mirror" && value != "extend" {
                return Err("AirPlay layout must be mirror or extend.".into());
            }
            if self.sender.is_some()
                && ["connecting", "pin_required", "streaming"].contains(&self.sender_state.as_str())
                && self.layout != value
            {
                return Err("Stop Screen Mirroring before changing display mode.".into());
            }
            self.layout = value.into();
        }
        Ok(())
    }
    fn tick(&mut self) {
        let now = Instant::now();
        if let Some(child) = self.sender.as_mut() {
            if !matches!(child.try_wait(), Ok(None)) {
                self.sender_fail(
                    "AirPlay sender stopped. Check Doubletake and its GStreamer dependencies.",
                );
            } else if self.sender_state == "starting"
                && now.duration_since(self.sender_started) > Duration::from_secs(8)
            {
                self.sender_fail("AirPlay sender could not open its control socket.");
            } else if !self.rpc_active
                && self.folder.join("sender.sock").exists()
                && now >= self.next_poll
            {
                let request = if let Some(v) = self.queue.pop_front() {
                    v
                } else {
                    if self.watching {
                        self.queue.push_back(json!({"cmd":"devices"}));
                    }
                    self.next_poll = now + Duration::from_secs(1);
                    json!({"cmd":"status"})
                };
                self.begin_rpc(request);
            }
            if self.sender_state == "ready"
                && !self.watching
                && self.queue.is_empty()
                && !self.rpc_active
            {
                self.sender_stop();
                self.sender_state = "off".into();
            }
        }
        if let Some(child) = self.receiver.as_mut() {
            let exited = !matches!(child.try_wait(), Ok(None));
            let timed_out = self.receiver_state.state == "starting"
                && now.duration_since(self.receiver_started) > Duration::from_secs(10);
            if exited || timed_out || self.receiver_state.state == "error" {
                stop_child(&mut self.receiver);
                self.receiver_id += 1;
                self.receiver_state.state = "error".into();
                if self.receiver_state.error.is_empty() {
                    self.receiver_state.error = if timed_out {
                        "AirPlay receiver did not advertise on the network."
                    } else {
                        "AirPlay receiver stopped. Check UxPlay and its GStreamer dependencies."
                    }
                    .into();
                }
                self.receiver_state.pin.clear();
                self.receiver_state.client.clear();
            }
        }
        if self.watching && now >= self.next_caps {
            self.refresh_caps();
        }
        self.retarget_extend();
        self.publish();
    }
}

fn main() -> io::Result<()> {
    if env::args().nth(1).as_deref() == Some("--protocol-version") {
        println!("macshell-screen-mirroring 1");
        return Ok(());
    }
    if env::args().nth(1).as_deref() == Some("--drm-dummy") {
        let args: Vec<String> = env::args().skip(2).collect();
        std::process::exit(drm_dummy::cli(&args));
    }
    unsafe {
        libc::umask(0o077);
        libc::signal(libc::SIGINT, stop_signal as *const () as libc::sighandler_t);
        libc::signal(
            libc::SIGTERM,
            stop_signal as *const () as libc::sighandler_t,
        );
        libc::signal(libc::SIGHUP, stop_signal as *const () as libc::sighandler_t);
    }
    let (tx, rx) = mpsc::channel();
    let input_tx = tx.clone();
    std::thread::spawn(move || {
        let stdin = io::stdin();
        let mut input = stdin.lock();
        loop {
            let mut buf = Vec::new();
            match input.by_ref().take(1048577).read_until(b'\n', &mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) if n > 1048576 => break,
                Ok(_) => {
                    if input_tx.send(Event::Input(buf)).is_err() {
                        return;
                    }
                }
            }
        }
        let _ = input_tx.send(Event::Eof);
    });
    let mut service = Service::new(tx)?;
    service.emit(json!({"type":"ready"}));
    while !STOP.load(Ordering::Relaxed) {
        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(Event::Input(line)) => {
                let result = serde_json::from_slice::<Value>(&line)
                    .map_err(|_| "Invalid service request".to_string())
                    .and_then(|v| service.command(v));
                if let Err(e) = result {
                    service.emit(
                        json!({"type":"error","error":e.chars().take(200).collect::<String>()}),
                    );
                }
            }
            Ok(Event::Eof) => break,
            Ok(Event::Log(id, line)) => {
                if id != 0 && id == service.receiver_id && service.receiver.is_some() {
                    service.receiver_state.apply_line(&line);
                    service.publish();
                }
            }
            Ok(Event::Rpc(id, request, result)) => {
                if id == service.rpc_id && service.rpc_active {
                    service.rpc_active = false;
                    let result = result.and_then(|v| service.apply_rpc(request, v));
                    if let Err(e) = result {
                        service.sender_fail(&e);
                    }
                    service.publish();
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
        service.tick();
    }
    Ok(())
}
