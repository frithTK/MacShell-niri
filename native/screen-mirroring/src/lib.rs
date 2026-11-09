use serde_json::{json, Value};
use std::collections::HashMap;
use std::net::IpAddr;

/// Normalize only endpoints returned by the discovery daemon, never user input.
pub fn devices_from_response(items: &Value) -> Vec<Value> {
    let Some(items) = items.as_array() else {
        return Vec::new();
    };
    let mut devices = HashMap::new();
    for item in items.iter().take(100) {
        let Some(object) = item.as_object() else {
            continue;
        };
        let Some(address) = object
            .get("ip")
            .and_then(Value::as_str)
            .and_then(|v| v.parse::<IpAddr>().ok())
        else {
            continue;
        };
        let port = match object.get("port") {
            None => Some(7000),
            Some(Value::String(s)) => s.parse::<u16>().ok(),
            Some(v) => v.as_u64().and_then(|v| u16::try_from(v).ok()),
        };
        let Some(port) = port.filter(|v| *v != 0) else {
            continue;
        };
        let address = address.to_string();
        let key = format!("{address}|{port}");
        let name = object
            .get("name")
            .and_then(Value::as_str)
            .filter(|v| !v.is_empty())
            .unwrap_or(&address)
            .chars()
            .take(120)
            .collect::<String>();
        let model = object
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or("")
            .chars()
            .take(100)
            .collect::<String>();
        devices.insert(
            key.clone(),
            json!({"key":key,"name":name,"model":model,"address":address,"port":port}),
        );
    }
    let mut result: Vec<_> = devices.into_values().collect();
    result.sort_by(|a, b| {
        a["name"]
            .as_str()
            .unwrap()
            .to_lowercase()
            .cmp(&b["name"].as_str().unwrap().to_lowercase())
            .then_with(|| a["key"].as_str().cmp(&b["key"].as_str()))
    });
    result
}

pub fn valid_receiver_name(name: &str) -> Option<&str> {
    let name = name.trim();
    if name.is_empty() || name.len() > 60 || name.chars().any(|c| c < ' ') {
        None
    } else {
        Some(name)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReceiverState {
    pub state: String,
    pub error: String,
    pub pin: String,
    pub client: String,
}

impl ReceiverState {
    pub fn apply_line(&mut self, line: &str) {
        if self.state == "error" {
            return;
        }
        if line.contains("register_dnssd: advertised AirPlay service") {
            self.state = "waiting".into();
        }
        if let Some(pin) = line
            .split("CLIENT MUST NOW ENTER PIN = \"")
            .nth(1)
            .and_then(|s| s.split('"').next())
        {
            if pin.len() == 4 && pin.bytes().all(|b| b.is_ascii_digit()) {
                self.pin = pin.into();
            }
        }
        if let Some(client) = line
            .split("connection request from ")
            .nth(1)
            .and_then(|s| s.split(" (").next())
        {
            self.client = client.chars().take(100).collect();
        }
        if line.contains("Begin streaming to GStreamer video pipeline")
            || line.contains("start audio connection, format")
        {
            self.state = "streaming".into();
            self.pin.clear();
        }
        if (line.contains("video_reset: type")
            && (line.contains("RTP_Shutdown") || line.contains("HLS_Shutdown")))
            || line.contains("lost connection with client")
            || (line.contains("Open connections: 0") && self.state == "streaming")
        {
            self.state = "waiting".into();
            self.pin.clear();
            self.client.clear();
        }
        let lower = line.to_lowercase();
        if lower.contains("error ")
            && lower.contains("socket")
            && [
                "binding",
                "initializing",
                "initialising",
                "listening to ipv4",
                "listening to ipv6",
            ]
            .iter()
            .any(|s| lower.contains(s))
        {
            self.error = "AirPlay ports 7100–7102 are already in use or unavailable. Stop another receiver and try again.".into();
            self.state = "error".into();
        } else if (lower.contains("dnssd_register_") && lower.contains("failed"))
            || lower.contains("could not initialize dnssd")
            || lower.contains("failed to initialize")
            || lower.contains("gstreamer error")
            || (lower.contains("could not")
                && (lower.contains("display") || lower.contains("sink")))
        {
            self.error = "AirPlay receiver could not start. Check the network, Wayland and GStreamer plug-ins.".into();
            self.state = "error".into();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn discovery_rejects_invalid_and_deduplicates() {
        let devices = devices_from_response(
            &json!([null,{}, {"ip":"invalid"}, {"ip":"127.0.0.1","port":0}, {"ip":"127.0.0.1","port":7000,"name":"TV"}, {"ip":"127.0.0.1","port":7000,"name":"TV"}]),
        );
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0]["key"], "127.0.0.1|7000");
    }
    #[test]
    fn receiver_name_checks_bytes_and_controls() {
        assert_eq!(valid_receiver_name("  TV  "), Some("TV"));
        assert_eq!(valid_receiver_name(" \n "), None);
        assert_eq!(valid_receiver_name(&"я".repeat(31)), None);
        assert_eq!(valid_receiver_name("bad\u{1}name"), None);
    }
    #[test]
    fn failed_receiver_cannot_be_marked_ready_by_late_advertisement() {
        let mut s = ReceiverState {
            state: "starting".into(),
            error: String::new(),
            pin: String::new(),
            client: String::new(),
        };
        s.apply_line("Error initialising socket 98");
        s.apply_line("register_dnssd: advertised AirPlay service");
        assert_eq!(s.state, "error");
        assert!(s.error.contains("7100–7102"));
    }
    #[test]
    fn receiver_pin_stream_and_disconnect() {
        let mut s = ReceiverState {
            state: "starting".into(),
            error: String::new(),
            pin: String::new(),
            client: String::new(),
        };
        s.apply_line("register_dnssd: advertised AirPlay service");
        s.apply_line("connection request from Test iPhone (iPhone)");
        s.apply_line("CLIENT MUST NOW ENTER PIN = \"0042\"");
        assert_eq!(
            (&*s.state, &*s.pin, &*s.client),
            ("waiting", "0042", "Test iPhone")
        );
        s.apply_line("Begin streaming to GStreamer video pipeline");
        assert_eq!((&*s.state, &*s.pin), ("streaming", ""));
        s.apply_line("Open connections: 0");
        assert_eq!((&*s.state, &*s.client), ("waiting", ""));
    }
}
