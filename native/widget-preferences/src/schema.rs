use macshell_preferences_store::{ReadGuard, Schema as StoreSchema};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::collections::HashSet;

const KINDS: [&str; 7] = [
    "weather",
    "calendar",
    "clock",
    "player",
    "activity",
    "batteries",
    "timer",
];
fn object() -> Value {
    json!({})
}
fn identifier(value: Option<&Value>, max: usize) -> bool {
    value
        .and_then(Value::as_str)
        .is_some_and(|s| !s.is_empty() && s.chars().count() <= max)
}
fn legacy_float_string(number: f64) -> String {
    let text = format!("{number:?}");
    let Some((mantissa, exponent)) = text.split_once('e') else {
        return text;
    };
    let Ok(exponent) = exponent.parse::<i32>() else {
        return text;
    };
    format!(
        "{mantissa}e{}{magnitude:02}",
        if exponent < 0 { '-' } else { '+' },
        magnitude = exponent.unsigned_abs()
    )
}
fn json_truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(value) => *value,
        Value::Number(_) => value.as_f64().is_some_and(|n| n != 0.0),
        Value::String(value) => !value.is_empty(),
        Value::Array(value) => !value.is_empty(),
        Value::Object(value) => !value.is_empty(),
    }
}
fn one_of(value: &Value, choices: &[&str]) -> bool {
    value.as_str().is_some_and(|s| choices.contains(&s))
}
fn style(kind: &str, value: &Value) -> bool {
    one_of(
        value,
        if matches!(kind, "clock" | "player") {
            &["liquid", "light", "dark"]
        } else {
            &["liquid", "normal"]
        },
    )
}
fn valid_origin(origin: &Value) -> bool {
    origin.is_object()
        && identifier(origin.get("name"), 200)
        && ["make", "model", "serial"].iter().all(|k| {
            origin.get(*k).map_or(true, |v| {
                v.as_str().is_some_and(|s| s.chars().count() <= 200)
            })
        })
        && ["width", "height"].iter().all(|k| {
            origin
                .get(*k)
                .and_then(Value::as_f64)
                .is_some_and(|n| n.is_finite() && n > 0.0 && n <= 100000.0)
        })
}
pub fn defaults() -> Value {
    let styles: Map<String, Value> = KINDS
        .iter()
        .map(|k| ((*k).into(), json!("liquid")))
        .collect();
    json!({"defaults":{"tempUnit":"C", "locMode":"auto", "cityName":"", "styles":styles, "mode":"auto"}, "desktopOutput":"", "outputs":{}, "bindings":{}, "widgets":[]})
}
fn migrate(source: &Value, origin: &Value) -> Value {
    let mut result = defaults();
    let Some(source) = source.as_object() else {
        return result;
    };
    result.as_object_mut().unwrap().extend(source.clone());
    let mut common: Map<String, Value> = source
        .iter()
        .filter(|(k, _)| !["widgets", "version", "revision", "values"].contains(&k.as_str()))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    for (k, v) in defaults()["defaults"].as_object().unwrap() {
        common.entry(k.clone()).or_insert_with(|| v.clone());
    }
    if let Some(global) = source
        .get("style")
        .and_then(Value::as_str)
        .filter(|_| !source.contains_key("styles"))
    {
        common.insert(
            "styles".into(),
            Value::Object(
                KINDS
                    .iter()
                    .map(|kind| {
                        (
                            (*kind).into(),
                            if style(kind, &json!(global)) {
                                json!(global)
                            } else {
                                json!("liquid")
                            },
                        )
                    })
                    .collect(),
            ),
        );
    }
    result["defaults"] = Value::Object(common);
    let records = source.get("widgets").cloned().unwrap_or_else(|| json!([]));
    let Some(records) = records.as_array().filter(|v| v.len() <= 256) else {
        result["widgets"] = records;
        return result;
    };
    if records.is_empty() || !valid_origin(origin) {
        result["widgets"] = json!([]);
        return result;
    }
    let name = origin["name"].as_str().unwrap();
    let identity = json!({"connector":name,"make":origin.get("make").and_then(Value::as_str).unwrap_or(""),"model":origin.get("model").and_then(Value::as_str).unwrap_or(""),"serial":origin.get("serial").and_then(Value::as_str).unwrap_or("")});
    let profile = format!("legacy-{:x}", Sha256::digest(name.as_bytes()))[..23].to_owned();
    result["desktopOutput"] = json!(profile);
    result["outputs"] = json!({profile.clone(): {"identity":identity}});
    result["bindings"] = json!({name: profile.clone()});
    let width = origin["width"].as_f64().unwrap();
    let columns = ((width - 14.0) / 207.0).floor().max(1.0);
    let left =
        21.0 + ((width - 42.0 - columns * 179.0 - (columns - 1.0) * 28.0).max(0.0) / 2.0).floor();
    let mut used = HashSet::new();
    let mut migrated = Vec::new();
    for (index, record) in records.iter().enumerate() {
        let Some(mut item) = record.as_object().cloned() else {
            migrated.push(record.clone());
            continue;
        };
        let old = item.get("id");
        let mut ident = if identifier(old, 100) {
            old.unwrap().as_str().unwrap().to_owned()
        } else {
            format!("w{index}")
        };
        if let Some(number) = old
            .filter(|v| v.is_number())
            .and_then(Value::as_f64)
            .filter(|n| n.is_finite() && *n != 0.0)
        {
            let original = old.unwrap();
            let text = original.to_string();
            ident = if text
                .trim_start_matches('-')
                .bytes()
                .all(|b| b.is_ascii_digit())
            {
                text
            } else {
                legacy_float_string(number)
            };
        }
        let mut suffix = 1;
        let mut ambiguous_id = false;
        while used.contains(&ident) {
            suffix += 1;
            let base = match old {
                Some(Value::String(s)) if !s.is_empty() => s.clone(),
                Some(Value::Bool(true)) => "True".to_owned(),
                Some(v @ Value::Number(_)) if json_truthy(v) => {
                    let text = v.to_string();
                    if text
                        .trim_start_matches('-')
                        .bytes()
                        .all(|b| b.is_ascii_digit())
                    {
                        text
                    } else {
                        v.as_f64().map(legacy_float_string).unwrap_or(text)
                    }
                }
                Some(v @ (Value::Array(_) | Value::Object(_))) if json_truthy(v) => {
                    // Python's repr of composite IDs is not a JSON encoding.
                    // Refuse automatic migration instead of changing an ID.
                    ambiguous_id = true;
                    format!("w{index}")
                }
                _ => format!("w{index}"),
            };
            ident = format!("{}-{suffix}", base.chars().take(80).collect::<String>());
        }
        if old.is_some_and(|value| !value.is_null() && value != &json!(ident)) {
            item.insert("legacyId".into(), old.unwrap().clone());
        }
        used.insert(ident.clone());
        if ["version", "output", "position", "settings"]
            .iter()
            .any(|k| item.contains_key(*k))
        {
            item.insert("legacyRecord".into(), record.clone());
        }
        item.insert(
            "id".into(),
            if ambiguous_id {
                Value::Null
            } else {
                json!(ident)
            },
        );
        item.insert("version".into(), json!(1));
        item.insert("output".into(), json!(profile));
        if let Some(kind) = item
            .get("type")
            .and_then(Value::as_str)
            .filter(|k| KINDS.contains(k))
            .map(str::to_owned)
        {
            let inherited = result["defaults"]["styles"]
                .get(&kind)
                .cloned()
                .unwrap_or_else(|| json!("liquid"));
            let chosen = item.get("style").unwrap_or(&inherited);
            let chosen = if style(&kind, chosen) {
                chosen.clone()
            } else {
                json!("liquid")
            };
            let size = item
                .get("size")
                .filter(|v| one_of(v, &["small", "medium", "large"]))
                .cloned()
                .unwrap_or_else(|| json!("small"));
            let mode = item
                .get("mode")
                .filter(|v| one_of(v, &["light", "dark"]))
                .cloned()
                .unwrap_or_else(|| json!("auto"));
            let mut settings = item
                .get("settings")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default();
            settings.insert("style".into(), chosen);
            settings.insert("size".into(), size);
            settings.insert("mode".into(), mode);
            item.insert("settings".into(), Value::Object(settings));
            let coordinate = |key: &str, offset: f64, pitch: f64| -> u64 {
                let number = item
                    .get(key)
                    .and_then(Value::as_f64)
                    .filter(|n| n.is_finite())
                    .unwrap_or(0.0);
                (((number - offset) / pitch + 0.5).floor().clamp(0.0, 4096.0)) as u64
            };
            item.insert(
                "position".into(),
                json!({"column":coordinate("x",left,207.0), "row":coordinate("y",56.0,202.0)}),
            );
        }
        migrated.push(Value::Object(item));
    }
    result["widgets"] = Value::Array(migrated);
    result
}
fn valid_appearance(value: &Value) -> bool {
    let Some(obj) = value.as_object() else {
        return false;
    };
    obj.iter().all(|(key, v)| match key.as_str() {
        "theme" => one_of(v, &["auto", "light", "dark"]),
        "fontFamily" => v.as_str().is_some_and(|s| {
            !s.trim().is_empty() && s.chars().count() <= 100 && s.chars().all(|c| c as u32 >= 32)
        }),
        "textScale" => v
            .as_f64()
            .is_some_and(|n| n.is_finite() && (0.9..=1.2).contains(&n)),
        "density" => one_of(v, &["compact", "comfortable"]),
        "tint" => v.as_str().is_some_and(|s| {
            s.len() == 7
                && s.starts_with('#')
                && s.as_bytes()[1..].iter().all(u8::is_ascii_hexdigit)
        }),
        "secondsMode" => one_of(v, &["smooth", "tick", "hidden"]),
        _ => true,
    })
}
fn valid_activity(value: &Value) -> bool {
    if !value.is_object() {
        return false;
    }
    let default = json!(["cpu", "memory", "network", "disk"]);
    let metrics = value.get("metrics").unwrap_or(&default);
    metrics.as_array().is_some_and(|items| {
        let mut seen = HashSet::new();
        (1..=4).contains(&items.len())
            && items.iter().all(|v| {
                v.as_str().is_some_and(|s| {
                    ["cpu", "memory", "network", "disk"].contains(&s) && seen.insert(s)
                })
            })
    }) && one_of(
        value.get("view").unwrap_or(&json!("rings")),
        &["rings", "graphs"],
    )
}
fn valid_batteries(value: &Value) -> bool {
    if !value.is_object()
        || !one_of(
            value.get("mode").unwrap_or(&json!("auto")),
            &["auto", "selected"],
        )
    {
        return false;
    }
    let empty = json!([]);
    value
        .get("devices")
        .unwrap_or(&empty)
        .as_array()
        .is_some_and(|items| {
            let mut seen = HashSet::new();
            items.len() <= 16
                && items.iter().all(|v| {
                    v.as_str().is_some_and(|s| {
                        let bt = s.strip_prefix("bluetooth:").is_some_and(|addr| {
                            addr.len() == 17
                                && addr.split(':').count() == 6
                                && addr.split(':').all(|part| {
                                    part.len() == 2
                                        && part.bytes().all(|b| {
                                            b.is_ascii_digit() || (b'A'..=b'F').contains(&b)
                                        })
                                })
                        });
                        let path =
                            s.strip_prefix("bluetooth-path:/org/bluez/")
                                .is_some_and(|path| {
                                    !path.is_empty()
                                        && path.bytes().all(|b| {
                                            b.is_ascii_alphanumeric() || b == b'_' || b == b'/'
                                        })
                                });
                        s.chars().count() <= 200 && (s == "laptop" || bt || path) && seen.insert(s)
                    })
                })
        })
}
fn valid_timer(value: &Value) -> bool {
    if !value.is_object() {
        return false;
    }
    let default = json!([5, 15, 25]);
    value
        .get("presets")
        .unwrap_or(&default)
        .as_array()
        .is_some_and(|v| {
            v.len() == 3
                && v.iter()
                    .all(|x| x.as_u64().is_some_and(|n| (1..=1440).contains(&n)))
        })
}
fn normalize(source: &Value) -> (Value, Map<String, Value>) {
    let mut values = source.as_object().cloned().unwrap_or_default();
    let mut errors = Map::new();
    if values.get("enabled").is_some_and(|v| !v.is_boolean()) {
        errors.insert(
            "enabled".into(),
            json!("Widget visibility must be true or false."),
        );
        values.insert("enabled".into(), json!(false));
    }
    let mut common = match values.get("defaults") {
        None => Map::new(),
        Some(v) => match v.as_object() {
            Some(o) => o.clone(),
            None => {
                errors.insert("defaults".into(), json!("Invalid common widget settings."));
                Map::new()
            }
        },
    };
    let baseline = defaults();
    for (key, allowed) in [
        ("tempUnit", &["C", "F"][..]),
        ("locMode", &["auto", "city"][..]),
        ("mode", &["auto", "light", "dark"][..]),
    ] {
        if common.get(key).is_some_and(|v| !one_of(v, allowed)) {
            errors.insert(
                key.into(),
                json!(format!("Invalid common widget setting: {key}")),
            );
            common.insert(key.into(), baseline["defaults"][key].clone());
        }
        common
            .entry(key)
            .or_insert_with(|| baseline["defaults"][key].clone());
    }
    if common
        .get("cityName")
        .is_some_and(|v| !v.as_str().is_some_and(|s| s.chars().count() <= 200))
    {
        errors.insert(
            "cityName".into(),
            json!("City name must be at most 200 characters."),
        );
        common.insert("cityName".into(), json!(""));
    }
    common.entry("cityName").or_insert_with(|| json!(""));
    let mut styles = match common.get("styles") {
        None => Map::new(),
        Some(v) => match v.as_object() {
            Some(o) => o.clone(),
            None => {
                errors.insert("styles".into(), json!("Invalid default widget styles."));
                Map::new()
            }
        },
    };
    for kind in KINDS {
        if styles.get(kind).is_some_and(|v| !style(kind, v)) {
            errors.insert("styles".into(), json!("Unsupported default widget style."));
            styles.insert(kind.into(), json!("liquid"));
        }
        styles.entry(kind).or_insert_with(|| json!("liquid"));
    }
    common.insert("styles".into(), Value::Object(styles));
    values.insert("defaults".into(), Value::Object(common));
    let empty = object();
    let profiles = values
        .get("outputs")
        .unwrap_or(&empty)
        .as_object()
        .filter(|o| o.len() <= 64);
    let mut valid_profiles = Map::new();
    if let Some(profiles) = profiles {
        for (key, profile) in profiles {
            let identity = profile.get("identity");
            let valid = !key.is_empty()
                && key.chars().count() <= 100
                && identity.is_some_and(Value::is_object)
                && identifier(identity.and_then(|i| i.get("connector")), 200)
                && ["make", "model", "serial"].iter().all(|field| {
                    identity.and_then(|i| i.get(*field)).map_or(true, |v| {
                        v.as_str().is_some_and(|s| s.chars().count() <= 200)
                    })
                });
            if valid {
                valid_profiles.insert(key.clone(), profile.clone());
            } else {
                errors.insert(
                    "outputs".into(),
                    json!("A widget display profile needs a valid device identity."),
                );
            }
        }
    } else {
        errors.insert(
            "outputs".into(),
            json!("At most 64 widget display profiles are supported."),
        );
    }
    let bindings = values.get("bindings").unwrap_or(&empty);
    if !bindings.as_object().is_some_and(|o| {
        o.len() <= 64
            && o.iter().all(|(k, v)| {
                !k.is_empty()
                    && k.chars().count() <= 200
                    && v.as_str().is_some_and(|s| valid_profiles.contains_key(s))
            })
    }) {
        errors.insert(
            "bindings".into(),
            json!("Widget display bindings must refer to saved profiles."),
        );
        values.insert("bindings".into(), object());
    } else {
        values.insert("bindings".into(), bindings.clone());
    }
    let desktop = values
        .get("desktopOutput")
        .cloned()
        .unwrap_or_else(|| json!(""));
    if !desktop
        .as_str()
        .is_some_and(|s| s.is_empty() || valid_profiles.contains_key(s))
    {
        errors.insert(
            "desktopOutput".into(),
            json!("The desktop must refer to a saved widget display."),
        );
        values.insert("desktopOutput".into(), json!(""));
    } else {
        values.insert("desktopOutput".into(), desktop);
    }
    values.insert("outputs".into(), Value::Object(valid_profiles.clone()));
    let empty_records = json!([]);
    let records = values
        .get("widgets")
        .unwrap_or(&empty_records)
        .as_array()
        .filter(|a| a.len() <= 256);
    let mut validated = Vec::new();
    let mut seen = HashSet::new();
    if let Some(records) = records {
        for record in records {
            let id = record.get("id").and_then(Value::as_str).unwrap_or("");
            let kind = record.get("type").and_then(Value::as_str).unwrap_or("");
            let version = record
                .get("version")
                .filter(|v| v.is_number())
                .map(Value::to_string);
            let valid_version = version.as_deref().is_some_and(|s| {
                !s.is_empty()
                    && s.bytes().all(|b| b.is_ascii_digit())
                    && s.bytes().any(|b| b != b'0')
            });
            let mut valid = record.is_object()
                && identifier(record.get("id"), 100)
                && !seen.contains(id)
                && identifier(record.get("type"), 100)
                && valid_version;
            if valid {
                seen.insert(id.to_owned());
            }
            if valid && version.as_deref() == Some("1") && KINDS.contains(&kind) {
                let settings = record.get("settings").unwrap_or(&empty);
                let position = record.get("position").unwrap_or(&Value::Null);
                valid = record
                    .get("output")
                    .and_then(Value::as_str)
                    .is_some_and(|s| valid_profiles.contains_key(s))
                    && settings.is_object()
                    && position.is_object()
                    && ["column", "row"].iter().all(|k| {
                        position
                            .get(*k)
                            .and_then(Value::as_u64)
                            .is_some_and(|v| v <= 4096)
                    })
                    && style(kind, settings.get("style").unwrap_or(&json!("liquid")))
                    && one_of(
                        settings.get("size").unwrap_or(&json!("small")),
                        &["small", "medium", "large"],
                    )
                    && one_of(
                        settings.get("mode").unwrap_or(&json!("auto")),
                        &["auto", "light", "dark"],
                    )
                    && valid_appearance(settings.get("appearance").unwrap_or(&empty));
                valid &= match kind {
                    "activity" => valid_activity(settings.get("activity").unwrap_or(&empty)),
                    "batteries" => valid_batteries(settings.get("batteries").unwrap_or(&empty)),
                    "timer" => valid_timer(settings.get("timer").unwrap_or(&empty)),
                    _ => true,
                };
            }
            if valid {
                validated.push(record.clone());
            } else {
                errors.insert("widgets".into(),json!("Invalid widget instance, duplicate ID, position or settings. Restore a backup or reset widgets."));
            }
        }
    } else {
        errors.insert(
            "widgets".into(),
            json!("At most 256 widget instances are supported."),
        );
    }
    values.insert("widgets".into(), Value::Array(validated));
    (Value::Object(values), errors)
}
pub struct Schema {
    defaults: Map<String, Value>,
    pub origin: Value,
}
impl Schema {
    pub fn new() -> Self {
        Self {
            defaults: defaults().as_object().unwrap().clone(),
            origin: object(),
        }
    }
}
impl StoreSchema for Schema {
    fn version(&self) -> u64 {
        1
    }
    fn label(&self) -> &str {
        "Widget"
    }
    fn defaults(&self) -> &Map<String, Value> {
        &self.defaults
    }
    fn optional_keys(&self) -> &[&str] {
        &["enabled"]
    }
    fn source_values(&self, source: &Value, version: u64) -> Value {
        if version == 0 {
            migrate(source, &self.origin)
        } else {
            source.clone()
        }
    }
    fn normalize(&self, source: &Value, _: bool) -> (Value, Map<String, Value>) {
        normalize(source)
    }
    fn read_guard(&self, source: &Value, version: u64, repair: bool) -> Option<ReadGuard> {
        if waiting(source, version, &self.origin) {
            Some(ReadGuard {
                notice: "Connect a display to bind the existing desktop widgets before editing."
                    .into(),
                can_recover: false,
            })
        } else if repair {
            Some(ReadGuard { notice:"Some saved widget records are invalid. Restore a backup or reset widgets; the original file will be kept.".into(),can_recover:true })
        } else {
            None
        }
    }
    fn state_fields(&self, source: &Value, version: u64) -> Map<String, Value> {
        json!({"awaitingDisplay":waiting(source,version,&self.origin)})
            .as_object()
            .unwrap()
            .clone()
    }
}
fn waiting(source: &Value, version: u64, origin: &Value) -> bool {
    let widgets = source.get("widgets");
    version == 0
        && widgets.is_some_and(|v| match v {
            Value::Null => false,
            Value::Bool(b) => *b,
            Value::String(s) => !s.is_empty(),
            Value::Array(a) => !a.is_empty(),
            Value::Object(o) => !o.is_empty(),
            Value::Number(_) => v.as_f64().is_some_and(|n| n != 0.0),
        })
        && !valid_origin(origin)
}
