//! Test-only worker wired to a dedicated connection on an explicit test bus.
use macshell_gio_bridge::{self as gio, c, Variant};
use macshell_network_snapshot::{worker::Worker, Error};
use serde_json::json;
use std::ptr;
use std::time::{Duration, Instant};

fn main() {
    let Some(address) = std::env::var("DBUS_SYSTEM_BUS_ADDRESS")
        .ok()
        .filter(|s| !s.is_empty() && !s.contains('\0'))
    else {
        std::process::exit(2)
    };
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
        }
        gio::g_object_unref(bus);
        let Some(owner) = owner else {
            std::process::exit(2)
        };
        let mut worker = Worker::new(move |owner| {
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
                return Err(Error::Unavailable);
            }
            let state = macshell_network_snapshot::read(bus, owner, Duration::from_secs(5));
            gio::g_dbus_connection_close_sync(bus, ptr::null_mut(), &mut error);
            if !error.is_null() {
                gio::g_error_free(error);
            }
            gio::g_object_unref(bus);
            state
        });
        worker.owner_changed(Some(&owner)).unwrap();
        assert!(worker.request().unwrap());
        let deadline = Instant::now() + Duration::from_secs(7);
        loop {
            if let Some(value) = worker.poll() {
                match value {
                    Ok(state) => println!("{}", json!({"ok":true,"state":state})),
                    Err(error) => println!("{}", json!({"ok":false,"error":format!("{error:?}")})),
                }
                break;
            }
            if Instant::now() >= deadline {
                std::process::exit(3);
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}
