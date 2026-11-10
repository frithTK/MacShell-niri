use serde_json::{json, Value};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub const PROTOCOL: &str = "macshell-desktop-source 1";

pub const BUILTINS: &[&str] = &[
    "macshell-clock",
    "macshell-calculator",
    "macshell-notes",
    "macshell-reminders",
    "macshell-stickies",
    "macshell-calendar",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Origin {
    Builtin,
    Local,
    System,
    Pacman,
    FlatpakUser,
    FlatpakSystem,
    Missing,
    Ambiguous,
}

impl Origin {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Builtin => "builtin",
            Self::Local => "local",
            Self::System => "system",
            Self::Pacman => "pacman",
            Self::FlatpakUser => "flatpak-user",
            Self::FlatpakSystem => "flatpak-system",
            Self::Missing => "missing",
            Self::Ambiguous => "ambiguous",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Source {
    pub app_id: String,
    pub path: Option<PathBuf>,
    pub origin: Origin,
    pub unique: bool,
    pub package: Option<String>,
    pub version: Option<String>,
    pub repo: Option<String>,
    pub official: bool,
    pub flatpak_id: Option<String>,
    pub name: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Plan {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub scope: &'static str,
    pub privileged: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mutation {
    Remove,
    Reinstall,
    Update,
}

impl Mutation {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "remove" => Some(Self::Remove),
            "reinstall" => Some(Self::Reinstall),
            "update" => Some(Self::Update),
            _ => None,
        }
    }
}

#[derive(Clone, Debug)]
pub struct ResolveEnv {
    pub home: PathBuf,
    pub data_home: PathBuf,
    pub data_dirs: Vec<PathBuf>,
    pub extra_flatpak: Vec<PathBuf>,
    pub pacman: PathBuf,
    pub flatpak: PathBuf,
    pub pkexec: PathBuf,
    pub mutate: bool,
    pub fixture: bool,
}

impl ResolveEnv {
    pub fn from_os() -> Self {
        let home = env::var_os("HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/"));
        let data_home = env::var_os("XDG_DATA_HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".local/share"));
        let data_dirs = env::var("XDG_DATA_DIRS")
            .ok()
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| "/usr/local/share:/usr/share".into())
            .split(':')
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .collect();
        let extra_flatpak = vec![
            home.join(".local/share/flatpak/exports/share"),
            PathBuf::from("/var/lib/flatpak/exports/share"),
        ];
        Self {
            home,
            data_home,
            data_dirs,
            extra_flatpak,
            pacman: env::var_os("MACSHELL_PACMAN")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("pacman")),
            flatpak: env::var_os("MACSHELL_FLATPAK")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("flatpak")),
            pkexec: env::var_os("MACSHELL_PKEXEC")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("pkexec")),
            mutate: true,
            fixture: env::var_os("MACSHELL_PACMAN").is_some()
                || env::var_os("MACSHELL_FLATPAK").is_some(),
        }
    }

    pub fn search_dirs(&self) -> Vec<PathBuf> {
        let mut dirs = Vec::with_capacity(2 + self.data_dirs.len() + self.extra_flatpak.len());
        dirs.push(self.data_home.clone());
        for dir in &self.data_dirs {
            if !dirs.iter().any(|seen| seen == dir) {
                dirs.push(dir.clone());
            }
        }
        for dir in &self.extra_flatpak {
            if !dirs.iter().any(|seen| seen == dir) {
                dirs.push(dir.clone());
            }
        }
        dirs
    }

    pub fn mutations_allowed(&self) -> bool {
        self.mutate
    }
}

pub fn normalize_id(id: &str) -> String {
    id.trim().trim_end_matches(".desktop").trim().to_string()
}

pub fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() < 256
        && !id.contains('/')
        && !id.contains('\\')
        && !id.contains("..")
        && !id.chars().any(|ch| ch.is_control())
}

