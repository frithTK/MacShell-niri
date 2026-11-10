use serde_json::{json, Value};
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};

pub const PROTOCOL: &str = "macshell-trash 1";

const SKIP_FS: &[&str] = &[
    "autofs",
    "binfmt_misc",
    "bpf",
    "cgroup",
    "cgroup2",
    "configfs",
    "debugfs",
    "devpts",
    "devtmpfs",
    "efivarfs",
    "fusectl",
    "hugetlbfs",
    "mqueue",
    "nsfs",
    "overlay",
    "proc",
    "pstore",
    "ramfs",
    "rpc_pipefs",
    "securityfs",
    "squashfs",
    "sysfs",
    "tmpfs",
    "tracefs",
];

#[derive(Clone, Debug)]
pub struct TrashEnv {
    pub home: PathBuf,
    pub extra_volumes: Vec<PathBuf>,
    pub scan_mounts: bool,
    pub uid: u32,
}

impl TrashEnv {
    pub fn from_os() -> Self {
        let uid = unsafe { libc::getuid() };
        let isolated = env::var_os("MACSHELL_TRASH_HOME");
        let home = isolated
            .as_ref()
            .map(PathBuf::from)
            .unwrap_or_else(default_home);
        let extra_volumes = env::var_os("MACSHELL_TRASH_MOUNTS")
            .map(|value| {
                env::split_paths(&value)
                    .filter(|path| !path.as_os_str().is_empty())
                    .collect()
            })
            .unwrap_or_default();
        Self {
            home,
            extra_volumes,
            scan_mounts: isolated.is_none(),
            uid,
        }
    }
}

fn default_home() -> PathBuf {
    env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| {
            PathBuf::from(env::var_os("HOME").unwrap_or_else(|| "/".into())).join(".local/share")
        })
        .join("Trash")
}

#[derive(Clone, Debug)]
struct Root {
    trash: PathBuf,
    topdir: Option<PathBuf>,
}

#[derive(Clone, Debug)]
pub struct Item {
    pub id: String,
    pub trash_name: String,
    pub name: String,
    pub path: PathBuf,
    pub info_path: PathBuf,
    pub original_path: PathBuf,
    pub original_dir: PathBuf,
    pub deleted_at: String,
    pub is_dir: bool,
    pub size: u64,
    pub volume: String,
}

impl Item {
    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "trashName": self.trash_name,
            "name": self.name,
            "path": path_string(&self.path),
            "originalPath": path_string(&self.original_path),
            "originalDir": path_string(&self.original_dir),
            "deletedAt": self.deleted_at,
            "isDir": self.is_dir,
            "size": self.size,
            "volume": self.volume,
            "restore": !self.original_path.as_os_str().is_empty(),
        })
    }
}

pub fn handle(action: &str, data: &Value, env: &TrashEnv) -> Value {
    match action {
        "list" | "state" => list_payload(env),
        "restore" => restore_payload(env, data),
        "empty" => empty_payload(env),
        _ => json!({"success": false, "error": "Unknown action"}),
    }
}

pub fn list_items(env: &TrashEnv) -> Vec<Item> {
    let mut items = Vec::new();
    for root in roots(env) {
        let _ = fs::create_dir_all(root.trash.join("files"));
        let _ = fs::create_dir_all(root.trash.join("info"));
        items.extend(list_root(&root));
    }
    items.sort_by(|a, b| {
        b.deleted_at
            .cmp(&a.deleted_at)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
            .then_with(|| a.id.cmp(&b.id))
    });
    items
}

