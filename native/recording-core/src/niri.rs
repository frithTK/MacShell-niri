//! Bounded request/response access to a pinned niri IPC peer.
use serde_json::{json, Value};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Peer {
    pid: libc::pid_t,
    uid: libc::uid_t,
    gid: libc::gid_t,
    start_ticks: u64,
}

fn peer(socket: &UnixStream) -> io::Result<Peer> {
    let mut credential = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut size = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credential as *mut libc::ucred).cast(),
            &mut size,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    if size as usize != std::mem::size_of::<libc::ucred>()
        || credential.uid != unsafe { libc::getuid() }
        || credential.pid <= 0
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Invalid niri peer",
        ));
    }
    let stat = std::fs::read_to_string(format!("/proc/{}/stat", credential.pid))?;
    let start_ticks = stat
        .rsplit_once(") ")
        .and_then(|(_, fields)| fields.split_whitespace().nth(19))
        .and_then(|v| v.parse().ok())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "Invalid niri peer identity"))?;
    Ok(Peer {
        pid: credential.pid,
        uid: credential.uid,
        gid: credential.gid,
        start_ticks,
    })
}

/// Pin the process identity on first use, and fail if a later connection
/// points to a different process. Calls belong on a bounded worker, not UI.
pub fn outputs(path: &Path, expected: &mut Option<Peer>) -> io::Result<Vec<Value>> {
    let mut socket = UnixStream::connect(path)?;
    socket.set_read_timeout(Some(Duration::from_secs(3)))?;
    socket.set_write_timeout(Some(Duration::from_secs(3)))?;
    let actual = peer(&socket)?;
    if expected.is_some_and(|previous| previous != actual) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "niri peer changed",
        ));
    }
    *expected = Some(actual);
    serde_json::to_writer(&mut socket, &json!("Outputs"))?;
    socket.write_all(b"\n")?;
    let mut line = Vec::new();
    BufReader::new(socket)
        .take(1_048_577)
        .read_until(b'\n', &mut line)?;
    if line.is_empty() || line.len() > 1_048_576 || !line.ends_with(b"\n") {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Invalid niri response",
        ));
    }
    let reply: Value = serde_json::from_slice(&line)?;
    let value = reply
        .get("Ok")
        .ok_or_else(|| io::Error::other("niri request failed"))?;
    crate::outputs::parse(value).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::thread;
    static SERIAL: AtomicU64 = AtomicU64::new(0);
    #[test]
    fn reads_bounded_fresh_output_from_pinned_test_peer() {
        let path = std::env::temp_dir().join(format!(
            "macshell-niri-test-{}-{}",
            std::process::id(),
            SERIAL.fetch_add(1, Ordering::Relaxed)
        ));
        let listener = UnixListener::bind(&path).unwrap();
        let worker = thread::spawn(move || {
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut line = String::new();
                BufReader::new(stream.try_clone().unwrap())
                    .read_line(&mut line)
                    .unwrap();
                assert_eq!(line.trim(), "\"Outputs\"");
                stream.write_all(b"{\"Ok\":{\"Outputs\":{\"test\":{\"logical\":{\"x\":-10,\"y\":0,\"width\":100,\"height\":100},\"current_mode\":0,\"modes\":[{}]}}}}\n").unwrap();
            }
        });
        let mut expected = None;
        for _ in 0..2 {
            let result = outputs(&path, &mut expected).unwrap();
            assert_eq!(result[0]["logical"]["x"], -10);
        }
        worker.join().unwrap();
        std::fs::remove_file(path).unwrap();
    }
}
