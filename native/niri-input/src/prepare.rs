//! Read-only preparation and conflict detection for a future input update.
use crate::{lock, plan_profile, plan_single_fragment, snapshot, validation, Plan};
use serde_json::Value;
use std::ffi::{OsStr, OsString};
use std::fs::{File, OpenOptions};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::time::Duration;

type Planner = fn(
    std::collections::BTreeMap<std::path::PathBuf, Vec<u8>>,
    &Path,
    &Value,
) -> Result<Plan, String>;

/// A plan validated against a particular snapshot. It is not permission to
/// write: callers must recheck the snapshot when committing, and even a check
/// immediately before a rename cannot prevent edits by uncooperative writers.
pub struct Prepared {
    snapshot: snapshot::Snapshot,
    plan: Plan,
    reject_artifacts: bool,
}

/// Retains the cooperative lock for the entire lifetime of the prepared plan.
pub struct LockedPrepared {
    guard: lock::Guard,
    prepared: Prepared,
}

impl LockedPrepared {
    pub fn plan(&self) -> &Plan {
        self.prepared.plan()
    }

    pub fn is_current(&self, profile: &Path) -> io::Result<bool> {
        self.guard.check_profile(profile)?;
        let current = self.prepared.is_current(profile)?;
        self.guard.check_profile(profile)?;
        Ok(current)
    }

