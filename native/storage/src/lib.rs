use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::env;
use std::fs::{self, Metadata};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

pub const PROTOCOL: &str = "macshell-storage 1";
pub const METHOD: &str = "apparent-size";
pub const VOLUME_METHOD: &str = "statvfs";
pub const DEFAULT_MAX_ENTRIES: u64 = 80_000;
pub const DEFAULT_MAX_LARGE: usize = 12;
pub const DEFAULT_MAX_APPS: usize = 16;

const SKIP_FS: &[&str] = &[
    "autofs", "binfmt_misc", "bpf", "cgroup", "cgroup2", "configfs", "debugfs", "devpts",
    "devtmpfs", "efivarfs", "fuse.gvfsd-fuse", "fuse.portal", "fusectl", "hugetlbfs", "mqueue",
    "nsfs", "overlay", "proc", "pstore", "ramfs", "rpc_pipefs", "securityfs", "squashfs",
    "sysfs", "tmpfs", "tracefs",
];

const SKIP_APP: &[&str] = &[
    "Trash", "applications", "icons", "fonts", "mime", "themes", "locale", "man", "dbus-1",
    "flatpak", "keyrings", "recently-used.xbel", "xorg", "wayland-sessions",
];

#[derive(Clone, Debug)]
pub struct StorageEnv {
    pub home: PathBuf,
    pub data_home: PathBuf,
    pub config_home: PathBuf,
    pub data_dirs: Vec<PathBuf>,
    pub mountinfo: String,
    pub max_entries: u64,
    pub max_large: usize,
    pub max_apps: usize,
}

impl StorageEnv {
    pub fn from_os() -> Self {
        let home = env::var_os("MACSHELL_STORAGE_HOME")
            .filter(|value| !value.is_empty())
            .or_else(|| env::var_os("HOME"))
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/"));
        let data_home = env::var_os("XDG_DATA_HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".local/share"));
        let config_home = env::var_os("XDG_CONFIG_HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".config"));
        let data_dirs = env::var("XDG_DATA_DIRS")
            .ok()
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| "/usr/local/share:/usr/share".into())
            .split(':')
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .collect();
        let mountinfo = env::var_os("MACSHELL_STORAGE_MOUNTINFO")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/proc/self/mountinfo"));
        Self {
            home,
            data_home,
            config_home,
            data_dirs,
            mountinfo: fs::read_to_string(mountinfo).unwrap_or_default(),
            max_entries: DEFAULT_MAX_ENTRIES,
            max_large: DEFAULT_MAX_LARGE,
            max_apps: DEFAULT_MAX_APPS,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Volume {
    pub id: String,
    pub name: String,
    pub path: String,
    pub fstype: String,
    pub device: String,
    pub total: u64,
    pub used: u64,
    pub available: u64,
    pub bind: bool,
    pub ready: bool,
}

impl Volume {
    fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "name": self.name,
            "path": self.path,
            "fstype": self.fstype,
            "device": self.device,
            "total": self.total,
            "used": self.used,
            "available": self.available,
            "bind": self.bind,
            "ready": self.ready,
        })
    }
}

#[derive(Clone, Debug, Default)]
pub struct ScanReport {
    pub cancelled: bool,
    pub incomplete: bool,
    pub reason: String,
    pub visited: u64,
    pub denied: u64,
    pub skipped_mounts: u64,
    pub folders: Vec<Entry>,
    pub large: Vec<Entry>,
    pub apps: Vec<Entry>,
    pub trash: Entry,
}

#[derive(Clone, Debug, Default)]
pub struct Entry {
    pub id: String,
    pub name: String,
    pub path: String,
    pub bytes: u64,
    pub incomplete: bool,
}

impl Entry {
    fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "name": self.name,
            "path": self.path,
            "bytes": self.bytes,
            "incomplete": self.incomplete,
        })
    }
}

struct WalkState<'a> {
    cancel: &'a AtomicBool,
    skip_mounts: &'a HashSet<PathBuf>,
    max_entries: u64,
    max_large: usize,
    seen: HashSet<(u64, u64)>,
    large: Vec<Entry>,
    visited: u64,
    denied: u64,
    skipped_mounts: u64,
    incomplete: bool,
    reason: String,
    progress: &'a dyn Fn(u64),
}

