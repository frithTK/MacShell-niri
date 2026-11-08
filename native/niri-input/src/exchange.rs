//! Experimental single-directory file exchange. This is not a transaction.
//!
//! Both names are retained. A successful exchange is atomic, but checking a
//! pathname and exchanging it cannot be made into a filesystem compare/swap.
//! Concurrent writers can change the names between these operations. The
//! caller must treat uncertainty as requiring recovery and retain both files.
use std::ffi::{CString, OsStr};
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileExt, MetadataExt};
use std::path::{Component, Path};

#[derive(Debug, PartialEq, Eq)]
pub enum ResultState {
    /// Both names resolved to the expected inodes after the exchange and the
    /// contents matched, and the directory was synced. Later races remain.
    Exchanged,
    /// The exchange happened but one or both names could not be verified.
    /// Do not delete either name or automatically overwrite either file.
    Uncertain,
    /// The names matched after exchange but syncing the directory failed.
    DurabilityUnknown,
}

pub(crate) fn name(value: &OsStr) -> io::Result<CString> {
    let mut components = Path::new(value).components();
    if !matches!(components.next(), Some(Component::Normal(_))) || components.next().is_some() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Expected a single file name",
        ));
    }
    CString::new(value.as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "Invalid filename"))
}

pub(crate) fn at(dir: &File, path: &CString) -> io::Result<File> {
    let fd = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            path.as_ptr(),
            libc::O_PATH | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

pub(crate) fn same_regular(left: &File, right: &File) -> io::Result<bool> {
    let a = left.metadata()?;
    let b = right.metadata()?;
    Ok(a.is_file()
        && b.is_file()
        && a.nlink() == 1
        && b.nlink() == 1
        && a.dev() == b.dev()
        && a.ino() == b.ino())
}

#[derive(PartialEq, Eq)]
struct Attributes {
    mode: u32,
    uid: u32,
    gid: u32,
    nlink: u64,
}

fn attributes(file: &File) -> io::Result<Attributes> {
    let metadata = file.metadata()?;
    Ok(Attributes {
        mode: metadata.mode(),
        uid: metadata.uid(),
        gid: metadata.gid(),
        nlink: metadata.nlink(),
    })
}

// Linux ACLs are represented by extended attributes. Reject visible xattrs until
// the transaction can preserve them, including security labels. Listing may
// omit attributes not visible to the caller, and is subject to races. An
// unsupported or inaccessible xattr interface is an error, not evidence
// that the file has none.
pub(crate) fn no_extended_attributes(file: &File) -> io::Result<bool> {
    let count = unsafe { libc::flistxattr(file.as_raw_fd(), std::ptr::null_mut(), 0) };
    if count < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(count == 0)
}

pub(crate) fn matches_bytes(file: &File, expected: &[u8]) -> io::Result<bool> {
    if expected.len() > 2 * 1024 * 1024 {
        return Ok(false);
    }
    let before = file.metadata()?;
    if !before.is_file() || before.len() != expected.len() as u64 {
        return Ok(false);
    }
    let mut offset = 0;
    let mut buffer = [0u8; 8192];
    while offset < expected.len() {
        let size = buffer.len().min(expected.len() - offset);
        let n = file.read_at(&mut buffer[..size], offset as u64)?;
        if n == 0 || buffer[..n] != expected[offset..offset + n] {
            return Ok(false);
        }
        offset += n;
    }
    let after = file.metadata()?;
    Ok(before.dev() == after.dev()
        && before.ino() == after.ino()
        && before.size() == after.size()
        && before.mtime() == after.mtime()
        && before.mtime_nsec() == after.mtime_nsec()
        && before.ctime() == after.ctime()
        && before.ctime_nsec() == after.ctime_nsec())
}

pub struct Expected<'a> {
    pub original: &'a File,
    pub replacement: &'a File,
    pub original_bytes: &'a [u8],
    pub replacement_bytes: &'a [u8],
}

