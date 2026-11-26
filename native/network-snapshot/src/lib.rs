//! Bounded, read-only NetworkManager snapshot for a dedicated worker.
//!
//! This API performs synchronous calls and must not run on the UI or a D-Bus
//! dispatch thread. The caller must discard the result whenever its independent
//! NetworkManager owner generation changes during the read, even if the same
//! unique owner later reacquires the name.
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use macshell_network_core::{choose_profile, links, security, Profile};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::ptr;
use std::time::{Duration, Instant};

pub mod action_worker;
pub mod activate;
pub mod coordinator;
pub mod identity;
pub mod join;
pub mod links_act;
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
    id: String,
    kind: String,
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
        let id = field_string(connection.as_ref(), "id")?.unwrap_or_default();
        let kind = field_string(connection.as_ref(), "type")?.unwrap_or_default();
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
            id,
            kind,
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

struct Seen {
    kind: u32,
    state: u32,
    profile: String,
    interface: String,
    ip: String,
    gateway: String,
}

unsafe fn active_profile(reader: &Reader, props: &Variant) -> Result<String, Error> {
    let active = field_path(props, "ActiveConnection")?;
    if active == "/" {
        return Ok(String::new());
    }
    if !active.starts_with(&format!("{ROOT}/ActiveConnection/")) || active.len() > 1024 {
        return Err(Error::Invalid);
    }
    let active_props = reader.get_all(&active, ACTIVE)?;
    let profile = field_path(&active_props, "Connection")?;
    if profile == "/" {
        return Ok(String::new());
    }
    if !profile.starts_with(&format!("{ROOT}/Settings/")) || profile.len() > 1024 {
        return Err(Error::Invalid);
    }
    Ok(profile)
}

unsafe fn ip4_of(reader: &Reader, path: &str) -> (String, String) {
    if !path.starts_with(&format!("{ROOT}/IP4Config/")) || path.len() > 1024 {
        return (String::new(), String::new());
    }
    let Ok(props) = reader.get_all(path, "org.freedesktop.NetworkManager.IP4Config") else {
        return (String::new(), String::new());
    };
    let gateway = field_string(Some(&props), "Gateway")
        .ok()
        .flatten()
        .unwrap_or_default();
    let address = props
        .lookup("AddressData")
        .and_then(|list| list.child(0))
        .and_then(|entry| entry.lookup("address"))
        .and_then(|value| value.string())
        .unwrap_or_default();
    (address, gateway)
}