pub fn handle(action: &str, _data: &Value, env: &StorageEnv) -> Value {
    match action {
        "volumes" => volumes_payload(env),
        "scan" => scan_payload(env, &AtomicBool::new(false), &|_| {}),
        "cancel" => json!({"success": true, "action": "cancel", "cancelled": true}),
        _ => json!({"success": false, "error": "Unknown action"}),
    }
}

pub fn volumes_payload(env: &StorageEnv) -> Value {
    let volumes = volumes_from_mountinfo(&env.mountinfo, statvfs_path);
    json!({
        "success": true,
        "action": "volumes",
        "measuredAt": now_secs(),
        "method": VOLUME_METHOD,
        "volumes": volumes.iter().map(Volume::to_json).collect::<Vec<_>>(),
    })
}

pub fn scan_payload(env: &StorageEnv, cancel: &AtomicBool, progress: &dyn Fn(u64)) -> Value {
    let report = scan(env, cancel, progress);
    let volumes = volumes_from_mountinfo(&env.mountinfo, statvfs_path);
    json!({
        "success": true,
        "action": "scan",
        "cancelled": report.cancelled,
        "incomplete": report.incomplete,
        "reason": report.reason,
        "measuredAt": now_secs(),
        "method": METHOD,
        "visited": report.visited,
        "denied": report.denied,
        "skippedMounts": report.skipped_mounts,
        "volumes": volumes.iter().map(Volume::to_json).collect::<Vec<_>>(),
        "folders": report.folders.iter().map(Entry::to_json).collect::<Vec<_>>(),
        "large": report.large.iter().map(Entry::to_json).collect::<Vec<_>>(),
        "apps": report.apps.iter().map(Entry::to_json).collect::<Vec<_>>(),
        "trash": report.trash.to_json(),
    })
}

pub fn volumes_from_mountinfo(
    text: &str,
    stat: impl Fn(&Path) -> Option<(u64, u64, u64)>,
) -> Vec<Volume> {
    let parsed = parse_mountinfo(text);
    let mut counts: HashMap<String, usize> = HashMap::new();
    for mount in &parsed {
        *counts.entry(mount.dev.clone()).or_insert(0) += 1;
    }
    let mut primary: HashMap<String, String> = HashMap::new();
    for mount in &parsed {
        let best = primary.entry(mount.dev.clone()).or_insert_with(|| mount.path.clone());
        if mount.path == "/" || mount.path.len() < best.len() {
            *best = mount.path.clone();
        }
    }
    let mut volumes = Vec::new();
    for mount in parsed {
        let bind = counts.get(&mount.dev).copied().unwrap_or(0) > 1
            && primary.get(&mount.dev).map(String::as_str) != Some(mount.path.as_str());
        let stats = stat(Path::new(&mount.path));
        let (total, used, available, ready) = match stats {
            Some((total, used, available)) => (total, used, available, true),
            None => (0, 0, 0, false),
        };
        volumes.push(Volume {
            id: mount.path.clone(),
            name: volume_name(&mount.path),
            path: mount.path,
            fstype: mount.fstype,
            device: mount.source,
            total,
            used,
            available,
            bind,
            ready,
        });
    }
    volumes.sort_by(|a, b| {
        bind_rank(a.bind).cmp(&bind_rank(b.bind)).then_with(|| {
            (a.path != "/").cmp(&(b.path != "/")).then_with(|| a.path.cmp(&b.path))
        })
    });
    volumes
}

fn bind_rank(bind: bool) -> u8 {
    u8::from(bind)
}

struct Mount {
    path: String,
    fstype: String,
    source: String,
    dev: String,
}

fn parse_mountinfo(text: &str) -> Vec<Mount> {
    let mut mounts = Vec::new();
    for line in text.lines() {
        let Some(mount) = parse_mountinfo_line(line) else {
            continue;
        };
        if SKIP_FS.iter().any(|name| *name == mount.fstype) {
            continue;
        }
        if !keep_mount(&mount.path) {
            continue;
        }
        if mounts.iter().any(|have: &Mount| have.path == mount.path) {
            continue;
        }
        mounts.push(mount);
    }
    mounts
}

