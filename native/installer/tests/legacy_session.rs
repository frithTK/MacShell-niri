use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

static SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[test]
fn retired_python_installer_is_rejected_before_building() {
    let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let result = Command::new("/bin/bash")
        .arg(source.join("install.sh"))
        .args(["--python-bridge", "--help"])
        .env("PATH", "/nonexistent")
        .output()
        .unwrap();
    assert_eq!(result.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&result.stderr).contains("Python installer is retired"));
}

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "macshell-legacy-session-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn script(&self, name: &str, body: &str) {
        let path = self.0.join("tools").join(name);
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn legacy_session_install_failure_and_rollback() {
    let fixture = Fixture::new();
    let root = &fixture.0;
    let real_components = std::env::var_os("MACSHELL_TEST_REAL_COMPONENTS").is_some();
    for dir in [
        "tools",
        "runtime",
        "config/niri",
        "config/macshell-niri/settings",
        "config/systemd/user",
        "config/quickshell/MacShell-niri",
        "config/quickshell/MacLock-niri",
        "bin",
        "data",
    ] {
        fs::create_dir_all(root.join(dir)).unwrap();
    }
    let profile = root.join("config/macshell-niri");
    let shell = root.join("config/quickshell/MacShell-niri");
    let lock = root.join("config/quickshell/MacLock-niri");
    fs::write(shell.join("notes_service.py"), "legacy notes\n").unwrap();
    fs::write(lock.join("boot_clock.py"), "legacy clock\n").unwrap();
    let units = root.join("config/systemd/user");
    fs::write(root.join("config/niri/config.kdl"), "// original niri\n").unwrap();
    fs::write(profile.join("shell-supervisor.py"), "legacy supervisor\n").unwrap();
    fs::write(
        profile.join("settings/preferences.json"),
        "legacy settings\n",
    )
    .unwrap();
    fs::write(units.join("niri-macshell.service"), "legacy session unit\n").unwrap();
    fs::write(
        units.join("macshell-niri-shell.service"),
        "legacy shell unit\n",
    )
    .unwrap();
    fs::write(root.join("bin/niri-macshell-session"), "legacy entry\n").unwrap();
    let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let preflight_build = root.join("real-preflight-build");
    let build = Command::new("cargo")
        .args([
            "build",
            "--release",
            "--offline",
            "--locked",
            "--manifest-path",
        ])
        .arg(source.join("native/session-preflight/Cargo.toml"))
        .arg("--target-dir")
        .arg(&preflight_build)
        .output()
        .unwrap();
    assert!(
        build.status.success(),
        "{}",
        String::from_utf8_lossy(&build.stderr)
    );
    let locale_build = root.join("real-locale-build");
    let build = Command::new("cargo")
        .args([
            "build",
            "--release",
            "--offline",
            "--locked",
            "--manifest-path",
        ])
        .arg(source.join("native/locale-preferences/Cargo.toml"))
        .arg("--target-dir")
        .arg(&locale_build)
        .output()
        .unwrap();
    assert!(
        build.status.success(),
        "{}",
        String::from_utf8_lossy(&build.stderr)
    );
    fixture.script(
        "systemctl",
        "case \"$*\" in *show*) printf 'inactive\\n';; esac; exit 0",
    );
    fixture.script(
        "qs",
        "case \"$*\" in *list*) printf '[]\\n';; *) printf 'ready\\n';; esac",
    );
    fixture.script("niri", "exit 0");
    fixture.script("systemd-run", "exit 0");
    fixture.script("desktop-file-validate", "test ! -f \"$TEST_FAIL_VALIDATE\"");
    fixture.script("cargo", r#"
manifest= target= bins=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest-path) manifest=$2; shift;;
    --target-dir) target=$2; shift;;
    --bin) bins="$bins $2"; shift;;
  esac
  shift
done
crate=$(/usr/bin/basename "$(/usr/bin/dirname "$manifest")")
if [ "${REAL_COMPONENTS:-0}" = 1 ] && [ "$crate" != session-preflight ] && [ "$crate" != locale-preferences ]; then
  set -- build --release --locked --offline --manifest-path "$manifest" --target-dir "$target"
  for bin in $bins; do set -- "$@" --bin "$bin"; done
  exec /usr/bin/cargo "$@"
fi
if [ -z "$bins" ]; then
  case "$crate" in biometric-probe) bins='macshell-biometric-probe fingerprint-operation';; *) bins="macshell-$crate";; esac
fi
/usr/bin/mkdir -p "$target/release"
if [ "$crate" = session-preflight ]; then
  /usr/bin/cp "$REAL_PREFLIGHT" "$target/release/macshell-session-preflight"
  exit $?