pub fn restore(env: &TrashEnv, id: &str, as_name: &str) -> Result<Item, RestoreError> {
    let item = item_by_id(env, id).ok_or(RestoreError::Missing)?;
    if item.original_path.as_os_str().is_empty() {
        return Err(RestoreError::Invalid);
    }
    let file_name = if as_name.is_empty() {
        original_name(&item.original_path).ok_or(RestoreError::Invalid)?
    } else {
        safe_file_name(as_name).ok_or(RestoreError::Invalid)?
    };
    if file_name.is_empty() {
        return Err(RestoreError::Invalid);
    }
    let dest_dir = item
        .original_path
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("/"));
    if !dest_dir.exists() {
        return Err(if dest_dir.parent().map(Path::exists).unwrap_or(false) {
            RestoreError::MissingDir
        } else {
            RestoreError::MissingVolume
        });
    }
    let dest = dest_dir.join(&file_name);
    if dest.exists() || dest.symlink_metadata().is_ok() {
        return Err(RestoreError::Conflict {
            suggested: unique_name(&dest_dir, &file_name),
        });
    }
    if let Err(error) = fs::rename(&item.path, &dest) {
        if error.raw_os_error() == Some(libc::EXDEV) {
            return Err(RestoreError::CrossDevice);
        }
        return Err(io_restore(error));
    }
    let _ = fs::remove_file(&item.info_path);
    Ok(item)
}

pub fn empty(env: &TrashEnv) -> EmptyReport {
    let mut report = EmptyReport::default();
    for item in list_items(env) {
        match delete_item(&item) {
            Ok(()) => report.removed += 1,
            Err(error) => report.failed.push(Failed {
                id: item.id,
                error,
            }),
        }
    }
    for root in roots(env) {
        let _ = fs::remove_file(root.trash.join("directorysizes"));
        sweep_orphans(&root, &mut report);
    }
    report
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RestoreError {
    Missing,
    MissingDir,
    MissingVolume,
    Conflict { suggested: String },
    Denied,
    Invalid,
    CrossDevice,
    NotInTrash,
}

impl RestoreError {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Missing => "missing",
            Self::MissingDir => "missing_dir",
            Self::MissingVolume => "missing_volume",
            Self::Conflict { .. } => "conflict",
            Self::Denied => "denied",
            Self::Invalid => "invalid",
            Self::CrossDevice => "cross_device",
            Self::NotInTrash => "not_in_trash",
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct EmptyReport {
    pub removed: u64,
    pub failed: Vec<Failed>,
}

#[derive(Clone, Debug)]
pub struct Failed {
    pub id: String,
    pub error: String,
}

fn list_payload(env: &TrashEnv) -> Value {
    let items = list_items(env);
    let count = items.len();
    json!({
        "success": true,
        "items": items.iter().map(Item::to_json).collect::<Vec<_>>(),
        "count": count,
        "full": count > 0,
    })
}

fn restore_payload(env: &TrashEnv, data: &Value) -> Value {
    let id = data.get("id").and_then(Value::as_str).unwrap_or("");
    let as_name = data.get("as").and_then(Value::as_str).unwrap_or("");
    match restore(env, id, as_name) {
        Ok(item) => json!({"success": true, "item": item.to_json()}),
        Err(RestoreError::Conflict { suggested }) => json!({
            "success": false,
            "error": "conflict",
            "suggested": suggested,
        }),
        Err(error) => json!({"success": false, "error": error.as_str()}),
    }
}

fn empty_payload(env: &TrashEnv) -> Value {
    let report = empty(env);
    json!({
        "success": report.failed.is_empty(),
        "removed": report.removed,
        "failed": report.failed.iter().map(|entry| json!({
            "id": entry.id,
            "error": entry.error,
        })).collect::<Vec<_>>(),
    })
}

fn roots(env: &TrashEnv) -> Vec<Root> {
    let mut out = Vec::new();
    push_root(
        &mut out,
        Root {
            trash: env.home.clone(),
            topdir: None,
        },
    );
    for topdir in extra_topdirs(env) {
        push_volume(&mut out, &topdir, env.uid);
    }
    out
}

fn extra_topdirs(env: &TrashEnv) -> Vec<PathBuf> {
    let mut dirs = env.extra_volumes.clone();
    if env.scan_mounts {
        dirs.extend(mount_topdirs());
    }
    dirs
}

fn push_volume(out: &mut Vec<Root>, topdir: &Path, uid: u32) {
    let shared = topdir.join(".Trash");
    if usable_shared_trash(&shared) {
        push_root(
            out,
            Root {
                trash: shared.join(uid.to_string()),
                topdir: Some(topdir.to_path_buf()),
            },
        );
        return;
    }
    push_root(
        out,
        Root {
            trash: topdir.join(format!(".Trash-{uid}")),
            topdir: Some(topdir.to_path_buf()),
        },
    );
}

fn push_root(out: &mut Vec<Root>, root: Root) {
    if out.iter().any(|have| have.trash == root.trash) {
        return;
    }
    out.push(root);
}

fn usable_shared_trash(path: &Path) -> bool {
    let meta = match fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(_) => return false,
    };
    meta.file_type().is_dir() && !meta.file_type().is_symlink() && meta.mode() & 0o1000 != 0
}

fn mount_topdirs() -> Vec<PathBuf> {
    let text = match fs::read_to_string("/proc/mounts") {
        Ok(text) => text,
        Err(_) => return Vec::new(),
    };
    parse_mounts(&text)
}

pub fn parse_mounts(text: &str) -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    for line in text.lines() {
        let mut parts = line.split_whitespace();
        let _device = parts.next();
        let mount = match parts.next() {
            Some(value) => unescape_mount(value),
            None => continue,
        };
        let fstype = parts.next().unwrap_or("");
        if SKIP_FS.iter().any(|name| *name == fstype) {
            continue;
        }
        if !mount.starts_with('/') || mount == "/" || mount == "/boot" || mount.starts_with("/boot/")
        {
            continue;
        }
        if mount.starts_with("/proc")
            || mount.starts_with("/sys")
            || mount.starts_with("/dev")
            || mount.starts_with("/run")
        {
            continue;
        }
        dirs.push(PathBuf::from(mount));
    }
    dirs
}

