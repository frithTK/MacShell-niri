//! Validated, non-secret inputs for a new NetworkManager Wi-Fi profile.
//!
//! This module neither generates random values nor creates a D-Bus request.
//! The caller supplies a fresh CSPRNG-generated UUID and keeps the password
//! separately; plans can therefore be compared or debugged without passwords.
use crate::validate_password;

#[derive(Clone, Copy)]
pub struct Input<'a> {
    pub ssid: &'a [u8],
    pub interface: &'a str,
    pub username: &'a str,
    pub security: &'a str,
    pub uuid: &'a str,
    pub password: &'a str,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    pub ssid: Vec<u8>,
    pub display_name: String,
    pub interface: String,
    pub permission: String,
    pub security: Security,
    pub uuid: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Security {
    Open,
    WpaPsk,
    Sae,
}

/// Validate an explicitly selected access point and password. Error messages
/// are fixed strings and never contain user-supplied values.
pub fn prepare(input: Input<'_>) -> Result<Plan, &'static str> {
    if input.ssid.is_empty() || input.ssid.len() > 32 || input.ssid.contains(&0) {
        return Err("Invalid Wi-Fi network identity.");
    }
    if input.interface.is_empty()
        || input.interface.len() > 15
        || input.interface == "."
        || input.interface == ".."
        || input
            .interface
            .bytes()
            .any(|c| c == b'/' || c == b':' || c.is_ascii_control() || c.is_ascii_whitespace())
    {
        return Err("Invalid network interface.");
    }
    if input.username.is_empty()
        || input.username.len() > 255
        || input.username.chars().any(|c| c == ':' || c.is_control())
    {
        return Err("Invalid user identity.");
    }
    if !valid_v4_uuid(input.uuid) {
        return Err("Invalid new connection identity.");
    }
    if input.password.contains('\0') {
        return Err("Invalid Wi-Fi password.");
    }
    validate_password(input.security, input.password)?;
    let security = match input.security {
        "open" => Security::Open,
        "wpa-psk" => Security::WpaPsk,
        "sae" => Security::Sae,
        _ => return Err("This security type needs advanced network settings."),
    };
    Ok(Plan {
        ssid: input.ssid.to_vec(),
        display_name: String::from_utf8_lossy(input.ssid).into_owned(),
        interface: input.interface.into(),
        permission: format!("user:{}:", input.username),
        security,
        uuid: input.uuid.into(),
    })
}

fn valid_v4_uuid(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => *c == b'-',
            14 => *c == b'4',
            19 => matches!(*c, b'8' | b'9' | b'a' | b'b'),
            _ => c.is_ascii_digit() || (b'a'..=b'f').contains(c),
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    const UUID: &str = "d4ac1208-0a7b-4012-8abc-381d6ca41234";
    fn input<'a>() -> Input<'a> {
        Input {
            ssid: b"net\xff",
            interface: "wlan0",
            username: "tester",
            security: "wpa-psk",
            uuid: UUID,
            password: "test-password",
        }
    }
    #[test]
    fn plan_keeps_raw_ssid_but_never_stores_password() {
        let plan = prepare(input()).unwrap();
        assert_eq!(plan.ssid, b"net\xff");
        assert_eq!(plan.display_name, "net\u{fffd}");
        assert_eq!(plan.permission, "user:tester:");
        assert_eq!(plan.security, Security::WpaPsk);
        assert!(!format!("{plan:?}").contains("test-password"));
    }
    #[test]
    fn accepts_supported_modes_and_rejects_invalid_passwords() {
        let mut v = input();
        v.security = "open";
        v.password = "";
        assert_eq!(prepare(v).unwrap().security, Security::Open);
        let mut v = input();
        v.security = "sae";
        v.password = "x";
        assert_eq!(prepare(v).unwrap().security, Security::Sae);
        let mut v = input();
        v.password = "short";
        assert!(prepare(v).is_err());
        let mut v = input();
        v.security = "enterprise";
        assert!(prepare(v).is_err());
        let mut v = input();
        v.password = "bad\0password";
        assert!(prepare(v).is_err());
    }
    #[test]
    fn rejects_empty_and_oversized_ssids_without_changing_identity() {
        let mut v = input();
        v.ssid = b"";
        assert!(prepare(v).is_err());
        let mut v = input();
        v.ssid = b"net\0name";
        assert!(prepare(v).is_err());
        let oversized = [65; 33];
        let mut v = input();
        v.ssid = &oversized;
        assert!(prepare(v).is_err());
        let boundary = [255; 32];
        let mut v = input();
        v.ssid = &boundary;
        assert_eq!(prepare(v).unwrap().ssid, boundary);
    }
    #[test]
    fn rejects_bad_user_and_interface_without_exposing_them() {
        for username in ["", "other:user", "test\nuser", "test\0user"] {
            let mut v = input();
            v.username = username;
            assert_eq!(prepare(v), Err("Invalid user identity."));
        }
        for interface in [
            "",
            ".",
            "..",
            "bad/name",
            "bad:name",
            "bad name",
            "0123456789012345",
            "bad\0name",
        ] {
            let mut v = input();
            v.interface = interface;
            assert_eq!(prepare(v), Err("Invalid network interface."));
        }
    }
    #[test]
    fn requires_canonical_v4_uuid_and_valid_variant() {
        for uuid in [
            "",
            "d4ac1208-0a7b-1012-8abc-381d6ca41234",
            "d4ac1208-0a7b-4012-0abc-381d6ca41234",
            "D4AC1208-0a7b-4012-8abc-381d6ca41234",
            "d4ac1208-0a7b-4012-8abc-381d6ca4123x",
        ] {
            let mut v = input();
            v.uuid = uuid;
            assert_eq!(prepare(v), Err("Invalid new connection identity."));
        }
        assert_eq!(prepare(input()).unwrap().uuid, UUID);
    }
}
