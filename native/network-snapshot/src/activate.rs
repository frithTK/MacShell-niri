//! Saved-profile activation and read-only status on a dedicated worker.
use crate::radio::Client;
use macshell_gio_bridge::{self as gio, c, Ptr};
use macshell_network_core::activation::ActiveState;
use macshell_network_core::new_profile::Input;
use std::time::{Duration, Instant};

const ROOT: &str = "/org/freedesktop/NetworkManager";
const NM: &str = "org.freedesktop.NetworkManager";
const ACTIVE: &str = "org.freedesktop.NetworkManager.Connection.Active";
const PROPS: &str = "org.freedesktop.DBus.Properties";

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    Invalid,
    Unavailable,
    OwnerChanged,
    Stale,
    Uncertain,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Started {
    pub active_path: String,
    /// A returned path does not prove exclusive ownership under concurrent use.
    pub exclusively_owned: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Created {
    pub profile_path: String,
    pub active_path: String,
    pub exclusively_owned: bool,
}

pub struct NewSelection<'a> {
    pub device: &'a str,
    pub ap: &'a str,
    pub profile: Input<'a>,
}

pub struct Selection<'a> {
    pub profile: &'a str,
    pub device: &'a str,
    pub ap: &'a str,
    pub ssid: &'a [u8],
    pub uuid: &'a str,
    pub security: &'a str,
}

fn valid_path(path: &str, suffix: &str) -> bool {
    let prefix = format!("{ROOT}/{suffix}/");
    path.len() <= 1024
        && path.strip_prefix(&prefix).is_some_and(|tail| {
            !tail.is_empty()
                && tail.split('/').all(|part| {
                    !part.is_empty() && part.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
                })
        })
}
unsafe fn client(bus: Ptr, owner: &str, timeout: Duration) -> Result<Client, Error> {
    if bus.is_null()
        || owner.contains('\0')
        || gio::g_dbus_is_unique_name(c(owner).as_ptr()) == 0
        || timeout.is_zero()
        || timeout > Duration::from_secs(30)
    {
        return Err(Error::Invalid);
    }
    Ok(Client {
        bus,
        deadline: Instant::now().checked_add(timeout).ok_or(Error::Invalid)?,
    })
}
unsafe fn check_owner(client: &Client, owner: &str) -> Result<(), Error> {
    let current = client.owner().map_err(|_| Error::Unavailable)?;
    if current != owner {
        return Err(Error::OwnerChanged);
    }
    Ok(())
}

/// Dispatch a single saved-profile activation. The caller must not infer
/// ownership of the returned ActiveConnection from the returned path.
///
/// # Safety
/// Use a dedicated connection on a worker, serialize mutations and track owner
/// generations independently. On `Uncertain`, close the connection and do not
/// retry: the activation may already exist. User intent is required to call it.
pub unsafe fn saved(
    bus: Ptr,
    owner: &str,
    selected: &Selection<'_>,
    timeout: Duration,
) -> Result<Started, Error> {
    let Selection {
        profile,
        device,
        ap,
        ssid,
        uuid,
        security,
    } = *selected;
    if !valid_path(profile, "Settings")
        || !valid_path(device, "Devices")
        || !valid_path(ap, "AccessPoint")
        || ssid.is_empty()
        || ssid.len() > 32
        || uuid.is_empty()
        || uuid.len() > 128
        || uuid.contains('\0')
        || !matches!(security, "open" | "wpa-psk" | "sae")
    {
        return Err(Error::Invalid);
    }
    let client = client(bus, owner, timeout)?;
    check_owner(&client, owner)?;
    // Re-read identity and profile immediately before mutation; this detects
    // stale UI selections but is not an atomic CAS against other clients.
    let remaining = client.deadline.saturating_duration_since(Instant::now());
    let snapshot = crate::read(bus, owner, remaining).map_err(|error| match error {
        crate::Error::OwnerChanged => Error::OwnerChanged,
        _ => Error::Unavailable,
    })?;
    let matches = snapshot["networks"].as_array().is_some_and(|networks| {
        networks.iter().any(|network| {
            network["id"].as_str() == Some(ap)
                && network["device"].as_str() == Some(device)
                && network["profile"].as_str() == Some(profile)
                && network["uuid"].as_str() == Some(uuid)
                && network["security"].as_str() == Some(security)
                && network["supported"] == true
                && network["saved"] == true
                && network["rawSsid"].as_array().is_some_and(|bytes| {
                    bytes.len() == ssid.len()
                        && bytes
                            .iter()
                            .zip(ssid)
                            .all(|(value, byte)| value.as_u64() == Some(u64::from(*byte)))
                })
        })
    });
    if !matches {
        return Err(Error::Stale);
    }
    check_owner(&client, owner)?;
    let params = gio::tuple(&[
        gio::g_variant_new_object_path(c(profile).as_ptr()),
        gio::g_variant_new_object_path(c(device).as_ptr()),
        gio::g_variant_new_object_path(c(ap).as_ptr()),
    ]);
    let reply = client
        .call(owner, ROOT, NM, "ActivateConnection", params)
        .map_err(|_| Error::Uncertain)?;
    if reply.kind() != "(o)" {
        return Err(Error::Uncertain);
    }
    let active = reply
        .child(0)
        .and_then(|v| v.object_path())
        .ok_or(Error::Uncertain)?;
    if !valid_path(&active, "ActiveConnection") {
        return Err(Error::Uncertain);
    }
    check_owner(&client, owner).map_err(|_| Error::Uncertain)?;
    Ok(Started {
        active_path: active,
        exclusively_owned: false,
    })
}

