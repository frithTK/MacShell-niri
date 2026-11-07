//! Test-only ObjectManager reader. The private bus must be supplied explicitly.
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use std::ptr;

unsafe fn call(
    bus: Ptr,
    dest: &str,
    path: &str,
    interface: &str,
    method: &str,
    params: Ptr,
) -> Result<Variant, String> {
    let mut error = ptr::null_mut();
    let result = gio::g_dbus_connection_call_sync(
        bus,
        c(dest).as_ptr(),
        c(path).as_ptr(),
        c(interface).as_ptr(),
        c(method).as_ptr(),
        params,
        ptr::null_mut(),
        0,
        3000,
        ptr::null_mut(),
        &mut error,
    );
    Variant::from(result).ok_or_else(|| gio::error(error))
}
fn main() {
    if std::env::var_os("DBUS_SYSTEM_BUS_ADDRESS").is_none() {
        eprintln!("test bus is required");
        std::process::exit(1);
    }
    let result = unsafe {
        let mut error = ptr::null_mut();
        let bus = gio::g_bus_get_sync(1, ptr::null_mut(), &mut error);
        if bus.is_null() {
            Err(gio::error(error))
        } else {
            let result = (|| {
                let owner = call(
                    bus,
                    "org.freedesktop.DBus",
                    "/org/freedesktop/DBus",
                    "org.freedesktop.DBus",
                    "GetNameOwner",
                    gio::tuple(&[gio::string("org.bluez")]),
                )?
                .child(0)
                .and_then(|v| v.string())
                .ok_or("Invalid owner")?;
                let reply = call(
                    bus,
                    &owner,
                    "/",
                    "org.freedesktop.DBus.ObjectManager",
                    "GetManagedObjects",
                    ptr::null_mut(),
                )?;
                macshell_bluez_snapshot::parse(&reply).map_err(str::to_owned)
            })();
            gio::g_object_unref(bus);
            result
        }
    };
    match result {
        Ok(value) => println!("{value}"),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}
