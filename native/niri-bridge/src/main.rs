// SPDX-License-Identifier: MIT
//! Experimental replacement for the persistent niri IPC bridge.
//! This binary is not installed or selected by MacShell by default.
mod state;

use serde_json::{json, Map, Value};
use state::{Change, State};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(3);
const OUTPUT_INTERVAL: Duration = Duration::from_secs(30);
const COALESCE: Duration = Duration::from_millis(33);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Peer {
    pid: libc::pid_t,
    uid: libc::uid_t,
    gid: libc::gid_t,
    start_ticks: u64,
}

fn peer(socket: &UnixStream) -> io::Result<Peer> {
    let mut credentials = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: both pointers refer to initialized writable objects of the given size.
    let result = unsafe {
        libc::getsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut length,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    if length as usize != std::mem::size_of::<libc::ucred>() {
        return Err(io::Error::other("Invalid niri peer credentials"));
    }
    let stat = std::fs::read_to_string(format!("/proc/{}/stat", credentials.pid))?;
    let start_ticks = stat
        .rsplit_once(") ")
        .and_then(|(_, fields)| fields.split_whitespace().nth(19))
        .and_then(|value| value.parse().ok())
        .ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "Invalid niri process identity")
        })?;
    Ok(Peer {
        pid: credentials.pid,
        uid: credentials.uid,
        gid: credentials.gid,
        start_ticks,
    })
}

fn new_session() -> io::Result<String> {
    let mut bytes = [0u8; 16];
    let mut offset = 0;
    while offset < bytes.len() {
        // SAFETY: the pointer and length describe the remaining writable bytes.
        let count = unsafe {
            libc::getrandom(bytes[offset..].as_mut_ptr().cast(), bytes.len() - offset, 0)
        };
        if count < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if count == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "No session entropy",
            ));
        }
        offset += count as usize;
    }
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

fn socket_path() -> Result<String, String> {
    std::env::var("NIRI_SOCKET").map_err(|_| "NIRI_SOCKET is not set".to_string())
}

fn request(value: &Value, expected_peer: Peer) -> Result<Value, String> {
    let socket = UnixStream::connect(socket_path()?).map_err(|e| e.to_string())?;
    request_on_socket(socket, value, expected_peer)
}

fn request_on_socket(
    mut socket: UnixStream,
    value: &Value,
    expected_peer: Peer,
) -> Result<Value, String> {
    if peer(&socket).map_err(|e| e.to_string())? != expected_peer {
        return Err("niri connection belongs to a different process".into());
    }
    socket
        .set_read_timeout(Some(REQUEST_TIMEOUT))
        .map_err(|e| e.to_string())?;
    socket
        .set_write_timeout(Some(REQUEST_TIMEOUT))
        .map_err(|e| e.to_string())?;
    serde_json::to_writer(&mut socket, value).map_err(|e| e.to_string())?;
    socket.write_all(b"\n").map_err(|e| e.to_string())?;
    let mut line = String::new();
    if BufReader::new(socket)
        .read_line(&mut line)
        .map_err(|e| e.to_string())?
        == 0
    {
        return Err("niri closed request".into());
    }
    let reply: Value = serde_json::from_str(&line).map_err(|e| e.to_string())?;
    if let Some(error) = reply.get("Err") {
        return Err(error.as_str().unwrap_or("niri request failed").into());
    }
    Ok(reply.get("Ok").cloned().unwrap_or(Value::Null))
}

fn emit(value: &Value) -> io::Result<()> {
    let stdout = io::stdout();
    let mut output = stdout.lock();
    serde_json::to_writer(&mut output, value)?;
    output.write_all(b"\n")?;
    output.flush()
}

// Poll only owned descriptors. libc does not retain the pointer after this call.
fn poll_input(stream: Option<&UnixStream>, timeout: Duration) -> io::Result<(bool, bool)> {
    let mut fds = [
        libc::pollfd {
            fd: libc::STDIN_FILENO,
            events: libc::POLLIN,
            revents: 0,
        },
        libc::pollfd {
            fd: stream.map(AsRawFd::as_raw_fd).unwrap_or(-1),
            events: libc::POLLIN,
            revents: 0,
        },
    ];
    let timeout_ms = timeout.as_millis().min(i32::MAX as u128) as i32;
    // SAFETY: fds is a valid writable array for its stated length; poll does not retain it.
    let result = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout_ms) };
    if result < 0 {
        return Err(io::Error::last_os_error());
    }
    let ready = |item: &libc::pollfd| {
        item.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0
    };
    Ok((ready(&fds[0]), ready(&fds[1])))
}