fn parse_mountinfo_line(line: &str) -> Option<Mount> {
    let (left, right) = line.split_once(" - ")?;
    let mut left_parts = left.split_whitespace();
    let _id = left_parts.next()?;
    let _parent = left_parts.next()?;
    let dev = left_parts.next()?.to_string();
    let _root = left_parts.next()?;
    let path = unescape_mount(left_parts.next()?);
    let mut right_parts = right.split_whitespace();
    let fstype = right_parts.next()?.to_string();
    let source = unescape_mount(right_parts.next().unwrap_or(""));
    Some(Mount {
        path,
        fstype,
        source,
        dev,
    })
}

fn keep_mount(path: &str) -> bool {
    if !path.starts_with('/') {
        return false;
    }
    if path == "/boot" || path.starts_with("/boot/") {
        return true;
    }
    if path.starts_with("/proc")
        || path.starts_with("/sys")
        || path.starts_with("/dev")
        || path == "/run"
        || path.starts_with("/run/") && !path.starts_with("/run/media/")
    {
        return false;
    }
    true
}

fn unescape_mount(value: &str) -> String {
    value
        .replace("\\040", " ")
        .replace("\\011", "\t")
        .replace("\\012", "\n")
        .replace("\\134", "\\")
}

fn volume_name(path: &str) -> String {
    match path {
        "/" => "System".into(),
        "/home" => "Home".into(),
        "/boot/efi" | "/efi" | "/boot" => "EFI".into(),
        _ => Path::new(path)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or(path)
            .to_string(),
    }
}

fn statvfs_path(path: &Path) -> Option<(u64, u64, u64)> {
    let cstr = c_path(path)?;
    unsafe {
        let mut stats: libc::statvfs = std::mem::zeroed();
        if libc::statvfs(cstr.as_ptr(), &mut stats) != 0 {
            return None;
        }
        let frsize = stats.f_frsize as u64;
        let total = frsize.saturating_mul(stats.f_blocks as u64);
        let free = frsize.saturating_mul(stats.f_bfree as u64);
        let available = frsize.saturating_mul(stats.f_bavail as u64);
        Some((total, total.saturating_sub(free), available))
    }
}

fn c_path(path: &Path) -> Option<std::ffi::CString> {
    std::ffi::CString::new(path.as_os_str().as_bytes()).ok()
}

pub fn scan(env: &StorageEnv, cancel: &AtomicBool, progress: &dyn Fn(u64)) -> ScanReport {
    let skip_mounts = parse_mountinfo(&env.mountinfo)
        .into_iter()
        .map(|mount| PathBuf::from(mount.path))
        .collect::<HashSet<_>>();
    let mut state = WalkState {
        cancel,
        skip_mounts: &skip_mounts,
        max_entries: env.max_entries,
        max_large: env.max_large,
        seen: HashSet::new(),
        large: Vec::new(),
        visited: 0,
        denied: 0,
        skipped_mounts: 0,
        incomplete: false,
        reason: String::new(),
        progress,
    };
    let mut folders = Vec::new();
    let trash = measure_trash(env, cancel, progress);
    if trash.incomplete {
        state.incomplete = true;
        if state.reason.is_empty() {
            state.reason = "limit".into();
        }
    }
    let mut cache = None;
    for (id, name, path) in user_folders(env) {
        if id == "cache" {
            cache = Some((id, name, path));
            continue;
        }
        if let Some(folder) = measure_folder(id, name, &path, &mut state) {
            folders.push(folder);
        }
        if state.cancel.load(Ordering::Relaxed) {
            break;
        }
    }
    let mut apps = Vec::new();
    if !state.cancel.load(Ordering::Relaxed) {
        apps = app_entries(env, &mut state);
    }
    if let Some((id, name, path)) = cache {
        if !state.cancel.load(Ordering::Relaxed) && state.visited < state.max_entries {
            if let Some(folder) = measure_folder(id, name, &path, &mut state) {
                folders.push(folder);
            }
        }
    }
    folders.sort_by(|a, b| b.bytes.cmp(&a.bytes).then_with(|| a.name.cmp(&b.name)));
    let cancelled = state.cancel.load(Ordering::Relaxed);
    if cancelled {
        state.incomplete = true;
        state.reason = "cancelled".into();
    } else if state.incomplete && state.reason.is_empty() {
        state.reason = if state.denied > 0 { "denied" } else { "limit" }.into();
    }
    ScanReport {
        cancelled,
        incomplete: state.incomplete,
        reason: state.reason,
        visited: state.visited,
        denied: state.denied,
        skipped_mounts: state.skipped_mounts,
        folders,
        large: state.large,
        apps,
        trash,
    }
}

