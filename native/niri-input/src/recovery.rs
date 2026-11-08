//! Read-only, racy observations for a possible future recovery workflow.
//! A matching manifest does not establish provenance or authorize writes.
use crate::journal::{FileVersion, Manifest};
use crate::progress::{Event, Ledger};
use std::ffi::{CString, OsStr};
use std::fs::{File, OpenOptions};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Component, Path};

#[derive(Debug, PartialEq, Eq)]
pub enum Observation {
    Original,
    Exchanged,
    Conflict,
}

/// A summary of separate, non-atomic observations. None of these states grants
/// permission to modify files or proves that the profile is currently valid.
#[derive(Debug, PartialEq, Eq)]
pub enum ProfileObservation {
    AllOriginal,
    AllExchanged,
    PartiallyExchanged,
    Conflict,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Report {
    /// In manifest order, for locating the affected entries.
    pub files: Vec<Observation>,
    pub profile: ProfileObservation,
}

/// Diagnostic agreement between the recorded progress and independent,
/// non-atomic observations. None of these permits a write or proves fsync.
#[derive(Debug, PartialEq, Eq)]
pub enum ProgressAgreement {
    Consistent,
    /// The pending intent might have run before its completion was recorded.
    PendingExchange,
    Conflict,
}

/// Evidence observed at different times, never authority to recover or write.
#[derive(Debug, PartialEq, Eq)]
pub struct Diagnostic {
    pub files: Report,
    pub ledger: Option<Ledger>,
    pub agreement: ProgressAgreement,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Preflight {
    Clear,
    Blocked(Diagnostic),
}

/// Inspect the known transaction journal before starting another operation.
/// Any retained journal blocks a new write, including a consistent completed
/// arrangement, until an explicit cleanup/resolution phase exists.
pub fn preflight(root: &File, journal: &OsStr) -> io::Result<Preflight> {
    match inspect_journal(root, journal) {
        Ok(diagnostic) => Ok(Preflight::Blocked(diagnostic)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Preflight::Clear),
        Err(error) => Err(error),
    }
}

/// Explicitly remove evidence for a transaction that was observed as fully
/// exchanged and complete. This is deliberately not automatic recovery: every
/// check is repeated while the cooperative profile lock is held, but an
/// uncooperative writer can still race the operation. On any mismatch, no
/// cleanup is attempted.
pub fn cleanup_completed(profile: &Path, journal: &OsStr) -> io::Result<()> {
    let guard = crate::lock::Guard::acquire(profile)?;
    let root = guard.root();
    let manifest = crate::journal_store::read(root, journal)?;
    let diagnostic = inspect_journal(root, journal)?;
    if diagnostic.agreement != ProgressAgreement::Consistent
        || diagnostic.files.profile != ProfileObservation::AllExchanged
        || diagnostic
            .ledger
            .as_ref()
            .is_none_or(|ledger| ledger.events().len() != manifest.entries.len() * 2)
    {
        return Err(invalid("Transaction is not explicitly cleanup-safe"));
    }
    guard.check_profile(profile)?;
    if inspect_journal(root, journal)?.agreement != ProgressAgreement::Consistent {
        return Err(invalid("Transaction changed before cleanup"));
    }
    for entry in &manifest.entries {
        unlink_relative(root, Path::new(&entry.candidate))?;
    }
    root.sync_all()?;
    for index in 0..=manifest.entries.len() * 2 {
        let name = format!("{}-progress-{index:04}", journal.to_string_lossy());
        unlink_relative(root, Path::new(&name))?;
    }
    let journal_name =
        crate::journal_store::journal_name(journal).map_err(|_| invalid("Invalid journal name"))?;
    unlink_relative(
        root,
        Path::new(
            journal_name
                .to_str()
                .map_err(|_| invalid("Invalid journal name"))?,
        ),
    )?;
    root.sync_all()?;
    guard.check_profile(profile)?;
    Ok(())
}

fn unlink_relative(root: &File, path: &Path) -> io::Result<()> {
    let mut parent = root.try_clone()?;
    for component in path.parent().unwrap_or(Path::new("")).components() {
        let Component::Normal(name) = component else {
            return Err(invalid("Invalid cleanup path"));
        };
        parent = open_at(&parent, name, libc::O_RDONLY | libc::O_DIRECTORY)?;
    }
    let name = path
        .file_name()
        .ok_or_else(|| invalid("Invalid cleanup name"))?;
    let c_name = CString::new(name.as_bytes()).map_err(|_| invalid("Invalid cleanup name"))?;
    let result = unsafe { libc::unlinkat(parent.as_raw_fd(), c_name.as_ptr(), 0) };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    parent.sync_all()?;
    Ok(())
}

/// Reopen the private manifest and progress chain, then inspect the file pairs.
/// Re-reading the manifest and chain rejects changes observed during inspection,
/// but the observations are not atomic and the records are not authenticated.
/// A readable chain cannot prove that a previous fsync completed successfully.
pub fn inspect_journal(root: &File, journal: &OsStr) -> io::Result<Diagnostic> {
    let manifest = crate::journal_store::read(root, journal)?;
    let ledger = crate::progress_store::scan_chain(root, journal, &manifest)?;
    let files = inspect_report(root, &manifest)?;
    let agreement = compare_progress(&manifest, ledger.as_ref(), &files)?;
    if crate::journal_store::read(root, journal)? != manifest
        || crate::progress_store::scan_chain(root, journal, &manifest)? != ledger
    {
        return Err(invalid("Transaction evidence changed during inspection"));
    }
    Ok(Diagnostic {
        files,
        ledger,
        agreement,
    })
}

/// Compare a validated ledger with observations in manifest order. A missing
/// ledger, invalid binding, missing observation, unexpected order, or external
/// edit is a conflict. Observations can change immediately after this returns.
pub fn compare_progress(
    manifest: &Manifest,
    ledger: Option<&Ledger>,
    report: &Report,
) -> io::Result<ProgressAgreement> {
    let Some(ledger) = ledger else {
        return Ok(ProgressAgreement::Conflict);
    };
    let encoded = ledger.encode().map_err(|_| invalid("Invalid progress"))?;
    let checked = Ledger::decode(&encoded, manifest).map_err(|_| invalid("Invalid progress"))?;
    if report.files.len() != manifest.entries.len() {
        return Ok(ProgressAgreement::Conflict);
    }
    let events = checked.events();
    let completed = events.len() / 2;
    let pending = matches!(events.last(), Some(Event::Intent(_)));
    for (index, observation) in report.files.iter().enumerate() {
        let expected = if index < completed {
            Observation::Exchanged
        } else {
            Observation::Original
        };
        if pending && index == completed {
            if !matches!(observation, Observation::Original | Observation::Exchanged) {
                return Ok(ProgressAgreement::Conflict);
            }
        } else if *observation != expected {
            return Ok(ProgressAgreement::Conflict);
        }
    }
    Ok(if pending {
        ProgressAgreement::PendingExchange
    } else {
        ProgressAgreement::Consistent
    })
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn open_at(dir: &File, name: &std::ffi::OsStr, flags: libc::c_int) -> io::Result<File> {
    let name = CString::new(name.as_bytes()).map_err(|_| invalid("Invalid path"))?;
    let fd = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn matches_version(dir: &File, name: &std::ffi::OsStr, expected: &FileVersion) -> io::Result<bool> {
    let handle = match open_at(dir, name, libc::O_PATH) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    };
    let before = handle.metadata()?;
    if !before.is_file()
        || before.dev() != expected.device
        || before.ino() != expected.inode
        || before.mode() != expected.mode
        || before.uid() != expected.uid
        || before.gid() != expected.gid
        || before.nlink() != expected.nlink
        || before.size() != expected.bytes.len() as u64
    {
        return Ok(false);
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(format!("/proc/self/fd/{}", handle.as_raw_fd()))?;
    let opened = file.metadata()?;
    if opened.dev() != before.dev()
        || opened.ino() != before.ino()
        || opened.mode() != before.mode()
        || opened.uid() != before.uid()
        || opened.gid() != before.gid()
        || opened.nlink() != before.nlink()
        || opened.size() != before.size()
        || opened.mtime() != before.mtime()
        || opened.mtime_nsec() != before.mtime_nsec()
        || opened.ctime() != before.ctime()
        || opened.ctime_nsec() != before.ctime_nsec()
    {
        return Ok(false);
    }
    let xattrs = unsafe { libc::flistxattr(file.as_raw_fd(), std::ptr::null_mut(), 0) };
    if xattrs < 0 {
        return Err(io::Error::last_os_error());
    }
    if xattrs != 0 {
        return Ok(false);
    }
    let mut buf = [0u8; 8192];
    let mut offset = 0usize;
    while offset < expected.bytes.len() {
        let count = buf.len().min(expected.bytes.len() - offset);
        let n = file.read_at(&mut buf[..count], offset as u64)?;
        if n == 0 || buf[..n] != expected.bytes[offset..offset + n] {
            return Ok(false);
        }
        offset += n;
    }
    let after = file.metadata()?;
    Ok(opened.dev() == after.dev()
        && opened.ino() == after.ino()
        && opened.mode() == after.mode()
        && opened.uid() == after.uid()
        && opened.gid() == after.gid()
        && opened.nlink() == after.nlink()
        && opened.size() == after.size()
        && opened.mtime() == after.mtime()
        && opened.mtime_nsec() == after.mtime_nsec()
        && opened.ctime() == after.ctime()
        && opened.ctime_nsec() == after.ctime_nsec())
}

/// Observe every pair named in a validated manifest, without modifying files.
/// The root must be the manifest's owned, non-group/world-writable directory.
/// Results are not atomic and can become stale immediately; matching inode,
/// contents and metadata do not establish provenance after restart.
pub fn inspect(root: &File, manifest: &Manifest) -> io::Result<Vec<Observation>> {
    manifest
        .validate()
        .map_err(|_| invalid("Invalid manifest"))?;
    crate::journal_store::check_directory(root, manifest.profile_device, manifest.profile_inode)?;
    let mut observations = Vec::with_capacity(manifest.entries.len());
    for entry in &manifest.entries {
        let path = Path::new(&entry.target);
        let mut parent = root.try_clone()?;
        for part in path
            .parent()
            .ok_or_else(|| invalid("Invalid parent"))?
            .components()
        {
            let Component::Normal(name) = part else {
                return Err(invalid("Invalid parent"));
            };
            parent = open_at(&parent, name, libc::O_RDONLY | libc::O_DIRECTORY)?;
        }
        let target = path.file_name().ok_or_else(|| invalid("Invalid target"))?;
        let candidate = Path::new(&entry.candidate)
            .file_name()
            .ok_or_else(|| invalid("Invalid candidate"))?;
        let original = matches_version(&parent, target, &entry.original)?
            && matches_version(&parent, candidate, &entry.replacement)?;
        let exchanged = !original
            && matches_version(&parent, target, &entry.replacement)?
            && matches_version(&parent, candidate, &entry.original)?;
        observations.push(if original {
            Observation::Original
        } else if exchanged {
            Observation::Exchanged
        } else {
            Observation::Conflict
        });
    }
    crate::journal_store::check_directory(root, manifest.profile_device, manifest.profile_inode)?;
    Ok(observations)
}

/// Summarize a diagnostic scan without assuming that individual observations
/// occurred at the same instant. Any conflict takes precedence over the
/// apparently complete or partial arrangements of other files.
pub fn inspect_report(root: &File, manifest: &Manifest) -> io::Result<Report> {
    let files = inspect(root, manifest)?;
    let profile = if files.contains(&Observation::Conflict) {
        ProfileObservation::Conflict
    } else if files.iter().all(|state| *state == Observation::Original) {
        ProfileObservation::AllOriginal
    } else if files.iter().all(|state| *state == Observation::Exchanged) {
        ProfileObservation::AllExchanged
    } else {
        ProfileObservation::PartiallyExchanged
    };
    Ok(Report { files, profile })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::journal::Entry;
    use std::fs;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct TestDir(std::path::PathBuf);
    impl TestDir {
        fn new() -> Self {
            static ID: AtomicUsize = AtomicUsize::new(0);
            let path = std::env::temp_dir().join(format!(
                "macshell-recovery-{}-{}",
                std::process::id(),
                ID.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for TestDir {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    const CANDIDATE: &str = ".macshell-input-0123456789abcdef0123456789abcdef";
    fn version(path: &Path) -> FileVersion {
        let m = fs::metadata(path).unwrap();
        FileVersion {
            device: m.dev(),
            inode: m.ino(),
            mode: m.mode(),
            uid: m.uid(),
            gid: m.gid(),
            nlink: m.nlink(),
            bytes: fs::read(path).unwrap(),
        }
    }
    fn setup(dir: &TestDir) -> (File, Manifest) {
        fs::create_dir(dir.0.join("nested")).unwrap();
        fs::write(dir.0.join("nested/input.kdl"), b"old").unwrap();
        fs::write(dir.0.join("nested").join(CANDIDATE), b"new").unwrap();
        let root = File::open(&dir.0).unwrap();
        let meta = root.metadata().unwrap();
        let manifest = Manifest {
            profile_device: meta.dev(),
            profile_inode: meta.ino(),
            entries: vec![Entry {
                target: "nested/input.kdl".into(),
                candidate: format!("nested/{CANDIDATE}"),
                original: version(&dir.0.join("nested/input.kdl")),
                replacement: version(&dir.0.join("nested").join(CANDIDATE)),
            }],
        };
        (root, manifest)
    }

    #[test]
    fn recognizes_both_arrangements_after_reopening_files() {
        let dir = TestDir::new();
        let (root, manifest) = setup(&dir);
        assert_eq!(inspect(&root, &manifest).unwrap(), [Observation::Original]);
        let parent = File::open(dir.0.join("nested")).unwrap();
        let target = File::open(dir.0.join("nested/input.kdl")).unwrap();
        let replacement = File::open(dir.0.join("nested").join(CANDIDATE)).unwrap();
        let result = crate::exchange::exchange(
            &parent,
            "input.kdl".as_ref(),
            CANDIDATE.as_ref(),
            crate::exchange::Expected {
                original: &target,
                replacement: &replacement,
                original_bytes: b"old",
                replacement_bytes: b"new",
            },
        )
        .unwrap();
        assert_eq!(result, crate::exchange::ResultState::Exchanged);
        drop(target);
        drop(replacement);
        assert_eq!(inspect(&root, &manifest).unwrap(), [Observation::Exchanged]);
    }

    #[test]
    fn detects_edits_permissions_missing_and_symlinks() {
        let dir = TestDir::new();
        let (root, manifest) = setup(&dir);
        let path = dir.0.join("nested/input.kdl");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        // Choose a mode different from the snapshot even when umask is 077.
        let new_mode = if manifest.entries[0].original.mode & 0o777 == 0o600 {
            0o640
        } else {
            0o600
        };
        fs::set_permissions(&path, fs::Permissions::from_mode(new_mode)).unwrap();
        assert_eq!(inspect(&root, &manifest).unwrap(), [Observation::Conflict]);
        fs::set_permissions(
            &path,
            fs::Permissions::from_mode(manifest.entries[0].original.mode & 0o777),
        )
        .unwrap();
        fs::write(&path, b"edit").unwrap();
        assert_eq!(inspect(&root, &manifest).unwrap(), [Observation::Conflict]);
        fs::remove_file(&path).unwrap();
        assert_eq!(inspect(&root, &manifest).unwrap(), [Observation::Conflict]);
        symlink(CANDIDATE, &path).unwrap();
        assert_eq!(inspect(&root, &manifest).unwrap(), [Observation::Conflict]);
    }

    #[test]
    fn rejects_directory_symlinks_and_wrong_profile() {
        let dir = TestDir::new();
        let (root, manifest) = setup(&dir);
        fs::rename(dir.0.join("nested"), dir.0.join("saved")).unwrap();
        symlink("saved", dir.0.join("nested")).unwrap();
        assert!(inspect(&root, &manifest).is_err());
        let other = TestDir::new();
        assert!(inspect(&File::open(&other.0).unwrap(), &manifest).is_err());
    }

    #[test]
    fn persisted_manifest_can_be_reopened_and_inspected_without_changes() {
        let dir = TestDir::new();
        let (root, manifest) = setup(&dir);
        let journal = ".macshell-input-journal-0123456789abcdef0123456789abcdef".as_ref();
        assert!(matches!(
            crate::journal_store::create(&root, journal, &manifest).unwrap(),
            crate::journal_store::CreateResult::Durable
        ));
        drop(root);
        let reopened_root = File::open(&dir.0).unwrap();
        let reopened_manifest = crate::journal_store::read(&reopened_root, journal).unwrap();
        assert_eq!(
            inspect(&reopened_root, &reopened_manifest).unwrap(),
            [Observation::Original]
        );
        assert_eq!(fs::read(dir.0.join("nested/input.kdl")).unwrap(), b"old");
        assert_eq!(
            fs::read(dir.0.join("nested").join(CANDIDATE)).unwrap(),
            b"new"
        );
    }

    #[test]
    fn multi_file_partial_exchange_and_conflict_are_not_reported_as_complete() {
        use crate::journal_store::CreateResult;
        use crate::staging::StageResult;
        let dir = TestDir::new();
        let root = File::open(&dir.0).unwrap();
        let root_meta = root.metadata().unwrap();
        let mut entries = Vec::new();
        for target in ["a.kdl", "b.kdl"] {
            let path = dir.0.join(target);
            fs::write(&path, b"old").unwrap();
            let original = File::open(&path).unwrap();
            let StageResult::Ready(candidate) =
                crate::staging::stage(&root, target.as_ref(), &original, b"old", b"new").unwrap()
            else {
                panic!("staging failed")
            };
            entries.push(Entry {
                target: target.into(),
                candidate: candidate.name.to_str().unwrap().into(),
                original: version(&path),
                replacement: version(&dir.0.join(&candidate.name)),
            });
        }
        let manifest = Manifest {
            profile_device: root_meta.dev(),
            profile_inode: root_meta.ino(),
            entries,
        };
        let journal = ".macshell-input-journal-0123456789abcdef0123456789abcdef".as_ref();
        assert!(matches!(
            crate::journal_store::create(&root, journal, &manifest).unwrap(),
            CreateResult::Durable
        ));
        assert_eq!(
            inspect_report(&root, &manifest).unwrap().profile,
            ProfileObservation::AllOriginal
        );
        let exchange_entry = |entry: &Entry| {
            let original = File::open(dir.0.join(&entry.target)).unwrap();
            let replacement = File::open(dir.0.join(&entry.candidate)).unwrap();
            assert_eq!(
                crate::exchange::exchange(
                    &root,
                    entry.target.as_ref(),
                    entry.candidate.as_ref(),
                    crate::exchange::Expected {
                        original: &original,
                        replacement: &replacement,
                        original_bytes: b"old",
                        replacement_bytes: b"new",
                    }
                )
                .unwrap(),
                crate::exchange::ResultState::Exchanged
            );
        };
        exchange_entry(&manifest.entries[0]);
        let reopened = File::open(&dir.0).unwrap();
        let saved = crate::journal_store::read(&reopened, journal).unwrap();
        let report = inspect_report(&reopened, &saved).unwrap();
        assert_eq!(
            report.files,
            [Observation::Exchanged, Observation::Original]
        );
        assert_eq!(report.profile, ProfileObservation::PartiallyExchanged);
        exchange_entry(&manifest.entries[1]);
        assert_eq!(
            inspect_report(&reopened, &saved).unwrap().profile,
            ProfileObservation::AllExchanged
        );
        fs::write(dir.0.join(&manifest.entries[1].candidate), b"external edit").unwrap();
        let report = inspect_report(&reopened, &saved).unwrap();
        assert_eq!(
            report.files,
            [Observation::Exchanged, Observation::Conflict]
        );
        assert_eq!(report.profile, ProfileObservation::Conflict);
        assert_eq!(
            fs::read(dir.0.join(&manifest.entries[1].candidate)).unwrap(),
            b"external edit"
        );
        assert_eq!(fs::read(dir.0.join("a.kdl")).unwrap(), b"new");
    }

    #[test]
    fn progress_comparison_reports_pending_and_rejects_conflicts() {
        let dir = TestDir::new();
        let (root, manifest) = setup(&dir);
        let mut ledger = Ledger::new(&manifest).unwrap();
        let original = inspect_report(&root, &manifest).unwrap();
        assert_eq!(
            compare_progress(&manifest, None, &original).unwrap(),
            ProgressAgreement::Conflict
        );
        assert_eq!(
            compare_progress(&manifest, Some(&ledger), &original).unwrap(),
            ProgressAgreement::Consistent
        );
        ledger.push(Event::Intent(0)).unwrap();
        assert_eq!(
            compare_progress(&manifest, Some(&ledger), &original).unwrap(),
            ProgressAgreement::PendingExchange
        );
        let exchanged = Report {
            files: vec![Observation::Exchanged],
            profile: ProfileObservation::AllExchanged,
        };
        assert_eq!(
            compare_progress(&manifest, Some(&ledger), &exchanged).unwrap(),
            ProgressAgreement::PendingExchange
        );
        ledger.push(Event::Exchanged(0)).unwrap();
        assert_eq!(
            compare_progress(&manifest, Some(&ledger), &exchanged).unwrap(),
            ProgressAgreement::Consistent
        );
        assert_eq!(
            compare_progress(&manifest, Some(&ledger), &original).unwrap(),
            ProgressAgreement::Conflict
        );
        let conflict = Report {
            files: vec![Observation::Conflict],
            profile: ProfileObservation::Conflict,
        };
        assert_eq!(
            compare_progress(&manifest, Some(&ledger), &conflict).unwrap(),
            ProgressAgreement::Conflict
        );
        let mut changed = manifest.clone();
        changed.entries[0].original.bytes.push(1);
        assert!(compare_progress(&changed, Some(&ledger), &original).is_err());
    }

    #[test]
    fn reopened_journal_diagnoses_pending_exchange_and_external_edit() {
        use crate::{journal_store, progress_store};
        let dir = TestDir::new();
        let (root, manifest) = setup(&dir);
        let journal = OsStr::new(".macshell-input-journal-0123456789abcdef0123456789abcdef");
        assert!(matches!(
            journal_store::create(&root, journal, &manifest).unwrap(),
            journal_store::CreateResult::Durable
        ));
        let mut ledger = Ledger::new(&manifest).unwrap();
        assert!(matches!(
            progress_store::write(&root, journal, &manifest, &ledger).unwrap(),
            progress_store::WriteResult::Durable
        ));
        ledger.push(Event::Intent(0)).unwrap();
        assert!(matches!(
            progress_store::write(&root, journal, &manifest, &ledger).unwrap(),
            progress_store::WriteResult::Durable
        ));
        drop(root);
        let reopened = File::open(&dir.0).unwrap();
        let diagnostic = inspect_journal(&reopened, journal).unwrap();
        assert_eq!(diagnostic.agreement, ProgressAgreement::PendingExchange);
        assert_eq!(diagnostic.files.files, [Observation::Original]);
        fs::write(dir.0.join("nested/input.kdl"), b"external").unwrap();
        assert_eq!(
            inspect_journal(&reopened, journal).unwrap().agreement,
            ProgressAgreement::Conflict
        );
        fs::write(
            dir.0
                .join(format!("{}-progress-0001", journal.to_str().unwrap())),
            b"corrupt",
        )
        .unwrap();
        assert!(inspect_journal(&reopened, journal).is_err());
        assert_eq!(
            fs::read(dir.0.join("nested/input.kdl")).unwrap(),
            b"external"
        );
    }

    #[test]
    fn preflight_blocks_retained_journal_until_explicit_resolution() {
        let dir = TestDir::new();
        let (root, manifest) = setup(&dir);
        let journal = OsStr::new(".macshell-input-journal-0123456789abcdef0123456789abcdef");
        assert_eq!(preflight(&root, journal).unwrap(), Preflight::Clear);
        assert!(matches!(
            crate::journal_store::create(&root, journal, &manifest).unwrap(),
            crate::journal_store::CreateResult::Durable
        ));
        assert!(matches!(
            preflight(&root, journal).unwrap(),
            Preflight::Blocked(_)
        ));
    }

    #[test]
    fn cleanup_refuses_pending_state_and_preserves_artifacts() {
        use crate::{journal_store, progress_store};
        let dir = TestDir::new();
        let (root, manifest) = setup(&dir);
        let journal = OsStr::new(".macshell-input-journal-0123456789abcdef0123456789abcdef");
        assert!(matches!(
            journal_store::create(&root, journal, &manifest).unwrap(),
            journal_store::CreateResult::Durable
        ));
        let mut ledger = Ledger::new(&manifest).unwrap();
        assert!(matches!(
            progress_store::write(&root, journal, &manifest, &ledger).unwrap(),
            progress_store::WriteResult::Durable
        ));
        ledger.push(Event::Intent(0)).unwrap();
        assert!(matches!(
            progress_store::write(&root, journal, &manifest, &ledger).unwrap(),
            progress_store::WriteResult::Durable
        ));
        assert!(cleanup_completed(&dir.0, journal).is_err());
        assert!(dir.0.join(journal).is_file());
        assert!(dir.0.join(format!("nested/{CANDIDATE}")).is_file());
    }
}