fn unescape_mount(value: &str) -> String {
    value
        .replace("\\040", " ")
        .replace("\\011", "\t")
        .replace("\\012", "\n")
        .replace("\\134", "\\")
}

fn list_root(root: &Root) -> Vec<Item> {
    let files = root.trash.join("files");
    let info = root.trash.join("info");
    let entries = match fs::read_dir(&files) {
        Ok(entries) => entries,
        Err(_) => return Vec::new(),
    };
    let mut items = Vec::new();
    for entry in entries.flatten() {
        let trash_name = entry.file_name();
        let trash_name = match trash_name.to_str() {
            Some(name) if valid_trash_name(name) => name.to_string(),
            _ => continue,
        };
        let path = files.join(&trash_name);
        if !contained(&path, &files) {
            continue;
        }
        let info_path = info.join(format!("{trash_name}.trashinfo"));
        if !contained(&info_path, &info) {
            continue;
        }
        let meta = match fs::symlink_metadata(&path) {
            Ok(meta) => meta,
            Err(_) => continue,
        };
        let parsed = fs::read_to_string(&info_path)
            .ok()
            .and_then(|text| parse_trashinfo(&text));
        let original = parsed
            .as_ref()
            .map(|info| resolve_original(root, &info.path))
            .unwrap_or_default();
        let original_dir = original
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("/"));
        items.push(Item {
            id: path_string(&path),
            name: original_name(&original).unwrap_or_else(|| trash_name.clone()),
            trash_name,
            path,
            info_path,
            original_path: original,
            original_dir,
            deleted_at: parsed.map(|info| info.deleted_at).unwrap_or_default(),
            is_dir: meta.file_type().is_dir(),
            size: if meta.file_type().is_dir() { 0 } else { meta.len() },
            volume: root
                .topdir
                .as_ref()
                .map(|path| path_string(path))
                .unwrap_or_else(|| "home".into()),
        });
    }
    items
}

fn item_by_id(env: &TrashEnv, id: &str) -> Option<Item> {
    if !valid_path(id) {
        return None;
    }
    list_items(env).into_iter().find(|item| item.id == id)
}

