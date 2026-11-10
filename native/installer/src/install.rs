use crate::{build, guard, niri, session};
use serde_json::Value;
use std::env;
use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

struct Temp(PathBuf);
impl Temp {
    fn new() -> io::Result<Self> {
        use std::os::unix::fs::DirBuilderExt;
        let mut bytes = [0u8; 16];
        use std::io::Read;
        fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
        let name: String = bytes.iter().map(|v| format!("{v:02x}")).collect();
        let path = env::temp_dir().join(format!("macshell-install-{name}"));
        fs::DirBuilder::new().mode(0o700).create(&path)?;
        Ok(Self(path))
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

pub struct Paths {
    pub source: PathBuf,
    pub config: PathBuf,
    pub cache: PathBuf,
    pub data: PathBuf,
    pub bin: PathBuf,
    pub qs: PathBuf,
}

pub fn runtime_check(p: &Paths, preflight: &Path) -> io::Result<()> {
    for program in ["niri", "systemctl", "systemd-run", "flock", "timeout"] {
        if !available(program) {
            return Err(io::Error::other(format!(
                "Missing required program: {program}"
            )));
        }
    }
    let output = Command::new("timeout")
        .arg("15")
        .arg(preflight)
        .arg("--runtime")
        .arg(&p.qs)
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "Quickshell runtime check failed: {}",
            String::from_utf8_lossy(&output.stderr)
        )));
    }
    Ok(())
}

fn available(name: &str) -> bool {
    let path = Path::new(name);
    let executable = |p: &Path| {
        fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    };
    if path.components().count() > 1 {
        return executable(path);
    }
    env::split_paths(&env::var_os("PATH").unwrap_or_default()).any(|p| executable(&p.join(name)))
}

pub fn doctor(p: &Paths) -> bool {
    let mut ok = true;
    for program in [
        "cargo",
        "niri",
        "systemctl",
        "systemd-run",
        "flock",
        "timeout",
    ] {
        let present = available(program);
        println!(
            "{}: {program}",
            if present { "OK" } else { "ERROR: missing" }
        );
        ok &= present;
    }
    let present = available(p.qs.to_str().unwrap_or(""));
    println!(
        "{}: Quickshell",
        if present { "OK" } else { "ERROR: missing" }
    );
    ok &= present;
    let runtime = Temp::new().and_then(|temp| {
        let manifest = p.source.join("native/session-preflight/Cargo.toml");
        let output = Command::new("timeout")
            .args([
                "300",
                "cargo",
                "build",
                "--release",
                "--locked",
                "--offline",
                "--manifest-path",
            ])
            .arg(manifest)
            .arg("--target-dir")
            .arg(&temp.0)
            .output()?;
        if !output.status.success() {
            return Err(io::Error::other("could not build session preflight"));
        }
        runtime_check(p, &temp.0.join("release/macshell-session-preflight"))
    });
    match runtime {
        Ok(()) => println!("OK: Quickshell runtime"),
        Err(error) => {
            println!("ERROR: Quickshell runtime: {error}");
            ok = false;
        }
    }
    for program in [
        "jq",
        "grim",
        "wl-copy",
        "wl-paste",
        "wtype",
        "brightnessctl",
        "nmcli",
        "wlsunset",
        "wf-recorder",
        "slurp",
        "pw-dump",
        "pw-loopback",
        "ffprobe",
        "cliphist",
        "mpvpaper",
        "doubletake",
        "uxplay",
    ] {
        let present = available(program) || p.data.join("runtime/bin").join(program).is_file();
        println!(
            "{}: {program}",
            if present { "OK" } else { "OPTIONAL MISSING" }
        );
    }
    let qsb = available("qsb") || Path::new("/usr/lib/qt6/bin/qsb").is_file();
    println!(
        "{}: qt6-shadertools",
        if qsb { "OK" } else { "ERROR: missing" }
    );
    ok &= qsb;
    for plugin in [
        "pipewiresrc",
        "capssetter",
        "videoscale",
        "videoconvert",
        "appsink",
        "appsrc",
        "pngenc",
    ] {
        let found = Command::new("timeout")
            .args(["5", "gst-inspect-1.0", plugin])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
        if !found {
            println!("ERROR: missing GStreamer element: {plugin}");
            ok = false;
        }
    }
    ok
}
impl Paths {
    fn profile(&self) -> PathBuf {
        self.config.join("macshell-niri")
    }
    fn shell(&self) -> PathBuf {
        self.config.join("quickshell/MacShell-niri")
    }
    fn lock(&self) -> PathBuf {
        self.config.join("quickshell/MacLock-niri")
    }
    fn niri(&self) -> PathBuf {
        self.config.join("niri/config.kdl")
    }
}

