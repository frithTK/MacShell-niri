//! Which NetworkManager profiles the shell may change, and how proxy and
//! hotspot fields are validated. No D-Bus, files, or secrets are touched.
use std::cmp::Ordering;

pub const HOTSPOT_ID: &str = "MacShell Hotspot";
/// Second interface that stays in access-point mode while the station stays up.
pub const AP_IFACE: &str = "macshell-ap";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Class {
    /// A saved VPN or WireGuard profile this shell may connect and remove.
    Controllable,
    /// A tun/tap device owned outside this shell. Status only.
    External,
    Hidden,
}

pub fn classify(kind: &str) -> Class {
    match kind {
        "vpn" | "wireguard" => Class::Controllable,
        "tun" | "tap" => Class::External,
        _ => Class::Hidden,
    }
}

pub fn can_toggle(kind: &str) -> bool {
    classify(kind) == Class::Controllable
}

pub fn can_delete(kind: &str) -> bool {
    can_toggle(kind)
}

/// A saved VPN the shell is allowed to connect. `timestamp` is seconds, or 0
/// when NetworkManager has never activated the profile.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VpnCandidate {
    pub uuid: String,
    pub path: String,
    pub name: String,
    pub timestamp: u64,
    pub active: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VpnPlan {
    /// Connect `uuid` after disconnecting every other active profile in `stop`.
    Up {
        path: String,
        uuid: String,
        stop: Vec<(String, String)>,
    },
    /// Disconnect every active profile. The switch has nothing to turn on.
    Down { stop: Vec<(String, String)> },
}

fn prefer_vpn(current: &VpnCandidate, other: &VpnCandidate) -> bool {
    if current.timestamp != other.timestamp {
        return current.timestamp > other.timestamp;
    }
    if current.name != other.name {
        return current.name < other.name;
    }
    current.uuid <= other.uuid
}

fn chosen<'a>(rows: &'a [VpnCandidate], indexes: &[usize]) -> Option<usize> {
    indexes.iter().copied().reduce(|best, index| {
        if prefer_vpn(&rows[best], &rows[index]) {
            best
        } else {
            index
        }
    })
}

/// The profile the VPN switch represents. An active profile wins. Otherwise
/// the most recently used profile wins. A profile that has never connected is
/// not a switch target.
pub fn vpn_target(rows: &[VpnCandidate]) -> Option<usize> {
    let active: Vec<usize> = rows
        .iter()
        .enumerate()
        .filter(|(_, row)| row.active)
        .map(|(index, _)| index)
        .collect();
    if let Some(index) = chosen(rows, &active) {
        return Some(index);
    }
    let used: Vec<usize> = rows
        .iter()
        .enumerate()
        .filter(|(_, row)| row.timestamp > 0)
        .map(|(index, _)| index)
        .collect();
    chosen(rows, &used)
}

pub fn vpn_plan(rows: &[VpnCandidate], enabled: bool) -> Result<VpnPlan, &'static str> {
    let stop_of = |except: Option<usize>| {
        rows.iter()
            .enumerate()
            .filter(|(index, row)| row.active && Some(*index) != except)
            .map(|(_, row)| (row.path.clone(), row.uuid.clone()))
            .collect()
    };
    if !enabled {
        return Ok(VpnPlan::Down {
            stop: stop_of(None),
        });
    }
    let index = vpn_target(rows).ok_or("There is no saved VPN to turn on.")?;
    let row = &rows[index];
    Ok(VpnPlan::Up {
        path: row.path.clone(),
        uuid: row.uuid.clone(),
        stop: stop_of(Some(index)),
    })
}

/// Connect one saved profile and disconnect any other active profile first.
pub fn vpn_connect(rows: &[VpnCandidate], uuid: &str) -> Result<VpnPlan, &'static str> {
    let index = rows
        .iter()
        .position(|row| row.uuid == uuid)
        .ok_or("This connection cannot be changed from here.")?;
    let row = &rows[index];
    Ok(VpnPlan::Up {
        path: row.path.clone(),
        uuid: row.uuid.clone(),
        stop: rows
            .iter()
            .enumerate()
            .filter(|(other, candidate)| candidate.active && *other != index)
            .map(|(_, candidate)| (candidate.path.clone(), candidate.uuid.clone()))
            .collect(),
    })
}

pub fn cmp_vpn_list(
    a_active: bool,
    a_timestamp: u64,
    a_name: &str,
    b_active: bool,
    b_timestamp: u64,
    b_name: &str,
) -> Ordering {
    b_active
        .cmp(&a_active)
        .then(b_timestamp.cmp(&a_timestamp))
        .then(a_name.cmp(b_name))
}