fn delete_item(item: &Item) -> Result<(), String> {
    let files = item
        .path
        .parent()
        .ok_or_else(|| "not_in_trash".to_string())?;
    let info_dir = item
        .info_path
        .parent()
        .ok_or_else(|| "not_in_trash".to_string())?;
    if files.file_name().and_then(|name| name.to_str()) != Some("files")
        || info_dir.file_name().and_then(|name| name.to_str()) != Some("info")
        || !contained(&item.path, files)
        || !contained(&item.info_path, info_dir)
    {
        return Err("not_in_trash".into());
    }
    make_writable(&item.path);
    if let Err(error) = remove_entry(&item.path) {
        return Err(io_code(&error).into());
    }
    let _ = fs::remove_file(&item.info_path);
    Ok(())
}

fn sweep_orphans(root: &Root, report: &mut EmptyReport) {
    let files = root.trash.join("files");
    let info = root.trash.join("info");
    if let Ok(entries) = fs::read_dir(&files) {
        for entry in entries.flatten() {
            let path = entry.path();
            if !contained(&path, &files) {
                continue;
            }
            make_writable(&path);
            match remove_entry(&path) {
                Ok(()) => report.removed += 1,
                Err(error) => report.failed.push(Failed {
                    id: path_string(&path),
                    error: io_code(&error).into(),
                }),
            }
        }
    }
    if let Ok(entries) = fs::read_dir(&info) {
        for entry in entries.flatten() {
            let path = entry.path();
            if contained(&path, &info) {
                let _ = fs::remove_file(&path);
            }
        }
    }
}

fn remove_entry(path: &Path) -> io::Result<()> {
    let meta = fs::symlink_metadata(path)?;
    if meta.file_type().is_dir() && !meta.file_type().is_symlink() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}

fn make_writable(path: &Path) {
    let meta = match fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(_) => return,
    };
    if meta.file_type().is_symlink() {
        return;
    }
    let mut perms = meta.permissions();
    perms.set_mode(perms.mode() | 0o200);
    let _ = fs::set_permissions(path, perms);
    if meta.file_type().is_dir() {
        if let Ok(entries) = fs::read_dir(path) {
            for entry in entries.flatten() {
                make_writable(&entry.path());
            }
        }
    }
}

struct TrashInfo {
    path: String,
    deleted_at: String,
}

fn parse_trashinfo(text: &str) -> Option<TrashInfo> {
    let mut section = false;
    let mut path = None;
    let mut deleted_at = String::new();
    for raw in text.lines() {
        let line = raw.trim().trim_end_matches('\r');
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.eq_ignore_ascii_case("[Trash Info]") {
            section = true;
            continue;
        }
        if line.starts_with('[') {
            section = false;
            continue;
        }
        if !section {
            continue;
        }
        if let Some(value) = line.strip_prefix("Path=") {
            path = Some(decode_path(value.trim())?);
        } else if let Some(value) = line.strip_prefix("DeletionDate=") {
            deleted_at = value.trim().to_string();
        }
    }
    Some(TrashInfo {
        path: path?,
        deleted_at,
    })
}

