//! Validate a separate niri session and probe the actual Quickshell runtime.
use std::env;
use std::ffi::OsStr;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixStream;
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
fn graphical_agent_running(proc: &Path) -> bool {
    let Ok(entries) = fs::read_dir(proc) else {
        return false;
    };
    entries.flatten().any(|entry| {
        let name = entry.file_name();
        if !name.to_string_lossy().bytes().all(|b| b.is_ascii_digit()) || name.is_empty() {
            return false;
        }
        let path = entry.path();
        if !fs::metadata(&path).is_ok_and(|m| m.uid() == unsafe { libc::getuid() }) {
            return false;
        }
        let executable = fs::read_link(path.join("exe")).ok().or_else(|| {
            let bytes = fs::read(path.join("cmdline")).ok()?;
            use std::os::unix::ffi::OsStringExt;
            Some(PathBuf::from(std::ffi::OsString::from_vec(
                bytes.split(|b| *b == 0).next()?.to_vec(),
            )))
        });
        let name = executable
            .as_ref()
            .and_then(|p| p.file_name())
            .map(|s| s.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        name != "pkttyagent"
            && name.contains("polkit")
            && (name.contains("agent") || name.contains("auth"))
    })
}

fn executable(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

fn ensure_polkit_agent() -> io::Result<()> {
    if graphical_agent_running(Path::new("/proc")) {
        return Ok(());
    }
    let candidates = [
        "/usr/lib/polkit-kde-authentication-agent-1",
        "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1",
        "/usr/libexec/polkit-gnome-authentication-agent-1",
        "lxqt-policykit-agent",
        "hyprpolkitagent",
        "polkit-mate-authentication-agent-1",
    ];
    let paths = env::var_os("PATH").unwrap_or_default();
    let agent = candidates.iter().find_map(|name| {
        let path = Path::new(name);
        if path.is_absolute() {
            return executable(path).then(|| path.to_path_buf());
        }
        env::split_paths(&paths)
            .map(|p| p.join(path))
            .find(|p| executable(p))
    });
    let Some(agent) = agent else {
        eprintln!("MacShell: no graphical PolicyKit agent is available.");
        return Ok(());
    };
    let output = run(
        Command::new("systemd-run")
            .args([
                "--user",
                "--unit=macshell-polkit-agent",
                "--collect",
                "--service-type=exec",
                "--property=Restart=on-failure",
                "--property=RestartSec=2",
                "--property=PartOf=niri-macshell.service",
            ])
            .arg(agent),
        Duration::from_secs(10),
    )?;
    if !output.status.success() {
        eprintln!("MacShell: no graphical PolicyKit agent is available.");
    }
    Ok(())
}

fn wait_ready(launcher: &OsStr, timeout: Duration) -> io::Result<()> {
    let deadline = Instant::now() + timeout;
    let mut last = String::from("No status received");
    while Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match run(
            Command::new(launcher).args(["ipc", "call", "status", "state"]),
            remaining.min(Duration::from_secs(2)),
        ) {
            Ok(output) => {
                if output.status.success()
                    && serde_json::from_slice::<serde_json::Value>(&output.stdout)
                        .ok()
                        .and_then(|v| v.get("connected").and_then(|v| v.as_bool()))
                        == Some(true)
                {
                    return Ok(());
                }
                last = String::from_utf8_lossy(if output.stderr.is_empty() {
                    &output.stdout
                } else {
                    &output.stderr
                })
                .into_owned();
            }
            Err(error) => last = error.to_string(),
        }
        std::thread::sleep(
            Duration::from_millis(200).min(deadline.saturating_duration_since(Instant::now())),
        );
    }
    let tail: String = last
        .chars()
        .rev()
        .take(1500)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    Err(io::Error::other(format!(
        "MacShell did not connect within the startup deadline: {tail}"
    )))
}

fn checked_output(command: &mut Command, timeout: Duration) -> io::Result<String> {
    let output = run(command, timeout)?;
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "command failed: {}",
            String::from_utf8_lossy(&output.stderr)
        )));
    }
    String::from_utf8(output.stdout)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid command output"))
}

fn check_no_instance(qs: &OsStr) -> io::Result<()> {
    let output = checked_output(
        Command::new(qs).args(["-c", "MacShell-niri", "list", "--any-display", "--json"]),
        Duration::from_secs(5),
    )?;
    if output.starts_with("No running instances for \"")
        && output
            .trim_end()
            .ends_with("Use --all to list all instances.")
    {
        return Ok(());
    }
    let instances: serde_json::Value = serde_json::from_str(&output)
        .map_err(|_| io::Error::other("Unexpected Quickshell instance list"))?;
    let list = instances
        .as_array()
        .ok_or_else(|| io::Error::other("Unexpected Quickshell instance list"))?;
    if !list.is_empty() {
        return Err(io::Error::other(
            "MacShell is already running; refusing to start a second instance",
        ));
    }
    Ok(())
}

