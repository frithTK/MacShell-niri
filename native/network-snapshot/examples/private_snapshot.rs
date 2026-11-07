//! Test-only runner. An explicitly provided private bus is mandatory.
use macshell_gio_bridge::{self as gio, c, Variant};
use serde_json::json;
use std::ptr;
use std::time::Duration;

fn main() {
    let Some(address) = std::env::var_os("DBUS_SYSTEM_BUS_ADDRESS") else {
        std::process::exit(2)
    };
    let Some(address) = address
        .to_str()
        .filter(|s| !s.is_empty() && !s.contains('\0'))
    else {
        std::process::exit(2)
    };
    unsafe {
        let mut error = ptr::null_mut();
        let bus = gio::g_dbus_connection_new_for_address_sync(
            c(address).as_ptr(),
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
        }
        let Some(owner) = owner else {
            gio::g_object_unref(bus);
            std::process::exit(2)
        };
        let owner = std::env::args().nth(1).unwrap_or(owner);
        let result = macshell_network_snapshot::read(bus, &owner, Duration::from_secs(5));
        match result {
            Ok(state) => println!("{}", json!({"ok":true,"state":state})),
            Err(error) => println!("{}", json!({"ok":false,"error":format!("{error:?}")})),
        }
        gio::g_object_unref(bus);
    }
}
