//! Validate a separate niri session and probe the actual Quickshell runtime.
use std::env;
use std::ffi::OsStr;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

const TIMEOUT: Duration = Duration::from_secs(10);
const LOG_LIMIT: usize = 1_048_576;
const PROBE:&str="import QtQuick\nimport Quickshell\nShellRoot { Timer { interval: 100; running: true; onTriggered: Qt.quit() } }\n";
fn random_hex() -> io::Result<String> {
    let mut bytes = [0u8; 16];
    let mut offset = 0;
    while offset < bytes.len() {
        let n = unsafe {
            libc::getrandom(bytes[offset..].as_mut_ptr().cast(), bytes.len() - offset, 0)
        };
        if n < 0 {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(e);
        }
        if n == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "random source closed",
            ));
        }
        offset += n as usize;
    }
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
struct Scratch(PathBuf);
impl Scratch {
    fn new() -> io::Result<Self> {
        let mut candidates: Vec<PathBuf> = ["TMPDIR", "TEMP", "TMP"]
            .iter()
            .filter_map(env::var_os)
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .collect();
        candidates.extend([
            PathBuf::from("/tmp"),
            PathBuf::from("/var/tmp"),
            PathBuf::from("/usr/tmp"),
        ]);
        let cwd = env::current_dir().ok();
        if let Some(path) = &cwd {
            candidates.push(path.clone());
        }
        let mut last_error = None;
        for parent in candidates {
            let parent = if parent.is_absolute() {
                parent
            } else if let Some(cwd) = &cwd {
                cwd.join(parent)
            } else {
                continue;
            };
            let root = parent.join(format!("macshell-session-check-{}", random_hex()?));
            match fs::DirBuilder::new().mode(0o700).create(&root) {
                Ok(()) => return Ok(Self(root)),
                Err(error) => last_error = Some(error),
            }
        }
        Err(last_error.unwrap_or_else(|| io::Error::other("no temporary directory")))
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
struct Output {
    status: ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}
fn nonblocking(fd: i32) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
fn drain(reader: &mut impl Read, buffer: &mut Vec<u8>) -> io::Result<bool> {
    let mut chunk = [0u8; 8192];
    loop {
        match reader.read(&mut chunk) {
            Ok(0) => return Ok(true),
            Ok(n) => {
                if buffer.len() + n > LOG_LIMIT {
                    return Err(io::Error::other("preflight output is too large"));
                }
                buffer.extend_from_slice(&chunk[..n]);
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(false),
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
}
fn stop(child: &mut Child) {
    // This child owns its process group; never signal other user processes.
    unsafe {
        libc::kill(-(child.id() as i32), libc::SIGKILL);
    }
    let _ = child.kill();
    let _ = child.wait();
}
fn has_exited(child: &Child) -> io::Result<bool> {
    // Keep the child unreaped while descendants can still hold our pipes.
    // Its PID then cannot be reused before a timeout signals its process group.
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    loop {
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                child.id(),
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };
        if result == 0 {
            return Ok(unsafe { info.si_pid() } != 0);
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}
fn run(command: &mut Command, timeout: Duration) -> io::Result<Output> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);
    unsafe {
        command.pre_exec(|| {
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) != 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::getppid() == 1 {
                return Err(io::Error::other("parent already exited"));
            }
            Ok(())
        });
    }
    let mut child = command.spawn()?;
    let mut stdout = child.stdout.take().unwrap();
    let mut stderr = child.stderr.take().unwrap();
    if let Err(e) = nonblocking(stdout.as_raw_fd()).and_then(|_| nonblocking(stderr.as_raw_fd())) {
        stop(&mut child);
        return Err(e);
    }
    let mut out = Vec::new();
    let mut err = Vec::new();
    let mut exited = false;
    let mut out_closed = false;
    let mut err_closed = false;
    let deadline = Instant::now() + timeout;
    loop {
        if !out_closed {
            match drain(&mut stdout, &mut out) {
                Ok(closed) => out_closed = closed,
                Err(e) => {
                    stop(&mut child);
                    return Err(e);
                }
            }
        }
        if !err_closed {
            match drain(&mut stderr, &mut err) {
                Ok(closed) => err_closed = closed,
                Err(e) => {
                    stop(&mut child);
                    return Err(e);
                }
            }
        }
        if !exited {
            match has_exited(&child) {
                Ok(value) => exited = value,
                Err(e) => {
                    stop(&mut child);
                    return Err(e);
                }
            }
        }
        if exited && out_closed && err_closed {
            break;
        }
        if Instant::now() >= deadline {
            stop(&mut child);
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "preflight timed out",
            ));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    Ok(Output {
        status: child.wait()?,
        stdout: out,
        stderr: err,
    })
}
fn validate(config: &Path) -> io::Result<()> {
    let mut command = Command::new("niri");
    command.args(["validate", "-c"]).arg(config);
    let output = run(&mut command, TIMEOUT)?;
    let _ = std::str::from_utf8(&output.stdout)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid niri output"))?;
    let stderr = std::str::from_utf8(&output.stderr)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid niri output"))?;
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "niri configuration validation failed:\n{}",
            stderr
        )));
    }
    Ok(())
}
fn check_runtime(binary: &OsStr) -> io::Result<()> {
    let scratch = Scratch::new()?;
    let runtime = scratch.0.join("runtime");
    fs::DirBuilder::new().mode(0o700).create(&runtime)?;
    let probe = scratch.0.join("shell.qml");
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&probe)?;
    file.write_all(PROBE.as_bytes())?;
    drop(file);
    let mut command = Command::new(binary);
    command
        .arg("-p")
        .arg(&probe)
        .env("QT_QPA_PLATFORM", "offscreen")
        .env("QT_QPA_PLATFORMTHEME", "")
        .env("QT_QUICK_CONTROLS_STYLE", "Basic")
        .env("XDG_RUNTIME_DIR", &runtime)
        .env("XDG_CACHE_HOME", &scratch.0)
        .env(
            "DBUS_SESSION_BUS_ADDRESS",
            format!("unix:path={}/no-bus", scratch.0.display()),
        )
        .env_remove("DISPLAY")
        .env_remove("WAYLAND_DISPLAY");
    let output = run(&mut command, TIMEOUT)?;
    let stdout = std::str::from_utf8(&output.stdout)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid Quickshell output"))?;
    let stderr = std::str::from_utf8(&output.stderr)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid Quickshell output"))?;
    let log = format!("{stdout}{stderr}");
    if !output.status.success()
        || log.contains("without rebuilding")
        || log.contains("Failed to load configuration")
    {
        return Err(io::Error::other(format!(
            "Quickshell runtime check failed:\n{log}"
        )));
    }
    Ok(())
}
fn main() {
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("macshell-session-preflight 1");
        return;
    }
    let outcome = if args.len() == 2 && args[0] == "--runtime" {
        check_runtime(&args[1])
    } else if args.len() == 2 {
        validate(Path::new(&args[0]))
            .and_then(|_| check_runtime(&args[1]))
            .map(|_| println!("MacShell session configuration and Quickshell runtime are ready."))
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Usage: macshell-session-preflight CONFIG QS_BINARY",
        ))
    };
    if let Err(error) = outcome {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn timeout_cleans_a_child_holding_pipes_after_parent_exit() {
        let scratch = Scratch::new().unwrap();
        let pidfile = scratch.0.join("pid");
        let mut command = Command::new("/bin/sh");
        command
            .args(["-c", "sleep 30 & printf '%s' $! > \"$1\"", "sh"])
            .arg(&pidfile);
        let result = run(&mut command, Duration::from_millis(500));
        assert_eq!(result.err().unwrap().kind(), io::ErrorKind::TimedOut);
        let pid: libc::pid_t = fs::read_to_string(pidfile).unwrap().parse().unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let state = fs::read_to_string(format!("/proc/{pid}/stat"))
                .ok()
                .and_then(|s| {
                    s.rsplit_once(") ")
                        .and_then(|(_, tail)| tail.chars().next())
                });
            if state.is_none() || state == Some('Z') {
                break;
            }
            assert!(Instant::now() < deadline, "owned child remained running");
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}
