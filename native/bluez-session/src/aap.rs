//! AACP battery client over L2CAP PSM 0x1001.
//!
//! Handshake constants match published PacketLogger captures (host handshake,
//! SET_FEATURES 0x4D with 0xD7, REQUEST_NOTIFICATIONS 0x0F). Battery frames
//! are decoded by `macshell_bluez_snapshot::apple::parse_aap`.
use macshell_bluez_snapshot::apple::{self, AppleBattery};
use std::collections::{HashMap, HashSet};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

const AF_BLUETOOTH: i32 = 31;
const BTPROTO_L2CAP: i32 = 0;
const SOL_BLUETOOTH: i32 = 274;
const BT_SECURITY: i32 = 4;
const BT_SECURITY_MEDIUM: u8 = 2;
const PSM: u16 = 0x1001;
const HANDSHAKE: [u8; 16] = [
    0x00, 0x00, 0x04, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];
const SET_FEATURES: [u8; 14] = [
    0x04, 0x00, 0x04, 0x00, 0x4D, 0x00, 0xD7, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];
const REQUEST_NOTIFICATIONS: [u8; 10] =
    [0x04, 0x00, 0x04, 0x00, 0x0F, 0x00, 0xFF, 0xFF, 0xFF, 0xFF];
const REQUEST_BATTERY: [u8; 7] = [0x04, 0x00, 0x04, 0x00, 0x05, 0x00, 0x01];

#[repr(C, packed)]
struct SockaddrL2 {
    l2_family: u16,
    l2_psm: u16,
    l2_bdaddr: [u8; 6],
    l2_cid: u16,
    l2_bdaddr_type: u8,
}

pub struct Hub {
    cmd: Sender<Vec<String>>,
    events: Receiver<(String, AppleBattery)>,
    _thread: JoinHandle<()>,
}

impl Hub {
    pub fn start() -> Self {
        let (cmd_tx, cmd_rx) = mpsc::channel();
        let (evt_tx, evt_rx) = mpsc::channel();
        let thread = thread::Builder::new()
            .name("macshell-aap".into())
            .spawn(move || run(cmd_rx, evt_tx))
            .expect("AACP worker");
        Self {
            cmd: cmd_tx,
            events: evt_rx,
            _thread: thread,
        }
    }

    pub fn set_targets(&self, addresses: Vec<String>) {
        let _ = self.cmd.send(addresses);
    }

    pub fn drain(&self) -> Vec<(String, AppleBattery)> {
        self.events.try_iter().collect()
    }
}

fn run(commands: Receiver<Vec<String>>, events: Sender<(String, AppleBattery)>) {
    let mut workers: HashMap<String, Arc<AtomicBool>> = HashMap::new();
    loop {
        match commands.recv_timeout(Duration::from_millis(200)) {
            Ok(targets) => apply_targets(&mut workers, targets, &events),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                for stop in workers.values() {
                    stop.store(true, Ordering::Relaxed);
                }
                return;
            }
        }
    }
}

fn apply_targets(
    workers: &mut HashMap<String, Arc<AtomicBool>>,
    targets: Vec<String>,
    events: &Sender<(String, AppleBattery)>,
) {
    let wanted: HashSet<String> = targets.into_iter().collect();
    workers.retain(|address, stop| {
        if wanted.contains(address) {
            true
        } else {
            stop.store(true, Ordering::Relaxed);
            false
        }
    });
    for address in wanted {
        if workers.contains_key(&address) {
            continue;
        }
        let stop = Arc::new(AtomicBool::new(false));
        let events = events.clone();
        let flag = Arc::clone(&stop);
        let name = address.clone();
        if thread::Builder::new()
            .name(format!("aap-{address}"))
            .spawn(move || worker(name, flag, events))
            .is_ok()
        {
            workers.insert(address, stop);
        }
    }
}

fn worker(address: String, stop: Arc<AtomicBool>, events: Sender<(String, AppleBattery)>) {
    while !stop.load(Ordering::Relaxed) {
        match session(&address, &stop, &events) {
            Ok(()) => (),
            Err(_) => {
                for _ in 0..15 {
                    if stop.load(Ordering::Relaxed) {
                        return;
                    }
                    thread::sleep(Duration::from_millis(200));
                }
            }
        }
    }
}

