use crate::session::{active_profile, Error, Identity};
use regex::Regex;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const MARKER: &str = "// Managed by MacShell: native blur strength.\n";
const INCLUDE: &str = "include \"./macshell-blur.kdl\"";
fn err(text: &str) -> Error {
    Error::Message(text.into())
}
fn random_hex() -> io::Result<String> {
    let mut data = [0u8; 16];
    let mut pos = 0;
    while pos < data.len() {
        let n = unsafe { libc::getrandom(data[pos..].as_mut_ptr().cast(), data.len() - pos, 0) };
        if n < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if n == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "random source closed",
            ));
        }
        pos += n as usize;
    }
    Ok(data.iter().map(|v| format!("{v:02x}")).collect())
}
struct Temp {
    path: PathBuf,
    directory: bool,
}
impl Drop for Temp {
    fn drop(&mut self) {
        if self.directory {
            let _ = fs::remove_file(self.path.join("blur.kdl"));
            let _ = fs::remove_dir(&self.path);
        } else {
            let _ = fs::remove_file(&self.path);
        }
    }
}
fn new_temp(
    dir: &Path,
    prefix: &str,
    suffix: &str,
    is_dir: bool,
) -> io::Result<(Temp, Option<File>)> {
    let path = dir.join(format!("{prefix}{}{suffix}", random_hex()?));
    if is_dir {
        fs::DirBuilder::new().mode(0o700).create(&path)?;
        Ok((
            Temp {
                path,
                directory: true,
            },
            None,
        ))
    } else {
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)?;
        Ok((
            Temp {
                path,
                directory: false,
            },
            Some(file),
        ))
    }
}
pub fn read_owned(path: &Path) -> Result<Option<String>, Error> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() || !meta.is_file() => {
            return Err(err(
                "The native blur file was edited outside MacShell; leaving it unchanged.",
            ))
        }
        Ok(_) => (),
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.into()),
    }
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    if !file.metadata()?.is_file() {
        return Err(err(
            "The native blur file was edited outside MacShell; leaving it unchanged.",
        ));
    }
    let mut text = String::new();
    file.read_to_string(&mut text)?;
    if !text.starts_with(MARKER) {
        return Err(err(
            "The native blur file was edited outside MacShell; leaving it unchanged.",
        ));
    }
    Ok(Some(text))
}
pub fn level(text: Option<&str>) -> Option<u64> {
    let re = Regex::new(r"(?m)^// Level: (\d+)$").unwrap();
    re.captures(text.unwrap_or(""))
        .and_then(|m| m.get(1))
        .and_then(|v| v.as_str().parse().ok())
}
fn blur_config(level: f64) -> String {
    let level = level.round_ties_even().clamp(0.0, 80.0) as u64;
    let offset = 0.5 + level as f64 * 3.5 / 80.0;
    format!("{MARKER}// Level: {level}\nblur {{ passes 3; offset {offset:.5}; }}\n")
}
fn atomic_write(path: &Path, data: &[u8]) -> io::Result<()> {
    let dir = path
        .parent()
        .ok_or_else(|| io::Error::other("missing directory"))?;
    let mode = match fs::symlink_metadata(path) {
        Ok(m) if m.file_type().is_symlink() || !m.is_file() => {
            return Err(io::Error::other("unexpected file type"))
        }
        Ok(m) => m.mode() & 0o7777,
        Err(e) if e.kind() == io::ErrorKind::NotFound => 0o600,
        Err(e) => return Err(e),
    };
    let (stage, file) = new_temp(dir, ".macshell-blur-", ".tmp", false)?;
    let mut file = file.unwrap();
    file.set_permissions(fs::Permissions::from_mode(mode))?;
    file.write_all(data)?;
    file.sync_all()?;
    drop(file);
    fs::rename(&stage.path, path)?;
    File::open(dir)?.sync_all()?;
    Ok(())
}
fn backup_once(dir: &Path, before: &[u8]) -> io::Result<()> {
    let backup = dir.join("macshell-blur-config.before");
    match fs::symlink_metadata(&backup) {
        Ok(_) => return Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => (),
        Err(error) => return Err(error),
    }
    let (stage, file) = new_temp(dir, ".macshell-blur-backup-", ".tmp", false)?;
    let mut file = file.unwrap();
    file.write_all(before)?;
    file.sync_all()?;
    drop(file);
    match fs::hard_link(&stage.path, &backup) {
        Ok(()) => File::open(dir)?.sync_all(),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => Ok(()),
        Err(error) => Err(error),
    }
}
fn validate(candidate: &Path) -> Result<(), Error> {
    let mut command = Command::new("niri");
    command
        .args(["validate", "-c"])
        .arg(candidate)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // The helper is single threaded. If it exits unexpectedly, stop only the
    // validator that it owns; do not leave a child validating an obsolete file.
    unsafe {
        command.pre_exec(|| {
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) != 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::getppid() == 1 {
                return Err(io::Error::other("parent already exited"));
            }
            Ok(())
        });
    }
    let mut child = command.spawn()?;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(_)) => {
                return Err(err(
                    "niri rejected the blur setting; the active configuration was not changed.",
                ))
            }
            Ok(None) => (),
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(e.into());
            }
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(Error::Io);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}
pub fn apply(identity: &Identity, value: f64) -> Result<(), Error> {
    let lock_path = identity
        .config()
        .parent()
        .ok_or(Error::Io)?
        .join(".macshell-blur.lock");
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(lock_path)?;
    if !lock.metadata()?.is_file() {
        return Err(Error::Io);
    }
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(err("Another native blur update is in progress. Try again."));
    }
    if active_profile()? != *identity {
        return Err(err(
            "The niri configuration changed while applying blur. Try again.",
        ));
    }
    apply_with(identity, value, &atomic_write)
}
fn apply_with(
    identity: &Identity,
    value: f64,
    write: &dyn Fn(&Path, &[u8]) -> io::Result<()>,
) -> Result<(), Error> {
    if !value.is_finite() {
        return Err(err("Invalid blur strength."));
    }
    let config = identity.config();
    let dir = config.parent().ok_or(Error::Io)?;
    let fragment = dir.join("macshell-blur.kdl");
    let previous = read_owned(&fragment)?;
    let before = fs::read(config)?;
    let original = std::str::from_utf8(&before).map_err(|_| Error::Io)?;
    let re = Regex::new(r#"(?m)^include "\./macshell-blur\.kdl"[ \t]*\n?"#).unwrap();
    let removed = re.replace_all(original, "");
    let text = format!("{}\n\n{INCLUDE}\n", removed.trim_end());
    let contents = blur_config(value);
    if previous.as_deref() == Some(contents.as_str()) && original == text {
        return Ok(());
    }
    let (stage, _) = new_temp(dir, ".macshell-blur-", "", true)?;
    let proposed = stage.path.join("blur.kdl");
    fs::write(&proposed, &contents)?;
    let (candidate, file) = new_temp(dir, ".macshell-blur-check-", ".kdl", false)?;
    let proposed_text = proposed.to_str().ok_or(Error::Io)?;
    let include = format!(
        "include {}",
        serde_json::to_string(proposed_text).map_err(|_| Error::Io)?
    );
    let mut file = file.unwrap();
    file.write_all(text.replace(INCLUDE, &include).as_bytes())?;
    drop(file);
    validate(&candidate.path)?;
    if fs::read(config)? != before
        || read_owned(&fragment)? != previous
        || active_profile()? != *identity
    {
        return Err(err(
            "The niri configuration changed while applying blur. Try again.",
        ));
    }
    if text.as_bytes() != before {
        backup_once(dir, &before)?;
    }
    if fs::read(config)? != before || read_owned(&fragment)? != previous {
        return Err(err(
            "The niri configuration changed while applying blur. Try again.",
        ));
    }
    commit_files(
        config, &fragment, &before, &text, &contents, previous, write,
    )
}

fn commit_files(
    config: &Path,
    fragment: &Path,
    before: &[u8],
    text: &str,
    contents: &str,
    previous: Option<String>,
    write: &dyn Fn(&Path, &[u8]) -> io::Result<()>,
) -> Result<(), Error> {
    if let Err(error) = write(fragment, contents.as_bytes()) {
        if fs::read(config).ok().as_deref() == Some(before)
            && read_owned(fragment).ok().flatten().as_deref() == Some(contents)
        {
            if let Some(previous) = &previous {
                write(fragment, previous.as_bytes())?;
            } else {
                fs::remove_file(fragment)?;
            }
        }
        return Err(error.into());
    }
    if text.as_bytes() != before {
        let changed = fs::read(config)? != before;
        let replacement = if changed {
            Err(io::Error::other("Configuration changed"))
        } else {
            write(config, text.as_bytes())
        };
        if let Err(error) = replacement {
            // Only undo the fragment if it is still the one we just wrote.
            // A failed directory sync can occur after the rename actually took
            // effect; never undo the fragment while the new config is live.
            if fs::read(config).ok().as_deref() == Some(before)
                && read_owned(fragment).ok().flatten().as_deref() == Some(contents)
            {
                if let Some(previous) = previous {
                    write(fragment, previous.as_bytes())?;
                } else {
                    fs::remove_file(fragment)?;
                }
            }
            if changed {
                return Err(err(
                    "The niri configuration changed while applying blur. Try again.",
                ));
            }
            return Err(error.into());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn root() -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "macshell-blur-transaction-{}-{}",
            std::process::id(),
            random_hex().unwrap()
        ));
        fs::create_dir(&root).unwrap();
        root
    }
    #[test]
    fn backup_is_exact_and_existing_backup_is_preserved() {
        let root = root();
        backup_once(&root, b"first config").unwrap();
        backup_once(&root, b"later config").unwrap();
        assert_eq!(
            fs::read(root.join("macshell-blur-config.before")).unwrap(),
            b"first config"
        );
        assert!(!fs::read_dir(&root).unwrap().flatten().any(|entry| entry
            .file_name()
            .to_string_lossy()
            .starts_with(".macshell-blur-backup-")));
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn failed_config_replacement_restores_the_old_fragment() {
        let root = root();
        let config = root.join("config.kdl");
        let fragment = root.join("macshell-blur.kdl");
        fs::write(&config, b"old config").unwrap();
        let old = blur_config(5.0);
        fs::write(&fragment, &old).unwrap();
        let result = commit_files(
            &config,
            &fragment,
            b"old config",
            "new config",
            &blur_config(50.0),
            Some(old.clone()),
            &|path, data| {
                if path == config {
                    Err(io::Error::other("failed before rename"))
                } else {
                    atomic_write(path, data)
                }
            },
        );
        assert!(result.is_err());
        assert_eq!(fs::read(&config).unwrap(), b"old config");
        assert_eq!(fs::read_to_string(&fragment).unwrap(), old);
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn failed_sync_after_config_rename_keeps_the_new_fragment() {
        let root = root();
        let config = root.join("config.kdl");
        let fragment = root.join("macshell-blur.kdl");
        fs::write(&config, b"old config").unwrap();
        let updated = blur_config(50.0);
        let result = commit_files(
            &config,
            &fragment,
            b"old config",
            "new config",
            &updated,
            None,
            &|path, data| {
                atomic_write(path, data)?;
                if path == config {
                    Err(io::Error::other("failed after rename"))
                } else {
                    Ok(())
                }
            },
        );
        assert!(result.is_err());
        assert_eq!(fs::read(&config).unwrap(), b"new config");
        assert_eq!(fs::read_to_string(&fragment).unwrap(), updated);
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn failed_sync_after_fragment_rename_restores_original() {
        let root = root();
        let config = root.join("config.kdl");
        let fragment = root.join("macshell-blur.kdl");
        fs::write(&config, b"old config").unwrap();
        let old = blur_config(5.0);
        let updated = blur_config(50.0);
        fs::write(&fragment, &old).unwrap();
        let result = commit_files(
            &config,
            &fragment,
            b"old config",
            "new config",
            &updated,
            Some(old.clone()),
            &|path, data| {
                atomic_write(path, data)?;
                if path == fragment && data == updated.as_bytes() {
                    Err(io::Error::other("failed after fragment rename"))
                } else {
                    Ok(())
                }
            },
        );
        assert!(result.is_err());
        assert_eq!(fs::read(&config).unwrap(), b"old config");
        assert_eq!(fs::read_to_string(&fragment).unwrap(), old);
        fs::remove_dir_all(root).unwrap();
    }
}
