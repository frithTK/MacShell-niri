//! Experimental recorder. Never selected by the installed shell.
mod audio_runtime;
use macshell_recording_core::{
    audio::{self, State as AudioState},
    geometry,
    lifecycle::{Effect, Recorder, State},
    niri::{self, Peer},
    outputs,
    owned::{reserve, OwnedChild},
    validation,
};
use serde_json::{json, Value};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn shutdown(_: i32) {
    STOP.store(true, Ordering::Relaxed);
}
enum Input {
    Line(Vec<u8>),
    Eof,
}
struct Service {
    start: Instant,
    recorder: Recorder,
    peer: Option<Peer>,
    generation: Option<Value>,
    config: Value,
    file: Option<PathBuf>,
    child: Option<OwnedChild>,
    child_log: Receiver<(u64, String)>,
    log_tx: SyncSender<(u64, String)>,
    log_epoch: u64,
    log: String,
    #[cfg(feature = "test-diagnostics")]
    initial_log: String,
    video_seen: bool,
    video_progress: Arc<AtomicBool>,
    audio_failure: Arc<AtomicBool>,
    error: String,
    started: Option<u64>,
    countdown: i32,
    countdown_deadline: Option<u64>,
    next_validate: u64,
    audio_backend: String,
    audio_target: String,
    routes: Vec<OwnedChild>,
    audio_routes: Vec<[String; 4]>,
    mix_token: String,
    selector: Option<OwnedChild>,
    selection_result: Option<Receiver<Vec<u8>>>,
    selection_status: Option<bool>,
    selector_deadline: Option<u64>,
}
fn now(start: Instant) -> u64 {
    start.elapsed().as_millis().min(u64::MAX as u128) as u64
}
fn executable(name: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|paths| {
        std::env::split_paths(&paths).any(|p| {
            std::fs::metadata(p.join(name))
                .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
    })
}
fn output_file() -> io::Result<PathBuf> {
    let folder = PathBuf::from(
        std::env::var_os("HOME")
            .ok_or_else(|| io::Error::other("Home directory is unavailable"))?,
    )
    .join("Videos");
    std::fs::create_dir_all(&folder)?;
    let mut random = [0u8; 8];
    let read = unsafe { libc::getrandom(random.as_mut_ptr().cast(), random.len(), 1) };
    if read != random.len() as isize {
        return Err(io::Error::other("Cannot create a unique recording name"));
    }
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(io::Error::other)?
        .as_secs();
    let suffix: String = random.iter().map(|b| format!("{b:02x}")).collect();
    let path = folder.join(format!("Screen-Recording-{stamp}-{suffix}.mkv"));
    drop(reserve(&path)?);
    Ok(path)
}
fn probe(path: &Path, expect_audio: bool) -> bool {
    let mut command = Command::new("ffprobe");
    command
        .args([
            "-v",
            "error",
            "-show_entries",
            "format=duration:stream=codec_type",
            "-of",
            "json",
        ])
        .arg(path)
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let Ok(mut child) = OwnedChild::spawn(&mut command) else {
        return false;
    };
    let Some(output) = child.child_mut().stdout.take() else {
        return false;
    };
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let mut data = Vec::new();
        let _ = output.take(1_048_577).read_to_end(&mut data);
        let _ = tx.send(data);
    });
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => {
                return rx
                    .recv_timeout(Duration::from_secs(1))
                    .ok()
                    .filter(|d| d.len() <= 1_048_576)
                    .and_then(|d| serde_json::from_slice::<Value>(&d).ok())
                    .is_some_and(|v| validation::valid_file(&v, expect_audio));
            }
            Ok(Some(_)) | Err(_) => return false,
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(20)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
        }
    }
}
fn progress(log: &str) -> bool {
    log.lines().any(|line| {
        line.split_once("Writing block of size ")
            .is_some_and(|(_, tail)| {
                tail.split_whitespace()
                    .next()
                    .and_then(|v| v.parse::<u64>().ok())
                    .is_some_and(|n| n > 0)
                    && tail.contains("TrackNumber 1,")
            })
            || line.split_once("frame=").is_some_and(|(_, tail)| {
                tail.split_whitespace()
                    .next()
                    .and_then(|v| v.parse::<u64>().ok())
                    .is_some_and(|n| n > 0)
            })
    })
}
fn audio_error(log: &str) -> bool {
    [
        "not found, using default",
        "pipewire: core error",
        "Failed to connect to PulseAudio",
        "Failed to read from PulseAudio stream",
    ]
    .iter()
    .any(|s| log.contains(s))
}
impl Service {
    fn emit(&self, mut value: Value) {
        if let Some(generation) = &self.generation {
            value["generation"] = generation.clone();
        }
        let mut out = io::stdout().lock();
        if serde_json::to_writer(&mut out, &value).is_err()
            || writeln!(out).is_err()
            || out.flush().is_err()
        {
            STOP.store(true, Ordering::Relaxed);
        }
    }
    fn state(&self) -> &'static str {
        match self.recorder.state() {
            State::Choose => "choose",
            State::Selecting => "selecting",
            State::Countdown => "countdown",
            State::Starting => "starting",
            State::Mixing => "mixing",
            State::Recording => "recording",
            State::Stopping => "stopping",
            State::Saving => "saving",
            State::Result => "result",
            State::Error => "error",
        }
    }
    fn publish(&self) {
        self.emit(
            json!({"type":"state","state":self.state(),"countdown":self.countdown,
            "elapsed":self.started.map(|s| now(self.start).saturating_sub(s) / 1000).unwrap_or(0),
            "file":self.file.as_ref().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default(),
            "geometry":self.config["geometry"].as_str().unwrap_or(""),"error":self.error}),
        );
    }
    fn outputs(&mut self) -> Result<Vec<Value>, String> {
        let path = std::env::var_os("NIRI_SOCKET").ok_or("Niri socket is unavailable")?;
        niri::outputs(Path::new(&path), &mut self.peer).map_err(|e| e.to_string())
    }
    fn validate_monitor(&mut self) -> Result<(), String> {
        let output = self.config["output"]
            .as_str()
            .ok_or("Select a monitor.")?
            .to_owned();
        let selected = self
            .outputs()?
            .into_iter()
            .find(|v| v["name"].as_str() == Some(output.as_str()))
            .ok_or("The selected monitor is no longer available.")?;
        if self.config["region"].as_bool().unwrap_or(false) {
            let region = self.config["geometry"]
                .as_str()
                .ok_or("Invalid selection. Choose the area again.")?;
            let logical = outputs::rect(&selected["logical"]).map_err(str::to_owned)?;
            self.config["geometry"] = json!(geometry(region, logical).map_err(str::to_owned)?);
        }
        Ok(())
    }
    fn validate(&mut self) -> Result<(), String> {
        self.validate_monitor()?;
        let mode = self.config["audio"].as_str().unwrap_or("none");
        let selected: &[(&str, &str)] = match mode {
            "none" => return Ok(()),
            "system" => &[("sink", "Audio/Sink")],
            "mic" => &[("microphone", "Audio/Source")],
            "both" => &[("sink", "Audio/Sink"), ("microphone", "Audio/Source")],
            _ => return Err("Invalid audio mode.".into()),
        };
        let graph = audio_runtime::graph().map_err(str::to_owned)?;
        let objects = graph.as_array().ok_or("Invalid audio service response.")?;
        for (key, class) in selected {
            let name = self.config[*key]
                .as_str()
                .filter(|v| !v.is_empty())
                .ok_or("Choose an audio device.")?;
            let matches = objects
                .iter()
                .filter(|o| {
                    o["info"]["props"]["node.name"].as_str() == Some(name)
                        && o["info"]["props"]["media.class"].as_str() == Some(*class)
                })
                .count();
            if matches != 1 {
                return Err(
                "The selected audio device disappeared or is not unique. Choose a device again."
                    .into(),
            );
            }
        }
        Ok(())
    }
    fn audio_state(&self) -> Result<AudioState, String> {
        let child = self.child.as_ref().ok_or("Recorder is unavailable.")?;
        let graph = audio_runtime::graph().map_err(str::to_owned)?;
        let (nodes, links) = audio::parse_graph(&graph).map_err(str::to_owned)?;
        let routes: Vec<_> = self
            .audio_routes
            .iter()
            .map(|v| [v[0].as_str(), v[1].as_str(), v[2].as_str(), v[3].as_str()])
            .collect();
        Ok(audio::link_state(
            &nodes,
            &links,
            child.id(),
            &self.audio_target,
            &routes,
        ))
    }
    fn route(&mut self, args: &[String]) -> Result<(), String> {
        let mut command = Command::new("pw-loopback");
        command
            .args(args)
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut child = OwnedChild::spawn(&mut command).map_err(|e| e.to_string())?;
        child.set_drop_grace(Duration::from_secs(2));
        self.routes.push(child);
        Ok(())
    }
    fn begin_mix(&mut self) -> Result<(), String> {
        if !executable("pw-loopback") {
            return Err("Install pw-loopback to mix microphone and system audio.".into());
        }
        let mut random = [0u8; 16];
        if unsafe { libc::getrandom(random.as_mut_ptr().cast(), random.len(), 1) }
            != random.len() as isize
        {
            return Err("Cannot create a unique audio mixer identity.".into());
        }
        self.mix_token = format!(
            "macshell_record_{}",
            random
                .iter()
                .map(|v| format!("{v:02x}"))
                .collect::<String>()
        );
        let sink = format!("{}_sink", self.mix_token);
        let source = format!("{}_source", self.mix_token);
        let input = json!({"node.virtual":true,"node.autoconnect":false,"node.dont-reconnect":true,"node.name":sink,"media.class":"Audio/Sink"}).to_string();
        let output = json!({"node.virtual":true,"node.autoconnect":false,"node.dont-reconnect":true,"node.name":source,"media.class":"Audio/Source"}).to_string();
        self.route(&[
            "-n".into(),
            self.mix_token.clone(),
            "-c".into(),
            "2".into(),
            "-i".into(),
            input,
            "-o".into(),
            output,
        ])?;
        self.audio_target = source;
        self.next_validate = 0;
        let e = self.recorder.mixing(now(self.start));
        self.effects(e);
        Ok(())
    }
    fn connect_mix(&mut self) -> Result<(), String> {
        let sink = format!("{}_sink", self.mix_token);
        for (role, key) in [("system", "sink"), ("mic", "microphone")] {
            let target = self.config[key]
                .as_str()
                .ok_or("Choose an audio device.")?
                .to_owned();
            let capture = format!("{}_{}_capture", self.mix_token, role);
            let playback = format!("{}_{}_playback", self.mix_token, role);
            let mut input = json!({"node.dont-reconnect":true,"node.name":capture});
            if role == "system" {
                input["stream.capture.sink"] = json!(true);
            }
            let output = json!({"node.dont-reconnect":true,"node.name":playback}).to_string();
            self.route(&[
                "-n".into(),
                format!("{}_{}", self.mix_token, role),
                "-C".into(),
                target.clone(),
                "-P".into(),
                sink.clone(),
                "-i".into(),
                input.to_string(),
                "-o".into(),
                output,
            ])?;
            self.audio_routes
                .push([target, capture, playback, sink.clone()]);
        }
        Ok(())
    }
    fn select(&mut self) -> Result<(), String> {
        let output = self.config["output"]
            .as_str()
            .ok_or("Select a monitor.")?
            .to_owned();
        let selected = self
            .outputs()?
            .into_iter()
            .find(|v| v["name"].as_str() == Some(output.as_str()))
            .ok_or("The selected monitor is no longer available.")?;
        let rect = outputs::rect(&selected["logical"]).map_err(str::to_owned)?;
        let hint = format!(
            "{},{} {}x{} {}\n",
            rect.x, rect.y, rect.width, rect.height, output
        );
        let mut command = Command::new("slurp");
        command
            .args(["-f", "%x,%y %wx%h"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = OwnedChild::spawn_with_stdin(&mut command).map_err(|e| e.to_string())?;
        child.set_drop_grace(Duration::from_secs(3));
        let mut stdin = child
            .child_mut()
            .stdin
            .take()
            .ok_or("Could not start area selector.")?;
        stdin
            .write_all(hint.as_bytes())
            .map_err(|e| e.to_string())?;
        drop(stdin);
        let stdout = child
            .child_mut()
            .stdout
            .take()
            .ok_or("Could not start area selector.")?;
        let (tx, rx) = mpsc::channel();
        thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = stdout.take(4097).read_to_end(&mut bytes);
            let _ = tx.send(bytes);
        });
        self.selection_result = Some(rx);
        self.selection_status = None;
        self.selector = Some(child);
        Ok(())
    }
    fn spawn(&mut self) -> Result<(), String> {
        self.validate()?;
        if !self.audio_target.is_empty() {
            let graph = audio_runtime::graph().map_err(str::to_owned)?;
            let expected = if self.config["audio"].as_str() == Some("system") {
                "Audio/Sink"
            } else {
                "Audio/Source"
            };
            let count = graph
                .as_array()
                .ok_or("Invalid audio service response.")?
                .iter()
                .filter(|v| {
                    v["info"]["props"]["node.name"].as_str() == Some(self.audio_target.as_str())
                        && v["info"]["props"]["media.class"].as_str() == Some(expected)
                })
                .count();
            if count != 1 {
                return Err("The selected audio source is no longer uniquely available.".into());
            }
        }
        let file = output_file().map_err(|e| e.to_string())?;
        self.file = Some(file.clone());
        let mut command = Command::new("wf-recorder");
        command.arg("-f").arg(&file).args([
            "-y",
            "-o",
            self.config["output"].as_str().ok_or("Select a monitor.")?,
            "-r",
            "60",
            "--no-damage",
            "-c",
            "libx264",
            "-p",
            "preset=veryfast",
            "-p",
            "crf=20",
            "-F",
            "pad=ceil(iw/2)*2:ceil(ih/2)*2",
            "--log",
        ]);
        if self.config["region"].as_bool().unwrap_or(false) {
            command.arg("-g").arg(
                self.config["geometry"]
                    .as_str()
                    .ok_or("Invalid selection.")?,
            );
        }
        if !self.audio_target.is_empty() {
            let source = if self.audio_backend == "pulse" {
                audio_runtime::pulse_source(
                    &self.audio_target,
                    self.config["audio"].as_str() == Some("system"),
                )
                .map_err(str::to_owned)?
            } else {
                self.audio_target.clone()
            };
            command
                .arg(format!("--audio-backend={}", self.audio_backend))
                .arg(format!("--audio={source}"));
            if self.audio_backend == "pulse" {
                for key in [
                    "node.dont-reconnect",
                    "node.dont-fallback",
                    "node.dont-move",
                ] {
                    command.env(format!("PULSE_PROP_{key}"), "true");
                }
            }
        }
        command.stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = OwnedChild::spawn(&mut command).map_err(|e| e.to_string())?;
        self.log_epoch = self
            .log_epoch
            .checked_add(1)
            .ok_or("Recording sequence exhausted.")?;
        let epoch = self.log_epoch;
        self.video_progress = Arc::new(AtomicBool::new(false));
        self.audio_failure = Arc::new(AtomicBool::new(false));
        for pipe in [
            child
                .child_mut()
                .stdout
                .take()
                .map(|p| Box::new(p) as Box<dyn Read + Send>),
            child
                .child_mut()
                .stderr
                .take()
                .map(|p| Box::new(p) as Box<dyn Read + Send>),
        ]
        .into_iter()
        .flatten()
        {
            let tx = self.log_tx.clone();
            let progress_flag = Arc::clone(&self.video_progress);
            let audio_flag = Arc::clone(&self.audio_failure);
            thread::spawn(move || {
                let mut input = pipe;
                let mut bytes = [0u8; 4096];
                let mut recent = String::new();
                while let Ok(n) = input.read(&mut bytes) {
                    if n == 0 {
                        break;
                    }
                    let chunk = String::from_utf8_lossy(&bytes[..n]).into_owned();
                    recent.push_str(&chunk);
                    if progress(&recent) {
                        progress_flag.store(true, Ordering::Release);
                    }
                    if audio_error(&recent) {
                        audio_flag.store(true, Ordering::Release);
                    }
                    if recent.len() > 8192 {
                        let mut cutoff = recent.len() - 8192;
                        while !recent.is_char_boundary(cutoff) {
                            cutoff += 1;
                        }
                        recent.drain(..cutoff);
                    }
                    match tx.try_send((epoch, chunk)) {
                        Ok(()) | Err(mpsc::TrySendError::Full(_)) => (),
                        Err(mpsc::TrySendError::Disconnected(_)) => break,
                    }
                }
            });
        }
        self.child = Some(child);
        self.started = Some(now(self.start));
        self.next_validate = 0;
        self.log.clear();
        #[cfg(feature = "test-diagnostics")]
        self.initial_log.clear();
        self.video_seen = false;
        let effects = self
            .recorder
            .spawned(now(self.start), !self.audio_target.is_empty());
        self.effects(effects);
        Ok(())
    }
    fn effects(&mut self, effects: Vec<Effect>) {
        for effect in effects {
            match effect {
                Effect::Publish => self.publish(),
                Effect::HideControls => (),
                Effect::CleanRoutes => {
                    while let Some(route) = self.routes.pop() {
                        drop(route);
                    }
                    self.audio_routes.clear();
                    self.mix_token.clear();
                }
                Effect::StartSelector => {
                    if let Err(error) = self.select() {
                        self.error = error;
                        let e = self.recorder.fail(now(self.start));
                        self.effects(e);
                    }
                }
                Effect::StopSelector => {
                    if let Some(selector) = &mut self.selector {
                        let _ = selector.interrupt();
                        self.selector_deadline = Some(now(self.start).saturating_add(3000));
                    }
                }
                Effect::StartRecorder => {
                    let starting_mix =
                        self.config["audio"].as_str() == Some("both") && self.routes.is_empty();
                    let result = self.validate().and_then(|()| {
                        if starting_mix {
                            self.begin_mix()
                        } else {
                            self.spawn()
                        }
                    });
                    if let Err(error) = result {
                        self.error = error;
                        let e = self.recorder.fail(now(self.start));
                        self.effects(e);
                    }
                }
                Effect::InterruptRecorder => {
                    if let Some(child) = &mut self.child {
                        let _ = child.interrupt();
                    }
                }
                Effect::KillRecorder => {
                    if let Some(child) = &mut self.child {
                        let _ = child.kill();
                    }
                }
                Effect::ValidateFile => {
                    let valid = self
                        .file
                        .as_ref()
                        .is_some_and(|p| probe(p, !self.audio_target.is_empty()));
                    let e = self.recorder.validated(valid);
                    if self.recorder.state() == State::Error && self.error.is_empty() {
                        self.error = "Recording did not finish cleanly. A partial file was kept; check it before using it.".into();
                    }
                    self.effects(e);
                }
            }
        }
    }
    fn command(&mut self, request: Value) -> Result<(), String> {
        if !request.is_object() || !request["data"].is_object() {
            return Err("Invalid service request".into());
        }
        if let Some(generation) = request.get("generation") {
            if self.generation.as_ref().is_some_and(|v| v != generation) {
                return Ok(());
            }
            self.generation = Some(generation.clone());
        }
        let data = &request["data"];
        match request["action"].as_str().unwrap_or("") {
            "status" => self.publish(),
            "prepare" => {
                let outputs = self.outputs()?;
                let (audio, audio_error) =
                    match audio_runtime::graph().and_then(|v| audio_runtime::choices(&v)) {
                        Ok(audio) => (audio, ""),
                        Err(_) => (
                            json!({"microphones":[],"sinks":[]}),
                            "PipeWire audio is unavailable.",
                        ),
                    };
                self.emit(json!({"type":"choices", "outputs":outputs,"audio":audio,"audioError":audio_error, "available":executable("wf-recorder"),"mixAvailable":executable("pw-loopback")}));
            }
            "stop" | "cancel" => {
                let effects = self.recorder.stop(now(self.start));
                self.effects(effects);
            }
            "start" => {
                if self.selector.is_some() || self.selection_status.is_some() {
                    return Err("Wait for the area selector to close, then try again.".into());
                }
                let mode = data["audio"].as_str().unwrap_or("none");
                if !matches!(mode, "none" | "system" | "mic" | "both") {
                    return Err(
                        "This audio mode is not supported by this experimental build.".into(),
                    );
                }
                if mode == "both" && !executable("pw-loopback") {
                    return Err("Install pw-loopback to mix microphone and system audio.".into());
                }
                if !executable("wf-recorder") || !executable("ffprobe") {
                    return Err("Install wf-recorder and ffmpeg (ffprobe) to record.".into());
                }
                if !matches!(
                    self.recorder.state(),
                    State::Choose | State::Error | State::Result
                ) {
                    return Err("A recording operation is already in progress.".into());
                }
                self.config = data.clone();
                self.validate()?;
                self.audio_backend = if mode == "none" {
                    String::new()
                } else {
                    audio_runtime::backend().map_err(str::to_owned)?.to_owned()
                };
                self.audio_target = match mode {
                    "system" => data["sink"].as_str().unwrap_or(""),
                    "mic" => data["microphone"].as_str().unwrap_or(""),
                    _ => "",
                }
                .to_owned();
                self.file = None;
                self.error.clear();
                self.started = None;
                self.countdown = 3;
                self.next_validate = 0;
                self.countdown_deadline = Some(now(self.start).saturating_add(3000));
                let effects = self
                    .recorder
                    .start(now(self.start))
                    .map_err(str::to_owned)?;
                self.effects(effects);
            }
            "select" => {
                if self.selector.is_some() || self.selection_status.is_some() {
                    return Err("Wait for the area selector to close, then try again.".into());
                }
                if !executable("slurp") {
                    return Err("Install slurp to select an area.".into());
                }
                if !matches!(
                    self.recorder.state(),
                    State::Choose | State::Error | State::Result
                ) {
                    return Err("A recording operation is already in progress.".into());
                }
                self.config = data.clone();
                self.config["region"] = json!(false);
                self.validate_monitor()?;
                self.error.clear();
                let effects = self
                    .recorder
                    .select(now(self.start))
                    .map_err(str::to_owned)?;
                self.effects(effects);
            }
            _ => return Err("Unknown recording action.".into()),
        }
        Ok(())
    }
    fn tick(&mut self) {
        if self.recorder.state() == State::Countdown {
            if let Some(deadline) = self.countdown_deadline {
                let seconds = deadline.saturating_sub(now(self.start)).div_ceil(1000) as i32;
                if seconds != self.countdown {
                    self.countdown = seconds;
                    self.publish();
                }
            }
        }
        if self.recorder.state() == State::Mixing && now(self.start) >= self.next_validate {
            self.next_validate = now(self.start).saturating_add(200);
            let exited = self
                .routes
                .iter_mut()
                .any(|child| !matches!(child.try_wait(), Ok(None)));
            if exited {
                self.error = "The PipeWire mixer could not start.".into();
                let e = self.recorder.fail(now(self.start));
                self.effects(e);
            } else {
                let ready = audio_runtime::graph()
                    .ok()
                    .and_then(|v| v.as_array().cloned())
                    .is_some_and(|objects| {
                        let count = |name: &str| {
                            objects
                                .iter()
                                .filter(|v| v["info"]["props"]["node.name"].as_str() == Some(name))
                                .count()
                        };
                        count(&format!("{}_sink", self.mix_token)) == 1
                            && count(&self.audio_target) == 1
                    });
                if ready {
                    match self.connect_mix() {
                        Ok(()) => {
                            let e = self.recorder.mixer_ready();
                            self.effects(e);
                        }
                        Err(error) => {
                            self.error = error;
                            let e = self.recorder.fail(now(self.start));
                            self.effects(e);
                        }
                    }
                }
            }
        }
        if let Some(selector) = &mut self.selector {
            if self
                .selector_deadline
                .is_some_and(|deadline| now(self.start) >= deadline)
            {
                let _ = selector.kill();
                self.selector_deadline = None;
            }
            if let Ok(Some(status)) = selector.try_wait() {
                self.selection_status = Some(status.success());
                self.selector.take();
                self.selector_deadline = None;
            }
        }
        if let Some(success) = self.selection_status {
            if let Some(data) = self
                .selection_result
                .as_ref()
                .and_then(|r| r.try_recv().ok())
            {
                self.selection_result = None;
                self.selection_status = None;
                if self.recorder.state() == State::Selecting {
                    if success {
                        let region = String::from_utf8_lossy(&data).trim().to_owned();
                        self.config["geometry"] = json!(region);
                        self.config["region"] = json!(true);
                        if data.len() > 4096 {
                            self.error = "Invalid selection. Choose the area again.".into();
                        } else if let Err(error) = self.validate() {
                            self.error = error;
                        }
                    }
                    if self.error.is_empty() {
                        let e = self.recorder.selection_done();
                        self.effects(e);
                    } else {
                        let e = self.recorder.fail(now(self.start));
                        self.effects(e);
                    }
                }
            }
        }
        for _ in 0..32 {
            let Ok((epoch, chunk)) = self.child_log.try_recv() else {
                break;
            };
            if epoch != self.log_epoch {
                continue;
            }
            self.log.push_str(&chunk);
            #[cfg(feature = "test-diagnostics")]
            if self.initial_log.len() < 8192 {
                self.initial_log
                    .extend(chunk.chars().take(8192 - self.initial_log.len()));
            }
            self.video_seen |= progress(&self.log);
            if self.log.len() > 16384 {
                let mut n = self.log.len() - 16384;
                while !self.log.is_char_boundary(n) {
                    n += 1;
                }
                self.log.drain(..n);
            }
        }
        self.video_seen |= self.video_progress.load(Ordering::Acquire);
        if !self.audio_target.is_empty()
            && self.child.is_some()
            && matches!(self.recorder.state(), State::Starting | State::Recording)
            && self.audio_failure.load(Ordering::Acquire)
        {
            self.error =
                "The audio source was lost. Recording stopped to avoid capturing another device."
                    .into();
            let effects = self.recorder.fail(now(self.start));
            self.effects(effects);
        }
        if self.recorder.state() == State::Starting
            && self.child.is_some()
            && self.video_seen
            && now(self.start) >= self.next_validate
        {
            self.next_validate = now(self.start).saturating_add(1000);
            let audio = if self.audio_target.is_empty() {
                Ok(AudioState::Ready)
            } else {
                self.audio_state()
            };
            match audio {
                Ok(AudioState::Ready) => {
                    let effects = self.recorder.ready(true, true);
                    self.effects(effects);
                }
                Ok(AudioState::Waiting) => (),
                Ok(AudioState::Wrong) => {
                    self.error = "The recorder connected to an unexpected audio source.".into();
                    let e = self.recorder.fail(now(self.start));
                    self.effects(e);
                }
                Err(error) => {
                    self.error = error;
                    let e = self.recorder.fail(now(self.start));
                    self.effects(e);
                }
            }
        }
        if self.recorder.state() == State::Recording && now(self.start) >= self.next_validate {
            self.next_validate = now(self.start).saturating_add(1000);
            if self
                .routes
                .iter_mut()
                .any(|child| !matches!(child.try_wait(), Ok(None)))
            {
                self.error = "The audio mixer stopped. A partial recording was kept.".into();
                let effects = self.recorder.fail(now(self.start));
                self.effects(effects);
            } else if let Err(error) = self.validate() {
                self.error = error;
                let effects = self.recorder.fail(now(self.start));
                self.effects(effects);
            } else if !self.audio_target.is_empty() && self.audio_state() != Ok(AudioState::Ready) {
                self.error = "An audio link disappeared. Recording stopped to avoid capturing another device.".into();
                let effects = self.recorder.fail(now(self.start));
                self.effects(effects);
            }
        }
        if let Some(child) = &mut self.child {
            if let Ok(Some(status)) = child.try_wait() {
                #[cfg(feature = "test-diagnostics")]
                eprintln!(
                    "TEST_RECORDER_EXIT status={status:?} initial={} recent={}",
                    self.initial_log, self.log
                );
                let accepted = status.success()
                    || status.code() == Some(130)
                    || status.signal() == Some(libc::SIGINT);
                self.child.take();
                let effects = self.recorder.child_exited(accepted);
                self.effects(effects);
            }
        }
        if self.recorder.state() == State::Starting
            && self.child.is_some()
            && self
                .started
                .is_some_and(|started| now(self.start).saturating_sub(started) >= 10_000)
            && self.error.is_empty()
        {
            self.error = if self.video_seen {
                "Audio capture did not connect to the selected device. Check the recorder audio backend and PipeWire links."
            } else {
                "No video frames arrived. Check recorder and screen capture support."
            }.into();
        }
        let effects = self.recorder.tick(now(self.start));
        self.effects(effects);
    }
}
fn main() {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("macshell-recording 1");
        return;
    }
    if !args.is_empty() {
        std::process::exit(1);
    }
    unsafe {
        libc::signal(libc::SIGTERM, shutdown as *const () as libc::sighandler_t);
        libc::signal(libc::SIGINT, shutdown as *const () as libc::sighandler_t);
        libc::signal(libc::SIGHUP, shutdown as *const () as libc::sighandler_t);
    }
    let (input_tx, input_rx) = mpsc::sync_channel(128);
    thread::spawn(move || {
        let mut input = BufReader::new(io::stdin());
        loop {
            let mut line = Vec::new();
            match (&mut input).take(1_048_577).read_until(b'\n', &mut line) {
                Ok(0) | Err(_) => {
                    let _ = input_tx.send(Input::Eof);
                    break;
                }
                Ok(_) if line.len() > 1_048_576 || !line.ends_with(b"\n") => {
                    let _ = input_tx.send(Input::Eof);
                    break;
                }
                Ok(_) => {
                    if input_tx.send(Input::Line(line)).is_err() {
                        break;
                    }
                }
            }
        }
    });
    let (log_tx, child_log) = mpsc::sync_channel(128);
    let mut service = Service {
        start: Instant::now(),
        recorder: Recorder::default(),
        peer: None,
        generation: None,
        config: json!({}),
        file: None,
        child: None,
        child_log,
        log_tx,
        log_epoch: 0,
        log: String::new(),
        #[cfg(feature = "test-diagnostics")]
        initial_log: String::new(),
        video_seen: false,
        video_progress: Arc::new(AtomicBool::new(false)),
        audio_failure: Arc::new(AtomicBool::new(false)),
        error: String::new(),
        started: None,
        countdown: 3,
        countdown_deadline: None,
        next_validate: 0,
        audio_backend: String::new(),
        audio_target: String::new(),
        routes: Vec::new(),
        audio_routes: Vec::new(),
        mix_token: String::new(),
        selector: None,
        selection_result: None,
        selection_status: None,
        selector_deadline: None,
    };
    service.emit(json!({"type":"ready"}));
    while !STOP.load(Ordering::Relaxed) {
        match input_rx.recv_timeout(Duration::from_millis(50)) {
            Ok(Input::Line(line)) => match serde_json::from_slice::<Value>(&line) {
                Ok(request) => {
                    if let Err(error) = service.command(request) {
                        service.emit(json!({"type":"error","error":error}));
                    }
                }
                Err(_) => service.emit(json!({"type":"error","error":"Invalid service request"})),
            },
            Ok(Input::Eof) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => (),
        }
        service.tick();
    }
}
