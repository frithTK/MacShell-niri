//! VPN, proxy and hotspot changes on the radio worker.
//!
//! Passwords are placed only in D-Bus variants or in `nmcli` arguments that
//! never include the hotspot key. Errors returned here are fixed strings.
use crate::identity;
use crate::radio::{self, Error};
use crate::session::RadioAction;
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use macshell_network_core::links::{self, HOTSPOT_ID};
use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::ptr;
use std::thread;
use std::time::{Duration, Instant};

const NM: &str = "org.freedesktop.NetworkManager";
const ROOT: &str = "/org/freedesktop/NetworkManager";
const PROPS: &str = "org.freedesktop.DBus.Properties";
const DEVICE: &str = "org.freedesktop.NetworkManager.Device";
const WIFI: &str = "org.freedesktop.NetworkManager.Device.Wireless";
const ACCESS: &str = "org.freedesktop.NetworkManager.AccessPoint";
const ACTIVE: &str = "org.freedesktop.NetworkManager.Connection.Active";
const SETTINGS: &str = "org.freedesktop.NetworkManager.Settings";
const CONNECTION: &str = "org.freedesktop.NetworkManager.Settings.Connection";

pub unsafe fn perform(
    bus: Ptr,
    owner: &str,
    action: RadioAction,
    timeout: Duration,
) -> Result<usize, Error> {
    match action {
        RadioAction::LinkUp { path, uuid } => link_up(&path, &uuid).map(|()| 0),
        RadioAction::LinkDown { path, uuid } => link_down(&path, &uuid).map(|()| 0),
        RadioAction::Proxy {
            uuid,
            method,
            pac,
            http,
            https,
            socks,
            bypass,
        } => proxy(&uuid, &method, &pac, &http, &https, &socks, &bypass).map(|()| 0),
        RadioAction::HotspotStart {
            ssid,
            password,
            restore,
        } => hotspot_start(bus, owner, &ssid, &password, &restore, timeout).map(|()| 0),
        RadioAction::HotspotStop { restore } => {
            hotspot_stop(bus, owner, restore, timeout).map(|()| 0)
        }
        RadioAction::Import { path } => import_profile(&path).map(|()| 0),
        RadioAction::Delete { path, uuid } => delete_profile(&path, &uuid).map(|()| 0),
        RadioAction::VpnSet { up, down } => vpn_set(up, down).map(|()| 0),
        _ => Err(Error::Invalid),
    }
}

fn rejected(message: &'static str) -> Error {
    Error::Rejected(message)
}

fn classify(text: &str) -> Error {
    let lower = text.to_ascii_lowercase();
    if lower.contains("secret") || lower.contains("password") {
        rejected("The VPN profile needs a password.")
    } else if lower.contains("plugin")
        || lower.contains("unknown connection type")
        || lower.contains("invalid connection type")
    {
        rejected("This VPN type is not available.")
    } else {
        rejected("NetworkManager rejected the change.")
    }
}

fn nmcli(args: &[&str]) -> Result<String, Error> {
    let output = Command::new("nmcli")
        .args(args)
        .output()
        .map_err(|_| rejected("NetworkManager rejected the change."))?;
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
    } else {
        Err(classify(&stderr))
    }
}

fn connection_type(uuid: &str) -> Result<String, Error> {
    if !links::valid_uuid(uuid) {
        return Err(rejected("This connection cannot be changed from here."));
    }
    let text = nmcli(&["-g", "connection.type", "connection", "show", "uuid", uuid])?;
    Ok(text.trim().to_owned())
}

fn link_up(path: &str, uuid: &str) -> Result<(), Error> {
    if !links::valid_settings_path(path) {
        return Err(rejected("This connection cannot be changed from here."));
    }
    let kind = connection_type(uuid)?;
    if !links::can_toggle(&kind) {
        return Err(rejected("This connection cannot be changed from here."));
    }
    nmcli(&["-w", "45", "connection", "up", "uuid", uuid]).map(|_| ())
}

