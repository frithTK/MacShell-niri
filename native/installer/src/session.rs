use crate::niri::shell_quote;
use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

fn text(path: &Path) -> io::Result<&str> {
    path.to_str()
        .ok_or_else(|| io::Error::other("non-UTF-8 path"))
}
fn quote(path: &Path) -> io::Result<String> {
    Ok(shell_quote(text(path)?))
}
fn unit(path: &Path) -> io::Result<String> {
    Ok(format!(
        "\"{}\"",
        text(path)?
            .replace('%', "%%")
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
    ))
}
fn write_executable(path: &Path, content: &str) -> io::Result<()> {
    fs::write(path, content)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o755))
}
fn copy(source: &Path, destination: &Path, executable: bool) -> io::Result<()> {
    crate::remove(destination)?;
    fs::copy(source, destination)?;
    if executable {
        fs::set_permissions(destination, fs::Permissions::from_mode(0o755))?;
    }
    Ok(())
}

pub fn launchers(
    profile: &Path,
    bin: &Path,
    cache: &Path,
    lock: &Path,
    qs: &Path,
) -> io::Result<()> {
    fs::create_dir_all(bin)?;
    for is_lock in [false, true] {
        let mut env = vec![
            ("MACSHELL_SETTINGS_HOME", profile.join("settings")),
            ("MACSHELL_LOCK_HELPER", bin.join("maclock-niri")),
            ("XDG_CACHE_HOME", cache.join("macshell-niri")),
            ("MACSHELL_WALLPAPER_CACHE_HOME", cache.to_owned()),
            ("MACSHELL_QS_BIN", qs.to_owned()),
        ];
        if !is_lock {
            env.push((
                "MACSHELL_INPUT_FRAGMENT",
                profile.join("niri/macshell-input.kdl"),
            ));
            env.push(("MACSHELL_NIRI_PROFILE", profile.join("niri")));
        }
        let mut script = String::from("#!/usr/bin/env bash\nset -euo pipefail\n");
        for (key, value) in env {
            script.push_str(&format!("export {key}={}\n", quote(&value)?));
        }
        let parent = qs
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        script.push_str(&format!("export PATH={}:\"$PATH\"\n", quote(parent)?));
        script.push_str("export QT_QUICK_CONTROLS_STYLE=\"${QT_QUICK_CONTROLS_STYLE:-Basic}\"\n");
        if is_lock {
            script.push_str(&format!(
                "exec sh {} \"$@\"\n",
                quote(&lock.join("lock-via-ipc.sh"))?
            ));
        } else {
            script.push_str("if [[ $# -eq 0 && ${MACSHELL_MANAGED_SHELL:-} == 1 && ${MACSHELL_SERVICE_CHILD:-} != 1 ]]; then\n");
            script.push_str(&format!(
                "    if [[ -f {} ]]; then\n        exec sh {} start\n    fi\n    if [[ -e {} || -L {} ]]; then\n        echo 'Shell supervisor Rust helper is missing or incompatible' >&2\n        exit 1\n    fi\n    exec python3 {} start\nfi\n",
                quote(&profile.join("shell-supervisor.sh"))?,
                quote(&profile.join("shell-supervisor.sh"))?,
                quote(&profile.join(".macshell-rust-only"))?,
                quote(&profile.join(".macshell-rust-only"))?,
                quote(&profile.join("shell-supervisor.py"))?
            ));
            script.push_str(
                "unset MACSHELL_SERVICE_CHILD\nexec \"$MACSHELL_QS_BIN\" -c MacShell-niri \"$@\"\n",
            );
        }
        let target = bin.join(if is_lock {
            "maclock-niri"
        } else {
            "macshell-niri"
        });
        crate::remove(&target)?;
        write_executable(&target, &script)?;
    }
    Ok(())
}

pub struct Paths<'a> {
    pub source: &'a Path,
    pub profile: &'a Path,
    pub bin: &'a Path,
    pub data: &'a Path,
    pub config: &'a Path,
    pub qs: &'a Path,
    pub locale: &'a Path,
    pub preflight: &'a Path,
}

