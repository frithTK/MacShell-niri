use crate::connect::connect_niri;
use std::env;
use std::fs;
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::MetadataExt;
use std::path::PathBuf;

const NEED_PROFILE: &str = "Native blur needs the active MacShell niri profile.";
#[derive(Debug)]
pub enum Error {
    Message(String),
    Io,
}
impl From<io::Error> for Error {
    fn from(_: io::Error) -> Self {
        Self::Io
    }
}
fn message(text: &str) -> Error {
    Error::Message(text.into())
}
#[derive(Debug, PartialEq, Eq)]
pub struct Identity {
    uid: u32,
    pid: i32,
    start: u64,
    device: u64,
    inode: u64,
    changed: i128,
    config: PathBuf,
}
impl Identity {
    pub fn config(&self) -> &std::path::Path {
        &self.config
    }
}
pub fn active_profile() -> Result<Identity, Error> {
    let profile = env::var_os("MACSHELL_NIRI_PROFILE")
        .filter(|v| !v.is_empty())
        .ok_or_else(|| message(NEED_PROFILE))?;
    let address = env::var_os("NIRI_SOCKET")
        .filter(|v| !v.is_empty())
        .ok_or_else(|| message(NEED_PROFILE))?;
    let config = fs::canonicalize(profile)?.join("config.kdl");
    if !config.is_file() {
        return Err(message(NEED_PROFILE));
    }
    // Do not replace a symlink as the managed root configuration.
    if fs::symlink_metadata(&config)?.file_type().is_symlink() {
        return Err(message(NEED_PROFILE));
    }
    let before = fs::metadata(&address)?;
    let connection = connect_niri(&address)?;
    let mut credentials: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    if unsafe {
        libc::getsockopt(
            connection.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut len,
        )
    } != 0
    {
        return Err(Error::Io);
    }
    if len as usize != std::mem::size_of::<libc::ucred>() || credentials.pid <= 0 {
        return Err(Error::Io);
    }
    if credentials.uid != unsafe { libc::getuid() } {
        return Err(message("The niri session belongs to another user."));
    }
    let start_ticks = || -> Result<u64, Error> {
        let stat = fs::read_to_string(format!("/proc/{}/stat", credentials.pid))?;
        stat.rsplit_once(") ")
            .and_then(|(_, fields)| fields.split_whitespace().nth(19))
            .and_then(|field| field.parse().ok())
            .ok_or(Error::Io)
    };
    let start = start_ticks()?;
    let command = String::from_utf8(fs::read(format!("/proc/{}/cmdline", credentials.pid))?)
        .map_err(|_| Error::Io)?;
    if start_ticks()? != start {
        return Err(Error::Io);
    }
    let args: Vec<_> = command.trim_end_matches('\0').split('\0').collect();
    let mut current = env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .ok_or(Error::Io)?
        .join("niri/config.kdl");
    for (index, arg) in args.iter().enumerate() {
        if (*arg == "--config" || *arg == "-c") && index + 1 < args.len() {
            current = PathBuf::from(args[index + 1]);
        } else if let Some(value) = arg.strip_prefix("--config=") {
            current = PathBuf::from(value);
        }
    }
    if fs::canonicalize(&current).ok() != fs::canonicalize(&config).ok() {
        return Err(message(NEED_PROFILE));
    }
    let after = fs::metadata(&address)?;
    let identity = |m: &fs::Metadata| {
        (
            m.dev(),
            m.ino(),
            m.ctime() as i128 * 1_000_000_000 + m.ctime_nsec() as i128,
        )
    };
    if identity(&before) != identity(&after) {
        return Err(Error::Io);
    }
    Ok(Identity {
        uid: credentials.uid,
        pid: credentials.pid,
        start,
        device: before.dev(),
        inode: before.ino(),
        changed: identity(&before).2,
        config,
    })
}
