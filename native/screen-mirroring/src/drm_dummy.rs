use std::env;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

pub fn is_dummy_name(name: &str) -> bool {
    (name.starts_with("HDMI-A-") || name.starts_with("DP-")) && !name.starts_with("eDP-")
}

pub fn edid_1920x1080() -> [u8; 128] {
    let mut edid = [0u8; 128];
    edid[0..8].copy_from_slice(&[0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]);
    edid[8] = 0x36;
    edid[9] = 0x68;
    edid[10] = 0x01;
    edid[18] = 0x01;
    edid[19] = 0x03;
    edid[20] = 0x80;
    edid[21] = 52;
    edid[22] = 29;
    edid[23] = 0x78;
    edid[24] = 0x0A;
    edid[25..35].copy_from_slice(&[0xCF, 0x74, 0xA3, 0x57, 0x4C, 0xB0, 0x23, 0x09, 0x48, 0x4C]);
    for slot in edid[38..54].iter_mut() {
        *slot = 0x01;
    }
    edid[54..72].copy_from_slice(&[
        0x02, 0x3A, 0x80, 0x18, 0x71, 0x38, 0x2D, 0x40, 0x58, 0x2C, 0x45, 0x00, 0x34, 0x00, 0x11,
        0x00, 0x00, 0x1E,
    ]);
    edid[72..77].copy_from_slice(&[0x00, 0x00, 0x00, 0xFC, 0x00]);
    edid[77..90].copy_from_slice(b"MacShell\n    ");
    edid[90..94].copy_from_slice(&[0x00, 0x00, 0x00, 0x10]);
    edid[108..112].copy_from_slice(&[0x00, 0x00, 0x00, 0x10]);
    let sum: u8 = edid[..127]
        .iter()
        .fold(0u8, |acc, byte| acc.wrapping_add(*byte));
    edid[127] = 0u8.wrapping_sub(sum);
    edid
}

fn sysfs_root() -> PathBuf {
    env::var_os("MACSHELL_DRM_SYSFS")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/sys/class/drm"))
}

fn debugfs_root() -> PathBuf {
    env::var_os("MACSHELL_DRM_DEBUGFS")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/sys/kernel/debug/dri"))
}

pub fn candidate() -> Option<String> {
    let mut found = Vec::new();
    let entries = fs::read_dir(sysfs_root()).ok()?;
    for entry in entries.flatten() {
        let file_name = entry.file_name();
        let Some(full) = file_name.to_str() else {
            continue;
        };
        let Some((_, connector)) = full
            .split_once('-')
            .filter(|(card, _)| card.starts_with("card"))
        else {
            continue;
        };
        if !is_dummy_name(connector) {
            continue;
        }
        let status = fs::read_to_string(entry.path().join("status")).unwrap_or_default();
        if status.trim() == "disconnected" {
            found.push(connector.to_string());
        }
    }
    found.sort();
    found
        .iter()
        .find(|name| name.starts_with("HDMI-A-"))
        .cloned()
        .or_else(|| found.into_iter().next())
}

fn walk_named(root: &Path, name: &str, depth: u8, found: &mut Option<PathBuf>) {
    if found.is_some() || depth == 0 {
        return;
    }
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let file_name = entry.file_name();
        let label = file_name.to_string_lossy();
        if label == name || label.ends_with(&format!("-{name}")) {
            if path.join("force").exists() || path.join("edid_override").exists() {
                *found = Some(path);
                return;
            }
        }
        if path.is_dir() {
            walk_named(&path, name, depth - 1, found);
            if found.is_some() {
                return;
            }
        }
    }
}

fn connector_debug_dir(name: &str) -> Option<PathBuf> {
    let mut found = None;
    walk_named(&debugfs_root(), name, 3, &mut found);
    found
}

fn sysfs_connector(name: &str) -> Option<PathBuf> {
    let root = sysfs_root();
    let entries = fs::read_dir(&root).ok()?;
    for entry in entries.flatten() {
        let file_name = entry.file_name();
        if file_name.to_string_lossy().ends_with(&format!("-{name}")) {
            return Some(entry.path());
        }
    }
    None
}

fn write_value(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let mut file = OpenOptions::new()
        .write(true)
        .truncate(true)
        .open(path)
        .map_err(|error| format!("Could not update {}: {error}", path.display()))?;
    file.write_all(bytes)
        .map_err(|error| format!("Could not update {}: {error}", path.display()))
}

fn live_drm() -> bool {
    env::var_os("MACSHELL_DRM_SYSFS").is_none()
}

fn wait_connected(name: &str, timeout: Duration) -> bool {
    let end = Instant::now() + timeout;
    loop {
        if is_connected(name) {
            return true;
        }
        if Instant::now() >= end {
            return false;
        }
        thread::sleep(Duration::from_millis(40));
    }
}

