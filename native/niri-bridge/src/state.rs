// SPDX-License-Identifier: MIT
use indexmap::IndexMap;
use serde_json::{json, Map, Value};

#[derive(Default)]
pub struct State {
    windows: IndexMap<String, Value>,
    workspaces: IndexMap<String, Value>,
    pub outputs: Map<String, Value>,
    keyboard: Option<Value>,
    overview: bool,
}

#[derive(Debug, PartialEq)]
pub enum Change {
    Full,
    Title(String, String),
}

fn id(value: &Value) -> String {
    value.to_string()
}
fn number(v: Option<&Value>, fallback: f64) -> f64 {
    v.and_then(Value::as_f64).unwrap_or(fallback)
}
fn pair(v: Option<&Value>, default: [f64; 2]) -> [f64; 2] {
    let Some(a) = v.and_then(Value::as_array) else {
        return default;
    };
    [number(a.first(), default[0]), number(a.get(1), default[1])]
}
fn truth(value: Option<&Value>) -> bool {
    value.and_then(Value::as_bool).unwrap_or(false)
}
fn populated(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(value) => *value,
        Value::Number(value) => value.as_f64().is_some_and(|x| x != 0.0),
        Value::String(value) => !value.is_empty(),
        Value::Array(value) => !value.is_empty(),
        Value::Object(value) => !value.is_empty(),
    }
}
fn string(value: Option<&Value>) -> &str {
    value.and_then(Value::as_str).unwrap_or("")
}
fn array(value: Option<&Value>) -> &[Value] {
    value
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}
fn set(object: &mut Value, key: &str, value: Value) {
    if let Some(map) = object.as_object_mut() {
        map.insert(key.into(), value);
    }
}

impl State {
    pub fn apply(&mut self, event: &Value) -> Result<Change, String> {
        let (name, data) = event
            .as_object()
            .and_then(|m| m.iter().next())
            .ok_or("invalid event")?;
        match name.as_str() {
            "WindowsChanged" => {
                self.windows.clear();
                for item in array(data.get("windows")) {
                    let key = id(item.get("id").ok_or("window without id")?);
                    self.windows.insert(key, item.clone());
                }
            }
            "WindowOpenedOrChanged" => {
                let window = data.get("window").ok_or("missing window")?;
                let key = id(window.get("id").ok_or("window without id")?);
                if let Some(previous) = self.windows.get(&key) {
                    let a = previous.as_object().ok_or("invalid window")?;
                    let b = window.as_object().ok_or("invalid window")?;
                    if a.len() == b.len()
                        && a.keys().all(|k| b.contains_key(k))
                        && a.iter().all(|(k, v)| k == "title" || b.get(k) == Some(v))
                    {
                        self.windows.insert(key.clone(), window.clone());
                        return Ok(Change::Title(key, string(window.get("title")).into()));
                    }
                }
                if truth(window.get("is_focused")) {
                    for existing in self.windows.values_mut() {
                        set(existing, "is_focused", json!(false));
                    }
                }
                self.windows.insert(key, window.clone());
            }
            "WindowClosed" => {
                self.windows
                    .shift_remove(&id(data.get("id").unwrap_or(&Value::Null)));
            }
            "WindowFocusChanged" => {
                let focused = data.get("id").unwrap_or(&Value::Null);
                for window in self.windows.values_mut() {
                    let is_focused = window.get("id") == Some(focused);
                    set(window, "is_focused", json!(is_focused));
                }
            }
            "WindowLayoutsChanged" => {
                for change in array(data.get("changes")) {
                    if let Some(pair) = change.as_array() {
                        if let (Some(wid), Some(layout)) = (pair.first(), pair.get(1)) {
                            if let Some(window) = self.windows.get_mut(&id(wid)) {
                                set(window, "layout", layout.clone());
                            }
                        }
                    }
                }
            }
            "WindowUrgencyChanged" | "WindowFocusTimestampChanged" => {
                let key = id(data.get("id").unwrap_or(&Value::Null));
                if let Some(window) = self.windows.get_mut(&key) {
                    let field = if name == "WindowUrgencyChanged" {
                        "is_urgent"
                    } else {
                        "focus_timestamp"
                    };
                    let input = if name == "WindowUrgencyChanged" {
                        "urgent"
                    } else {
                        field
                    };
                    set(
                        window,
                        field,
                        data.get(input).cloned().unwrap_or(Value::Null),
                    );
                }
            }
            "WorkspacesChanged" => {
                self.workspaces.clear();
                for workspace in array(data.get("workspaces")) {
                    let key = id(workspace.get("id").ok_or("workspace without id")?);
                    self.workspaces.insert(key, workspace.clone());
                }
            }
            "WorkspaceActivated" => {
                let key = id(data.get("id").unwrap_or(&Value::Null));
                if let Some(target) = self.workspaces.get(&key) {
                    let output = target.get("output").cloned().unwrap_or(Value::Null);
                    for workspace in self.workspaces.values_mut() {
                        if workspace.get("output").unwrap_or(&Value::Null) == &output {
                            let active = id(workspace.get("id").unwrap_or(&Value::Null)) == key;
                            set(workspace, "is_active", json!(active));
                        }
                        if truth(data.get("focused")) {
                            let focused = id(workspace.get("id").unwrap_or(&Value::Null)) == key;
                            set(workspace, "is_focused", json!(focused));
                        }
                    }
                }
            }
            "WorkspaceActiveWindowChanged" | "WorkspaceUrgencyChanged" => {
                let key_name = if name == "WorkspaceActiveWindowChanged" {
                    "workspace_id"
                } else {
                    "id"
                };
                let field = if name == "WorkspaceActiveWindowChanged" {
                    "active_window_id"
                } else {
                    "is_urgent"
                };
                if let Some(workspace) = self
                    .workspaces
                    .get_mut(&id(data.get(key_name).unwrap_or(&Value::Null)))
                {
                    let input = if name == "WorkspaceUrgencyChanged" {
                        "urgent"
                    } else {
                        field
                    };
                    set(
                        workspace,
                        field,
                        data.get(input).cloned().unwrap_or(Value::Null),
                    );
                }
            }
            "KeyboardLayoutsChanged" => {
                self.keyboard = Some(data.get("keyboard_layouts").cloned().unwrap_or(Value::Null))
            }
            "KeyboardLayoutSwitched" => {
                let mut keyboard = self
                    .keyboard
                    .take()
                    .unwrap_or_else(|| json!({"names":[],"current_idx":0}));
                set(
                    &mut keyboard,
                    "current_idx",
                    data.get("idx").cloned().unwrap_or(Value::Null),
                );
                self.keyboard = Some(keyboard);
            }
            "OverviewOpenedOrClosed" => self.overview = truth(data.get("is_open")),
            _ => (),
        }
        Ok(Change::Full)
    }