pub fn valid_uuid(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => *byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
}

pub fn valid_settings_path(path: &str) -> bool {
    const PREFIX: &str = "/org/freedesktop/NetworkManager/Settings/";
    path.len() <= 1024
        && path.strip_prefix(PREFIX).is_some_and(|tail| {
            !tail.is_empty()
                && tail.split('/').all(|segment| {
                    !segment.is_empty()
                        && segment
                            .bytes()
                            .all(|c| c.is_ascii_alphanumeric() || c == b'_')
                })
        })
}

/// The form still describes the connection that owns the default route.
pub fn same_route(shown: &str, current: &str) -> bool {
    valid_uuid(shown) && shown == current
}

pub fn import_kind(path: &str) -> Result<&'static str, &'static str> {
    if path.is_empty()
        || path.len() > 4096
        || path.contains('\0')
        || !path.starts_with('/')
        || path.ends_with('/')
    {
        return Err("The file is not a readable profile.");
    }
    let lower = path.to_ascii_lowercase();
    if lower.ends_with(".ovpn") {
        Ok("openvpn")
    } else if lower.ends_with(".conf") {
        Ok("wireguard")
    } else {
        Err("The file is not a readable profile.")
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProxyForm {
    pub method: String,
    pub pac: String,
    pub http: String,
    pub https: String,
    pub socks: String,
    pub bypass: String,
}

pub fn validate_proxy(
    method: &str,
    pac: &str,
    http: &str,
    https: &str,
    socks: &str,
    bypass: &str,
) -> Result<ProxyForm, &'static str> {
    let bypass = normalize_bypass(bypass)?;
    let form = match method {
        "none" => ProxyForm {
            method: "none".into(),
            pac: String::new(),
            http: String::new(),
            https: String::new(),
            socks: String::new(),
            bypass,
        },
        "auto" => ProxyForm {
            method: "auto".into(),
            pac: normalize_pac(pac)?,
            http: String::new(),
            https: String::new(),
            socks: String::new(),
            bypass,
        },
        "manual" => {
            let http = normalize_endpoint(http, true)?;
            let https = normalize_endpoint(https, true)?;
            let socks = normalize_endpoint(socks, true)?;
            if http.is_empty() && https.is_empty() && socks.is_empty() {
                return Err("Enter at least one proxy address.");
            }
            ProxyForm {
                method: "manual".into(),
                pac: String::new(),
                http,
                https,
                socks,
                bypass,
            }
        }
        _ => return Err("Unknown proxy mode."),
    };
    Ok(form)
}

pub fn validate_hotspot(ssid: &str, password: &str) -> Result<(), &'static str> {
    let bytes = ssid.as_bytes();
    if bytes.is_empty() || bytes.len() > 32 || bytes.contains(&0) {
        return Err("The hotspot name must be 1–32 bytes.");
    }
    let length = password.chars().count();
    if !(8..=63).contains(&length) || password.as_bytes().contains(&0) {
        return Err("The hotspot password must contain 8–63 characters.");
    }
    Ok(())
}

/// A netdev name that can be passed to `iw` without a shell.
pub fn valid_netdev(name: &str) -> bool {
    let bytes = name.as_bytes();
    (1..=15).contains(&bytes.len())
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(*byte, b'-' | b'_' | b'.'))
        && bytes[0].is_ascii_alphanumeric()
        && !name.contains("..")
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ShareChannel {
    pub band: &'static str,
    pub channel: u32,
}

/// Channel the access point must use so it can share an already associated station.
/// DFS frequencies are refused: the radio cannot leave the station's channel.
pub fn share_channel(mhz: u32) -> Result<ShareChannel, &'static str> {
    let refused = "The current Wi-Fi channel does not allow an access point.";
    let (band, channel) = match mhz {
        2412..=2472 if (mhz - 2412) % 5 == 0 => ("bg", (mhz - 2407) / 5),
        2484 => ("bg", 14),
        5160..=5885 if (mhz - 5000) % 5 == 0 && !(5260..=5720).contains(&mhz) => {
            ("a", (mhz - 5000) / 5)
        }
        _ => return Err(refused),
    };
    Ok(ShareChannel { band, channel })
}

/// Any connected device with a gateway can be the NAT upstream, including the
/// station. The access point itself is not an upstream.
pub fn shares_upstream(
    state: u32,
    gateway: &str,
    profile: &str,
    hotspot_profile: &str,
    interface: &str,
) -> bool {
    state == 100
        && !gateway.is_empty()
        && interface != AP_IFACE
        && (hotspot_profile.is_empty() || profile != hotspot_profile)
}

