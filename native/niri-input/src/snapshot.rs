//! Bounded, read-only snapshot of a generated profile. Directory handles keep
//! traversal anchored even if a pathname is exchanged during the scan.
use std::collections::BTreeMap;
use std::ffi::{CString, OsStr};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

const MAX_FILES: usize = 1024;
const MAX_ENTRIES: usize = 4096;
const MAX_DEPTH: usize = 32;
const MAX_FILE: u64 = 2 * 1024 * 1024;
const MAX_TOTAL: usize = 16 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
    dev: u64,
    ino: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    nlink: u64,
    size: u64,
    mtime: i64,
    mtime_ns: i64,
    ctime: i64,
    ctime_ns: i64,
}

fn identity(metadata: &fs::Metadata) -> Identity {
    Identity {
        dev: metadata.dev(),
        ino: metadata.ino(),
        mode: metadata.mode(),
        uid: metadata.uid(),
        gid: metadata.gid(),
        nlink: metadata.nlink(),
        size: metadata.size(),
        mtime: metadata.mtime(),
        mtime_ns: metadata.mtime_nsec(),
        ctime: metadata.ctime(),
        ctime_ns: metadata.ctime_nsec(),
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    pub files: BTreeMap<PathBuf, Vec<u8>>,
    /// Identity of the root, all traversed directories and all KDL files.
    pub identities: BTreeMap<PathBuf, Identity>,
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn open_at(dir: &File, name: &std::ffi::OsStr, directory: bool) -> io::Result<File> {
    let name = CString::new(name.as_bytes()).map_err(|_| invalid("Invalid filename"))?;
    let flags = libc::O_RDONLY
        | libc::O_CLOEXEC
        | libc::O_NOFOLLOW
        | libc::O_NONBLOCK
        | if directory { libc::O_DIRECTORY } else { 0 };
    let fd = unsafe { libc::openat(dir.as_raw_fd(), name.as_ptr(), flags) };
    if fd < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(unsafe { File::from_raw_fd(fd) })
    }
}

fn open_regular_at(dir: &File, name: &std::ffi::OsStr) -> io::Result<File> {
    let name = CString::new(name.as_bytes()).map_err(|_| invalid("Invalid filename"))?;
    let fd = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            name.as_ptr(),
            libc::O_PATH | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let handle = unsafe { File::from_raw_fd(fd) };
    let before = handle.metadata()?;
    if !before.is_file() || before.nlink() != 1 || before.size() > MAX_FILE {
        return Err(invalid("Profile KDL is linked or too large"));
    }
    // Reopen the verified inode via its fd, not its replaceable pathname.
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(format!("/proc/self/fd/{}", handle.as_raw_fd()))?;
    if identity(&file.metadata()?) != identity(&before) {
        return Err(invalid("Profile KDL changed while opening"));
    }
    Ok(file)
}

pub fn read_profile(root: &Path) -> io::Result<Snapshot> {
    read_profile_with_policy(root, false)
}

/// Reject any reserved transaction artifact name throughout the profile tree.
/// This is a racy observation, not proof that another writer cannot add one.
pub fn read_profile_without_artifacts(root: &Path) -> io::Result<Snapshot> {
    read_profile_with_policy(root, true)
}

fn read_profile_with_policy(root: &Path, reject_artifacts: bool) -> io::Result<Snapshot> {
    let root_dir = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(root)?;
    let mut result = Snapshot {
        files: BTreeMap::new(),
        identities: BTreeMap::new(),
    };
    let mut entries = 0usize;
    let mut total = 0usize;
    visit(
        &root_dir,
        Path::new(""),
        0,
        &mut entries,
        &mut total,
        &mut result,
        reject_artifacts,
    )?;
    Ok(result)
}

fn visit(
    dir: &File,
    relative: &Path,
    depth: usize,
    entries: &mut usize,
    total: &mut usize,
    result: &mut Snapshot,
    reject_artifacts: bool,
) -> io::Result<()> {
    if depth > MAX_DEPTH {
        return Err(invalid("Profile nesting limit exceeded"));
    }
    let before = identity(&dir.metadata()?);
    let proc_path = format!("/proc/self/fd/{}", dir.as_raw_fd());
    for entry in fs::read_dir(proc_path)? {
        let entry = entry?;
        *entries += 1;
        if *entries > MAX_ENTRIES {
            return Err(invalid("Profile entry limit exceeded"));
        }
        let name = entry.file_name();
        let path = relative.join(&name);
        if reject_artifacts
            && name.as_bytes().starts_with(b".macshell-input-")
            && name != OsStr::new(".macshell-input.lock")
        {
            return Err(invalid(&format!(
                "Input transaction artifact requires inspection: {}",
                path.display()
            )));
        }
        let kind = entry.file_type()?;
        if kind.is_symlink() {
            return Err(invalid("Profile contains a symbolic link"));
        }
        if kind.is_dir() {
            let child = open_at(dir, &name, true)?;
            visit(
                &child,
                &path,
                depth + 1,
                entries,
                total,
                result,
                reject_artifacts,
            )?;
        } else if path.extension().is_some_and(|ext| ext == "kdl") {
            if !kind.is_file() {
                return Err(invalid("Profile KDL is not a regular file"));
            }
            let mut file = open_regular_at(dir, &name)?;
            let metadata = file.metadata()?;
            if !metadata.is_file() || metadata.nlink() != 1 || metadata.size() > MAX_FILE {
                return Err(invalid("Profile KDL is linked or too large"));
            }
            let file_identity = identity(&metadata);
            let mut data = Vec::new();
            (&mut file).take(MAX_FILE + 1).read_to_end(&mut data)?;
            if data.len() as u64 > MAX_FILE || identity(&file.metadata()?) != file_identity {
                return Err(invalid("Profile KDL changed while reading"));
            }
            *total = total
                .checked_add(data.len())
                .ok_or_else(|| invalid("Profile too large"))?;
            if *total > MAX_TOTAL || result.files.len() >= MAX_FILES {
                return Err(invalid("Profile size limit exceeded"));
            }
            result.identities.insert(path.clone(), file_identity);
            result.files.insert(path, data);
        }
    }
    if identity(&dir.metadata()?) != before {
        return Err(invalid("Profile directory changed while reading"));
    }
    result.identities.insert(relative.to_owned(), before);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct TestDir(PathBuf);
    impl TestDir {
        fn new() -> Self {
            static ID: AtomicUsize = AtomicUsize::new(0);
            let path = std::env::temp_dir().join(format!(
                "macshell-input-snapshot-{}-{}",
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
    fn reads_nested_profile_and_detects_changes() {
        let dir = TestDir::new();
        fs::create_dir(dir.0.join("nested")).unwrap();
        fs::write(dir.0.join("config.kdl"), b"// config\n").unwrap();
        fs::write(dir.0.join("nested/input.kdl"), b"input {}\n").unwrap();
        fs::write(dir.0.join("ignored.txt"), b"not configuration").unwrap();
        let first = read_profile(&dir.0).unwrap();
        assert_eq!(first.files.len(), 2);
        assert_eq!(first.files[Path::new("nested/input.kdl")], b"input {}\n");
        assert_eq!(first.identities.len(), 4);
        assert_eq!(first, read_profile(&dir.0).unwrap());
        fs::write(dir.0.join("nested/input.kdl"), b"changed\n").unwrap();
        assert_ne!(first, read_profile(&dir.0).unwrap());
    }

    #[test]
    fn rejects_symlinks_and_hardlinked_kdl() {
        let dir = TestDir::new();
        fs::write(dir.0.join("config.kdl"), b"// config\n").unwrap();
        symlink("config.kdl", dir.0.join("alias.kdl")).unwrap();
        assert!(read_profile(&dir.0).is_err());
        fs::remove_file(dir.0.join("alias.kdl")).unwrap();
        fs::hard_link(dir.0.join("config.kdl"), dir.0.join("alias.kdl")).unwrap();
        assert!(read_profile(&dir.0).is_err());
    }

    #[test]
    fn artifact_policy_rejects_orphans_anywhere_without_following_them() {
        let dir = TestDir::new();
        fs::write(dir.0.join("config.kdl"), b"// config\n").unwrap();
        fs::create_dir(dir.0.join("nested")).unwrap();
        assert!(read_profile_without_artifacts(&dir.0).is_ok());
        for name in [
            ".macshell-input-0123456789abcdef0123456789abcdef",
            ".macshell-input-journal-0123456789abcdef0123456789abcdef-progress-0001",
            ".macshell-input-malformed",
        ] {
            let artifact = dir.0.join("nested").join(name);
            fs::write(&artifact, b"preserve").unwrap();
            let error = read_profile_without_artifacts(&dir.0).unwrap_err();
            assert!(error.to_string().contains(name));
            assert_eq!(fs::read(&artifact).unwrap(), b"preserve");
            fs::remove_file(artifact).unwrap();
        }
        let artifact = dir.0.join(".macshell-input-link");
        symlink("config.kdl", &artifact).unwrap();
        assert!(read_profile_without_artifacts(&dir.0).is_err());
        assert_eq!(fs::read(dir.0.join("config.kdl")).unwrap(), b"// config\n");
    }

    #[test]
    fn single_prepared_recheck_rejects_new_artifact() {
        use std::time::Duration;
        let dir = TestDir::new();
        fs::write(
            dir.0.join("config.kdl"),
            b"include \"./macshell-input.kdl\"\n",
        )
        .unwrap();
        fs::write(
            dir.0.join("macshell-input.kdl"),
            b"// Input preferences remain unchanged until edited in MacShell.\n",
        )
        .unwrap();
        let values = serde_json::json!({"repeatRate":30,"repeatDelay":500,"mouseSens":0,"tpScroll":0.7,"mouseNatural":false,"tpNatural":true,"tpTap":true,"tpDwt":true});
        let prepared = crate::prepare::prepare_single(
            &dir.0,
            Path::new("macshell-input.kdl"),
            &values,
            Path::new("/bin/true"),
            Duration::from_secs(1),
        )
        .unwrap();
        fs::write(dir.0.join(".macshell-input-orphan"), b"evidence").unwrap();
        assert!(prepared.is_current(&dir.0).is_err());
        assert_eq!(
            fs::read(dir.0.join(".macshell-input-orphan")).unwrap(),
            b"evidence"
        );
    }

    #[test]
    fn locked_single_staging_preserves_original_and_rejects_stale_snapshot() {
        use std::time::Duration;
        let dir = TestDir::new();
        let config = dir.0.join("config.kdl");
        let fragment = dir.0.join("macshell-input.kdl");
        fs::write(&config, b"include \"./macshell-input.kdl\"\n").unwrap();
        let original = b"// Input preferences remain unchanged until edited in MacShell.\n";
        fs::write(&fragment, original).unwrap();
        let values = serde_json::json!({"repeatRate":30,"repeatDelay":500,"mouseSens":0,"tpScroll":0.7,"mouseNatural":false,"tpNatural":true,"tpTap":true,"tpDwt":true});
        let prepared = crate::prepare::prepare_single_locked(
            &dir.0,
            Path::new("macshell-input.kdl"),
            &values,
            Path::new("/bin/true"),
            Duration::from_secs(1),
        )
        .unwrap();
        fs::write(&config, b"// external\ninclude \"./macshell-input.kdl\"\n").unwrap();
        assert!(prepared
            .stage_single(&dir.0, Path::new("macshell-input.kdl"))
            .is_err());
        drop(prepared);
        let prepared = crate::prepare::prepare_single_locked(
            &dir.0,
            Path::new("macshell-input.kdl"),
            &values,
            Path::new("/bin/true"),
            Duration::from_secs(1),
        )
        .unwrap();
        let crate::staging::StageResult::Ready(staged) = prepared
            .stage_single(&dir.0, Path::new("macshell-input.kdl"))
            .unwrap()
        else {
            panic!("staging incomplete")
        };
        assert_eq!(fs::read(&fragment).unwrap(), original);
        assert_eq!(
            fs::read(dir.0.join(&staged.name)).unwrap(),
            prepared.plan().changes[Path::new("macshell-input.kdl")]
        );
        assert!(crate::lock::Guard::acquire(&dir.0).is_err());
    }

    #[test]
    fn locked_single_transaction_persists_manifest_before_exchange() {
        use std::time::Duration;
        let dir = TestDir::new();
        fs::write(
            dir.0.join("config.kdl"),
            b"include \"./macshell-input.kdl\"\n",
        )
        .unwrap();
        fs::write(
            dir.0.join("macshell-input.kdl"),
            b"// Input preferences remain unchanged until edited in MacShell.\n",
        )
        .unwrap();
        let values = serde_json::json!({"repeatRate":30,"repeatDelay":500,"mouseSens":0,"tpScroll":0.7,"mouseNatural":false,"tpNatural":true,"tpTap":true,"tpDwt":true});
        let prepared = crate::prepare::prepare_single_locked(
            &dir.0,
            Path::new("macshell-input.kdl"),
            &values,
            Path::new("/bin/true"),
            Duration::from_secs(1),
        )
        .unwrap();
        let crate::staging::StageResult::Ready(staged) = prepared
            .stage_single(&dir.0, Path::new("macshell-input.kdl"))
            .unwrap()
        else {
            panic!("staging incomplete")
        };
        let (manifest, journal) = prepared
            .begin_single_transaction(&dir.0, Path::new("macshell-input.kdl"), &staged)
            .unwrap();
        assert_eq!(manifest.entries.len(), 1);
        assert_eq!(manifest.entries[0].candidate, staged.name.to_string_lossy());
        let root = File::open(&dir.0).unwrap();
        assert_eq!(
            crate::journal_store::read(&root, journal.as_os_str()).unwrap(),
            manifest
        );
        assert_eq!(
            fs::read(dir.0.join("macshell-input.kdl")).unwrap(),
            b"// Input preferences remain unchanged until edited in MacShell.\n"
        );
        assert!(dir.0.join(&journal).is_file());
    }

    #[test]
    fn locked_single_transaction_commits_and_reopens_as_consistent() {
        use std::time::Duration;
        let dir = TestDir::new();
        fs::write(
            dir.0.join("config.kdl"),
            b"include \"./macshell-input.kdl\"\n",
        )
        .unwrap();
        fs::write(
            dir.0.join("macshell-input.kdl"),
            b"// Input preferences remain unchanged until edited in MacShell.\n",
        )
        .unwrap();
        let values = serde_json::json!({"repeatRate":30,"repeatDelay":500,"mouseSens":0,"tpScroll":0.7,"mouseNatural":false,"tpNatural":true,"tpTap":true,"tpDwt":true});
        let prepared = crate::prepare::prepare_single_locked(
            &dir.0,
            Path::new("macshell-input.kdl"),
            &values,
            Path::new("/bin/true"),
            Duration::from_secs(1),
        )
        .unwrap();
        let staged = match prepared
            .stage_single(&dir.0, Path::new("macshell-input.kdl"))
            .unwrap()
        {
            crate::staging::StageResult::Ready(value) => value,
            crate::staging::StageResult::Incomplete { .. } => panic!("staging incomplete"),
        };
        let (manifest, journal) = prepared
            .begin_single_transaction(&dir.0, Path::new("macshell-input.kdl"), &staged)
            .unwrap();
        let outcome = prepared
            .commit_single_transaction(
                &dir.0,
                Path::new("macshell-input.kdl"),
                staged,
                manifest.clone(),
                journal.clone(),
            )
            .unwrap();
        assert_eq!(outcome, crate::coordinator::Outcome::Complete);
        let root = File::open(&dir.0).unwrap();
        let diagnostic = crate::recovery::inspect_journal(&root, journal.as_os_str()).unwrap();
        assert_eq!(
            diagnostic.agreement,
            crate::recovery::ProgressAgreement::Consistent
        );
        assert_eq!(
            diagnostic.files.profile,
            crate::recovery::ProfileObservation::AllExchanged
        );
        assert_eq!(
            fs::read(dir.0.join("macshell-input.kdl")).unwrap(),
            manifest.entries[0].replacement.bytes
        );
    }

    #[test]
    fn interrupted_completion_reopens_as_pending_and_preserves_versions() {
        use std::time::Duration;
        let dir = TestDir::new();
        fs::write(
            dir.0.join("config.kdl"),
            b"include \"./macshell-input.kdl\"\n",
        )
        .unwrap();
        fs::write(
            dir.0.join("macshell-input.kdl"),
            b"// Input preferences remain unchanged until edited in MacShell.\n",
        )
        .unwrap();
        let values = serde_json::json!({"repeatRate":30,"repeatDelay":500,"mouseSens":0,"tpScroll":0.7,"mouseNatural":false,"tpNatural":true,"tpTap":true,"tpDwt":true});
        let prepared = crate::prepare::prepare_single_locked(
            &dir.0,
            Path::new("macshell-input.kdl"),
            &values,
            Path::new("/bin/true"),
            Duration::from_secs(1),
        )
        .unwrap();
        let staged = match prepared
            .stage_single(&dir.0, Path::new("macshell-input.kdl"))
            .unwrap()
        {
            crate::staging::StageResult::Ready(value) => value,
            crate::staging::StageResult::Incomplete { .. } => panic!("staging incomplete"),
        };
        let (manifest, journal) = prepared
            .begin_single_transaction(&dir.0, Path::new("macshell-input.kdl"), &staged)
            .unwrap();
        let outcome = prepared
            .commit_single_transaction_with_failure(
                &dir.0,
                Path::new("macshell-input.kdl"),
                staged,
                manifest,
                journal.clone(),
            )
            .unwrap();
        assert!(matches!(
            outcome,
            crate::coordinator::Outcome::Interrupted {
                stage: crate::coordinator::Stage::Completion,
                ..
            }
        ));
        let root = File::open(&dir.0).unwrap();
        let diagnostic = crate::recovery::inspect_journal(&root, journal.as_os_str()).unwrap();
        assert_eq!(
            diagnostic.agreement,
            crate::recovery::ProgressAgreement::PendingExchange
        );
        assert_eq!(
            diagnostic.files.profile,
            crate::recovery::ProfileObservation::AllExchanged
        );
        assert!(dir.0.join(journal).is_file());
    }

    #[test]
    fn snapshot_detects_permission_changes_even_when_content_is_unchanged() {
        use std::os::unix::fs::PermissionsExt;
        let dir = TestDir::new();
        let config = dir.0.join("config.kdl");
        fs::write(&config, b"// same\n").unwrap();
        fs::set_permissions(&config, fs::Permissions::from_mode(0o600)).unwrap();
        let before = read_profile(&dir.0).unwrap();
        fs::set_permissions(&config, fs::Permissions::from_mode(0o640)).unwrap();
        let after = read_profile(&dir.0).unwrap();
        assert_eq!(before.files, after.files);
        assert_ne!(before.identities, after.identities);
    }

    #[test]
    fn planned_profile_validates_in_isolated_directory() {
        use std::process::Command;
        if Command::new("niri").arg("--version").output().is_err() {
            return;
        }
        let dir = TestDir::new();
        fs::write(
            dir.0.join("config.kdl"),
            b"include \"./original.kdl\"\ninclude \"./macshell-input.kdl\"\ninclude \"./nested/extra.kdl\"\n",
        )
        .unwrap();
        fs::create_dir(dir.0.join("nested")).unwrap();
        fs::write(dir.0.join("nested/extra.kdl"), b"include \"./leaf.kdl\"\n").unwrap();
        fs::write(dir.0.join("nested/leaf.kdl"), b"// nested\n").unwrap();
        fs::write(dir.0.join("original.kdl"), b"input { keyboard { repeat-rate 20; xkb { layout \"us,ru\"; }; }; mouse { natural-scroll; }; }\n").unwrap();
        fs::write(
            dir.0.join("macshell-input.kdl"),
            b"// Input preferences remain unchanged until edited in MacShell.\n",
        )
        .unwrap();
        let validate = || {
            Command::new("niri")
                .arg("validate")
                .arg("-c")
                .arg(dir.0.join("config.kdl"))
                .output()
                .unwrap()
        };
        assert!(validate().status.success());
        let before = read_profile(&dir.0).unwrap();
        let values = serde_json::json!({"repeatRate":30,"repeatDelay":500,"mouseSens":0,"tpScroll":0.7,"mouseNatural":false,"tpNatural":true,"tpTap":true,"tpDwt":true});
        let plan = crate::plan_profile(
            before.files.clone(),
            Path::new("macshell-input.kdl"),
            &values,
        )
        .unwrap();
        assert_eq!(before, read_profile(&dir.0).unwrap());
        crate::validation::validate(&plan, Path::new("niri"), std::time::Duration::from_secs(5))
            .unwrap();
        assert_eq!(before, read_profile(&dir.0).unwrap());
        for (path, content) in plan.changes {
            fs::write(dir.0.join(path), content).unwrap();
        }
        let result = validate();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        assert!(fs::read_to_string(dir.0.join("original.kdl"))
            .unwrap()
            .contains("layout \"us,ru\""));
    }

    #[test]
    fn single_preparation_validates_and_refuses_external_managed_settings() {
        use std::process::Command;
        use std::time::Duration;
        if Command::new("niri").arg("--version").output().is_err() {
            return;
        }
        let dir = TestDir::new();
        let config = dir.0.join("config.kdl");
        let fragment = dir.0.join("macshell-input.kdl");
        fs::write(
            &config,
            b"input { keyboard { xkb { layout \"us\"; }; }; }\ninclude \"./macshell-input.kdl\"\n",
        )
        .unwrap();
        fs::write(
            &fragment,
            b"// Input preferences remain unchanged until edited in MacShell.\n",
        )
        .unwrap();
        let values = serde_json::json!({"repeatRate":30,"repeatDelay":500,"mouseSens":0,"tpScroll":0.7,"mouseNatural":false,"tpNatural":true,"tpTap":true,"tpDwt":true});
        let before = read_profile(&dir.0).unwrap();
        let prepared = crate::prepare::prepare_single(
            &dir.0,
            Path::new("macshell-input.kdl"),
            &values,
            Path::new("niri"),
            Duration::from_secs(5),
        )
        .unwrap();
        assert_eq!(prepared.plan().changes.len(), 1);
        assert!(prepared
            .plan()
            .changes
            .contains_key(Path::new("macshell-input.kdl")));
        assert_eq!(before, read_profile(&dir.0).unwrap());
        let conflicting =
            b"input { mouse { accel-speed 0.2; }; }\ninclude \"./macshell-input.kdl\"\n";
        fs::write(&config, conflicting).unwrap();
        let error = match crate::prepare::prepare_single(
            &dir.0,
            Path::new("macshell-input.kdl"),
            &values,
            Path::new("niri"),
            Duration::from_secs(5),
        ) {
            Ok(_) => panic!("external setting accepted"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("config.kdl"), "{error}");
        assert_eq!(fs::read(&config).unwrap(), conflicting);
        assert_eq!(
            fs::read(&fragment).unwrap(),
            before.files[Path::new("macshell-input.kdl")]
        );
        fs::write(
            &config,
            b"invalid-niri-node\ninclude \"./macshell-input.kdl\"\n",
        )
        .unwrap();
        assert!(crate::prepare::prepare_single(
            &dir.0,
            Path::new("macshell-input.kdl"),
            &values,
            Path::new("niri"),
            Duration::from_secs(5)
        )
        .is_err());
    }

    #[test]
    fn validation_rejects_external_includes_and_times_out_owned_child() {
        use std::os::unix::fs::PermissionsExt;
        use std::time::Duration;
        let dir = TestDir::new();
        let validator = dir.0.join("validator");
        fs::write(&validator, b"#!/bin/sh\nexec sleep 10\n").unwrap();
        fs::set_permissions(&validator, fs::Permissions::from_mode(0o700)).unwrap();
        let mut plan = crate::Plan {
            before: BTreeMap::from([(
                PathBuf::from("config.kdl"),
                b"// Input preferences remain unchanged until edited in MacShell.\n".to_vec(),
            )]),
            changes: BTreeMap::new(),
        };
        let error =
            crate::validation::validate(&plan, &validator, Duration::from_millis(80)).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        plan.changes.insert(
            PathBuf::from("config.kdl"),
            b"include \"/tmp/outside.kdl\"\n".to_vec(),
        );
        let error =
            crate::validation::validate(&plan, &validator, Duration::from_secs(1)).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn validation_rejects_external_includes_hidden_by_kdl_newlines() {
        use std::process::Command;
        use std::time::Duration;
        if Command::new("niri").arg("--version").output().is_err() {
            return;
        }
        let dir = TestDir::new();
        let external = dir.0.join("external.kdl");
        fs::write(&external, b"macshell-input-external-canary\n").unwrap();
        let config = dir.0.join("config.kdl");
        for newline in ["\r", "\u{000c}", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let source = format!(
                "screenshot-path \"foo\"{newline}include \"{}\"\n",
                external.display()
            );
            fs::write(&config, &source).unwrap();
            let output = Command::new("niri")
                .arg("validate")
                .arg("-c")
                .arg(&config)
                .output()
                .unwrap();
            assert!(!output.status.success());
            assert!(
                String::from_utf8_lossy(&output.stderr).contains("macshell-input-external-canary"),
                "niri did not parse the canary for {newline:?}"
            );
            let plan = crate::Plan {
                before: BTreeMap::from([(PathBuf::from("config.kdl"), source.into_bytes())]),
                changes: BTreeMap::new(),
            };
            let error =
                crate::validation::validate(&plan, Path::new("niri"), Duration::from_secs(5))
                    .unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::InvalidData);
            assert!(error.to_string().contains("include syntax"));
        }
    }

    #[test]
    fn preparation_detects_concurrent_profile_change() {
        use std::os::unix::fs::PermissionsExt;
        use std::time::Duration;
        let dir = TestDir::new();
        fs::write(
            dir.0.join("config.kdl"),
            b"include \"./macshell-input.kdl\"\n",
        )
        .unwrap();
        fs::write(
            dir.0.join("macshell-input.kdl"),
            b"// Input preferences remain unchanged until edited in MacShell.\n",
        )
        .unwrap();
        let validator = dir.0.join("validator");
        fs::write(
            &validator,
            b"#!/bin/sh\nprintf '// external edit\\n' > \"$(dirname \"$0\")/config.kdl\"\n",
        )
        .unwrap();
        fs::set_permissions(&validator, fs::Permissions::from_mode(0o700)).unwrap();
        let values = serde_json::json!({"repeatRate":30,"repeatDelay":500,"mouseSens":0,"tpScroll":0.7,"mouseNatural":false,"tpNatural":true,"tpTap":true,"tpDwt":true});
        let error = match crate::prepare::prepare(
            &dir.0,
            Path::new("macshell-input.kdl"),
            &values,
            &validator,
            Duration::from_secs(2),
        ) {
            Ok(_) => panic!("expected profile conflict"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("Profile changed"));
        assert_eq!(
            fs::read(dir.0.join("config.kdl")).unwrap(),
            b"// external edit\n"
        );
        assert_eq!(
            fs::read(dir.0.join("macshell-input.kdl")).unwrap(),
            b"// Input preferences remain unchanged until edited in MacShell.\n"
        );
    }

    #[test]
    fn preparation_checks_original_fragment_before_replacing_it() {
        use std::time::Duration;
        let dir = TestDir::new();
        fs::write(
            dir.0.join("config.kdl"),
            b"include \"./macshell-input.kdl\"\n",
        )
        .unwrap();
        let fragment = dir.0.join("macshell-input.kdl");
        fs::write(&fragment, b"include \"/tmp/outside.kdl\"\n").unwrap();
        let values = serde_json::json!({"repeatRate":30,"repeatDelay":500,"mouseSens":0,"tpScroll":0.7,"mouseNatural":false,"tpNatural":true,"tpTap":true,"tpDwt":true});
        let error = match crate::prepare::prepare(
            &dir.0,
            Path::new("macshell-input.kdl"),
            &values,
            Path::new("/bin/true"),
            Duration::from_secs(1),
        ) {
            Ok(_) => panic!("unsafe source fragment accepted"),
            Err(error) => error,
        };
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert_eq!(
            fs::read(fragment).unwrap(),
            b"include \"/tmp/outside.kdl\"\n"
        );
    }

    #[test]
    fn prepared_plan_detects_additions() {
        use std::os::unix::fs::PermissionsExt;
        use std::time::Duration;
        let dir = TestDir::new();
        fs::write(
            dir.0.join("config.kdl"),
            b"include \"./macshell-input.kdl\"\n",
        )
        .unwrap();
        fs::write(
            dir.0.join("macshell-input.kdl"),
            b"// Input preferences remain unchanged until edited in MacShell.\n",
        )
        .unwrap();
        let validator = dir.0.join("validator");
        fs::write(&validator, b"#!/bin/sh\nexit 0\n").unwrap();
        fs::set_permissions(&validator, fs::Permissions::from_mode(0o700)).unwrap();
        let values = serde_json::json!({"repeatRate":30,"repeatDelay":500,"mouseSens":0,"tpScroll":0.7,"mouseNatural":false,"tpNatural":true,"tpTap":true,"tpDwt":true});
        let prepared = crate::prepare::prepare_locked(
            &dir.0,
            Path::new("macshell-input.kdl"),
            &values,
            &validator,
            Duration::from_secs(2),
        )
        .unwrap();
        assert!(crate::lock::Guard::acquire(&dir.0).is_err());
        assert!(prepared.is_current(&dir.0).unwrap());
        assert!(prepared
            .plan()
            .changes
            .contains_key(Path::new("macshell-input.kdl")));
        fs::write(dir.0.join("added.kdl"), b"// added\n").unwrap();
        assert!(!prepared.is_current(&dir.0).unwrap());
        drop(prepared);
        assert!(crate::lock::Guard::acquire(&dir.0).is_ok());
    }

    #[test]
    fn input_lock_serializes_and_detects_replacement() {
        use std::os::unix::fs::PermissionsExt;
        let dir = TestDir::new();
        let guard = crate::lock::Guard::acquire(&dir.0).unwrap();
        assert!(crate::lock::Guard::acquire(&dir.0).is_err());
        guard.check().unwrap();
        fs::rename(dir.0.join(".macshell-input.lock"), dir.0.join("old-lock")).unwrap();
        fs::write(dir.0.join(".macshell-input.lock"), b"").unwrap();
        fs::set_permissions(
            dir.0.join(".macshell-input.lock"),
            fs::Permissions::from_mode(0o600),
        )
        .unwrap();
        assert!(guard.check().unwrap_err().to_string().contains("replaced"));
        drop(guard);
    }

    #[test]
    fn input_lock_rejects_symlink_without_touching_target() {
        let dir = TestDir::new();
        let target = dir.0.join("target");
        fs::write(&target, b"original").unwrap();
        symlink("target", dir.0.join(".macshell-input.lock")).unwrap();
        assert!(crate::lock::Guard::acquire(&dir.0).is_err());
        assert_eq!(fs::read(target).unwrap(), b"original");
    }

    #[test]
    fn input_lock_detects_profile_directory_replacement() {
        let dir = TestDir::new();
        let profile = dir.0.join("profile");
        fs::create_dir(&profile).unwrap();
        let guard = crate::lock::Guard::acquire(&profile).unwrap();
        guard.check_profile(&profile).unwrap();
        fs::rename(&profile, dir.0.join("old-profile")).unwrap();
        fs::create_dir(&profile).unwrap();
        assert!(guard
            .check_profile(&profile)
            .unwrap_err()
            .to_string()
            .contains("replaced"));
    }
}