fn copy_sources(source: &Path, destination: &Path) -> io::Result<()> {
    fs::create_dir(destination)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let excluded_recording = source.ends_with("MacShell/sounds")
            && matches!(name.as_ref(), "apple" | "alarm.wav" | "timer.wav");
        if name == "__pycache__"
            || name.ends_with(".py")
            || name.ends_with(".pyc")
            || name.ends_with("-rust")
            || excluded_recording
        {
            continue;
        }
        let path = entry.path();
        let target = destination.join(entry.file_name());
        if fs::metadata(&path)?.is_dir() {
            copy_sources(&path, &target)?;
        } else if path.extension().is_some_and(|ext| ext == "sh") {
            let script = fs::read_to_string(&path)?;
            let installed = if script.contains("exec python3 ") {
                let marker = script.find(".macshell-rust-only").ok_or_else(|| {
                    io::Error::other(format!("missing legacy policy in {}", path.display()))
                })?;
                let line = script[..marker].rfind('\n').map_or(0, |i| i + 1);
                if !script[marker..].contains("exec python3 ") {
                    return Err(io::Error::other(format!(
                        "invalid legacy policy in {}",
                        path.display()
                    )));
                }
                let prefix = script[..line]
                    .replace(
                        "Rust bridge unavailable or incompatible; using Python bridge",
                        "Rust bridge unavailable or incompatible",
                    )
                    .replace("    python) ;;\n", "");
                format!("{prefix}echo 'Rust helper is missing, incompatible, or disabled' >&2\nexit 1\n")
            } else {
                script
            };
            if installed.to_ascii_lowercase().contains("python") {
                return Err(io::Error::other(format!(
                    "Python reference in Rust-only shell script {}",
                    path.display()
                )));
            }
            fs::write(&target, installed)?;
            fs::set_permissions(&target, fs::metadata(&path)?.permissions())?;
        } else {
            fs::copy(path, target)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod source_tests {
    use super::*;

    #[test]
    fn rejects_python_invocations_outside_legacy_fallback() {
        let root = std::env::temp_dir().join(format!(
            "macshell-copy-sources-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let source = root.join("source");
        fs::create_dir_all(&source).unwrap();
        for (index, script) in [
            "#!/bin/sh\npython3 helper.py\n",
            "#!/bin/sh\npython3 helper.py\n# .macshell-rust-only\nexec python3 legacy.py\n",
        ]
        .iter()
        .enumerate()
        {
            fs::write(source.join("service.sh"), script).unwrap();
            let error =
                copy_sources(&source, &root.join(format!("installed-{index}"))).unwrap_err();
            assert!(error.to_string().contains("Python reference"));
        }
        fs::remove_dir_all(root).unwrap();
    }
}

const ARTIFACTS: &[(&str, &str)] = &[
    ("macshell-niri-bridge", "niri-bridge-rust"),
    ("macshell-boot-clock", "boot-clock-rust"),
    ("macshell-system-stats", "system-stats-rust"),
    ("macshell-night-shift", "night-shift-rust"),
    ("macshell-timed-modes", "timed-modes-rust"),
    ("macshell-activity-preferences", "activity-preferences-rust"),
    ("macshell-bar-preferences", "bar-preferences-rust"),
    ("macshell-widget-preferences", "widget-preferences-rust"),
    ("macshell-locale-preferences", "locale-preferences-rust"),
    ("macshell-native-blur", "native-blur-rust"),
    ("macshell-session-preflight", "session-preflight-rust"),
    ("macshell-power-profiles", "power-profiles-rust"),
    ("macshell-niri-color", "niri-color-rust"),
    ("macshell-bluetooth", "bluetooth-service-rust"),
    ("macshell-capture-experimental", "capture-service-rust"),
    ("macshell-recording-experimental", "recording-service-rust"),
    ("macshell-network", "network-service-rust"),
    ("macshell-niri-input", "niri-input-rust"),
    ("macshell-session-service", "session-service-rust"),
    ("macshell-currency-fetch", "currency-fetch-rust"),
    ("macshell-widget-fetch", "widget-fetch-rust"),
    ("macshell-wallpaper-discovery", "wallpaper-discovery-rust"),
    ("macshell-notes-service", "notes-service-rust"),
    ("macshell-calendar-service", "calendar-service-rust"),
    ("macshell-reminders-service", "reminders-service-rust"),
    ("clock-service-prototype", "clock-service-prototype-rust"),
    ("clock-audio-worker", "clock-audio-worker-rust"),
    ("clock-sound-import", "clock-sound-import-rust"),
    ("macshell-screen-mirroring", "screen-mirroring-service-rust"),
    ("macshell-airdrop-service", "airdrop-service-rust"),
    ("macshell-biometric-probe", "biometric-probe-rust"),
    ("fingerprint-operation", "fingerprint-operation-rust"),
    ("macshell-update-service", "update-service-rust"),
    ("macshell-desktop-source", "desktop-source-rust"),
    ("macshell-preview", "preview-rust"),
];

fn artifact<'a>(artifacts: &'a Value, name: &str) -> io::Result<&'a Path> {
    artifacts
        .get(name)
        .and_then(Value::as_str)
        .map(Path::new)
        .ok_or_else(|| io::Error::other(format!("missing build artifact: {name}")))
}
pub fn dry_run(p: &Paths) -> io::Result<()> {
    let temp = Temp::new()?;
    niri::prepare(
        &p.niri(),
        &p.profile(),
        &p.bin.join("macshell-niri"),
        &p.source.join("config/macshell.kdl"),
        &temp.0.join("niri"),
    )?;
    println!("Generated niri configuration validates successfully.");
    Ok(())
}
fn deploy_binary(source: &Path, destination: &Path) -> io::Result<()> {
    crate::remove(destination)?;
    fs::copy(source, destination)?;
    fs::set_permissions(destination, fs::Permissions::from_mode(0o755))
}

fn run(program: &Path, args: &[&str]) -> io::Result<String> {
    let output = Command::new("timeout")
        .arg("5")
        .arg(program)
        .args(args)
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "{} failed: {}",
            program.display(),
            String::from_utf8_lossy(&output.stderr)
        )));
    }
    String::from_utf8(output.stdout).map_err(io::Error::other)
}

