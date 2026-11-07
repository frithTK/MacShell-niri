//! User-requested NetworkManager Wi-Fi power change on a dedicated worker.
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use std::ptr;
use std::time::{Duration, Instant};

const NM: &str = "org.freedesktop.NetworkManager";
const ROOT: &str = "/org/freedesktop/NetworkManager";
const PROPS: &str = "org.freedesktop.DBus.Properties";
const DEVICE: &str = "org.freedesktop.NetworkManager.Device";
const WIFI: &str = "org.freedesktop.NetworkManager.Device.Wireless";

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    Invalid,
    Unavailable,
    HardwareBlocked,
    Limit,
    OwnerChanged,
    Stale,
    Uncertain,
}

/// Disconnect the explicitly selected, currently active access point once.
/// A fresh snapshot checks identity, but cannot make it atomic against other
/// NetworkManager clients. Success means the request was accepted.
///
/// # Safety
/// Use a dedicated bounded worker connection and serialize Wi-Fi writes.
/// Close the connection on `Uncertain` and never automatically retry.
pub unsafe fn disconnect(
    bus: Ptr,
    owner: &str,
    device: &str,
    ap: &str,
    timeout: Duration,
) -> Result<(), Error> {
    fn path(value: &str, prefix: &str) -> bool {
        value.len() <= 1024
            && value.strip_prefix(prefix).is_some_and(|tail| {
                !tail.is_empty()
                    && tail.split('/').all(|part| {
                        !part.is_empty()
                            && part.bytes().all(|v| v.is_ascii_alphanumeric() || v == b'_')
                    })
            })
    }
    if bus.is_null()
        || owner.contains('\0')
        || gio::g_dbus_is_unique_name(c(owner).as_ptr()) == 0
        || timeout.is_zero()
        || timeout > Duration::from_secs(30)
        || !path(device, "/org/freedesktop/NetworkManager/Devices/")
        || !path(ap, "/org/freedesktop/NetworkManager/AccessPoint/")
    {
        return Err(Error::Invalid);
    }
    let client = Client {
        bus,
        deadline: Instant::now().checked_add(timeout).ok_or(Error::Invalid)?,
    };
    if client.owner()? != owner {
        return Err(Error::OwnerChanged);
    }
    let remaining = client.deadline.saturating_duration_since(Instant::now());
    let snapshot = crate::read(bus, owner, remaining).map_err(|error| match error {
        crate::Error::OwnerChanged => Error::OwnerChanged,
        _ => Error::Unavailable,
    })?;
    let matches = snapshot["networks"].as_array().is_some_and(|networks| {
        networks.iter().any(|n| {
            n["id"].as_str() == Some(ap)
                && n["device"].as_str() == Some(device)
                && n["inUse"] == true
        })
    });
    if !matches {
        return Err(Error::Stale);
    }
    if client.owner()? != owner {
        return Err(Error::OwnerChanged);
    }
    let reply = client
        .call(owner, device, DEVICE, "Disconnect", ptr::null_mut())
        .map_err(|_| Error::Uncertain)?;
    if reply.kind() != "()" {
        return Err(Error::Uncertain);
    }
    if client.owner().map_err(|_| Error::Uncertain)? != owner {
        return Err(Error::Uncertain);
    }
    Ok(())
}

/// Request one scan per observed Wi-Fi device. Success means NetworkManager
/// accepted each request, not that results are ready; refresh on later signals.
///
/// # Safety
/// Use a dedicated worker and serialize with other Wi-Fi actions. The caller
/// must fence by owner generation, close on `Uncertain`, and never automatically
/// retry a potentially dispatched scan. No hidden-SSID options are sent.
pub unsafe fn scan(bus: Ptr, owner: &str, timeout: Duration) -> Result<usize, Error> {
    if bus.is_null()
        || owner.contains('\0')
        || gio::g_dbus_is_unique_name(c(owner).as_ptr()) == 0
        || timeout.is_zero()
        || timeout > Duration::from_secs(30)
    {
        return Err(Error::Invalid);
    }
    let client = Client {
        bus,
        deadline: Instant::now().checked_add(timeout).ok_or(Error::Invalid)?,
    };
    if client.owner()? != owner {
        return Err(Error::OwnerChanged);
    }
    let root = client
        .call(owner, ROOT, PROPS, "GetAll", gio::tuple(&[gio::string(NM)]))
        .map_err(|_| Error::Unavailable)?;
    if root.kind() != "(a{sv})" {
        return Err(Error::Invalid);
    }
    let objects = root
        .child(0)
        .and_then(|v| v.lookup("Devices"))
        .ok_or(Error::Invalid)?;
    if objects.kind() != "ao" {
        return Err(Error::Invalid);
    }
    if objects.len() > 64 {
        return Err(Error::Limit);
    }
    let mut devices = Vec::new();
    for i in 0..objects.len() {
        let path = objects
            .child(i)
            .and_then(|v| v.object_path())
            .ok_or(Error::Invalid)?;
        if !path.starts_with("/org/freedesktop/NetworkManager/Devices/") || path.len() > 1024 {
            return Err(Error::Invalid);
        }
        if devices.contains(&path) {
            continue;
        }
        let properties = client
            .call(
                owner,
                &path,
                PROPS,
                "GetAll",
                gio::tuple(&[gio::string(DEVICE)]),
            )
            .map_err(|_| Error::Unavailable)?;
        if properties.kind() != "(a{sv})" {
            return Err(Error::Invalid);
        }
        let kind = properties
            .child(0)
            .and_then(|v| v.lookup("DeviceType"))
            .and_then(|v| v.u32())
            .ok_or(Error::Invalid)?;
        if kind == 2 {
            devices.push(path);
        }
    }
    let mut dispatched = 0;
    for path in devices {
        match client.owner() {
            Ok(current) if current == owner => (),
            Ok(_) if dispatched == 0 => return Err(Error::OwnerChanged),
            Err(error) if dispatched == 0 => return Err(error),
            _ => return Err(Error::Uncertain),
        }
        let element = gio::g_variant_type_new(c("{sv}").as_ptr());
        if element.is_null() {
            return Err(if dispatched == 0 {
                Error::Invalid
            } else {
                Error::Uncertain
            });
        }
        let options = gio::g_variant_new_array(element, ptr::null(), 0);
        gio::g_variant_type_free(element);
        dispatched += 1;
        match client.call(owner, &path, WIFI, "RequestScan", gio::tuple(&[options])) {
            Ok(reply) if reply.kind() == "()" => (),
            _ => return Err(Error::Uncertain),
        }
    }
    match client.owner() {
        Ok(current) if current == owner => Ok(dispatched),
        Ok(_) if dispatched == 0 => Err(Error::OwnerChanged),
        Err(error) if dispatched == 0 => Err(error),
        _ => Err(Error::Uncertain),
    }
}

