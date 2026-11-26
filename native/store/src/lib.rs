use serde_json::{json, Value};

pub const PROTOCOL: &str = "macshell-store 1";
pub const SOURCE_CHANGED: &str = "Source changed";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub name: String,
    pub version: String,
    pub repo: String,
    pub description: String,
    pub installed: bool,
    pub scope: String,
    pub new_version: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Selection {
    pub action: String,
    pub source: String,
    pub name: String,
    pub version: String,
    pub repo: String,
    pub scope: String,
}

pub fn valid_query(query: &str) -> bool {
    let query = query.trim();
    let chars = query.chars().count();
    (2..80).contains(&chars) && !query.chars().any(|ch| ch.is_control())
}

pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() < 256
        && !name.starts_with('-')
        && !name.contains("..")
        && !name.chars().any(|ch| ch.is_whitespace() || ch.is_control())
        && name
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '+' | '-' | '@'))
}

fn valid_version(version: &str) -> bool {
    !version.is_empty()
        && version.len() < 128
        && version
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '+' | '-' | ':' | '~'))
}

fn valid_repo(repo: &str) -> bool {
    !repo.is_empty()
        && repo.len() < 128
        && repo
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '+' | '-'))
}

fn text<'a>(value: &'a Value, keys: &[&str]) -> &'a str {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_str))
        .unwrap_or("")
        .trim()
}

