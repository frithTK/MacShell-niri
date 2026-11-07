//! Operation-owned recording resources. No process is started implicitly.
use std::fs::{File, OpenOptions};
use std::io;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant};

/// Exclusively reserve a new output file, without truncating an existing one.
/// The caller chooses a path inside the intended Videos directory; no path is
/// removed on failure, including partially written recordings.
pub fn reserve(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
}

/// A child created by this recorder, never a PID read from a shared file.
pub struct OwnedChild {
    child: Child,
    drop_grace: Duration,
}
impl OwnedChild {
    /// The caller supplies a fully configured command. The executable is run
    /// directly; stdin is closed and combined log handling belongs to caller.
    /// Linux parent-death signaling protects against an unexpected helper exit.
    pub fn spawn(command: &mut Command) -> io::Result<Self> {
        command.stdin(Stdio::null());
        Self::spawn_inner(command)
    }
    /// Spawn a selector whose input is an operation-owned pipe.
    pub fn spawn_with_stdin(command: &mut Command) -> io::Result<Self> {
        command.stdin(Stdio::piped());
        Self::spawn_inner(command)
    }
    fn spawn_inner(command: &mut Command) -> io::Result<Self> {
        let parent = unsafe { libc::getpid() };
        unsafe {
            command.pre_exec(move || {
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGINT) != 0 {
                    return Err(io::Error::last_os_error());
                }
                if libc::getppid() != parent {
                    return Err(io::Error::new(
                        io::ErrorKind::Interrupted,
                        "Recorder parent exited",
                    ));
                }
                Ok(())
            });
        }
        Ok(Self {
            child: command.spawn()?,
            drop_grace: Duration::from_secs(10),
        })
    }
    pub fn id(&self) -> u32 {
        self.child.id()
    }
    pub fn child_mut(&mut self) -> &mut Child {
        &mut self.child
    }
    pub fn set_drop_grace(&mut self, grace: Duration) {
        self.drop_grace = grace;
    }
    /// Signal only our live child. An exited child is reaped without signaling.
    pub fn interrupt(&mut self) -> io::Result<bool> {
        if self.child.try_wait()?.is_some() {
            return Ok(false);
        }
        let result = unsafe { libc::kill(self.child.id() as libc::pid_t, libc::SIGINT) };
        if result == 0 {
            Ok(true)
        } else {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) {
                Ok(false)
            } else {
                Err(error)
            }
        }
    }
    pub fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        self.child.try_wait()
    }
    pub fn kill(&mut self) -> io::Result<()> {
        if self.child.try_wait()?.is_none() {
            self.child.kill()?;
        }
        Ok(())
    }
    pub fn wait(&mut self) -> io::Result<ExitStatus> {
        self.child.wait()
    }
}
impl Drop for OwnedChild {
    fn drop(&mut self) {
        let _ = self.interrupt();
        let deadline = Instant::now() + self.drop_grace;
        loop {
            match self.child.try_wait() {
                Ok(Some(_)) | Err(_) => return,
                Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
                Ok(None) => {
                    let _ = self.child.kill();
                    let _ = self.child.wait();
                    return;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::{AtomicU64, Ordering};
    static SERIAL: AtomicU64 = AtomicU64::new(0);
    #[test]
    fn reservation_is_exclusive_and_never_truncates() {
        let path = std::env::temp_dir().join(format!(
            "macshell-recording-test-{}-{}",
            std::process::id(),
            SERIAL.fetch_add(1, Ordering::Relaxed)
        ));
        let mut file = reserve(&path).unwrap();
        file.write_all(b"existing").unwrap();
        drop(file);
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            reserve(&path).unwrap_err().kind(),
            io::ErrorKind::AlreadyExists
        );
        let mut text = String::new();
        File::open(&path)
            .unwrap()
            .read_to_string(&mut text)
            .unwrap();
        assert_eq!(text, "existing");
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn interrupt_only_the_spawned_child_and_reap_it() {
        let mut child = OwnedChild::spawn(Command::new("/bin/sleep").arg("30")).unwrap();
        assert!(child.interrupt().unwrap());
        let status = child.wait().unwrap();
        assert!(!status.success());
        assert!(!child.interrupt().unwrap());
    }
}
