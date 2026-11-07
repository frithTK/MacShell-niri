mod state;

use serde_json::{json, Map, Value};
use std::env;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

fn clock(id: libc::clockid_t) -> io::Result<f64> {
    let mut time = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    if unsafe { libc::clock_gettime(id, &mut time) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(time.tv_sec as f64 + time.tv_nsec as f64 / 1_000_000_000.)
}

fn socket_id(metadata: &fs::Metadata) -> (u64, u64, i128) {
    (
        metadata.dev(),
        metadata.ino(),
        metadata.ctime() as i128 * 1_000_000_000 + metadata.ctime_nsec() as i128,
    )
}

fn connect_niri(path: &std::ffi::OsStr) -> io::Result<UnixStream> {
    let bytes = path.as_bytes();
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.is_empty() || bytes.len() >= address.sun_path.len() || bytes.contains(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Invalid niri socket path",
        ));
    }
    let fd = unsafe {
        libc::socket(
            libc::AF_UNIX,
            libc::SOCK_STREAM | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
            0,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let connection = unsafe { UnixStream::from_raw_fd(fd) };
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    unsafe {
        std::ptr::copy_nonoverlapping(
            bytes.as_ptr(),
            address.sun_path.as_mut_ptr().cast(),
            bytes.len(),
        );
    }
    let length =
        (std::mem::offset_of!(libc::sockaddr_un, sun_path) + bytes.len() + 1) as libc::socklen_t;
    let connected =
        unsafe { libc::connect(fd, (&address as *const libc::sockaddr_un).cast(), length) };
    if connected != 0 {
        let error = io::Error::last_os_error();
        // A full Unix-socket backlog reports EAGAIN; fail closed immediately.
        if error.raw_os_error() != Some(libc::EINPROGRESS) {
            return Err(error);
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "niri connection timed out",
                ));
            }
            let mut poll = libc::pollfd {
                fd: connection.as_raw_fd(),
                events: libc::POLLOUT,
                revents: 0,
            };
            let ready = unsafe {
                libc::poll(
                    &mut poll,
                    1,
                    remaining.as_millis().min(i32::MAX as u128) as i32,
                )
            };
            if ready < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if ready == 0 {
                continue;
            }
            let mut socket_error: libc::c_int = 0;
            let mut length = std::mem::size_of_val(&socket_error) as libc::socklen_t;
            if unsafe {
                libc::getsockopt(
                    fd,
                    libc::SOL_SOCKET,
                    libc::SO_ERROR,
                    (&mut socket_error as *mut libc::c_int).cast(),
                    &mut length,
                )
            } != 0
            {
                return Err(io::Error::last_os_error());
            }
            if socket_error != 0 {
                return Err(io::Error::from_raw_os_error(socket_error));
            }
            break;
        }
    }
    connection.set_nonblocking(false)?;
    Ok(connection)
}

fn niri_session(boot: &str) -> io::Result<String> {
    let path = env::var_os("NIRI_SOCKET")
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "No niri socket"))?;
    let before = socket_id(&fs::metadata(&path)?);
    let mut connection = connect_niri(&path)?;
    connection.set_read_timeout(Some(Duration::from_secs(3)))?;
    connection.set_write_timeout(Some(Duration::from_secs(3)))?;
    connection.write_all(b"\"Version\"\n")?;
    let mut line = Vec::new();
    BufReader::new(connection.take(1_048_577)).read_until(b'\n', &mut line)?;
    if line.len() > 1_048_576 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "niri response too large",
        ));
    }
    let response: Value = serde_json::from_slice(&line)?;
    if response.get("Err").is_some() || response.get("Ok").is_none() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "niri did not confirm the session",
        ));
    }
    let after = socket_id(&fs::metadata(&path)?);
    if before != after {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "niri socket changed",
        ));
    }
    Ok(format!("{}:{}:{}:{}", boot, after.0, after.1, after.2))
}

fn identity() -> io::Result<(String, String)> {
    let boot = fs::read_to_string("/proc/sys/kernel/random/boot_id")?
        .trim()
        .to_owned();
    let session = env::var("MACSHELL_SESSION_TOKEN")
        .ok()
        .filter(|token| !token.is_empty())
        .unwrap_or_else(|| niri_session(&boot).unwrap_or_default());
    Ok((boot, session))
}

fn emit(output: &mut impl Write, mut value: Value, generation: &Option<Value>) -> io::Result<()> {
    if let Some(generation) = generation {
        value["generation"] = generation.clone();
    }
    output.write_all(&serde_json::to_vec(&value)?)?;
    output.write_all(b"\n")?;
    output.flush()
}

