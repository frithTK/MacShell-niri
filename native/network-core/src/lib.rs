//! Pure NetworkManager Wi-Fi decisions; no D-Bus, secrets or system access.

pub mod activation;
pub mod new_profile;
pub mod secret_agent;

/// Preserve NetworkManager's precedence for access points advertising multiple
/// key management modes. Values are the NM 802.11 AP security flag bits.
pub fn security(flags: u32, wpa_flags: u32, rsn_flags: u32) -> &'static str {
    let combined = wpa_flags | rsn_flags;
    if combined & (0x200 | 0x2000) != 0 {
        "enterprise"
    } else if combined & (0x800 | 0x1000) != 0 {
        "owe"
    } else if combined & 0x400 != 0 {
        "sae"
    } else if combined & 0x100 != 0 {
        "wpa-psk"
    } else if flags & 1 != 0 {
        "unsupported"
    } else {
        "open"
    }
}

/// A decoded, non-secret view of a saved NetworkManager connection.
pub struct Profile<'a> {
    pub path: &'a str,
    pub ssid: &'a [u8],
    pub key_management: &'a str,
    /// None means NetworkManager has not restricted the profile to an interface.
    pub interface: Option<&'a str>,
    pub timestamp: u64,
    pub uuid: &'a str,
}

/// Choose the active matching profile, otherwise the most recently used one,
/// with UUID as the existing deterministic tie-breaker. Match SSIDs as bytes.
pub fn choose_profile<'a>(
    profiles: &'a [Profile<'a>],
    ssid: &[u8],
    key_management: &str,
    interface: &str,
    active: &str,
) -> Option<&'a str> {
    profiles
        .iter()
        .filter(|p| {
            p.ssid == ssid
                && p.key_management == key_management
                && p.interface.is_none_or(|name| name == interface)
        })
        .min_by(|a, b| {
            (a.path != active)
                .cmp(&(b.path != active))
                .then_with(|| b.timestamp.cmp(&a.timestamp))
                .then_with(|| a.uuid.cmp(b.uuid))
        })
        .map(|profile| profile.path)
}

/// Validate the password forms accepted by the existing connection flow.
pub fn validate_password(kind: &str, password: &str) -> Result<(), &'static str> {
    let length = password.chars().count();
    match kind {
        "open" => Ok(()),
        "wpa-psk"
            if (8..=63).contains(&length)
                || (length == 64 && password.bytes().all(|c| c.is_ascii_hexdigit())) =>
        {
            Ok(())
        }
        "wpa-psk" => Err("WPA password must contain 8–63 characters (or 64 hexadecimal digits)."),
        "sae" if (1..=63).contains(&length) => Ok(()),
        "sae" => Err("Enter the WPA3 password (1–63 characters)."),
        _ => Err("This security type needs advanced network settings."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn security_precedence_and_legacy_privacy() {
        assert_eq!(security(0, 0, 0), "open");
        assert_eq!(security(1, 0, 0), "unsupported");
        assert_eq!(security(0, 0x100, 0), "wpa-psk");
        assert_eq!(security(0, 0x100, 0x400), "sae");
        assert_eq!(security(0, 0x400, 0x800), "owe");
        assert_eq!(security(0, 0x800, 0x2000), "enterprise");
    }

    #[test]
    fn raw_ssid_active_interface_and_tie_breaker() {
        let profiles = [
            Profile {
                path: "/old",
                ssid: b"net\xff",
                key_management: "wpa-psk",
                interface: None,
                timestamp: 1,
                uuid: "z",
            },
            Profile {
                path: "/new",
                ssid: b"net\xff",
                key_management: "wpa-psk",
                interface: Some("wlan0"),
                timestamp: 20,
                uuid: "b",
            },
            Profile {
                path: "/other",
                ssid: b"net\xff",
                key_management: "wpa-psk",
                interface: Some("wlan1"),
                timestamp: 30,
                uuid: "a",
            },
            Profile {
                path: "/tie",
                ssid: b"net\xff",
                key_management: "wpa-psk",
                interface: None,
                timestamp: 20,
                uuid: "a",
            },
        ];
        assert_eq!(
            choose_profile(&profiles, b"net\xff", "wpa-psk", "wlan0", "/old"),
            Some("/old")
        );
        assert_eq!(
            choose_profile(&profiles, b"net\xff", "wpa-psk", "wlan0", ""),
            Some("/tie")
        );
        assert_eq!(
            choose_profile(&profiles, b"net", "wpa-psk", "wlan0", ""),
            None
        );
        assert_eq!(
            choose_profile(&profiles, b"net\xff", "sae", "wlan0", ""),
            None
        );
    }

    #[test]
    fn password_boundaries_and_unicode() {
        assert!(validate_password("open", "").is_ok());
        assert!(validate_password("wpa-psk", "пароль12").is_ok());
        assert!(validate_password("wpa-psk", "short").is_err());
        assert!(validate_password("wpa-psk", &"f".repeat(64)).is_ok());
        assert!(validate_password("wpa-psk", &"z".repeat(64)).is_err());
        assert!(validate_password("sae", "x").is_ok());
        assert!(validate_password("sae", &"x".repeat(64)).is_err());
        assert!(validate_password("enterprise", "anything").is_err());
    }
}