pub fn encode_path(path: &str) -> String {
    let mut out = String::new();
    for byte in path.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                out.push(*byte as char);
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

pub fn decode_path(value: &str) -> Option<String> {
    let mut bytes = Vec::new();
    let raw = value.as_bytes();
    let mut i = 0;
    while i < raw.len() {
        if raw[i] == b'%' {
            if i + 2 >= raw.len() {
                return None;
            }
            bytes.push(u8::from_str_radix(std::str::from_utf8(&raw[i + 1..i + 3]).ok()?, 16).ok()?);
            i += 3;
        } else {
            bytes.push(raw[i]);
            i += 1;
        }
    }
    String::from_utf8(bytes).ok()
}

fn resolve_original(root: &Root, stored: &str) -> PathBuf {
    let path = PathBuf::from(stored);
    if path.is_absolute() {
        return path;
    }
    match &root.topdir {
        Some(topdir) => topdir.join(path),
        None => PathBuf::new(),
    }
}

fn original_name(path: &Path) -> Option<String> {
    path.file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .map(str::to_string)
}

pub fn unique_name(dir: &Path, name: &str) -> String {
    if !exists_here(dir, name) {
        return name.to_string();
    }
    let (stem, ext) = split_name(name);
    for index in 2..1000 {
        let candidate = format!("{stem} {index}{ext}");
        if !exists_here(dir, &candidate) {
            return candidate;
        }
    }
    format!("{stem} copy{ext}")
}

fn exists_here(dir: &Path, name: &str) -> bool {
    let path = dir.join(name);
    path.exists() || path.symlink_metadata().is_ok()
}

fn split_name(name: &str) -> (String, String) {
    if let Some(index) = name.rfind('.') {
        if index > 0 {
            return (name[..index].to_string(), name[index..].to_string());
        }
    }
    (name.to_string(), String::new())
}

fn safe_file_name(name: &str) -> Option<String> {
    let trimmed = name.trim();
    if trimmed.is_empty()
        || trimmed.contains('/')
        || trimmed.contains('\0')
        || trimmed == "."
        || trimmed == ".."
    {
        return None;
    }
    Some(trimmed.to_string())
}

fn valid_trash_name(name: &str) -> bool {
    !name.is_empty() && !name.contains('/') && name != "." && name != ".."
}

pub fn valid_path(path: &str) -> bool {
    !path.is_empty()
        && path.len() < 4096
        && path.starts_with('/')
        && !path.contains('\0')
        && !path.contains('\n')
        && !path.contains('\r')
}

fn contained(path: &Path, parent: &Path) -> bool {
    let parent = normalize(parent);
    let child = normalize(path);
    child.starts_with(&parent) && child != parent
}

fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Prefix(_) | Component::RootDir => out = PathBuf::from("/"),
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            Component::Normal(part) => out.push(part),
        }
    }
    out
}

fn path_string(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn io_restore(error: io::Error) -> RestoreError {
    match error.kind() {
        io::ErrorKind::PermissionDenied => RestoreError::Denied,
        io::ErrorKind::NotFound => RestoreError::Missing,
        _ => RestoreError::Denied,
    }
}

fn io_code(error: &io::Error) -> &'static str {
    match error.kind() {
        io::ErrorKind::PermissionDenied => "denied",
        io::ErrorKind::NotFound => "missing",
        _ => "denied",
    }
}

