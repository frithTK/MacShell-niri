//! Shared locale document contract for Settings and session startup.
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, OpenOptions};
use std::io::{self, Read};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

pub const HEADER: &str = "# MacShell locale preferences v1";
pub const REGIONAL: [&str; 9] = [
    "LC_NUMERIC",
    "LC_TIME",
    "LC_MONETARY",
    "LC_PAPER",
    "LC_NAME",
    "LC_ADDRESS",
    "LC_TELEPHONE",
    "LC_MEASUREMENT",
    "LC_IDENTIFICATION",
];
pub type Environment = BTreeMap<String, String>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LocaleError {
    pub code: &'static str,
    pub detail: String,
}
impl LocaleError {
    pub fn new(code: &'static str) -> Self {
        Self {
            code,
            detail: String::new(),
        }
    }
    pub fn detail(code: &'static str, detail: impl Into<String>) -> Self {
        Self {
            code,
            detail: detail.into(),
        }
    }
}
impl From<io::Error> for LocaleError {
    fn from(_: io::Error) -> Self {
        Self::new("io_error")
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Selection {
    pub ui: String,
    pub session: String,
    pub region: String,
}
impl Default for Selection {
    fn default() -> Self {
        Self {
            ui: "system".into(),
            session: "system".into(),
            region: "system".into(),
        }
    }
}
fn valid_value(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"_.@:-".contains(&c))
}
fn allowed(name: &str) -> bool {
    matches!(name, "LANG" | "LANGUAGE" | "LC_MESSAGES") || REGIONAL.contains(&name)
}

// Match Python splitlines(), including CRLF and Unicode line separators.
pub fn split_lines(text: &str) -> Vec<&str> {
    let mut result = Vec::new();
    let mut start = 0;
    let mut iter = text.char_indices().peekable();
    while let Some((pos, ch)) = iter.next() {
        if matches!(
            ch,
            '\n' | '\r'
                | '\u{000b}'
                | '\u{000c}'
                | '\u{001c}'
                | '\u{001d}'
                | '\u{001e}'
                | '\u{0085}'
                | '\u{2028}'
                | '\u{2029}'
        ) {
            result.push(&text[start..pos]);
            start = pos + ch.len_utf8();
            if ch == '\r' && iter.peek().is_some_and(|(_, c)| *c == '\n') {
                let (next, _) = iter.next().unwrap();
                start = next + 1;
            }
        }
    }
    if start < text.len() {
        result.push(&text[start..]);
    }
    result
}
pub fn parse(raw: Option<&[u8]>) -> Result<(Selection, Environment), LocaleError> {
    let Some(raw) = raw else {
        return Ok((Selection::default(), Environment::new()));
    };
    let text = std::str::from_utf8(raw).map_err(|_| LocaleError::new("invalid"))?;
    let lines = split_lines(text);
    if lines.first().copied() != Some(HEADER) {
        return Err(LocaleError::new("unowned_or_future"));
    }
    let mut prefs = BTreeMap::new();
    let mut env = Environment::new();
    for line in lines.iter().skip(1) {
        if line.trim().is_empty() {
            continue;
        }
        if let Some(comment) = line.strip_prefix("# ") {
            let (name, value) = comment
                .split_once('=')
                .ok_or_else(|| LocaleError::new("invalid"))?;
            if !["ui", "session", "region"].contains(&name)
                || !valid_value(value)
                || prefs.insert(name, value).is_some()
            {
                return Err(LocaleError::new("invalid"));
            }
        } else {
            let (name, value) = line
                .split_once('=')
                .ok_or_else(|| LocaleError::new("invalid"))?;
            if !allowed(name)
                || !valid_value(value)
                || env.insert(name.into(), value.into()).is_some()
            {
                return Err(LocaleError::new("invalid"));
            }
        }
    }
    if prefs.len() != 3
        || !prefs
            .get("ui")
            .is_some_and(|ui| ["system", "en", "ru"].contains(ui))
    {
        return Err(LocaleError::new("invalid"));
    }
    Ok((
        Selection {
            ui: prefs["ui"].into(),
            session: prefs["session"].into(),
            region: prefs["region"].into(),
        },
        env,
    ))
}

pub fn serialize(
    selection: &Selection,
    locales: &BTreeSet<String>,
) -> Result<(Vec<u8>, Environment), LocaleError> {
    if !["system", "en", "ru"].contains(&selection.ui.as_str()) {
        return Err(LocaleError::new("invalid_selection"));
    }
    for value in [&selection.session, &selection.region] {
        if !valid_value(value) {
            return Err(LocaleError::new("invalid_selection"));
        }
        if value != "system" && !locales.contains(value) {
            return Err(LocaleError::detail("locale_missing", value));
        }
    }
    let mut ordered = Vec::new();
    if selection.session != "system" {
        let value = &selection.session;
        ordered.push(("LANG", value.clone()));
        ordered.push(("LC_MESSAGES", value.clone()));
        let language = value.split(['_', '.', '@', '-']).next().unwrap();
        ordered.push((
            "LANGUAGE",
            if language == "en" {
                language.to_owned()
            } else {
                format!("{language}:en")
            },
        ));
    }
    if selection.region != "system" {
        for key in REGIONAL {
            ordered.push((key, selection.region.clone()));
        }
    }
    let mut text = format!(
        "{HEADER}\n# ui={}\n# session={}\n# region={}\n",
        selection.ui, selection.session, selection.region
    );
    let mut env = Environment::new();
    for (key, value) in ordered {
        text.push_str(&format!("{key}={value}\n"));
        env.insert(key.into(), value);
    }
    Ok((text.into_bytes(), env))
}

pub fn read_document(path: &Path) -> Result<Option<Vec<u8>>, LocaleError> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => return Err(LocaleError::new("symlink")),
        Ok(_) => (),
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.into()),
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|e| {
            if e.raw_os_error() == Some(libc::ELOOP) {
                LocaleError::new("symlink")
            } else {
                e.into()
            }
        })?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(LocaleError::new("io_error"));
    }
    if metadata.len() > 16384 {
        return Err(LocaleError::new("invalid"));
    }
    let mut raw = Vec::new();
    file.take(16385).read_to_end(&mut raw)?;
    if raw.len() > 16384 {
        return Err(LocaleError::new("invalid"));
    }
    Ok(Some(raw))
}

