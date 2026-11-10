use serde_json::Value;
use std::env;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub const VIRTUAL_NAME: &str = "MacShell-AirPlay";
pub const EXTEND_UNAVAILABLE: &str = "This compositor cannot create a virtual display. Plug an HDMI dummy, or use a niri build with virtual outputs (niri#3800).";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutputInfo {
    pub name: String,
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Caps {
    pub virtual_create: bool,
    pub outputs: Vec<OutputInfo>,
    pub dummy_connector: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExtendTarget {
    pub name: String,
    pub owned: bool,
    pub dummy: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CastMatch {
    None,
    Target,
    Dynamic,
    Other,
}

impl Caps {
    pub fn extend_available(&self) -> bool {
        self.virtual_create
            || extra_physical(&self.outputs).is_some()
            || self.dummy_connector.is_some()
    }

    pub fn planned_output(&self) -> String {
        if self.virtual_create {
            return VIRTUAL_NAME.into();
        }
        extra_physical(&self.outputs)
            .map(|output| output.name.clone())
            .or_else(|| self.dummy_connector.clone())
            .unwrap_or_default()
    }

    pub fn extend_method(&self) -> &'static str {
        if self.virtual_create {
            "virtual"
        } else if extra_physical(&self.outputs).is_some() {
            "output"
        } else if self.dummy_connector.is_some() {
            "dummy"
        } else {
            ""
        }
    }
}

pub fn valid_output_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

pub fn help_supports_virtual(help: &str) -> bool {
    help.contains("create-virtual-output")
}

pub fn parse_outputs(value: &Value) -> Vec<OutputInfo> {
    let Some(map) = value.as_object() else {
        return Vec::new();
    };
    let mut outputs = Vec::new();
    for (name, info) in map {
        if !valid_output_name(name) {
            continue;
        }
        let logical = info.get("logical").unwrap_or(&Value::Null);
        let width = logical.get("width").and_then(Value::as_i64).unwrap_or(0) as i32;
        let height = logical.get("height").and_then(Value::as_i64).unwrap_or(0) as i32;
        if width <= 0 || height <= 0 {
            continue;
        }
        outputs.push(OutputInfo {
            name: name.clone(),
            x: logical.get("x").and_then(Value::as_i64).unwrap_or(0) as i32,
            y: logical.get("y").and_then(Value::as_i64).unwrap_or(0) as i32,
            width,
            height,
        });
    }
    outputs.sort_by(|a, b| a.x.cmp(&b.x).then_with(|| a.name.cmp(&b.name)));
    outputs
}

pub fn extra_physical(outputs: &[OutputInfo]) -> Option<&OutputInfo> {
    let primary = outputs.first()?;
    outputs
        .iter()
        .find(|output| output.name != VIRTUAL_NAME && output.name != primary.name)
}

pub fn right_edge(outputs: &[OutputInfo], except: &str) -> (i32, i32) {
    outputs
        .iter()
        .filter(|output| output.name != except)
        .map(|output| (output.x + output.width, output.y))
        .max_by_key(|(x, _)| *x)
        .unwrap_or((0, 0))
}

pub fn match_casts(value: &Value, target: &str) -> CastMatch {
    let Some(items) = value.as_array() else {
        return CastMatch::None;
    };
    let mut found = CastMatch::None;
    for item in items {
        if item.get("is_active") == Some(&Value::Bool(false)) {
            continue;
        }
        if item.get("is_dynamic_target") == Some(&Value::Bool(true)) {
            return CastMatch::Dynamic;
        }
        let name = item
            .pointer("/target/Output/name")
            .and_then(Value::as_str)
            .unwrap_or("");
        if name == target {
            found = CastMatch::Target;
        } else if !name.is_empty() {
            found = CastMatch::Other;
        } else if item.get("target").is_some() {
            found = CastMatch::Other;
        }
    }
    found
}

fn niri_bin() -> PathBuf {
    env::var_os("MACSHELL_NIRI")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("niri"))
}

fn run(args: &[&str]) -> Result<String, String> {
    let output = Command::new(niri_bin())
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|_| "niri is not available.".to_string())?;
    if !output.status.success() {
        let mut text = String::from_utf8_lossy(&output.stderr).into_owned();
        if text.trim().is_empty() {
            text = String::from_utf8_lossy(&output.stdout).into_owned();
        }
        return Err(text.chars().take(200).collect());
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

pub fn supports_virtual() -> bool {
    run(&["msg", "--help"])
        .or_else(|_| run(&["--help"]))
        .map(|help| help_supports_virtual(&help))
        .unwrap_or(false)
}

pub fn probe() -> Caps {
    Caps {
        virtual_create: supports_virtual(),
        outputs: parse_outputs(
            &run(&["msg", "--json", "outputs"])
                .ok()
                .and_then(|text| serde_json::from_str(&text).ok())
                .unwrap_or(Value::Null),
        ),
        dummy_connector: super::drm_dummy::candidate(),
    }
}

fn turn_on_output(name: &str) {
    let _ = run(&["msg", "output", name, "on"]);
}

fn wait_for_output(name: &str, timeout: Duration) -> Result<Caps, String> {
    let end = Instant::now() + timeout;
    let mut next_on = Instant::now();
    loop {
        if Instant::now() >= next_on {
            turn_on_output(name);
            next_on = Instant::now() + Duration::from_millis(250);
        }
        let caps = probe();
        if caps.outputs.iter().any(|output| output.name == name) {
            return Ok(caps);
        }
        if Instant::now() >= end {
            return Err("niri did not publish the extra display.".into());
        }
        std::thread::sleep(Duration::from_millis(40));
    }
}

fn create_virtual(name: &str) -> Result<(), String> {
    if run(&["msg", "create-virtual-output", "--name", name]).is_ok() {
        return Ok(());
    }
    run(&["msg", "create-virtual-output", name]).map(|_| ())
}

fn position_output(name: &str, caps: &Caps) -> Result<(), String> {
    let (x, y) = right_edge(&caps.outputs, name);
    run(&[
        "msg",
        "output",
        name,
        "position",
        "set",
        &x.to_string(),
        &y.to_string(),
    ])
    .map(|_| ())
}

fn match_primary_mode(name: &str, caps: &Caps) {
    let Some(primary) = caps.outputs.iter().find(|output| output.name != name) else {
        return;
    };
    let mode = format!("{}x{}@60", primary.width, primary.height);
    let _ = run(&["msg", "output", name, "custom-mode", &mode]);
}

pub fn ensure_extend() -> Result<ExtendTarget, String> {
    let caps = probe();
    if let Some(existing) = caps
        .outputs
        .iter()
        .find(|output| output.name == VIRTUAL_NAME)
    {
        let _ = position_output(&existing.name, &caps);
        return Ok(ExtendTarget {
            name: existing.name.clone(),
            owned: false,
            dummy: false,
        });
    }
    if caps.virtual_create {
        create_virtual(VIRTUAL_NAME)?;
        let caps = wait_for_output(VIRTUAL_NAME, Duration::from_millis(800))?;
        let _ = position_output(VIRTUAL_NAME, &caps);
        match_primary_mode(VIRTUAL_NAME, &caps);
        return Ok(ExtendTarget {
            name: VIRTUAL_NAME.into(),
            owned: true,
            dummy: false,
        });
    }
    if let Some(extra) = extra_physical(&caps.outputs) {
        return Ok(ExtendTarget {
            name: extra.name.clone(),
            owned: false,
            dummy: false,
        });
    }
    if let Some(name) = super::drm_dummy::candidate() {
        super::drm_dummy::enable(&name)?;
        match wait_for_output(&name, Duration::from_secs(8)) {
            Ok(caps) => {
                let _ = position_output(&name, &caps);
                match_primary_mode(&name, &caps);
                return Ok(ExtendTarget {
                    name,
                    owned: false,
                    dummy: true,
                });
            }
            Err(error) => {
                if super::drm_dummy::is_connected(&name) {
                    return Err(error);
                }
                let _ = super::drm_dummy::disable(&name);
                return Err(super::drm_dummy::disconnected_error(&name));
            }
        }
    }
    Err(EXTEND_UNAVAILABLE.into())
}

pub fn remove_virtual(name: &str) {
    if !valid_output_name(name) {
        return;
    }
    if run(&["msg", "remove-virtual-output", name]).is_ok() {
        return;
    }
    let _ = run(&["msg", "remove-virtual-output", "--name", name]);
}

pub fn set_dynamic_cast(name: &str) {
    if !valid_output_name(name) {
        return;
    }
    let _ = run(&["msg", "action", "set-dynamic-cast-monitor", name]);
}

pub fn current_casts() -> Value {
    run(&["msg", "--json", "casts"])
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or(Value::Null)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn outputs_skip_invalid_and_pick_physical_extra() {
        let outputs = parse_outputs(&json!({
            "eDP-1": {"logical": {"x": 0, "y": 0, "width": 1920, "height": 1080}},
            "HDMI-A-1": {"logical": {"x": 1920, "y": 0, "width": 1920, "height": 1080}},
            "bad name": {"logical": {"x": 0, "y": 0, "width": 800, "height": 600}},
            "off": {"logical": {"x": 0, "y": 0, "width": 0, "height": 0}}
        }));
        assert_eq!(
            outputs.iter().map(|o| o.name.as_str()).collect::<Vec<_>>(),
            ["eDP-1", "HDMI-A-1"]
        );
        assert_eq!(extra_physical(&outputs).unwrap().name, "HDMI-A-1");
        assert_eq!(right_edge(&outputs, VIRTUAL_NAME), (3840, 0));
    }

    #[test]
    fn planned_output_prefers_virtual_name() {
        let mut caps = Caps {
            virtual_create: true,
            outputs: parse_outputs(&json!({
                "eDP-1": {"logical": {"x": 0, "y": 0, "width": 1920, "height": 1080}},
                "HDMI-A-1": {"logical": {"x": 1920, "y": 0, "width": 1920, "height": 1080}}
            })),
            dummy_connector: None,
        };
        assert_eq!(caps.planned_output(), VIRTUAL_NAME);
        caps.virtual_create = false;
        assert_eq!(caps.planned_output(), "HDMI-A-1");
        caps.outputs.truncate(1);
        assert!(!caps.extend_available());
        assert_eq!(caps.planned_output(), "");
        caps.dummy_connector = Some("HDMI-A-1".into());
        assert!(caps.extend_available());
        assert_eq!(caps.planned_output(), "HDMI-A-1");
        assert_eq!(caps.extend_method(), "dummy");
    }

    #[test]
    fn casts_distinguish_dynamic_target_and_wrong_screen() {
        assert_eq!(
            match_casts(
                &json!([{"is_active": true, "is_dynamic_target": true, "target": {"Output": {"name": "eDP-1"}}}]),
                VIRTUAL_NAME
            ),
            CastMatch::Dynamic
        );
        assert_eq!(
            match_casts(
                &json!([{"is_active": true, "is_dynamic_target": false, "target": {"Output": {"name": "MacShell-AirPlay"}}}]),
                VIRTUAL_NAME
            ),
            CastMatch::Target
        );
        assert_eq!(
            match_casts(
                &json!([{"is_active": true, "is_dynamic_target": false, "target": {"Output": {"name": "eDP-1"}}}]),
                VIRTUAL_NAME
            ),
            CastMatch::Other
        );
    }

    #[test]
    fn virtual_help_and_output_names() {
        assert!(help_supports_virtual(
            "  create-virtual-output\n  remove-virtual-output"
        ));
        assert!(!help_supports_virtual("outputs\nwindows"));
        assert!(valid_output_name(VIRTUAL_NAME));
        assert!(!valid_output_name("eDP-1;rm"));
    }
}
