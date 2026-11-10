use std::env;
use std::ffi::OsString;
use std::io::{self, Read};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub const PROTOCOL: &str = "macshell-file-search 1";
pub const DEFAULT_LIMIT: usize = 8;
pub const MIN_QUERY_CHARS: usize = 2;

pub struct SearchEnv {
    pub root: Option<PathBuf>,
    pub home: PathBuf,
    pub limit: usize,
    pub localsearch: PathBuf,
    pub fd: PathBuf,
    pub find: PathBuf,
}

impl SearchEnv {
    pub fn from_os() -> Self {
        Self {
            root: env::var_os("MACSHELL_FILE_SEARCH_ROOT").map(PathBuf::from),
            home: env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/")),
            limit: env::var("MACSHELL_FILE_SEARCH_LIMIT")
                .ok()
                .and_then(|value| value.parse().ok())
                .filter(|value| *value > 0)
                .unwrap_or(DEFAULT_LIMIT),
            localsearch: tool_path("MACSHELL_FILE_SEARCH_LOCALSEARCH", "localsearch"),
            fd: tool_path("MACSHELL_FILE_SEARCH_FD", "fd"),
            find: tool_path("MACSHELL_FILE_SEARCH_FIND", "find"),
        }
    }
}

fn tool_path(var: &str, fallback: &str) -> PathBuf {
    env::var_os(var)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(fallback))
}

pub fn glob_escape(query: &str) -> String {
    let mut out = String::with_capacity(query.len());
    for ch in query.chars() {
        match ch {
            '*' | '?' | '[' | ']' | '\\' => {
                out.push('\\');
                out.push(ch);
            }
            _ => out.push(ch),
        }
    }
    out
}

pub fn parse_file_uri(line: &str) -> Option<PathBuf> {
    let line = line.trim();
    let rest = line.strip_prefix("file://")?;
    let path = if rest.starts_with('/') {
        rest
    } else {
        let slash = rest.find('/')?;
        &rest[slash..]
    };
    Some(PathBuf::from(percent_decode(path)?))
}

fn percent_decode(input: &str) -> Option<String> {
    let mut bytes = Vec::with_capacity(input.len());
    let raw = input.as_bytes();
    let mut i = 0;
    while i < raw.len() {
        match raw[i] {
            b'%' if i + 2 < raw.len() => {
                let hi = from_hex(raw[i + 1])?;
                let lo = from_hex(raw[i + 2])?;
                bytes.push((hi << 4) | lo);
                i += 3;
            }
            b'+' => {
                bytes.push(b'+');
                i += 1;
            }
            byte => {
                bytes.push(byte);
                i += 1;
            }
        }
    }
    String::from_utf8(bytes).ok()
}

fn from_hex(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

pub fn query_ok(query: &str) -> bool {
    let trimmed = query.trim();
    !trimmed.is_empty()
        && trimmed.chars().count() >= MIN_QUERY_CHARS
        && !trimmed.contains('\0')
        && !trimmed.contains('\n')
        && !trimmed.contains('\r')
}

fn basename_matches(path: &Path, query: &str) -> bool {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("");
    name.to_lowercase().contains(&query.trim().to_lowercase())
}

fn excluded(path: &Path) -> bool {
    let mut parts = Vec::new();
    for component in path.components() {
        match component {
            Component::Normal(name) => {
                let label = name.to_string_lossy();
                if label == ".cache"
                    || label == ".git"
                    || label == "node_modules"
                    || label == "Trash"
                    || label == ".Trash"
                {
                    return true;
                }
                if label == ".local" {
                    parts.push(label.into_owned());
                    continue;
                }
                parts.clear();
            }
            _ => parts.clear(),
        }
    }
    false
}

fn excluded_local_trash(path: &Path) -> bool {
    let text = path.to_string_lossy();
    text.contains("/.local/share/Trash/") || text.contains("/.local/share/Trash")
}

pub fn keep_hit(path: &Path, query: &str, root: Option<&Path>) -> bool {
    if let Some(root) = root {
        if !path.starts_with(root) {
            return false;
        }
    }
    if excluded(path) || excluded_local_trash(path) {
        return false;
    }
    if !path.is_file() {
        return false;
    }
    basename_matches(path, query)
}

fn push_unique(out: &mut Vec<PathBuf>, path: PathBuf, limit: usize) {
    if out.len() >= limit {
        return;
    }
    if out.iter().any(|existing| existing == &path) {
        return;
    }
    out.push(path);
}

fn run_stdout(program: &Path, args: &[OsString], timeout: Duration) -> Result<String, String> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| error.to_string())?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| "missing stdout".to_string())?;
    let mut bytes = Vec::new();
    let started = Instant::now();
    let mut buffer = [0u8; 8192];
    loop {
        if started.elapsed() > timeout {
            let _ = child.kill();
            let _ = child.wait();
            return Err("search timed out".into());
        }
        match stdout.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => {
                bytes.extend_from_slice(&buffer[..count]);
                if bytes.len() > 512 * 1024 {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err("search output too large".into());
                }
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error.to_string());
            }
        }
    }
    let _ = child.wait();
    String::from_utf8(bytes).map_err(|error| error.to_string())
}

