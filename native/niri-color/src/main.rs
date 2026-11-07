//! Explicit user-initiated niri color picker; the desktop is never queried at startup.
use serde_json::Value;
use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::process::CommandExt;
use std::process::{Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

const LIMIT: usize = 65_536;
fn nonblocking(fd: i32) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}
fn drain(reader: &mut impl Read, buffer: &mut Vec<u8>) -> io::Result<bool> {
    let mut bytes = [0u8; 4096];
    loop {
        match reader.read(&mut bytes) {
            Ok(0) => return Ok(true),
            Ok(n) => {
                if buffer.len() + n > LIMIT {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Color picker response is too large.",
                    ));
                }
                buffer.extend_from_slice(&bytes[..n]);
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(false),
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
}
fn picker() -> io::Result<(ExitStatus, Vec<u8>, Vec<u8>)> {
    let mut command = Command::new("niri");
    command
        .args(["msg", "-j", "pick-color"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    // If the helper is terminated, stop only the niri client that it started.
    unsafe {
        command.pre_exec(|| {
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) != 0 {
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
        let _ = child.kill();
        let _ = child.wait();
        return Err(e);
    }
    let mut out = Vec::new();
    let mut err = Vec::new();
    let mut out_done = false;
    let mut err_done = false;
    let mut status = None;
    let mut finish_deadline = None;
    loop {
        let result = (|| -> io::Result<()> {
            if !out_done {
                out_done = drain(&mut stdout, &mut out)?;
            }
            if !err_done {
                err_done = drain(&mut stderr, &mut err)?;
            }
            if status.is_none() {
                status = child.try_wait()?;
                if status.is_some() {
                    finish_deadline = Some(Instant::now() + Duration::from_secs(2));
                }
            }
            Ok(())
        })();
        if let Err(error) = result {
            if status.is_none() {
                let _ = child.kill();
                let _ = child.wait();
            }
            return Err(error);
        }
        if status.is_some() && out_done && err_done {
            return Ok((status.unwrap(), out, err));
        }
        if finish_deadline.is_some_and(|end| Instant::now() >= end) {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "Color picker output did not close.",
            ));
        }
        let mut fds = [
            libc::pollfd {
                fd: if out_done { -1 } else { stdout.as_raw_fd() },
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: if err_done { -1 } else { stderr.as_raw_fd() },
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        let n = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, 500) };
        if n < 0 {
            let e = io::Error::last_os_error();
            if e.kind() != io::ErrorKind::Interrupted {
                if status.is_none() {
                    let _ = child.kill();
                    let _ = child.wait();
                }
                return Err(e);
            }
        }
    }
}
fn color(value: &Value) -> Result<Option<String>, String> {
    let truthy = |value: &Value| match value {
        Value::Null => false,
        Value::Bool(v) => *v,
        Value::Number(v) => v.as_f64().is_some_and(|v| v != 0.0),
        Value::String(v) => !v.is_empty(),
        Value::Array(v) => !v.is_empty(),
        Value::Object(v) => !v.is_empty(),
    };
    if !truthy(value) {
        return Ok(None);
    }
    let obj = value.as_object().ok_or("Invalid color response.")?;
    let selected = obj
        .get("rgb")
        .filter(|value| truthy(value))
        .or_else(|| obj.get("color").filter(|value| truthy(value)));
    let mut channels = Vec::new();
    let zero = Value::from(0);
    match selected {
        Some(Value::Object(values)) if !values.is_empty() => {
            for key in ["r", "g", "b"] {
                channels.push(values.get(key).unwrap_or(&zero));
            }
        }
        Some(Value::Array(values)) if !values.is_empty() => {
            if values.len() < 3 {
                return Err("Invalid color response.".into());
            }
            channels.extend(values.iter().take(3));
        }
        None | Some(Value::Array(_)) | Some(Value::Object(_)) => {
            for key in ["r", "g", "b"] {
                channels.push(obj.get(key).unwrap_or(&Value::Null));
            }
        }
        _ => return Err("Invalid color response.".into()),
    }
    let mut hex = String::from("#");
    for value in channels {
        let value = value
            .as_f64()
            .filter(|n| n.is_finite())
            .ok_or("Invalid color response.")?;
        let scaled = value * 255.0;
        if !scaled.is_finite() {
            return Err("Invalid color response.".into());
        }
        let channel = scaled.round_ties_even().clamp(0.0, 255.0) as u8;
        hex.push_str(&format!("{channel:02X}"));
    }
    Ok(Some(hex))
}
fn run() -> Result<(), String> {
    let (status, out, _err) = picker().map_err(|e| e.to_string())?;
    if !status.success() {
        return Err("Color picker could not be opened.".into());
    }
    let parsed: Value =
        serde_json::from_slice(&out).map_err(|_| "Invalid color response.".to_owned())?;
    let Some(value) = color(&parsed)? else {
        return Ok(());
    };
    let copied = Command::new("wl-copy")
        .arg(&value)
        .status()
        .map_err(|e| e.to_string())?;
    if !copied.success() {
        return Err("Could not copy the selected color.".into());
    }
    let _ = Command::new("notify-send")
        .args(["Color copied", &value])
        .status();
    Ok(())
}
fn main() {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("macshell-niri-color 1");
        return;
    }
    if !args.is_empty() {
        eprintln!("macshell-niri-color: unexpected argument");
        std::process::exit(1);
    }
    if let Err(error) = run() {
        eprintln!("{error}");
        let _ = Command::new("notify-send")
            .args(["MacShell", &error])
            .status();
        std::process::exit(1);
    }
}
