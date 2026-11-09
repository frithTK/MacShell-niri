//! Serialize against MacLock and refuse to modify a running session.
use serde_json::Value;
use std::env;
use std::ffi::OsStr;
use std::fs::{File, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::Command;

fn bounded(binary: &OsStr, args: &[&str]) -> io::Result<String> {
    let output = Command::new("timeout")
        .arg("5")
        .arg(binary)
        .args(args)
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other("Unable to check session or lock state"));
    }
    String::from_utf8(output.stdout).map_err(io::Error::other)
}

pub struct Guard {
    _file: File,
}
impl Guard {
    pub fn acquire(qs: &OsStr) -> io::Result<Self> {
        let runtime = env::var_os("XDG_RUNTIME_DIR")
            .filter(|s| !s.is_empty())
            .ok_or_else(|| io::Error::other("Installation needs the user runtime directory"))?;
        if !Path::new(&runtime).is_dir() {
            return Err(io::Error::other(
                "Installation needs the user runtime directory",
            ));
        }
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(Path::new(&runtime).join("macshell-niri-lock.guard"))?;
        loop {
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
                break;
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
        let instances = bounded(
            qs,
            &["-c", "MacLock-niri", "list", "--any-display", "--json"],
        )?;
        let absent = instances.starts_with("No running instances for \"")
            && instances
                .trim_end()
                .ends_with("Use --all to list all instances.");
        let locked = if absent {
            false
        } else {
            let value: Value = serde_json::from_str(&instances)
                .map_err(|_| io::Error::other("Unexpected Quickshell instance list"))?;
            !value
                .as_array()
                .ok_or_else(|| io::Error::other("Unexpected Quickshell instance list"))?
                .is_empty()
        };
        if locked
            && bounded(
                qs,
                &["-c", "MacLock-niri", "ipc", "call", "lockscreen", "state"],
            )?
            .trim()
                != "ready"
        {
            return Err(io::Error::other("MacLock is active or its state is unknown; unlock before changing the installation"));
        }
        let state = bounded(
            OsStr::new("systemctl"),
            &[
                "--user",
                "show",
                "niri-macshell.service",
                "--property=ActiveState",
                "--value",
            ],
        )?;
        if !matches!(state.trim(), "inactive" | "failed") {
            return Err(io::Error::other(
                "Log out of the MacShell session before installing or rolling back",
            ));
        }
        Ok(Self { _file: file })
    }
}

pub fn run(
    qs: &OsStr,
    executable: &OsStr,
    args: &[std::ffi::OsString],
) -> io::Result<std::process::ExitStatus> {
    let guard = Guard::acquire(qs)?;
    let fd = guard._file.as_raw_fd();
    let mut command = Command::new(executable);
    command.args(args);
    unsafe {
        command.pre_exec(move || {
            let flags = libc::fcntl(fd, libc::F_GETFD);
            if flags < 0 || libc::fcntl(fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    command.status()
}