    pub fn snapshot(&self) -> Value {
        let mut names: Vec<_> = self.outputs.keys().collect();
        names.sort();
        let mut monitors = Vec::new();
        // The index follows all sorted outputs, including disconnected ones, as in Python enumerate().
        for (index, name) in names.into_iter().enumerate() {
            let output = &self.outputs[name];
            let Some(logical) = output.get("logical").filter(|x| populated(x)) else {
                continue;
            };
            let scale = number(logical.get("scale"), 1.0);
            let width = number(logical.get("width"), 0.0);
            let height = number(logical.get("height"), 0.0);
            let modes = array(output.get("modes"));
            let index_mode = output.get("current_mode").and_then(Value::as_i64);
            let mode = index_mode
                .and_then(|i| {
                    if i < 0 {
                        modes.len().checked_sub(i.unsigned_abs() as usize)
                    } else {
                        Some(i as usize)
                    }
                })
                .and_then(|i| modes.get(i))
                .unwrap_or(&Value::Null);
            let active = self
                .workspaces
                .values()
                .find(|w| string(w.get("output")) == name && truth(w.get("is_active")))
                .unwrap_or(&Value::Null);
            let idx = active.get("idx").cloned().unwrap_or(Value::Null);
            let active_name = active
                .get("name")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .unwrap_or_else(|| {
                    if idx.is_null() {
                        String::new()
                    } else {
                        idx.to_string()
                    }
                });
            let available: Vec<_> = modes
                .iter()
                .map(|m| {
                    format!(
                        "{}x{}@{:.3}",
                        number(m.get("width"), 0.0) as i64,
                        number(m.get("height"), 0.0) as i64,
                        number(m.get("refresh_rate"), 0.0) / 1000.0
                    )
                })
                .collect();
            monitors.push(json!({
                "make": output.get("make").cloned().unwrap_or(Value::Null), "model": output.get("model").cloned().unwrap_or(Value::Null),
                "serial": output.get("serial").cloned().unwrap_or(Value::Null), "id": index, "name": name,
                "x": logical.get("x").cloned().unwrap_or(json!(0)), "y": logical.get("y").cloned().unwrap_or(json!(0)),
                "logicalRect": {"x": logical.get("x"), "y": logical.get("y"), "width":logical.get("width"), "height":logical.get("height")},
                "transform": logical.get("transform").cloned().unwrap_or(json!("Normal")),
                "pixelWidth": mode.get("width").cloned().unwrap_or(json!((width*scale).round_ties_even() as i64)),
                "pixelHeight": mode.get("height").cloned().unwrap_or(json!((height*scale).round_ties_even() as i64)),
                "width": (width*scale).round_ties_even() as i64, "height": (height*scale).round_ties_even() as i64, "scale": scale,
                "modeWidth": mode.get("width").cloned().unwrap_or(json!(width)), "modeHeight": mode.get("height").cloned().unwrap_or(json!(height)),
                "refreshRate": number(mode.get("refresh_rate"), 60000.0)/1000.0, "availableModes": available,
                "activeWorkspace": {"id":active.get("id").cloned().unwrap_or(json!(-1)), "name":active_name},
                "specialWorkspace":{"id":0}, "focused":truth(active.get("is_focused"))
            }));
        }
        for monitor in &mut monitors {
            for key in ["make", "model", "serial"] {
                if monitor.get(key).is_some_and(Value::is_null) {
                    set(monitor, key, json!(""));
                }
            }
        }
        let mut windows = Vec::new();
        for window in self.windows.values() {
            let workspace = self
                .workspaces
                .get(&id(window.get("workspace_id").unwrap_or(&Value::Null)))
                .unwrap_or(&Value::Null);
            let output_name = string(workspace.get("output"));
            let monitor = monitors
                .iter()
                .find(|m| string(m.get("name")) == output_name)
                .unwrap_or(&Value::Null);
            let output = self.outputs.get(output_name).unwrap_or(&Value::Null);
            let logical = output.get("logical").unwrap_or(&Value::Null);
            let layout = window.get("layout").unwrap_or(&Value::Null);
            let position = layout
                .get("tile_pos_in_workspace_view")
                .filter(|v| !v.is_null());
            let pos = pair(position, [0.0, 0.0]);
            let offset = pair(layout.get("window_offset_in_tile"), [0.0, 0.0]);
            let size_value = layout
                .get("window_size")
                .filter(|v| populated(v))
                .or_else(|| layout.get("tile_size").filter(|v| populated(v)))
                .cloned()
                .unwrap_or(json!([0, 0]));
            let size = pair(Some(&size_value), [0.0, 0.0]);
            let full = position.is_some()
                && (pos[0] + offset[0]).abs() < 2.0
                && (pos[1] + offset[1]).abs() < 2.0
                && (size[0] - number(logical.get("width"), 0.0)).abs() < 2.0
                && (size[1] - number(logical.get("height"), 0.0)).abs() < 2.0;
            let fullscreen = window
                .get("is_fullscreen")
                .and_then(|v| {
                    v.as_bool()
                        .map(i32::from)
                        .or_else(|| v.as_i64().map(|x| x as i32))
                })
                .unwrap_or(i32::from(full));
            let workspace_idx = workspace.get("idx").cloned().unwrap_or(Value::Null);
            let workspace_name = workspace
                .get("name")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .unwrap_or_else(|| {
                    if workspace_idx.is_null() {
                        String::new()
                    } else {
                        workspace_idx.to_string()
                    }
                });
            let mut result = window.clone();
            for (key, value) in [
                (
                    "address",
                    json!(id(window.get("id").unwrap_or(&Value::Null))),
                ),
                ("class", json!(string(window.get("app_id")))),
                ("pid", window.get("pid").cloned().unwrap_or(json!(0))),
                (
                    "workspace",
                    json!({"id":workspace.get("id").cloned().unwrap_or(json!(-1)),"name":workspace_name}),
                ),
                ("output", json!(output_name)),
                ("monitor", monitor.get("id").cloned().unwrap_or(json!(-1))),
                (
                    "at",
                    json!([
                        pos[0] + offset[0] + number(monitor.get("x"), 0.0),
                        pos[1] + offset[1] + number(monitor.get("y"), 0.0)
                    ]),
                ),
                ("size", size_value),
                ("geometryKnown", json!(position.is_some())),
                ("workspaceActive", json!(truth(workspace.get("is_active")))),
                ("mapped", json!(true)),
                (
                    "hidden",
                    json!(!truth(workspace.get("is_active")) || position.is_none()),
                ),
                (
                    "floating",
                    window.get("is_floating").cloned().unwrap_or(json!(false)),
                ),
                ("fullscreen", json!(fullscreen)),
                (
                    "focusHistoryID",
                    json!(if truth(window.get("is_focused")) {
                        0
                    } else {
                        1
                    }),
                ),
            ] {
                set(&mut result, key, value);
            }
            windows.push(result);
        }
        json!({"monitors":monitors,"windows":windows,"workspaces":self.workspaces.values().cloned().collect::<Vec<_>>(),
               "keyboard":self.keyboard.clone().unwrap_or_else(||json!({"names":[],"current_idx":0})),"overview":self.overview})
    }
}
