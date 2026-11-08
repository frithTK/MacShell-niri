//! Bounded, in-memory manifest codec. This module does not write a journal,
//! establish provenance, authorize recovery, or persist progress.
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::path::Path;

const MAX_FILES: usize = 1024;
const MAX_FILE_BYTES: usize = 2 * 1024 * 1024;
const MAX_BYTES: usize = 32 * 1024 * 1024;
// Hex encoding doubles the payload; leave bounded room for paths and metadata.
pub(crate) const MAX_ENCODED: usize = 2 * MAX_BYTES + 2 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileVersion {
    pub device: u64,
    pub inode: u64,
    pub mode: u32,
    pub uid: u32,
    pub gid: u32,
    pub nlink: u64,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub target: String,
    pub candidate: String,
    pub original: FileVersion,
    pub replacement: FileVersion,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    pub profile_device: u64,
    pub profile_inode: u64,
    pub entries: Vec<Entry>,
}

fn invalid() -> String {
    "Invalid input transaction manifest".into()
}

fn relative(path: &str) -> bool {
    !path.is_empty()
        && path.len() <= 4096
        && !path.contains('\0')
        && path.split('/').count() <= 32
        && path
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != ".." && part.len() <= 255)
}

impl Manifest {
    pub fn validate(&self) -> Result<(), String> {
        if self.entries.is_empty() || self.entries.len() > MAX_FILES || self.profile_inode == 0 {
            return Err(invalid());
        }
        let mut names = BTreeSet::new();
        let mut identities = BTreeSet::new();
        let mut total = 0usize;
        for entry in &self.entries {
            let target = Path::new(&entry.target);
            let candidate = Path::new(&entry.candidate);
            let candidate_name = candidate
                .file_name()
                .and_then(|n| n.to_str())
                .ok_or_else(invalid)?;
            let suffix = candidate_name
                .strip_prefix(".macshell-input-")
                .ok_or_else(invalid)?;
            if !relative(&entry.target)
                || !relative(&entry.candidate)
                || target.extension().is_none_or(|v| v != "kdl")
                || target.parent() != candidate.parent()
                || suffix.len() != 32
                || !suffix
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                || !names.insert(&entry.target)
                || !names.insert(&entry.candidate)
                || entry.original.inode == 0
                || entry.replacement.inode == 0
                || entry.original.device != entry.replacement.device
                || (entry.original.device, entry.original.inode)
                    == (entry.replacement.device, entry.replacement.inode)
            {
                return Err(invalid());
            }
            for version in [&entry.original, &entry.replacement] {
                if version.bytes.len() > MAX_FILE_BYTES
                    || version.mode & libc::S_IFMT != libc::S_IFREG
                    || version.nlink != 1
                    || !identities.insert((version.device, version.inode))
                {
                    return Err(invalid());
                }
                total = total.checked_add(version.bytes.len()).ok_or_else(invalid)?;
                if total > MAX_BYTES {
                    return Err(invalid());
                }
            }
        }
        Ok(())
    }

    /// Encode only validated metadata. The returned bytes include configuration
    /// contents and must be treated as private by any future persistence layer.
    pub fn encode(&self) -> Result<Vec<u8>, String> {
        self.validate()?;
        fn version(value: &FileVersion) -> Value {
            let mut hex = String::with_capacity(value.bytes.len() * 2);
            const DIGITS: &[u8; 16] = b"0123456789abcdef";
            for b in &value.bytes {
                hex.push(DIGITS[(b >> 4) as usize] as char);
                hex.push(DIGITS[(b & 15) as usize] as char);
            }
            json!({"device":value.device,"inode":value.inode,"mode":value.mode,"uid":value.uid,"gid":value.gid,"nlink":value.nlink,"bytes":hex})
        }
        let entries: Vec<Value> = self.entries.iter().map(|e| json!({"target":e.target,"candidate":e.candidate,"original":version(&e.original),"replacement":version(&e.replacement)})).collect();
        let encoded = serde_json::to_vec(&json!({"version":1,"profile_device":self.profile_device,"profile_inode":self.profile_inode,"entries":entries})).map_err(|_| invalid())?;
        if encoded.len() > MAX_ENCODED {
            return Err(invalid());
        }
        Ok(encoded)
    }

