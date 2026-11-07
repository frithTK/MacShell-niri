use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

const LIMIT: usize = 262_144;
pub trait Schema {
    fn version(&self) -> u64;
    fn label(&self) -> &str;
    fn defaults(&self) -> &Map<String, Value>;
    fn normalize(&self, source: &Value, strict: bool) -> (Value, Map<String, Value>);

    // Optional owned keys must be compared and persisted without being injected
    // into older documents where they were absent.
    fn optional_keys(&self) -> &[&str] {
        &[]
    }

    // Migration is a read-time preview; the original file is only replaced by
    // a subsequent commit under the same lock and token check as any edit.
    fn source_values(&self, source: &Value, _version: u64) -> Value {
        source.clone()
    }

    fn read_guard(&self, _source: &Value, _version: u64, _needs_repair: bool) -> Option<ReadGuard> {
        None
    }

    fn state_fields(&self, _source: &Value, _version: u64) -> Map<String, Value> {
        Map::new()
    }
}

pub struct ReadGuard {
    pub notice: String,
    pub can_recover: bool,
}

fn random_hex() -> io::Result<String> {
    let mut bytes = [0u8; 16];
    let mut filled = 0;
    while filled < bytes.len() {
        let count = unsafe {
            libc::getrandom(bytes[filled..].as_mut_ptr().cast(), bytes.len() - filled, 0)
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
                "random source closed",
            ));
        }
        filled += count as usize;
    }
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

struct Temporary {
    path: PathBuf,
    armed: bool,
}
impl Drop for Temporary {
    fn drop(&mut self) {
        if self.armed {
            let _ = fs::remove_file(&self.path);
        }
    }
}

pub fn atomic_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let directory = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "Missing settings directory"))?;
    fs::create_dir_all(directory)?;
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "Missing settings name"))?
        .to_string_lossy();
    let temporary_path = directory.join(format!(".{name}-{}", random_hex()?));
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary_path)?;
    let mut temporary = Temporary {
        path: temporary_path,
        armed: true,
    };
    output.write_all(bytes)?;
    output.flush()?;
    output.sync_all()?;
    drop(output);
    fs::rename(&temporary.path, path)?;
    temporary.armed = false;
    File::open(directory)?.sync_all()?;
    Ok(())
}

fn token(raw: Option<&[u8]>) -> String {
    raw.map_or_else(
        || "missing".to_owned(),
        |raw| format!("{:x}", Sha256::digest(raw)),
    )
}

fn nonnegative_integer(value: &Value) -> Option<String> {
    if !value.is_number() {
        return None;
    }
    let text = value.to_string();
    if text == "-0" {
        return Some("0".to_owned());
    }
    if !text.is_empty() && text.bytes().all(|byte| byte.is_ascii_digit()) {
        Some(text)
    } else {
        None
    }
}

fn next_revision(value: &Value) -> io::Result<Value> {
    let mut digits = nonnegative_integer(value)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "Invalid settings revision"))?
        .into_bytes();
    let mut carry = true;
    for digit in digits.iter_mut().rev() {
        if *digit < b'9' {
            *digit += 1;
            carry = false;
            break;
        }
        *digit = b'0';
    }
    if carry {
        digits.insert(0, b'1');
    }
    serde_json::from_slice(&digits).map_err(io::Error::other)
}

struct State {
    values: Value,
    token: String,
    revision: Value,
    read_only: bool,
    can_recover: bool,
    notice: String,
    migration_pending: bool,
    needs_repair: bool,
    document: Value,
    raw: Option<Vec<u8>>,
    extra: Map<String, Value>,
}

impl State {
    fn public(&self) -> Value {
        let mut public = json!({"values": self.values, "token": self.token, "revision": self.revision,
            "readOnly": self.read_only, "canRecover": self.can_recover, "notice": self.notice,
            "migrationPending": self.migration_pending, "needsRepair": self.needs_repair});
        let object = public.as_object_mut().unwrap();
        for (key, value) in &self.extra {
            object.entry(key.clone()).or_insert_with(|| value.clone());
        }
        public
    }
}

pub struct Store<S: Schema> {
    path: PathBuf,
    pub schema: S,
}

