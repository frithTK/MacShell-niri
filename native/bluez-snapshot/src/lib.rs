//! Convert a BlueZ ObjectManager reply to the existing Bluetooth JSON state.
use macshell_gio_bridge::{self as gio, c, Variant};
use serde_json::{json, Value};
use std::collections::BTreeMap;

pub mod reader;

const ADAPTER: &str = "org.bluez.Adapter1";
const DEVICE: &str = "org.bluez.Device1";
const BATTERY: &str = "org.bluez.Battery1";

struct Adapter {
    path: String,
    name: String,
    enabled: bool,
}
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
            devices.push(Device {
                path,
                address,
                name,
                icon: property(&props, "Icon").unwrap_or_else(|| "bluetooth".into()),
                connected: boolean(&props, "Connected"),
                blocked: boolean(&props, "Blocked"),
                paired: boolean(&props, "Paired") || boolean(&props, "Bonded"),
                adapter: props
                    .lookup("Adapter")
                    .and_then(|v| v.object_path())
                    .unwrap_or_default(),
                battery,
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
    let mut paired = Vec::new();
    let mut others = Vec::new();
    for device in devices {
        let Some(adapter) = adapters.get(&device.adapter) else {
            continue;
        };
        let value = json!({"path":device.path, "address":device.address, "name":device.name,
            "icon":device.icon, "connected":device.connected, "blocked":device.blocked,
            "adapterEnabled":adapter.enabled, "adapterName":adapter.name, "battery":device.battery});
        if device.paired || device.connected {
            let mut value = value;
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