fn measure_trash(env: &StorageEnv, cancel: &AtomicBool, progress: &dyn Fn(u64)) -> Entry {
    let skip_mounts = HashSet::new();
    let mut state = WalkState {
        cancel,
        skip_mounts: &skip_mounts,
        max_entries: env.max_entries,
        max_large: env.max_large,
        seen: HashSet::new(),
        large: Vec::new(),
        visited: 0,
        denied: 0,
        skipped_mounts: 0,
        incomplete: false,
        reason: String::new(),
        progress,
    };
    let roots = trash_roots(env);
    let path = roots
        .first()
        .cloned()
        .unwrap_or_else(|| env.data_home.join("Trash"));
    let mut trash = Entry {
        id: "trash".into(),
        name: "Trash".into(),
        path: path_string(&path),
        bytes: 0,
        incomplete: false,
    };
    for root in roots {
        if !root.is_dir() || cancel.load(Ordering::Relaxed) {
            continue;
        }
        let before = state.incomplete;
        trash.bytes = trash.bytes.saturating_add(walk(&root, &mut state));
        if state.incomplete && !before {
            trash.incomplete = true;
        }
    }
    trash
}

fn trash_roots(env: &StorageEnv) -> Vec<PathBuf> {
    let uid = unsafe { libc::getuid() };
    let mut roots = Vec::new();
    let home_trash = env.data_home.join("Trash");
    roots.push(home_trash.clone());
    let dot = env.home.join(".Trash");
    if dot.is_dir() && dot != home_trash {
        roots.push(dot);
    }
    for mount in parse_mountinfo(&env.mountinfo) {
        let top = PathBuf::from(&mount.path);
        if top == Path::new("/") {
            continue;
        }
        let shared = top.join(".Trash").join(uid.to_string());
        let numbered = top.join(format!(".Trash-{uid}"));
        for candidate in [shared, numbered] {
            if candidate.is_dir() && !roots.iter().any(|have| *have == candidate) {
                roots.push(candidate);
            }
        }
    }
    roots
}

fn measure_folder(id: String, name: String, path: &Path, state: &mut WalkState) -> Option<Entry> {
    if !path.is_dir() {
        return None;
    }
    let mut folder = Entry {
        id,
        name,
        path: path_string(path),
        bytes: 0,
        incomplete: false,
    };
    let before = state.incomplete;
    folder.bytes = walk(path, state);
    folder.incomplete = state.incomplete && !before;
    Some(folder)
}

fn user_folders(env: &StorageEnv) -> Vec<(String, String, PathBuf)> {
    let map = read_user_dirs(&env.home, &env.config_home);
    let mut folders = Vec::new();
    for (id, key, fallback) in [
        ("desktop", "XDG_DESKTOP_DIR", "Desktop"),
        ("documents", "XDG_DOCUMENTS_DIR", "Documents"),
        ("downloads", "XDG_DOWNLOAD_DIR", "Downloads"),
        ("music", "XDG_MUSIC_DIR", "Music"),
        ("pictures", "XDG_PICTURES_DIR", "Pictures"),
        ("videos", "XDG_VIDEOS_DIR", "Videos"),
        ("public", "XDG_PUBLICSHARE_DIR", "Public"),
        ("templates", "XDG_TEMPLATES_DIR", "Templates"),
    ] {
        let path = map
            .get(key)
            .cloned()
            .unwrap_or_else(|| env.home.join(fallback));
        folders.push((id.into(), fallback.into(), path));
    }
    folders.push(("cache".into(), "Cache".into(), env.home.join(".cache")));
    folders
}

fn read_user_dirs(home: &Path, config_home: &Path) -> HashMap<String, PathBuf> {
    let path = config_home.join("user-dirs.dirs");
    let Ok(text) = fs::read_to_string(path) else {
        return HashMap::new();
    };
    let mut map = HashMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let mut value = value.trim().trim_matches('"').to_string();
        if let Some(rest) = value.strip_prefix("$HOME/") {
            value = home.join(rest).to_string_lossy().into_owned();
        } else if value == "$HOME" {
            value = home.to_string_lossy().into_owned();
        }
        if value.starts_with('/') {
            map.insert(key.to_string(), PathBuf::from(value));
        }
    }
    map
}

