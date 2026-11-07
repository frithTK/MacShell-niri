//! Validate a fresh `niri msg Outputs` response before selecting a capture.
use crate::Output;
use serde_json::{json, Value};

/// Preserve logical coordinates and mode metadata for the UI and recorder.
/// Invalid active outputs fail the whole snapshot: they must not silently turn
/// an intended region into a full-monitor recording.
pub fn parse(reply: &Value) -> Result<Vec<Value>, &'static str> {
    let values = reply
        .get("Outputs")
        .unwrap_or(reply)
        .as_object()
        .ok_or("Invalid monitor response.")?;
    if values.len() > 128 {
        return Err("Too many monitors.");
    }
    let mut result = Vec::new();
    for (name, value) in values {
        let logical = &value["logical"];
        let mode = &value["current_mode"];
        if logical.is_null() || mode.is_null() {
            continue;
        }
        if name.is_empty() || name.len() > 512 || name.contains('\0') {
            return Err("Invalid monitor name.");
        }
        let geometry = rect(logical)?;
        let index = mode
            .as_u64()
            .and_then(|v| usize::try_from(v).ok())
            .ok_or("Invalid monitor mode.")?;
        let mode = value["modes"]
            .as_array()
            .and_then(|v| v.get(index))
            .filter(|v| v.is_object())
            .ok_or("Invalid monitor mode.")?;
        if geometry.width == 0 || geometry.height == 0 {
            return Err("Invalid monitor geometry.");
        }
        result.push(json!({"name": name, "logical": logical, "mode": mode,
            "transform": logical.get("transform").cloned().unwrap_or(json!("Normal"))}));
    }
    Ok(result)
}

pub fn rect(logical: &Value) -> Result<Output, &'static str> {
    let signed = |key| {
        logical
            .get(key)
            .and_then(Value::as_i64)
            .ok_or("Invalid monitor geometry.")
    };
    let unsigned = |key| {
        logical
            .get(key)
            .and_then(Value::as_u64)
            .ok_or("Invalid monitor geometry.")
    };
    let output = Output {
        x: signed("x")?,
        y: signed("y")?,
        width: unsigned("width")?,
        height: unsigned("height")?,
    };
    let width = i64::try_from(output.width).map_err(|_| "Invalid monitor geometry.")?;
    let height = i64::try_from(output.height).map_err(|_| "Invalid monitor geometry.")?;
    output
        .x
        .checked_add(width)
        .and_then(|_| output.y.checked_add(height))
        .ok_or("Invalid monitor geometry.")?;
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_logical_coordinates_and_actual_mode() {
        let data = json!({"Outputs":{"virtual":{"logical":{"x":-1280,"y":0,"width":1280,"height":720,"scale":1.5},"current_mode":0,"modes":[{"width":1920,"height":1080}]}, "disconnected":{"logical":null,"current_mode":null}}});
        let outputs = parse(&data).unwrap();
        assert_eq!(outputs.len(), 1);
        assert_eq!(outputs[0]["logical"]["x"], -1280);
        assert_eq!(outputs[0]["mode"]["width"], 1920);
        assert_eq!(outputs[0]["transform"], "Normal");
        assert_eq!(
            crate::geometry("-1200,10 321x201", rect(&outputs[0]["logical"]).unwrap()).unwrap(),
            "-1200,10 321x201"
        );
    }
    #[test]
    fn malformed_or_overflowing_active_outputs_fail_closed() {
        for logical in [
            json!({"x":0,"y":0,"width":0,"height":1}),
            json!({"x":i64::MAX,"y":0,"width":1,"height":1}),
            json!({"x":0,"y":0,"width":-1,"height":1}),
        ] {
            assert!(
                parse(&json!({"display":{"logical":logical,"current_mode":0,"modes":[{}]}}))
                    .is_err()
            );
        }
        assert!(parse(&json!({"display":{"logical":{"x":0,"y":0,"width":1,"height":1},"current_mode":2,"modes":[{}]}})).is_err());
    }
}
