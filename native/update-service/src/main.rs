//! On-demand release and Arch package checks for MacShell.
//!
//! This intentionally remains a short-lived CLI: it reports and prepares an
//! update, but never installs MacShell without an explicit user action.
use serde_json::{json, Value};
use std::env;
use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

const REPOSITORY: &str = "frithTK/MacShell-niri";
const PROTOCOL: &str = "macshell-update-service 1";

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct Version(u64, u64, u64);

fn invalid(name: &str) -> String {
    name.to_owned()
}

fn parse_version(value: &str) -> Result<Version, String> {
    let value = value.strip_prefix('v').unwrap_or(value);
    let mut parts = value.split('.');
    let parsed = [parts.next(), parts.next(), parts.next()]
        .into_iter()
        .map(|part| {
            part.ok_or_else(|| invalid("invalid_version"))?
                .parse::<u64>()
                .map_err(|_| invalid("invalid_version"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    if parts.next().is_some()
        || parsed.len() != 3
        || parsed
            .iter()
            .any(|part| part.to_string().len() > 1 && part.to_string().starts_with('0'))
    {
        return Err(invalid("invalid_version"));
    }
    Ok(Version(parsed[0], parsed[1], parsed[2]))
}

fn stable_tag(value: &str) -> Result<Version, String> {
    if !value.starts_with('v') || value[1..].contains('-') || value[1..].contains('/') {
        return Err(invalid("invalid_release"));
    }
    parse_version(value)
}

fn command(name: &str) -> PathBuf {
    if let Some(path) = env::var_os("MACSHELL_TEST_BIN_DIR")
        .map(PathBuf::from)
        .map(|dir| dir.join(name))
        .filter(|path| path.is_file())
    {
        return path;
    }
    if let Some(path) = env::var_os("PATH").and_then(|value| {
        value
            .to_string_lossy()
            .split(':')
            .map(Path::new)
            .map(|dir| dir.join(name))
            .find(|path| path.is_file())
    }) {
        return path;
    }
    PathBuf::from(name)
}

fn available(name: &str) -> bool {
    let path = command(name);
    path.is_file() || (env::var_os("PATH").is_some() && Command::new(&path).output().is_ok())
}

fn run(program: &str, args: &[&str], timeout: u64) -> Result<std::process::Output, String> {
    let mut process = Command::new(command(program));
    process
        .args(args)
        .stdin(Stdio::null())
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GH_PROMPT_DISABLED", "1")
        .env("LC_ALL", "C");
    let output = process.output().map_err(|_| invalid("operation_failed"))?;
    let _ = timeout;
    Ok(output)
}

fn installed_version() -> Result<String, String> {
    if let Some(path) = env::var_os("MACSHELL_UPDATE_VERSION_FILE") {
        let value = fs::read_to_string(path).map_err(|_| invalid("version_unknown"))?;
        let value = value.trim().to_owned();
        parse_version(&value)?;
        return Ok(value.trim_start_matches('v').to_owned());
    }
    let executable = env::current_exe().map_err(|_| invalid("version_unknown"))?;
    let candidates = [
        executable
            .parent()
            .unwrap_or(Path::new("."))
            .join("VERSION"),
        PathBuf::from("VERSION"),
    ];
    for path in candidates {
        if let Ok(value) = fs::read_to_string(path) {
            let value = value.trim().to_owned();
            parse_version(&value)?;
            return Ok(value.trim_start_matches('v').to_owned());
        }
    }
    Err(invalid("version_unknown"))
}

fn release_url() -> String {
    env::var("MACSHELL_UPDATE_API_URL")
        .unwrap_or_else(|_| format!("https://api.github.com/repos/{REPOSITORY}/releases/latest"))
}

fn remote_url() -> String {
    env::var("MACSHELL_UPDATE_REMOTE")
        .unwrap_or_else(|_| "https://github.com/frithTK/MacShell-niri.git".into())
}

fn latest_release() -> Result<String, String> {
    let url = release_url();
    if !available("curl") {
        return Err(invalid("release_unavailable"));
    }
    let output = run("curl", &["-fsSL", "--max-time", "20", &url], 20)?;
    let payload: Value =
        serde_json::from_slice(&output.stdout).map_err(|_| invalid("invalid_release"))?;
    let tag = payload
        .get("tag_name")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("invalid_release"))?;
    if payload
        .get("draft")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        || payload
            .get("prerelease")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        return Err(invalid("invalid_release"));
    }
    stable_tag(tag).map_err(|_| invalid("invalid_release"))?;
    Ok(tag.to_owned())
}

fn check_release() -> Value {
    let installed = installed_version().unwrap_or_default();
    match (parse_version(&installed), latest_release()) {
        (Ok(current), Ok(tag)) => {
            let latest = stable_tag(&tag).expect("validated tag");
            let state = if latest > current {
                "available"
            } else if latest < current {
                "ahead"
            } else {
                "current"
            };
            json!({"state":state,"installed":installed,"latest":tag.trim_start_matches('v'),"tag":tag})
        }
        _ => json!({"state":"error","installed":installed,"error":"release_unavailable"}),
    }
}

fn check_packages() -> Value {
    if !available("checkupdates") || !available("pacman") {
        return json!({"state":"unsupported"});
    }
    match run("checkupdates", &[], 150) {
        Ok(output) if output.status.code() == Some(2) => {
            json!({"state":"current","count":0,"packages":[]})
        }
        Ok(output) if output.status.success() => {
            let stdout = String::from_utf8_lossy(&output.stdout);
            let lines = stdout
                .lines()
                .map(str::trim)
                .filter(|line| !line.is_empty())
                .collect::<Vec<_>>();
            if lines.iter().any(|line| !line.contains(" -> ")) {
                return json!({"state":"error","error":"package_check_failed"});
            }
            json!({"state":if lines.is_empty(){"current"}else{"available"},"count":lines.len(),"packages":lines.into_iter().take(200).collect::<Vec<_>>()})
        }
        _ => json!({"state":"error","error":"package_check_failed"}),
    }
}

fn data_directory() -> Result<PathBuf, String> {
    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| invalid("operation_failed"))?;
    Ok(env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".local/share"))
        .join("macshell-niri/updates"))
}