    /// Decode untrusted bytes and reject malformed or ambiguous paths. A valid
    /// manifest alone is not proof of ownership or permission to modify files.
    pub fn decode(input: &[u8]) -> Result<Self, String> {
        if input.len() > MAX_ENCODED {
            return Err(invalid());
        }
        let value: Value = serde_json::from_slice(input).map_err(|_| invalid())?;
        fn exact(value: &Value, keys: &[&str]) -> Result<(), String> {
            let map = value.as_object().ok_or_else(invalid)?;
            if map.len() != keys.len() || keys.iter().any(|key| !map.contains_key(*key)) {
                return Err(invalid());
            }
            Ok(())
        }
        fn num(v: &Value, key: &str) -> Result<u64, String> {
            v[key].as_u64().ok_or_else(invalid)
        }
        fn version(value: &Value) -> Result<FileVersion, String> {
            exact(
                value,
                &["device", "inode", "mode", "uid", "gid", "nlink", "bytes"],
            )?;
            let text = value["bytes"].as_str().ok_or_else(invalid)?;
            if text.len() > 2 * MAX_FILE_BYTES || text.len() % 2 != 0 {
                return Err(invalid());
            }
            let mut bytes = Vec::with_capacity(text.len() / 2);
            let nibble = |b| match b {
                b'0'..=b'9' => Some(b - b'0'),
                b'a'..=b'f' => Some(b - b'a' + 10),
                _ => None,
            };
            for pair in text.as_bytes().chunks_exact(2) {
                bytes.push(
                    (nibble(pair[0]).ok_or_else(invalid)? << 4)
                        | nibble(pair[1]).ok_or_else(invalid)?,
                );
            }
            Ok(FileVersion {
                device: num(value, "device")?,
                inode: num(value, "inode")?,
                mode: num(value, "mode")?.try_into().map_err(|_| invalid())?,
                uid: num(value, "uid")?.try_into().map_err(|_| invalid())?,
                gid: num(value, "gid")?.try_into().map_err(|_| invalid())?,
                nlink: num(value, "nlink")?,
                bytes,
            })
        }
        exact(
            &value,
            &["version", "profile_device", "profile_inode", "entries"],
        )?;
        if num(&value, "version")? != 1 {
            return Err(invalid());
        }
        let items = value["entries"].as_array().ok_or_else(invalid)?;
        if items.is_empty() || items.len() > MAX_FILES {
            return Err(invalid());
        }
        let mut entries = Vec::with_capacity(items.len());
        for item in items {
            exact(item, &["target", "candidate", "original", "replacement"])?;
            entries.push(Entry {
                target: item["target"].as_str().ok_or_else(invalid)?.into(),
                candidate: item["candidate"].as_str().ok_or_else(invalid)?.into(),
                original: version(&item["original"])?,
                replacement: version(&item["replacement"])?,
            });
        }
        let result = Self {
            profile_device: num(&value, "profile_device")?,
            profile_inode: num(&value, "profile_inode")?,
            entries,
        };
        result.validate()?;
        // Requiring our exact encoding rejects duplicate JSON keys, alternative
        // spellings and trailing bytes rather than silently normalizing them.
        if result.encode()? != input {
            return Err(invalid());
        }
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest() -> Manifest {
        let version = |inode, bytes: &[u8]| FileVersion {
            device: 1,
            inode,
            mode: libc::S_IFREG | 0o600,
            uid: 1000,
            gid: 1000,
            nlink: 1,
            bytes: bytes.to_vec(),
        };
        Manifest {
            profile_device: 1,
            profile_inode: 2,
            entries: vec![Entry {
                target: "nested/input.kdl".into(),
                candidate: "nested/.macshell-input-0123456789abcdef0123456789abcdef".into(),
                original: version(3, b"old\0bytes"),
                replacement: version(4, b"new"),
            }],
        }
    }

    #[test]
    fn round_trip_preserves_exact_bytes_and_metadata() {
        let original = manifest();
        assert_eq!(
            Manifest::decode(&original.encode().unwrap()).unwrap(),
            original
        );
    }

    #[test]
    fn rejects_dangerous_and_duplicate_paths() {
        for target in [
            "/tmp/input.kdl",
            "../input.kdl",
            "nested/../input.kdl",
            "nested//input.kdl",
            "nested/./input.kdl",
            "nested/input.txt",
            "nested/\0.kdl",
        ] {
            let mut value = manifest();
            value.entries[0].target = target.into();
            assert!(value.encode().is_err(), "{target:?}");
        }
        let mut value = manifest();
        value.entries[0].candidate = ".macshell-input-0123456789abcdef0123456789abcdef".into();
        assert!(value.encode().is_err());
        let mut value = manifest();
        value.entries.push(value.entries[0].clone());
        assert!(value.encode().is_err());
    }

    #[test]
    fn rejects_corruption_noncanonical_json_and_oversized_entries() {
        let encoded = manifest().encode().unwrap();
        let mut duplicate = encoded.clone();
        duplicate.splice(1..1, b"\"version\":1,".iter().copied());
        assert!(Manifest::decode(&duplicate).is_err());
        let mut trailing = encoded.clone();
        trailing.push(b' ');
        assert!(Manifest::decode(&trailing).is_err());
        assert!(Manifest::decode(&encoded[..encoded.len() - 1]).is_err());
        let mut value = manifest();
        value.entries[0]
            .replacement
            .bytes
            .resize(MAX_FILE_BYTES + 1, 0);
        assert!(value.encode().is_err());
        let mut value = manifest();
        value.entries[0].original.mode = libc::S_IFLNK | 0o777;
        assert!(value.encode().is_err());
    }
}
