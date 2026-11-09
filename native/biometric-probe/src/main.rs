//! Read-only fprintd discovery for the Security & Unlock settings pane.
//!
//! This binary never claims a device and never handles fingerprint data. It
//! intentionally mirrors the small Python probe: current-user enrollment is
//! read from at most eight devices and every D-Bus request has a short bound.
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use serde_json::{json, Value};
use std::ffi::CStr;
use std::ptr;

const SERVICE: &str = "net.reactivated.Fprint";
const MANAGER: &str = "/net/reactivated/Fprint/Manager";
const DEVICE: &str = "net.reactivated.Fprint.Device";
const PROPERTIES: &str = "org.freedesktop.DBus.Properties";

unsafe fn call(
    bus: Ptr,
    path: &str,
    interface: &str,
    method: &str,
    args: Ptr,
) -> Result<Variant, String> {
    let mut error = ptr::null_mut();
    let reply = gio::g_dbus_connection_call_sync(
        bus,
        c(SERVICE).as_ptr(),
        c(path).as_ptr(),
        c(interface).as_ptr(),
        c(method).as_ptr(),
        args,
        ptr::null_mut(),
        0,
        3000,
        ptr::null_mut(),
        &mut error,
    );
    Variant::from(reply).ok_or_else(|| gio::error(error))
}

fn current_user() -> Result<String, String> {
    unsafe {
        let uid = libc::getuid();
        let entry = libc::getpwuid(uid);
        if entry.is_null() || (*entry).pw_name.is_null() {
            return Err("Cannot determine the current user.".into());
        }
        CStr::from_ptr((*entry).pw_name)
            .to_str()
            .map(str::to_owned)
            .map_err(|_| "The current user name is not valid UTF-8.".into())
    }
}

unsafe fn string_property(properties: &Variant, key: &str) -> String {
    properties
        .lookup(key)
        .and_then(|value| value.string())
        .unwrap_or_default()
}

unsafe fn device(bus: Ptr, path: &str, user: &str) -> Option<Value> {
    let properties = call(
        bus,
        path,
        PROPERTIES,
        "GetAll",
        gio::tuple(&[gio::string(DEVICE)]),
    )
    .ok()?
    .child(0)?;
    if properties.kind() != "a{sv}" {
        return None;
    }
    let name = string_property(&properties, "name");
    let scan_type = string_property(&properties, "scan-type");
    let fingers = match call(
        bus,
        path,
        DEVICE,
        "ListEnrolledFingers",
        gio::tuple(&[gio::string(user)]),
    ) {
        Ok(reply) => reply
            .child(0)
            .filter(|value| value.kind() == "as")
            .map(|array| {
                (0..array.len())
                    .filter_map(|index| array.child(index).and_then(|value| value.string()))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default(),
        Err(error) if error.contains("NoEnrolledPrints") => Vec::new(),
        Err(_) => {
            return Some(json!({
                "path": path,
                "name": name,
                "fingers": [],
                "enrollment": "unknown",
                "scanType": scan_type,
            }))
        }
    };
    Some(json!({
        "path": path,
        "name": name,
        "fingers": fingers,
        "enrollment": "ok",
        "scanType": scan_type,
    }))
}

unsafe fn inspect() -> Result<Value, String> {
    let user = current_user()?;
    let mut error = ptr::null_mut();
    let bus = gio::g_bus_get_sync(1, ptr::null_mut(), &mut error);
    if bus.is_null() {
        return Err(gio::error(error));
    }
    let result = (|| {
        let paths = call(
            bus,
            MANAGER,
            "net.reactivated.Fprint.Manager",
            "GetDevices",
            ptr::null_mut(),
        )?;
        let device_paths = paths
            .child(0)
            .filter(|value| value.kind() == "ao")
            .map(|array| {
                (0..array.len())
                    .take(8)
                    .filter_map(|index| array.child(index).and_then(|value| value.object_path()))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let devices = device_paths
            .iter()
            .filter_map(|path| device(bus, path, &user))
            .collect::<Vec<_>>();
        let status = if device_paths.is_empty() {
            "no_device"
        } else if devices.is_empty() {
            "device_error"
        } else {
            "ok"
        };
        Ok(json!({"status": status, "devices": devices}))
    })();
    gio::g_object_unref(bus);
    result
}

fn main() {
    if std::env::args().nth(1).as_deref() == Some("--protocol-version") {
        println!("macshell-biometric-probe 1");
        return;
    }
    if std::env::args().len() != 1 {
        eprintln!("macshell-biometric-probe: unexpected argument");
        std::process::exit(1);
    }
    let result = unsafe { inspect() };
    match result {
        Ok(value) => println!("{value}"),
        Err(_) => println!("{}", json!({"status":"service_unavailable","devices":[]})),
    }
}
