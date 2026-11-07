use serde_json::{json, Map, Value};
use std::collections::HashSet;

fn nonnegative_integer(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .or_else(|| value.as_i64().and_then(|value| u64::try_from(value).ok()))
}

pub struct Schema {
    pub catalog: Vec<Value>,
    pub defaults: Map<String, Value>,
}

impl Schema {
    pub fn new() -> Self {
        let catalog: Value =
            serde_json::from_str(include_str!("../../../MacShell/bar_catalog.json"))
                .expect("valid bundled bar catalog");
        let catalog = catalog["blocks"]
            .as_array()
            .expect("bar catalog blocks")
            .clone();
        let mut result = Self {
            catalog,
            defaults: Map::new(),
        };
        result.defaults = result.make_defaults(&Value::Null);
        result
    }

    pub fn make_defaults(&self, legacy: &Value) -> Map<String, Value> {
        let mut common = Vec::new();
        let enabled = legacy.get("barWidgets").and_then(Value::as_array);
        for block in &self.catalog {
            let kind = block["type"].as_str().unwrap();
            if kind == "spacer" {
                continue;
            }
            let mut on = if let Some(enabled) = enabled {
                matches!(kind, "tray" | "search" | "battery")
                    || enabled.iter().any(|item| item.as_str() == Some(kind))
            } else {
                true
            };
            if kind == "privacy" {
                on = on
                    && legacy.get("ccEnabled") != Some(&Value::Bool(false))
                    && enabled.is_none_or(|items| {
                        items
                            .iter()
                            .any(|item| item.as_str() == Some("controlCenter"))
                    });
            }
            if matches!(kind, "tray" | "search") {
                on = legacy.get(if kind == "tray" {
                    "showTray"
                } else {
                    "showSearch"
                }) != Some(&Value::Bool(false));
            }
            common.push(json!({"id":kind, "type":kind, "zone":block["zone"], "enabled":on, "priority":block["priority"]}));
        }
        json!({"common":common, "outputs":{}, "bindings":{}})
            .as_object()
            .unwrap()
            .clone()
    }

    fn layout(
        &self,
        items: Option<&Value>,
        key: &str,
        default: &Value,
        strict: bool,
        errors: &mut Map<String, Value>,
    ) -> Value {
        let Some(items) = items
            .and_then(Value::as_array)
            .filter(|items| items.len() <= 64)
        else {
            errors.insert(
                key.into(),
                json!("A layout must contain at most 64 blocks."),
            );
            return default.clone();
        };
        let mut result = Vec::new();
        let mut ids = HashSet::new();
        let mut types = HashSet::new();
        for item in items {
            let object = item.as_object();
            let ident = item.get("id").and_then(Value::as_str).unwrap_or("");
            let kind = item.get("type").and_then(Value::as_str).unwrap_or("");
            let catalog = self
                .catalog
                .iter()
                .find(|block| block["type"].as_str() == Some(kind));
            let priority_default = catalog
                .map(|entry| &entry["priority"])
                .cloned()
                .unwrap_or_else(|| json!(50));
            let priority = item.get("priority").unwrap_or(&priority_default);
            let zone = item.get("zone").and_then(Value::as_str);
            let valid = object.is_some()
                && !ident.is_empty()
                && ident.chars().count() <= 100
                && !ids.contains(ident)
                && !kind.is_empty()
                && kind.chars().count() <= 100
                && matches!(zone, Some("left" | "center" | "right"))
                && item.get("enabled").is_some_and(Value::is_boolean)
                && nonnegative_integer(priority).is_some_and(|value| value <= 100)
                && (catalog.is_none() || kind == "spacer" || !types.contains(kind));
            if !valid {
                errors.insert(key.into(), json!("Block IDs must be unique; singleton blocks cannot be duplicated. Check zone, visibility and priority."));
                if !strict {
                    return default.clone();
                }
                continue;
            }
            ids.insert(ident.to_owned());
            types.insert(kind.to_owned());
            let mut value = item.clone();
            value["priority"] = json!(nonnegative_integer(priority).unwrap());
            if kind == "spacer" {
                let width = item.get("width").cloned().unwrap_or_else(|| json!(16));
                if let Some(width) = nonnegative_integer(&width).filter(|width| *width <= 240) {
                    value["width"] = json!(width);
                } else {
                    errors.insert(key.into(), json!("Spacer width must be between 0 and 240."));
                    value["width"] = json!(16);
                }
            }
            result.push(value);
        }
        Value::Array(result)
    }

