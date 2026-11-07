//! Inspect an ffprobe JSON response; never runs a program or removes a file.
use serde_json::Value;

pub fn valid_file(response: &Value, expect_audio: bool) -> bool {
    let duration = &response["format"]["duration"];
    let duration = duration
        .as_f64()
        .or_else(|| duration.as_str().and_then(|v| v.parse::<f64>().ok()));
    if !duration.is_some_and(|v| v.is_finite() && v > 0.0) {
        return false;
    }
    let Some(streams) = response["streams"].as_array() else {
        return false;
    };
    let video = streams
        .iter()
        .any(|stream| stream["codec_type"].as_str() == Some("video"));
    let audio = streams
        .iter()
        .any(|stream| stream["codec_type"].as_str() == Some("audio"));
    video && (!expect_audio || audio)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn requires_nonzero_duration_video_and_selected_audio() {
        let mut probe = json!({"format":{"duration":"0.5"},"streams":[{"codec_type":"video"}]});
        assert!(valid_file(&probe, false));
        assert!(!valid_file(&probe, true));
        probe["streams"]
            .as_array_mut()
            .unwrap()
            .push(json!({"codec_type":"audio"}));
        assert!(valid_file(&probe, true));
        for duration in [
            json!("0"),
            json!("-1"),
            json!("inf"),
            json!("nan"),
            Value::Null,
        ] {
            probe["format"]["duration"] = duration;
            assert!(!valid_file(&probe, true));
        }
        assert!(!valid_file(&json!({}), false));
    }
}