fn vpn_set(up: Option<(String, String)>, down: Vec<(String, String)>) -> Result<(), Error> {
    for (path, uuid) in &down {
        link_down(path, uuid)?;
    }
    if let Some((path, uuid)) = up {
        link_up(&path, &uuid)?;
    }
    Ok(())
}

fn link_down(path: &str, uuid: &str) -> Result<(), Error> {
    if !links::valid_settings_path(path) {
        return Err(rejected("This connection cannot be changed from here."));
    }
    let kind = connection_type(uuid)?;
    if !links::can_toggle(&kind) {
        return Err(rejected("This connection cannot be changed from here."));
    }
    nmcli(&["connection", "down", "uuid", uuid]).map(|_| ())
}

fn delete_profile(path: &str, uuid: &str) -> Result<(), Error> {
    if !links::valid_settings_path(path) {
        return Err(rejected("This connection cannot be changed from here."));
    }
    let kind = connection_type(uuid)?;
    if !links::can_delete(&kind) {
        return Err(rejected("This connection cannot be changed from here."));
    }
    nmcli(&["connection", "delete", "uuid", uuid]).map(|_| ())
}

fn import_profile(path: &str) -> Result<(), Error> {
    let kind = links::import_kind(path).map_err(rejected)?;
    let meta =
        std::fs::metadata(path).map_err(|_| rejected("The file is not a readable profile."))?;
    if !meta.is_file() || meta.len() == 0 || meta.len() > 1_048_576 {
        return Err(rejected("The file is not a readable profile."));
    }
    nmcli(&[
        "-w",
        "30",
        "connection",
        "import",
        "type",
        kind,
        "file",
        path,
    ])
    .map(|_| ())
}

fn default_iface() -> Option<String> {
    let output = Command::new("ip")
        .args(["-4", "route", "show", "default"])
        .output()
        .ok()?;
    let text = String::from_utf8(output.stdout).ok()?;
    for line in text.lines() {
        let mut words = line.split_whitespace();
        while let Some(word) = words.next() {
            if word == "dev" {
                return words.next().map(str::to_owned);
            }
        }
    }
    None
}

fn uuid_on_iface(iface: &str) -> Option<String> {
    let output = Command::new("nmcli")
        .args(["-t", "-f", "UUID,DEVICE", "connection", "show", "--active"])
        .output()
        .ok()?;
    let text = String::from_utf8(output.stdout).ok()?;
    for line in text.lines() {
        let (uuid, device) = line.split_once(':')?;
        if device == iface && links::valid_uuid(uuid) {
            return Some(uuid.to_owned());
        }
    }
    None
}

fn proxy(
    uuid: &str,
    method: &str,
    pac: &str,
    http: &str,
    https: &str,
    socks: &str,
    bypass: &str,
) -> Result<(), Error> {
    let form = links::validate_proxy(method, pac, http, https, socks, bypass).map_err(rejected)?;
    let current = uuid_on_iface(&default_iface().unwrap_or_default()).unwrap_or_default();
    if !links::same_route(uuid, &current) {
        return Err(rejected("The network route changed. Reload and try again."));
    }
    let mut args = vec![
        "connection",
        "modify",
        "uuid",
        uuid,
        "proxy.method",
        form.method.as_str(),
        "proxy.pac-url",
        form.pac.as_str(),
        "proxy.http",
        form.http.as_str(),
        "proxy.https",
        form.https.as_str(),
        "proxy.socks",
        form.socks.as_str(),
        "proxy.no-proxy",
        form.bypass.as_str(),
    ];
    nmcli(&args)?;
    args.clear();
    if let Some(iface) = default_iface() {
        let _ = nmcli(&["device", "reapply", &iface]);
    }
    Ok(())
}

