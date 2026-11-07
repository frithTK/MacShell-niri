use serde_json::{json, Map, Value};
use std::collections::HashSet;

pub struct Schema {
    pub fields: Vec<Value>,
    pub defaults: Map<String, Value>,
    pub version: u64,
}

impl Schema {
    pub fn new() -> Self {
        let value: Value = serde_json::from_str(include_str!(
            "../../../MacShell/activity_preferences_schema.json"
        ))
        .expect("valid bundled Activity schema");
        let fields = value["fields"].as_array().expect("schema fields").clone();
        let defaults = fields
            .iter()
            .map(|field| {
                (
                    field["key"].as_str().unwrap().to_owned(),
                    field["default"].clone(),
                )
            })
            .collect();
        Self {
            fields,
            defaults,
            version: value["version"].as_u64().unwrap(),
        }
    }

    pub fn normalize(&self, source: &Value, strict: bool) -> (Value, Map<String, Value>) {
        let mut values = source.as_object().cloned().unwrap_or_default();
        let mut errors = Map::new();
        for field in &self.fields {
            let key = field["key"].as_str().unwrap();
            let default = &field["default"];
            let value = values.get(key).unwrap_or(default);
            let valid = match field["type"].as_str().unwrap() {
                "integer" => value.as_i64().is_some_and(|number| {
                    number >= field["minimum"].as_i64().unwrap()
                        && number <= field["maximum"].as_i64().unwrap()
                }),
                "choice" => field["choices"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|choice| choice["value"] == *value),
                "order" => {
                    let allowed: HashSet<_> = field["choices"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .filter_map(|choice| choice["value"].as_str())
                        .collect();
                    value.as_array().is_some_and(|items| {
                        let strings: Option<HashSet<_>> = items.iter().map(Value::as_str).collect();
                        items.len() == allowed.len()
                            && strings.is_some_and(|strings| strings == allowed)
                    })
                }
                _ => false,
            };
            if !valid {
                errors.insert(
                    key.into(),
                    json!(format!(
                        "{} has an invalid value.",
                        field["label"].as_str().unwrap()
                    )),
                );
                values.insert(key.into(), default.clone());
            } else if field["type"] == "integer" {
                let number = value.as_i64().unwrap();
                values.insert(key.into(), json!(number));
            } else if !values.contains_key(key) {
                values.insert(key.into(), default.clone());
            }
        }
        for field in &self.fields {
            if let Some(other) = field.get("lessThan").and_then(Value::as_str) {
                let key = field["key"].as_str().unwrap();
                if values[key].as_i64().unwrap() >= values[other].as_i64().unwrap() {
                    errors.insert(
                        key.into(),
                        json!(format!(
                            "{} must be below the critical threshold.",
                            field["label"].as_str().unwrap()
                        )),
                    );
                    if !strict {
                        values.insert(key.into(), field["default"].clone());
                        values.insert(other.into(), self.defaults[other].clone());
                    }
                }
            }
        }
        (Value::Object(values), errors)
    }
}

impl macshell_preferences_store::Schema for Schema {
    fn version(&self) -> u64 {
        self.version
    }
    fn label(&self) -> &str {
        "Activity"
    }
    fn defaults(&self) -> &Map<String, Value> {
        &self.defaults
    }
    fn normalize(&self, source: &Value, strict: bool) -> (Value, Map<String, Value>) {
        Schema::normalize(self, source, strict)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn schema_validation_and_unknown_fields() {
        let schema = Schema::new();
        let (values, errors) =
            schema.normalize(&json!({"cpuWarning":true, "unknown":{"keep":false}}), true);
        assert!(!errors.is_empty());
        assert_eq!(values["unknown"]["keep"], false);
        let (values, errors) = schema.normalize(&json!({"cpuWarning":95, "cpuCritical":50}), false);
        assert!(!errors.is_empty());
        assert_eq!(values["cpuWarning"], 65);
        assert_eq!(values["cpuCritical"], 90);
        assert!(!schema
            .normalize(&json!({"order":["cpu","cpu","network","disk"]}), true)
            .1
            .is_empty());
    }
}
