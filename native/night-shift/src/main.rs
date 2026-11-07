use serde_json::{json, Value};
use std::env;
use std::fs;
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn stop_signal(_: libc::c_int) {
    STOP.store(true, Ordering::Relaxed);
}

fn install_signals() -> io::Result<()> {
    for signal in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP] {
        let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
        action.sa_sigaction = stop_signal as *const () as usize;
        unsafe { libc::sigemptyset(&mut action.sa_mask) };
        if unsafe { libc::sigaction(signal, &action, std::ptr::null_mut()) } != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

fn executable(name: &str) -> Option<PathBuf> {
    env::split_paths(&env::var_os("PATH")?)
        .map(|directory| directory.join(name))
        .find(|path| {
            fs::metadata(path).is_ok_and(|metadata| {
                metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
            })
        })
}

fn emit(output: &mut impl Write, mut value: Value, generation: &Option<Value>) -> io::Result<()> {
    if let Some(generation) = generation {
        value["generation"] = generation.clone();
    }
    output.write_all(&serde_json::to_vec(&value)?)?;
    output.write_all(b"\n")?;
    output.flush()
}

fn gamma_submitted(log: &str) -> bool {
    log.lines().any(|line| {
        ["zwlr_gamma_control_v1#", "zwlr_gamma_control_v1@"]
            .iter()
            .any(|prefix| {
                line.split_once(prefix)
                    .is_some_and(|(_, rest)| rest.contains(".set_gamma("))
            })
    })
}

fn gamma_failed(log: &str) -> bool {
    log.lines().any(|line| {
        let line = line.to_lowercase();
        let unsupported = line
            .as_bytes()
            .windows(b"doesn't support".len())
            .any(|part| part.starts_with(b"doesn") && part.ends_with(b"t support"));
        line.contains(".failed(")
            || (line.contains("gamma control") && line.contains("failed"))
            || unsupported
            || line.contains("failed to create display")
    })
}

struct NightShift {
    child: Option<Child>,
    desired: bool,
    temperature: i64,
    applied: Option<i64>,
    restart_at: Option<Instant>,
    started_at: Option<Instant>,
    submitted_at: Option<Instant>,
    log: Vec<u8>,
    failed: bool,
    state: &'static str,
    error: String,
}

impl Default for NightShift {
    fn default() -> Self {
        Self {
            child: None,
            desired: false,
            temperature: 4000,
            applied: None,
            restart_at: None,
            started_at: None,
            submitted_at: None,
            log: Vec::new(),
            failed: false,
            state: "off",
            error: String::new(),
        }
    }
}

impl NightShift {
    fn publish(&self, output: &mut impl Write, generation: &Option<Value>) -> io::Result<()> {
        emit(
            output,
            json!({"type":"state", "available":executable("wlsunset").is_some(), "state":self.state,
            "error":self.error, "desired":self.desired, "temperature":self.temperature,
            "appliedTemperature":self.applied}),
            generation,
        )
    }

    fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            // try_wait can already have reaped the child; never signal a PID in
            // that case, because it may now belong to an unrelated process.
            let running = loop {
                match child.try_wait() {
                    Ok(Some(_)) => break false,
                    Ok(None) => break true,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(_) => break false,
                }
            };
            if running {
                unsafe { libc::kill(child.id() as libc::pid_t, libc::SIGTERM) };
                let deadline = Instant::now() + Duration::from_secs(2);
                loop {
                    match child.try_wait() {
                        Ok(Some(_)) => break,
                        Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                        Err(_) => break,
                        Ok(None) if Instant::now() >= deadline => {
                            let _ = child.kill();
                            let _ = child.wait();
                            break;
                        }
                        Ok(None) => std::thread::sleep(Duration::from_millis(10)),
                    }
                }
            }
        }
        self.started_at = None;
        self.submitted_at = None;
        self.applied = None;
    }

    fn configure(&mut self, data: &Value) -> Result<(), &'static str> {
        let temperature = match data.get("temperature") {
            None => 4000,
            Some(value) => value
                .as_i64()
                .ok_or("Invalid temperature")?
                .clamp(2500, 6000),
        };
        let desired = data
            .get("enabled")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let unchanged = self.desired && desired && self.temperature == temperature;
        self.desired = desired;
        self.temperature = temperature;
        if unchanged
            && self.child.is_some()
            && !self.failed
            && matches!(self.state, "on" | "starting")
            && self.restart_at.is_none()
        {
            return Ok(());
        }
        self.failed = false;
        self.error.clear();
        if self.desired {
            self.state = "starting";
            self.restart_at = Some(Instant::now() + Duration::from_millis(150));
        } else {
            self.restart_at = None;
            self.stop();
            self.state = "off";
        }
        Ok(())
    }

    fn start(&mut self) {
        self.stop();
        self.state = "off";
        if !self.desired {
            return;
        }
        let Some(program) = executable("wlsunset") else {
            self.error = "Install wlsunset to use Night Shift.".into();
            self.state = "unavailable";
            return;
        };
        self.log.clear();
        self.failed = false;
        self.error.clear();
        let parent = unsafe { libc::getpid() };
        let mut command = Command::new(program);
        command
            .args([
                "-T",
                &(self.temperature + 1).to_string(),
                "-t",
                &self.temperature.to_string(),
                "-S",
                "00:00",
                "-s",
                "23:59",
                "-d",
                "0",
            ])
            .env("WAYLAND_DEBUG", "client")
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        // Child must not outlive the helper even if the helper is killed abruptly.
        unsafe {
            command.pre_exec(move || {
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGINT) != 0 {
                    return Err(io::Error::last_os_error());
                }
                if libc::getppid() != parent {
                    libc::_exit(1);
                }
                Ok(())
            });
        }
        match command.spawn() {
            Ok(mut child) => {
                let fd = child.stderr.as_ref().unwrap().as_raw_fd();
                let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
                if flags < 0
                    || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
                {
                    let error = io::Error::last_os_error();
                    let _ = child.kill();
                    let _ = child.wait();
                    self.state = "error";
                    self.error = format!("Could not monitor Night Shift: {error}");
                    return;
                }
                self.child = Some(child);
                self.started_at = Some(Instant::now());
                self.state = "starting";
            }
            Err(error) => {
                self.state = "error";
                self.error = format!("Could not start Night Shift: {error}");
            }
        }
    }

    fn read_log(&mut self) {
        let mut chunk = [0u8; 32768];
        let mut closed = false;
        if let Some(stderr) = self.child.as_mut().and_then(|child| child.stderr.as_mut()) {
            for _ in 0..4 {
                match stderr.read(&mut chunk) {
                    Ok(0) => {
                        closed = true;
                        break;
                    }
                    Ok(n) => {
                        self.log.extend_from_slice(&chunk[..n]);
                        if self.log.len() > 16384 {
                            self.log.drain(..self.log.len() - 16384);
                        }
                        let text = String::from_utf8_lossy(&self.log);
                        if self.submitted_at.is_none() && gamma_submitted(&text) {
                            self.submitted_at = Some(Instant::now());
                        }
                        if gamma_failed(&text) {
                            self.failed = true;
                            self.error = "Gamma control is unavailable or another color manager owns this output.".into();
                        }
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(_) => {
                        self.failed = true;
                        break;
                    }
                }
            }
        }
        if closed {
            if let Some(child) = self.child.as_mut() {
                child.stderr.take();
            }
        }
    }

    fn tick(&mut self, output: &mut impl Write, generation: &Option<Value>) -> io::Result<()> {
        let now = Instant::now();
        if self.restart_at.is_some_and(|deadline| now >= deadline) {
            self.restart_at = None;
            self.start();
            self.publish(output, generation)?;
        }
        if self.child.is_some() && self.restart_at.is_none() {
            self.read_log();
            let exited = self
                .child
                .as_mut()
                .is_some_and(|child| child.try_wait().map_or(true, |result| result.is_some()));
            let timed_out = self.state == "starting"
                && self
                    .started_at
                    .is_some_and(|t| now.saturating_duration_since(t) > Duration::from_secs(5));
            if exited || self.failed || timed_out {
                self.stop();
                self.state = "error";
                if self.error.is_empty() {
                    self.error = "No gamma request was accepted. Check Wayland gamma support and other color managers.".into();
                }
                self.publish(output, generation)?;
            } else if self.state == "starting"
                && self
                    .submitted_at
                    .is_some_and(|t| now.saturating_duration_since(t) > Duration::from_secs(1))
            {
                self.state = "on";
                self.applied = Some(self.temperature);
                self.publish(output, generation)?;
            }
        }
        Ok(())
    }
}