    /// Stage a root-level managed fragment while retaining the lock. This is
    /// not a commit: a candidate or an error can leave an artifact and must
    /// never authorize an exchange or automatic cleanup by itself.
    pub fn stage_single(
        &self,
        profile: &Path,
        fragment: &Path,
    ) -> io::Result<crate::staging::StageResult> {
        if !self.prepared.reject_artifacts || fragment != Path::new("macshell-input.kdl") {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Expected root managed input fragment",
            ));
        }
        if !self.is_current(profile)? {
            return Err(io::Error::other("Profile changed before staging"));
        }
        let before = self
            .plan()
            .before
            .get(fragment)
            .ok_or_else(|| io::Error::other("Missing original fragment"))?;
        let replacement = self
            .plan()
            .changes
            .get(fragment)
            .ok_or_else(|| io::Error::other("No fragment change to stage"))?;
        let name = crate::exchange::name(fragment.as_os_str())?;
        let fd = unsafe {
            libc::openat(
                self.guard.root().as_raw_fd(),
                name.as_ptr(),
                libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let handle = unsafe { File::from_raw_fd(fd) };
        let metadata = handle.metadata()?;
        if !metadata.is_file() {
            return Err(io::Error::other("Fragment is not a regular file"));
        }
        let original = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(format!("/proc/self/fd/{}", handle.as_raw_fd()))?;
        self.guard.check_profile(profile)?;
        crate::staging::stage(
            self.guard.root(),
            fragment.as_os_str(),
            &original,
            before,
            replacement,
        )
    }

    pub fn begin_single_transaction(
        &self,
        profile: &Path,
        fragment: &Path,
        staged: &crate::staging::Staged,
    ) -> io::Result<(crate::journal::Manifest, OsString)> {
        if fragment != Path::new("macshell-input.kdl") {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Expected root managed input fragment",
            ));
        }
        self.guard.check_profile(profile)?;
        let before = self
            .plan()
            .before
            .get(fragment)
            .ok_or_else(|| io::Error::other("Missing original fragment"))?;
        let replacement = self
            .plan()
            .changes
            .get(fragment)
            .ok_or_else(|| io::Error::other("No fragment change to stage"))?;
        let original = open_regular(self.guard.root(), OsStr::new("macshell-input.kdl"))?;
        if !crate::exchange::matches_bytes(&original, before)?
            || !crate::exchange::matches_bytes(&staged.file, replacement)?
        {
            return Err(io::Error::other("Fragment changed before manifest"));
        }
        let version = |file: &File, bytes: &[u8]| -> io::Result<crate::journal::FileVersion> {
            let meta = file.metadata()?;
            Ok(crate::journal::FileVersion {
                device: meta.dev(),
                inode: meta.ino(),
                mode: meta.mode(),
                uid: meta.uid(),
                gid: meta.gid(),
                nlink: meta.nlink(),
                bytes: bytes.to_vec(),
            })
        };
        let root_meta = self.guard.root().metadata()?;
        let manifest = crate::journal::Manifest {
            profile_device: root_meta.dev(),
            profile_inode: root_meta.ino(),
            entries: vec![crate::journal::Entry {
                target: fragment.to_string_lossy().into_owned(),
                candidate: staged.name.to_string_lossy().into_owned(),
                original: version(&original, before)?,
                replacement: version(&staged.file, replacement)?,
            }],
        };
        let journal = journal_name()?;
        match crate::journal_store::create(self.guard.root(), journal.as_os_str(), &manifest)? {
            crate::journal_store::CreateResult::Durable => Ok((manifest, journal)),
            crate::journal_store::CreateResult::Incomplete(error) => Err(error),
        }
    }

    /// Run the real single-file coordinator after a durable manifest exists.
    /// The candidate and journal are intentionally retained on every outcome;
    /// cleanup belongs to a later, conflict-aware phase.
    pub fn commit_single_transaction(
        &self,
        profile: &Path,
        fragment: &Path,
        staged: crate::staging::Staged,
        manifest: crate::journal::Manifest,
        journal: OsString,
    ) -> io::Result<crate::coordinator::Outcome> {
        if fragment != Path::new("macshell-input.kdl") {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Expected root managed input fragment",
            ));
        }
        self.guard.check_profile(profile)?;
        if crate::journal_store::read(self.guard.root(), journal.as_os_str())? != manifest {
            return Err(io::Error::other("Transaction manifest changed"));
        }
        let original = open_regular(self.guard.root(), OsStr::new("macshell-input.kdl"))?;
        let replacement = staged.file;
        struct Disk<'a> {
            root: &'a File,
            journal: &'a OsStr,
            manifest: &'a crate::journal::Manifest,
            original: File,
            replacement: File,
        }
        impl crate::coordinator::Operations for Disk<'_> {
            fn persist(&mut self, ledger: &crate::progress::Ledger) -> io::Result<()> {
                match crate::progress_store::write(self.root, self.journal, self.manifest, ledger)?
                {
                    crate::progress_store::WriteResult::Durable => Ok(()),
                    crate::progress_store::WriteResult::Incomplete(error) => Err(error),
                }
            }
            fn exchange(&mut self, index: usize) -> io::Result<crate::exchange::ResultState> {
                if index != 0 || self.manifest.entries.len() != 1 {
                    return Err(io::Error::other("Unexpected transaction entry"));
                }
                let entry = &self.manifest.entries[0];
                crate::exchange::exchange(
                    self.root,
                    OsStr::new(&entry.target),
                    OsStr::new(&entry.candidate),
                    crate::exchange::Expected {
                        original: &self.original,
                        replacement: &self.replacement,
                        original_bytes: &entry.original.bytes,
                        replacement_bytes: &entry.replacement.bytes,
                    },
                )
            }
        }
        let journal_ref = journal.as_os_str();
        let mut disk = Disk {
            root: self.guard.root(),
            journal: journal_ref,
            manifest: &manifest,
            original,
            replacement,
        };
        let result = crate::coordinator::run(&manifest, &mut disk)?;
        self.guard.check_profile(profile)?;
        Ok(result)
    }

    pub fn commit_single_transaction_with_failure(
        &self,
        profile: &Path,
        fragment: &Path,
        staged: crate::staging::Staged,
        manifest: crate::journal::Manifest,
        journal: OsString,
    ) -> io::Result<crate::coordinator::Outcome> {
        if fragment != Path::new("macshell-input.kdl") {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Expected root managed input fragment",
            ));
        }
        self.guard.check_profile(profile)?;
        let original = open_regular(self.guard.root(), OsStr::new("macshell-input.kdl"))?;
        let replacement = staged.file;
        struct Disk<'a> {
            root: &'a File,
            journal: &'a OsStr,
            manifest: &'a crate::journal::Manifest,
            original: File,
            replacement: File,
        }
        impl crate::coordinator::Operations for Disk<'_> {
            fn persist(&mut self, ledger: &crate::progress::Ledger) -> io::Result<()> {
                if ledger.events().len() == 2 {
                    return Err(io::Error::other("injected completion failure"));
                }
                match crate::progress_store::write(self.root, self.journal, self.manifest, ledger)?
                {
                    crate::progress_store::WriteResult::Durable => Ok(()),
                    crate::progress_store::WriteResult::Incomplete(error) => Err(error),
                }
            }
            fn exchange(&mut self, index: usize) -> io::Result<crate::exchange::ResultState> {
                let entry = &self.manifest.entries[index];
                crate::exchange::exchange(
                    self.root,
                    OsStr::new(&entry.target),
                    OsStr::new(&entry.candidate),
                    crate::exchange::Expected {
                        original: &self.original,
                        replacement: &self.replacement,
                        original_bytes: &entry.original.bytes,
                        replacement_bytes: &entry.replacement.bytes,
                    },
                )
            }
        }
        let mut disk = Disk {
            root: self.guard.root(),
            journal: journal.as_os_str(),
            manifest: &manifest,
            original,
            replacement,
        };
        crate::coordinator::run(&manifest, &mut disk)
    }
}