pub fn resolve(id: &str, env: &ResolveEnv) -> Source {
    let app_id = normalize_id(id);
    if !valid_id(&app_id) {
        return missing("");
    }
    if BUILTINS.iter().any(|item| *item == app_id) {
        return Source {
            app_id,
            path: None,
            origin: Origin::Builtin,
            unique: true,
            package: None,
            version: None,
            repo: None,
            official: false,
            flatpak_id: None,
            name: None,
        };
    }
    let filename = format!("{app_id}.desktop");
    for dir in env.search_dirs() {
        let apps = dir.join("applications");
        if !apps.is_dir() {
            continue;
        }
        let mut hits = Vec::new();
        walk_named(&apps, &filename, &mut hits, 6);
        match hits.len() {
            0 => continue,
            1 => return classify(&app_id, &hits[0], env),
            _ => {
                return Source {
                    app_id,
                    path: None,
                    origin: Origin::Ambiguous,
                    unique: false,
                    package: None,
                    version: None,
                    repo: None,
                    official: false,
                    flatpak_id: None,
                    name: None,
                };
            }
        }
    }
    missing(&app_id)
}

fn missing(app_id: &str) -> Source {
    Source {
        app_id: app_id.to_string(),
        path: None,
        origin: Origin::Missing,
        unique: false,
        package: None,
        version: None,
        repo: None,
        official: false,
        flatpak_id: None,
        name: None,
    }
}

fn walk_named(dir: &Path, name: &str, out: &mut Vec<PathBuf>, depth: u8) {
    if depth == 0 {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() && !file_type.is_symlink() {
            walk_named(&path, name, out, depth.saturating_sub(1));
            continue;
        }
        if path.file_name().and_then(|value| value.to_str()) != Some(name) {
            continue;
        }
        if path.is_file() {
            out.push(path);
        }
    }
}

fn classify(app_id: &str, path: &Path, env: &ResolveEnv) -> Source {
    let name = desktop_value(path, "Name");
    if is_flatpak_export(path) {
        let user = is_user_flatpak(path, env);
        let flatpak_id = desktop_value(path, "X-Flatpak").or_else(|| Some(app_id.to_string()));
        return Source {
            app_id: app_id.to_string(),
            path: Some(path.to_path_buf()),
            origin: if user {
                Origin::FlatpakUser
            } else {
                Origin::FlatpakSystem
            },
            unique: true,
            package: flatpak_id.clone(),
            version: None,
            repo: None,
            official: true,
            flatpak_id,
            name,
        };
    }
    let local_apps = env.data_home.join("applications");
    if path.starts_with(&local_apps) {
        return Source {
            app_id: app_id.to_string(),
            path: Some(path.to_path_buf()),
            origin: Origin::Local,
            unique: true,
            package: None,
            version: None,
            repo: None,
            official: false,
            flatpak_id: None,
            name,
        };
    }
    if let Some(pkg) = pacman_owner(path, env) {
        let official = is_official_repo(pkg.repo.as_deref());
        return Source {
            app_id: app_id.to_string(),
            path: Some(path.to_path_buf()),
            origin: Origin::Pacman,
            unique: true,
            package: Some(pkg.name),
            version: pkg.version,
            repo: pkg.repo,
            official,
            flatpak_id: None,
            name,
        };
    }
    Source {
        app_id: app_id.to_string(),
        path: Some(path.to_path_buf()),
        origin: Origin::System,
        unique: true,
        package: None,
        version: None,
        repo: None,
        official: false,
        flatpak_id: None,
        name,
    }
}

fn is_flatpak_export(path: &Path) -> bool {
    path.to_string_lossy()
        .contains("/flatpak/exports/share/applications")
}

fn is_user_flatpak(path: &Path, env: &ResolveEnv) -> bool {
    let text = path.to_string_lossy();
    text.contains("/.local/share/flatpak/")
        || path.starts_with(env.home.join(".local/share/flatpak"))
        || path.starts_with(env.data_home.join("flatpak"))
}

fn desktop_value(path: &Path, key: &str) -> Option<String> {
    let text = fs::read_to_string(path).ok()?;
    let mut in_entry = false;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(rest) = line.strip_prefix('[') {
            in_entry = rest.trim_end_matches(']').trim() == "Desktop Entry";
            continue;
        }
        if !in_entry {
            continue;
        }
        if let Some((found, value)) = line.split_once('=') {
            if found == key {
                return Some(value.to_string());
            }
        }
    }
    None
}

struct Pkg {
    name: String,
    version: Option<String>,
    repo: Option<String>,
}