pub fn session_environment(
    raw: Option<&[u8]>,
    locales: &BTreeSet<String>,
    current: &Environment,
) -> Result<Environment, LocaleError> {
    let (selection, saved) = parse(raw)?;
    if raw.is_none() {
        return Ok(Environment::new());
    }
    let (_, expected) = serialize(&selection, locales)?;
    if saved != expected {
        return Err(LocaleError::new("invalid"));
    }
    if !expected.is_empty() && current.get("LC_ALL").is_some_and(|v| !v.is_empty()) {
        return Err(LocaleError::detail(
            "lc_all_conflict",
            current["LC_ALL"].clone(),
        ));
    }
    Ok(expected)
}

fn hash(raw: Option<&[u8]>) -> String {
    use sha2::{Digest, Sha256};
    raw.map_or_else(
        || "missing".to_owned(),
        |data| format!("{:x}", Sha256::digest(data)),
    )
}
pub fn selection_from_json(value: &serde_json::Value) -> Result<Selection, LocaleError> {
    let obj = value
        .as_object()
        .filter(|v| v.len() == 3)
        .ok_or_else(|| LocaleError::new("invalid_selection"))?;
    let field = |key: &str| {
        obj.get(key)
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| LocaleError::new("invalid_selection"))
    };
    Ok(Selection {
        ui: field("ui")?,
        session: field("session")?,
        region: field("region")?,
    })
}
pub fn load(
    path: &Path,
    locales: &BTreeSet<String>,
    current: &Environment,
) -> Result<serde_json::Value, LocaleError> {
    let raw = read_document(path)?;
    let (selection, saved) = parse(raw.as_deref())?;
    let mut known = locales.clone();
    known.insert(selection.session.clone());
    known.insert(selection.region.clone());
    let expected = if raw.is_some() {
        serialize(&selection, &known)?.1
    } else {
        Environment::new()
    };
    if saved != expected {
        return Err(LocaleError::new("invalid"));
    }
    let current_keys = ["LANG", "LANGUAGE", "LC_MESSAGES", "LC_ALL"]
        .into_iter()
        .chain(REGIONAL);
    let current: Environment = current_keys
        .map(|key| {
            (
                key.to_owned(),
                current.get(key).cloned().unwrap_or_default(),
            )
        })
        .collect();
    let pending = expected
        .iter()
        .any(|(key, value)| current.get(key) != Some(value));
    let missing: BTreeSet<_> = [&selection.session, &selection.region]
        .into_iter()
        .filter(|v| *v != "system" && !locales.contains(*v))
        .cloned()
        .collect();
    Ok(
        serde_json::json!({"values":{"ui":selection.ui,"session":selection.session,"region":selection.region},
        "token":hash(raw.as_deref()),"locales":locales,"current":current,"pending":pending,
        "conflict":current["LC_ALL"],"readOnly":false,"missing":missing}),
    )
}
pub fn save(
    path: &Path,
    values: &serde_json::Value,
    expected_token: Option<&str>,
    locales: &BTreeSet<String>,
    current: &Environment,
) -> Result<serde_json::Value, LocaleError> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::DirBuilderExt;
    let selection = selection_from_json(values)?;
    let (raw, _) = serialize(&selection, locales)?;
    if raw.len() > 16_384 {
        return Err(LocaleError::new("invalid_selection"));
    }
    if current.get("LC_ALL").is_some_and(|v| !v.is_empty())
        && (selection.session != "system" || selection.region != "system")
    {
        return Err(LocaleError::detail(
            "lc_all_conflict",
            current["LC_ALL"].clone(),
        ));
    }
    let parent = path.parent().ok_or_else(|| LocaleError::new("io_error"))?;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(parent)?;
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path.with_extension("lock"))?;
    loop {
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) } == 0 {
            break;
        }
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::Interrupted {
            return Err(e.into());
        }
    }
    let previous = read_document(path)?;
    if Some(hash(previous.as_deref()).as_str()) != expected_token {
        return Err(LocaleError::new("conflict"));
    }
    let (old_selection, old_environment) = parse(previous.as_deref())?;
    if previous.is_some() {
        let mut known = locales.clone();
        known.insert(old_selection.session.clone());
        known.insert(old_selection.region.clone());
        if serialize(&old_selection, &known)?.1 != old_environment {
            return Err(LocaleError::new("invalid"));
        }
    }
    if previous.as_deref() != Some(raw.as_slice()) {
        if let Some(previous) = previous {
            macshell_preferences_store::atomic_write(
                &path.with_extension("conf.previous"),
                &previous,
            )?;
        }
        macshell_preferences_store::atomic_write(path, &raw)?;
    }
    drop(lock);
    load(path, locales, current)
}