fn localsearch(query: &str, env: &SearchEnv) -> Option<Vec<PathBuf>> {
    if env.root.is_some() {
        return None;
    }
    let fetch = env.limit.saturating_mul(4).max(env.limit);
    let args = [
        OsString::from("search"),
        OsString::from("-f"),
        OsString::from("-l"),
        OsString::from(fetch.to_string()),
        OsString::from("--"),
        OsString::from(query.trim()),
    ];
    let text = run_stdout(&env.localsearch, &args, Duration::from_secs(2)).ok()?;
    let mut out = Vec::new();
    for line in text.lines() {
        let Some(path) = parse_file_uri(line) else {
            continue;
        };
        if keep_hit(&path, query, None) {
            push_unique(&mut out, path, env.limit);
        }
        if out.len() >= env.limit {
            break;
        }
    }
    Some(out)
}

fn fd_search(query: &str, env: &SearchEnv) -> Vec<PathBuf> {
    let pattern = format!("*{}*", glob_escape(query.trim()));
    let roots = search_roots(env);
    if roots.is_empty() {
        return Vec::new();
    }
    let mut args = vec![
        OsString::from("--glob"),
        OsString::from("--color=never"),
        OsString::from("--max-results"),
        OsString::from(env.limit.to_string()),
        OsString::from("-t"),
        OsString::from("f"),
        OsString::from("--exclude"),
        OsString::from(".cache"),
        OsString::from("--exclude"),
        OsString::from(".git"),
        OsString::from("--exclude"),
        OsString::from("node_modules"),
        OsString::from("--exclude"),
        OsString::from("Trash"),
        OsString::from("--exclude"),
        OsString::from(".Trash"),
        OsString::from("--"),
        OsString::from(pattern),
    ];
    for root in &roots {
        args.push(root.into());
    }
    let Ok(text) = run_stdout(&env.fd, &args, Duration::from_secs(3)) else {
        return Vec::new();
    };
    collect_lines(&text, query, env)
}

fn find_search(query: &str, env: &SearchEnv) -> Vec<PathBuf> {
    let pattern = format!("*{}*", glob_escape(query.trim()));
    let roots = search_roots(env);
    let mut out = Vec::new();
    for root in roots {
        let args = [
            root.into(),
            OsString::from("-type"),
            OsString::from("f"),
            OsString::from("-iname"),
            OsString::from(&pattern),
        ];
        let Ok(text) = run_stdout(&env.find, &args, Duration::from_secs(3)) else {
            continue;
        };
        for path in collect_lines(&text, query, env) {
            push_unique(&mut out, path, env.limit);
            if out.len() >= env.limit {
                return out;
            }
        }
    }
    out
}

fn search_roots(env: &SearchEnv) -> Vec<PathBuf> {
    if let Some(root) = &env.root {
        return if root.is_dir() {
            vec![root.clone()]
        } else {
            Vec::new()
        };
    }
    if env.home.is_dir() {
        vec![env.home.clone()]
    } else {
        Vec::new()
    }
}

fn collect_lines(text: &str, query: &str, env: &SearchEnv) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for line in text.lines() {
        let path = PathBuf::from(line.trim());
        if path.as_os_str().is_empty() {
            continue;
        }
        if keep_hit(&path, query, env.root.as_deref()) {
            push_unique(&mut out, path, env.limit);
        }
        if out.len() >= env.limit {
            break;
        }
    }
    out
}

