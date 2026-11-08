//! Advisory serialization for cooperating MacShell input writers only.
use std::ffi::CString;
use std::fs::{File, OpenOptions};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

const NAME: &str = ".macshell-input.lock";

/// Holds an advisory lock and an open root directory. Other programs and older
/// Python writers do not cooperate; this is not a filesystem transaction.
pub struct Guard {
    root: File,
    lock: File,
}

fn open_lock(root: &File, create: bool) -> io::Result<File> {
    let name = CString::new(NAME).expect("static name");
    if create {
        let fd = unsafe {
            libc::openat(
                root.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                0o600,
            )
        };
        if fd >= 0 {
            return Ok(unsafe { File::from_raw_fd(fd) });
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::AlreadyExists {
            return Err(error);
        }
    }
    // Inspect the inode without opening a possible device or FIFO for I/O.
    let fd = unsafe {
        libc::openat(
            root.as_raw_fd(),
            name.as_ptr(),
            libc::O_PATH | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let handle = unsafe { File::from_raw_fd(fd) };
    safe_lock(&handle)?;
    let expected = handle.metadata()?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(format!("/proc/self/fd/{}", handle.as_raw_fd()))?;
    let actual = file.metadata()?;
    if expected.dev() != actual.dev() || expected.ino() != actual.ino() {
        return Err(io::Error::other("Input lock changed"));
    }
    Ok(file)
}

fn safe_lock(file: &File) -> io::Result<()> {
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Unsafe input lock file",
        ));
    }
    Ok(())
}

impl Guard {
    pub(crate) fn root(&self) -> &File {
        &self.root
    }
    pub fn acquire(profile: &Path) -> io::Result<Self> {
        let root = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(profile)?;
        let lock = open_lock(&root, true)?;
        safe_lock(&lock)?;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let guard = Self { root, lock };
        guard.check()?;
        Ok(guard)
    }

    /// Detect removal or replacement of the lock pathname while it is held.
    pub fn check(&self) -> io::Result<()> {
        let current = open_lock(&self.root, false)?;
        safe_lock(&current)?;
        let expected = self.lock.metadata()?;
        let actual = current.metadata()?;
        if expected.dev() != actual.dev() || expected.ino() != actual.ino() {
            return Err(io::Error::other("Input lock was replaced"));
        }
        Ok(())
    }

    /// Ensure the profile pathname still names the directory that was locked.
    pub fn check_profile(&self, profile: &Path) -> io::Result<()> {
        self.check()?;
        let current = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(profile)?;
        let expected = self.root.metadata()?;
        let actual = current.metadata()?;
        if expected.dev() != actual.dev() || expected.ino() != actual.ino() {
            return Err(io::Error::other("Input profile directory was replaced"));
        }
        Ok(())
    }
}
