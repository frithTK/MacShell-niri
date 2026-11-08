//! Validate a planned profile in a disposable private directory.
//! This does not commit changes or establish that the source is still current.
use crate::{includes, Plan};
use std::collections::BTreeMap;
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

fn invalid(s: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, s)
}
struct Stage(PathBuf);
impl Drop for Stage {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn stage() -> io::Result<Stage> {
    let mut random = [0u8; 16];
    let mut pos = 0;
    while pos < random.len() {
        let n =
            unsafe { libc::getrandom(random[pos..].as_mut_ptr().cast(), random.len() - pos, 0) };
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
                "Random source closed",
            ));
        }
        pos += n as usize;
    }
    let suffix: String = random.iter().map(|b| format!("{b:02x}")).collect();
    let path = std::env::temp_dir().join(format!("macshell-input-{suffix}"));
    DirBuilder::new().mode(0o700).create(&path)?;
    Ok(Stage(path))
}

/// Validate the exact in-memory plan. The validator is an explicitly supplied
/// executable; callers must choose a trusted niri binary. The timeout bounds
/// the child process; no process from the active desktop is targeted.
pub fn validate(plan: &Plan, validator: &Path, timeout: Duration) -> io::Result<()> {
    let mut files: BTreeMap<PathBuf, Vec<u8>> = plan.before.clone();
    for (path, content) in &plan.changes {
        if !files.contains_key(path) {
            return Err(invalid("Plan adds an unknown file"));
        }
        files.insert(path.clone(), content.clone());
    }
    if files.len() > 1024 || !files.contains_key(Path::new("config.kdl")) {
        return Err(invalid("Incomplete profile"));
    }
    let mut total = 0usize;
    for (path, content) in &files {
        if path.as_os_str().is_empty()
            || !path.components().all(|c| matches!(c, Component::Normal(_)))
            || path.extension().is_none_or(|e| e != "kdl")
            || content.len() > 2 * 1024 * 1024
        {
            return Err(invalid("Invalid staged file"));
        }
        total = total
            .checked_add(content.len())
            .ok_or_else(|| invalid("Profile too large"))?;
        if total > 16 * 1024 * 1024 {
            return Err(invalid("Profile too large"));
        }
    }
    includes::check(&files).map_err(|_| invalid("Unsafe or unsupported include syntax"))?;
    let stage = stage()?;
    for (path, content) in files {
        let output = stage.0.join(path);
        fs::create_dir_all(
            output
                .parent()
                .ok_or_else(|| invalid("Invalid file path"))?,
        )?;
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(output)?;
        file.write_all(&content)?;
    }
    let deadline = Instant::now()
        .checked_add(timeout)
        .ok_or_else(|| invalid("Invalid timeout"))?;
    let mut command = Command::new(validator);
    command
        .arg("validate")
        .arg("-c")
        .arg(stage.0.join("config.kdl"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    unsafe {
        command.pre_exec(|| {
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) != 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::getppid() == 1 {
                return Err(io::Error::other("Parent exited"));
            }
            Ok(())
        });
    }
    let mut child = command.spawn()?;
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(_)) => return Err(invalid("niri rejected the staged profile")),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "niri validation timed out",
                ));
            }
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error);
            }
        }
    }
}
