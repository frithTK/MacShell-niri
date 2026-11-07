//! Bounded, read-only NetworkManager snapshot for a dedicated worker.
//!
//! This API performs synchronous calls and must not run on the UI or a D-Bus
//! dispatch thread. The caller must discard the result whenever its independent
//! NetworkManager owner generation changes during the read, even if the same
//! unique owner later reacquires the name.
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use macshell_network_core::{choose_profile, security, Profile};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::ptr;
use std::time::{Duration, Instant};

pub mod action_worker;
pub mod activate;
pub mod coordinator;
pub mod identity;
pub mod join;
pub mod profile;
pub mod radio;
pub mod session;
pub mod worker;

const NM: &str = "org.freedesktop.NetworkManager";
const ROOT: &str = "/org/freedesktop/NetworkManager";
const PROPS: &str = "org.freedesktop.DBus.Properties";
const DEVICE: &str = "org.freedesktop.NetworkManager.Device";
const WIFI: &str = "org.freedesktop.NetworkManager.Device.Wireless";
const AP: &str = "org.freedesktop.NetworkManager.AccessPoint";
const ACTIVE: &str = "org.freedesktop.NetworkManager.Connection.Active";
const CONNECTION: &str = "org.freedesktop.NetworkManager.Settings.Connection";
const MAX_DEVICES: usize = 64;
const MAX_PROFILES: usize = 256;
const MAX_APS: usize = 2048;

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    Invalid,
    Limit,
    Timeout,
    Unavailable,
    OwnerChanged,
}

struct Saved {
    path: String,
    ssid: Vec<u8>,
    key: String,
    interface: Option<String>,
    timestamp: u64,
    uuid: String,
}

struct Reader {
    bus: Ptr,
    owner: String,
    deadline: Instant,
}
impl Reader {
    unsafe fn call(
        &self,
        destination: &str,
        path: &str,
        interface: &str,
        method: &str,
        params: Ptr,
    ) -> Result<Variant, Error> {
        let remaining = self.deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(Error::Timeout);
        }
        let timeout = remaining
            .min(Duration::from_millis(1000))
            .as_millis()
            .max(1) as i32;
        let mut error = ptr::null_mut();
        let response = gio::g_dbus_connection_call_sync(
            self.bus,
            c(destination).as_ptr(),
            c(path).as_ptr(),
            c(interface).as_ptr(),
            c(method).as_ptr(),
            params,
            ptr::null_mut(),
            0,
            timeout,
            ptr::null_mut(),
            &mut error,
        );
        if !error.is_null() {
            gio::g_error_free(error);
        }
        if Instant::now() >= self.deadline {
            if let Some(value) = Variant::from(response) {
                drop(value);
            }
            return Err(Error::Timeout);
        }
        Variant::from(response).ok_or(Error::Unavailable)
    }
    unsafe fn owner(&self) -> Result<String, Error> {
        let reply = self.call(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "GetNameOwner",
            gio::tuple(&[gio::string(NM)]),
        )?;
        if reply.kind() != "(s)" {
            return Err(Error::Invalid);
        }
        reply
            .child(0)
            .and_then(|v| v.string())
            .ok_or(Error::Invalid)
    }
    unsafe fn get_all(&self, path: &str, iface: &str) -> Result<Variant, Error> {
        let reply = self.call(
            &self.owner,
            path,
            PROPS,
            "GetAll",
            gio::tuple(&[gio::string(iface)]),
        )?;
        if reply.kind() != "(a{sv})" {
            return Err(Error::Invalid);
        }
        reply.child(0).ok_or(Error::Invalid)
    }
    unsafe fn list(&self) -> Result<Vec<String>, Error> {
        let reply = self.call(
            &self.owner,
            &format!("{ROOT}/Settings"),
            "org.freedesktop.NetworkManager.Settings",
            "ListConnections",
            ptr::null_mut(),
        )?;
        if reply.kind() != "(ao)" {
            return Err(Error::Invalid);
        }
        let array = reply.child(0).ok_or(Error::Invalid)?;
        paths(&array, MAX_PROFILES, "/Settings/")
    }
    unsafe fn saved(&self, path: &str) -> Result<Saved, Error> {
        let reply = self.call(
            &self.owner,
            path,
            CONNECTION,
            "GetSettings",
            ptr::null_mut(),
        )?;
        if reply.kind() != "(a{sa{sv}})" {
            return Err(Error::Invalid);
        }
        let settings = reply.child(0).ok_or(Error::Invalid)?;
        let connection = settings.lookup("connection");
        let wifi = settings.lookup("802-11-wireless");
        let secure = settings.lookup("802-11-wireless-security");
        let ssid = match wifi.as_ref().and_then(|v| v.lookup("ssid")) {
            Some(v) => bytes(&v)?,
            None => Vec::new(),
        };
        let key = field_string(secure.as_ref(), "key-mgmt")?.unwrap_or_else(|| "open".into());
        let interface = field_string(connection.as_ref(), "interface-name")?;
        let uuid = field_string(connection.as_ref(), "uuid")?.unwrap_or_default();
        let timestamp = match connection.as_ref().and_then(|v| v.lookup("timestamp")) {
            Some(v) => v.u64().ok_or(Error::Invalid)?,
            None => 0,
        };
        Ok(Saved {
            path: path.into(),
            ssid,
            key,
            interface,
            timestamp,
            uuid,
        })
    }
}

