//! Synthetic saved-activation runner; requires an explicit private bus.
use macshell_gio_bridge::{self as gio, c, Variant};
use serde_json::json;
use std::ptr;
use std::time::Duration;

fn main() {
    let Some(address) = std::env::var("DBUS_SYSTEM_BUS_ADDRESS")
        .ok()
        .filter(|s| !s.is_empty() && !s.contains('\0'))
    else {
        std::process::exit(2)
    };
    let mode = std::env::args().nth(1).unwrap_or_default();
    unsafe {
        let mut error = ptr::null_mut();
        let bus = gio::g_dbus_connection_new_for_address_sync(
            c(&address).as_ptr(),
            9,
            ptr::null_mut(),
            ptr::null_mut(),
            &mut error,
        );
        if bus.is_null() {
            if !error.is_null() {
                gio::g_error_free(error);
            }
            std::process::exit(2);
        }
        let reply = gio::g_dbus_connection_call_sync(
            bus,
            c("org.freedesktop.DBus").as_ptr(),
            c("/org/freedesktop/DBus").as_ptr(),
            c("org.freedesktop.DBus").as_ptr(),
            c("GetNameOwner").as_ptr(),
            gio::tuple(&[gio::string("org.freedesktop.NetworkManager")]),
            ptr::null_mut(),
            0,
            1000,
            ptr::null_mut(),
            &mut error,
        );
        let owner = Variant::from(reply)
            .and_then(|v| v.child(0))
            .and_then(|v| v.string());
        if !error.is_null() {
            gio::g_error_free(error);
            error = ptr::null_mut();
        }
        let Some(owner) = owner else {
            gio::g_object_unref(bus);
            std::process::exit(2)
        };
        let owner = if mode == "wrong-owner" {
            ":1.999999"
        } else {
            &owner
        };
        let root = "/org/freedesktop/NetworkManager";
        if mode == "create" || mode == "create-stale" || mode == "create-stale-interface" {
            let device = format!("{root}/Devices/1");
            let ap = format!("{root}/AccessPoint/1");
            let input = macshell_network_core::new_profile::Input {
                ssid: if mode == "create-stale" {
                    b"other"
                } else {
                    b"Test WiFi"
                },
                interface: if mode == "create-stale-interface" {
                    "other0"
                } else {
                    "wlan0"
                },
                username: "tester",
                security: "wpa-psk",
                uuid: "d4ac1208-0a7b-4012-8abc-381d6ca41234",
                password: "synthetic-password",
            };
            let selection = macshell_network_snapshot::activate::NewSelection {
                device: &device,
                ap: &ap,
                profile: input,
            };
            match macshell_network_snapshot::activate::create(
                bus,
                owner,
                &selection,
                Duration::from_secs(4),
            ) {
                Ok(created) => println!(
                    "{}",
                    json!({"ok":true,"profile":created.profile_path,"path":created.active_path,"owned":created.exclusively_owned})
                ),
                Err(e) => println!("{}", json!({"ok":false,"error":format!("{e:?}")})),
            }
        } else if mode == "inspect" || mode == "inspect-invalid" {
            let path = if mode == "inspect" {
                format!("{root}/ActiveConnection/1")
            } else {
                "/foreign".into()
            };
            match macshell_network_snapshot::activate::inspect(
                bus,
                owner,
                &path,
                Duration::from_secs(4),
            ) {
                Ok(state) => println!("{}", json!({"ok":true,"state":format!("{state:?}")})),
                Err(e) => println!("{}", json!({"ok":false,"error":format!("{e:?}")})),
            }
        } else {
            let uuid = if mode == "stale-uuid" {
                "other-id"
            } else {
                "test-id"
            };
            let ssid = if mode == "stale-ssid" {
                b"other".as_slice()
            } else {
                b"Test WiFi".as_slice()
            };
            let security = if mode == "stale-security" {
                "sae"
            } else {
                "wpa-psk"
            };
            let profile = if mode == "invalid" {
                "/foreign".into()
            } else {
                format!("{root}/Settings/1")
            };
            let device = format!("{root}/Devices/1");
            let ap = format!("{root}/AccessPoint/1");
            let selection = macshell_network_snapshot::activate::Selection {
                profile: &profile,
                device: &device,
                ap: &ap,
                ssid,
                uuid,
                security,
            };
            match macshell_network_snapshot::activate::saved(
                bus,
                owner,
                &selection,
                Duration::from_secs(4),
            ) {
                Ok(started) => println!(
                    "{}",
                    json!({"ok":true,"path":started.active_path,"owned":started.exclusively_owned})
                ),
                Err(e) => println!("{}", json!({"ok":false,"error":format!("{e:?}")})),
            }
        }
        gio::g_dbus_connection_close_sync(bus, ptr::null_mut(), &mut error);
        if !error.is_null() {
            gio::g_error_free(error);
        }
        gio::g_object_unref(bus);
    }
}
