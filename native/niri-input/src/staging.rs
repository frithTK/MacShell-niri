//! Experimental preparation of one replacement file, not a transaction.
//! This writes a candidate and is not connected to the active profile.
use crate::exchange;
use std::ffi::{CString, OsStr, OsString};
use std::fs::File;
use std::io::{self, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::MetadataExt;

pub struct Staged {
    pub name: OsString,
    pub file: File,
}

pub enum StageResult {
    Ready(Staged),
    /// Creation happened; do not automatically delete this name.
    Incomplete {
        name: OsString,
        error: io::Error,
    },
}

fn candidate_name() -> io::Result<CString> {
    let mut bytes = [0u8; 16];
    let mut offset = 0;
    while offset < bytes.len() {
        let count = unsafe {
            libc::getrandom(bytes[offset..].as_mut_ptr().cast(), bytes.len() - offset, 0)
        };
        if count < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if count == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "Random source closed",
            ));
        }
        offset += count as usize;
    }
    let suffix: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    CString::new(format!(".macshell-input-{suffix}"))
        .map_err(|_| io::Error::other("Invalid candidate name"))
}

fn same_metadata(file: &File, before: &std::fs::Metadata) -> io::Result<bool> {
    let after = file.metadata()?;
    Ok(after.is_file()
        && after.dev() == before.dev()
        && after.ino() == before.ino()
        && after.uid() == before.uid()
        && after.gid() == before.gid()
        && after.mode() == before.mode()
        && after.nlink() == 1
        && after.size() == before.size()
        && after.mtime() == before.mtime()
        && after.mtime_nsec() == before.mtime_nsec()
        && after.ctime() == before.ctime()
        && after.ctime_nsec() == before.ctime_nsec())
}

/// Stage one replacement. The caller supplies a trusted open parent directory,
/// a readable original handle and snapshot bytes, and remains responsible for
/// the cooperative lock and comparison with the original profile snapshot.
/// Success means synchronization calls completed and checks matched; other
/// writers can still race checks or alter either file immediately afterwards.
pub fn stage(
    dir: &File,
    target: &OsStr,
    original: &File,
    before: &[u8],
    replacement: &[u8],
) -> io::Result<StageResult> {
    stage_with(
        dir,
        target,
        original,
        before,
        replacement,
        (|| {}, File::sync_all, File::sync_all),
    )
}