/// A point-in-time observation, not permission to modify either pathname.
/// Other writers may change either file immediately after inspection.
#[derive(Debug, PartialEq, Eq)]
pub enum ObservedState {
    Original,
    Exchanged,
    Conflict,
}

/// Inspect both names against the still-open handles and exact saved contents.
/// Missing names, changed contents, links, and unexpected inodes are conflicts.
/// This does not establish a consistent multi-file snapshot or recover after a
/// process restart: open handles and expected bytes must be supplied by the
/// caller, and any later action needs independent validation.
pub fn inspect(
    dir: &File,
    target: &OsStr,
    candidate: &OsStr,
    expected: Expected<'_>,
) -> io::Result<ObservedState> {
    if target == candidate {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Names must differ",
        ));
    }
    let target = name(target)?;
    let candidate = name(candidate)?;
    let observed = (|| -> io::Result<ObservedState> {
        let first = at(dir, &target)?;
        let second = at(dir, &candidate)?;
        if !matches_bytes(expected.original, expected.original_bytes)?
            || !matches_bytes(expected.replacement, expected.replacement_bytes)?
        {
            return Ok(ObservedState::Conflict);
        }
        if same_regular(&first, expected.original)? && same_regular(&second, expected.replacement)?
        {
            Ok(ObservedState::Original)
        } else if same_regular(&first, expected.replacement)?
            && same_regular(&second, expected.original)?
        {
            Ok(ObservedState::Exchanged)
        } else {
            Ok(ObservedState::Conflict)
        }
    })();
    match observed {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(ObservedState::Conflict),
        result => result,
    }
}

/// Exchange two existing regular files, keeping both names. `original` and
/// `replacement` are already-open readable handles for the expected inodes;
/// the caller must sync the replacement contents before calling, check the
/// attributes against its snapshot, and arrange appropriate replacement
/// attributes. Mode, owner, group and link count are also checked across the
/// exchange. Files with visible extended attributes (including Linux ACLs) are
/// rejected until preservation is implemented. This cannot prove the absence
/// of hidden attributes or prevent races. An error
/// means no exchange was issued or the kernel reported it failed; callers
/// should still inspect both names before recovery. `Uncertain` means the
/// kernel reported success but verification failed.
pub fn exchange(
    dir: &File,
    target: &OsStr,
    candidate: &OsStr,
    expected: Expected<'_>,
) -> io::Result<ResultState> {
    exchange_with(dir, target, candidate, expected, || {})
}

fn exchange_with(
    dir: &File,
    target: &OsStr,
    candidate: &OsStr,
    expected: Expected<'_>,
    before: impl FnOnce(),
) -> io::Result<ResultState> {
    exchange_with_sync(dir, target, candidate, expected, before, File::sync_all)
}