pub fn disconnected_error(name: &str) -> String {
    format!(
        "The extra display {name} stayed disconnected. The password was accepted, but the GPU did not enable this HDMI/DisplayPort port. Plug an HDMI dummy, or use niri with virtual outputs."
    )
}

pub fn is_connected(name: &str) -> bool {
    sysfs_connector(name)
        .and_then(|sys| fs::read_to_string(sys.join("status")).ok())
        .is_some_and(|status| status.trim() == "connected")
}

pub fn writable() -> bool {
    let Some(name) = candidate() else {
        return false;
    };
    let Some(dir) = connector_debug_dir(&name) else {
        return false;
    };
    OpenOptions::new()
        .write(true)
        .open(dir.join("force"))
        .is_ok()
}

fn privileged(action: &str, name: &str) -> Result<(), String> {
    let exe = env::current_exe().map_err(|error| error.to_string())?;
    let pkexec = env::var_os("MACSHELL_PKEXEC")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("pkexec"));
    let output = Command::new(&pkexec)
        .arg(exe)
        .arg("--drm-dummy")
        .arg(action)
        .arg(name)
        .stdin(Stdio::null())
        .output()
        .map_err(|_| "Authorization helper is not available.".to_string())?;
    if output.status.success() {
        return Ok(());
    }
    let text = String::from_utf8_lossy(&output.stderr);
    Err(if text.trim().is_empty() {
        "Authorization is required to create the extra display.".into()
    } else {
        text.chars().take(200).collect()
    })
}

pub fn enable(name: &str) -> Result<(), String> {
    if writable() {
        force_on(name)
    } else {
        privileged("on", name)
    }
}

pub fn disable(name: &str) -> Result<(), String> {
    if writable() {
        force_off(name)
    } else {
        let _ = privileged("off", name);
        Ok(())
    }
}

pub fn force_on(name: &str) -> Result<(), String> {
    if !super::niri::valid_output_name(name) || !is_dummy_name(name) {
        return Err(
            "The extra display name is not a disconnected HDMI or DisplayPort output.".into(),
        );
    }
    if is_connected(name) {
        return Ok(());
    }
    let dir = connector_debug_dir(name).ok_or_else(|| {
        "Cannot access DRM debugfs. Root authorization is required to create the extra display."
            .to_string()
    })?;
    let sys = sysfs_connector(name).ok_or_else(|| {
        "Cannot access the DRM sysfs connector for the extra display.".to_string()
    })?;
    write_value(&dir.join("edid_override"), &edid_1920x1080())?;
    // debugfs `force` only stores connector->force; it does not probe.
    // sysfs `status` calls fill_modes only when force *changes*. Writing
    // debugfs `digital` first, then sysfs `on-digital`, leaves force
    // unchanged so i915 never probes and the port stays disconnected.
    // `on-digital`/`digital` is DVI-I; HDMI/DP use DRM_FORCE_ON (`on`).
    // Do not write `detect` afterwards: that resets force.
    const ATTEMPTS: &[(&[u8], &[u8])] = &[(b"on", b"on"), (b"on-digital", b"digital")];
    let mut last_error = None;
    for (index, (sys_token, debug_token)) in ATTEMPTS.iter().enumerate() {
        if index > 0 {
            let _ = write_value(&sys.join("status"), b"off");
            let _ = write_value(&dir.join("force"), b"off");
        }
        match write_value(&sys.join("status"), sys_token) {
            Ok(()) => {
                let _ = write_value(&dir.join("force"), debug_token);
            }
            Err(error) => {
                last_error = Some(error);
                if write_value(&dir.join("force"), debug_token).is_err() {
                    continue;
                }
            }
        }
        if !live_drm() {
            return Ok(());
        }
        if wait_connected(name, Duration::from_millis(800)) {
            return Ok(());
        }
    }
    let _ = force_off(name);
    Err(last_error.unwrap_or_else(|| disconnected_error(name)))
}

pub fn force_off(name: &str) -> Result<(), String> {
    if !super::niri::valid_output_name(name) || !is_dummy_name(name) {
        return Ok(());
    }
    if let Some(dir) = connector_debug_dir(name) {
        let _ = write_value(&dir.join("edid_override"), b"reset");
        let _ = write_value(&dir.join("force"), b"unspecified");
    }
    if let Some(sys) = sysfs_connector(name) {
        let _ = write_value(&sys.join("status"), b"detect");
    }
    Ok(())
}

