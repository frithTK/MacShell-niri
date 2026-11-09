use regex::{Captures, Regex};
use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

fn copy_follow(source: &Path, destination: &Path, ancestors: &mut Vec<PathBuf>) -> io::Result<()> {
    let canonical = fs::canonicalize(source)?;
    let metadata = fs::metadata(source)?;
    if metadata.is_dir() {
        if ancestors.contains(&canonical) {
            return Err(io::Error::other("cycle in niri configuration"));
        }
        ancestors.push(canonical);
        fs::create_dir(destination)?;
        for entry in fs::read_dir(source)? {
            let entry = entry?;
            copy_follow(
                &entry.path(),
                &destination.join(entry.file_name()),
                ancestors,
            )?;
        }
        ancestors.pop();
    } else if metadata.is_file() {
        fs::copy(source, destination)?;
    } else {
        return Err(io::Error::other("unsupported niri configuration file"));
    }
    Ok(())
}

fn kdl_files(path: &Path, output: &mut Vec<PathBuf>) -> io::Result<()> {
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let metadata = entry.file_type()?;
        if metadata.is_dir() {
            kdl_files(&entry.path(), output)?;
        } else if metadata.is_file() && entry.path().extension().is_some_and(|x| x == "kdl") {
            output.push(entry.path());
        }
    }
    Ok(())
}

pub(crate) fn shell_quote(s: &str) -> String {
    if !s.is_empty()
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"_@%+=:,./-".contains(&c))
    {
        s.into()
    } else {
        format!("'{}'", s.replace('\'', "'\"'\"'"))
    }
}

fn json_string(s: &str) -> String {
    serde_json::to_string(s).expect("string serialization")
}

pub fn prepare(
    niri: &Path,
    profile: &Path,
    launcher: &Path,
    template: &Path,
    destination: &Path,
) -> io::Result<bool> {
    let original = fs::read_to_string(niri)?;
    let source = if original.starts_with("// Original config snapshot:") {
        profile.join("niri")
    } else {
        niri.parent()
            .ok_or_else(|| io::Error::other("niri path has no parent"))?
            .to_owned()
    };
    copy_follow(&source, destination, &mut Vec::new())?;
    let mut files = Vec::new();
    kdl_files(destination, &mut files)?;
    let mut previous_shell = false;
    for file in &files {
        previous_shell |= fs::read_to_string(file)?.contains("qs -c noctalia-shell");
    }
    let input = match fs::read_to_string(destination.join("macshell-input.kdl")) {
        Ok(value) => value,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            "// Input preferences remain unchanged until edited in MacShell.\n".into()
        }
        Err(error) => return Err(error),
    };
    for name in ["macshell.kdl", "macshell-input.kdl"] {
        match fs::remove_file(destination.join(name)) {
            Ok(()) => (),
            Err(e) if e.kind() == io::ErrorKind::NotFound => (),
            Err(e) => return Err(e),
        }
    }
    files.clear();
    kdl_files(destination, &mut files)?;
    let launcher = launcher
        .to_str()
        .ok_or_else(|| io::Error::other("launcher path must be UTF-8"))?;
    let quoted = json_string(&shell_quote(launcher));
    let escaped_launcher = &quoted[1..quoted.len() - 1];
    let ipc =
        Regex::new(r"qs\s+-c\s+noctalia-shell\s+ipc\s+call\s+([A-Za-z]+\s+[A-Za-z]+)").unwrap();
    let shell = Regex::new(r"qs\s+-c\s+noctalia-shell").unwrap();
    let keys_pattern = Regex::new(r"(?m)^\s*([\w+]+)\s+(?:[^\n{]*\s)?\{").unwrap();
    let binding = Regex::new(r"^\s*([\w+]+)\s+\{\s*spawn").unwrap();
    let include = Regex::new(r#"(?m)^include "\./macshell(?:-input)?\.kdl"\s*$"#).unwrap();
    let mut keys = HashSet::new();
    for file in &files {
        let content = fs::read_to_string(file)?;
        let content = ipc.replace_all(&content, |c: &Captures<'_>| {
            let mapped = match &c[1] {
                "launcher toggle" => "spotlight toggle",
                "lockScreen lock" => "session lock",
                "sessionMenu toggle" => "session menu",
                "media prev" => "media previous",
                v => v,
            };
            format!("{escaped_launcher} ipc call {mapped}")
        });
        let mut replaced = String::new();
        let mut end = 0;
        for matched in shell.find_iter(&content) {
            let boundary = content[matched.end()..].chars().next();
            if boundary.is_some_and(|ch| ch != '"' && !ch.is_whitespace()) {
                continue;
            }
            replaced.push_str(&content[end..matched.start()]);
            replaced.push_str(escaped_launcher);
            end = matched.end();
        }
        replaced.push_str(&content[end..]);
        let content = replaced;
        for capture in keys_pattern.captures_iter(&content) {
            let key = &capture[1];
            if key.contains('+') || key == "Print" {
                keys.insert(key.to_lowercase());
            }
        }
        fs::write(file, content.as_bytes())?;
    }
    let mut bindings = Vec::new();
    for line in fs::read_to_string(template)?.lines() {
        if binding
            .captures(line)
            .is_some_and(|c| keys.contains(&c[1].to_lowercase()))
        {
            continue;
        }
        bindings.push(line.to_owned());
    }
    fs::write(
        destination.join("macshell.kdl"),
        format!(
            "{}\n",
            bindings
                .join("\n")
                .replace("\"qs\" \"-c\" \"MacShell-niri\"", &json_string(launcher))
        ),
    )?;
    fs::write(destination.join("macshell-input.kdl"), input)?;
    let config = destination.join("config.kdl");
    let content = fs::read_to_string(&config)?;
    let mut content = format!(
        "{}\ninclude \"./macshell.kdl\"\ninclude \"./macshell-input.kdl\"\n",
        include.replace_all(&content, "")
    );
    files.clear();
    kdl_files(destination, &mut files)?;
    let has_launcher = files.iter().try_fold(false, |found, f| {
        fs::read_to_string(f).map(|text| found || text.contains(launcher))
    })?;
    if !has_launcher {
        content.push_str(&format!("spawn-at-startup {}\n", json_string(launcher)));
    }
    fs::write(&config, content)?;
    let result = Command::new("niri")
        .arg("validate")
        .arg("-c")
        .arg(&config)
        .output()?;
    if !result.status.success() {
        return Err(io::Error::other(format!(
            "niri validation failed: {}",
            String::from_utf8_lossy(&result.stderr)
        )));
    }
    Ok(previous_shell)
}