fn open_regular(dir: &File, name: &OsStr) -> io::Result<File> {
    let c = std::ffi::CString::new(name.as_bytes())
        .map_err(|_| io::Error::other("Invalid filename"))?;
    let fd = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            c.as_ptr(),
            libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let handle = unsafe { File::from_raw_fd(fd) };
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(format!("/proc/self/fd/{}", handle.as_raw_fd()))
}

fn journal_name() -> io::Result<OsString> {
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
    Ok(OsString::from(format!(
        ".macshell-input-journal-{}",
        bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()
    )))
}

pub fn prepare_locked(
    profile: &Path,
    fragment: &Path,
    values: &Value,
    validator: &Path,
    timeout: Duration,
) -> io::Result<LockedPrepared> {
    prepare_locked_with(profile, fragment, values, validator, timeout, prepare)
}

/// Prepare a fragment-only update while retaining the cooperative profile lock.
/// The lock file may be created, but no KDL file is modified. The returned plan
/// still requires safe transaction handling and cannot prevent external edits.
pub fn prepare_single_locked(
    profile: &Path,
    fragment: &Path,
    values: &Value,
    validator: &Path,
    timeout: Duration,
) -> io::Result<LockedPrepared> {
    prepare_locked_with(
        profile,
        fragment,
        values,
        validator,
        timeout,
        prepare_single,
    )
}

fn prepare_locked_with(
    profile: &Path,
    fragment: &Path,
    values: &Value,
    validator: &Path,
    timeout: Duration,
    prepare_fn: fn(&Path, &Path, &Value, &Path, Duration) -> io::Result<Prepared>,
) -> io::Result<LockedPrepared> {
    let guard = lock::Guard::acquire(profile)?;
    guard.check_profile(profile)?;
    let prepared = prepare_fn(profile, fragment, values, validator, timeout)?;
    let locked = LockedPrepared { guard, prepared };
    if !locked.is_current(profile)? {
        return Err(io::Error::other(
            "Profile changed while preparing input settings",
        ));
    }
    Ok(locked)
}

impl Prepared {
    pub fn plan(&self) -> &Plan {
        &self.plan
    }

    /// Check the complete KDL tree, including its directory/file identities.
    pub fn is_current(&self, profile: &Path) -> io::Result<bool> {
        let current = if self.reject_artifacts {
            snapshot::read_profile_without_artifacts(profile)?
        } else {
            snapshot::read_profile(profile)?
        };
        Ok(current == self.snapshot)
    }
}

pub fn prepare(
    profile: &Path,
    fragment: &Path,
    values: &Value,
    validator: &Path,
    timeout: Duration,
) -> io::Result<Prepared> {
    prepare_with(
        profile,
        fragment,
        values,
        validator,
        timeout,
        plan_profile,
        false,
    )
}

/// Prepare only a managed fragment update and refuse changes to other files.
/// The source and resulting profile are validated in an isolated directory.
pub fn prepare_single(
    profile: &Path,
    fragment: &Path,
    values: &Value,
    validator: &Path,
    timeout: Duration,
) -> io::Result<Prepared> {
    prepare_with(
        profile,
        fragment,
        values,
        validator,
        timeout,
        plan_single_fragment,
        true,
    )
}

fn prepare_with(
    profile: &Path,
    fragment: &Path,
    values: &Value,
    validator: &Path,
    timeout: Duration,
    planner: Planner,
    reject_artifacts: bool,
) -> io::Result<Prepared> {
    let snapshot = if reject_artifacts {
        snapshot::read_profile_without_artifacts(profile)?
    } else {
        snapshot::read_profile(profile)?
    };
    // Check the source as well as the resulting staged profile. Otherwise a
    // generated fragment could erase unsupported or external includes before
    // validation ever inspects them.
    crate::includes::check(&snapshot.files)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let source = Plan {
        before: snapshot.files.clone(),
        changes: Default::default(),
    };
    validation::validate(&source, validator, timeout)?;
    let plan = planner(snapshot.files.clone(), fragment, values)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    validation::validate(&plan, validator, timeout)?;
    let prepared = Prepared {
        snapshot,
        plan,
        reject_artifacts,
    };
    if !prepared.is_current(profile)? {
        return Err(io::Error::other(
            "Profile changed while preparing input settings",
        ));
    }
    Ok(prepared)
}