// Read the same descriptor poll watches. Rust's buffered Stdin may prefetch
// bytes that a subsequent poll on the underlying descriptor cannot see.
fn read_stdin(buffer: &mut [u8]) -> io::Result<usize> {
    // SAFETY: buffer is writable for buffer.len() bytes and remains alive for the call.
    let count = unsafe { libc::read(libc::STDIN_FILENO, buffer.as_mut_ptr().cast(), buffer.len()) };
    if count < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(count as usize)
    }
}

fn outputs(expected_peer: Peer) -> Result<Map<String, Value>, String> {
    let value = request(&json!("Outputs"), expected_peer)?;
    Ok(value
        .get("Outputs")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default())
}

fn action_line(line: &[u8], session: &str, expected_peer: Peer) {
    let result = (|| -> Result<(), String> {
        let input: Value = serde_json::from_slice(line).map_err(|e| e.to_string())?;
        if input.get("bridgeSession").and_then(Value::as_str) != Some(session) {
            return Err("stale or missing niri bridge session".into());
        }
        let request_value = input.get("request").ok_or("missing niri request")?;
        if let Some(commands) = request_value.as_array() {
            for command in commands {
                request(command, expected_peer)?;
            }
        } else {
            request(request_value, expected_peer)?;
        }
        Ok(())
    })();
    if let Err(error) = result {
        eprintln!("niri action failed: {error}");
    }
}

fn read_lines(buffer: &mut Vec<u8>, bytes: &[u8]) -> Vec<Vec<u8>> {
    buffer.extend_from_slice(bytes);
    let mut result = Vec::new();
    let mut consumed = 0;
    for (position, byte) in buffer.iter().enumerate() {
        if *byte == b'\n' {
            result.push(buffer[consumed..position].to_vec());
            consumed = position + 1;
        }
    }
    if consumed > 0 {
        buffer.drain(..consumed);
    }
    result
}

fn connected_loop(retry: &mut u64) -> Result<(), String> {
    let mut state = State::default();
    let mut stream = UnixStream::connect(socket_path()?).map_err(|e| e.to_string())?;
    let expected_peer = peer(&stream).map_err(|e| e.to_string())?;
    state.outputs = outputs(expected_peer)?;
    stream
        .write_all(b"\"EventStream\"\n")
        .map_err(|e| e.to_string())?;
    stream.set_nonblocking(true).map_err(|e| e.to_string())?;
    *retry = 1;
    let session = new_session().map_err(|e| e.to_string())?;
    let mut event_buffer = Vec::new();
    let mut input_buffer = Vec::new();
    let mut dirty = false;
    let mut titles = Map::new();
    let mut last_emit = Instant::now()
        .checked_sub(Duration::from_secs(1))
        .unwrap_or_else(Instant::now);
    let mut output_due = Instant::now() + OUTPUT_INTERVAL;
    let mut stream_bytes = vec![0u8; 262144];
    let mut input_bytes = vec![0u8; 65536];
    loop {
        let now = Instant::now();
        let timeout = if dirty || !titles.is_empty() {
            Duration::from_millis(34)
        } else {
            output_due.saturating_duration_since(now)
        };
        let (input_ready, stream_ready) = match poll_input(Some(&stream), timeout) {
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e.to_string()),
            Ok(result) => result,
        };
        if stream_ready {
            let count = match stream.read(&mut stream_bytes) {
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => 0,
                Err(e) => return Err(e.to_string()),
                Ok(0) => return Err("niri closed the event stream".into()),
                Ok(count) => count,
            };
            for line in read_lines(&mut event_buffer, &stream_bytes[..count]) {
                let event: Value = serde_json::from_slice(&line).map_err(|e| e.to_string())?;
                if event.get("Ok").is_some() {
                    continue;
                }
                if let Some(error) = event.get("Err") {
                    return Err(error.as_str().unwrap_or("niri stream error").into());
                }
                let name = event
                    .as_object()
                    .and_then(|v| v.keys().next())
                    .ok_or("invalid event")?;
                let change = state.apply(&event)?;
                if name == "WorkspacesChanged" || name == "ConfigLoaded" {
                    output_due = output_due.min(Instant::now() + Duration::from_millis(150));
                }
                match change {
                    Change::Title(id, title) => {
                        titles.insert(id, json!(title));
                    }
                    Change::Full
                        if !matches!(
                            name.as_str(),
                            "ScreenshotCaptured"
                                | "CastsChanged"
                                | "CastStartedOrChanged"
                                | "CastStopped"
                        ) =>
                    {
                        dirty = true
                    }
                    Change::Full => (),
                }
            }
        }
        if input_ready {
            let count = read_stdin(&mut input_bytes).map_err(|e| e.to_string())?;
            if count == 0 {
                return Ok(());
            }
            for line in read_lines(&mut input_buffer, &input_bytes[..count]) {
                action_line(&line, &session, expected_peer);
            }
        }
        let now = Instant::now();
        if now >= output_due {
            state.outputs = outputs(expected_peer)?;
            output_due = now + OUTPUT_INTERVAL;
            dirty = true;
        }
        if dirty && now.duration_since(last_emit) >= COALESCE {
            emit(&json!({"connected":true,"bridgeSession":session,"state":state.snapshot()}))
                .map_err(|e| e.to_string())?;
            last_emit = now;
            dirty = false;
            titles.clear();
        } else if !titles.is_empty() && now.duration_since(last_emit) >= COALESCE {
            emit(&json!({"connected":true,"bridgeSession":session,"titles":titles}))
                .map_err(|e| e.to_string())?;
            last_emit = now;
            titles.clear();
        }
    }
}