/// Create and activate a new profile once, after validating the selected AP.
///
/// # Safety
/// Use a dedicated worker and user-initiated request. The caller must supply
/// the actual desktop user's name, a CSPRNG-generated UUID and an operation-
/// scoped password agent before dispatch. A returned path is not proof of
/// exclusive ownership. Close the connection and never automatically retry
/// after `Uncertain`. Erase caller-owned secrets promptly; Gio may retain copies.
pub unsafe fn create(
    bus: Ptr,
    owner: &str,
    selected: &NewSelection<'_>,
    timeout: Duration,
) -> Result<Created, Error> {
    if !valid_path(selected.device, "Devices") || !valid_path(selected.ap, "AccessPoint") {
        return Err(Error::Invalid);
    }
    let plan = macshell_network_core::new_profile::prepare(selected.profile)
        .map_err(|_| Error::Invalid)?;
    let client = client(bus, owner, timeout)?;
    check_owner(&client, owner)?;
    let remaining = client.deadline.saturating_duration_since(Instant::now());
    let snapshot = crate::read(bus, owner, remaining).map_err(|error| match error {
        crate::Error::OwnerChanged => Error::OwnerChanged,
        _ => Error::Unavailable,
    })?;
    let matches = snapshot["networks"].as_array().is_some_and(|networks| {
        networks.iter().any(|network| {
            network["id"].as_str() == Some(selected.ap)
                && network["device"].as_str() == Some(selected.device)
                && network["interface"].as_str() == Some(selected.profile.interface)
                && network["security"].as_str() == Some(selected.profile.security)
                && network["supported"] == true
                && network["saved"] == false
                && network["rawSsid"].as_array().is_some_and(|bytes| {
                    bytes.len() == plan.ssid.len()
                        && bytes
                            .iter()
                            .zip(&plan.ssid)
                            .all(|(value, byte)| value.as_u64() == Some(u64::from(*byte)))
                })
        })
    });
    if !matches {
        return Err(Error::Stale);
    }
    check_owner(&client, owner)?;
    let settings = crate::profile::build(selected.profile).map_err(|_| Error::Invalid)?;
    let option = gio::g_variant_new_dict_entry(
        gio::string("persist"),
        gio::g_variant_new_variant(gio::string("disk")),
    );
    let options = gio::g_variant_new_array(std::ptr::null_mut(), [option].as_ptr(), 1);
    let params = gio::tuple(&[
        settings.0,
        gio::g_variant_new_object_path(c(selected.device).as_ptr()),
        gio::g_variant_new_object_path(c(selected.ap).as_ptr()),
        options,
    ]);
    let reply = client
        .call(owner, ROOT, NM, "AddAndActivateConnection2", params)
        .map_err(|_| Error::Uncertain)?;
    if reply.kind() != "(ooa{sv})" {
        return Err(Error::Uncertain);
    }
    let profile = reply
        .child(0)
        .and_then(|v| v.object_path())
        .ok_or(Error::Uncertain)?;
    let active = reply
        .child(1)
        .and_then(|v| v.object_path())
        .ok_or(Error::Uncertain)?;
    if !valid_path(&profile, "Settings") || !valid_path(&active, "ActiveConnection") {
        return Err(Error::Uncertain);
    }
    check_owner(&client, owner).map_err(|_| Error::Uncertain)?;
    Ok(Created {
        profile_path: profile,
        active_path: active,
        exclusively_owned: false,
    })
}