fn stage_with(
    dir: &File,
    target: &OsStr,
    original: &File,
    before: &[u8],
    replacement: &[u8],
    hooks: (
        impl FnOnce(),
        impl FnOnce(&File) -> io::Result<()>,
        impl FnOnce(&File) -> io::Result<()>,
    ),
) -> io::Result<StageResult> {
    let (after_create, sync_file, sync_directory) = hooks;
    if replacement.len() > 2 * 1024 * 1024 {
        return Err(io::Error::other("Candidate too large"));
    }
    let target = exchange::name(target)?;
    let metadata = original.metadata()?;
    if !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o7000 != 0
        || !exchange::same_regular(&exchange::at(dir, &target)?, original)?
        || !exchange::matches_bytes(original, before)?
        || !exchange::no_extended_attributes(original)?
    {
        return Err(io::Error::other("Original is unsupported or changed"));
    }
    let name = candidate_name()?;
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
    let candidate: OsString = std::os::unix::ffi::OsStringExt::from_vec(name.as_bytes().to_vec());
    let write = (|| -> io::Result<()> {
        after_create();
        if unsafe { libc::fchown(file.as_raw_fd(), metadata.uid(), metadata.gid()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        if unsafe { libc::fchmod(file.as_raw_fd(), metadata.mode() & 0o777) } != 0 {
            return Err(io::Error::last_os_error());
        }
        if !exchange::no_extended_attributes(&file)? {
            return Err(io::Error::other("Candidate has extended attributes"));
        }
        file.write_all(replacement)?;
        sync_file(&file)?;
        let verify = || -> io::Result<()> {
            let current = file.metadata()?;
            if !current.is_file()
                || current.nlink() != 1
                || current.uid() != metadata.uid()
                || current.gid() != metadata.gid()
                || current.mode() != metadata.mode()
                || !exchange::same_regular(&exchange::at(dir, &name)?, &file)?
                || !exchange::matches_bytes(&file, replacement)?
                || !exchange::no_extended_attributes(&file)?
                || !same_metadata(original, &metadata)?
                || !exchange::same_regular(&exchange::at(dir, &target)?, original)?
                || !exchange::matches_bytes(original, before)?
                || !exchange::no_extended_attributes(original)?
            {
                return Err(io::Error::other(
                    "File or attributes changed during staging",
                ));
            }
            Ok(())
        };
        verify()?;
        sync_directory(dir)?;
        verify()?;
        Ok(())
    })();
    Ok(match write {
        Ok(()) => StageResult::Ready(Staged {
            name: candidate,
            file,
        }),
        Err(error) => StageResult::Incomplete {
            name: candidate,
            error,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct TestDir(std::path::PathBuf);
    impl TestDir {
        fn new() -> Self {
            static ID: AtomicUsize = AtomicUsize::new(0);
            let path = std::env::temp_dir().join(format!(
                "macshell-staging-{}-{}",
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

    #[test]
    fn stages_and_syncs_replacement_with_matching_permissions() {
        let dir = TestDir::new();
        let path = dir.0.join("input.kdl");
        fs::write(&path, b"old").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
        let parent = File::open(&dir.0).unwrap();
        let original = File::open(&path).unwrap();
        let result = stage(&parent, OsStr::new("input.kdl"), &original, b"old", b"new").unwrap();
        let StageResult::Ready(staged) = result else {
            panic!("staging failed")
        };
        assert_eq!(fs::read(&path).unwrap(), b"old");
        assert_eq!(fs::read(dir.0.join(&staged.name)).unwrap(), b"new");
        assert_eq!(staged.file.metadata().unwrap().mode() & 0o777, 0o640);
        assert!(staged
            .name
            .to_str()
            .unwrap()
            .starts_with(".macshell-input-"));
    }

    #[test]
    fn refuses_stale_original_and_symlink() {
        let dir = TestDir::new();
        fs::write(dir.0.join("input.kdl"), b"old").unwrap();
        symlink("input.kdl", dir.0.join("link.kdl")).unwrap();
        let parent = File::open(&dir.0).unwrap();
        let original = File::open(dir.0.join("input.kdl")).unwrap();
        assert!(stage(
            &parent,
            OsStr::new("input.kdl"),
            &original,
            b"wrong",
            b"new"
        )
        .is_err());
        assert!(stage(&parent, OsStr::new("link.kdl"), &original, b"old", b"new").is_err());
        assert_eq!(fs::read(dir.0.join("input.kdl")).unwrap(), b"old");
    }

    #[test]
    fn retains_candidate_when_original_changes_or_sync_fails() {
        for conflict in [true, false] {
            let dir = TestDir::new();
            let path = dir.0.join("input.kdl");
            fs::write(&path, b"old").unwrap();
            let parent = File::open(&dir.0).unwrap();
            let original = File::open(&path).unwrap();
            let result = stage_with(
                &parent,
                OsStr::new("input.kdl"),
                &original,
                b"old",
                b"new",
                (
                    || {
                        if conflict {
                            fs::write(&path, b"external").unwrap();
                        }
                    },
                    File::sync_all,
                    |f| {
                        if conflict {
                            f.sync_all()
                        } else {
                            Err(io::Error::other("injected directory fsync failure"))
                        }
                    },
                ),
            )
            .unwrap();
            let StageResult::Incomplete { name, .. } = result else {
                panic!("expected incomplete")
            };
            assert_eq!(fs::read(dir.0.join(name)).unwrap(), b"new");
            assert_eq!(
                fs::read(path).unwrap(),
                if conflict {
                    b"external".as_slice()
                } else {
                    b"old"
                }
            );
        }
    }

    #[test]
    fn staged_file_manifest_exchange_and_reopen_on_temporary_profile() {
        use crate::journal::{Entry, FileVersion, Manifest};
        let dir = TestDir::new();
        let path = dir.0.join("input.kdl");
        fs::write(&path, b"old").unwrap();
        let parent = File::open(&dir.0).unwrap();
        let original = File::open(&path).unwrap();
        let StageResult::Ready(staged) =
            stage(&parent, OsStr::new("input.kdl"), &original, b"old", b"new").unwrap()
        else {
            panic!("stage failed")
        };
        let file_version = |file: &File, bytes: &[u8]| {
            let m = file.metadata().unwrap();
            FileVersion {
                device: m.dev(),
                inode: m.ino(),
                mode: m.mode(),
                uid: m.uid(),
                gid: m.gid(),
                nlink: m.nlink(),
                bytes: bytes.to_vec(),
            }
        };
        let root = parent.metadata().unwrap();
        let manifest = Manifest {
            profile_device: root.dev(),
            profile_inode: root.ino(),
            entries: vec![Entry {
                target: "input.kdl".into(),
                candidate: staged.name.to_str().unwrap().into(),
                original: file_version(&original, b"old"),
                replacement: file_version(&staged.file, b"new"),
            }],
        };
        let journal = OsStr::new(".macshell-input-journal-0123456789abcdef0123456789abcdef");
        assert!(matches!(
            crate::journal_store::create(&parent, journal, &manifest).unwrap(),
            crate::journal_store::CreateResult::Durable
        ));
        assert_eq!(
            crate::exchange::exchange(
                &parent,
                OsStr::new("input.kdl"),
                &staged.name,
                crate::exchange::Expected {
                    original: &original,
                    replacement: &staged.file,
                    original_bytes: b"old",
                    replacement_bytes: b"new"
                }
            )
            .unwrap(),
            crate::exchange::ResultState::Exchanged
        );
        drop(original);
        drop(staged.file);
        let saved = crate::journal_store::read(&parent, journal).unwrap();
        assert_eq!(
            crate::recovery::inspect(&parent, &saved).unwrap(),
            [crate::recovery::Observation::Exchanged]
        );
        assert_eq!(fs::read(path).unwrap(), b"new");
        assert_eq!(fs::read(dir.0.join(staged.name)).unwrap(), b"old");
    }
}