    fn normalize_impl(&self, source: &Value, strict: bool) -> (Value, Map<String, Value>) {
        let mut values = source.as_object().cloned().unwrap_or_default();
        let mut errors = Map::new();
        let default_common = &self.defaults["common"];
        let common = self.layout(
            values.get("common").or(Some(default_common)),
            "common",
            default_common,
            strict,
            &mut errors,
        );
        values.insert("common".into(), common.clone());
        let empty = json!({});
        let outputs = values.get("outputs").unwrap_or(&empty);
        let profiles = outputs.as_object().filter(|outputs| outputs.len() <= 64);
        let mut valid_profiles = Map::new();
        if let Some(profiles) = profiles {
            for (ident, profile) in profiles {
                if ident.is_empty() || ident.chars().count() > 100 || !profile.is_object() {
                    errors.insert("outputs".into(), json!("Invalid saved display profile."));
                    continue;
                }
                let identity = profile.get("identity");
                let connector = identity
                    .and_then(|value| value.get("connector"))
                    .and_then(Value::as_str);
                let valid = identity.is_some_and(Value::is_object)
                    && connector.is_some_and(|value| !value.is_empty())
                    && ["connector", "make", "model", "serial"]
                        .iter()
                        .all(|field| {
                            identity
                                .and_then(|value| value.get(*field))
                                .map_or(Some(""), Value::as_str)
                                .is_some_and(|text| text.chars().count() <= 200)
                        });
                if !valid {
                    errors.insert(
                        "outputs".into(),
                        json!("A display profile needs a connector and valid device details."),
                    );
                    continue;
                }
                let mut profile = profile.clone();
                if profile.get("layout").is_some() {
                    profile["layout"] =
                        self.layout(profile.get("layout"), ident, &common, strict, &mut errors);
                }
                valid_profiles.insert(ident.clone(), profile);
            }
        } else {
            errors.insert(
                "outputs".into(),
                json!("At most 64 saved display profiles are supported."),
            );
        }
        values.insert("outputs".into(), Value::Object(valid_profiles.clone()));
        let bindings = values.get("bindings").unwrap_or(&empty);
        let valid = bindings.as_object().is_some_and(|bindings| {
            bindings.len() <= 64
                && bindings.iter().all(|(name, ident)| {
                    !name.is_empty()
                        && name.chars().count() <= 200
                        && ident
                            .as_str()
                            .is_some_and(|ident| valid_profiles.contains_key(ident))
                })
        });
        if !valid {
            errors.insert(
                "bindings".into(),
                json!("Display bindings must refer to saved profiles."),
            );
            values.insert("bindings".into(), json!({}));
        } else {
            values.insert("bindings".into(), bindings.clone());
        }
        (Value::Object(values), errors)
    }
}

impl macshell_preferences_store::Schema for Schema {
    fn version(&self) -> u64 {
        1
    }
    fn label(&self) -> &str {
        "Menu bar"
    }
    fn defaults(&self) -> &Map<String, Value> {
        &self.defaults
    }
    fn normalize(&self, source: &Value, strict: bool) -> (Value, Map<String, Value>) {
        self.normalize_impl(source, strict)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn legacy_visibility_and_unique_blocks() {
        let schema = Schema::new();
        let defaults = schema.make_defaults(&json!({"barWidgets":["clock", "volume", "appleMenu"], "showTray":false, "showSearch":false}));
        let active: Vec<_> = defaults["common"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|item| item["enabled"] == true)
            .map(|item| item["type"].as_str().unwrap())
            .collect();
        assert_eq!(active, vec!["appleMenu", "volume", "battery", "clock"]);
        let duplicate = json!({"common":[defaults["common"][0], defaults["common"][0]]});
        assert!(!schema.normalize_impl(&duplicate, true).1.is_empty());
    }
}