fn exchange_with_sync(
    dir: &File,
    target: &OsStr,
    candidate: &OsStr,
    expected: Expected<'_>,
    before: impl FnOnce(),
    sync_directory: impl FnOnce(&File) -> io::Result<()>,
) -> io::Result<ResultState> {
    if target == candidate {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Names must differ",
        ));
    }
    let target = name(target)?;
    let candidate = name(candidate)?;
    let original_attributes = attributes(expected.original)?;
    let replacement_attributes = attributes(expected.replacement)?;
    if !same_regular(&at(dir, &target)?, expected.original)?
        || !same_regular(&at(dir, &candidate)?, expected.replacement)?
        || !matches_bytes(expected.original, expected.original_bytes)?
        || !matches_bytes(expected.replacement, expected.replacement_bytes)?
        || !no_extended_attributes(expected.original)?
        || !no_extended_attributes(expected.replacement)?
    {
        return Err(io::Error::other("File changed before exchange"));
    }
    before();
    let status = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            dir.as_raw_fd(),
            target.as_ptr(),
            dir.as_raw_fd(),
            candidate.as_ptr(),
            libc::RENAME_EXCHANGE,
        )
    };
    if status != 0 {
        return Err(io::Error::last_os_error());
    }
    let confirmed = (|| -> io::Result<bool> {
        Ok(same_regular(&at(dir, &target)?, expected.replacement)?
            && same_regular(&at(dir, &candidate)?, expected.original)?
            && matches_bytes(expected.original, expected.original_bytes)?
            && matches_bytes(expected.replacement, expected.replacement_bytes)?
            && attributes(expected.original)? == original_attributes
            && attributes(expected.replacement)? == replacement_attributes
            && no_extended_attributes(expected.original)?
            && no_extended_attributes(expected.replacement)?)
    })()
    .unwrap_or(false);
    if !confirmed {
        return Ok(ResultState::Uncertain);
    }
    if sync_directory(dir).is_err() {
        return Ok(ResultState::DurabilityUnknown);
    }
    Ok(ResultState::Exchanged)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::{self, OpenOptions};
    use std::sync::atomic::{AtomicUsize, Ordering};
    struct TestDir(std::path::PathBuf);
    impl TestDir {
        fn new() -> Self {
            static COUNTER: AtomicUsize = AtomicUsize::new(0);
            let path = std::env::temp_dir().join(format!(
                "macshell-input-exchange-{}-{}",
                std::process::id(),
                COUNTER.fetch_add(1, Ordering::Relaxed)
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
    #[test]
    fn atomic_exchange_retains_both_versions_and_can_be_reversed() {
        let dir = TestDir::new();
        fs::write(dir.0.join("target"), b"original").unwrap();
        fs::write(dir.0.join("candidate"), b"new").unwrap();
        let parent = File::open(&dir.0).unwrap();
        let original = File::open(dir.0.join("target")).unwrap();
        let replacement = File::open(dir.0.join("candidate")).unwrap();
        assert_eq!(
            exchange(
                &parent,
                OsStr::new("target"),
                OsStr::new("candidate"),
                Expected {
                    original: &original,
                    replacement: &replacement,
                    original_bytes: b"original",
                    replacement_bytes: b"new"
                }
            )
            .unwrap(),
            ResultState::Exchanged
        );
        assert_eq!(fs::read(dir.0.join("target")).unwrap(), b"new");
        assert_eq!(fs::read(dir.0.join("candidate")).unwrap(), b"original");
        assert_eq!(
            exchange(
                &parent,
                OsStr::new("target"),
                OsStr::new("candidate"),
                Expected {
                    original: &replacement,
                    replacement: &original,
                    original_bytes: b"new",
                    replacement_bytes: b"original"
                }
            )
            .unwrap(),
            ResultState::Exchanged
        );
        assert_eq!(fs::read(dir.0.join("target")).unwrap(), b"original");
    }
    #[test]
    fn stale_before_exchange_does_not_change_any_name() {
        let dir = TestDir::new();
        fs::write(dir.0.join("target"), b"old").unwrap();
        fs::write(dir.0.join("candidate"), b"new").unwrap();
        let parent = File::open(&dir.0).unwrap();
        let original = File::open(dir.0.join("target")).unwrap();
        let replacement = File::open(dir.0.join("candidate")).unwrap();
        fs::rename(dir.0.join("target"), dir.0.join("saved")).unwrap();
        fs::write(dir.0.join("target"), b"external").unwrap();
        assert!(exchange(
            &parent,
            OsStr::new("target"),
            OsStr::new("candidate"),
            Expected {
                original: &original,
                replacement: &replacement,
                original_bytes: b"old",
                replacement_bytes: b"new"
            }
        )
        .is_err());
        assert_eq!(fs::read(dir.0.join("target")).unwrap(), b"external");
        assert_eq!(fs::read(dir.0.join("candidate")).unwrap(), b"new");
    }
    #[test]
    fn race_after_check_reports_uncertainty_and_preserves_versions() {
        let dir = TestDir::new();
        fs::write(dir.0.join("target"), b"old").unwrap();
        fs::write(dir.0.join("candidate"), b"new").unwrap();
        let parent = File::open(&dir.0).unwrap();
        let original = File::open(dir.0.join("target")).unwrap();
        let replacement = File::open(dir.0.join("candidate")).unwrap();
        let result = exchange_with(
            &parent,
            OsStr::new("target"),
            OsStr::new("candidate"),
            Expected {
                original: &original,
                replacement: &replacement,
                original_bytes: b"old",
                replacement_bytes: b"new",
            },
            || {
                fs::rename(dir.0.join("target"), dir.0.join("saved")).unwrap();
                let mut file = OpenOptions::new()
                    .create_new(true)
                    .write(true)
                    .open(dir.0.join("target"))
                    .unwrap();
                std::io::Write::write_all(&mut file, b"external").unwrap();
            },
        )
        .unwrap();
        assert_eq!(result, ResultState::Uncertain);
        assert_eq!(fs::read(dir.0.join("target")).unwrap(), b"new");
        assert_eq!(fs::read(dir.0.join("candidate")).unwrap(), b"external");
        assert_eq!(fs::read(dir.0.join("saved")).unwrap(), b"old");
    }
    #[test]
    fn detects_in_place_edit_during_exchange() {
        let dir = TestDir::new();
        fs::write(dir.0.join("target"), b"old").unwrap();
        fs::write(dir.0.join("candidate"), b"new").unwrap();
        let parent = File::open(&dir.0).unwrap();
        let original = File::open(dir.0.join("target")).unwrap();
        let replacement = File::open(dir.0.join("candidate")).unwrap();
        let result = exchange_with(
            &parent,
            OsStr::new("target"),
            OsStr::new("candidate"),
            Expected {
                original: &original,
                replacement: &replacement,
                original_bytes: b"old",
                replacement_bytes: b"new",
            },
            || fs::write(dir.0.join("target"), b"edited").unwrap(),
        )
        .unwrap();
        assert_eq!(result, ResultState::Uncertain);
        assert_eq!(fs::read(dir.0.join("target")).unwrap(), b"new");
        assert_eq!(fs::read(dir.0.join("candidate")).unwrap(), b"edited");
    }

    #[test]
    fn detects_permission_change_during_exchange() {
        use std::os::unix::fs::PermissionsExt;
        let dir = TestDir::new();
        fs::write(dir.0.join("target"), b"old").unwrap();
        fs::write(dir.0.join("candidate"), b"new").unwrap();
        fs::set_permissions(dir.0.join("target"), fs::Permissions::from_mode(0o600)).unwrap();
        let parent = File::open(&dir.0).unwrap();
        let original = File::open(dir.0.join("target")).unwrap();
        let replacement = File::open(dir.0.join("candidate")).unwrap();
        let state = exchange_with(
            &parent,
            OsStr::new("target"),
            OsStr::new("candidate"),
            Expected {
                original: &original,
                replacement: &replacement,
                original_bytes: b"old",
                replacement_bytes: b"new",
            },
            || {
                fs::set_permissions(dir.0.join("target"), fs::Permissions::from_mode(0o640))
                    .unwrap()
            },
        )
        .unwrap();
        assert_eq!(state, ResultState::Uncertain);
        assert_eq!(fs::read(dir.0.join("target")).unwrap(), b"new");
        assert_eq!(fs::read(dir.0.join("candidate")).unwrap(), b"old");
        assert_eq!(
            fs::metadata(dir.0.join("candidate"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o640
        );
    }

    #[test]
    fn rejects_existing_extended_attributes_and_detects_new_ones() {
        let dir = TestDir::new();
        fs::write(dir.0.join("target"), b"old").unwrap();
        fs::write(dir.0.join("candidate"), b"new").unwrap();
        let parent = File::open(&dir.0).unwrap();
        let original = File::open(dir.0.join("target")).unwrap();
        let replacement = File::open(dir.0.join("candidate")).unwrap();
        let attr = c"user.macshell-test";
        let set = || unsafe {
            libc::fsetxattr(
                original.as_raw_fd(),
                attr.as_ptr(),
                b"test".as_ptr().cast(),
                4,
                0,
            )
        };
        if set() != 0 {
            let error = io::Error::last_os_error();
            if matches!(error.raw_os_error(), Some(libc::EOPNOTSUPP | libc::EPERM)) {
                return;
            }
            panic!("could not set test xattr: {error}");
        }
        let expected = || Expected {
            original: &original,
            replacement: &replacement,
            original_bytes: b"old",
            replacement_bytes: b"new",
        };
        assert!(exchange(
            &parent,
            OsStr::new("target"),
            OsStr::new("candidate"),
            expected()
        )
        .is_err());
        assert_eq!(fs::read(dir.0.join("target")).unwrap(), b"old");
        assert_eq!(
            unsafe { libc::fremovexattr(original.as_raw_fd(), attr.as_ptr()) },
            0
        );
        let state = exchange_with(
            &parent,
            OsStr::new("target"),
            OsStr::new("candidate"),
            expected(),
            || assert_eq!(set(), 0),
        )
        .unwrap();
        assert_eq!(state, ResultState::Uncertain);
        assert_eq!(fs::read(dir.0.join("target")).unwrap(), b"new");
        assert_eq!(fs::read(dir.0.join("candidate")).unwrap(), b"old");
        assert!(!no_extended_attributes(&original).unwrap());
    }
    #[test]
    fn rejects_symlink_and_content_change_before_exchange() {
        use std::os::unix::fs::symlink;
        let dir = TestDir::new();
        fs::write(dir.0.join("target"), b"old").unwrap();
        fs::write(dir.0.join("candidate"), b"new").unwrap();
        let parent = File::open(&dir.0).unwrap();
        let original = File::open(dir.0.join("target")).unwrap();
        let replacement = File::open(dir.0.join("candidate")).unwrap();
        fs::write(dir.0.join("target"), b"edited").unwrap();
        let expected = || Expected {
            original: &original,
            replacement: &replacement,
            original_bytes: b"old",
            replacement_bytes: b"new",
        };
        assert!(exchange(
            &parent,
            OsStr::new("target"),
            OsStr::new("candidate"),
            expected()
        )
        .is_err());
        assert_eq!(fs::read(dir.0.join("target")).unwrap(), b"edited");
        fs::rename(dir.0.join("candidate"), dir.0.join("saved")).unwrap();
        symlink("saved", dir.0.join("candidate")).unwrap();
        assert!(exchange(
            &parent,
            OsStr::new("target"),
            OsStr::new("candidate"),
            expected()
        )
        .is_err());
        assert_eq!(fs::read(dir.0.join("saved")).unwrap(), b"new");
    }

    #[test]
    fn inspection_distinguishes_exchange_from_conflicts_without_writing() {
        let dir = TestDir::new();
        fs::write(dir.0.join("target"), b"old").unwrap();
        fs::write(dir.0.join("candidate"), b"new").unwrap();
        let parent = File::open(&dir.0).unwrap();
        let original = File::open(dir.0.join("target")).unwrap();
        let replacement = File::open(dir.0.join("candidate")).unwrap();
        let expected = || Expected {
            original: &original,
            replacement: &replacement,
            original_bytes: b"old",
            replacement_bytes: b"new",
        };
        let inspect_now = || {
            inspect(
                &parent,
                OsStr::new("target"),
                OsStr::new("candidate"),
                expected(),
            )
            .unwrap()
        };
        assert_eq!(inspect_now(), ObservedState::Original);
        assert_eq!(
            exchange(
                &parent,
                OsStr::new("target"),
                OsStr::new("candidate"),
                expected()
            )
            .unwrap(),
            ResultState::Exchanged
        );
        assert_eq!(inspect_now(), ObservedState::Exchanged);
        fs::write(dir.0.join("candidate"), b"edited").unwrap();
        assert_eq!(inspect_now(), ObservedState::Conflict);
        assert_eq!(fs::read(dir.0.join("target")).unwrap(), b"new");
        assert_eq!(fs::read(dir.0.join("candidate")).unwrap(), b"edited");
        fs::remove_file(dir.0.join("candidate")).unwrap();
        assert_eq!(inspect_now(), ObservedState::Conflict);
    }

    #[test]
    fn inspection_rejects_substitution_even_with_identical_content() {
        let dir = TestDir::new();
        fs::write(dir.0.join("target"), b"same").unwrap();
        fs::write(dir.0.join("candidate"), b"same").unwrap();
        let parent = File::open(&dir.0).unwrap();
        let original = File::open(dir.0.join("target")).unwrap();
        let replacement = File::open(dir.0.join("candidate")).unwrap();
        let expected = || Expected {
            original: &original,
            replacement: &replacement,
            original_bytes: b"same",
            replacement_bytes: b"same",
        };
        assert_eq!(
            inspect(
                &parent,
                OsStr::new("target"),
                OsStr::new("candidate"),
                expected()
            )
            .unwrap(),
            ObservedState::Original
        );
        fs::rename(dir.0.join("candidate"), dir.0.join("saved")).unwrap();
        fs::write(dir.0.join("candidate"), b"same").unwrap();
        assert_eq!(
            inspect(
                &parent,
                OsStr::new("target"),
                OsStr::new("candidate"),
                expected()
            )
            .unwrap(),
            ObservedState::Conflict
        );
        assert_eq!(fs::read(dir.0.join("saved")).unwrap(), b"same");
    }

    #[test]
    fn sync_failure_reports_unknown_durability_and_keeps_both_versions() {
        let dir = TestDir::new();
        fs::write(dir.0.join("target"), b"old").unwrap();
        fs::write(dir.0.join("candidate"), b"new").unwrap();
        let parent = File::open(&dir.0).unwrap();
        let original = File::open(dir.0.join("target")).unwrap();
        let replacement = File::open(dir.0.join("candidate")).unwrap();
        let state = exchange_with_sync(
            &parent,
            OsStr::new("target"),
            OsStr::new("candidate"),
            Expected {
                original: &original,
                replacement: &replacement,
                original_bytes: b"old",
                replacement_bytes: b"new",
            },
            || {},
            |_| Err(io::Error::other("injected fsync failure")),
        )
        .unwrap();
        assert_eq!(state, ResultState::DurabilityUnknown);
        assert_eq!(fs::read(dir.0.join("target")).unwrap(), b"new");
        assert_eq!(fs::read(dir.0.join("candidate")).unwrap(), b"old");
    }

    #[test]
    fn missing_candidate_at_syscall_preserves_target_and_reports_error() {
        let dir = TestDir::new();
        fs::write(dir.0.join("target"), b"old").unwrap();
        fs::write(dir.0.join("candidate"), b"new").unwrap();
        let parent = File::open(&dir.0).unwrap();
        let original = File::open(dir.0.join("target")).unwrap();
        let replacement = File::open(dir.0.join("candidate")).unwrap();
        let error = exchange_with(
            &parent,
            OsStr::new("target"),
            OsStr::new("candidate"),
            Expected {
                original: &original,
                replacement: &replacement,
                original_bytes: b"old",
                replacement_bytes: b"new",
            },
            || fs::rename(dir.0.join("candidate"), dir.0.join("moved")).unwrap(),
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::NotFound);
        assert_eq!(fs::read(dir.0.join("target")).unwrap(), b"old");
        assert_eq!(fs::read(dir.0.join("moved")).unwrap(), b"new");
    }
}