impl Drop for NightShift {
    fn drop(&mut self) {
        self.stop();
    }
}

fn run() -> io::Result<()> {
    let args: Vec<_> = env::args().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("macshell-night-shift 1");
        return Ok(());
    }
    if !args.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unexpected argument",
        ));
    }
    install_signals()?;
    let mut service = NightShift::default();
    let stdout = io::stdout();
    let mut output = stdout.lock();
    let mut generation = None;
    let mut buffer = Vec::new();
    emit(&mut output, json!({"type":"ready"}), &generation)?;
    while !STOP.load(Ordering::Relaxed) {
        let timeout =
            service
                .restart_at
                .map_or(if service.child.is_some() { 200 } else { -1 }, |deadline| {
                    deadline
                        .saturating_duration_since(Instant::now())
                        .as_millis()
                        .min(i32::MAX as u128) as i32
                });
        let mut fds = [
            libc::pollfd {
                fd: libc::STDIN_FILENO,
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: if service.restart_at.is_some() {
                    -1
                } else {
                    service
                        .child
                        .as_ref()
                        .and_then(|child| child.stderr.as_ref())
                        .map_or(-1, |fd| fd.as_raw_fd())
                },
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if fds[0].revents & libc::POLLNVAL != 0 {
            break;
        }
        if fds[0].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
            let mut bytes = [0u8; 65536];
            let count =
                unsafe { libc::read(libc::STDIN_FILENO, bytes.as_mut_ptr().cast(), bytes.len()) };
            if count <= 0 {
                break;
            }
            buffer.extend_from_slice(&bytes[..count as usize]);
            if buffer.len() > 1_048_576 {
                break;
            }
            while let Some(end) = buffer.iter().position(|byte| *byte == b'\n') {
                let line: Vec<_> = buffer.drain(..=end).collect();
                let request = serde_json::from_slice::<Value>(&line);
                if let Ok(request) = request {
                    let data = request.get("data").cloned().unwrap_or_else(|| json!({}));
                    if request.is_object()
                        && data.is_object()
                        && request.get("generation").is_some()
                        && request.get("action").and_then(Value::as_str).is_some()
                    {
                        generation = request.get("generation").cloned();
                        if request["action"] == "configure" {
                            if let Err(error) = service.configure(&data) {
                                emit(
                                    &mut output,
                                    json!({"type":"error", "error":error}),
                                    &generation,
                                )?;
                                continue;
                            }
                        }
                        service.publish(&mut output, &generation)?;
                        continue;
                    }
                }
                emit(
                    &mut output,
                    json!({"type":"error", "error":"Invalid service request"}),
                    &generation,
                )?;
            }
        }
        service.tick(&mut output, &generation)?;
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        if error.kind() != io::ErrorKind::BrokenPipe {
            eprintln!("macshell-night-shift: {error}");
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_actual_gamma_submission_counts() {
        assert!(gamma_submitted(
            "[12] -> zwlr_gamma_control_v1#9.set_gamma(fd 4)"
        ));
        assert!(gamma_submitted("zwlr_gamma_control_v1@42.set_gamma(3)"));
        assert!(!gamma_submitted("setting temperature 4000"));
        assert!(!gamma_submitted(
            "zwlr_gamma_control_v1#9\nunrelated.set_gamma(3)"
        ));
    }
    #[test]
    fn detects_gamma_failures_case_insensitively() {
        assert!(gamma_failed("zwlr_gamma_control_v1#9.failed()"));
        assert!(gamma_failed("Gamma Control failed"));
        assert!(gamma_failed("server doesn't support gamma"));
        assert!(gamma_failed("Failed to create display"));
        assert!(!gamma_failed("setting temperature 4000"));
    }
}