fn instances(p: &Paths, name: &str) -> io::Result<bool> {
    let output = run(&p.qs, &["-c", name, "list", "--any-display", "--json"])?;
    if output.starts_with("No running instances for \"")
        && output
            .trim_end()
            .ends_with("Use --all to list all instances.")
    {
        return Ok(false);
    }
    let value: Value = serde_json::from_str(&output).map_err(io::Error::other)?;
    Ok(!value
        .as_array()
        .ok_or_else(|| io::Error::other("Unexpected Quickshell instance list"))?
        .is_empty())
}

fn stop_shell(p: &Paths, name: &str) -> io::Result<bool> {
    if !instances(p, name)? {
        return Ok(false);
    }
    run(&p.qs, &["-c", name, "kill"])?;
    let deadline = Instant::now() + Duration::from_secs(10);
    while instances(p, name)? {
        if Instant::now() >= deadline {
            return Err(io::Error::other(format!("{name} did not stop")));
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    Ok(true)
}

fn start_previous(p: &Paths, name: Option<&str>) -> io::Result<()> {
    use std::os::unix::process::CommandExt;
    if let Some(name) = name {
        let mut command = if name == "MacShell-niri" {
            Command::new(p.bin.join("macshell-niri"))
        } else {
            let mut c = Command::new(&p.qs);
            c.args(["-c", name]);
            c
        };
        command
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()?;
    }
    Ok(())
}

fn reload_niri() -> io::Result<()> {
    run(Path::new("niri"), &["msg", "action", "load-config-file"]).map(|_| ())
}

fn start_shell(p: &Paths) -> io::Result<()> {
    use std::os::unix::process::CommandExt;
    let logs = p.data.join("logs");
    fs::create_dir_all(&logs)?;
    let log = fs::File::create(logs.join("shell.log"))?;
    let mut child = Command::new(p.bin.join("macshell-niri"))
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log)
        .process_group(0)
        .spawn()?;
    for _ in 0..30 {
        if let Ok(status) = run(
            &p.qs,
            &["-c", "MacShell-niri", "ipc", "call", "status", "state"],
        ) {
            if serde_json::from_str::<Value>(&status)
                .ok()
                .and_then(|v| v.get("connected").and_then(Value::as_bool))
                == Some(true)
            {
                return Ok(());
            }
        }
        if child.try_wait()?.is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    let _ = child.kill();
    let _ = child.wait();
    Err(io::Error::other(format!(
        "MacShell did not become ready; log: {}",
        logs.join("shell.log").display()
    )))
}

#[derive(PartialEq, Eq)]
pub enum Mode {
    Plain,
    Session,
    Activate,
}

pub fn install(p: &Paths, mode: Mode) -> io::Result<PathBuf> {
    let _guard = guard::Guard::acquire(p.qs.as_os_str())?;
    if p.niri().is_file()
        && fs::read_to_string(p.niri())?.starts_with("// Original config snapshot:")
        && mode == Mode::Plain
    {
        return Err(io::Error::other(
            "MacShell is already active; refusing to replace the active profile",
        ));
    }
    let staging = Temp::new()?;
    if !p.source.join("MacShell/Niri.qml").is_file() || !p.source.join("VERSION").is_file() {
        return Err(io::Error::other("invalid source directory"));
    }
    let artifacts = build::build(&p.source, &staging.0.join("build"))?;
    if mode != Mode::Plain {
        runtime_check(p, artifact(&artifacts, "macshell-session-preflight")?)?;
    }
    let generated = staging.0.join("niri");
    let previous_port = mode == Mode::Activate
        && p.niri().is_file()
        && fs::read_to_string(p.niri())?.starts_with("// Original config snapshot:");
    let mut previous_shell = false;
    if mode != Mode::Plain {
        previous_shell = niri::prepare(
            &p.niri(),
            &p.profile(),
            &p.bin.join("macshell-niri"),
            &p.source.join("config/macshell.kdl"),
            &generated,
        )?;
    }
    let mut targets = vec![
        p.shell(),
        p.lock(),
        p.bin.join("macshell-niri"),
        p.bin.join("maclock-niri"),
        p.profile(),
    ];
    if mode == Mode::Activate {
        targets.push(p.niri());
    }
    if mode == Mode::Session {
        targets.extend([
            p.config.join("systemd/user/niri-macshell.service"),
            p.config.join("systemd/user/macshell-niri-shell.service"),
            p.bin.join("niri-macshell-session"),
            p.data.join("session"),
        ]);
    }
    let snapshot = crate::snapshot(&p.data, &targets)?;
    let directory = PathBuf::from(
        snapshot["directory"]
            .as_str()
            .ok_or_else(|| io::Error::other("invalid snapshot"))?,
    );
    let mut manifest = snapshot["manifest"].clone();
    if mode == Mode::Activate {
        manifest["previous_shell"] = if previous_port {
            Value::from("MacShell-niri")
        } else if previous_shell {
            Value::from("noctalia-shell")
        } else {
            Value::Null
        };
    }
    let mut previous_stopped = false;
    let result = (|| -> io::Result<()> {
        if previous_port {
            previous_stopped = stop_shell(p, "MacShell-niri")?;
        }
        for (name, target) in [("MacShell", p.shell()), ("MacLock", p.lock())] {
            crate::remove(&target)?;
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)?;
            }
            copy_sources(&p.source.join(name), &target)?;
            fs::write(target.join(".macshell-rust-only"), b"1\n")?;
        }
        for (name, destination) in ARTIFACTS {
            deploy_binary(artifact(&artifacts, name)?, &p.shell().join(destination))?;
        }
        for name in ["niri-input-service.sh", "session-service.sh"] {
            fs::set_permissions(p.shell().join(name), fs::Permissions::from_mode(0o755))?;
        }
        deploy_binary(
            artifact(&artifacts, "macshell-boot-clock")?,
            &p.lock().join("boot-clock-rust"),
        )?;
        fs::copy(p.source.join("VERSION"), p.shell().join("VERSION"))?;
        fs::create_dir_all(p.profile().join("settings"))?;
        session::launchers(&p.profile(), &p.bin, &p.cache, &p.lock(), &p.qs)?;
        if mode != Mode::Plain {
            crate::remove(&p.profile().join("niri"))?;
            crate::copy_tree(&generated, &p.profile().join("niri"))?;
        }
        if mode == Mode::Session {
            session::files(session::Paths {
                source: &p.source,
                profile: &p.profile(),
                bin: &p.bin,
                data: &p.data,
                config: &p.config,
                qs: &p.qs,
                locale: artifact(&artifacts, "macshell-locale-preferences")?,
                preflight: artifact(&artifacts, "macshell-session-preflight")?,
            })?;
            fs::write(p.profile().join(".macshell-rust-only"), b"1\n")?;
            manifest["session_only"] = Value::Bool(true);
        }
        if mode == Mode::Activate {
            let wrapper = p.niri().with_extension("macshell-new.kdl");
            fs::write(
                &wrapper,
                format!(
                    "// Original config snapshot: {}\ninclude {}\n",
                    directory.display(),
                    serde_json::to_string(&p.profile().join("niri/config.kdl").to_string_lossy())?
                ),
            )?;
            if let Err(error) = run(
                Path::new("niri"),
                &[
                    "validate",
                    "-c",
                    wrapper
                        .to_str()
                        .ok_or_else(|| io::Error::other("invalid path"))?,
                ],
            ) {
                let _ = fs::remove_file(&wrapper);
                return Err(error);
            }
            let digest =
                crate::sha256(&wrapper)?.ok_or_else(|| io::Error::other("missing niri config"))?;
            fs::rename(&wrapper, p.niri())?;
            manifest["niri_digest"] = Value::from(digest);
            manifest["activated"] = Value::Bool(true);
        }
        fs::write(
            directory.join("manifest.json"),
            serde_json::to_vec_pretty(&manifest)?,
        )?;
        fs::write(
            p.data.join("latest"),
            directory.as_os_str().as_encoded_bytes(),
        )?;
        if mode == Mode::Activate {
            reload_niri()?;
            if previous_shell {
                previous_stopped = stop_shell(p, "noctalia-shell")? || previous_stopped;
            }
            if instances(p, "MacShell-niri")? {
                return Err(io::Error::other(
                    "MacShell is already running; refusing to start another instance",
                ));
            }
            start_shell(p)?;
        }
        Ok(())
    })();
    if let Err(error) = result {
        if let Err(restore) = crate::restore(&p.data, &directory, &manifest, &p.niri(), false) {
            return Err(io::Error::other(format!(
                "installation failed: {error}; restore failed: {restore}"
            )));
        }
        if mode == Mode::Session {
            let _ = std::process::Command::new("systemctl")
                .args(["--user", "daemon-reload"])
                .status();
        }
        if manifest["activated"] == true {
            let _ = reload_niri();
        }
        if previous_stopped {
            let _ = start_previous(p, manifest["previous_shell"].as_str());
        }
        return Err(error);
    }
    Ok(directory)
}