impl<S: Schema> Store<S> {
    pub fn new(path: PathBuf, schema: S) -> Self {
        Self { path, schema }
    }

    fn read(&self) -> State {
        let mut raw = None;
        let mut document = json!({});
        let mut corrupt = false;
        let mut version = 0;
        let loaded = match File::open(&self.path) {
            Ok(file) => {
                let mut bytes = Vec::new();
                match file.take((LIMIT + 1) as u64).read_to_end(&mut bytes) {
                    Ok(_) => {
                        raw = Some(bytes);
                        true
                    }
                    Err(_) => {
                        corrupt = true;
                        false
                    }
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => false,
            Err(_) => {
                corrupt = true;
                false
            }
        };
        if loaded {
            let bytes = raw.as_ref().unwrap();
            let parsed = if bytes.len() > LIMIT {
                None
            } else {
                serde_json::from_slice::<Value>(bytes).ok()
            };
            if let Some(candidate) = parsed.filter(Value::is_object) {
                let version_value = candidate.get("version");
                let parsed_version = match version_value {
                    None => Some(0),
                    Some(value) => {
                        nonnegative_integer(value).map(|number| number.parse().unwrap_or(u64::MAX))
                    }
                };
                let valid = parsed_version.is_some_and(|v| {
                    v > self.schema.version() || {
                        let values_valid = candidate.get("values").is_none_or(Value::is_object)
                            && (v == 0 || candidate.get("values").is_some());
                        let revision_valid = candidate
                            .get("revision")
                            .is_none_or(|value| nonnegative_integer(value).is_some());
                        values_valid && revision_valid
                    }
                });
                if valid {
                    version = parsed_version.unwrap();
                    document = candidate;
                } else {
                    corrupt = true;
                }
            } else {
                corrupt = true;
            }
        }
        let future = version > self.schema.version();
        let source = document.get("values").cloned().unwrap_or_else(|| {
            if version == 0 {
                document.clone()
            } else {
                json!({})
            }
        });
        let migrated = self.schema.source_values(&source, version);
        let (values, errors) = self.schema.normalize(&migrated, false);
        let mut notice = String::new();
        let label = self.schema.label();
        if corrupt {
            notice = format!("{label} settings could not be read. Restore defaults to edit them; the original file will be kept.");
        }
        if future {
            notice = format!("These {label} settings were saved by a newer MacShell. Update MacShell to edit them.");
        } else if !errors.is_empty() && !corrupt {
            notice = format!("Some saved {label} values were invalid. Defaults are shown for those fields; Apply saves the corrected values.");
        }
        if corrupt && raw.as_ref().is_none_or(|bytes| bytes.len() > LIMIT) {
            notice = format!("{label} settings could not be read. Check file access and size, or restore a backup.");
        }
        let revision = document
            .get("revision")
            .and_then(nonnegative_integer)
            .and_then(|number| serde_json::from_str(&number).ok())
            .unwrap_or_else(|| json!(0));
        let mut read_only = corrupt || future;
        let mut can_recover = corrupt && raw.as_ref().is_some_and(|bytes| bytes.len() <= LIMIT);
        if !read_only {
            if let Some(guard) = self.schema.read_guard(&source, version, !errors.is_empty()) {
                read_only = true;
                can_recover =
                    guard.can_recover && raw.as_ref().is_some_and(|bytes| bytes.len() <= LIMIT);
                notice = guard.notice;
            }
        }
        State {
            values,
            token: token(raw.as_deref()),
            revision,
            read_only,
            can_recover,
            notice,
            migration_pending: raw.is_some() && version < self.schema.version() && !corrupt,
            needs_repair: !errors.is_empty(),
            document,
            raw,
            extra: self.schema.state_fields(&source, version),
        }
    }

    pub fn load(&self) -> Value {
        self.read().public()
    }

    pub fn commit(
        &self,
        candidate: &Value,
        expected: Option<&str>,
        recover: bool,
    ) -> io::Result<Value> {
        self.commit_with(candidate, expected, recover, &atomic_write)
    }

    fn commit_with(
        &self,
        candidate: &Value,
        expected: Option<&str>,
        recover: bool,
        write: &dyn Fn(&Path, &[u8]) -> io::Result<()>,
    ) -> io::Result<Value> {
        let directory = self.path.parent().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "Missing settings directory")
        })?;
        fs::create_dir_all(directory)?;
        let name = self
            .path
            .file_name()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "Missing settings name"))?
            .to_string_lossy();
        let lock_path = directory.join(format!(".{name}.lock"));
        let lock = OpenOptions::new()
            .read(true)
            .append(true)
            .create(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(lock_path)?;
        loop {
            if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) } == 0 {
                break;
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
        let state = self.read();
        let label = self.schema.label();
        if Some(state.token.as_str()) != expected {
            return Ok(
                json!({"success":false, "conflict":true, "error":format!("{label} settings changed elsewhere. Reload before applying."), "state":state.public()}),
            );
        }
        if state.read_only && !(recover && state.can_recover) {
            return Ok(json!({"success":false, "error":state.notice, "state":state.public()}));
        }
        if recover && !state.can_recover {
            return Ok(
                json!({"success":false, "error":format!("There is no recoverable {label} file."), "state":state.public()}),
            );
        }
        if !candidate.is_object() {
            return Ok(
                json!({"success":false, "error":format!("Invalid {label} settings."), "state":state.public()}),
            );
        }
        let (values, errors) = self.schema.normalize(candidate, true);
        if !errors.is_empty() {
            return Ok(
                json!({"success":false, "error":errors.values().next().unwrap(), "errors":errors, "state":state.public()}),
            );
        }
        let keys: Vec<&str> = self
            .schema
            .defaults()
            .keys()
            .map(String::as_str)
            .chain(self.schema.optional_keys().iter().copied())
            .collect();
        if !recover
            && !state.migration_pending
            && !state.needs_repair
            && keys
                .iter()
                .all(|key| state.values.get(*key) == values.get(*key))
        {
            return Ok(json!({"success":true, "changed":false, "state":state.public()}));
        }
        let mut document = state.document.as_object().cloned().unwrap_or_default();
        let mut stored = document
            .get("values")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_else(|| {
                if state.migration_pending {
                    document.clone()
                } else {
                    Map::new()
                }
            });
        for key in keys {
            if let Some(value) = values.get(key) {
                stored.insert(key.to_owned(), value.clone());
            } else {
                stored.shift_remove(key);
            }
        }
        let revision = next_revision(&state.revision)?;
        document.insert("version".into(), json!(self.schema.version()));
        document.insert("revision".into(), revision);
        document.insert("values".into(), Value::Object(stored));
        let mut data = serde_json::to_vec_pretty(&document)?;
        data.push(b'\n');
        if data.len() > LIMIT {
            return Ok(
                json!({"success":false, "error":format!("{label} settings are too large."), "state":state.public()}),
            );
        }
        if let Some(raw) = &state.raw {
            let stem = self.path.file_stem().unwrap().to_string_lossy();
            let suffix = if recover {
                format!(".recovery-{}.json", random_hex()?)
            } else if state.migration_pending {
                format!(".before-v{}-{}.json", self.schema.version(), random_hex()?)
            } else {
                ".previous.json".to_owned()
            };
            write(&directory.join(format!("{stem}{suffix}")), raw)?;
        }
        write(&self.path, &data)?;
        Ok(json!({"success":true, "changed":true, "state":self.load()}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestSchema {
        defaults: Map<String, Value>,
    }
    impl Schema for TestSchema {
        fn version(&self) -> u64 {
            1
        }
        fn label(&self) -> &str {
            "Test"
        }
        fn defaults(&self) -> &Map<String, Value> {
            &self.defaults
        }
        fn normalize(&self, source: &Value, _: bool) -> (Value, Map<String, Value>) {
            let mut values = source.as_object().cloned().unwrap_or_default();
            for (key, value) in &self.defaults {
                values.entry(key.clone()).or_insert_with(|| value.clone());
            }
            (Value::Object(values), Map::new())
        }
    }

    struct MigratingSchema {
        defaults: Map<String, Value>,
        display: Option<String>,
    }
    impl Schema for MigratingSchema {
        fn version(&self) -> u64 {
            1
        }
        fn label(&self) -> &str {
            "Test"
        }
        fn defaults(&self) -> &Map<String, Value> {
            &self.defaults
        }
        fn optional_keys(&self) -> &[&str] {
            &["enabled"]
        }
        fn source_values(&self, source: &Value, version: u64) -> Value {
            let mut values = source.clone();
            if version == 0 {
                values["display"] = json!(self.display.as_deref().unwrap_or(""));
            }
            values
        }
        fn normalize(&self, source: &Value, _: bool) -> (Value, Map<String, Value>) {
            let mut values = source.as_object().cloned().unwrap_or_default();
            for (key, value) in &self.defaults {
                values.entry(key.clone()).or_insert_with(|| value.clone());
            }
            let mut errors = Map::new();
            if values.get("display") == Some(&json!("invalid")) {
                errors.insert("display".into(), json!("Invalid display"));
            }
            (Value::Object(values), errors)
        }
        fn read_guard(
            &self,
            source: &Value,
            version: u64,
            needs_repair: bool,
        ) -> Option<ReadGuard> {
            if version == 0 && source.get("widgets").is_some() && self.display.is_none() {
                Some(ReadGuard {
                    notice: "Waiting for display".into(),
                    can_recover: false,
                })
            } else if needs_repair {
                Some(ReadGuard {
                    notice: "Invalid settings".into(),
                    can_recover: true,
                })
            } else {
                None
            }
        }
        fn state_fields(&self, source: &Value, version: u64) -> Map<String, Value> {
            json!({"awaitingDisplay": version == 0 && source.get("widgets").is_some() && self.display.is_none(),
                "readOnly": false}).as_object().unwrap().clone()
        }
    }

    #[test]
    fn migration_guard_optional_fields_and_concurrent_tokens() {
        let root = std::env::temp_dir().join(format!(
            "macshell-store-migration-{}-{}",
            std::process::id(),
            random_hex().unwrap()
        ));
        fs::create_dir(&root).unwrap();
        let path = root.join("settings.json");
        let original = br#"{"widgets":[{"id":"old"}],"extension":{"preserve":true}}"#;
        fs::write(&path, original).unwrap();
        let schema = MigratingSchema {
            defaults: json!({"display":""}).as_object().unwrap().clone(),
            display: None,
        };
        let mut store = Store::new(path.clone(), schema);
        let waiting = store.load();
        assert_eq!(waiting["awaitingDisplay"], true);
        assert_eq!(waiting["readOnly"], true); // Extra fields cannot override protections.
        assert_eq!(waiting["canRecover"], false);
        assert_eq!(
            store
                .commit(&waiting["values"], waiting["token"].as_str(), false)
                .unwrap()["success"],
            false
        );
        assert_eq!(fs::read(&path).unwrap(), original);
        store.schema.display = Some("DP-1".into());
        let preview = store.load();
        assert_eq!(preview["values"]["display"], "DP-1");
        let result = store
            .commit(&preview["values"], preview["token"].as_str(), false)
            .unwrap();
        assert_eq!(result["success"], true);
        assert_eq!(result["state"]["migrationPending"], false);
        let backups: Vec<_> = fs::read_dir(&root)
            .unwrap()
            .flatten()
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("settings.before-v1-")
            })
            .collect();
        assert_eq!(backups.len(), 1);
        assert_eq!(fs::read(backups[0].path()).unwrap(), original);
        store.schema.display = Some("HDMI-1".into());
        let first = store.load();
        assert_eq!(first["values"]["display"], "DP-1");
        assert!(first["values"].get("enabled").is_none());
        let mut changed = first["values"].clone();
        changed["enabled"] = json!(false);
        let saved = store
            .commit(&changed, first["token"].as_str(), false)
            .unwrap();
        assert_eq!(saved["state"]["values"]["enabled"], false);
        assert_eq!(
            store
                .commit(&first["values"], first["token"].as_str(), false)
                .unwrap()["conflict"],
            true
        );
        changed.as_object_mut().unwrap().remove("enabled");
        let removed = store
            .commit(&changed, saved["state"]["token"].as_str(), false)
            .unwrap();
        assert!(removed["state"]["values"].get("enabled").is_none());
        let written: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(written["values"]["extension"]["preserve"], true);
        assert!(written["values"].get("enabled").is_none());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn schema_repair_guard_requires_explicit_recovery() {
        let root = std::env::temp_dir().join(format!(
            "macshell-store-repair-{}-{}",
            std::process::id(),
            random_hex().unwrap()
        ));
        fs::create_dir(&root).unwrap();
        let path = root.join("settings.json");
        let original = br#"{"version":1,"values":{"display":"invalid"}}"#;
        fs::write(&path, original).unwrap();
        let store = Store::new(
            path.clone(),
            MigratingSchema {
                defaults: json!({"display":""}).as_object().unwrap().clone(),
                display: None,
            },
        );
        let state = store.load();
        assert_eq!(state["readOnly"], true);
        assert_eq!(state["canRecover"], true);
        let defaults = json!({"display":""});
        assert_eq!(
            store
                .commit(&defaults, state["token"].as_str(), false)
                .unwrap()["success"],
            false
        );
        assert_eq!(fs::read(&path).unwrap(), original);
        assert_eq!(
            store
                .commit(&defaults, state["token"].as_str(), true)
                .unwrap()["success"],
            true
        );
        assert!(fs::read_dir(&root).unwrap().flatten().any(|entry| entry
            .file_name()
            .to_string_lossy()
            .starts_with("settings.recovery-")));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn simultaneous_writers_cannot_both_commit_the_same_token() {
        use std::sync::{Arc, Barrier};
        use std::thread;

        let root = std::env::temp_dir().join(format!(
            "macshell-store-race-{}-{}",
            std::process::id(),
            random_hex().unwrap()
        ));
        fs::create_dir(&root).unwrap();
        let path = root.join("settings.json");
        let make_store = || {
            Store::new(
                path.clone(),
                MigratingSchema {
                    defaults: json!({"display":""}).as_object().unwrap().clone(),
                    display: None,
                },
            )
        };
        let initial = make_store().load();
        let barrier = Arc::new(Barrier::new(2));
        let mut writers = Vec::new();
        for display in ["DP-1", "HDMI-1"] {
            let store = make_store();
            let token = initial["token"].as_str().unwrap().to_owned();
            let barrier = Arc::clone(&barrier);
            writers.push(thread::spawn(move || {
                barrier.wait();
                store
                    .commit(&json!({"display":display}), Some(&token), false)
                    .unwrap()
            }));
        }
        let results: Vec<Value> = writers
            .into_iter()
            .map(|writer| writer.join().unwrap())
            .collect();
        assert_eq!(
            results
                .iter()
                .filter(|result| result["success"] == true)
                .count(),
            1
        );
        assert_eq!(
            results
                .iter()
                .filter(|result| result["conflict"] == true)
                .count(),
            1
        );
        let saved = make_store().load();
        assert!(matches!(
            saved["values"]["display"].as_str(),
            Some("DP-1" | "HDMI-1")
        ));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn concurrent_migrations_bind_once_and_keep_original_backup() {
        use std::sync::{Arc, Barrier};
        use std::thread;

        let root = std::env::temp_dir().join(format!(
            "macshell-store-migrate-race-{}-{}",
            std::process::id(),
            random_hex().unwrap()
        ));
        fs::create_dir(&root).unwrap();
        let path = root.join("settings.json");
        let original = br#"{"widgets":[{"id":"old"}]}"#;
        fs::write(&path, original).unwrap();
        let barrier = Arc::new(Barrier::new(2));
        let mut writers = Vec::new();
        for display in ["DP-1", "HDMI-1"] {
            let store = Store::new(
                path.clone(),
                MigratingSchema {
                    defaults: json!({"display":""}).as_object().unwrap().clone(),
                    display: Some(display.into()),
                },
            );
            let preview = store.load();
            let barrier = Arc::clone(&barrier);
            writers.push(thread::spawn(move || {
                barrier.wait();
                store
                    .commit(&preview["values"], preview["token"].as_str(), false)
                    .unwrap()
            }));
        }
        let results: Vec<Value> = writers
            .into_iter()
            .map(|writer| writer.join().unwrap())
            .collect();
        assert_eq!(
            results
                .iter()
                .filter(|result| result["success"] == true)
                .count(),
            1
        );
        assert_eq!(
            results
                .iter()
                .filter(|result| result["conflict"] == true)
                .count(),
            1
        );
        let winner = results
            .iter()
            .find(|result| result["success"] == true)
            .unwrap();
        let document: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(
            document["values"]["display"],
            winner["state"]["values"]["display"]
        );
        let backups: Vec<_> = fs::read_dir(&root)
            .unwrap()
            .flatten()
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("settings.before-v1-")
            })
            .collect();
        assert_eq!(backups.len(), 1);
        assert_eq!(fs::read(backups[0].path()).unwrap(), original);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn schema_guard_cannot_override_corrupt_or_future_file_protection() {
        let root = std::env::temp_dir().join(format!(
            "macshell-store-protection-{}-{}",
            std::process::id(),
            random_hex().unwrap()
        ));
        fs::create_dir(&root).unwrap();
        let path = root.join("settings.json");
        let store = Store::new(
            path.clone(),
            MigratingSchema {
                defaults: json!({"display":""}).as_object().unwrap().clone(),
                display: None,
            },
        );
        for raw in [
            b"{broken".as_slice(),
            br#"{"version":99,"values":{"display":"invalid"}}"#.as_slice(),
        ] {
            fs::write(&path, raw).unwrap();
            let state = store.load();
            assert_eq!(state["readOnly"], true);
            assert_eq!(
                store
                    .commit(&json!({"display":""}), state["token"].as_str(), false)
                    .unwrap()["success"],
                false
            );
            assert_eq!(fs::read(&path).unwrap(), raw);
            if raw.starts_with(br#"{"version"#) {
                assert_eq!(state["canRecover"], false);
                assert_eq!(
                    store
                        .commit(&json!({"display":""}), state["token"].as_str(), true)
                        .unwrap()["success"],
                    false
                );
            }
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn failed_replace_preserves_original_and_removes_temporary_file() {
        let root = std::env::temp_dir().join(format!(
            "macshell-activity-test-{}-{}",
            std::process::id(),
            random_hex().unwrap()
        ));
        fs::create_dir(&root).unwrap();
        let path = root.join("activity-appearance.json");
        let schema = TestSchema {
            defaults: json!({"cpuWarning":65}).as_object().unwrap().clone(),
        };
        let store = Store::new(path.clone(), schema);
        let original =
            serde_json::to_vec(&json!({"version":1,"revision":1,"values":store.schema.defaults}))
                .unwrap();
        fs::write(&path, &original).unwrap();
        let snapshot = store.load();
        let mut changed = snapshot["values"].clone();
        changed["cpuWarning"] = json!(25);
        let result = store.commit_with(
            &changed,
            snapshot["token"].as_str(),
            false,
            &|destination, data| {
                if destination == path {
                    return Err(io::Error::other("simulated replace failure"));
                }
                atomic_write(destination, data)
            },
        );
        assert!(result.is_err());
        assert_eq!(fs::read(&path).unwrap(), original);
        assert!(!fs::read_dir(&root).unwrap().flatten().any(|entry| entry
            .file_name()
            .to_string_lossy()
            .starts_with(".activity-appearance.json-")));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn atomic_write_cleans_stage_when_rename_fails() {
        let root = std::env::temp_dir().join(format!(
            "macshell-activity-atomic-{}-{}",
            std::process::id(),
            random_hex().unwrap()
        ));
        fs::create_dir(&root).unwrap();
        let destination = root.join("settings.json");
        fs::create_dir(&destination).unwrap();
        fs::write(destination.join("keep"), b"original").unwrap();
        assert!(atomic_write(&destination, b"replacement").is_err());
        assert_eq!(fs::read(destination.join("keep")).unwrap(), b"original");
        assert_eq!(fs::read_dir(&root).unwrap().count(), 1);
        fs::remove_dir_all(root).unwrap();
    }
}