fn pacman_owner(path: &Path, env: &ResolveEnv) -> Option<Pkg> {
    let output = Command::new(&env.pacman)
        .args(["-Qo", "--"])
        .arg(path)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let mut pkg = parse_qo(&String::from_utf8_lossy(&output.stdout))?;
    if pkg.repo.is_none() {
        pkg.repo = pacman_repo(&pkg.name, env);
    }
    Some(pkg)
}

fn parse_qo(text: &str) -> Option<Pkg> {
    let rest = text.split(" is owned by ").nth(1)?.trim();
    let mut parts = rest.split_whitespace();
    let owned = parts.next()?;
    let version = parts.next().map(str::to_string);
    let (repo, name) = match owned.split_once('/') {
        Some((repo, name)) if !repo.is_empty() && !name.is_empty() => {
            (Some(repo.to_string()), name.to_string())
        }
        _ => (None, owned.to_string()),
    };
    if name.is_empty() {
        return None;
    }
    Some(Pkg {
        name,
        version,
        repo,
    })
}

fn pacman_repo(package: &str, env: &ResolveEnv) -> Option<String> {
    let output = Command::new(&env.pacman)
        .args(["-Qi", "--", package])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let line = line.trim();
        let rest = line.strip_prefix("Repository")?;
        let value = rest.trim_start_matches([' ', ':']).trim();
        if !value.is_empty() {
            return Some(value.to_string());
        }
    }
    None
}

fn is_official_repo(repo: Option<&str>) -> bool {
    matches!(repo, Some("core" | "extra" | "multilib"))
}

fn valid_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() < 256
        && !value.starts_with('-')
        && value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '+' | '-' | '@'))
}

fn expected_matches(source: &Source, data: &Value) -> Result<(), String> {
    let origin = data
        .get("origin")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "Confirmation is incomplete".to_string())?;
    let path = data.get("path").and_then(Value::as_str).unwrap_or("");
    let package = data.get("package").and_then(Value::as_str).unwrap_or("");
    let fresh_path = source
        .path
        .as_ref()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_default();
    let fresh_package = source.package.clone().unwrap_or_default();
    if source.origin.as_str() != origin
        || fresh_path != path
        || fresh_package != package
        || !source.unique
    {
        return Err("Source changed".into());
    }
    Ok(())
}

pub fn operations(source: &Source) -> Value {
    let reveal = source.path.is_some() && source.unique;
    let info = source.origin != Origin::Missing;
    let (remove, reinstall, update, remove_reason, reinstall_reason, update_reason) =
        match source.origin {
            Origin::Pacman if source.unique && source.official => (
                true,
                false,
                true,
                "confirm",
                "system-update",
                "confirm",
            ),
            Origin::Pacman if source.unique => (
                true,
                false,
                false,
                "unofficial",
                "unofficial",
                "unofficial",
            ),
            Origin::FlatpakUser | Origin::FlatpakSystem if source.unique => {
                (true, true, true, "confirm", "confirm", "confirm")
            }
            Origin::Builtin => (false, false, false, "builtin", "builtin", "builtin"),
            Origin::Local => (false, false, false, "local", "local", "local"),
            Origin::System => (false, false, false, "unowned", "unowned", "unowned"),
            Origin::Ambiguous => (false, false, false, "ambiguous", "ambiguous", "ambiguous"),
            Origin::Missing => (false, false, false, "missing", "missing", "missing"),
            _ => (false, false, false, "missing", "missing", "missing"),
        };
    json!({
        "reveal": reveal,
        "info": info,
        "remove": remove,
        "reinstall": reinstall,
        "update": update,
        "reasons": {
            "remove": remove_reason,
            "reinstall": reinstall_reason,
            "update": update_reason,
        }
    })
}

pub fn source_json(source: &Source) -> Value {
    json!({
        "appId": source.app_id,
        "path": source.path.as_ref().map(|path| path.to_string_lossy().into_owned()).unwrap_or_default(),
        "origin": source.origin.as_str(),
        "unique": source.unique,
        "package": source.package.clone().unwrap_or_default(),
        "version": source.version.clone().unwrap_or_default(),
        "repo": source.repo.clone().unwrap_or_default(),
        "official": source.official,
        "flatpakId": source.flatpak_id.clone().unwrap_or_default(),
        "name": source.name.clone().unwrap_or_default(),
        "operations": operations(source),
    })
}