pub fn rollback(p: &Paths, force: bool) -> io::Result<PathBuf> {
    let _guard = guard::Guard::acquire(p.qs.as_os_str())?;
    let directory = PathBuf::from(fs::read_to_string(p.data.join("latest"))?.trim());
    let manifest: Value =
        serde_json::from_reader(fs::File::open(directory.join("manifest.json"))?)?;
    let active = manifest.get("activated").and_then(Value::as_bool) == Some(true);
    if let Some(expected) = manifest.get("niri_digest").and_then(Value::as_str) {
        if !force && crate::sha256(&p.niri())?.as_deref() != Some(expected) {
            return Err(io::Error::other(
                "niri config was edited; inspect the backup before forcing rollback",
            ));
        }
    }
    let stopped = if active {
        stop_shell(p, "MacShell-niri")?
    } else {
        false
    };
    if let Err(error) = crate::restore(&p.data, &directory, &manifest, &p.niri(), force) {
        if stopped {
            let _ = start_previous(p, Some("MacShell-niri"));
        }
        return Err(error);
    }
    if active {
        if let Err(error) = reload_niri()
            .and_then(|_| start_previous(p, manifest.get("previous_shell").and_then(Value::as_str)))
        {
            if stopped {
                let _ = start_previous(p, Some("MacShell-niri"));
            }
            return Err(error);
        }
    }
    if manifest.get("session_only").and_then(Value::as_bool) == Some(true) {
        let status = std::process::Command::new("systemctl")
            .args(["--user", "daemon-reload"])
            .status()?;
        if !status.success() {
            return Err(io::Error::other("systemctl daemon-reload failed"));
        }
    }
    Ok(directory)
}