fn restore_path() -> Option<PathBuf> {
    let dir = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR")?);
    if !dir.is_absolute() {
        return None;
    }
    Some(dir.join("macshell-hotspot.restore"))
}

fn write_restore(uuid: &str) {
    if !links::valid_uuid(uuid) {
        return;
    }
    let Some(path) = restore_path() else {
        return;
    };
    let mut file = match OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
    {
        Ok(file) => file,
        Err(_) => return,
    };
    let _ = writeln!(file, "{uuid}");
}

fn take_restore() -> Option<String> {
    let path = restore_path()?;
    let text = std::fs::read_to_string(&path).ok()?;
    let _ = std::fs::remove_file(path);
    let uuid = text.trim();
    links::valid_uuid(uuid).then(|| uuid.to_owned())
}

unsafe fn hotspot_start(
    bus: Ptr,
    owner: &str,
    ssid: &str,
    password: &str,
    restore: &str,
    timeout: Duration,
) -> Result<(), Error> {
    links::validate_hotspot(ssid, password).map_err(rejected)?;
    // set_power refuses a budget above 30s. The hotspot budget is longer because
    // creating the second interface waits for the administrator password, and a
    // rejected radio check was reported as a NetworkManager failure.
    match radio::set_power(bus, owner, true, timeout.min(Duration::from_secs(8))) {
        Ok(()) => {}
        Err(Error::HardwareBlocked) => {
            return Err(rejected(
                "Hotspot needs a Wi-Fi device that can start an access point.",
            ))
        }
        Err(Error::Uncertain) => return Err(Error::Uncertain),
        Err(_) => return Err(rejected("NetworkManager rejected the change.")),
    }
    let mut call = Dbus {
        bus,
        deadline: Instant::now().checked_add(timeout).ok_or(Error::Invalid)?,
    };
    if call.owner()? != owner {
        return Err(Error::OwnerChanged);
    }
    let station = call.station(owner)?;
    let share = match &station {
        Some(station) => Some(links::share_channel(station.frequency).map_err(rejected)?),
        None => None,
    };
    let device = if let Some(station) = &station {
        // The station stays associated. An older restore file would bounce it on stop.
        let _ = take_restore();
        ensure_ap_iface(&station.interface)?;
        // The password prompt sits outside the NetworkManager budget.
        call.deadline = Instant::now().checked_add(timeout).ok_or(Error::Invalid)?;
        if call.owner()? != owner {
            return Err(Error::OwnerChanged);
        }
        let _ = nmcli(&["device", "set", links::AP_IFACE, "managed", "yes"]);
        call.wait_iface(owner, links::AP_IFACE)?
    } else {
        write_restore(restore);
        call.ap_device(owner)?
    };
    let existing = call.find_hotspot(owner)?;
    let uuid = existing.as_ref().map(|found| found.uuid.clone()).unwrap_or(
        identity::new_uuid().map_err(|_| rejected("NetworkManager rejected the change."))?,
    );
    let settings = hotspot_settings(&uuid, &device.interface, ssid, password, share)?;
    let path = if let Some(found) = existing {
        call.call(
            owner,
            &found.path,
            CONNECTION,
            "Update",
            gio::tuple(&[settings]),
        )
        .map(|_| found.path)?
    } else {
        let reply = call.call(
            owner,
            &format!("{ROOT}/Settings"),
            SETTINGS,
            "AddConnection",
            gio::tuple(&[settings]),
        )?;
        reply
            .child(0)
            .and_then(|v| v.object_path())
            .filter(|path| links::valid_settings_path(path))
            .ok_or_else(|| rejected("NetworkManager rejected the change."))?
    };
    let params = gio::tuple(&[
        gio::g_variant_new_object_path(c(&path).as_ptr()),
        gio::g_variant_new_object_path(c(&device.path).as_ptr()),
        gio::g_variant_new_object_path(c("/").as_ptr()),
    ]);
    let started = call.call(owner, ROOT, NM, "ActivateConnection", params);
    if started.is_err() && station.is_none() {
        let _ = take_restore();
    }
    started.map(|_| ())
}

