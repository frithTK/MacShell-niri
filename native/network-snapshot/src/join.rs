//! Operation-scoped join data, built from the last confirmed snapshot.
//! Never print this type or its inputs: its password remains secret.
use crate::activate::{self, Error, Started};
use crate::identity;
use macshell_gio_bridge::Ptr;
use macshell_network_core::new_profile::{self, Input};
use serde_json::Value;
use std::sync::atomic::{compiler_fence, Ordering};
use std::time::Duration;

/// Best-effort erasure of this owned buffer; callers, Gio and the system bus
/// may hold separate copies. Do not derive Debug or Clone.
pub struct Secret(String);
impl Secret {
    pub fn new(value: String) -> Result<Self, &'static str> {
        let secret = Self(value);
        if secret.0.len() > 1024 || secret.0.contains('\0') {
            return Err("Invalid Wi-Fi password.");
        }
        Ok(secret)
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
impl Drop for Secret {
    fn drop(&mut self) {
        unsafe {
            for byte in self.0.as_bytes_mut() {
                std::ptr::write_volatile(byte, 0);
            }
        }
        compiler_fence(Ordering::SeqCst);
    }
}

pub struct Job {
    pub device: String,
    pub ap: String,
    pub uuid: String,
    pub profile: Option<String>,
    pub security: String,
    ssid: Vec<u8>,
    interface: String,
    username: String,
    password: Secret,
}
impl Job {
    pub fn from_snapshot(
        network: &Value,
        username: &str,
        password: Secret,
    ) -> Result<Self, &'static str> {
        let string = |key| {
            network
                .get(key)
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .ok_or("Invalid Wi-Fi network.")
        };
        if network.get("supported") != Some(&Value::Bool(true)) {
            return Err("This network needs advanced network settings.");
        }
        let ap = string("id")?.to_owned();
        let device = string("device")?.to_owned();
        let security = string("security")?.to_owned();
        if !matches!(security.as_str(), "open" | "wpa-psk" | "sae") {
            return Err("This network needs advanced network settings.");
        }
        let interface = string("interface")?.to_owned();
        let ssid = network
            .get("rawSsid")
            .and_then(Value::as_array)
            .ok_or("Invalid Wi-Fi network.")?
            .iter()
            .map(|v| {
                v.as_u64()
                    .and_then(|n| u8::try_from(n).ok())
                    .ok_or("Invalid Wi-Fi network.")
            })
            .collect::<Result<Vec<_>, _>>()?;
        if ssid.is_empty() || ssid.len() > 32 {
            return Err("Invalid Wi-Fi network.");
        }
        let saved = network
            .get("saved")
            .and_then(Value::as_bool)
            .ok_or("Invalid Wi-Fi network.")?;
        let (profile, uuid) = if saved {
            (
                Some(string("profile")?.to_owned()),
                string("uuid")?.to_owned(),
            )
        } else {
            let uuid = identity::new_uuid().map_err(|_| "Cannot create a connection identity.")?;
            new_profile::prepare(Input {
                ssid: &ssid,
                interface: &interface,
                username,
                security: &security,
                uuid: &uuid,
                password: password.as_str(),
            })?;
            (None, uuid)
        };
        Ok(Self {
            device,
            ap,
            uuid,
            profile,
            security,
            ssid,
            interface,
            username: username.to_owned(),
            password,
        })
    }

    /// # Safety
    /// Use a dedicated bounded worker connection and owner-generation fencing.
    /// Close on uncertainty and never retry a potentially dispatched request.
    pub unsafe fn start(self, bus: Ptr, owner: &str, timeout: Duration) -> Result<Started, Error> {
        if let Some(profile) = self.profile.as_deref() {
            activate::saved(
                bus,
                owner,
                &activate::Selection {
                    profile,
                    device: &self.device,
                    ap: &self.ap,
                    ssid: &self.ssid,
                    uuid: &self.uuid,
                    security: &self.security,
                },
                timeout,
            )
        } else {
            let profile = Input {
                ssid: &self.ssid,
                interface: &self.interface,
                username: &self.username,
                security: &self.security,
                uuid: &self.uuid,
                password: self.password.as_str(),
            };
            activate::create(
                bus,
                owner,
                &activate::NewSelection {
                    device: &self.device,
                    ap: &self.ap,
                    profile,
                },
                timeout,
            )
            .map(|created| Started {
                active_path: created.active_path,
                exclusively_owned: created.exclusively_owned,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn network(saved: bool) -> Value {
        json!({"id":"/org/freedesktop/NetworkManager/AccessPoint/1", "device":"/org/freedesktop/NetworkManager/Devices/1", "interface":"wlan0", "rawSsid":[84,101,115,116,255], "security":"wpa-psk", "supported":true, "saved":saved, "profile":"/org/freedesktop/NetworkManager/Settings/1", "uuid":"saved-id"})
    }
    #[test]
    fn uses_raw_snapshot_identity_and_fresh_new_uuid() {
        let job = Job::from_snapshot(
            &network(false),
            "tester",
            Secret::new("synthetic-password".into()).unwrap(),
        )
        .unwrap();
        assert_eq!(job.ssid, b"Test\xff");
        assert!(job.profile.is_none());
        assert_ne!(job.uuid, "saved-id");
        let saved = Job::from_snapshot(
            &network(true),
            "tester",
            Secret::new(String::new()).unwrap(),
        )
        .unwrap();
        assert_eq!(saved.uuid, "saved-id");
        assert!(saved.profile.is_some());
    }
    #[test]
    fn rejects_invalid_snapshot_and_new_password() {
        assert!(Job::from_snapshot(
            &network(false),
            "tester",
            Secret::new("short".into()).unwrap()
        )
        .is_err());
        let mut invalid = network(true);
        invalid["rawSsid"] = json!([256]);
        assert!(
            Job::from_snapshot(&invalid, "tester", Secret::new(String::new()).unwrap()).is_err()
        );
        invalid = network(true);
        invalid["supported"] = json!(false);
        assert!(
            Job::from_snapshot(&invalid, "tester", Secret::new(String::new()).unwrap()).is_err()
        );
        assert!(Secret::new("nul\0secret".into()).is_err());
    }
}