fn start_managed_shell() -> io::Result<()> {
    let required = ["WAYLAND_DISPLAY", "NIRI_SOCKET", "MACSHELL_SESSION_TOKEN"];
    let values: Vec<_> = required
        .iter()
        .map(|name| env::var_os(name).filter(|v| !v.is_empty()))
        .collect();
    if values.iter().any(Option::is_none) {
        return Err(io::Error::other("Missing compositor session environment"));
    }
    let status = checked_output(
        Command::new("systemctl").args([
            "--user",
            "show",
            "niri-macshell.service",
            "--property=ActiveState",
            "--value",
        ]),
        Duration::from_secs(5),
    )?;
    if !["active", "activating"].contains(&status.trim()) {
        return Err(io::Error::other(
            "The MacShell compositor session is not running",
        ));
    }
    let pid = checked_output(
        Command::new("systemctl").args([
            "--user",
            "show",
            "niri-macshell.service",
            "--property=MainPID",
            "--value",
        ]),
        Duration::from_secs(5),
    )?
    .trim()
    .parse::<libc::pid_t>()
    .map_err(|_| io::Error::other("The MacShell compositor has no process"))?;
    if pid <= 0 {
        return Err(io::Error::other("The MacShell compositor has no process"));
    }
    use std::os::unix::ffi::OsStrExt;
    let mut token = b"MACSHELL_SESSION_TOKEN=".to_vec();
    token.extend_from_slice(values[2].as_ref().unwrap().as_bytes());
    let environ = fs::read(format!("/proc/{pid}/environ"))?;
    if !environ.split(|b| *b == 0).any(|value| value == token) {
        return Err(io::Error::other(
            "The compositor belongs to another session",
        ));
    }
    let stream = UnixStream::connect(values[1].as_ref().unwrap())?;
    let mut peer: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    if unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut peer as *mut libc::ucred).cast(),
            &mut len,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    if len as usize != std::mem::size_of::<libc::ucred>()
        || peer.pid != pid
        || peer.uid != unsafe { libc::getuid() }
    {
        return Err(io::Error::other(
            "The niri socket belongs to another compositor",
        ));
    }
    let mut import = Command::new("systemctl");
    import.args(["--user", "import-environment"]);
    for name in [
        "WAYLAND_DISPLAY",
        "NIRI_SOCKET",
        "MACSHELL_SESSION_TOKEN",
        "XDG_CURRENT_DESKTOP",
        "XDG_SESSION_TYPE",
    ] {
        if env::var_os(name).is_some_and(|v| !v.is_empty()) {
            import.arg(name);
        }
    }
    checked_output(&mut import, Duration::from_secs(5))?;
    checked_output(
        Command::new("systemctl").args(["--user", "start", "macshell-niri-shell.service"]),
        Duration::from_secs(15),
    )?;
    Ok(())
}

fn main() {
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("macshell-session-preflight 1");
        return;
    }
    if args == ["--ready-protocol-version"] {
        println!("macshell-session-ready 1");
        return;
    }
    if args == ["--supervisor-protocol-version"] {
        println!("macshell-shell-supervisor 1");
        return;
    }
    let outcome = if args == ["--supervisor-start"] {
        start_managed_shell()
    } else if args.len() == 2 && args[0] == "--supervisor-check" {
        check_no_instance(&args[1])
    } else if args.len() == 2 && args[0] == "--ready" {
        wait_ready(&args[1], Duration::from_secs(15)).map(|_| {
            if let Err(error) = ensure_polkit_agent() {
                eprintln!("MacShell: could not start the PolicyKit agent: {error}");
            }
        })
    } else if args.len() == 2 && args[0] == "--runtime" {
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
    fn readiness_requires_connected_json_and_retries() {
        let scratch = Scratch::new().unwrap();
        let launcher = scratch.0.join("launcher");
        let counter = scratch.0.join("counter");
        fs::write(&launcher, format!("#!/bin/sh\nif [ ! -e '{}' ]; then touch '{}'; printf '{{\"connected\":false}}'; else printf '{{\"connected\":true}}'; fi\n", counter.display(), counter.display())).unwrap();
        fs::set_permissions(&launcher, fs::Permissions::from_mode(0o755)).unwrap();
        wait_ready(launcher.as_os_str(), Duration::from_secs(3)).unwrap();
        fs::write(&launcher, "#!/bin/sh\nprintf '{\"connected\":1}'\n").unwrap();
        assert!(wait_ready(launcher.as_os_str(), Duration::from_millis(250)).is_err());
    }
    #[test]
    fn graphical_agent_ignores_terminal_and_checks_cmdline() {
        use std::os::unix::fs::symlink;
        let scratch = Scratch::new().unwrap();
        let proc = scratch.0.join("42");
        fs::create_dir(&proc).unwrap();
        symlink("/usr/bin/pkttyagent", proc.join("exe")).unwrap();
        assert!(!graphical_agent_running(&scratch.0));
        fs::remove_file(proc.join("exe")).unwrap();
        fs::write(
            proc.join("cmdline"),
            b"/usr/lib/polkit-kde-authentication-agent-1\0",
        )
        .unwrap();
        assert!(graphical_agent_running(&scratch.0));
    }
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
