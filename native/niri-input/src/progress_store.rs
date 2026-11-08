//! Experimental immutable progress snapshots. Not a transaction coordinator.
//! Callers must retain the profile lock and treat all observations as racy.
use crate::{
    journal::Manifest,
    journal_store,
    progress::{manifest_hash, Ledger, MAX_LEDGER_BYTES},
};
use std::ffi::{CString, OsStr};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

pub enum WriteResult {
    Durable,
    /// A file was created but the operation did not complete. Preserve it.
    Incomplete(io::Error),
}

fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "Invalid transaction progress")
}

fn name(journal: &OsStr, index: usize) -> io::Result<CString> {
    let journal = journal_store::journal_name(journal)?;
    if index > 2048 {
        return Err(invalid());
    }
    CString::new(format!(
        "{}-progress-{index:04}",
        journal.to_str().map_err(|_| invalid())?
    ))
    .map_err(|_| invalid())
}

/// Read a specific immutable progress snapshot and bind it to the given
/// manifest. Neither this record nor its SHA-256 hash is authenticated.
pub fn read(dir: &File, journal: &OsStr, manifest: &Manifest, index: usize) -> io::Result<Ledger> {
    if index > manifest.entries.len().saturating_mul(2) {
        return Err(invalid());
    }
    journal_store::check_directory(dir, manifest.profile_device, manifest.profile_inode)?;
    if journal_store::read(dir, journal)? != *manifest {
        return Err(invalid());
    }
    let hash = manifest_hash(manifest).map_err(|_| invalid())?;
    let result = read_snapshot(dir, journal, manifest, index, &hash)?;
    journal_store::check_directory(dir, manifest.profile_device, manifest.profile_inode)?;
    Ok(result)
}