unsafe fn paths(value: &Variant, max: usize, suffix: &str) -> Result<Vec<String>, Error> {
    if value.kind() != "ao" {
        return Err(Error::Invalid);
    }
    if value.len() > max {
        return Err(Error::Limit);
    }
    let prefix = format!("{ROOT}{suffix}");
    (0..value.len())
        .map(|i| {
            let path = value
                .child(i)
                .and_then(|v| v.object_path())
                .ok_or(Error::Invalid)?;
            if !path.starts_with(&prefix) || path.len() > 1024 {
                return Err(Error::Invalid);
            }
            Ok(path)
        })
        .collect()
}
unsafe fn bytes(value: &Variant) -> Result<Vec<u8>, Error> {
    if value.kind() != "ay" {
        return Err(Error::Invalid);
    }
    if value.len() > 32 {
        return Err(Error::Limit);
    }
    (0..value.len())
        .map(|i| value.child(i).and_then(|v| v.byte()).ok_or(Error::Invalid))
        .collect()
}
unsafe fn field_string(value: Option<&Variant>, key: &str) -> Result<Option<String>, Error> {
    match value.and_then(|v| v.lookup(key)) {
        Some(v) => {
            let s = v.string().ok_or(Error::Invalid)?;
            if s.len() > 4096 {
                return Err(Error::Limit);
            }
            Ok(Some(s))
        }
        None => Ok(None),
    }
}
unsafe fn field_u32(value: &Variant, key: &str) -> Result<u32, Error> {
    match value.lookup(key) {
        Some(v) => v.u32().ok_or(Error::Invalid),
        None => Ok(0),
    }
}
unsafe fn field_bool(value: &Variant, key: &str) -> Result<bool, Error> {
    match value.lookup(key) {
        Some(v) => v.boolean().ok_or(Error::Invalid),
        None => Ok(false),
    }
}
unsafe fn field_path(value: &Variant, key: &str) -> Result<String, Error> {
    match value.lookup(key) {
        Some(v) => v.object_path().ok_or(Error::Invalid),
        None => Ok("/".into()),
    }
}
unsafe fn field_paths(
    value: &Variant,
    key: &str,
    max: usize,
    prefix: &str,
) -> Result<Vec<String>, Error> {
    match value.lookup(key) {
        Some(v) => paths(&v, max, prefix),
        None => Ok(Vec::new()),
    }
}