pub fn cli(args: &[String]) -> i32 {
    match args.first().map(String::as_str) {
        Some("status") => {
            let candidate = candidate().unwrap_or_default();
            println!(
                "{}",
                serde_json::json!({"candidate": candidate, "writable": writable()})
            );
            0
        }
        Some("on") => match args.get(1) {
            Some(name) => force_on(name).map(|_| 0).unwrap_or_else(|error| {
                eprintln!("{error}");
                1
            }),
            None => {
                eprintln!("Usage: --drm-dummy on OUTPUT");
                2
            }
        },
        Some("off") => match args.get(1) {
            Some(name) => force_off(name).map(|_| 0).unwrap_or_else(|error| {
                eprintln!("{error}");
                1
            }),
            None => {
                eprintln!("Usage: --drm-dummy off OUTPUT");
                2
            }
        },
        _ => {
            eprintln!("Usage: --drm-dummy status|on OUTPUT|off OUTPUT");
            2
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::time::{SystemTime, UNIX_EPOCH};

    static LOCK: Mutex<()> = Mutex::new(());

    struct Env {
        sysfs: PathBuf,
        debugfs: PathBuf,
    }

    impl Env {
        fn new() -> Self {
            let stamp = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let root = std::env::temp_dir().join(format!("macshell-drm-{stamp}"));
            let sysfs = root.join("sys");
            let debugfs = root.join("debug");
            fs::create_dir_all(sysfs.join("card1-eDP-1")).unwrap();
            fs::write(sysfs.join("card1-eDP-1/status"), "connected\n").unwrap();
            fs::create_dir_all(sysfs.join("card1-HDMI-A-1")).unwrap();
            fs::write(sysfs.join("card1-HDMI-A-1/status"), "disconnected\n").unwrap();
            fs::create_dir_all(debugfs.join("1/HDMI-A-1")).unwrap();
            fs::write(debugfs.join("1/HDMI-A-1/force"), "unspecified").unwrap();
            fs::write(debugfs.join("1/HDMI-A-1/edid_override"), "").unwrap();
            env::set_var("MACSHELL_DRM_SYSFS", &sysfs);
            env::set_var("MACSHELL_DRM_DEBUGFS", &debugfs);
            Self { sysfs, debugfs }
        }
    }

    impl Drop for Env {
        fn drop(&mut self) {
            env::remove_var("MACSHELL_DRM_SYSFS");
            env::remove_var("MACSHELL_DRM_DEBUGFS");
            let _ = fs::remove_dir_all(self.sysfs.parent().unwrap());
        }
    }

    #[test]
    fn edid_checksum_and_name() {
        let edid = edid_1920x1080();
        assert_eq!(edid.iter().fold(0u8, |a, b| a.wrapping_add(*b)), 0);
        assert!(edid[77..].starts_with(b"MacShell"));
        assert!(is_dummy_name("HDMI-A-1"));
        assert!(is_dummy_name("DP-2"));
        assert!(!is_dummy_name("eDP-1"));
    }

    #[test]
    fn disconnected_hdmi_is_preferred_and_can_be_forced_off() {
        let _lock = LOCK.lock().unwrap_or_else(|error| error.into_inner());
        let env = Env::new();
        assert_eq!(candidate().as_deref(), Some("HDMI-A-1"));
        force_on("HDMI-A-1").unwrap();
        assert_eq!(
            fs::read(env.debugfs.join("1/HDMI-A-1/force")).unwrap(),
            b"on"
        );
        assert_eq!(
            fs::read(env.sysfs.join("card1-HDMI-A-1/status")).unwrap(),
            b"on"
        );
        assert_eq!(
            fs::read(env.debugfs.join("1/HDMI-A-1/edid_override")).unwrap(),
            edid_1920x1080()
        );
        assert!(!is_connected("HDMI-A-1"));
        assert!(disconnected_error("HDMI-A-1").contains("HDMI-A-1"));
        assert!(disconnected_error("HDMI-A-1").contains("HDMI dummy"));
        force_off("HDMI-A-1").unwrap();
        assert_eq!(
            fs::read(env.debugfs.join("1/HDMI-A-1/force")).unwrap(),
            b"unspecified"
        );
        assert_eq!(
            fs::read(env.debugfs.join("1/HDMI-A-1/edid_override")).unwrap(),
            b"reset"
        );
        force_on("eDP-1").unwrap_err();
    }

    #[test]
    fn missing_debugfs_is_an_authorization_error() {
        let _lock = LOCK.lock().unwrap_or_else(|error| error.into_inner());
        let env = Env::new();
        let _ = fs::remove_dir_all(&env.debugfs);
        fs::create_dir_all(&env.debugfs).unwrap();
        let error = force_on("HDMI-A-1").unwrap_err();
        assert!(error.contains("debugfs"), "{error}");
    }
}