pub fn search(query: &str, env: &SearchEnv) -> Result<Vec<PathBuf>, String> {
    if !query_ok(query) {
        return Ok(Vec::new());
    }
    if let Some(hits) = localsearch(query, env) {
        if !hits.is_empty() {
            return Ok(hits);
        }
    }
    let hits = fd_search(query, env);
    if !hits.is_empty() {
        return Ok(hits);
    }
    Ok(find_search(query, env))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TICK: AtomicU64 = AtomicU64::new(0);

    fn stamp() -> u64 {
        TICK.fetch_add(1, Ordering::Relaxed)
    }

    fn temp_dir() -> PathBuf {
        let path = env::temp_dir().join(format!(
            "macshell-file-search-{}-{}",
            std::process::id(),
            stamp()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn write_exec(path: &Path, body: &str) {
        fs::write(path, body).unwrap();
        let mut permissions = fs::metadata(path).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(path, permissions).unwrap();
    }

    fn env_for(root: PathBuf) -> SearchEnv {
        SearchEnv {
            root: Some(root.clone()),
            home: root,
            limit: 8,
            localsearch: PathBuf::from("/usr/bin/false"),
            fd: PathBuf::from("/usr/bin/false"),
            find: PathBuf::from("find"),
        }
    }

    #[test]
    fn protocol_and_query_guards() {
        assert_eq!(PROTOCOL, "macshell-file-search 1");
        assert!(!query_ok("a"));
        assert!(!query_ok(" *"));
        assert!(query_ok("ph"));
        assert!(!query_ok("a\nb"));
        assert_eq!(glob_escape("a*b?c[d]"), r"a\*b\?c\[d\]");
    }

    #[test]
    fn file_uri_decodes_utf8() {
        let path = parse_file_uri(
            "file:///home/frith/%D0%97%D0%B0%D0%B3%D1%80%D1%83%D0%B7%D0%BA%D0%B8/photo.png",
        )
        .unwrap();
        assert_eq!(path, PathBuf::from("/home/frith/Загрузки/photo.png"));
    }

    #[test]
    fn find_in_root_skips_node_modules_and_globs() {
        let root = temp_dir();
        fs::create_dir_all(root.join("node_modules")).unwrap();
        fs::write(root.join("holiday photo.png"), b"ok").unwrap();
        fs::write(root.join("readme.txt"), b"photo in content").unwrap();
        fs::write(root.join("node_modules/photo.png"), b"no").unwrap();
        fs::write(root.join("star*name.png"), b"x").unwrap();
        let env = env_for(root.clone());
        let hits = search("photo", &env).unwrap();
        assert_eq!(hits, vec![root.join("holiday photo.png")]);
        let starred = search("star", &env).unwrap();
        assert_eq!(starred, vec![root.join("star*name.png")]);
        let globbed = search("a*", &env).unwrap();
        assert!(globbed.is_empty());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn localsearch_hits_are_filtered_to_basename() {
        let root = temp_dir();
        fs::write(root.join("photo.png"), b"ok").unwrap();
        fs::write(root.join("notes.txt"), b"photo").unwrap();
        let localsearch = root.join("localsearch");
        write_exec(
            &localsearch,
            &format!(
                "#!/bin/sh\nprintf '%s\\n%s\\n' 'file://{}/photo.png' 'file://{}/notes.txt'\n",
                root.display(),
                root.display()
            ),
        );
        let env = SearchEnv {
            root: None,
            home: root.clone(),
            limit: 8,
            localsearch,
            fd: PathBuf::from("/usr/bin/false"),
            find: PathBuf::from("/usr/bin/false"),
        };
        let hits = search("photo", &env).unwrap();
        assert_eq!(hits, vec![root.join("photo.png")]);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn root_does_not_call_localsearch() {
        let root = temp_dir();
        fs::write(root.join("photo.png"), b"ok").unwrap();
        let localsearch = root.join("localsearch");
        write_exec(&localsearch, "#!/bin/sh\necho should-not-run >&2\nexit 1\n");
        let mut env = env_for(root.clone());
        env.localsearch = localsearch;
        let hits = search("photo", &env).unwrap();
        assert_eq!(hits, vec![root.join("photo.png")]);
        let _ = fs::remove_dir_all(root);
    }
}
