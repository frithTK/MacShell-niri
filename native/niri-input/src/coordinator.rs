//! Ordered in-process transaction steps. This is not restart recovery.
//! The caller owns the lock, evidence and all filesystem operations.
use crate::progress::{Event, Ledger};
use crate::{exchange, journal::Manifest};
use std::io;

/// Every operation is performed at most once. An error after work has begun
/// can leave durable files or a partially exchanged profile. Never retry or
/// remove evidence automatically based on this result.
pub trait Operations {
    /// Persist a snapshot and return success only after file and directory sync.
    fn persist(&mut self, ledger: &Ledger) -> io::Result<()>;
    /// Exchange and sync one entry; uncertainty must not be reported as success.
    fn exchange(&mut self, index: usize) -> io::Result<exchange::ResultState>;
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Complete,
    /// The call did not establish completion. Retain all versions and journal.
    Interrupted {
        index: Option<usize>,
        stage: Stage,
        reason: Reason,
    },
}

#[derive(Debug, PartialEq, Eq)]
pub enum Reason {
    Io {
        kind: io::ErrorKind,
        message: String,
    },
    Uncertain,
    DurabilityUnknown,
}

impl From<io::Error> for Reason {
    fn from(error: io::Error) -> Self {
        Self::Io {
            kind: error.kind(),
            message: error.to_string(),
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Stage {
    InitialProgress,
    Intent,
    Exchange,
    Completion,
}

impl std::fmt::Display for Stage {
    fn fmt(&self, output: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(output, "{:?}", self)
    }
}

/// Run a fresh ledger only; no assumption about recovery or cleanup is made.
/// This function alone does not verify a profile, hold a lock, protect against
/// external writers, or implement atomic multi-file visibility.
pub fn run(manifest: &Manifest, operations: &mut impl Operations) -> io::Result<Outcome> {
    let mut ledger = Ledger::new(manifest).map_err(io::Error::other)?;
    if let Err(error) = operations.persist(&ledger) {
        return Ok(Outcome::Interrupted {
            index: None,
            stage: Stage::InitialProgress,
            reason: error.into(),
        });
    }
    for index in 0..manifest.entries.len() {
        ledger
            .push(Event::Intent(index))
            .map_err(io::Error::other)?;
        if let Err(error) = operations.persist(&ledger) {
            return Ok(Outcome::Interrupted {
                index: Some(index),
                stage: Stage::Intent,
                reason: error.into(),
            });
        }
        let reason = match operations.exchange(index) {
            Ok(exchange::ResultState::Exchanged) => None,
            Ok(exchange::ResultState::Uncertain) => Some(Reason::Uncertain),
            Ok(exchange::ResultState::DurabilityUnknown) => Some(Reason::DurabilityUnknown),
            Err(error) => Some(error.into()),
        };
        if let Some(reason) = reason {
            return Ok(Outcome::Interrupted {
                index: Some(index),
                stage: Stage::Exchange,
                reason,
            });
        }
        ledger
            .push(Event::Exchanged(index))
            .map_err(io::Error::other)?;
        if let Err(error) = operations.persist(&ledger) {
            return Ok(Outcome::Interrupted {
                index: Some(index),
                stage: Stage::Completion,
                reason: error.into(),
            });
        }
    }
    Ok(Outcome::Complete)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::journal::{Entry, FileVersion};
    use std::ffi::OsStr;
    use std::fs::{self, File};
    use std::os::unix::fs::MetadataExt;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Fake {
        calls: Vec<String>,
        fail_at: Option<usize>,
        uncertain: bool,
    }
    impl Operations for Fake {
        fn persist(&mut self, ledger: &Ledger) -> io::Result<()> {
            self.calls
                .push(format!("persist:{}", ledger.events().len()));
            if self.fail_at == Some(self.calls.len()) {
                Err(io::Error::other("failed"))
            } else {
                Ok(())
            }
        }
        fn exchange(&mut self, index: usize) -> io::Result<exchange::ResultState> {
            self.calls.push(format!("exchange:{index}"));
            if self.fail_at == Some(self.calls.len()) {
                return Err(io::Error::other("failed"));
            }
            Ok(if self.uncertain {
                exchange::ResultState::Uncertain
            } else {
                exchange::ResultState::Exchanged
            })
        }
    }
    fn manifest() -> Manifest {
        let version = |inode| FileVersion {
            device: 1,
            inode,
            mode: libc::S_IFREG | 0o600,
            uid: 1,
            gid: 1,
            nlink: 1,
            bytes: vec![],
        };
        Manifest {
            profile_device: 1,
            profile_inode: 1,
            entries: (0..2)
                .map(|i| Entry {
                    target: format!("{i}.kdl"),
                    candidate: format!(".macshell-input-{i:032x}"),
                    original: version(i * 2 + 1),
                    replacement: version(i * 2 + 2),
                })
                .collect(),
        }
    }
    #[test]
    fn persists_intent_before_each_exchange_and_stops_on_any_failure() {
        let expected = [
            "persist:0",
            "persist:1",
            "exchange:0",
            "persist:2",
            "persist:3",
            "exchange:1",
            "persist:4",
        ];
        for fail in 1..=expected.len() {
            let mut fake = Fake {
                calls: vec![],
                fail_at: Some(fail),
                uncertain: false,
            };
            assert!(matches!(
                run(&manifest(), &mut fake).unwrap(),
                Outcome::Interrupted { .. }
            ));
            assert_eq!(fake.calls, expected[..fail]);
        }
        let mut fake = Fake {
            calls: vec![],
            fail_at: None,
            uncertain: false,
        };
        assert_eq!(run(&manifest(), &mut fake).unwrap(), Outcome::Complete);
        assert_eq!(fake.calls, expected);
        let mut fake = Fake {
            calls: vec![],
            fail_at: None,
            uncertain: true,
        };
        assert_eq!(
            run(&manifest(), &mut fake).unwrap(),
            Outcome::Interrupted {
                index: Some(0),
                stage: Stage::Exchange,
                reason: Reason::Uncertain,
            }
        );
        assert_eq!(fake.calls, expected[..3]);
    }

    #[test]
    fn real_progress_and_exchange_preserve_evidence_at_interruption() {
        use crate::{journal_store, progress_store, recovery, staging};
        static ID: AtomicUsize = AtomicUsize::new(0);
        struct TestDir(std::path::PathBuf);
        impl Drop for TestDir {
            fn drop(&mut self) {
                fs::remove_dir_all(&self.0).unwrap();
            }
        }
        struct Disk<'a> {
            root: &'a File,
            journal: &'a OsStr,
            manifest: &'a Manifest,
            originals: Vec<File>,
            replacements: Vec<File>,
            fail_on_completion: bool,
        }
        impl Operations for Disk<'_> {
            fn persist(&mut self, ledger: &Ledger) -> io::Result<()> {
                if self.fail_on_completion && ledger.events().len() == 2 {
                    return Err(io::Error::other("injected interruption"));
                }
                match progress_store::write(self.root, self.journal, self.manifest, ledger)? {
                    progress_store::WriteResult::Durable => Ok(()),
                    progress_store::WriteResult::Incomplete(error) => Err(error),
                }
            }
            fn exchange(&mut self, index: usize) -> io::Result<exchange::ResultState> {
                let entry = &self.manifest.entries[index];
                exchange::exchange(
                    self.root,
                    OsStr::new(&entry.target),
                    OsStr::new(&entry.candidate),
                    exchange::Expected {
                        original: &self.originals[index],
                        replacement: &self.replacements[index],
                        original_bytes: &entry.original.bytes,
                        replacement_bytes: &entry.replacement.bytes,
                    },
                )
            }
        }
        for interrupted in [false, true] {
            let path = std::env::temp_dir().join(format!(
                "macshell-coordinator-{}-{}",
                std::process::id(),
                ID.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            let dir = TestDir(path);
            let root = File::open(&dir.0).unwrap();
            let root_meta = root.metadata().unwrap();
            let mut entries = Vec::new();
            let mut originals = Vec::new();
            let mut replacements = Vec::new();
            for target in ["a.kdl", "b.kdl"] {
                fs::write(dir.0.join(target), b"old").unwrap();
                let original = File::open(dir.0.join(target)).unwrap();
                let staging::StageResult::Ready(staged) =
                    staging::stage(&root, OsStr::new(target), &original, b"old", b"new").unwrap()
                else {
                    panic!("staging failed")
                };
                let version = |file: &File, bytes: &[u8]| {
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
                entries.push(Entry {
                    target: target.into(),
                    candidate: staged.name.to_str().unwrap().into(),
                    original: version(&original, b"old"),
                    replacement: version(&staged.file, b"new"),
                });
                originals.push(original);
                replacements.push(staged.file);
            }
            let manifest = Manifest {
                profile_device: root_meta.dev(),
                profile_inode: root_meta.ino(),
                entries,
            };
            let journal = OsStr::new(".macshell-input-journal-0123456789abcdef0123456789abcdef");
            assert!(matches!(
                journal_store::create(&root, journal, &manifest).unwrap(),
                journal_store::CreateResult::Durable
            ));
            let mut disk = Disk {
                root: &root,
                journal,
                manifest: &manifest,
                originals,
                replacements,
                fail_on_completion: interrupted,
            };
            let outcome = run(&manifest, &mut disk).unwrap();
            drop(disk);
            drop(root);
            let root = File::open(&dir.0).unwrap();
            let report = recovery::inspect_journal(&root, journal).unwrap();
            if interrupted {
                assert_eq!(
                    outcome,
                    Outcome::Interrupted {
                        index: Some(0),
                        stage: Stage::Completion,
                        reason: Reason::Io {
                            kind: io::ErrorKind::Other,
                            message: "injected interruption".into()
                        },
                    }
                );
                assert_eq!(
                    report.agreement,
                    recovery::ProgressAgreement::PendingExchange
                );
                assert_eq!(
                    report.files.files,
                    [
                        recovery::Observation::Exchanged,
                        recovery::Observation::Original
                    ]
                );
            } else {
                assert_eq!(outcome, Outcome::Complete);
                assert_eq!(report.agreement, recovery::ProgressAgreement::Consistent);
                assert_eq!(
                    report.files.profile,
                    recovery::ProfileObservation::AllExchanged
                );
            }
        }
    }
}