unsafe fn text_list(value: Option<&Variant>) -> String {
    match value {
        Some(item) if item.kind() == "s" => item.string().unwrap_or_default(),
        Some(item) if item.kind() == "as" => (0..item.len())
            .filter_map(|index| item.child(index).and_then(|child| child.string()))
            .collect::<Vec<_>>()
            .join(","),
        _ => String::new(),
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
    let mut ap_capable = false;
    let mut seen = Vec::new();
    let mut ap_count = 0usize;
    for device in devices {
        let props = reader.get_all(&device, DEVICE)?;
        let kind = field_u32(&props, "DeviceType")?;
        let state = field_u32(&props, "State")?;
        let interface = field_string(Some(&props), "Interface")?.unwrap_or_default();
        let profile = active_profile(&reader, &props)?;
        let (ip, gateway) = ip4_of(&reader, &field_path(&props, "Ip4Config")?);
        if kind == 1 && state == 100 {
            ethernet = true;
        }
        seen.push(Seen {
            kind,
            state,
            profile: profile.clone(),
            interface: interface.clone(),
            ip,
            gateway,
        });
        if kind != 2 {
            continue;
        }
        let wifi = reader.get_all(&device, WIFI)?;
        if field_u32(&wifi, "WirelessCapabilities")? & 0x40 != 0 {
            ap_capable = true;
        }
        let active_profile = profile;
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
    let mut link_rows = Vec::new();
    let mut vpn_rows = Vec::new();
    for profile in &saved {
        if !matches!(
            links::classify(&profile.kind),
            links::Class::Controllable | links::Class::External
        ) {
            continue;
        }
        let live = seen.iter().find(|item| item.profile == profile.path);
        let active = live.is_some_and(|item| item.state == 100);
        if links::can_toggle(&profile.kind) {
            vpn_rows.push(links::VpnCandidate {
                uuid: profile.uuid.clone(),
                path: profile.path.clone(),
                name: profile.id.clone(),
                timestamp: profile.timestamp,
                active,
            });
        }
        link_rows.push(json!({
            "name": profile.id,
            "uuid": profile.uuid,
            "path": profile.path,
            "type": profile.kind,
            "device": live.map(|item| item.interface.as_str()).unwrap_or(""),
            "ip": live.map(|item| item.ip.as_str()).unwrap_or(""),
            "active": active,
            "timestamp": profile.timestamp,
            "controllable": links::can_toggle(&profile.kind),
            "removable": links::can_delete(&profile.kind),
        }));
    }
    link_rows.sort_by(|a, b| {
        links::cmp_vpn_list(
            a["active"].as_bool().unwrap_or(false),
            a["timestamp"].as_u64().unwrap_or(0),
            a["name"].as_str().unwrap_or(""),
            b["active"].as_bool().unwrap_or(false),
            b["timestamp"].as_u64().unwrap_or(0),
            b["name"].as_str().unwrap_or(""),
        )
    });
    let vpn = match links::vpn_plan(&vpn_rows, true) {
        Ok(links::VpnPlan::Up { path, uuid, .. }) => {
            let name = vpn_rows
                .iter()
                .find(|row| row.uuid == uuid)
                .map(|row| row.name.as_str())
                .unwrap_or("");
            json!({
                "on": vpn_rows.iter().any(|row| row.active),
                "available": true,
                "uuid": uuid,
                "path": path,
                "name": name,
            })
        }
        _ => json!({"on": false, "available": false, "uuid": "", "path": "", "name": ""}),
    };
    let hotspot_profile = saved
        .iter()
        .find(|profile| profile.id == links::HOTSPOT_ID && profile.kind == "802-11-wireless");
    let hotspot_live = hotspot_profile.and_then(|profile| {
        seen.iter()
            .find(|item| item.kind == 2 && item.profile == profile.path && item.state == 100)
    });
    let hotspot = json!({
        "available": ap_capable,
        "active": hotspot_live.is_some(),
        "ssid": hotspot_profile.map(|profile| String::from_utf8_lossy(&profile.ssid).into_owned()).unwrap_or_default(),
        "address": hotspot_live.map(|item| item.ip.clone()).unwrap_or_default(),
        "upstream": seen.iter().any(|item| {
            links::shares_upstream(
                item.state,
                &item.gateway,
                &item.profile,
                hotspot_profile.map(|profile| profile.path.as_str()).unwrap_or(""),
                &item.interface,
            )
        }),
    });
    let proxy = proxy_state(&reader, &root, &saved).unwrap_or(Value::Null);
    Ok(
        json!({"type":"state", "available":true, "enabled":field_bool(&root, "WirelessEnabled")?,
        "hardwareEnabled":field_bool(&root, "WirelessHardwareEnabled")?, "ethernet":ethernet,
        "connectivity":field_u32(&root, "Connectivity")?, "networks":networks,
        "links":link_rows, "proxy":proxy, "hotspot":hotspot, "vpn":vpn}),
    )
}

unsafe fn proxy_state(reader: &Reader, root: &Variant, saved: &[Saved]) -> Result<Value, Error> {
    let primary = field_path(root, "PrimaryConnection")?;
    if primary == "/" || !primary.starts_with(&format!("{ROOT}/ActiveConnection/")) {
        return Ok(Value::Null);
    }
    let active = reader.get_all(&primary, ACTIVE)?;
    let profile = field_path(&active, "Connection")?;
    let Some(found) = saved.iter().find(|item| item.path == profile) else {
        return Ok(Value::Null);
    };
    let reply = reader.call(
        &reader.owner,
        &profile,
        CONNECTION,
        "GetSettings",
        ptr::null_mut(),
    )?;
    let settings = reply.child(0).ok_or(Error::Invalid)?;
    let proxy = settings.lookup("proxy");
    let method = field_string(proxy.as_ref(), "method")?.unwrap_or_else(|| "none".into());
    Ok(json!({
        "name": found.id,
        "uuid": found.uuid,
        "path": found.path,
        "method": method,
        "pac": field_string(proxy.as_ref(), "pac-url")?.unwrap_or_default(),
        "http": field_string(proxy.as_ref(), "http")?.unwrap_or_default(),
        "https": field_string(proxy.as_ref(), "https")?.unwrap_or_default(),
        "socks": field_string(proxy.as_ref(), "socks")?.unwrap_or_default(),
        "bypass": text_list(proxy.as_ref().and_then(|item| item.lookup("no-proxy")).as_ref()),
    }))
}