pub fn write_trashinfo(path: &Path, original: &str, deleted_at: &str) -> io::Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    write!(
        file,
        "[Trash Info]\nPath={}\nDeletionDate={}\n",
        encode_path(original),
        deleted_at
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static SEQ: AtomicU64 = AtomicU64::new(0);

    struct Temp(PathBuf);
    impl Temp {
        fn new(name: &str) -> Self {
            let n = SEQ.fetch_add(1, Ordering::Relaxed);
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = std::env::temp_dir().join(format!(
                "macshell-trash-{}-{}-{}-{name}",
                std::process::id(),
                now,
                n
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn path(&self) -> &Path {
            &self.0
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn env_at(home: &Path) -> TrashEnv {
        TrashEnv {
            home: home.to_path_buf(),
            extra_volumes: Vec::new(),
            scan_mounts: false,
            uid: 1000,
        }
    }

    fn put(home: &Path, trash_name: &str, original: &str, body: &[u8], date: &str) -> PathBuf {
        let files = home.join("files");
        let info = home.join("info");
        fs::create_dir_all(&files).unwrap();
        fs::create_dir_all(&info).unwrap();
        let path = files.join(trash_name);
        fs::write(&path, body).unwrap();
        write_trashinfo(&info.join(format!("{trash_name}.trashinfo")), original, date).unwrap();
        path
    }

    #[test]
    fn lists_unicode_and_duplicate_original_names() {
        let tmp = Temp::new("list");
        let dest = tmp.path().join("docs");
        fs::create_dir_all(&dest).unwrap();
        let home = tmp.path().join("Trash");
        put(
            &home,
            "notes.txt",
            &path_string(&dest.join("notes.txt")),
            b"one",
            "2024-01-02T03:04:05",
        );
        put(
            &home,
            "notes.txt.2",
            &path_string(&dest.join("notes.txt")),
            "две".as_bytes(),
            "2024-02-03T04:05:06",
        );
        put(
            &home,
            "фото.png",
            &path_string(&dest.join("фото.png")),
            b"img",
            "2024-03-04T05:06:07",
        );
        let items = list_items(&env_at(&home));
        assert_eq!(items.len(), 3);
        assert_eq!(items[0].name, "фото.png");
        assert_eq!(items[1].name, "notes.txt");
        assert_eq!(items[2].name, "notes.txt");
        assert_ne!(items[1].id, items[2].id);
        assert_eq!(items[1].deleted_at, "2024-02-03T04:05:06");
    }

    #[test]
    fn restore_moves_file_and_removes_info() {
        let tmp = Temp::new("restore");
        let dest_dir = tmp.path().join("keep");
        fs::create_dir_all(&dest_dir).unwrap();
        let original = dest_dir.join("letter.txt");
        let home = tmp.path().join("Trash");
        let id = path_string(&put(
            &home,
            "letter.txt",
            &path_string(&original),
            b"hello",
            "2024-05-06T07:08:09",
        ));
        restore(&env_at(&home), &id, "").unwrap();
        assert_eq!(fs::read(&original).unwrap(), b"hello");
        assert!(list_items(&env_at(&home)).is_empty());
        assert!(!home.join("info/letter.txt.trashinfo").exists());
    }

    #[test]
    fn restore_conflict_keeps_trash_and_suggests_name() {
        let tmp = Temp::new("conflict");
        let dest_dir = tmp.path().join("keep");
        fs::create_dir_all(&dest_dir).unwrap();
        fs::write(dest_dir.join("file.txt"), b"live").unwrap();
        let home = tmp.path().join("Trash");
        let id = path_string(&put(
            &home,
            "file.txt",
            &path_string(&dest_dir.join("file.txt")),
            b"old",
            "2024-01-01T00:00:00",
        ));
        match restore(&env_at(&home), &id, "") {
            Err(RestoreError::Conflict { suggested }) => assert_eq!(suggested, "file 2.txt"),
            other => panic!("{other:?}"),
        }
        assert_eq!(fs::read(home.join("files/file.txt")).unwrap(), b"old");
        restore(&env_at(&home), &id, "file 2.txt").unwrap();
        assert_eq!(fs::read(dest_dir.join("file 2.txt")).unwrap(), b"old");
        assert_eq!(fs::read(dest_dir.join("file.txt")).unwrap(), b"live");
    }

    #[test]
    fn missing_original_dir_keeps_the_file() {
        let tmp = Temp::new("missing-dir");
        let original = tmp.path().join("gone/nested/doc.txt");
        let home = tmp.path().join("Trash");
        let id = path_string(&put(
            &home,
            "doc.txt",
            &path_string(&original),
            b"keep",
            "2024-01-01T00:00:00",
        ));
        assert_eq!(
            restore(&env_at(&home), &id, "").unwrap_err(),
            RestoreError::MissingVolume
        );
        assert_eq!(fs::read(home.join("files/doc.txt")).unwrap(), b"keep");
    }

    #[test]
    fn empty_removes_files_info_and_directory() {
        let tmp = Temp::new("empty");
        let dest = tmp.path().join("docs");
        fs::create_dir_all(dest.join("folder")).unwrap();
        let home = tmp.path().join("Trash");
        put(
            &home,
            "a.txt",
            &path_string(&dest.join("a.txt")),
            b"a",
            "2024-01-01T00:00:00",
        );
        let files = home.join("files/folder");
        fs::create_dir_all(&files).unwrap();
        fs::write(files.join("inner.txt"), b"in").unwrap();
        write_trashinfo(
            &home.join("info/folder.trashinfo"),
            &path_string(&dest.join("folder")),
            "2024-01-01T00:00:01",
        )
        .unwrap();
        let report = empty(&env_at(&home));
        assert_eq!(report.removed, 2);
        assert!(report.failed.is_empty());
        assert!(fs::read_dir(home.join("files")).unwrap().next().is_none());
        assert!(fs::read_dir(home.join("info")).unwrap().next().is_none());
        assert!(dest.join("folder").exists());
    }

    #[test]
    fn empty_does_not_follow_symlink_out_of_trash() {
        let tmp = Temp::new("symlink");
        let outside = tmp.path().join("outside.txt");
        fs::write(&outside, b"safe").unwrap();
        let home = tmp.path().join("Trash");
        fs::create_dir_all(home.join("files")).unwrap();
        fs::create_dir_all(home.join("info")).unwrap();
        symlink(&outside, home.join("files/link")).unwrap();
        write_trashinfo(
            &home.join("info/link.trashinfo"),
            &path_string(&tmp.path().join("link")),
            "2024-01-01T00:00:00",
        )
        .unwrap();
        let report = empty(&env_at(&home));
        assert_eq!(report.removed, 1);
        assert_eq!(fs::read(&outside).unwrap(), b"safe");
        assert!(!home.join("files/link").exists());
    }

    #[test]
    fn volume_trash_uses_relative_original_path() {
        let tmp = Temp::new("volume");
        let volume = tmp.path().join("disk");
        fs::create_dir_all(volume.join("docs")).unwrap();
        let trash = volume.join(".Trash-1000");
        put(
            &trash,
            "shot.jpg",
            "docs/shot.jpg",
            b"pic",
            "2024-08-09T10:11:12",
        );
        let env = TrashEnv {
            home: tmp.path().join("unused-home"),
            extra_volumes: vec![volume.clone()],
            scan_mounts: false,
            uid: 1000,
        };
        let items = list_items(&env);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].original_path, volume.join("docs/shot.jpg"));
        assert_eq!(items[0].volume, path_string(&volume));
        restore(&env, &items[0].id, "").unwrap();
        assert_eq!(fs::read(volume.join("docs/shot.jpg")).unwrap(), b"pic");
    }

    #[test]
    fn unknown_id_does_not_delete_arbitrary_paths() {
        let tmp = Temp::new("arbitrary");
        let victim = tmp.path().join("victim.txt");
        fs::write(&victim, b"live").unwrap();
        let home = tmp.path().join("Trash");
        fs::create_dir_all(home.join("files")).unwrap();
        fs::create_dir_all(home.join("info")).unwrap();
        assert_eq!(
            restore(&env_at(&home), &path_string(&victim), "").unwrap_err(),
            RestoreError::Missing
        );
        assert_eq!(fs::read(&victim).unwrap(), b"live");
        let report = empty(&env_at(&home));
        assert_eq!(report.removed, 0);
        assert_eq!(fs::read(&victim).unwrap(), b"live");
    }

    #[test]
    fn encode_roundtrip_and_mount_parser() {
        let original = "/home/user/Мои файлы/a+b.txt";
        assert_eq!(decode_path(&encode_path(original)).unwrap(), original);
        let mounts = parse_mounts(
            "/dev/sda1 /data ext4 rw 0 0\n\
             tmpfs /tmp tmpfs rw 0 0\n\
             /dev/sdb1 /media/disk\\040A vfat rw 0 0\n",
        );
        assert!(mounts.contains(&PathBuf::from("/data")));
        assert!(mounts.contains(&PathBuf::from("/media/disk A")));
        assert!(!mounts.iter().any(|path| path == Path::new("/tmp")));
    }

    #[test]
    fn protocol_constant_matches_installer() {
        assert_eq!(PROTOCOL, "macshell-trash 1");
        let tmp = Temp::new("proto");
        let env = env_at(&tmp.path().join("Trash"));
        let payload = handle("list", &json!({}), &env);
        assert_eq!(payload["success"], true);
        assert_eq!(payload["count"], 0);
        assert_eq!(payload["full"], false);
        assert_eq!(handle("nope", &json!({}), &env)["error"], "Unknown action");
    }
}
