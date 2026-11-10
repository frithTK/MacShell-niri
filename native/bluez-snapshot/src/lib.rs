//! Convert a BlueZ ObjectManager reply to the existing Bluetooth JSON state.
use macshell_gio_bridge::{self as gio, c, Variant};
use serde_json::{json, Value};
use std::collections::BTreeMap;

pub mod apple;
pub mod reader;

const ADAPTER: &str = "org.bluez.Adapter1";
const DEVICE: &str = "org.bluez.Device1";
const BATTERY: &str = "org.bluez.Battery1";

struct Adapter {
    path: String,
    name: String,
    enabled: bool,
}
#[derive(Clone)]
struct Device {
    path: String,
    address: String,
    name: String,
    icon: String,
    connected: bool,
    blocked: bool,
    paired: bool,
    adapter: String,
    battery: i32,
    left: i32,
    right: i32,
    case: i32,
    charging: bool,
    apple_audio: bool,
}

unsafe fn property(value: &Variant, key: &str) -> Option<String> {
    value.lookup(key).and_then(|v| v.string())
}
unsafe fn boolean(value: &Variant, key: &str) -> bool {
    value.lookup(key).and_then(|v| v.boolean()).unwrap_or(false)
}
unsafe fn casefold(value: &str) -> String {
    let folded = gio::g_utf8_casefold(c(value).as_ptr(), -1);
    if folded.is_null() {
        return value.to_lowercase();
    }
    let result = gio::text(folded);
    gio::g_free(folded.cast());
    result
}

/// Parse an owned or borrowed `(a{oa{sa{sv}}})` reply.
///
/// # Safety
/// `reply` must be a live Gio GVariant for the duration of this call.
pub unsafe fn parse(reply: &Variant) -> Result<Value, &'static str> {
    if reply.kind() != "(a{oa{sa{sv}}})" {
        return Err("Invalid BlueZ object response.");
    }
    let objects = reply.child(0).ok_or("Invalid BlueZ object response.")?;
    let mut adapters = BTreeMap::<String, Adapter>::new();
    let mut devices = Vec::new();
    for index in 0..objects.len() {
        let Some(entry) = objects.child(index) else {
            continue;
        };
        let Some(path) = entry.child(0).and_then(|v| v.object_path()) else {
            continue;
        };
        let Some(interfaces) = entry.child(1) else {
            continue;
        };
        if let Some(props) = interfaces.lookup(ADAPTER) {
            adapters.insert(
                path.clone(),
                Adapter {
                    path: path.clone(),
                    name: property(&props, "Alias").unwrap_or_else(|| "Bluetooth".into()),
                    enabled: boolean(&props, "Powered"),
                },
            );
        }
        if let Some(props) = interfaces.lookup(DEVICE) {
            let address_property = property(&props, "Address");
            let address = address_property.clone().unwrap_or_default();
            let name = property(&props, "Alias")
                .filter(|v| !v.is_empty())
                .or_else(|| property(&props, "Name").filter(|v| !v.is_empty()))
                .unwrap_or_else(|| address_property.unwrap_or_else(|| "Device".into()));
            let battery = interfaces
                .lookup(BATTERY)
                .and_then(|v| v.lookup("Percentage"))
                .and_then(|v| v.byte())
                .filter(|v| *v <= 100)
                .map(i32::from)
                .unwrap_or(-1);
            let mut level = battery;
            let mut left = -1;
            let mut right = -1;
            let mut case = -1;
            let mut charging = false;
            if let Some(apple) = apple_from_props(&props) {
                apple.merge_into(&mut level, &mut left, &mut right, &mut case, &mut charging);
                if battery >= 0 {
                    level = battery;
                }
            }
            devices.push(Device {
                path,
                address,
                name: name.clone(),
                icon: property(&props, "Icon").unwrap_or_else(|| "bluetooth".into()),
                connected: boolean(&props, "Connected"),
                blocked: boolean(&props, "Blocked"),
                paired: boolean(&props, "Paired") || boolean(&props, "Bonded"),
                adapter: props
                    .lookup("Adapter")
                    .and_then(|v| v.object_path())
                    .unwrap_or_default(),
                battery: level,
                left,
                right,
                case,
                charging,
                apple_audio: apple::is_apple_audio(
                    &property(&props, "Modalias").unwrap_or_default(),
                    &name,
                ),
            });
        }
    }
    devices.sort_by_cached_key(|device| {
        (
            !device.connected,
            casefold(&device.name),
            device.path.clone(),
        )
    });
    attach_nearby_apple(&mut devices);
    let mut paired = Vec::new();
    let mut others = Vec::new();
    for device in devices {
        let Some(adapter) = adapters.get(&device.adapter) else {
            continue;
        };
        let mut value = json!({"path":device.path, "address":device.address, "name":device.name,
            "icon":device.icon, "connected":device.connected, "blocked":device.blocked,
            "adapterEnabled":adapter.enabled, "adapterName":adapter.name, "battery":device.battery});
        extend_apple(&mut value, &device);
        if device.apple_audio {
            value["appleAudio"] = json!(true);
        }
        if device.paired || device.connected {
            value["paired"] = Value::Bool(device.paired);
            paired.push(value);
        } else {
            others.push(value);
        }
    }
    let connected = paired.iter().filter(|v| v["connected"] == true).count();
    let adapter_values: Vec<_> = adapters
        .values()
        .map(|a| json!({"path":a.path,"name":a.name,"enabled":a.enabled}))
        .collect();
    Ok(
        json!({"available":!adapters.is_empty(), "enabled":adapters.values().any(|a| a.enabled),
        "adapters":adapter_values,"devices":paired,"others":others,"connected":connected}),
    )
}