fn latest_again(expected: &str) -> Result<(), String> {
    if latest_release()? == expected {
        Ok(())
    } else {
        Err(invalid("release_changed"))
    }
}

fn prepare(tag: &str) -> Result<Value, String> {
    let expected = stable_tag(tag)?;
    let installed = parse_version(&installed_version()?)?;
    if expected <= installed {
        return Err(invalid("invalid_release"));
    }
    latest_again(tag)?;
    if !available("git") {
        return Err(invalid("git_missing"));
    }
    let base = data_directory()?;
    fs::create_dir_all(&base).map_err(|_| invalid("unsafe_directory"))?;
    if base.is_symlink() || !base.is_dir() {
        return Err(invalid("unsafe_directory"));
    }
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| invalid("operation_failed"))?
        .as_nanos();
    let temporary = base.join(format!(".download-{unique}"));
    fs::create_dir(&temporary).map_err(|_| invalid("download_failed"))?;
    let checkout = temporary.join("checkout");
    let tag_arg = tag;
    let result = run(
        "git",
        &[
            "-c",
            "core.hooksPath=/dev/null",
            "clone",
            "--quiet",
            "--depth=1",
            "--single-branch",
            "--branch",
            tag_arg,
            "--",
            &remote_url(),
            checkout
                .to_str()
                .ok_or_else(|| invalid("download_failed"))?,
        ],
        300,
    )?;
    if !result.status.success() {
        let _ = fs::remove_dir_all(&temporary);
        return Err(invalid("download_failed"));
    }
    let head = run(
        "git",
        &[
            "-C",
            checkout.to_str().unwrap_or_default(),
            "rev-parse",
            "HEAD",
        ],
        10,
    )?;
    let tagged = run(
        "git",
        &[
            "-C",
            checkout.to_str().unwrap_or_default(),
            "rev-parse",
            &format!("refs/tags/{tag}^{{commit}}"),
        ],
        10,
    )?;
    let version =
        fs::read_to_string(checkout.join("VERSION")).map_err(|_| invalid("release_mismatch"))?;
    if !head.status.success()
        || !tagged.status.success()
        || head.stdout != tagged.stdout
        || parse_version(version.trim()).ok() != Some(expected)
    {
        let _ = fs::remove_dir_all(&temporary);
        return Err(invalid("release_mismatch"));
    }
    if !checkout.join("install.sh").is_file() || checkout.join("install.sh").is_symlink() {
        let _ = fs::remove_dir_all(&temporary);
        return Err(invalid("release_mismatch"));
    }
    latest_again(tag)?;
    let destination = base.join(format!("{tag}-{unique}"));
    fs::rename(&checkout, &destination).map_err(|_| invalid("download_failed"))?;
    let _ = fs::remove_dir_all(&temporary);
    let command = format!("bash {}", shell_quote(&destination.join("install.sh")));
    let info = json!({"tag":tag,"command":command});
    let state = base.join("prepared.json");
    if state.is_symlink() {
        return Err(invalid("unsafe_directory"));
    }
    let temporary_state = base.join(format!(".prepared-{unique}"));
    let mut file = File::create(&temporary_state).map_err(|_| invalid("unsafe_directory"))?;
    serde_json::to_writer(&mut file, &info).map_err(|_| invalid("unsafe_directory"))?;
    file.sync_all().map_err(|_| invalid("unsafe_directory"))?;
    fs::rename(temporary_state, state).map_err(|_| invalid("unsafe_directory"))?;
    Ok(info)
}