fn installed_of(value: &Value) -> bool {
    let reason = text(value, &["InstallReason", "installReason"]);
    if reason.eq_ignore_ascii_case("Not Installed") {
        return false;
    }
    if !reason.is_empty() {
        return true;
    }
    value
        .get("Explicit")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn scope_of(value: &Value) -> String {
    let raw = text(value, &["Scope", "Installation", "scope", "installation"]);
    if raw.eq_ignore_ascii_case("user") {
        return "user".into();
    }
    if raw.eq_ignore_ascii_case("system") {
        return "system".into();
    }
    match value.get("User").and_then(Value::as_bool) {
        Some(true) => "user".into(),
        Some(false) => "system".into(),
        None => String::new(),
    }
}

pub fn parse_rows(value: &Value) -> Result<Vec<Row>, String> {
    let list = value
        .as_array()
        .ok_or_else(|| "Unexpected package list".to_string())?;
    let mut rows = Vec::new();
    for item in list.iter().take(30) {
        let name = text(item, &["Name", "name", "Id", "id"]).to_string();
        if !valid_name(&name) {
            continue;
        }
        rows.push(Row {
            version: text(item, &["Version", "version"]).to_string(),
            repo: text(item, &["Repository", "repository", "Remote", "remote"]).to_string(),
            description: text(item, &["Description", "description", "Summary", "summary"])
                .to_string(),
            installed: installed_of(item) || !text(item, &["NewVersion", "newVersion"]).is_empty(),
            scope: scope_of(item),
            new_version: text(item, &["NewVersion", "newVersion"]).to_string(),
            name,
        });
    }
    Ok(rows)
}

pub fn row_json(row: &Row) -> Value {
    json!({
        "name": row.name,
        "version": row.version,
        "repo": row.repo,
        "description": row.description,
        "installed": row.installed,
        "scope": row.scope,
        "newVersion": row.new_version,
    })
}

pub fn search_argv(program: &str, source: &str, query: &str) -> Result<Vec<String>, String> {
    if !valid_query(query) {
        return Err("Query is too short".into());
    }
    let query = query.trim();
    let mut argv = vec![program.to_string(), "search".into(), source.into()];
    match source {
        "standard" | "flatpak" => argv.extend(["-j", "-n", "-t", "30"].map(str::to_string)),
        "aur" => argv.extend(["-j", "-n"].map(str::to_string)),
        _ => return Err("Unknown source".into()),
    }
    argv.push("--".into());
    argv.push(query.to_string());
    Ok(argv)
}

pub fn updates_argv(program: &str, source: &str) -> Result<Vec<String>, String> {
    if !matches!(source, "standard" | "flatpak" | "appimage" | "aur") {
        return Err("Unknown source".into());
    }
    Ok(vec![
        program.into(),
        "list-updates".into(),
        source.into(),
        "-j".into(),
        "-n".into(),
    ])
}

pub fn list_appimage_argv(program: &str) -> Vec<String> {
    vec![
        program.into(),
        "list".into(),
        "appimage".into(),
        "-j".into(),
        "-n".into(),
    ]
}

fn push_name(argv: &mut Vec<String>, name: &str) -> Result<(), String> {
    if !valid_name(name) {
        return Err(if name.is_empty() {
            "Name is empty".into()
        } else {
            "Name is not allowed".into()
        });
    }
    argv.push("--".into());
    argv.push(name.to_string());
    Ok(())
}

pub fn mutation_argv(program: &str, selection: &Selection) -> Result<Vec<String>, String> {
    if selection.source == "aur" {
        return Err("AUR builds are not started from this window".into());
    }
    let mut argv = vec![program.to_string()];
    match (selection.action.as_str(), selection.source.as_str()) {
        ("install", "standard") => {
            argv.extend(["install", "standard", "--upgrade", "--needed", "-n"].map(str::to_string));
            push_name(&mut argv, &selection.name)?;
        }
        ("remove", "standard") => {
            argv.extend(["remove", "standard", "--no-cascade", "-n"].map(str::to_string));
            push_name(&mut argv, &selection.name)?;
        }
        ("upgrade", "standard") => {
            if !selection.name.is_empty() {
                return Err("Name is not allowed".into());
            }
            argv.extend(["upgrade", "standard", "-n"].map(str::to_string));
        }
        ("install", "flatpak") | ("remove", "flatpak") => {
            let scope = match selection.scope.as_str() {
                "user" => "--user",
                "system" => "--system",
                _ => return Err("Installation is unknown".into()),
            };
            argv.extend(
                [
                    if selection.action == "install" {
                        "install"
                    } else {
                        "remove"
                    },
                    "flatpak",
                    scope,
                    "-n",
                ]
                .map(str::to_string),
            );
            push_name(&mut argv, &selection.name)?;
        }
        ("update", "flatpak") => {
            argv.extend(["update", "flatpak", "-n"].map(str::to_string));
            push_name(&mut argv, &selection.name)?;
        }
        ("upgrade", "appimage") => {
            if !selection.name.is_empty() {
                return Err("Name is not allowed".into());
            }
            argv.extend(["upgrade", "appimage", "-n"].map(str::to_string));
        }
        ("remove", "appimage") => {
            argv.extend(["remove", "appimage", "-n"].map(str::to_string));
            push_name(&mut argv, &selection.name)?;
        }
        ("install", "aur") | ("upgrade", "aur") | ("update", "aur") | ("remove", "aur") => {
            return Err("AUR builds are not started from this window".into());
        }
        ("update", "standard") => return Err("Unknown source".into()),
        _ => return Err("Unknown source".into()),
    }
    Ok(argv)
}

pub fn needs_recheck(selection: &Selection) -> bool {
    !matches!(
        (selection.action.as_str(), selection.source.as_str()),
        ("upgrade", "standard") | ("upgrade", "appimage")
    )
}

pub fn recheck_argv(program: &str, selection: &Selection) -> Result<Vec<String>, String> {
    if !needs_recheck(selection) {
        return Err("Source changed".into());
    }
    if selection.source == "appimage" {
        push_name(&mut Vec::new(), &selection.name)?;
        return Ok(list_appimage_argv(program));
    }
    search_argv(program, &selection.source, &selection.name)
}

pub fn accept(selection: &Selection, rows: &[Row]) -> Result<(), String> {
    if !needs_recheck(selection) {
        return Ok(());
    }
    if selection.action == "install"
        && selection.source == "standard"
        && !valid_version(&selection.version)
    {
        return Err(SOURCE_CHANGED.into());
    }
    if selection.source == "standard"
        && !valid_repo(&selection.repo)
        && selection.action != "upgrade"
    {
        return Err(SOURCE_CHANGED.into());
    }
    let row = rows
        .iter()
        .find(|row| row.name == selection.name)
        .ok_or_else(|| SOURCE_CHANGED.to_string())?;
    if !selection.version.is_empty() && !row.version.is_empty() && row.version != selection.version
    {
        return Err(SOURCE_CHANGED.into());
    }
    if selection.source == "standard" && row.repo != selection.repo {
        return Err(SOURCE_CHANGED.into());
    }
    if !selection.repo.is_empty() && !row.repo.is_empty() && row.repo != selection.repo {
        return Err(SOURCE_CHANGED.into());
    }
    if matches!(selection.action.as_str(), "install" | "remove") && selection.source == "flatpak" {
        if selection.scope.is_empty() || row.scope != selection.scope {
            return Err(SOURCE_CHANGED.into());
        }
    }
    if selection.action == "remove" && !row.installed && selection.source != "appimage" {
        return Err(SOURCE_CHANGED.into());
    }
    if selection.action == "install" && row.installed && selection.source == "flatpak" {
        return Err(SOURCE_CHANGED.into());
    }
    Ok(())
}

pub fn selection_from(data: &Value) -> Result<Selection, String> {
    Ok(Selection {
        action: data
            .get("action")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        source: data
            .get("source")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        name: data
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        version: data
            .get("version")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        repo: data
            .get("repo")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        scope: data
            .get("scope")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn firefox() -> Value {
        json!([{
            "Name": "firefox",
            "Version": "160.0.1-1.1",
            "Description": "Fast, Private & Safe Web Browser",
            "Repository": "cachyos-extra-v3",
            "InstallReason": "Not Installed"
        }])
    }

    fn selection(action: &str, source: &str, name: &str) -> Selection {
        Selection {
            action: action.into(),
            source: source.into(),
            name: name.into(),
            version: "160.0.1-1.1".into(),
            repo: "cachyos-extra-v3".into(),
            scope: String::new(),
        }
    }

    #[test]
    fn recorded_search_keeps_the_known_fields() {
        let rows = parse_rows(&firefox()).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].name, "firefox");
        assert_eq!(rows[0].version, "160.0.1-1.1");
        assert_eq!(rows[0].repo, "cachyos-extra-v3");
        assert!(!rows[0].installed);
    }

    #[test]
    fn names_that_look_like_flags_are_refused() {
        assert!(mutation_argv("shelly", &selection("install", "standard", "-Syu")).is_err());
        assert!(mutation_argv("shelly", &selection("install", "standard", "")).is_err());
        assert!(mutation_argv("shelly", &selection("remove", "standard", "has space")).is_err());
        assert!(mutation_argv("shelly", &selection("install", "standard", "a..b")).is_err());
    }

    #[test]
    fn search_and_update_commands_are_fixed() {
        assert_eq!(
            search_argv("shelly", "standard", "firefox").unwrap(),
            ["shelly", "search", "standard", "-j", "-n", "-t", "30", "--", "firefox"]
        );
        assert_eq!(
            search_argv("shelly", "flatpak", "firefox").unwrap(),
            ["shelly", "search", "flatpak", "-j", "-n", "-t", "30", "--", "firefox"]
        );
        assert_eq!(
            search_argv("shelly", "aur", "firefox").unwrap(),
            ["shelly", "search", "aur", "-j", "-n", "--", "firefox"]
        );
        assert!(search_argv("shelly", "standard", "f").is_err());
        assert!(search_argv("shelly", "appimage", "firefox").is_err());
        for source in ["standard", "flatpak", "appimage", "aur"] {
            assert_eq!(
                updates_argv("shelly", source).unwrap(),
                ["shelly", "list-updates", source, "-j", "-n"]
            );
        }
    }

    #[test]
    fn mutation_commands_match_the_allowlist() {
        assert_eq!(
            mutation_argv("shelly", &selection("install", "standard", "firefox")).unwrap(),
            [
                "shelly",
                "install",
                "standard",
                "--upgrade",
                "--needed",
                "-n",
                "--",
                "firefox"
            ]
        );
        assert_eq!(
            mutation_argv("shelly", &selection("remove", "standard", "firefox")).unwrap(),
            [
                "shelly",
                "remove",
                "standard",
                "--no-cascade",
                "-n",
                "--",
                "firefox"
            ]
        );
        let system = Selection {
            action: "upgrade".into(),
            source: "standard".into(),
            name: String::new(),
            version: String::new(),
            repo: String::new(),
            scope: String::new(),
        };
        assert_eq!(
            mutation_argv("shelly", &system).unwrap(),
            ["shelly", "upgrade", "standard", "-n"]
        );
        let mut flatpak = selection("install", "flatpak", "org.mozilla.firefox");
        flatpak.scope = "user".into();
        assert_eq!(
            mutation_argv("shelly", &flatpak).unwrap(),
            [
                "shelly",
                "install",
                "flatpak",
                "--user",
                "-n",
                "--",
                "org.mozilla.firefox"
            ]
        );
        flatpak.action = "update".into();
        assert_eq!(
            mutation_argv("shelly", &flatpak).unwrap(),
            [
                "shelly",
                "update",
                "flatpak",
                "-n",
                "--",
                "org.mozilla.firefox"
            ]
        );
        flatpak.scope = String::new();
        flatpak.action = "install".into();
        assert!(mutation_argv("shelly", &flatpak).is_err());
        let images = Selection {
            action: "upgrade".into(),
            source: "appimage".into(),
            name: String::new(),
            version: String::new(),
            repo: String::new(),
            scope: String::new(),
        };
        assert_eq!(
            mutation_argv("shelly", &images).unwrap(),
            ["shelly", "upgrade", "appimage", "-n"]
        );
        assert_eq!(
            mutation_argv("shelly", &selection("remove", "appimage", "App.AppImage")).unwrap(),
            ["shelly", "remove", "appimage", "-n", "--", "App.AppImage"]
        );
    }

    #[test]
    fn aur_install_is_refused() {
        let error = mutation_argv("shelly", &selection("install", "aur", "yay")).unwrap_err();
        assert!(error.contains("AUR"));
        assert!(mutation_argv("shelly", &selection("update", "standard", "firefox")).is_err());
    }

    #[test]
    fn a_changed_version_does_not_run() {
        let rows = parse_rows(&firefox()).unwrap();
        let mut picked = selection("install", "standard", "firefox");
        assert!(accept(&picked, &rows).is_ok());
        picked.version = "1.0-1".into();
        assert_eq!(accept(&picked, &rows).unwrap_err(), SOURCE_CHANGED);
        picked.version = "160.0.1-1.1".into();
        picked.repo = "extra".into();
        assert_eq!(accept(&picked, &rows).unwrap_err(), SOURCE_CHANGED);
    }
}
