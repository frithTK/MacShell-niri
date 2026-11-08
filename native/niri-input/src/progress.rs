//! Experimental in-memory progress ledger. It neither writes to disk nor
//! asserts that a filesystem operation happened or was made durable.
use crate::journal::Manifest;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

pub(crate) const MAX_LEDGER_BYTES: usize = 128 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    Intent(usize),
    Exchanged(usize),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ledger {
    manifest_hash: String,
    file_count: usize,
    events: Vec<Event>,
}

fn invalid() -> String {
    "Invalid input transaction progress".into()
}

pub(crate) fn manifest_hash(manifest: &Manifest) -> Result<String, String> {
    let bytes = manifest.encode()?;
    Ok(format!("{:x}", Sha256::digest(&bytes)))
}

impl Ledger {
    pub fn new(manifest: &Manifest) -> Result<Self, String> {
        Ok(Self {
            manifest_hash: manifest_hash(manifest)?,
            file_count: manifest.entries.len(),
            events: Vec::new(),
        })
    }

    pub fn events(&self) -> &[Event] {
        &self.events
    }

    /// Append only the next expected intent or completion in manifest order.
    /// The caller must durably record intent before issuing an exchange and
    /// report completion only after the exchange and directory sync succeed.
    pub fn push(&mut self, event: Event) -> Result<(), String> {
        let position = self.events.len();
        let index = position / 2;
        if index >= self.file_count {
            return Err(invalid());
        }
        let expected = if position % 2 == 0 {
            Event::Intent(index)
        } else {
            Event::Exchanged(index)
        };
        if event != expected {
            return Err(invalid());
        }
        self.events.push(event);
        Ok(())
    }

    pub fn encode(&self) -> Result<Vec<u8>, String> {
        let events: Vec<Value> = self
            .events
            .iter()
            .map(|event| match event {
                Event::Intent(index) => json!({"index":index,"kind":"intent"}),
                Event::Exchanged(index) => json!({"index":index,"kind":"exchanged"}),
            })
            .collect();
        let bytes = serde_json::to_vec(&json!({"version":1,"manifest_sha256":self.manifest_hash,"file_count":self.file_count,"events":events})).map_err(|_| invalid())?;
        if bytes.len() > MAX_LEDGER_BYTES {
            return Err(invalid());
        }
        Ok(bytes)
    }

    /// Decode only canonical JSON bound to these exact manifest bytes. SHA-256
    /// detects accidental differences; it does not authenticate either file.
    pub fn decode(bytes: &[u8], manifest: &Manifest) -> Result<Self, String> {
        let hash = manifest_hash(manifest)?;
        Self::decode_hashed(bytes, manifest, &hash)
    }

    pub(crate) fn decode_hashed(
        bytes: &[u8],
        manifest: &Manifest,
        hash: &str,
    ) -> Result<Self, String> {
        if bytes.len() > MAX_LEDGER_BYTES {
            return Err(invalid());
        }
        let value: Value = serde_json::from_slice(bytes).map_err(|_| invalid())?;
        let object = value.as_object().ok_or_else(invalid)?;
        if object.len() != 4 || value["version"].as_u64() != Some(1) {
            return Err(invalid());
        }
        let mut result = Self {
            manifest_hash: hash.to_owned(),
            file_count: manifest.entries.len(),
            events: Vec::new(),
        };
        if value["manifest_sha256"].as_str() != Some(&result.manifest_hash)
            || value["file_count"].as_u64() != Some(result.file_count as u64)
        {
            return Err(invalid());
        }
        let events = value["events"].as_array().ok_or_else(invalid)?;
        if events.len() > result.file_count * 2 {
            return Err(invalid());
        }
        for item in events {
            if item.as_object().is_none_or(|object| object.len() != 2) {
                return Err(invalid());
            }
            let index: usize = item["index"]
                .as_u64()
                .ok_or_else(invalid)?
                .try_into()
                .map_err(|_| invalid())?;
            let event = match item["kind"].as_str() {
                Some("intent") => Event::Intent(index),
                Some("exchanged") => Event::Exchanged(index),
                _ => return Err(invalid()),
            };
            result.push(event)?;
        }
        if result.encode()? != bytes {
            return Err(invalid());
        }
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::journal::{Entry, FileVersion};

    fn manifest() -> Manifest {
        let version = |inode| FileVersion {
            device: 1,
            inode,
            mode: libc::S_IFREG | 0o600,
            uid: 1,
            gid: 1,
            nlink: 1,
            bytes: vec![inode as u8],
        };
        Manifest {
            profile_device: 1,
            profile_inode: 2,
            entries: vec![
                Entry {
                    target: "a.kdl".into(),
                    candidate: ".macshell-input-0123456789abcdef0123456789abcdef".into(),
                    original: version(10),
                    replacement: version(11),
                },
                Entry {
                    target: "b.kdl".into(),
                    candidate: ".macshell-input-1123456789abcdef0123456789abcdef".into(),
                    original: version(12),
                    replacement: version(13),
                },
            ],
        }
    }

    #[test]
    fn accepts_only_ordered_intent_and_completion() {
        let mut ledger = Ledger::new(&manifest()).unwrap();
        assert!(ledger.push(Event::Exchanged(0)).is_err());
        assert!(ledger.push(Event::Intent(1)).is_err());
        ledger.push(Event::Intent(0)).unwrap();
        assert!(ledger.push(Event::Intent(0)).is_err());
        ledger.push(Event::Exchanged(0)).unwrap();
        ledger.push(Event::Intent(1)).unwrap();
        ledger.push(Event::Exchanged(1)).unwrap();
        assert!(ledger.push(Event::Intent(2)).is_err());
        assert_eq!(
            Ledger::decode(&ledger.encode().unwrap(), &manifest()).unwrap(),
            ledger
        );
    }

    #[test]
    fn rejects_changed_manifest_corruption_and_duplicate_json_keys() {
        let source = manifest();
        let mut ledger = Ledger::new(&source).unwrap();
        ledger.push(Event::Intent(0)).unwrap();
        let bytes = ledger.encode().unwrap();
        let mut changed = source.clone();
        changed.entries[0].original.bytes.push(3);
        assert!(Ledger::decode(&bytes, &changed).is_err());
        assert!(Ledger::decode(&bytes[..bytes.len() - 1], &source).is_err());
        let mut duplicate = bytes.clone();
        duplicate.splice(1..1, b"\"version\":1,".iter().copied());
        assert!(Ledger::decode(&duplicate, &source).is_err());
        let mut wrong = bytes.clone();
        let index = wrong
            .windows(b"intent".len())
            .position(|v| v == b"intent")
            .unwrap();
        wrong[index..index + 6].copy_from_slice(b"bogus!");
        assert!(Ledger::decode(&wrong, &source).is_err());
    }
}