fn normalize_bypass(value: &str) -> Result<String, &'static str> {
    if value.is_empty() {
        return Ok(String::new());
    }
    if value.len() > 2048 || value.contains('\0') {
        return Err("The proxy bypass list is invalid.");
    }
    let mut items = Vec::new();
    for part in value.split(',') {
        let item = part.trim();
        if item.is_empty()
            || item.len() > 253
            || item.chars().any(|c| c.is_whitespace() || c == ',')
        {
            return Err("The proxy bypass list is invalid.");
        }
        items.push(item);
        if items.len() > 32 {
            return Err("The proxy bypass list is invalid.");
        }
    }
    Ok(items.join(","))
}

fn normalize_pac(value: &str) -> Result<String, &'static str> {
    if value.len() > 2048
        || value.contains('\0')
        || value.chars().any(|c| c.is_whitespace())
        || !(value.starts_with("http://") || value.starts_with("https://"))
        || value.contains('@')
    {
        return Err("The PAC address must be an http or https URL.");
    }
    Ok(value.into())
}

fn normalize_endpoint(value: &str, allow_empty: bool) -> Result<String, &'static str> {
    if value.is_empty() && allow_empty {
        return Ok(String::new());
    }
    if value.len() > 300 || value.contains('\0') || value.contains('@') || value.contains('/') {
        return Err("Enter a proxy as host:port.");
    }
    let (host, port) = value
        .rsplit_once(':')
        .ok_or("Enter a proxy as host:port.")?;
    let (host, bracketed) = if let Some(inner) = host.strip_prefix('[') {
        (
            inner
                .strip_suffix(']')
                .filter(|inner| !inner.is_empty() && !inner.contains(['[', ']']))
                .ok_or("Enter a proxy as host:port.")?,
            true,
        )
    } else {
        (host, false)
    };
    if host.is_empty()
        || (!bracketed && host.contains(':'))
        || host.chars().any(|c| c.is_whitespace())
    {
        return Err("Enter a proxy as host:port.");
    }
    let port: u16 = port.parse().map_err(|_| "Enter a proxy as host:port.")?;
    if port == 0 {
        return Err("Enter a proxy as host:port.");
    }
    Ok(value.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tun_is_visible_and_not_controllable() {
        assert_eq!(classify("tun"), Class::External);
        assert_eq!(classify("tap"), Class::External);
        assert!(!can_toggle("tun"));
        assert!(!can_delete("tun"));
        assert!(can_toggle("vpn"));
        assert!(can_delete("wireguard"));
        assert_eq!(classify("802-11-wireless"), Class::Hidden);
        assert!(!can_delete("802-11-wireless"));
    }

    #[test]
    fn proxy_rejects_credentials_and_empty_manual() {
        assert!(validate_proxy("manual", "", "", "", "", "").is_err());
        assert!(validate_proxy("manual", "", "user:pass@127.0.0.1:8080", "", "", "").is_err());
        assert!(validate_proxy("auto", "http://user:x@example/p.pac", "", "", "", "").is_err());
        assert!(validate_proxy("auto", "ftp://example/p.pac", "", "", "", "").is_err());
        let form = validate_proxy(
            "manual",
            "",
            "127.0.0.1:8080",
            "",
            "[::1]:1080",
            "localhost, .example.com ",
        )
        .unwrap();
        assert_eq!(form.http, "127.0.0.1:8080");
        assert_eq!(form.socks, "[::1]:1080");
        assert_eq!(form.bypass, "localhost,.example.com");
        assert!(validate_proxy("manual", "", "127.0.0.1:0", "", "", "").is_err());
        assert_eq!(
            validate_proxy("none", "http://x", "h:1", "", "", "")
                .unwrap()
                .method,
            "none"
        );
    }

    #[test]
    fn route_and_hotspot_identity() {
        let id = "3718c1e5-a111-4296-95c7-f94132062a85";
        assert!(same_route(id, id));
        assert!(!same_route(id, "d3e5e0e1-ac1d-4fa6-9804-30f20f2d2cce"));
        assert!(!same_route("tun0", "tun0"));
        assert!(validate_hotspot("Cabin", "correct horse").is_ok());
        assert!(validate_hotspot("Cabin", "short").is_err());
        assert!(validate_hotspot(&"a".repeat(33), "correct horse").is_err());
        assert!(validate_hotspot("a", "").is_err());
        assert!(valid_netdev("wlan0"));
        assert!(valid_netdev(AP_IFACE));
        assert!(!valid_netdev(""));
        assert!(!valid_netdev("../wlan0"));
        assert!(!valid_netdev(".wlan"));
        assert!(!valid_netdev(&"w".repeat(16)));
        assert_eq!(
            share_channel(5180).unwrap(),
            ShareChannel {
                band: "a",
                channel: 36
            }
        );
        assert_eq!(
            share_channel(2412).unwrap(),
            ShareChannel {
                band: "bg",
                channel: 1
            }
        );
        assert_eq!(
            share_channel(2437).unwrap(),
            ShareChannel {
                band: "bg",
                channel: 6
            }
        );
        assert!(share_channel(5260).is_err());
        assert!(share_channel(5720).is_err());
        assert!(share_channel(5955).is_err());
        assert!(share_channel(2413).is_err());
        let hotspot = "/org/freedesktop/NetworkManager/Settings/9";
        assert!(shares_upstream(
            100,
            "192.168.1.1",
            "/org/freedesktop/NetworkManager/Settings/3",
            hotspot,
            "wlan0"
        ));
        assert!(!shares_upstream(
            100,
            "10.42.0.1",
            hotspot,
            hotspot,
            AP_IFACE
        ));
        assert!(!shares_upstream(
            100,
            "",
            "/org/freedesktop/NetworkManager/Settings/3",
            hotspot,
            "wlan0"
        ));
        assert!(!shares_upstream(
            30,
            "192.168.1.1",
            "/org/freedesktop/NetworkManager/Settings/3",
            hotspot,
            "wlan0"
        ));
        assert_eq!(import_kind("/home/a/office.ovpn").unwrap(), "openvpn");
        assert_eq!(import_kind("/home/a/wg.conf").unwrap(), "wireguard");
        assert!(import_kind("/home/a/notes.txt").is_err());
        assert!(import_kind("office.ovpn").is_err());
        assert!(valid_settings_path(
            "/org/freedesktop/NetworkManager/Settings/7"
        ));
        assert!(!valid_settings_path("/tmp/profile"));
    }

    fn vpn(name: &str, timestamp: u64, active: bool) -> VpnCandidate {
        VpnCandidate {
            uuid: format!(
                "00000000-0000-4000-8000-{:012}",
                name.len() + timestamp as usize
            ),
            path: format!("/org/freedesktop/NetworkManager/Settings/{name}"),
            name: name.into(),
            timestamp,
            active,
        }
    }

    #[test]
    fn vpn_switch_uses_the_active_profile_then_the_latest() {
        let unused = vpn("Fresh", 0, false);
        assert!(vpn_plan(&[unused.clone()], true).is_err());
        assert_eq!(
            vpn_plan(&[unused], false),
            Ok(VpnPlan::Down { stop: vec![] })
        );

        let older = vpn("Home", 10, false);
        let newer = vpn("Office", 20, false);
        let plan = vpn_plan(&[older.clone(), newer.clone()], true).unwrap();
        assert_eq!(
            plan,
            VpnPlan::Up {
                path: newer.path.clone(),
                uuid: newer.uuid.clone(),
                stop: vec![]
            }
        );

        let tied = vpn("Alpha", 20, false);
        let also = vpn("Beta", 20, false);
        match vpn_plan(&[also.clone(), tied.clone()], true).unwrap() {
            VpnPlan::Up { uuid, .. } => assert_eq!(uuid, tied.uuid),
            other => panic!("expected Alpha, got {other:?}"),
        }

        let active = vpn("Home", 10, true);
        let later = vpn("Office", 30, false);
        match vpn_plan(&[later, active.clone()], true).unwrap() {
            VpnPlan::Up { uuid, stop, .. } => {
                assert_eq!(uuid, active.uuid);
                assert!(stop.is_empty());
            }
            other => panic!("expected the active profile, got {other:?}"),
        }

        let second = vpn("Office", 40, true);
        match vpn_plan(&[active.clone(), second.clone()], false).unwrap() {
            VpnPlan::Down { stop } => {
                assert_eq!(stop.len(), 2);
            }
            other => panic!("expected both to stop, got {other:?}"),
        }
        match vpn_connect(&[active.clone(), second.clone()], &second.uuid).unwrap() {
            VpnPlan::Up { uuid, stop, .. } => {
                assert_eq!(uuid, second.uuid);
                assert_eq!(stop, vec![(active.path, active.uuid)]);
            }
            other => panic!("expected Office, got {other:?}"),
        }
        assert!(vpn_connect(&[second], "missing").is_err());
        assert_eq!(cmp_vpn_list(true, 1, "B", false, 9, "A"), Ordering::Less);
    }
}