pub fn plan_mutation(source: &Source, action: Mutation, env: &ResolveEnv) -> Result<Plan, String> {
    if !source.unique {
        return Err("Source is ambiguous".into());
    }
    match (source.origin, action) {
        (Origin::Pacman, Mutation::Update) if source.official => Ok(Plan {
            program: env.pacman.clone(),
            args: vec!["-Syu".into(), "--noconfirm".into()],
            scope: "system-update",
            privileged: true,
        }),
        (Origin::Pacman, Mutation::Remove) if source.official => {
            let package = source
                .package
                .clone()
                .filter(|value| valid_token(value))
                .ok_or_else(|| "Package name is missing".to_string())?;
            Ok(Plan {
                program: env.pacman.clone(),
                args: vec!["-Rns".into(), "--noconfirm".into(), "--".into(), package],
                scope: "package",
                privileged: true,
            })
        }
        (Origin::Pacman, Mutation::Reinstall) => {
            Err("Pacman reinstall would be a partial upgrade; use a full system update".into())
        }
        (Origin::Pacman, _) => Err("Not an official repository package".into()),
        (Origin::FlatpakUser | Origin::FlatpakSystem, action) => {
            let id = source
                .flatpak_id
                .clone()
                .or_else(|| source.package.clone())
                .filter(|value| valid_token(value))
                .ok_or_else(|| "Flatpak ID is missing".to_string())?;
            let mut args = vec![match action {
                Mutation::Remove => "uninstall".into(),
                Mutation::Reinstall => "install".into(),
                Mutation::Update => "update".into(),
            }];
            if action == Mutation::Reinstall {
                args.push("--reinstall".into());
            }
            args.push("--noninteractive".into());
            if source.origin == Origin::FlatpakUser {
                args.push("--user".into());
            } else {
                args.push("--system".into());
            }
            args.push("--".into());
            args.push(id);
            Ok(Plan {
                program: env.flatpak.clone(),
                args,
                scope: "package",
                privileged: source.origin == Origin::FlatpakSystem,
            })
        }
        (Origin::Builtin, _) => Err("Built-in MacShell app".into()),
        (Origin::Local, _) => Err("Local shortcut is not a package".into()),
        (Origin::System, _) => Err("File is not owned by a package".into()),
        (Origin::Missing, _) => Err("App location is unknown".into()),
        (Origin::Ambiguous, _) => Err("Source is ambiguous".into()),
    }
}

fn run_plan(plan: &Plan, env: &ResolveEnv) -> Result<std::process::Output, String> {
    let mut command = if env.fixture {
        let mut command = Command::new(&plan.program);
        command.args(&plan.args);
        command
    } else if plan.privileged {
        let mut command = Command::new(&env.pkexec);
        command.arg(&plan.program).args(&plan.args);
        command
    } else {
        let mut command = Command::new(&plan.program);
        command.args(&plan.args);
        command
    };
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|error| error.to_string())
}

pub fn apply_mutation(
    source: &Source,
    action: Mutation,
    env: &ResolveEnv,
) -> Result<Value, String> {
    if !env.mutations_allowed() {
        return Err("Package changes are not enabled".into());
    }
    let plan = plan_mutation(source, action, env)?;
    let output = run_plan(&plan, env)?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let detail: String = stderr.chars().take(200).collect();
        return Err(if detail.is_empty() {
            "Package operation failed".into()
        } else {
            detail
        });
    }
    Ok(json!({
        "scope": plan.scope,
        "program": plan.program.to_string_lossy(),
        "args": plan.args,
        "privileged": plan.privileged,
        "fixture": env.fixture,
    }))
}