pub(crate) struct CallError;
pub(crate) struct Client {
    pub(crate) bus: Ptr,
    pub(crate) deadline: Instant,
}
impl Client {
    pub(crate) unsafe fn call(
        &self,
        owner: &str,
        path: &str,
        iface: &str,
        method: &str,
        params: Ptr,
    ) -> Result<Variant, CallError> {
        let remaining = self.deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            if !params.is_null() {
                gio::g_variant_unref(params);
            }
            return Err(CallError);
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
            remaining.min(Duration::from_secs(2)).as_millis().max(1) as i32,
            ptr::null_mut(),
            &mut error,
        );
        if !error.is_null() {
            gio::g_error_free(error);
        }
        Variant::from(reply).ok_or(CallError)
    }
    pub(crate) unsafe fn owner(&self) -> Result<String, Error> {
        let result = self
            .call(
                "org.freedesktop.DBus",
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                "GetNameOwner",
                gio::tuple(&[gio::string(NM)]),
            )
            .map_err(|_| Error::Unavailable)?;
        if result.kind() != "(s)" {
            return Err(Error::Invalid);
        }
        result
            .child(0)
            .and_then(|v| v.string())
            .ok_or(Error::Invalid)
    }
    unsafe fn properties(&self, owner: &str) -> Result<(bool, bool), Error> {
        let result = self
            .call(owner, ROOT, PROPS, "GetAll", gio::tuple(&[gio::string(NM)]))
            .map_err(|_| Error::Unavailable)?;
        if result.kind() != "(a{sv})" {
            return Err(Error::Invalid);
        }
        let props = result.child(0).ok_or(Error::Invalid)?;
        let enabled = props
            .lookup("WirelessEnabled")
            .and_then(|v| v.boolean())
            .ok_or(Error::Invalid)?;
        let hardware = props
            .lookup("WirelessHardwareEnabled")
            .and_then(|v| v.boolean())
            .ok_or(Error::Invalid)?;
        Ok((enabled, hardware))
    }
}

/// Change the Wi-Fi radio exactly once and verify the observed state.
///
/// # Safety
/// `bus` must be a live dedicated connection, used from a worker thread. The
/// owning service must serialize radio operations, track owner generations,
/// discard stale results and close the connection after `Uncertain`. Never
/// automatically retry an uncertain `Set`; it may still have taken effect.
pub unsafe fn set_power(
    bus: Ptr,
    owner: &str,
    enabled: bool,
    timeout: Duration,
) -> Result<(), Error> {
    if bus.is_null()
        || owner.contains('\0')
        || gio::g_dbus_is_unique_name(c(owner).as_ptr()) == 0
        || timeout.is_zero()
        || timeout > Duration::from_secs(30)
    {
        return Err(Error::Invalid);
    }
    let client = Client {
        bus,
        deadline: Instant::now().checked_add(timeout).ok_or(Error::Invalid)?,
    };
    if client.owner()? != owner {
        return Err(Error::OwnerChanged);
    }
    let (actual, hardware) = client.properties(owner)?;
    if enabled && !hardware {
        return Err(Error::HardwareBlocked);
    }
    if client.owner()? != owner {
        return Err(Error::OwnerChanged);
    }
    if actual == enabled {
        return Ok(());
    }
    let params = gio::tuple(&[
        gio::string(NM),
        gio::string("WirelessEnabled"),
        gio::g_variant_new_variant(gio::g_variant_new_boolean(i32::from(enabled))),
    ]);
    match client.call(owner, ROOT, PROPS, "Set", params) {
        Ok(reply) if reply.kind() == "()" => (),
        Ok(_) => return Err(Error::Uncertain),
        Err(_) => return Err(Error::Uncertain),
    }
    // The write has been dispatched. Any inability to observe the owner or
    // state now is uncertain and requires the connection to be closed.
    if client.owner().map_err(|_| Error::Uncertain)? != owner {
        return Err(Error::Uncertain);
    }
    let (observed, _) = client.properties(owner).map_err(|_| Error::Uncertain)?;
    if client.owner().map_err(|_| Error::Uncertain)? != owner {
        return Err(Error::Uncertain);
    }
    if observed != enabled {
        // A late state transition is still possible after a successful reply.
        return Err(Error::Uncertain);
    }
    Ok(())
}