struct Service {
    boot: String,
    session: String,
    values: Map<String, Value>,
    next_tick: Instant,
}

impl Service {
    fn finite(&self) -> bool {
        self.values.values().any(|value| {
            !matches!(
                value.get("mode").and_then(Value::as_str),
                Some("off" | "manual")
            )
        })
    }

    fn publish(
        &mut self,
        output: &mut impl Write,
        generation: &Option<Value>,
        mut changed: bool,
    ) -> io::Result<()> {
        let now = clock(libc::CLOCK_REALTIME)?;
        let boot_time = clock(libc::CLOCK_BOOTTIME)?;
        let mut remaining = Map::new();
        for (key, value) in &mut self.values {
            let left = state::remaining(value, now, boot_time, &self.boot);
            if left == Some(0.) && value.get("mode").and_then(Value::as_str) != Some("off") {
                *value = state::create("off", now, boot_time, &self.boot, &self.session).unwrap();
                changed = true;
            }
            remaining.insert(key.clone(), json!(left));
        }
        emit(
            output,
            json!({"type":"state", "values":self.values, "remaining":remaining,
            "changed":changed, "sessionKnown":!self.session.is_empty()}),
            generation,
        )?;
        self.next_tick = Instant::now() + Duration::from_secs(1);
        Ok(())
    }

    fn command(
        &mut self,
        request: &Value,
        output: &mut impl Write,
        generation: &Option<Value>,
    ) -> io::Result<()> {
        let now = clock(libc::CLOCK_REALTIME)?;
        let boot_time = clock(libc::CLOCK_BOOTTIME)?;
        let data = request.get("data").cloned().unwrap_or_else(|| json!({}));
        let result = match request.get("action").and_then(Value::as_str) {
            Some("restore") => {
                self.values = ["focus", "awake"]
                    .iter()
                    .map(|kind| {
                        let fallback = json!({"mode":"off"});
                        (
                            (*kind).to_owned(),
                            state::restore(
                                data.get(*kind).unwrap_or(&fallback),
                                kind,
                                now,
                                boot_time,
                                &self.boot,
                                &self.session,
                            ),
                        )
                    })
                    .collect();
                Ok(())
            }
            Some("set") => {
                let kind = data.get("kind").and_then(Value::as_str);
                let mode = data.get("mode").and_then(Value::as_str);
                match (kind, mode) {
                    (Some(kind @ ("focus" | "awake")), Some(mode)) => {
                        match state::create(mode, now, boot_time, &self.boot, &self.session) {
                            Ok(value) => {
                                self.values.insert(kind.to_owned(), value);
                                Ok(())
                            }
                            Err(error) => Err(error),
                        }
                    }
                    _ => Err("Invalid timer request"),
                }
            }
            _ => Err("Invalid timer request"),
        };
        match result {
            Ok(()) => self.publish(output, generation, true),
            Err(error) => emit(output, json!({"type":"error", "error":error}), generation),
        }
    }
}

fn run() -> io::Result<()> {
    let args: Vec<_> = env::args().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("macshell-timed-modes 1");
        return Ok(());
    }
    if !args.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unexpected argument",
        ));
    }
    let (boot, session) = identity()?;
    let mut service = Service {
        boot,
        session,
        values: Map::new(),
        next_tick: Instant::now() + Duration::from_secs(1),
    };
    let stdout = io::stdout();
    let mut output = stdout.lock();
    let mut generation = None;
    let mut buffer = Vec::new();
    emit(&mut output, json!({"type":"ready"}), &generation)?;
    loop {
        let timeout = if service.finite() {
            service
                .next_tick
                .saturating_duration_since(Instant::now())
                .as_millis()
                .min(i32::MAX as u128) as i32
        } else {
            -1
        };
        let mut fd = libc::pollfd {
            fd: libc::STDIN_FILENO,
            events: libc::POLLIN,
            revents: 0,
        };
        let ready = unsafe { libc::poll(&mut fd, 1, timeout) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if fd.revents & libc::POLLNVAL != 0 {
            break;
        }
        if fd.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
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
                    {
                        generation = request.get("generation").cloned();
                        service.command(&request, &mut output, &generation)?;
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
        if service.finite() && Instant::now() >= service.next_tick {
            service.publish(&mut output, &generation, false)?;
        }
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        if error.kind() != io::ErrorKind::BrokenPipe {
            eprintln!("macshell-timed-modes: {error}");
            std::process::exit(1);
        }
    }
}