fn desktop_ids(env: &StorageEnv) -> HashSet<String> {
    let mut ids = HashSet::new();
    let mut dirs = vec![env.data_home.join("applications")];
    for dir in &env.data_dirs {
        dirs.push(dir.join("applications"));
    }
    for dir in dirs {
        let Ok(entries) = fs::read_dir(dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            if let Some(id) = name.strip_suffix(".desktop") {
                if !id.is_empty() && id.len() <= 200 {
                    ids.insert(id.to_string());
                }
            }
            if ids.len() > 4000 {
                return ids;
            }
        }
    }
    ids
}

fn app_entries(env: &StorageEnv, state: &mut WalkState) -> Vec<Entry> {
    let ids = desktop_ids(env);
    let mut by_id: HashMap<String, Entry> = HashMap::new();
    for root in [env.data_home.clone(), env.config_home.clone()] {
        let Ok(entries) = fs::read_dir(&root) else {
            continue;
        };
        for entry in entries.flatten() {
            if state.cancel.load(Ordering::Relaxed) {
                break;
            }
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            if SKIP_APP.iter().any(|skip| *skip == name) || !ids.contains(name) {
                continue;
            }
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let bytes = walk(&path, state);
            let row = by_id.entry(name.to_string()).or_insert_with(|| Entry {
                id: name.to_string(),
                name: name.to_string(),
                path: path_string(&path),
                bytes: 0,
                incomplete: false,
            });
            row.bytes = row.bytes.saturating_add(bytes);
        }
    }
    let mut apps: Vec<_> = by_id.into_values().collect();
    apps.sort_by(|a, b| b.bytes.cmp(&a.bytes).then_with(|| a.name.cmp(&b.name)));
    apps.truncate(env.max_apps);
    apps
}

fn walk(path: &Path, state: &mut WalkState) -> u64 {
    if state.cancel.load(Ordering::Relaxed) {
        return 0;
    }
    if state.visited >= state.max_entries {
        state.incomplete = true;
        if state.reason.is_empty() {
            state.reason = "limit".into();
        }
        return 0;
    }
    let meta = match fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(error) => {
            if error.kind() == std::io::ErrorKind::PermissionDenied {
                state.denied += 1;
                state.incomplete = true;
            }
            return 0;
        }
    };
    if meta.file_type().is_symlink() {
        return 0;
    }
    if meta.file_type().is_dir() {
        return walk_dir(path, meta.dev(), state);
    }
    add_file(path, &meta, state)
}

fn walk_dir(path: &Path, tree_dev: u64, state: &mut WalkState) -> u64 {
    let entries = match fs::read_dir(path) {
        Ok(entries) => entries,
        Err(error) => {
            if error.kind() == std::io::ErrorKind::PermissionDenied {
                state.denied += 1;
                state.incomplete = true;
            }
            return 0;
        }
    };
    let mut total = 0u64;
    for entry in entries.flatten() {
        if state.cancel.load(Ordering::Relaxed) {
            return total;
        }
        let child = entry.path();
        let meta = match fs::symlink_metadata(&child) {
            Ok(meta) => meta,
            Err(error) => {
                if error.kind() == std::io::ErrorKind::PermissionDenied {
                    state.denied += 1;
                    state.incomplete = true;
                }
                continue;
            }
        };
        if meta.file_type().is_symlink() {
            continue;
        }
        if meta.dev() != tree_dev || state.skip_mounts.contains(&child) {
            state.skipped_mounts += 1;
            continue;
        }
        if meta.file_type().is_dir() {
            total = total.saturating_add(walk_dir(&child, tree_dev, state));
        } else {
            total = total.saturating_add(add_file(&child, &meta, state));
        }
    }
    total
}

fn add_file(path: &Path, meta: &Metadata, state: &mut WalkState) -> u64 {
    if state.visited >= state.max_entries {
        state.incomplete = true;
        if state.reason.is_empty() {
            state.reason = "limit".into();
        }
        return 0;
    }
    state.visited += 1;
    if state.visited % 256 == 0 {
        (state.progress)(state.visited);
    }
    if !state.seen.insert((meta.dev(), meta.ino())) {
        return 0;
    }
    let bytes = meta.len();
    if bytes > 0 {
        consider_large(path, bytes, state);
    }
    bytes
}