unsafe fn apple_from_props(props: &Variant) -> Option<apple::AppleBattery> {
    let md = props.lookup("ManufacturerData")?;
    for index in 0..md.len() {
        let entry = md.child(index)?;
        let company = entry.child(0)?.u16()?;
        let wrapped = entry.child(1)?;
        let payload = if wrapped.kind() == "v" {
            wrapped.variant()?.bytes()?
        } else {
            wrapped.bytes()?
        };
        if let Some(parsed) = apple::from_company(company, &payload) {
            return Some(parsed);
        }
    }
    None
}

fn has_parts(device: &Device) -> bool {
    device.left >= 0 || device.right >= 0 || device.case >= 0
}

fn attach_nearby_apple(devices: &mut [Device]) {
    let need: Vec<usize> = devices
        .iter()
        .enumerate()
        .filter(|(_, device)| device.connected && device.apple_audio && !has_parts(device))
        .map(|(index, _)| index)
        .collect();
    if need.len() != 1 {
        return;
    }
    let Some(source) = devices
        .iter()
        .filter(|device| !device.paired && !device.connected && has_parts(device))
        .max_by_key(|device| {
            i32::from(device.left >= 0) + i32::from(device.right >= 0) + i32::from(device.case >= 0)
        })
        .cloned()
    else {
        return;
    };
    let dest = &mut devices[need[0]];
    if dest.left < 0 {
        dest.left = source.left;
    }
    if dest.right < 0 {
        dest.right = source.right;
    }
    if dest.case < 0 {
        dest.case = source.case;
    }
    if dest.battery < 0 {
        dest.battery = source.battery;
    }
    dest.charging |= source.charging;
}

fn extend_apple(value: &mut Value, device: &Device) {
    if device.left >= 0 {
        value["batteryLeft"] = json!(device.left);
    }
    if device.right >= 0 {
        value["batteryRight"] = json!(device.right);
    }
    if device.case >= 0 {
        value["batteryCase"] = json!(device.case);
    }
    if device.charging {
        value["charging"] = json!(true);
    }
}

/// Overlay AACP battery reports onto a snapshot. Parts always update; overall
/// percentage stays with Battery1 when that value is already present.
pub fn merge_aap(state: &mut Value, charges: &BTreeMap<String, apple::AppleBattery>) {
    if charges.is_empty() {
        return;
    }
    for key in ["devices", "others"] {
        let Some(list) = state.get_mut(key).and_then(Value::as_array_mut) else {
            continue;
        };
        for device in list {
            let Some(address) = device.get("address").and_then(Value::as_str) else {
                continue;
            };
            let Some(parsed) = charges.get(&address.to_ascii_uppercase()) else {
                continue;
            };
            if parsed.left >= 0 {
                device["batteryLeft"] = json!(parsed.left);
            }
            if parsed.right >= 0 {
                device["batteryRight"] = json!(parsed.right);
            }
            if parsed.case >= 0 {
                device["batteryCase"] = json!(parsed.case);
            }
            if parsed.charging {
                device["charging"] = json!(true);
            } else if let Some(object) = device.as_object_mut() {
                object.remove("charging");
            }
            if parsed.battery >= 0 {
                device["battery"] = json!(parsed.battery);
            }
        }
    }
}

pub fn apple_addresses(state: &Value) -> Vec<String> {
    state
        .get("devices")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|device| device.get("connected") == Some(&Value::Bool(true)))
        .filter(|device| device.get("appleAudio") == Some(&Value::Bool(true)))
        .filter_map(|device| {
            device
                .get("address")
                .and_then(Value::as_str)
                .map(str::to_ascii_uppercase)
        })
        .filter(|address| address.len() == 17)
        .collect()
}