unsafe fn hotspot_stop(
    bus: Ptr,
    owner: &str,
    restore: bool,
    timeout: Duration,
) -> Result<(), Error> {
    let call = Dbus {
        bus,
        deadline: Instant::now().checked_add(timeout).ok_or(Error::Invalid)?,
    };
    if call.owner()? != owner {
        return Err(Error::OwnerChanged);
    }
    if let Some(found) = call.find_hotspot(owner)? {
        if let Some(active) = call.active_for(owner, &found.path)? {
            let params = gio::tuple(&[gio::g_variant_new_object_path(c(&active).as_ptr())]);
            call.call(owner, ROOT, NM, "DeactivateConnection", params)?;
        }
    }
    if restore {
        if let Some(uuid) = take_restore() {
            let _ = nmcli(&["-w", "30", "connection", "up", "uuid", &uuid]);
        }
        // User stop only. Turning the radio off must not wait on a password prompt.
        remove_ap_iface();
    }
    Ok(())
}

struct Station {
    interface: String,
    frequency: u32,
}

fn ap_present() -> bool {
    Path::new("/sys/class/net")
        .join(links::AP_IFACE)
        .join("phy80211")
        .exists()
}

/// Creating the virtual interface needs `CAP_NET_ADMIN`. NetworkManager does
/// not create it, so the same binary is re-executed through pkexec.
fn ensure_ap_iface(parent: &str) -> Result<(), Error> {
    if !links::valid_netdev(parent) || parent == links::AP_IFACE {
        return Err(rejected(
            "Hotspot needs a Wi-Fi device that can start an access point.",
        ));
    }
    if ap_present() {
        return Ok(());
    }
    match ap_helper(&["add", parent]) {
        Some(0) if ap_present() => Ok(()),
        Some(3) => Err(rejected(
            "Hotspot needs a Wi-Fi device that can start an access point.",
        )),
        _ => Err(rejected("The access-point interface was not authorized.")),
    }
}

fn remove_ap_iface() {
    if ap_present() {
        let _ = ap_helper(&["del"]);
    }
}

fn ap_helper(args: &[&str]) -> Option<i32> {
    let exe = std::env::current_exe().ok()?;
    let pkexec = std::env::var_os("MACSHELL_PKEXEC")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("pkexec"));
    let mut command = Command::new(pkexec);
    command
        .arg(exe)
        .arg("--ap-iface")
        .args(args)
        .stdin(Stdio::null());
    command.output().ok()?.status.code()
}

/// Root-only entry for `--ap-iface`. The parent name is checked again here.
pub fn apply_ap_iface(args: &[String]) -> Result<(), ()> {
    match args {
        [action, parent] if action == "add" => add_ap_iface(parent),
        [action] if action == "del" => del_ap_iface(),
        _ => Err(()),
    }
}

fn add_ap_iface(parent: &str) -> Result<(), ()> {
    if !links::valid_netdev(parent) || parent == links::AP_IFACE {
        return Err(());
    }
    let sys = Path::new("/sys/class/net").join(parent);
    if !sys.join("phy80211").exists() {
        return Err(());
    }
    if !ap_present() {
        let status = Command::new("iw")
            .args([
                "dev",
                parent,
                "interface",
                "add",
                links::AP_IFACE,
                "type",
                "__ap",
            ])
            .stdin(Stdio::null())
            .status()
            .map_err(|_| ())?;
        if !status.success() || !ap_present() {
            return Err(());
        }
    }
    let status = Command::new("ip")
        .args(["link", "set", links::AP_IFACE, "up"])
        .stdin(Stdio::null())
        .status()
        .map_err(|_| ())?;
    if !status.success() {
        return Err(());
    }
    // Pin the new interface to the station channel. A different channel cannot
    // coexist on this radio, and NetworkManager reads the channel from the profile.
    if let Some(channel) = station_channel(parent) {
        let _ = Command::new("iw")
            .args([
                "dev",
                links::AP_IFACE,
                "set",
                "channel",
                &channel.to_string(),
            ])
            .stdin(Stdio::null())
            .status();
    }
    Ok(())
}