fn wait_retry(delay: Duration) -> bool {
    let deadline = Instant::now() + delay;
    let mut buffer = [0u8; 4096];
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return true;
        }
        match poll_input(None, remaining) {
            Ok((true, _)) => match read_stdin(&mut buffer) {
                Ok(0) | Err(_) => return false,
                Ok(_) => eprintln!("niri action discarded while disconnected"),
            },
            Ok(_) => return true,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => (),
            Err(_) => return false,
        }
    }
}

// Test-only protocol: replay artificial events without a real compositor.
fn replay() -> Result<(), String> {
    let mut state = State::default();
    for line in io::stdin().lock().lines() {
        let input: Value =
            serde_json::from_str(&line.map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        if let Some(outputs) = input.get("outputs").and_then(Value::as_object) {
            state.outputs = outputs.clone();
        }
        let change = if let Some(event) = input.get("event") {
            match state.apply(event)? {
                Change::Full => json!("full"),
                Change::Title(id, title) => json!({"id": id, "title": title}),
            }
        } else {
            Value::Null
        };
        emit(&json!({"change":change, "state":state.snapshot()})).map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn main() {
    match std::env::args().nth(1).as_deref() {
        Some("--protocol-version") => {
            println!("macshell-niri-bridge 1");
            return;
        }
        Some("--replay") => {
            if let Err(error) = replay() {
                eprintln!("replay failed: {error}");
                std::process::exit(1);
            }
            return;
        }
        Some(_) => {
            eprintln!("Unknown argument");
            std::process::exit(2);
        }
        None => (),
    }
    let mut retry = 1;
    loop {
        match connected_loop(&mut retry) {
            Ok(()) => return,
            Err(error) => {
                if emit(&json!({"connected":false,"error":error})).is_err() {
                    return;
                }
                if !wait_retry(Duration::from_secs(retry)) {
                    return;
                }
                retry = (retry * 2).min(30);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{new_session, peer, read_lines, request_on_socket, Peer};
    use serde_json::json;
    use std::io::Read;
    use std::os::unix::net::UnixStream;

    #[test]
    fn reassembles_partial_lines_and_keeps_tail() {
        let mut buffer = Vec::new();
        assert!(read_lines(&mut buffer, b"one").is_empty());
        assert_eq!(
            read_lines(&mut buffer, b"\ntwo\nthree"),
            vec![b"one".to_vec(), b"two".to_vec()]
        );
        assert_eq!(read_lines(&mut buffer, b"\n"), vec![b"three".to_vec()]);
        assert!(buffer.is_empty());
    }

    #[test]
    fn session_ids_are_distinct() {
        let first = new_session().unwrap();
        let second = new_session().unwrap();
        assert_eq!(first.len(), 32);
        assert_ne!(first, second);
    }

    #[test]
    fn refuses_other_peer_before_sending_action() {
        let (client, mut other) = UnixStream::pair().unwrap();
        let current = peer(&client).unwrap();
        let different = Peer {
            pid: current.pid + 1,
            ..current
        };
        assert!(request_on_socket(client, &json!({"Action":"test"}), different).is_err());
        let mut bytes = [0u8; 8];
        assert_eq!(other.read(&mut bytes).unwrap(), 0);
    }
}