/// Read a complete snapshot. Errors never contain service-supplied strings.
///
/// # Safety
/// `bus` must be a live dedicated Gio connection. Call from a worker that does
/// not dispatch the caller's main context. The caller must independently track
/// owner generations and discard results from an outdated generation.
pub unsafe fn read(bus: Ptr, owner: &str, timeout: Duration) -> Result<Value, Error> {
    if bus.is_null()
        || owner.contains('\0')
        || gio::g_dbus_is_unique_name(c(owner).as_ptr()) == 0
        || timeout.is_zero()
        || timeout > Duration::from_secs(30)
    {
        return Err(Error::Invalid);
    }
    let reader = Reader {
        bus,
        owner: owner.into(),
        deadline: Instant::now().checked_add(timeout).ok_or(Error::Invalid)?,
    };
    if reader.owner()? != owner {
        return Err(Error::OwnerChanged);
    }
    let root = reader.get_all(ROOT, NM)?;
    let devices = field_paths(&root, "Devices", MAX_DEVICES, "/Devices/")?;
    let mut saved = Vec::new();
    for path in reader.list()? {
        match reader.saved(&path) {
            Ok(v) => saved.push(v),
            Err(Error::Unavailable) => (),
            Err(e) => return Err(e),
        }
    }
    let profiles: Vec<_> = saved
        .iter()
        .map(|p| Profile {
            path: &p.path,
            ssid: &p.ssid,
            key_management: &p.key,
            interface: p.interface.as_deref(),
            timestamp: p.timestamp,
            uuid: &p.uuid,
        })
        .collect();
    let mut networks = BTreeMap::new();
    let mut ethernet = false;
    let mut ap_count = 0usize;
    for device in devices {
        let props = reader.get_all(&device, DEVICE)?;
        let kind = field_u32(&props, "DeviceType")?;
        if kind == 1 && field_u32(&props, "State")? == 100 {
            ethernet = true;
        }
        if kind != 2 {
            continue;
        }
        let interface = field_string(Some(&props), "Interface")?.unwrap_or_default();
        let wifi = reader.get_all(&device, WIFI)?;
        let active = field_path(&props, "ActiveConnection")?;
        let active_profile = if active == "/" {
            String::new()
        } else {
            if !active.starts_with(&format!("{ROOT}/ActiveConnection/")) || active.len() > 1024 {
                return Err(Error::Invalid);
            }
            let active_props = reader.get_all(&active, ACTIVE)?;
            let profile = field_path(&active_props, "Connection")?;
            if profile != "/"
                && (!profile.starts_with(&format!("{ROOT}/Settings/")) || profile.len() > 1024)
            {
                return Err(Error::Invalid);
            }
            if profile == "/" {
                String::new()
            } else {
                profile
            }
        };
        let active_ap = field_path(&wifi, "ActiveAccessPoint")?;
        let access_points = field_paths(&wifi, "AccessPoints", MAX_APS, "/AccessPoint/")?;
        ap_count = ap_count
            .checked_add(access_points.len())
            .ok_or(Error::Limit)?;
        if ap_count > MAX_APS {
            return Err(Error::Limit);
        }
        for path in access_points {
            let ap = match reader.get_all(&path, AP) {
                Ok(v) => v,
                Err(Error::Unavailable) => continue,
                Err(e) => return Err(e),
            };
            let ssid = match ap.lookup("Ssid") {
                Some(v) => bytes(&v)?,
                None => Vec::new(),
            };
            if ssid.is_empty() {
                continue;
            }
            let kind = security(
                field_u32(&ap, "Flags")?,
                field_u32(&ap, "WpaFlags")?,
                field_u32(&ap, "RsnFlags")?,
            );
            let profile =
                choose_profile(&profiles, &ssid, kind, &interface, &active_profile).unwrap_or("");
            let uuid = saved
                .iter()
                .find(|p| p.path == profile)
                .map(|p| p.uuid.as_str())
                .unwrap_or("");
            let signal = match ap.lookup("Strength") {
                Some(v) => v.byte().ok_or(Error::Invalid)?,
                None => 0,
            };
            networks.insert(path.clone(), json!({"id":path, "ap":path, "device":device,
                "interface":interface, "ssid":String::from_utf8_lossy(&ssid), "rawSsid":ssid,
                "signal":signal, "security":kind, "secure":kind != "open",
                "supported":matches!(kind, "open" | "wpa-psk" | "sae"),
                "inUse":path == active_ap, "saved":!profile.is_empty(), "profile":profile, "uuid":uuid}));
        }
    }
    if reader.owner()? != owner {
        return Err(Error::OwnerChanged);
    }
    let mut networks: Vec<Value> = networks.into_values().collect();
    networks.sort_by(|a, b| {
        b["inUse"]
            .as_bool()
            .cmp(&a["inUse"].as_bool())
            .then_with(|| b["signal"].as_u64().cmp(&a["signal"].as_u64()))
            .then_with(|| a["id"].as_str().cmp(&b["id"].as_str()))
    });
    Ok(
        json!({"type":"state", "available":true, "enabled":field_bool(&root, "WirelessEnabled")?,
        "hardwareEnabled":field_bool(&root, "WirelessHardwareEnabled")?, "ethernet":ethernet,
        "connectivity":field_u32(&root, "Connectivity")?, "networks":networks}),
    )
}