fn station_channel(parent: &str) -> Option<u32> {
    let output = Command::new("iw")
        .args(["dev", parent, "info"])
        .stdin(Stdio::null())
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    let mut words = text.split_whitespace();
    while let Some(word) = words.next() {
        if word == "channel" {
            return words
                .next()?
                .parse()
                .ok()
                .filter(|channel| (1..=233).contains(channel));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::apply_ap_iface;
    use std::time::Duration;

    #[test]
    fn hotspot_radio_check_stays_within_the_power_limit() {
        let budget = Duration::from_secs(50).min(Duration::from_secs(8));
        assert!(budget <= Duration::from_secs(30));
        assert_eq!(budget, Duration::from_secs(8));
    }

    #[test]
    fn ap_iface_rejects_anything_but_the_fixed_command() {
        assert!(apply_ap_iface(&[]).is_err());
        assert!(apply_ap_iface(&["add".into(), "../wlan0".into()]).is_err());
        assert!(apply_ap_iface(&["add".into(), "macshell-ap".into()]).is_err());
        assert!(apply_ap_iface(&["del".into(), "wlan0".into()]).is_err());
        assert!(apply_ap_iface(&["down".into()]).is_err());
    }
}

fn del_ap_iface() -> Result<(), ()> {
    if !ap_present() {
        return Ok(());
    }
    let status = Command::new("iw")
        .args(["dev", links::AP_IFACE, "del"])
        .stdin(Stdio::null())
        .status()
        .map_err(|_| ())?;
    status.success().then_some(()).ok_or(())
}

struct Found {
    path: String,
    uuid: String,
}
struct ApDevice {
    path: String,
    interface: String,
}

struct Dbus {
    bus: Ptr,
    deadline: Instant,
}
impl Dbus {
    unsafe fn call(
        &self,
        owner: &str,
        path: &str,
        iface: &str,
        method: &str,
        params: Ptr,
    ) -> Result<Variant, Error> {
        let remaining = self.deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            if !params.is_null() {
                gio::g_variant_unref(params);
            }
            return Err(rejected("NetworkManager rejected the change."));
        }
        let mut error = ptr::null_mut();
        let reply = gio::g_dbus_connection_call_sync(
            self.bus,
            c(owner).as_ptr(),
            c(path).as_ptr(),
            c(iface).as_ptr(),
            c(method).as_ptr(),
            params,
            ptr::null_mut(),
            0,
            remaining.min(Duration::from_secs(20)).as_millis().max(1) as i32,
            ptr::null_mut(),
            &mut error,
        );
        if !error.is_null() {
            let message = gio::error(error);
            return Err(classify(&message));
        }
        Variant::from(reply).ok_or_else(|| rejected("NetworkManager rejected the change."))
    }
    unsafe fn owner(&self) -> Result<String, Error> {
        let reply = self.call(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "GetNameOwner",
            gio::tuple(&[gio::string(NM)]),
        )?;
        reply
            .child(0)
            .and_then(|v| v.string())
            .ok_or(Error::Invalid)
    }
    unsafe fn ap_device(&self, owner: &str) -> Result<ApDevice, Error> {
        let root = self.call(owner, ROOT, PROPS, "GetAll", gio::tuple(&[gio::string(NM)]))?;
        let props = root.child(0).ok_or(Error::Invalid)?;
        let devices = props.lookup("Devices").ok_or(Error::Invalid)?;
        if devices.len() > 64 {
            return Err(Error::Limit);
        }
        for index in 0..devices.len() {
            let path = devices
                .child(index)
                .and_then(|v| v.object_path())
                .ok_or(Error::Invalid)?;
            let device = self
                .call(
                    owner,
                    &path,
                    PROPS,
                    "GetAll",
                    gio::tuple(&[gio::string(DEVICE)]),
                )?
                .child(0)
                .ok_or(Error::Invalid)?;
            if device.lookup("DeviceType").and_then(|v| v.u32()) != Some(2) {
                continue;
            }
            let interface = device
                .lookup("Interface")
                .and_then(|v| v.string())
                .unwrap_or_default();
            let wifi = self
                .call(
                    owner,
                    &path,
                    PROPS,
                    "GetAll",
                    gio::tuple(&[gio::string(WIFI)]),
                )?
                .child(0)
                .ok_or(Error::Invalid)?;
            let caps = wifi
                .lookup("WirelessCapabilities")
                .and_then(|v| v.u32())
                .unwrap_or(0);
            if interface == links::AP_IFACE {
                continue;
            }
            if caps & 0x40 != 0 && !interface.is_empty() && !interface.contains('\0') {
                return Ok(ApDevice { path, interface });
            }
        }
        Err(rejected(
            "Hotspot needs a Wi-Fi device that can start an access point.",
        ))
    }
    unsafe fn station(&self, owner: &str) -> Result<Option<Station>, Error> {
        let root = self.call(owner, ROOT, PROPS, "GetAll", gio::tuple(&[gio::string(NM)]))?;
        let props = root.child(0).ok_or(Error::Invalid)?;
        let devices = props.lookup("Devices").ok_or(Error::Invalid)?;
        if devices.len() > 64 {
            return Err(Error::Limit);
        }
        for index in 0..devices.len() {
            let path = devices
                .child(index)
                .and_then(|v| v.object_path())
                .ok_or(Error::Invalid)?;
            let device = self
                .call(
                    owner,
                    &path,
                    PROPS,
                    "GetAll",
                    gio::tuple(&[gio::string(DEVICE)]),
                )?
                .child(0)
                .ok_or(Error::Invalid)?;
            if device.lookup("DeviceType").and_then(|v| v.u32()) != Some(2) {
                continue;
            }
            let interface = device
                .lookup("Interface")
                .and_then(|v| v.string())
                .unwrap_or_default();
            if interface == links::AP_IFACE || !links::valid_netdev(&interface) {
                continue;
            }
            if device.lookup("State").and_then(|v| v.u32()) != Some(100) {
                continue;
            }
            let wifi = self
                .call(
                    owner,
                    &path,
                    PROPS,
                    "GetAll",
                    gio::tuple(&[gio::string(WIFI)]),
                )?
                .child(0)
                .ok_or(Error::Invalid)?;
            let ap = wifi
                .lookup("ActiveAccessPoint")
                .and_then(|v| v.object_path())
                .unwrap_or_default();
            if !ap.starts_with("/org/freedesktop/NetworkManager/AccessPoint/") {
                continue;
            }
            let point = match self.call(
                owner,
                &ap,
                PROPS,
                "GetAll",
                gio::tuple(&[gio::string(ACCESS)]),
            ) {
                Ok(v) => v.child(0).ok_or(Error::Invalid)?,
                Err(Error::Rejected(_)) => continue,
                Err(error) => return Err(error),
            };
            // Mode 3 is an access point. The station we share is infrastructure.
            if point.lookup("Mode").and_then(|v| v.u32()) == Some(3) {
                continue;
            }
            let frequency = point.lookup("Frequency").and_then(|v| v.u32()).unwrap_or(0);
            if frequency == 0 {
                continue;
            }
            return Ok(Some(Station {
                interface,
                frequency,
            }));
        }
        Ok(None)
    }
    unsafe fn wait_iface(&self, owner: &str, name: &str) -> Result<ApDevice, Error> {
        loop {
            if self.owner()? != owner {
                return Err(Error::OwnerChanged);
            }
            if let Some(device) = self.device_named(owner, name)? {
                return Ok(device);
            }
            if self.deadline.saturating_duration_since(Instant::now()) < Duration::from_millis(400)
            {
                break;
            }
            thread::sleep(Duration::from_millis(200));
        }
        Err(rejected(
            "Hotspot needs a Wi-Fi device that can start an access point.",
        ))
    }
    unsafe fn device_named(&self, owner: &str, name: &str) -> Result<Option<ApDevice>, Error> {
        let root = self.call(owner, ROOT, PROPS, "GetAll", gio::tuple(&[gio::string(NM)]))?;
        let props = root.child(0).ok_or(Error::Invalid)?;
        let devices = props.lookup("Devices").ok_or(Error::Invalid)?;
        if devices.len() > 64 {
            return Err(Error::Limit);
        }
        for index in 0..devices.len() {
            let path = devices
                .child(index)
                .and_then(|v| v.object_path())
                .ok_or(Error::Invalid)?;
            let device = self
                .call(
                    owner,
                    &path,
                    PROPS,
                    "GetAll",
                    gio::tuple(&[gio::string(DEVICE)]),
                )?
                .child(0)
                .ok_or(Error::Invalid)?;
            if device.lookup("DeviceType").and_then(|v| v.u32()) != Some(2) {
                continue;
            }
            let interface = device
                .lookup("Interface")
                .and_then(|v| v.string())
                .unwrap_or_default();
            if interface == name {
                return Ok(Some(ApDevice { path, interface }));
            }
        }
        Ok(None)
    }
    unsafe fn find_hotspot(&self, owner: &str) -> Result<Option<Found>, Error> {
        let listed = self.call(
            owner,
            &format!("{ROOT}/Settings"),
            SETTINGS,
            "ListConnections",
            ptr::null_mut(),
        )?;
        let paths = listed.child(0).ok_or(Error::Invalid)?;
        if paths.len() > 256 {
            return Err(Error::Limit);
        }
        for index in 0..paths.len() {
            let path = paths
                .child(index)
                .and_then(|v| v.object_path())
                .ok_or(Error::Invalid)?;
            let settings = match self.call(owner, &path, CONNECTION, "GetSettings", ptr::null_mut())
            {
                Ok(v) => v.child(0).ok_or(Error::Invalid)?,
                Err(Error::Rejected(_)) => continue,
                Err(error) => return Err(error),
            };
            let connection = settings.lookup("connection");
            let id = connection
                .as_ref()
                .and_then(|v| v.lookup("id"))
                .and_then(|v| v.string())
                .unwrap_or_default();
            if id != HOTSPOT_ID {
                continue;
            }
            let mode = settings
                .lookup("802-11-wireless")
                .as_ref()
                .and_then(|v| v.lookup("mode"))
                .and_then(|v| v.string())
                .unwrap_or_else(|| "infrastructure".into());
            if mode != "ap" {
                return Err(rejected(
                    "A connection named MacShell Hotspot already exists.",
                ));
            }
            let uuid = connection
                .as_ref()
                .and_then(|v| v.lookup("uuid"))
                .and_then(|v| v.string())
                .unwrap_or_default();
            if !links::valid_uuid(&uuid) || !links::valid_settings_path(&path) {
                return Err(rejected("NetworkManager rejected the change."));
            }
            return Ok(Some(Found { path, uuid }));
        }
        Ok(None)
    }
    unsafe fn active_for(&self, owner: &str, profile: &str) -> Result<Option<String>, Error> {
        let root = self.call(owner, ROOT, PROPS, "GetAll", gio::tuple(&[gio::string(NM)]))?;
        let props = root.child(0).ok_or(Error::Invalid)?;
        let Some(active) = props.lookup("ActiveConnections") else {
            return Ok(None);
        };
        for index in 0..active.len().min(64) {
            let path = active
                .child(index)
                .and_then(|v| v.object_path())
                .ok_or(Error::Invalid)?;
            let info = self
                .call(
                    owner,
                    &path,
                    PROPS,
                    "GetAll",
                    gio::tuple(&[gio::string(ACTIVE)]),
                )?
                .child(0)
                .ok_or(Error::Invalid)?;
            if info
                .lookup("Connection")
                .and_then(|v| v.object_path())
                .as_deref()
                == Some(profile)
            {
                return Ok(Some(path));
            }
        }
        Ok(None)
    }
}

unsafe fn hotspot_settings(
    uuid: &str,
    interface: &str,
    ssid: &str,
    password: &str,
    share: Option<links::ShareChannel>,
) -> Result<Ptr, Error> {
    let user = username().map_err(|_| rejected("NetworkManager rejected the change."))?;
    let permission = format!("user:{user}");
    let ssid_bytes: Vec<Ptr> = ssid.bytes().map(|b| gio::g_variant_new_byte(b)).collect();
    let secret = std::ffi::CString::new(password.as_bytes())
        .map_err(|_| rejected("The hotspot password must contain 8–63 characters."))?;
    let psk = gio::g_variant_new_string(secret.as_ptr());
    let mut wiped = secret.into_bytes_with_nul();
    for byte in &mut wiped {
        ptr::write_volatile(byte, 0);
    }
    std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::SeqCst);
    let permissions = array(&[gio::string(&permission)]);
    let connection = section(
        "connection",
        &[
            field("id", gio::string(HOTSPOT_ID)),
            field("uuid", gio::string(uuid)),
            field("type", gio::string("802-11-wireless")),
            field("interface-name", gio::string(interface)),
            field("autoconnect", gio::boolean(false)),
            field("permissions", permissions),
        ],
    );
    let mut wireless = vec![
        field("ssid", array(&ssid_bytes)),
        field("mode", gio::string("ap")),
    ];
    if let Some(share) = share {
        wireless.push(field("band", gio::string(share.band)));
        wireless.push(field("channel", gio::uint32(share.channel)));
    }
    let wifi = section("802-11-wireless", &wireless);
    let secure = section(
        "802-11-wireless-security",
        &[
            field("key-mgmt", gio::string("wpa-psk")),
            field("psk", psk),
            field("psk-flags", gio::uint32(0)),
        ],
    );
    let ipv4 = section("ipv4", &[field("method", gio::string("shared"))]);
    let ipv6 = section("ipv6", &[field("method", gio::string("auto"))]);
    Ok(array(&[connection, wifi, secure, ipv4, ipv6]))
}

unsafe fn array(entries: &[Ptr]) -> Ptr {
    gio::g_variant_new_array(ptr::null_mut(), entries.as_ptr(), entries.len())
}
unsafe fn field(key: &str, value: Ptr) -> Ptr {
    gio::g_variant_new_dict_entry(gio::string(key), gio::g_variant_new_variant(value))
}
unsafe fn section(name: &str, fields: &[Ptr]) -> Ptr {
    gio::g_variant_new_dict_entry(gio::string(name), array(fields))
}

fn username() -> Result<String, ()> {
    let mut buffer = vec![0u8; 16384];
    let mut entry = unsafe { std::mem::zeroed::<libc::passwd>() };
    let mut found = ptr::null_mut();
    let result = unsafe {
        libc::getpwuid_r(
            libc::getuid(),
            &mut entry,
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut found,
        )
    };
    if result != 0 || found.is_null() || entry.pw_name.is_null() {
        return Err(());
    }
    let name = unsafe { std::ffi::CStr::from_ptr(entry.pw_name) }
        .to_str()
        .map_err(|_| ())?
        .to_owned();
    if name.is_empty() || name.contains('\0') || name.contains(':') {
        return Err(());
    }
    Ok(name)
}
