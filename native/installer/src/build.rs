//! Build all runtime components in staging before changing installed files.
use serde_json::{json, Map, Value};
use std::io;
use std::path::Path;
use std::process::Command;

struct Artifact {
    name: &'static str,
    protocol: Option<&'static str>,
}
struct Component {
    crate_name: &'static str,
    bins: &'static [&'static str],
    artifacts: &'static [Artifact],
}
macro_rules! artifact {
    ($name:literal) => {
        Artifact {
            name: concat!("macshell-", $name),
            protocol: Some(concat!("macshell-", $name, " 1")),
        }
    };
}
macro_rules! component {
    ($package:literal, $name:literal) => {
        Component {
            crate_name: $package,
            bins: &[],
            artifacts: &[artifact!($name)],
        }
    };
}

static COMPONENTS: &[Component] = &[
    component!("niri-bridge", "niri-bridge"),
    component!("boot-clock", "boot-clock"),
    component!("system-stats", "system-stats"),
    component!("night-shift", "night-shift"),
    component!("timed-modes", "timed-modes"),
    component!("activity-preferences", "activity-preferences"),
    component!("bar-preferences", "bar-preferences"),
    component!("widget-preferences", "widget-preferences"),
    component!("locale-preferences", "locale-preferences"),
    component!("native-blur", "native-blur"),
    component!("session-preflight", "session-preflight"),
    component!("power-profiles", "power-profiles"),
    component!("niri-color", "niri-color"),
    Component {
        crate_name: "bluez-session",
        bins: &["macshell-bluetooth"],
        artifacts: &[artifact!("bluetooth")],
    },
    Component {
        crate_name: "capture-service",
        bins: &["macshell-capture-experimental"],
        artifacts: &[Artifact {
            name: "macshell-capture-experimental",
            protocol: Some("macshell-capture 1"),
        }],
    },
    Component {
        crate_name: "recording-core",
        bins: &["macshell-recording-experimental"],
        artifacts: &[Artifact {
            name: "macshell-recording-experimental",
            protocol: Some("macshell-recording 1"),
        }],
    },
    Component {
        crate_name: "network-snapshot",
        bins: &["macshell-network"],
        artifacts: &[artifact!("network")],
    },
    Component {
        crate_name: "niri-input",
        bins: &["macshell-niri-input"],
        artifacts: &[artifact!("niri-input")],
    },
    Component {
        crate_name: "session-service",
        bins: &[],
        artifacts: &[Artifact {
            name: "macshell-session-service",
            protocol: None,
        }],
    },
    component!("currency-fetch", "currency-fetch"),
    component!("widget-fetch", "widget-fetch"),
    component!("wallpaper-discovery", "wallpaper-discovery"),
    component!("notes-service", "notes-service"),
    component!("calendar-service", "calendar-service"),
    component!("reminders-service", "reminders-service"),
    Component {
        crate_name: "clock-core",
        bins: &[
            "clock-service-prototype",
            "clock-audio-worker",
            "clock-sound-import",
        ],
        artifacts: &[
            Artifact {
                name: "clock-service-prototype",
                protocol: Some("macshell-clock-service 1"),
            },
            Artifact {
                name: "clock-audio-worker",
                protocol: None,
            },
            Artifact {
                name: "clock-sound-import",
                protocol: Some("macshell-clock-import 1"),
            },
        ],
    },
    component!("screen-mirroring", "screen-mirroring"),
    component!("airdrop-service", "airdrop-service"),
    Component {
        crate_name: "biometric-probe",
        bins: &[],
        artifacts: &[
            artifact!("biometric-probe"),
            Artifact {
                name: "fingerprint-operation",
                protocol: Some("macshell-fingerprint-operation 1"),
            },
        ],
    },
    component!("update-service", "update-service"),
    component!("desktop-source", "desktop-source"),
    component!("preview", "preview"),
];

fn check(binary: &Path, argument: &str, expected: &str) -> io::Result<()> {
    let output = Command::new("timeout")
        .arg("5")
        .arg(binary)
        .arg(argument)
        .output()?;
    if !output.status.success()
        || std::str::from_utf8(&output.stdout).ok().map(str::trim) != Some(expected)
    {
        return Err(io::Error::other(format!(
            "protocol check failed: {} {argument}",
            binary.display()
        )));
    }
    Ok(())
}

pub fn build(source: &Path, target: &Path) -> io::Result<Value> {
    let mut outputs = Map::new();
    for component in COMPONENTS {
        let manifest = source
            .join("native")
            .join(component.crate_name)
            .join("Cargo.toml");
        if !manifest.is_file() {
            return Err(io::Error::other(format!(
                "missing source: {}",
                manifest.display()
            )));
        }
        let dir = target.join(component.crate_name);
        let mut command = Command::new("timeout");
        command
            .args([
                "300",
                "cargo",
                "build",
                "--release",
                "--locked",
                "--offline",
                "--manifest-path",
            ])
            .arg(&manifest)
            .arg("--target-dir")
            .arg(&dir);
        for name in component.bins {
            command.arg("--bin").arg(name);
        }
        command
            .env_remove("MACSHELL_CURRENCY_TEST_API")
            .env_remove("MACSHELL_WIDGET_TEST_API");
        let output = command.output()?;
        if !output.status.success() {
            let error = String::from_utf8_lossy(&output.stderr);
            let tail: String = error
                .chars()
                .rev()
                .take(3000)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            return Err(io::Error::other(format!(
                "Rust build failed for {}: {tail}",
                component.crate_name
            )));
        }
        for artifact in component.artifacts {
            let binary = dir.join("release").join(artifact.name);
            if !binary.is_file() {
                return Err(io::Error::other(format!(
                    "missing built binary: {}",
                    binary.display()
                )));
            }
            if let Some(expected) = artifact.protocol {
                check(&binary, "--protocol-version", expected)?;
            }
            if artifact.name == "macshell-session-preflight" {
                check(
                    &binary,
                    "--ready-protocol-version",
                    "macshell-session-ready 1",
                )?;
                check(
                    &binary,
                    "--supervisor-protocol-version",
                    "macshell-shell-supervisor 1",
                )?;
            }
            outputs.insert(
                artifact.name.into(),
                json!(binary
                    .to_str()
                    .ok_or_else(|| io::Error::other("non UTF-8 target path"))?),
            );
        }
    }
    Ok(Value::Object(outputs))
}
