//! Construct a NetworkManager settings GVariant without sending it.
use macshell_gio_bridge::{self as gio, Ptr, Variant};
use macshell_network_core::new_profile::{prepare, Input, Security};
use std::ffi::CString;
use std::ptr;
use std::sync::atomic::{compiler_fence, Ordering};

unsafe fn array(entries: &[Ptr]) -> Ptr {
    gio::g_variant_new_array(ptr::null_mut(), entries.as_ptr(), entries.len())
}
unsafe fn field(key: &str, value: Ptr) -> Ptr {
    gio::g_variant_new_dict_entry(gio::string(key), gio::g_variant_new_variant(value))
}
unsafe fn section(name: &str, fields: &[Ptr]) -> Ptr {
    gio::g_variant_new_dict_entry(gio::string(name), array(fields))
}

/// Build `a{sa{sv}}` settings data, without making a D-Bus call.
///
/// # Safety
/// The returned owned GVariant contains the password for secured networks.
/// The caller must never log it and must drop it promptly. Gio/D-Bus may retain
/// additional secret copies; wiping all copies cannot be guaranteed. The caller
/// also owns and must erase its original password. Input UUID must come from a
/// CSPRNG, e.g. `identity::new_uuid`, not merely have a valid format.
pub unsafe fn build(input: Input<'_>) -> Result<Variant, &'static str> {
    let plan = prepare(input)?;
    let ssid: Vec<Ptr> = plan
        .ssid
        .iter()
        .map(|byte| gio::g_variant_new_byte(*byte))
        .collect();
    let permissions = array(&[gio::string(&plan.permission)]);
    let connection = section(
        "connection",
        &[
            field("id", gio::string(&plan.display_name)),
            field("uuid", gio::string(&plan.uuid)),
            field("type", gio::string("802-11-wireless")),
            field("interface-name", gio::string(&plan.interface)),
            field("permissions", permissions),
        ],
    );
    let wifi = section(
        "802-11-wireless",
        &[
            field("ssid", array(&ssid)),
            field("mode", gio::string("infrastructure")),
        ],
    );
    let ipv4 = section("ipv4", &[field("method", gio::string("auto"))]);
    let ipv6 = section("ipv6", &[field("method", gio::string("auto"))]);
    let mut sections = vec![connection, wifi, ipv4, ipv6];
    if plan.security != Security::Open {
        let secret =
            CString::new(input.password.as_bytes()).map_err(|_| "Invalid Wi-Fi password.")?;
        let value = gio::g_variant_new_string(secret.as_ptr());
        let mut bytes = secret.into_bytes_with_nul();
        for byte in &mut bytes {
            ptr::write_volatile(byte, 0);
        }
        compiler_fence(Ordering::SeqCst);
        let key = match plan.security {
            Security::WpaPsk => "wpa-psk",
            Security::Sae => "sae",
            Security::Open => unreachable!(),
        };
        sections.push(section(
            "802-11-wireless-security",
            &[
                field("key-mgmt", gio::string(key)),
                field("psk", value),
                field("psk-flags", gio::g_variant_new_uint32(0)),
            ],
        ));
    }
    Variant::from(gio::g_variant_ref_sink(array(&sections))).ok_or("Cannot build Wi-Fi profile.")
}

#[cfg(test)]
mod tests {
    use super::*;
    const UUID: &str = "d4ac1208-0a7b-4012-8abc-381d6ca41234";
    #[test]
    fn settings_keep_raw_ssid_and_expected_types() {
        unsafe {
            let value = build(Input {
                ssid: b"net\xff",
                interface: "fake0",
                username: "tester",
                security: "wpa-psk",
                uuid: UUID,
                password: "synthetic-password",
            })
            .unwrap();
            assert_eq!(value.kind(), "a{sa{sv}}");
            let connection = value.lookup("connection").unwrap();
            assert_eq!(
                connection.lookup("id").unwrap().string().as_deref(),
                Some("net\u{fffd}")
            );
            assert_eq!(
                connection.lookup("uuid").unwrap().string().as_deref(),
                Some(UUID)
            );
            assert_eq!(
                connection
                    .lookup("permissions")
                    .unwrap()
                    .child(0)
                    .unwrap()
                    .string()
                    .as_deref(),
                Some("user:tester:")
            );
            let wireless = value.lookup("802-11-wireless").unwrap();
            let ssid = wireless.lookup("ssid").unwrap();
            assert_eq!(ssid.kind(), "ay");
            assert_eq!(
                (0..ssid.len())
                    .map(|i| ssid.child(i).unwrap().byte().unwrap())
                    .collect::<Vec<_>>(),
                b"net\xff"
            );
            let security = value.lookup("802-11-wireless-security").unwrap();
            assert_eq!(
                security.lookup("key-mgmt").unwrap().string().as_deref(),
                Some("wpa-psk")
            );
            assert_eq!(
                security.lookup("psk").unwrap().string().as_deref(),
                Some("synthetic-password")
            );
            assert_eq!(security.lookup("psk-flags").unwrap().u32(), Some(0));
        }
    }
    #[test]
    fn open_network_has_no_secret_section_and_invalid_inputs_fail() {
        unsafe {
            let value = build(Input {
                ssid: b"network",
                interface: "fake0",
                username: "tester",
                security: "open",
                uuid: UUID,
                password: "",
            })
            .unwrap();
            assert!(value.lookup("802-11-wireless-security").is_none());
            assert_eq!(
                value
                    .lookup("ipv4")
                    .unwrap()
                    .lookup("method")
                    .unwrap()
                    .string()
                    .as_deref(),
                Some("auto")
            );
            assert!(build(Input {
                ssid: b"network",
                interface: "fake0",
                username: "tester",
                security: "wpa-psk",
                uuid: UUID,
                password: "bad\0secret"
            })
            .is_err());
        }
    }

    #[test]
    fn sae_profile_retains_expected_security_and_ip_configuration() {
        unsafe {
            let value = build(Input {
                ssid: b"wifi",
                interface: "fake0",
                username: "tester",
                security: "sae",
                uuid: UUID,
                password: "synthetic",
            })
            .unwrap();
            let sec = value.lookup("802-11-wireless-security").unwrap();
            assert_eq!(
                sec.lookup("key-mgmt").unwrap().string().as_deref(),
                Some("sae")
            );
            assert_eq!(
                sec.lookup("psk").unwrap().string().as_deref(),
                Some("synthetic")
            );
            assert_eq!(sec.lookup("psk-flags").unwrap().u32(), Some(0));
            assert_eq!(
                value
                    .lookup("ipv6")
                    .unwrap()
                    .lookup("method")
                    .unwrap()
                    .string()
                    .as_deref(),
                Some("auto")
            );
        }
    }
}