fn session(
    address: &str,
    stop: &AtomicBool,
    events: &Sender<(String, AppleBattery)>,
) -> io::Result<()> {
    let socket = connect(address)?;
    write_all(&socket, &HANDSHAKE)?;
    drain(&socket, stop, address, events)?;
    write_all(&socket, &SET_FEATURES)?;
    drain(&socket, stop, address, events)?;
    write_all(&socket, &REQUEST_NOTIFICATIONS)?;
    drain(&socket, stop, address, events)?;
    write_all(&socket, &REQUEST_BATTERY)?;
    let mut buf = [0u8; 2048];
    let mut idle = 0u32;
    while !stop.load(Ordering::Relaxed) {
        match recv_timeout(&socket, &mut buf, 400) {
            Ok(0) => return Err(io::Error::from(io::ErrorKind::ConnectionAborted)),
            Ok(n) => {
                idle = 0;
                if let Some(parsed) = apple::parse_aap(&buf[..n]) {
                    if events.send((address.to_owned(), parsed)).is_err() {
                        return Ok(());
                    }
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => continue,
            Err(error) if error.kind() == io::ErrorKind::TimedOut => {
                idle = idle.saturating_add(1);
                if idle % 25 == 0 {
                    let _ = write_all(&socket, &REQUEST_BATTERY);
                }
            }
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn drain(
    socket: &OwnedFd,
    stop: &AtomicBool,
    address: &str,
    events: &Sender<(String, AppleBattery)>,
) -> io::Result<()> {
    let mut buf = [0u8; 2048];
    for _ in 0..8 {
        if stop.load(Ordering::Relaxed) {
            return Ok(());
        }
        match recv_timeout(socket, &mut buf, 80) {
            Ok(0) => return Err(io::Error::from(io::ErrorKind::ConnectionAborted)),
            Ok(n) => {
                if let Some(parsed) = apple::parse_aap(&buf[..n]) {
                    if events.send((address.to_owned(), parsed)).is_err() {
                        return Ok(());
                    }
                }
            }
            Err(error)
                if error.kind() == io::ErrorKind::WouldBlock
                    || error.kind() == io::ErrorKind::TimedOut =>
            {
                return Ok(());
            }
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn connect(address: &str) -> io::Result<OwnedFd> {
    let bdaddr =
        parse_address(address).ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
    unsafe {
        let fd = libc::socket(AF_BLUETOOTH, libc::SOCK_SEQPACKET, BTPROTO_L2CAP);
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let socket = OwnedFd::from_raw_fd(fd);
        let security = [BT_SECURITY_MEDIUM, 0u8];
        libc::setsockopt(
            socket.as_raw_fd(),
            SOL_BLUETOOTH,
            BT_SECURITY,
            security.as_ptr().cast(),
            2,
        );
        let addr = SockaddrL2 {
            l2_family: AF_BLUETOOTH as u16,
            l2_psm: PSM.to_le(),
            l2_bdaddr: bdaddr,
            l2_cid: 0,
            l2_bdaddr_type: 0,
        };
        let rc = libc::connect(
            socket.as_raw_fd(),
            std::ptr::addr_of!(addr).cast(),
            std::mem::size_of::<SockaddrL2>() as u32,
        );
        if rc != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(socket)
    }
}

fn parse_address(address: &str) -> Option<[u8; 6]> {
    let mut parts = address.split(':');
    let mut bytes = [0u8; 6];
    for slot in bytes.iter_mut().rev() {
        *slot = u8::from_str_radix(parts.next()?, 16).ok()?;
    }
    parts.next().is_none().then_some(bytes)
}

fn write_all(socket: &OwnedFd, bytes: &[u8]) -> io::Result<()> {
    unsafe {
        let sent = libc::send(socket.as_raw_fd(), bytes.as_ptr().cast(), bytes.len(), 0);
        if sent == bytes.len() as isize {
            Ok(())
        } else if sent < 0 {
            Err(io::Error::last_os_error())
        } else {
            Err(io::Error::from(io::ErrorKind::WriteZero))
        }
    }
}

fn recv_timeout(socket: &OwnedFd, buf: &mut [u8], timeout_ms: i32) -> io::Result<usize> {
    unsafe {
        let mut poll = libc::pollfd {
            fd: socket.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let ready = libc::poll(&mut poll, 1, timeout_ms);
        if ready < 0 {
            return Err(io::Error::last_os_error());
        }
        if ready == 0 {
            return Err(io::Error::from(io::ErrorKind::TimedOut));
        }
        if poll.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0
            && poll.revents & libc::POLLIN == 0
        {
            return Ok(0);
        }
        let n = libc::recv(socket.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len(), 0);
        if n < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(n as usize)
        }
    }
}