/// Read one active connection's state. This never modifies the connection.
///
/// # Safety
/// Use a dedicated worker connection and discard results after any owner
/// generation change, even if the same unique owner reacquires the name.
pub unsafe fn inspect(
    bus: Ptr,
    owner: &str,
    active: &str,
    timeout: Duration,
) -> Result<ActiveState, Error> {
    if !valid_path(active, "ActiveConnection") {
        return Err(Error::Invalid);
    }
    let client = client(bus, owner, timeout)?;
    check_owner(&client, owner)?;
    let reply = match client.call(
        owner,
        active,
        PROPS,
        "GetAll",
        gio::tuple(&[gio::string(ACTIVE)]),
    ) {
        Ok(reply) => reply,
        Err(_) => {
            // NetworkManager removes an ActiveConnection object once it is
            // gone. Confirm absence against its authoritative list rather
            // than turning an arbitrary D-Bus error into a cancellation.
            let root = client
                .call(owner, ROOT, PROPS, "GetAll", gio::tuple(&[gio::string(NM)]))
                .map_err(|_| Error::Unavailable)?;
            if root.kind() != "(a{sv})" {
                return Err(Error::Invalid);
            }
            let paths = root
                .child(0)
                .and_then(|v| v.lookup("ActiveConnections"))
                .ok_or(Error::Unavailable)?;
            if paths.kind() != "ao" || paths.len() > 4096 {
                return Err(Error::Invalid);
            }
            let mut found = false;
            for index in 0..paths.len() {
                let path = paths
                    .child(index)
                    .and_then(|v| v.object_path())
                    .ok_or(Error::Invalid)?;
                found |= path == active;
            }
            check_owner(&client, owner)?;
            return if found {
                Err(Error::Unavailable)
            } else {
                Ok(ActiveState::Deactivated)
            };
        }
    };
    if reply.kind() != "(a{sv})" {
        return Err(Error::Invalid);
    }
    let state = reply
        .child(0)
        .and_then(|v| v.lookup("State"))
        .and_then(|v| v.u32())
        .ok_or(Error::Invalid)?;
    check_owner(&client, owner)?;
    Ok(match state {
        1 => ActiveState::Activating,
        2 => ActiveState::Activated,
        3 => ActiveState::Deactivating,
        4 => ActiveState::Deactivated,
        _ => ActiveState::Unknown,
    })
}

/// Cancel the exact activation returned by NetworkManager for the user's join.
/// A second state check narrows, but cannot eliminate, the race with activation.
/// Never retry this mutating call after an ambiguous result.
///
/// # Safety
/// Use a dedicated bounded worker connection, pin the owner and fence the job.
pub unsafe fn cancel(
    bus: Ptr,
    owner: &str,
    active: &str,
    timeout: Duration,
) -> Result<usize, crate::radio::Error> {
    use crate::radio::Error as RadioError;
    let deadline = Instant::now()
        .checked_add(timeout)
        .ok_or(RadioError::Invalid)?;
    match inspect(bus, owner, active, timeout).map_err(|_| RadioError::Uncertain)? {
        ActiveState::Deactivating | ActiveState::Deactivated => return Ok(0),
        ActiveState::Activated => return Ok(1),
        ActiveState::Activating => (),
        _ => return Err(RadioError::Uncertain),
    }
    let remaining = deadline.saturating_duration_since(Instant::now());
    let client = client(bus, owner, remaining).map_err(|_| RadioError::Uncertain)?;
    check_owner(&client, owner).map_err(|_| RadioError::Uncertain)?;
    let reply = client
        .call(
            owner,
            ROOT,
            NM,
            "DeactivateConnection",
            gio::tuple(&[gio::g_variant_new_object_path(c(active).as_ptr())]),
        )
        .map_err(|_| RadioError::Uncertain)?;
    if reply.kind() != "()" {
        return Err(RadioError::Uncertain);
    }
    check_owner(&client, owner).map_err(|_| RadioError::Uncertain)?;
    Ok(0)
}