fi
if [ "$crate" = locale-preferences ]; then
  /usr/bin/cp "$REAL_LOCALE" "$target/release/macshell-locale-preferences"
  exit $?
fi
for bin in $bins; do
  case "$bin" in
    macshell-capture-experimental) protocol='macshell-capture 1';;
    macshell-recording-experimental) protocol='macshell-recording 1';;
    fingerprint-operation) protocol='macshell-fingerprint-operation 1';;
    clock-service-prototype) protocol='macshell-clock-service 1';;
    clock-sound-import) protocol='macshell-clock-import 1';;
    *) protocol="$bin 1";;
  esac
  printf '#!/bin/sh\ncase "$1" in --ready-protocol-version) echo "macshell-session-ready 1";; --supervisor-protocol-version) echo "macshell-shell-supervisor 1";; *) echo "%s";; esac\n' "$protocol" > "$target/release/$bin"
  /usr/bin/chmod +x "$target/release/$bin"
done
"#);
    let tools = root.join("tools");
    let invoke = |action: &str| {
        Command::new(env!("CARGO_BIN_EXE_macshell-installer"))
            .arg(action)
            .arg(&source)
            .arg(root.join("config"))
            .arg(root.join("cache"))
            .arg(root.join("data"))
            .arg(root.join("bin"))
            .arg(tools.join("qs"))
            .arg(if action == "install-profile" {
                "session"
            } else {
                "safe"
            })
            .env("PATH", format!("{}:/usr/bin:/bin", tools.display()))
            .env("XDG_RUNTIME_DIR", root.join("runtime"))
            .env("TEST_FAIL_VALIDATE", root.join("fail-validate"))
            .env("REAL_COMPONENTS", if real_components { "1" } else { "0" })
            .env(
                "REAL_PREFLIGHT",
                preflight_build.join("release/macshell-session-preflight"),
            )
            .env(
                "REAL_LOCALE",
                locale_build.join("release/macshell-locale-preferences"),
            )
            .output()
            .unwrap()
    };
    let check_legacy = || {
        assert_eq!(
            fs::read_to_string(profile.join("shell-supervisor.py")).unwrap(),
            "legacy supervisor\n"
        );
        assert_eq!(
            fs::read_to_string(profile.join("settings/preferences.json")).unwrap(),
            "legacy settings\n"
        );
        assert_eq!(
            fs::read_to_string(units.join("niri-macshell.service")).unwrap(),
            "legacy session unit\n"
        );
        assert_eq!(
            fs::read_to_string(root.join("bin/niri-macshell-session")).unwrap(),
            "legacy entry\n"
        );
        assert!(!profile.join(".macshell-rust-only").exists());
        assert_eq!(
            fs::read_to_string(shell.join("notes_service.py")).unwrap(),
            "legacy notes\n"
        );
        assert_eq!(
            fs::read_to_string(lock.join("boot_clock.py")).unwrap(),
            "legacy clock\n"
        );
    };
    fs::write(root.join("fail-validate"), "fail").unwrap();
    let failed = invoke("install-profile");
    assert!(
        !failed.status.success(),
        "{}",
        String::from_utf8_lossy(&failed.stderr)
    );
    check_legacy();
    fs::remove_file(root.join("fail-validate")).unwrap();
    let installed = invoke("install-profile");
    assert!(
        installed.status.success(),
        "{}",
        String::from_utf8_lossy(&installed.stderr)
    );
    assert!(profile.join(".macshell-rust-only").is_file());
    assert!(profile.join("session-preflight-rust").is_file());
    fn assert_no_python(dir: &Path) {
        for entry in fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                assert_no_python(&path);
            } else {
                assert_ne!(
                    path.extension().and_then(|s| s.to_str()),
                    Some("py"),
                    "{}",
                    path.display()
                );
                if path.extension().is_some_and(|s| s == "sh") {
                    let script = fs::read_to_string(&path).unwrap();
                    assert!(!script.contains("python3"), "{}", path.display());
                    let checked = Command::new("/bin/sh")
                        .arg("-n")
                        .arg(&path)
                        .output()
                        .unwrap();
                    assert!(
                        checked.status.success(),
                        "{}: {}",
                        path.display(),
                        String::from_utf8_lossy(&checked.stderr)
                    );
                }
            }
        }
    }
    assert_no_python(&shell);
    assert_no_python(&lock);
    for name in ["apple", "alarm.wav", "timer.wav"] {
        assert!(
            !shell.join("sounds").join(name).exists(),
            "recording {name} was installed"
        );
    }
    for name in [
        "session-preflight.sh",
        "session-ready.sh",
        "shell-supervisor.sh",
        "session-locale.sh",
    ] {
        assert!(!fs::read_to_string(profile.join(name))
            .unwrap()
            .contains("python"));
    }
    for name in [
        "session-preflight.py",
        "session-ready.py",
        "session-locale.py",
        "locale_preferences.py",
    ] {
        assert!(
            !profile.join(name).exists(),
            "new session should not install {name}"
        );
    }
    assert_eq!(
        fs::read_to_string(profile.join("shell-supervisor.py")).unwrap(),
        "legacy supervisor\n"
    );
    let version = Command::new(profile.join("session-preflight-rust"))
        .arg("--supervisor-protocol-version")
        .output()
        .unwrap();
    assert!(version.status.success());
    assert_eq!(version.stdout, b"macshell-shell-supervisor 1\n");
    let locale = Command::new(profile.join("locale-preferences-rust"))
        .arg("--protocol-version")
        .output()
        .unwrap();
    assert!(locale.status.success());
    assert_eq!(locale.stdout, b"macshell-locale-preferences 1\n");
    fixture.script(
        "python3",
        "printf called > \"$TEST_PYTHON_CALLED\"; exit 99",
    );
    let python_called = root.join("python-called");
    for (dir, launcher, binary) in [
        (&shell, "network-service.sh", "network-service-rust"),
        (&shell, "niri-bridge.sh", "niri-bridge-rust"),
        (&lock, "boot-clock.sh", "boot-clock-rust"),
        (&lock, "fingerprint-unlock.sh", "fingerprint-operation-rust"),
    ] {
        let binary = dir.join(binary);
        let saved = binary.with_extension("saved");
        fs::rename(&binary, &saved).unwrap();
        let result = Command::new("/bin/sh")
            .arg(dir.join(launcher))
            .env("PATH", format!("{}:/usr/bin:/bin", tools.display()))
            .env("TEST_PYTHON_CALLED", &python_called)
            .output()
            .unwrap();
        fs::rename(&saved, &binary).unwrap();
        assert!(
            !result.status.success(),
            "{launcher} accepted missing binary"
        );
        assert!(String::from_utf8_lossy(&result.stderr).contains("Rust"));
    }
    let run_helper = |name: &str, args: &[&str]| {
        Command::new("/bin/sh")
            .arg(profile.join(name))
            .args(args)
            .env("PATH", format!("{}:/usr/bin:/bin", tools.display()))
            .env("TEST_PYTHON_CALLED", &python_called)
            .env("HOME", root)
            .env("XDG_CONFIG_HOME", root.join("config"))
            .output()
            .unwrap()
    };
    let qs_path = tools.join("qs");
    let qs_arg = qs_path.to_str().unwrap();
    let config_path = profile.join("niri/config.kdl");
    let config_arg = config_path.to_str().unwrap();
    let preflight = run_helper("session-preflight.sh", &[config_arg, qs_arg]);
    assert!(
        preflight.status.success(),
        "{}",
        String::from_utf8_lossy(&preflight.stderr)
    );
    let supervisor = run_helper("shell-supervisor.sh", &["check", qs_arg]);
    assert!(
        supervisor.status.success(),
        "{}",
        String::from_utf8_lossy(&supervisor.stderr)
    );
    let locale = run_helper("session-locale.sh", &[]);
    assert!(
        locale.status.success(),
        "{}",
        String::from_utf8_lossy(&locale.stderr)
    );
    let real = profile.join("session-preflight-rust");
    let saved = profile.join("session-preflight-saved");
    fs::rename(&real, &saved).unwrap();
    for (name, args) in [
        ("session-preflight.sh", vec![config_arg, qs_arg]),
        ("session-ready.sh", vec![qs_arg]),
        ("shell-supervisor.sh", vec!["check", qs_arg]),
    ] {
        let result = run_helper(name, &args);
        assert!(!result.status.success(), "{name} accepted missing helper");
        assert!(String::from_utf8_lossy(&result.stderr).contains("missing or incompatible"));
    }
    fs::rename(&saved, &real).unwrap();
    let real_locale = profile.join("locale-preferences-rust");
    let saved_locale = profile.join("locale-preferences-saved");
    fs::rename(&real_locale, &saved_locale).unwrap();
    assert!(!run_helper("session-locale.sh", &[]).status.success());
    fs::rename(&saved_locale, &real_locale).unwrap();
    assert!(!python_called.exists(), "session invoked Python");
    assert!(fs::read_to_string(units.join("niri-macshell.service"))
        .unwrap()
        .contains("session-ready.sh"));
    let rolled_back = invoke("rollback-profile");
    assert!(
        rolled_back.status.success(),
        "{}",
        String::from_utf8_lossy(&rolled_back.stderr)
    );
    check_legacy();
}
