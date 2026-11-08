//! Experimental single-manifest persistence, not a transaction or recovery.
//! A partial file is deliberately retained after any failure following create.
use crate::journal::{Manifest, MAX_ENCODED};
use std::ffi::{CString, OsStr};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::FileExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

pub enum CreateResult {
    /// File contents and parent directory were synchronized successfully.
    Durable,
    /// A file was created but is not known durable. Retain it for inspection.
    Incomplete(io::Error),
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

pub(crate) fn journal_name(name: &OsStr) -> io::Result<CString> {
    let raw = name.as_bytes();
    let suffix = raw
        .strip_prefix(b".macshell-input-journal-")
        .ok_or_else(|| invalid("Invalid journal name"))?;
    if suffix.len() != 32
        || !suffix
            .iter()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
    {
        return Err(invalid("Invalid journal name"));
    }
    CString::new(raw).map_err(|_| invalid("Invalid journal name"))
}

pub(crate) fn check_directory(dir: &File, device: u64, inode: u64) -> io::Result<()> {
    let metadata = dir.metadata()?;
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o022 != 0
        || metadata.dev() != device
        || metadata.ino() != inode
    {
        return Err(invalid("Untrusted or changed journal directory"));
    }
    Ok(())
}

pub(crate) fn check_file(file: &File) -> io::Result<std::fs::Metadata> {
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o7777 != 0o600
        || metadata.nlink() != 1
        || metadata.size() > MAX_ENCODED as u64
    {
        return Err(invalid("Untrusted journal file"));
    }
    Ok(metadata)
}

pub(crate) fn verify_created(
    dir: &File,
    name: &CString,
    file: &File,
    bytes: &[u8],
) -> io::Result<()> {
    let before = check_file(file)?;
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
    let path = unsafe { File::from_raw_fd(fd) };
    let named = check_file(&path)?;
    if before.dev() != named.dev()
        || before.ino() != named.ino()
        || before.size() != bytes.len() as u64
    {
        return Err(invalid("Journal pathname or size changed"));
    }
    let mut offset = 0;
    let mut buffer = [0u8; 8192];
    while offset < bytes.len() {
        let count = buffer.len().min(bytes.len() - offset);
        let n = file.read_at(&mut buffer[..count], offset as u64)?;
        if n == 0 || buffer[..n] != bytes[offset..offset + n] {
            return Err(invalid("Journal contents changed"));
        }
        offset += n;
    }
    let after = check_file(file)?;
    if before.dev() != after.dev()
        || before.ino() != after.ino()
        || before.size() != after.size()
        || before.mtime() != after.mtime()
        || before.mtime_nsec() != after.mtime_nsec()
        || before.ctime() != after.ctime()
        || before.ctime_nsec() != after.ctime_nsec()
    {
        return Err(invalid("Journal changed during verification"));
    }
    Ok(())
}

/// Create a new private manifest without overwriting any existing pathname.
/// The caller must hold the lock and maintain its own profile identity checks.
/// A crash or `Incomplete` may leave a partial file. Never delete or use it
/// automatically. A durable manifest is not proof that an exchange happened.
pub fn create(dir: &File, name: &OsStr, manifest: &Manifest) -> io::Result<CreateResult> {
    create_with(dir, name, manifest, File::sync_all, File::sync_all)
}

fn create_with(
    dir: &File,
    name: &OsStr,
    manifest: &Manifest,
    sync_file: impl FnOnce(&File) -> io::Result<()>,
    sync_directory: impl FnOnce(&File) -> io::Result<()>,
) -> io::Result<CreateResult> {
    let bytes = manifest.encode().map_err(|_| invalid("Invalid manifest"))?;
    let name = journal_name(name)?;
    check_directory(dir, manifest.profile_device, manifest.profile_inode)?;
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
    let persist = (|| -> io::Result<()> {
        if unsafe { libc::fchmod(file.as_raw_fd(), 0o600) } != 0 {
            return Err(io::Error::last_os_error());
        }
        check_file(&file)?;
        file.write_all(&bytes)?;
        sync_file(&file)?;
        verify_created(dir, &name, &file, &bytes)?;
        check_directory(dir, manifest.profile_device, manifest.profile_inode)?;
        sync_directory(dir)?;
        verify_created(dir, &name, &file, &bytes)?;
        Ok(())
    })();
    Ok(match persist {
        Ok(()) => CreateResult::Durable,
        Err(error) => CreateResult::Incomplete(error),
    })
}

/// Read a private regular file via its verified inode. File ownership, mode,
/// contents and directory identity are checked; this is still a racy
/// observation and provides no authenticity or authorization for recovery.
pub fn read(dir: &File, name: &OsStr) -> io::Result<Manifest> {
    let name = journal_name(name)?;
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
    let before = check_file(&handle)?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(format!("/proc/self/fd/{}", handle.as_raw_fd()))?;
    let opened = check_file(&file)?;
    if before.dev() != opened.dev() || before.ino() != opened.ino() {
        return Err(invalid("Journal changed while opening"));
    }
    let mut bytes = Vec::new();
    (&file)
        .take(MAX_ENCODED as u64 + 1)
        .read_to_end(&mut bytes)?;
    let after = check_file(&file)?;
    if bytes.len() > MAX_ENCODED
        || opened.dev() != after.dev()
        || opened.ino() != after.ino()
        || opened.size() != after.size()
        || opened.mtime() != after.mtime()
        || opened.mtime_nsec() != after.mtime_nsec()
        || opened.ctime() != after.ctime()
        || opened.ctime_nsec() != after.ctime_nsec()
    {
        return Err(invalid("Journal changed while reading"));
    }
    let manifest = Manifest::decode(&bytes).map_err(|_| invalid("Invalid manifest"))?;
    check_directory(dir, manifest.profile_device, manifest.profile_inode)?;
    Ok(manifest)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::journal::{Entry, FileVersion};
    use std::fs;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct TestDir(std::path::PathBuf);
    impl TestDir {
        fn new() -> Self {
            static ID: AtomicUsize = AtomicUsize::new(0);
            let path = std::env::temp_dir().join(format!(
                "macshell-journal-store-{}-{}",
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
    const NAME: &str = ".macshell-input-journal-0123456789abcdef0123456789abcdef";
    fn sample(dir: &File) -> Manifest {
        let m = dir.metadata().unwrap();
        let version = |inode, bytes: &[u8]| FileVersion {
            device: m.dev(),
            inode,
            mode: libc::S_IFREG | 0o600,
            uid: m.uid(),
            gid: m.gid(),
            nlink: 1,
            bytes: bytes.to_vec(),
        };
        Manifest {
            profile_device: m.dev(),
            profile_inode: m.ino(),
            entries: vec![Entry {
                target: "input.kdl".into(),
                candidate: ".macshell-input-0123456789abcdef0123456789abcdef".into(),
                original: version(12, b"old"),
                replacement: version(13, b"new"),
            }],
        }
    }

    #[test]
    fn durable_round_trip_and_exclusive_creation() {
        let dir = TestDir::new();
        let parent = File::open(&dir.0).unwrap();
        let manifest = sample(&parent);
        assert!(matches!(
            create(&parent, OsStr::new(NAME), &manifest).unwrap(),
            CreateResult::Durable
        ));
        assert_eq!(
            fs::metadata(dir.0.join(NAME)).unwrap().mode() & 0o7777,
            0o600
        );
        assert_eq!(read(&parent, OsStr::new(NAME)).unwrap(), manifest);
        assert_eq!(
            create(&parent, OsStr::new(NAME), &manifest)
                .err()
                .unwrap()
                .kind(),
            io::ErrorKind::AlreadyExists
        );
        assert_eq!(read(&parent, OsStr::new(NAME)).unwrap(), manifest);
    }

    #[test]
    fn failures_leave_manifest_and_never_claim_durability() {
        for file_sync in [true, false] {
            let dir = TestDir::new();
            let parent = File::open(&dir.0).unwrap();
            let manifest = sample(&parent);
            let fail = || io::Error::other("injected sync failure");
            let result = create_with(
                &parent,
                OsStr::new(NAME),
                &manifest,
                |f| if file_sync { Err(fail()) } else { f.sync_all() },
                |f| if file_sync { f.sync_all() } else { Err(fail()) },
            )
            .unwrap();
            assert!(matches!(result, CreateResult::Incomplete(_)));
            assert_eq!(read(&parent, OsStr::new(NAME)).unwrap(), manifest);
        }
    }

    #[test]
    fn rejects_symlinks_unsafe_permissions_and_corrupt_contents() {
        let dir = TestDir::new();
        let parent = File::open(&dir.0).unwrap();
        let manifest = sample(&parent);
        let target = dir.0.join("other");
        fs::write(&target, b"untouched").unwrap();
        symlink("other", dir.0.join(NAME)).unwrap();
        assert!(create(&parent, OsStr::new(NAME), &manifest).is_err());
        assert!(read(&parent, OsStr::new(NAME)).is_err());
        assert_eq!(fs::read(&target).unwrap(), b"untouched");
        fs::remove_file(dir.0.join(NAME)).unwrap();
        assert!(matches!(
            create(&parent, OsStr::new(NAME), &manifest).unwrap(),
            CreateResult::Durable
        ));
        fs::set_permissions(dir.0.join(NAME), fs::Permissions::from_mode(0o644)).unwrap();
        assert!(read(&parent, OsStr::new(NAME)).is_err());
        fs::set_permissions(dir.0.join(NAME), fs::Permissions::from_mode(0o600)).unwrap();
        fs::write(dir.0.join(NAME), b"{broken").unwrap();
        assert!(read(&parent, OsStr::new(NAME)).is_err());
        fs::set_permissions(&dir.0, fs::Permissions::from_mode(0o777)).unwrap();
        assert!(read(&parent, OsStr::new(NAME)).is_err());
    }

    #[test]
    fn detects_path_replacement_during_persistence() {
        let dir = TestDir::new();
        let parent = File::open(&dir.0).unwrap();
        let manifest = sample(&parent);
        let result = create_with(
            &parent,
            OsStr::new(NAME),
            &manifest,
            |file| {
                file.sync_all()?;
                fs::rename(dir.0.join(NAME), dir.0.join("saved"))?;
                fs::write(dir.0.join(NAME), b"external")?;
                fs::set_permissions(dir.0.join(NAME), fs::Permissions::from_mode(0o600))?;
                Ok(())
            },
            File::sync_all,
        )
        .unwrap();
        assert!(matches!(result, CreateResult::Incomplete(_)));
        assert_eq!(fs::read(dir.0.join(NAME)).unwrap(), b"external");
        assert_eq!(
            fs::read(dir.0.join("saved")).unwrap(),
            manifest.encode().unwrap()
        );
    }
}