fn read_snapshot(
    dir: &File,
    journal: &OsStr,
    manifest: &Manifest,
    index: usize,
    hash: &str,
) -> io::Result<Ledger> {
    let name = name(journal, index)?;
    let fd = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            name.as_ptr(),
            libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let handle = unsafe { File::from_raw_fd(fd) };
    let before = journal_store::check_file(&handle)?;
    if before.size() > MAX_LEDGER_BYTES as u64 {
        return Err(invalid());
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(format!("/proc/self/fd/{}", handle.as_raw_fd()))?;
    let opened = journal_store::check_file(&file)?;
    if before.dev() != opened.dev()
        || before.ino() != opened.ino()
        || opened.size() > MAX_LEDGER_BYTES as u64
    {
        return Err(invalid());
    }
    let mut bytes = Vec::new();
    (&file)
        .take(MAX_LEDGER_BYTES as u64 + 1)
        .read_to_end(&mut bytes)?;
    let after = journal_store::check_file(&file)?;
    if bytes.len() > MAX_LEDGER_BYTES
        || opened.dev() != after.dev()
        || opened.ino() != after.ino()
        || opened.size() != after.size()
        || opened.mtime() != after.mtime()
        || opened.mtime_nsec() != after.mtime_nsec()
        || opened.ctime() != after.ctime()
        || opened.ctime_nsec() != after.ctime_nsec()
    {
        return Err(invalid());
    }
    let ledger = Ledger::decode_hashed(&bytes, manifest, hash).map_err(|_| invalid())?;
    if ledger.events().len() != index {
        return Err(invalid());
    }
    Ok(ledger)
}

/// Diagnose every supported snapshot index, including indices after a gap.
/// An absent chain returns `None`; gaps, invalid snapshots or changed manifest
/// return an error. The result can become stale and does not prove that any
/// fsync succeeded, any exchange occurred, or the records are authentic.
pub fn scan_chain(dir: &File, journal: &OsStr, manifest: &Manifest) -> io::Result<Option<Ledger>> {
    journal_store::check_directory(dir, manifest.profile_device, manifest.profile_inode)?;
    if journal_store::read(dir, journal)? != *manifest {
        return Err(invalid());
    }
    let hash = manifest_hash(manifest).map_err(|_| invalid())?;
    let mut last: Option<Ledger> = None;
    let mut gap = false;
    for index in 0..=manifest.entries.len() * 2 {
        match read_snapshot(dir, journal, manifest, index, &hash) {
            Ok(ledger) => {
                if gap
                    || (index > 0
                        && last.as_ref().is_none_or(|previous| {
                            previous.events() != &ledger.events()[..index - 1]
                        }))
                {
                    return Err(invalid());
                }
                last = Some(ledger);
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => gap = true,
            Err(error) => return Err(error),
        }
    }
    let prefix = format!("{}-progress-", journal.to_string_lossy());
    scan_names(dir, &prefix, manifest.entries.len() * 2)?;
    if journal_store::read(dir, journal)? != *manifest {
        return Err(invalid());
    }
    journal_store::check_directory(dir, manifest.profile_device, manifest.profile_inode)?;
    Ok(last)
}

fn scan_names(dir: &File, prefix: &str, maximum: usize) -> io::Result<()> {
    let dot = CString::new(".").expect("constant has no NUL");
    let directory = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            dot.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if directory < 0 {
        return Err(io::Error::last_os_error());
    }
    let stream = unsafe { libc::fdopendir(directory) };
    if stream.is_null() {
        let error = io::Error::last_os_error();
        unsafe { libc::close(directory) };
        return Err(error);
    }
    let entries = std::iter::from_fn(|| {
        unsafe { *libc::__errno_location() = 0 };
        let entry = unsafe { libc::readdir(stream) };
        if entry.is_null() {
            let error = io::Error::last_os_error();
            Some(if error.raw_os_error() == Some(0) {
                Ok(None)
            } else {
                Err(error)
            })
        } else {
            let bytes = unsafe { std::ffi::CStr::from_ptr((*entry).d_name.as_ptr()) }
                .to_bytes()
                .to_vec();
            Some(Ok(Some(bytes)))
        }
    });
    let result = validate_snapshot_names(entries, prefix, maximum);
    let close_result = unsafe { libc::closedir(stream) };
    if close_result != 0 && result.is_ok() {
        return Err(io::Error::last_os_error());
    }
    result
}

fn validate_snapshot_names(
    entries: impl IntoIterator<Item = io::Result<Option<Vec<u8>>>>,
    prefix: &str,
    maximum: usize,
) -> io::Result<()> {
    for entry in entries {
        let Some(bytes) = entry? else {
            return Ok(());
        };
        let Some(suffix) = bytes.strip_prefix(prefix.as_bytes()) else {
            continue;
        };
        if suffix.len() != 4 || !suffix.iter().all(u8::is_ascii_digit) {
            return Err(invalid());
        }
        let index = suffix
            .iter()
            .try_fold(0usize, |value, byte| {
                value.checked_mul(10)?.checked_add(usize::from(byte - b'0'))
            })
            .ok_or_else(invalid)?;
        if index > maximum {
            return Err(invalid());
        }
    }
    Ok(())
}

/// Write the initial empty ledger or exactly the successor of an existing
/// snapshot. No existing name is overwritten or removed. Callers must only
/// record completion after an exchange and directory sync actually succeeded.
/// A crash or incomplete result may leave a partial snapshot for inspection.
/// Reading a valid predecessor does not establish that its earlier fsync
/// succeeded or that all earlier snapshots still exist. In particular, do not
/// continue after `Incomplete`; restart and chain verification are unfinished.
pub fn write(
    dir: &File,
    journal: &OsStr,
    manifest: &Manifest,
    ledger: &Ledger,
) -> io::Result<WriteResult> {
    write_with(
        dir,
        journal,
        manifest,
        ledger,
        File::sync_all,
        File::sync_all,
    )
}

fn write_with(
    dir: &File,
    journal: &OsStr,
    manifest: &Manifest,
    ledger: &Ledger,
    sync_file: impl FnOnce(&File) -> io::Result<()>,
    sync_dir: impl FnOnce(&File) -> io::Result<()>,
) -> io::Result<WriteResult> {
    let bytes = ledger.encode().map_err(|_| invalid())?;
    let validated = Ledger::decode(&bytes, manifest).map_err(|_| invalid())?;
    let index = validated.events().len();
    journal_store::check_directory(dir, manifest.profile_device, manifest.profile_inode)?;
    if journal_store::read(dir, journal)? != *manifest {
        return Err(invalid());
    }
    let existing = scan_chain(dir, journal, manifest)?;
    match (index, existing.as_ref()) {
        (0, None) => {}
        (0, Some(_)) => return Err(invalid()),
        (next, Some(previous)) if previous.events().len() == next - 1 => {
            if previous.events() != &validated.events()[..next - 1] {
                return Err(invalid());
            }
        }
        _ => return Err(invalid()),
    }
    let name = name(journal, index)?;
    let fd = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut file = unsafe { File::from_raw_fd(fd) };
    let result = (|| -> io::Result<()> {
        if unsafe { libc::fchmod(file.as_raw_fd(), 0o600) } != 0 {
            return Err(io::Error::last_os_error());
        }
        journal_store::check_file(&file)?;
        file.write_all(&bytes)?;
        sync_file(&file)?;
        journal_store::verify_created(dir, &name, &file, &bytes)?;
        journal_store::check_directory(dir, manifest.profile_device, manifest.profile_inode)?;
        sync_dir(dir)?;
        journal_store::verify_created(dir, &name, &file, &bytes)?;
        Ok(())
    })();
    Ok(match result {
        Ok(()) => WriteResult::Durable,
        Err(error) => WriteResult::Incomplete(error),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        journal::{Entry, FileVersion},
        progress::Event,
    };
    use std::fs;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::sync::atomic::{AtomicUsize, Ordering};

    const JOURNAL: &str = ".macshell-input-journal-0123456789abcdef0123456789abcdef";
    struct TestDir(std::path::PathBuf);
    impl TestDir {
        fn new() -> Self {
            static ID: AtomicUsize = AtomicUsize::new(0);
            let p = std::env::temp_dir().join(format!(
                "macshell-progress-{}-{}",
                std::process::id(),
                ID.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&p).unwrap();
            Self(p)
        }
    }
    impl Drop for TestDir {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    fn setup(dir: &File) -> Manifest {
        let m = dir.metadata().unwrap();
        let version = |inode| FileVersion {
            device: m.dev(),
            inode,
            mode: libc::S_IFREG | 0o600,
            uid: m.uid(),
            gid: m.gid(),
            nlink: 1,
            bytes: vec![inode as u8],
        };
        let manifest = Manifest {
            profile_device: m.dev(),
            profile_inode: m.ino(),
            entries: vec![Entry {
                target: "input.kdl".into(),
                candidate: ".macshell-input-0123456789abcdef0123456789abcdef".into(),
                original: version(11),
                replacement: version(12),
            }],
        };
        assert!(matches!(
            journal_store::create(dir, OsStr::new(JOURNAL), &manifest).unwrap(),
            journal_store::CreateResult::Durable
        ));
        manifest
    }

    #[test]
    fn persists_ordered_snapshots_and_never_overwrites() {
        let dir = TestDir::new();
        let root = File::open(&dir.0).unwrap();
        let manifest = setup(&root);
        let mut ledger = Ledger::new(&manifest).unwrap();
        ledger.push(Event::Intent(0)).unwrap();
        assert_eq!(
            write(&root, OsStr::new(JOURNAL), &manifest, &ledger)
                .err()
                .unwrap()
                .kind(),
            io::ErrorKind::InvalidData
        );
        let empty = Ledger::new(&manifest).unwrap();
        assert!(matches!(
            write(&root, OsStr::new(JOURNAL), &manifest, &empty).unwrap(),
            WriteResult::Durable
        ));
        assert!(matches!(
            write(&root, OsStr::new(JOURNAL), &manifest, &ledger).unwrap(),
            WriteResult::Durable
        ));
        ledger.push(Event::Exchanged(0)).unwrap();
        assert!(matches!(
            write(&root, OsStr::new(JOURNAL), &manifest, &ledger).unwrap(),
            WriteResult::Durable
        ));
        assert_eq!(
            read(&root, OsStr::new(JOURNAL), &manifest, 2).unwrap(),
            ledger
        );
        assert_eq!(
            write(&root, OsStr::new(JOURNAL), &manifest, &ledger)
                .err()
                .unwrap()
                .kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(
            fs::metadata(dir.0.join(format!("{JOURNAL}-progress-0002")))
                .unwrap()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[test]
    fn sync_failure_leaves_record_and_does_not_claim_success() {
        for file_failure in [true, false] {
            let dir = TestDir::new();
            let root = File::open(&dir.0).unwrap();
            let manifest = setup(&root);
            let ledger = Ledger::new(&manifest).unwrap();
            let failure = || io::Error::other("injected sync failure");
            let result = write_with(
                &root,
                OsStr::new(JOURNAL),
                &manifest,
                &ledger,
                |f| {
                    if file_failure {
                        Err(failure())
                    } else {
                        f.sync_all()
                    }
                },
                |f| {
                    if file_failure {
                        f.sync_all()
                    } else {
                        Err(failure())
                    }
                },
            )
            .unwrap();
            assert!(matches!(result, WriteResult::Incomplete(_)));
            assert_eq!(
                read(&root, OsStr::new(JOURNAL), &manifest, 0).unwrap(),
                ledger
            );
        }
    }

    #[test]
    fn rejects_symlink_corruption_and_mismatched_manifest() {
        let dir = TestDir::new();
        let root = File::open(&dir.0).unwrap();
        let manifest = setup(&root);
        let ledger = Ledger::new(&manifest).unwrap();
        let target = dir.0.join("target");
        fs::write(&target, b"untouched").unwrap();
        let path = dir.0.join(format!("{JOURNAL}-progress-0000"));
        symlink("target", &path).unwrap();
        assert!(write(&root, OsStr::new(JOURNAL), &manifest, &ledger).is_err());
        assert!(read(&root, OsStr::new(JOURNAL), &manifest, 0).is_err());
        assert_eq!(fs::read(&target).unwrap(), b"untouched");
        fs::remove_file(&path).unwrap();
        assert!(matches!(
            write(&root, OsStr::new(JOURNAL), &manifest, &ledger).unwrap(),
            WriteResult::Durable
        ));
        let mut changed = manifest.clone();
        changed.entries[0].original.bytes.push(10);
        assert!(read(&root, OsStr::new(JOURNAL), &changed, 0).is_err());
        fs::write(&path, b"broken").unwrap();
        assert!(read(&root, OsStr::new(JOURNAL), &manifest, 0).is_err());
    }

    #[test]
    fn read_rejects_indices_beyond_this_manifest() {
        let dir = TestDir::new();
        let root = File::open(&dir.0).unwrap();
        let manifest = setup(&root);
        for index in [3, 2049] {
            assert_eq!(
                read(&root, OsStr::new(JOURNAL), &manifest, index)
                    .err()
                    .unwrap()
                    .kind(),
                io::ErrorKind::InvalidData
            );
        }
    }

    #[test]
    fn chain_scan_rejects_gaps_and_corrupt_later_snapshots() {
        let dir = TestDir::new();
        let root = File::open(&dir.0).unwrap();
        let manifest = setup(&root);
        assert_eq!(
            scan_chain(&root, OsStr::new(JOURNAL), &manifest).unwrap(),
            None
        );
        let mut ledger = Ledger::new(&manifest).unwrap();
        assert!(matches!(
            write(&root, OsStr::new(JOURNAL), &manifest, &ledger).unwrap(),
            WriteResult::Durable
        ));
        ledger.push(Event::Intent(0)).unwrap();
        assert!(matches!(
            write(&root, OsStr::new(JOURNAL), &manifest, &ledger).unwrap(),
            WriteResult::Durable
        ));
        ledger.push(Event::Exchanged(0)).unwrap();
        assert!(matches!(
            write(&root, OsStr::new(JOURNAL), &manifest, &ledger).unwrap(),
            WriteResult::Durable
        ));
        assert_eq!(
            scan_chain(&root, OsStr::new(JOURNAL), &manifest).unwrap(),
            Some(ledger)
        );
        let middle = dir.0.join(format!("{JOURNAL}-progress-0001"));
        let saved = fs::read(&middle).unwrap();
        fs::remove_file(&middle).unwrap();
        assert!(scan_chain(&root, OsStr::new(JOURNAL), &manifest).is_err());
        fs::write(&middle, saved).unwrap();
        fs::set_permissions(&middle, fs::Permissions::from_mode(0o600)).unwrap();
        fs::write(dir.0.join(format!("{JOURNAL}-progress-0002")), b"broken").unwrap();
        assert!(scan_chain(&root, OsStr::new(JOURNAL), &manifest).is_err());
    }

    #[test]
    fn chain_scan_rejects_out_of_range_and_malformed_snapshot_names() {
        for name in [
            format!("{JOURNAL}-progress-0003"),
            format!("{JOURNAL}-progress-000x"),
        ] {
            let dir = TestDir::new();
            let root = File::open(&dir.0).unwrap();
            let manifest = setup(&root);
            fs::write(dir.0.join(name), b"orphan").unwrap();
            assert!(scan_chain(&root, OsStr::new(JOURNAL), &manifest).is_err());
        }
    }

    #[test]
    fn directory_iteration_errors_are_not_treated_as_end_of_directory() {
        assert_eq!(
            validate_snapshot_names(
                [Err(io::Error::other("injected readdir failure"))],
                JOURNAL,
                2,
            )
            .unwrap_err()
            .to_string(),
            "injected readdir failure"
        );
        assert!(validate_snapshot_names([Ok(None)], JOURNAL, 2).is_ok());
    }

    #[test]
    fn writer_refuses_to_extend_a_gapped_chain() {
        let dir = TestDir::new();
        let root = File::open(&dir.0).unwrap();
        let manifest = setup(&root);
        let mut ledger = Ledger::new(&manifest).unwrap();
        assert!(matches!(
            write(&root, OsStr::new(JOURNAL), &manifest, &ledger).unwrap(),
            WriteResult::Durable
        ));
        ledger.push(Event::Intent(0)).unwrap();
        assert!(matches!(
            write(&root, OsStr::new(JOURNAL), &manifest, &ledger).unwrap(),
            WriteResult::Durable
        ));
        fs::remove_file(dir.0.join(format!("{JOURNAL}-progress-0000"))).unwrap();
        ledger.push(Event::Exchanged(0)).unwrap();
        assert_eq!(
            write(&root, OsStr::new(JOURNAL), &manifest, &ledger)
                .err()
                .unwrap()
                .kind(),
            io::ErrorKind::InvalidData
        );
        assert!(!dir.0.join(format!("{JOURNAL}-progress-0002")).exists());
    }
}