fn consider_large(path: &Path, bytes: u64, state: &mut WalkState) {
    let entry = Entry {
        id: path_string(path),
        name: path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("file")
            .to_string(),
        path: path_string(path),
        bytes,
        incomplete: false,
    };
    if state.large.len() < state.max_large {
        state.large.push(entry);
        state.large.sort_by(|a, b| b.bytes.cmp(&a.bytes));
        return;
    }
    if state.large.last().map(|row| row.bytes).unwrap_or(0) >= bytes {
        return;
    }
    state.large.pop();
    state.large.push(entry);
    state.large.sort_by(|a, b| b.bytes.cmp(&a.bytes));
}

fn path_string(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::AtomicU64;

    static SEQ: AtomicU64 = AtomicU64::new(0);

    struct Temp(PathBuf);
    impl Temp {
        fn new(name: &str) -> Self {
            let n = SEQ.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "macshell-storage-{}-{}-{name}",
                std::process::id(),
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

    fn env_at(home: &Path) -> StorageEnv {
        StorageEnv {
            home: home.to_path_buf(),
            data_home: home.join(".local/share"),
            config_home: home.join(".config"),
            data_dirs: vec![home.join(".local/share")],
            mountinfo: String::new(),
            max_entries: 80_000,
            max_large: 4,
            max_apps: 8,
        }
    }

    #[test]
    fn protocol_constant_matches_installer() {
        assert_eq!(PROTOCOL, "macshell-storage 1");
        let payload = handle("nope", &json!({}), &env_at(Path::new("/")));
        assert_eq!(payload["success"], false);
    }

    #[test]
    fn volumes_mark_bind_and_skip_virtual() {
        let mounts = "\
22 1 8:2 / / rw shared:1 - ext4 /dev/sda2 rw\n\
36 22 8:2 /data /mnt/data rw shared:1 - ext4 /dev/sda2 rw\n\
40 22 0:21 / /proc rw - proc proc rw\n\
41 22 8:3 / /home rw shared:2 - ext4 /dev/sda3 rw\n";
        let stats = |path: &Path| match path.to_str() {
            Some("/") => Some((1000, 400, 500)),
            Some("/home") => Some((2000, 200, 1500)),
            Some("/mnt/data") => Some((1000, 400, 500)),
            _ => None,
        };
        let volumes = volumes_from_mountinfo(mounts, stats);
        assert_eq!(volumes.len(), 3);
        assert_eq!(volumes[0].path, "/");
        assert_eq!(volumes[0].bind, false);
        assert_eq!(volumes[0].used, 400);
        let home = volumes.iter().find(|row| row.path == "/home").unwrap();
        assert_eq!(home.bind, false);
        let bind = volumes.iter().find(|row| row.path == "/mnt/data").unwrap();
        assert_eq!(bind.bind, true);
        assert!(volumes.iter().all(|row| row.fstype != "proc"));
    }

    #[test]
    fn same_device_subvolumes_are_bind_not_extra_disks() {
        let mounts = "\
22 1 0:37 /@ / rw - btrfs /dev/nvme0n1p2 rw\n\
30 22 0:37 /@home /home rw - btrfs /dev/nvme0n1p2 rw\n\
31 22 0:37 /@log /var/log rw - btrfs /dev/nvme0n1p2 rw\n\
40 22 0:38 / /boot/efi rw - vfat /dev/nvme0n1p1 rw\n";
        let stats = |path: &Path| match path.to_str() {
            Some("/") | Some("/home") | Some("/var/log") => Some((1000, 400, 500)),
            Some("/boot/efi") => Some((50, 1, 49)),
            _ => None,
        };
        let volumes = volumes_from_mountinfo(mounts, stats);
        let primary: Vec<_> = volumes.iter().filter(|row| !row.bind).map(|row| row.path.as_str()).collect();
        assert_eq!(primary, vec!["/", "/boot/efi"]);
        assert_eq!(volumes.iter().find(|row| row.path == "/").unwrap().name, "System");
        assert_eq!(volumes.iter().find(|row| row.path == "/home").unwrap().bind, true);
        assert_eq!(volumes.iter().find(|row| row.path == "/boot/efi").unwrap().name, "EFI");
    }

    #[test]
    fn unavailable_mount_stays_listed() {
        let mounts = "22 1 8:2 / / rw - ext4 /dev/sda2 rw\n23 22 8:20 / /media/usb rw - vfat /dev/sdb1 rw\n";
        let stats = |path: &Path| {
            if path == Path::new("/") {
                Some((10, 4, 6))
            } else {
                None
            }
        };
        let volumes = volumes_from_mountinfo(mounts, stats);
        let usb = volumes.iter().find(|row| row.path == "/media/usb").unwrap();
        assert_eq!(usb.ready, false);
        assert_eq!(usb.total, 0);
    }

    #[test]
    fn hardlinks_count_once_and_symlinks_are_not_followed() {
        let dir = Temp::new("links");
        let home = dir.path();
        let docs = home.join("Documents");
        fs::create_dir_all(&docs).unwrap();
        let file = docs.join("note.txt");
        fs::write(&file, vec![b'a'; 100]).unwrap();
        fs::hard_link(&file, docs.join("copy.txt")).unwrap();
        fs::create_dir_all(home.join("outside")).unwrap();
        fs::write(home.join("outside/big.bin"), vec![b'b'; 400]).unwrap();
        std::os::unix::fs::symlink(home.join("outside/big.bin"), docs.join("alias.bin")).unwrap();
        let report = scan(&env_at(home), &AtomicBool::new(false), &|_| {});
        let documents = report.folders.iter().find(|row| row.id == "documents").unwrap();
        assert_eq!(documents.bytes, 100);
        assert!(report.large.iter().all(|row| row.name != "alias.bin"));
        assert!(report.large.iter().all(|row| !row.path.contains("outside")));
    }

    #[test]
    fn bind_mount_points_inside_a_tree_are_skipped() {
        let dir = Temp::new("bind");
        let home = dir.path();
        let docs = home.join("Documents");
        let nested = docs.join("mounted");
        fs::create_dir_all(&nested).unwrap();
        fs::write(docs.join("keep.txt"), vec![b'x'; 50]).unwrap();
        fs::write(nested.join("skip.txt"), vec![b'y'; 500]).unwrap();
        let mut env = env_at(home);
        env.mountinfo = format!("22 1 8:2 / {nested} rw - ext4 /dev/sdb1 rw\n", nested = nested.display());
        let report = scan(&env, &AtomicBool::new(false), &|_| {});
        let documents = report.folders.iter().find(|row| row.id == "documents").unwrap();
        assert_eq!(documents.bytes, 50);
        assert!(report.skipped_mounts >= 1);
    }

    #[test]
    fn cancel_stops_and_marks_incomplete() {
        let dir = Temp::new("cancel");
        let home = dir.path();
        let docs = home.join("Documents");
        fs::create_dir_all(&docs).unwrap();
        for i in 0..40 {
            fs::write(docs.join(format!("f{i}.txt")), vec![b'z'; 8]).unwrap();
        }
        let cancel = AtomicBool::new(true);
        let report = scan(&env_at(home), &cancel, &|_| {});
        assert!(report.cancelled);
        assert!(report.incomplete);
        assert_eq!(report.reason, "cancelled");
    }

    #[test]
    fn entry_limit_is_not_a_full_disk_map() {
        let dir = Temp::new("limit");
        let home = dir.path();
        let docs = home.join("Documents");
        fs::create_dir_all(&docs).unwrap();
        for i in 0..8 {
            fs::write(docs.join(format!("n{i}.txt")), vec![1u8; 10]).unwrap();
        }
        let mut env = env_at(home);
        env.max_entries = 3;
        let report = scan(&env, &AtomicBool::new(false), &|_| {});
        assert!(report.incomplete);
        assert_eq!(report.reason, "limit");
        let documents = report.folders.iter().find(|row| row.id == "documents").unwrap();
        assert!(documents.bytes < 80);
        let folder_sum: u64 = report.folders.iter().map(|row| row.bytes).sum();
        assert!(folder_sum < 80);
    }

    #[test]
    fn cache_does_not_starve_trash_or_user_folders() {
        let dir = Temp::new("cache-last");
        let home = dir.path();
        let docs = home.join("Documents");
        let cache = home.join(".cache");
        let trash = home.join(".local/share/Trash/files");
        fs::create_dir_all(&docs).unwrap();
        fs::create_dir_all(&cache).unwrap();
        fs::create_dir_all(&trash).unwrap();
        fs::write(docs.join("note.txt"), vec![b'd'; 40]).unwrap();
        fs::write(trash.join("old.txt"), vec![b't'; 30]).unwrap();
        for i in 0..12 {
            fs::write(cache.join(format!("c{i}.bin")), vec![b'c'; 8]).unwrap();
        }
        let mut env = env_at(home);
        env.max_entries = 4;
        let report = scan(&env, &AtomicBool::new(false), &|_| {});
        assert!(report.incomplete);
        assert_eq!(report.reason, "limit");
        assert_eq!(report.trash.bytes, 30);
        let documents = report.folders.iter().find(|row| row.id == "documents").unwrap();
        assert_eq!(documents.bytes, 40);
        let cache_row = report.folders.iter().find(|row| row.id == "cache");
        assert!(cache_row.is_none() || cache_row.unwrap().bytes < 96);
    }

    #[test]
    fn volume_and_home_trash_are_both_measured() {
        let dir = Temp::new("vol-trash");
        let home = dir.path();
        let vol = home.join("mnt");
        let uid = unsafe { libc::getuid() };
        let home_files = home.join(".local/share/Trash/files");
        let vol_files = vol.join(format!(".Trash-{uid}/files"));
        fs::create_dir_all(&home_files).unwrap();
        fs::create_dir_all(&vol_files).unwrap();
        fs::write(home_files.join("home.bin"), vec![b'h'; 40]).unwrap();
        fs::write(vol_files.join("vol.bin"), vec![b'v'; 70]).unwrap();
        let mut env = env_at(home);
        env.mountinfo = format!(
            "22 1 8:20 / {} rw - ext4 /dev/sdb1 rw\n",
            vol.display()
        );
        let report = scan(&env, &AtomicBool::new(false), &|_| {});
        assert_eq!(report.trash.bytes, 110);
    }

    #[test]
    fn scan_payload_includes_volumes() {
        let payload = scan_payload(&env_at(Path::new("/")), &AtomicBool::new(false), &|_| {});
        assert_eq!(payload["action"], "scan");
        assert!(payload["volumes"].is_array());
        assert!(payload["folders"].is_array());
        assert!(payload["trash"].is_object());
    }

    #[test]
    fn permission_denied_is_reported() {
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        let dir = Temp::new("deny");
        let home = dir.path();
        let docs = home.join("Documents");
        let secret = docs.join("secret");
        fs::create_dir_all(&secret).unwrap();
        fs::write(secret.join("x.bin"), vec![7u8; 20]).unwrap();
        fs::set_permissions(&secret, fs::Permissions::from_mode(0o000)).unwrap();
        let report = scan(&env_at(home), &AtomicBool::new(false), &|_| {});
        let _ = fs::set_permissions(&secret, fs::Permissions::from_mode(0o755));
        assert!(report.denied >= 1);
        assert!(report.incomplete);
    }

    #[test]
    fn apps_require_a_matching_desktop_id() {
        let dir = Temp::new("apps");
        let home = dir.path();
        let share = home.join(".local/share");
        let apps = share.join("applications");
        fs::create_dir_all(&apps).unwrap();
        fs::write(apps.join("known.app.desktop"), "[Desktop Entry]\nName=Known\n").unwrap();
        fs::create_dir_all(share.join("known.app")).unwrap();
        fs::write(share.join("known.app/data"), vec![3u8; 30]).unwrap();
        fs::create_dir_all(share.join("mystery-cache")).unwrap();
        fs::write(share.join("mystery-cache/blob"), vec![3u8; 90]).unwrap();
        fs::create_dir_all(share.join("Trash/files")).unwrap();
        fs::write(share.join("Trash/files/old"), vec![3u8; 40]).unwrap();
        let report = scan(&env_at(home), &AtomicBool::new(false), &|_| {});
        assert_eq!(report.apps.len(), 1);
        assert_eq!(report.apps[0].id, "known.app");
        assert_eq!(report.apps[0].bytes, 30);
        assert_eq!(report.trash.bytes, 40);
        assert!(report.apps.iter().all(|row| row.id != "mystery-cache"));
    }
}