pub fn handle(action: &str, data: &Value, env: &ResolveEnv) -> Value {
    match action {
        "resolve" => {
            let id = data.get("id").and_then(Value::as_str).unwrap_or("");
            let source = resolve(id, env);
            json!({"success": true, "source": source_json(&source)})
        }
        "apply" => {
            let id = data.get("id").and_then(Value::as_str).unwrap_or("");
            let op = data.get("op").and_then(Value::as_str).unwrap_or("");
            let Some(action) = Mutation::parse(op) else {
                return json!({"success": false, "error": "Unknown package operation"});
            };
            let source = resolve(id, env);
            if let Err(error) = expected_matches(&source, data) {
                return json!({"success": false, "error": error});
            }
            match apply_mutation(&source, action, env) {
                Ok(result) => json!({"success": true, "result": result}),
                Err(error) => json!({"success": false, "error": error}),
            }
        }
        _ => json!({"success": false, "error": "Unknown action"}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::os::unix::fs::PermissionsExt;
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
            let path = env::temp_dir().join(format!(
                "macshell-ds-{}-{}-{}-{name}",
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

    fn write(path: &Path, body: &str) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, body).unwrap();
    }

    fn desktop(path: &Path, name: &str, extra: &str) {
        write(
            path,
            &format!("[Desktop Entry]\nType=Application\nName={name}\nExec=true\n{extra}"),
        );
    }

    fn fixture_env(root: &Path, pacman: &Path) -> ResolveEnv {
        ResolveEnv {
            home: root.join("home"),
            data_home: root.join("data"),
            data_dirs: vec![root.join("system")],
            extra_flatpak: vec![
                root.join("home/.local/share/flatpak/exports/share"),
                root.join("flatpak-system/exports/share"),
            ],
            pacman: pacman.to_path_buf(),
            flatpak: root.join("bin/flatpak"),
            pkexec: root.join("bin/pkexec"),
            mutate: false,
            fixture: false,
        }
    }

    fn fake_pacman(root: &Path, owned: &Path, repo: &str, name: &str, version: &str) -> PathBuf {
        let bin = root.join("bin/pacman");
        let log = root.join("pacman.log");
        write(
            &bin,
            &format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> {log}\ncase \"$1\" in\n  -Qo)\n    if [ \"$3\" = {owned} ]; then echo \"$3 is owned by {repo}/{name} {version}\"; exit 0; fi\n    echo \"error: No package owns $3\" >&2; exit 1 ;;\n  -Qi)\n    echo \"Repository         : {repo}\"; exit 0 ;;\n  -Syu|-Rns|-S) echo ok; exit 0 ;;\nesac\nexit 1\n",
                log = serde_json::to_string(&log.to_string_lossy().into_owned()).unwrap(),
                owned = serde_json::to_string(&owned.to_string_lossy().into_owned()).unwrap(),
            ),
        );
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();
        write(&log, "");
        bin
    }

    #[test]
    fn builtins_are_not_looked_up_on_disk() {
        let tmp = Temp::new("builtin");
        let env = fixture_env(tmp.path(), &tmp.path().join("missing-pacman"));
        desktop(
            &env.data_home.join("applications/macshell-clock.desktop"),
            "Fake",
            "",
        );
        let source = resolve("macshell-clock.desktop", &env);
        assert_eq!(source.origin, Origin::Builtin);
        assert!(source.unique);
        assert!(source.path.is_none());
        assert_eq!(operations(&source)["remove"], false);
    }

    #[test]
    fn local_shortcut_wins_over_later_system_copy() {
        let tmp = Temp::new("override");
        let env = fixture_env(tmp.path(), &tmp.path().join("missing-pacman"));
        desktop(
            &env.data_home.join("applications/foo.desktop"),
            "Local Foo",
            "",
        );
        desktop(
            &env.data_dirs[0].join("applications/foo.desktop"),
            "System Foo",
            "",
        );
        let source = resolve("foo", &env);
        assert_eq!(source.origin, Origin::Local);
        assert!(source.unique);
        assert_eq!(source.name.as_deref(), Some("Local Foo"));
        assert_eq!(operations(&source)["reasons"]["remove"], "local");
    }

    #[test]
    fn nested_desktop_file_is_unique() {
        let tmp = Temp::new("nested");
        let env = fixture_env(tmp.path(), &tmp.path().join("missing-pacman"));
        desktop(
            &env.data_dirs[0].join("applications/kde/org.kde.dolphin.desktop"),
            "Dolphin",
            "",
        );
        let source = resolve("org.kde.dolphin", &env);
        assert_eq!(source.origin, Origin::System);
        assert!(source.unique);
        assert!(source
            .path
            .as_ref()
            .unwrap()
            .ends_with("applications/kde/org.kde.dolphin.desktop"));
    }

    #[test]
    fn duplicate_in_the_same_tree_is_ambiguous() {
        let tmp = Temp::new("ambiguous");
        let env = fixture_env(tmp.path(), &tmp.path().join("missing-pacman"));
        desktop(
            &env.data_dirs[0].join("applications/foo.desktop"),
            "A",
            "",
        );
        desktop(
            &env.data_dirs[0].join("applications/kde/foo.desktop"),
            "B",
            "",
        );
        let source = resolve("foo", &env);
        assert_eq!(source.origin, Origin::Ambiguous);
        assert!(!source.unique);
        assert_eq!(operations(&source)["reasons"]["remove"], "ambiguous");
        assert!(plan_mutation(&source, Mutation::Remove, &env).is_err());
    }

    #[test]
    fn official_pacman_package_is_classified_without_guessing_the_name() {
        let tmp = Temp::new("pacman");
        let desktop_path = tmp
            .path()
            .join("system/applications/org.kde.dolphin.desktop");
        desktop(&desktop_path, "Dolphin", "");
        let pacman = fake_pacman(tmp.path(), &desktop_path, "extra", "dolphin", "24.12.3-1");
        let env = fixture_env(tmp.path(), &pacman);
        let source = resolve("org.kde.dolphin", &env);
        assert_eq!(source.origin, Origin::Pacman);
        assert_eq!(source.package.as_deref(), Some("dolphin"));
        assert_eq!(source.version.as_deref(), Some("24.12.3-1"));
        assert_eq!(source.repo.as_deref(), Some("extra"));
        assert!(source.official);
        let ops = operations(&source);
        assert_eq!(ops["remove"], true);
        assert_eq!(ops["reinstall"], false);
        assert_eq!(ops["update"], true);
        let update = plan_mutation(&source, Mutation::Update, &env).unwrap();
        assert_eq!(update.args, ["-Syu", "--noconfirm"]);
        assert_eq!(update.scope, "system-update");
        assert!(update.privileged);
        let remove = plan_mutation(&source, Mutation::Remove, &env).unwrap();
        assert_eq!(remove.args, ["-Rns", "--noconfirm", "--", "dolphin"]);
        assert!(plan_mutation(&source, Mutation::Reinstall, &env)
            .unwrap_err()
            .contains("partial upgrade"));
    }

    #[test]
    fn unofficial_pacman_package_is_not_treated_as_official() {
        let tmp = Temp::new("aur");
        let desktop_path = tmp.path().join("system/applications/example.desktop");
        desktop(&desktop_path, "Example", "");
        let pacman = fake_pacman(tmp.path(), &desktop_path, "aur", "example-bin", "1-1");
        let env = fixture_env(tmp.path(), &pacman);
        let source = resolve("example", &env);
        assert_eq!(source.origin, Origin::Pacman);
        assert!(!source.official);
        assert_eq!(operations(&source)["reasons"]["remove"], "unofficial");
        assert!(plan_mutation(&source, Mutation::Update, &env)
            .unwrap_err()
            .contains("official"));
    }

    #[test]
    fn user_flatpak_export_is_distinct_from_system() {
        let tmp = Temp::new("flatpak");
        let env = fixture_env(tmp.path(), &tmp.path().join("missing-pacman"));
        desktop(
            &env.extra_flatpak[0].join("applications/org.example.App.desktop"),
            "Example",
            "X-Flatpak=org.example.App\n",
        );
        let source = resolve("org.example.App", &env);
        assert_eq!(source.origin, Origin::FlatpakUser);
        assert_eq!(source.flatpak_id.as_deref(), Some("org.example.App"));
        let plan = plan_mutation(&source, Mutation::Remove, &env).unwrap();
        assert_eq!(
            plan.args,
            ["uninstall", "--noninteractive", "--user", "--", "org.example.App"]
        );
        assert!(!plan.privileged);
        let reinstall = plan_mutation(&source, Mutation::Reinstall, &env).unwrap();
        assert_eq!(
            reinstall.args,
            [
                "install",
                "--reinstall",
                "--noninteractive",
                "--user",
                "--",
                "org.example.App"
            ]
        );
    }

    #[test]
    fn apply_is_refused_without_fixture_managers() {
        let tmp = Temp::new("apply");
        let desktop_path = tmp.path().join("system/applications/foo.desktop");
        desktop(&desktop_path, "Foo", "");
        let pacman = fake_pacman(tmp.path(), &desktop_path, "extra", "foo", "1-1");
        let env = fixture_env(tmp.path(), &pacman);
        let source = resolve("foo", &env);
        let err = apply_mutation(&source, Mutation::Remove, &env).unwrap_err();
        assert!(err.contains("not enabled"));
    }

    #[test]
    fn apply_with_fixture_records_argv_and_does_not_call_host_pacman() {
        let tmp = Temp::new("mutate");
        let desktop_path = tmp.path().join("system/applications/foo.desktop");
        desktop(&desktop_path, "Foo", "");
        let pacman = fake_pacman(tmp.path(), &desktop_path, "extra", "foo", "1-1");
        let log = tmp.path().join("pacman.log");
        let mut env = fixture_env(tmp.path(), &pacman);
        env.mutate = true;
        env.fixture = true;
        let source = resolve("foo", &env);
        let result = apply_mutation(&source, Mutation::Update, &env).unwrap();
        assert_eq!(result["scope"], "system-update");
        assert_eq!(result["fixture"], true);
        let recorded = fs::read_to_string(&log).unwrap();
        assert!(recorded.contains("-Syu --noconfirm"));
        assert!(!recorded.contains("-S foo"));
        assert!(!tmp.path().join("bin/pkexec").is_file());
    }

    #[test]
    fn handle_rejects_unknown_actions_and_invalid_ids() {
        let tmp = Temp::new("handle");
        let env = fixture_env(tmp.path(), &tmp.path().join("missing"));
        let unknown = handle("explode", &json!({}), &env);
        assert_eq!(unknown["success"], false);
        let missing = handle("resolve", &json!({"id": "../etc/passwd"}), &env);
        assert_eq!(missing["source"]["origin"], "missing");
        let apply = handle(
            "apply",
            &json!({"id": "foo", "op": "remove"}),
            &env,
        );
        assert_eq!(apply["success"], false);
        assert!(apply["error"].as_str().unwrap().contains("incomplete"));
    }

    fn fingerprint(source: &Source) -> Value {
        json!({
            "id": source.app_id,
            "op": "remove",
            "origin": source.origin.as_str(),
            "path": source.path.as_ref().map(|path| path.to_string_lossy().into_owned()).unwrap_or_default(),
            "package": source.package.clone().unwrap_or_default(),
        })
    }

    #[test]
    fn stale_source_refuses_apply_before_running_the_manager() {
        let tmp = Temp::new("stale");
        let desktop_path = tmp.path().join("system/applications/foo.desktop");
        desktop(&desktop_path, "Foo", "");
        let pacman = fake_pacman(tmp.path(), &desktop_path, "extra", "foo", "1-1");
        let mut env = fixture_env(tmp.path(), &pacman);
        env.mutate = true;
        env.fixture = true;
        let source = resolve("foo", &env);
        let mut data = fingerprint(&source);
        data["path"] = json!("/tmp/other.desktop");
        let result = handle("apply", &data, &env);
        assert_eq!(result["success"], false);
        assert_eq!(result["error"], "Source changed");
        assert!(!fs::read_to_string(tmp.path().join("pacman.log")).unwrap().contains("-Rns"));
    }

    #[test]
    fn apply_failure_is_not_reported_as_success() {
        let tmp = Temp::new("fail");
        let desktop_path = tmp.path().join("system/applications/foo.desktop");
        desktop(&desktop_path, "Foo", "");
        let pacman = tmp.path().join("bin/pacman");
        write(
            &pacman,
            "#!/bin/sh\nif [ \"$1\" = \"-Qo\" ]; then echo \"$3 is owned by extra/foo 1-1\"; exit 0; fi\nif [ \"$1\" = \"-Qi\" ]; then echo \"Repository         : extra\"; exit 0; fi\necho denied >&2\nexit 1\n",
        );
        fs::set_permissions(&pacman, fs::Permissions::from_mode(0o755)).unwrap();
        let mut env = fixture_env(tmp.path(), &pacman);
        env.mutate = true;
        env.fixture = true;
        let source = resolve("foo", &env);
        let err = apply_mutation(&source, Mutation::Update, &env).unwrap_err();
        assert!(err.contains("denied"));
    }

    #[test]
    fn production_pacman_goes_through_pkexec_and_does_not_run_host_pacman() {
        let tmp = Temp::new("pkexec");
        let desktop_path = tmp.path().join("system/applications/foo.desktop");
        desktop(&desktop_path, "Foo", "");
        let pacman = fake_pacman(tmp.path(), &desktop_path, "extra", "foo", "1-1");
        let pkexec = tmp.path().join("bin/pkexec");
        let log = tmp.path().join("pkexec.log");
        write(
            &pkexec,
            &format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> {log}\nexit 0\n",
                log = serde_json::to_string(&log.to_string_lossy().into_owned()).unwrap(),
            ),
        );
        fs::set_permissions(&pkexec, fs::Permissions::from_mode(0o755)).unwrap();
        write(&log, "");
        let mut env = fixture_env(tmp.path(), &PathBuf::from("pacman"));
        env.pacman = PathBuf::from("pacman");
        env.pkexec = pkexec;
        env.mutate = true;
        env.fixture = false;
        // Resolve still uses the fake owner lookup.
        env.pacman = pacman.clone();
        let source = resolve("foo", &env);
        env.pacman = PathBuf::from("pacman");
        let result = apply_mutation(&source, Mutation::Update, &env).unwrap();
        assert_eq!(result["privileged"], true);
        assert_eq!(result["fixture"], false);
        let recorded = fs::read_to_string(&log).unwrap();
        assert!(recorded.contains("pacman -Syu --noconfirm"));
        let owner_log = fs::read_to_string(tmp.path().join("pacman.log")).unwrap();
        assert!(owner_log.contains("-Qo"));
        assert!(!owner_log.contains("-Syu"));
    }

    #[test]
    fn user_flatpak_apply_skips_pkexec() {
        let tmp = Temp::new("fp-apply");
        let mut env = fixture_env(tmp.path(), &tmp.path().join("missing-pacman"));
        desktop(
            &env.extra_flatpak[0].join("applications/org.example.App.desktop"),
            "Example",
            "X-Flatpak=org.example.App\n",
        );
        let flatpak = tmp.path().join("bin/flatpak");
        let log = tmp.path().join("flatpak.log");
        let pkexec = tmp.path().join("bin/pkexec");
        write(
            &flatpak,
            &format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> {log}\nexit 0\n",
                log = serde_json::to_string(&log.to_string_lossy().into_owned()).unwrap(),
            ),
        );
        write(&pkexec, "#!/bin/sh\nexit 1\n");
        fs::set_permissions(&flatpak, fs::Permissions::from_mode(0o755)).unwrap();
        fs::set_permissions(&pkexec, fs::Permissions::from_mode(0o755)).unwrap();
        write(&log, "");
        env.flatpak = flatpak;
        env.pkexec = pkexec;
        env.mutate = true;
        env.fixture = true;
        let source = resolve("org.example.App", &env);
        let result = apply_mutation(&source, Mutation::Remove, &env).unwrap();
        assert_eq!(result["privileged"], false);
        let recorded = fs::read_to_string(&log).unwrap();
        assert!(recorded.contains("uninstall --noninteractive --user -- org.example.App"));
        assert!(!recorded.contains("delete-data"));
    }

    #[test]
    fn mutate_without_confirmation_fields_is_incomplete() {
        let tmp = Temp::new("incomplete");
        let desktop_path = tmp.path().join("system/applications/foo.desktop");
        desktop(&desktop_path, "Foo", "");
        let pacman = fake_pacman(tmp.path(), &desktop_path, "extra", "foo", "1-1");
        let mut env = fixture_env(tmp.path(), &pacman);
        env.mutate = true;
        env.fixture = true;
        let result = handle("apply", &json!({"id": "foo", "op": "remove"}), &env);
        assert_eq!(result["success"], false);
        assert!(result["error"].as_str().unwrap().contains("incomplete"));
        assert!(!fs::read_to_string(tmp.path().join("pacman.log")).unwrap().contains("-Rns"));
    }
}