pub fn files(p: Paths<'_>) -> io::Result<()> {
    fs::create_dir_all(p.profile)?;
    fs::create_dir_all(p.bin)?;
    for (name, version_flag, expected, invocation, message) in [
        ("session-preflight.sh", "--protocol-version", "macshell-session-preflight 1", "exec \"$binary\" \"$@\"", "Session preflight"),
        ("session-ready.sh", "--ready-protocol-version", "macshell-session-ready 1", "exec \"$binary\" --ready \"$@\"", "Session readiness"),
        ("shell-supervisor.sh", "--supervisor-protocol-version", "macshell-shell-supervisor 1", "case \"${1-}\" in start) shift; exec \"$binary\" --supervisor-start \"$@\" ;; check) shift; exec \"$binary\" --supervisor-check \"$@\" ;; esac", "Shell supervisor"),
        ("session-locale.sh", "--protocol-version", "macshell-locale-preferences 1", "exec \"$binary\" --session", "Session locale"),
    ] {
        let binary = if name == "session-locale.sh" { "locale-preferences-rust" } else { "session-preflight-rust" };
        let script = format!("#!/bin/sh\nset -eu\ndirectory=$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)\nbinary=\"$directory/{binary}\"\nif [ -x \"$binary\" ] && [ \"$(timeout 3 \"$binary\" {version_flag} 2>/dev/null || :)\" = \"{expected}\" ]; then\n    {invocation}\nfi\necho '{message} Rust helper is missing or incompatible' >&2\nexit 1\n");
        crate::remove(&p.profile.join(name))?;
        write_executable(&p.profile.join(name), &script)?;
    }
    copy(p.preflight, &p.profile.join("session-preflight-rust"), true)?;
    copy(p.locale, &p.profile.join("locale-preferences-rust"), true)?;
    let mut script = fs::read_to_string(p.source.join("scripts/niri-macshell-session.sh"))?;
    for (token, value) in [
        ("@PROFILE_CONFIG@", p.profile.join("niri/config.kdl")),
        ("@PREFLIGHT@", p.profile.join("session-preflight.sh")),
        ("@QS_BINARY@", p.qs.to_owned()),
        ("@LOCALE_HELPER@", p.profile.join("session-locale.sh")),
    ] {
        script = script.replace(token, &quote(&value)?);
    }
    write_executable(&p.bin.join("niri-macshell-session"), &script)?;
    let units = p.config.join("systemd/user");
    fs::create_dir_all(&units)?;
    let session = format!("[Unit]\nDescription=niri with the separate MacShell profile\nBindsTo=graphical-session.target\nBefore=graphical-session.target\nWants=graphical-session-pre.target\nAfter=graphical-session-pre.target\nWants=xdg-desktop-autostart.target\nBefore=xdg-desktop-autostart.target\n\n[Service]\nSlice=session.slice\nType=notify\nTimeoutStartSec=30\nTimeoutStopSec=10\nExecStart=/usr/bin/niri --session --config {}\nExecStartPost=/bin/sh {} {}\nExecStopPost=-/usr/bin/systemctl --user stop macshell-niri-shell.service\n", unit(&p.profile.join("niri/config.kdl"))?, unit(&p.profile.join("session-ready.sh"))?, unit(&p.bin.join("macshell-niri"))?);
    let shell = format!("[Unit]\nDescription=MacShell for the niri session\nPartOf=niri-macshell.service\nStartLimitIntervalSec=60\nStartLimitBurst=5\n\n[Service]\nSlice=session.slice\nType=exec\nEnvironment=MACSHELL_SERVICE_CHILD=1\nExecStartPre=/bin/sh {} check {}\nExecStart={}\nRestart=on-failure\nRestartSec=2\nTimeoutStopSec=10\nKillMode=control-group\n", unit(&p.profile.join("shell-supervisor.sh"))?, unit(p.qs)?, unit(&p.bin.join("macshell-niri"))?);
    fs::write(units.join("niri-macshell.service"), session)?;
    fs::write(units.join("macshell-niri-shell.service"), shell)?;
    let bundle = p.data.join("session");
    fs::create_dir_all(&bundle)?;
    for source in [
        "scripts/register-session.sh",
        "scripts/session-entry.sh",
        "config/niri-macshell.desktop",
    ] {
        let path = PathBuf::from(source);
        copy(
            &p.source.join(source),
            &bundle.join(path.file_name().unwrap()),
            false,
        )?;
    }
    for (program, args) in [
        (
            "desktop-file-validate",
            vec![bundle.join("niri-macshell.desktop").into_os_string()],
        ),
        ("systemctl", vec!["--user".into(), "daemon-reload".into()]),
    ] {
        let output = Command::new(program).args(args).output()?;
        if !output.status.success() {
            return Err(io::Error::other(format!(
                "{program} failed: {}",
                String::from_utf8_lossy(&output.stderr)
            )));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    use std::sync::atomic::{AtomicU64, Ordering};

    static SEQUENCE: AtomicU64 = AtomicU64::new(0);

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "macshell launcher 'test' {} {}",
                std::process::id(),
                SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn managed_launcher_respects_profile_policy_and_legacy_sessions() {
        let fixture = Fixture::new();
        let root = &fixture.0;
        let profile = root.join("profile 'quoted %");
        let bin = root.join("bin");
        let tools = root.join("tools");
        fs::create_dir(&profile).unwrap();
        fs::create_dir(&tools).unwrap();
        write_executable(
            &tools.join("python3"),
            "#!/bin/sh\nprintf 'legacy:%s\\n' \"$2\"\n",
        )
        .unwrap();
        let qs = tools.join("qs");
        write_executable(&qs, "#!/bin/sh\nprintf 'qs:%s\\n' \"$*\"\n").unwrap();
        launchers(&profile, &bin, &root.join("cache"), &root.join("lock"), &qs).unwrap();
        let run = |managed: bool, child: bool| {
            Command::new(bin.join("macshell-niri"))
                .env("MACSHELL_MANAGED_SHELL", if managed { "1" } else { "0" })
                .env("MACSHELL_SERVICE_CHILD", if child { "1" } else { "0" })
                .output()
                .unwrap()
        };
        let legacy = run(true, false);
        assert!(legacy.status.success());
        assert_eq!(legacy.stdout, b"legacy:start\n");

        let marker = profile.join(".macshell-rust-only");
        fs::write(&marker, "1\n").unwrap();
        let denied = run(true, false);
        assert!(!denied.status.success());
        assert!(denied.stdout.is_empty());
        assert!(String::from_utf8_lossy(&denied.stderr)
            .contains("Shell supervisor Rust helper is missing"));

        fs::remove_file(&marker).unwrap();
        symlink("missing-marker", &marker).unwrap();
        assert!(!run(true, false).status.success());

        write_executable(
            &profile.join("shell-supervisor.sh"),
            "#!/bin/sh\nprintf 'helper:%s\\n' \"$1\"\n",
        )
        .unwrap();
        let helper = run(true, false);
        assert!(helper.status.success());
        assert_eq!(helper.stdout, b"helper:start\n");
        for (managed, child) in [(false, false), (true, true)] {
            let direct = run(managed, child);
            assert!(direct.status.success());
            assert_eq!(direct.stdout, b"qs:-c MacShell-niri\n");
        }
    }

    #[test]
    fn session_profile_snapshot_restores_legacy_and_preserves_new_state() {
        let fixture = Fixture::new();
        let root = &fixture.0;
        let profile = root.join("legacy profile");
        let data = root.join("data");
        let unit = root.join("systemd/user/niri-macshell.service");
        fs::create_dir_all(profile.join("settings")).unwrap();
        fs::create_dir_all(unit.parent().unwrap()).unwrap();
        fs::write(profile.join("shell-supervisor.py"), "old supervisor").unwrap();
        fs::write(profile.join("settings/preferences.json"), "original").unwrap();
        fs::write(&unit, "old unit").unwrap();
        let snapshot = crate::snapshot(&data, &[profile.clone(), unit.clone()]).unwrap();
        let directory = PathBuf::from(snapshot["directory"].as_str().unwrap());
        fs::write(profile.join(".macshell-rust-only"), "1\n").unwrap();
        fs::write(profile.join("shell-supervisor.sh"), "new supervisor").unwrap();
        fs::write(profile.join("settings/preferences.json"), "new settings").unwrap();
        fs::write(&unit, "new unit").unwrap();
        crate::restore(
            &data,
            &directory,
            &snapshot["manifest"],
            &root.join("niri"),
            false,
        )
        .unwrap();
        assert_eq!(
            fs::read_to_string(profile.join("shell-supervisor.py")).unwrap(),
            "old supervisor"
        );
        assert_eq!(
            fs::read_to_string(profile.join("settings/preferences.json")).unwrap(),
            "original"
        );
        assert!(!profile.join(".macshell-rust-only").exists());
        assert!(!profile.join("shell-supervisor.sh").exists());
        assert_eq!(fs::read_to_string(&unit).unwrap(), "old unit");
        assert_eq!(
            fs::read_to_string(directory.join("after/0/settings/preferences.json")).unwrap(),
            "new settings"
        );
        assert_eq!(
            fs::read_to_string(directory.join("after/1")).unwrap(),
            "new unit"
        );
    }

    #[test]
    fn installed_supervisor_rejects_missing_or_incompatible_rust_in_marked_profile() {
        let fixture = Fixture::new();
        let root = &fixture.0;
        let profile = root.join("profile");
        let bin = root.join("bin");
        let tools = root.join("tools");
        fs::create_dir(&profile).unwrap();
        fs::create_dir(&tools).unwrap();
        let source =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/shell-supervisor.sh");
        fs::copy(source, profile.join("shell-supervisor.sh")).unwrap();
        fs::write(profile.join(".macshell-rust-only"), "1\n").unwrap();
        let called = root.join("python-called");
        write_executable(
            &tools.join("python3"),
            "#!/bin/sh\ntouch \"$PYTHON_CALLED\"\n",
        )
        .unwrap();
        let qs = tools.join("qs");
        write_executable(&qs, "#!/bin/sh\nexit 0\n").unwrap();
        launchers(&profile, &bin, &root.join("cache"), &root.join("lock"), &qs).unwrap();
        let path = format!("{}:/usr/bin:/bin", tools.display());
        let run = || {
            Command::new(bin.join("macshell-niri"))
                .env("PATH", &path)
                .env("PYTHON_CALLED", &called)
                .env("MACSHELL_MANAGED_SHELL", "1")
                .env("MACSHELL_SERVICE_CHILD", "0")
                .output()
                .unwrap()
        };
        for incompatible in [false, true] {
            if incompatible {
                write_executable(
                    &profile.join("session-preflight-rust"),
                    "#!/bin/sh\nprintf 'wrong version\\n'\n",
                )
                .unwrap();
            }
            let result = run();
            assert!(!result.status.success());
            assert!(String::from_utf8_lossy(&result.stderr)
                .contains("Shell supervisor Rust helper is missing or incompatible"));
            assert!(!called.exists());
        }
    }
}