fn shell_quote(path: &Path) -> String {
    format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"))
}

fn prepared() -> Value {
    let Ok(base) = data_directory() else {
        return Value::Null;
    };
    let state = base.join("prepared.json");
    let Ok(text) = fs::read_to_string(&state) else {
        return Value::Null;
    };
    let Ok(info) = serde_json::from_str::<Value>(&text) else {
        return Value::Null;
    };
    let Some(tag) = info.get("tag").and_then(Value::as_str) else {
        return Value::Null;
    };
    let Some(command) = info.get("command").and_then(Value::as_str) else {
        return Value::Null;
    };
    let Ok(version) = parse_version(&tag[1..]) else {
        return Value::Null;
    };
    let Ok(installed) = installed_version().and_then(|v| parse_version(&v)) else {
        return Value::Null;
    };
    let Some(path) = command
        .strip_prefix("bash '")
        .and_then(|v| v.strip_suffix("/install.sh'"))
    else {
        return Value::Null;
    };
    let path = PathBuf::from(path.replace("'\\''", "'"));
    if version <= installed
        || path.parent() != Some(base.as_path())
        || path.is_symlink()
        || !path.join("install.sh").is_file()
    {
        return Value::Null;
    }
    json!({"tag":tag,"command":command})
}

fn launch_packages() -> Result<(), String> {
    let kitty = command("kitty");
    let sudo = command("sudo");
    let pacman = command("pacman");
    if !available("kitty") || !available("sudo") || !available("pacman") {
        return Err(invalid("terminal_unavailable"));
    }
    Command::new(kitty)
        .args(["--hold", "-e"])
        .arg(sudo)
        .arg(pacman)
        .arg("-Syu")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| invalid("terminal_unavailable"))?;
    Ok(())
}

fn main() {
    let mut args = env::args().skip(1);
    if args.next().as_deref() == Some("--protocol-version") {
        println!("{PROTOCOL}");
        return;
    }
    let action = env::args().nth(1).unwrap_or_else(|| "status".into());
    let result = match action.as_str() {
        "status" => Ok(
            json!({"release":check_release(),"packages":check_packages(),"prepared":prepared(),"clipboard":available("wl-copy")}),
        ),
        "prepare" => args
            .next()
            .map(|tag| prepare(&tag))
            .unwrap_or_else(|| Err(invalid("invalid_request"))),
        "install-packages" => launch_packages().map(|_| json!({"launched":true})),
        _ => Err(invalid("invalid_request")),
    };
    match result {
        Ok(value) => {
            if action == "prepare" {
                println!("{}", json!({"prepared":value}));
            } else {
                println!("{value}");
            }
        }
        Err(error) => {
            println!("{}", json!({"error":error}));
            std::process::exit(1);
        }
    }
}
