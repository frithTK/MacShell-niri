//! One operation-owned Mutter ScreenCast session on a dedicated D-Bus connection.
//! Construct and drop on the owning GLib context. Does not read PipeWire frames.
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use std::ffi::c_char;
use std::marker::PhantomData;
use std::ptr;
use std::rc::Rc;
use std::sync::mpsc::Sender;

const BUS: &str = "org.gnome.Mutter.ScreenCast";
const ROOT: &str = "/org/gnome/Mutter/ScreenCast";
const SESSION: &str = "org.gnome.Mutter.ScreenCast.Session";
const STREAM: &str = "org.gnome.Mutter.ScreenCast.Stream";
const DBUS: &str = "org.freedesktop.DBus";
const DBUS_PATH: &str = "/org/freedesktop/DBus";

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    Node { token: u64, node: u32 },
    Changed { token: u64 },
    OwnerLost { token: u64 },
}
struct SignalData {
    owner: String,
    stream: String,
    token: u64,
    first: Option<u32>,
    events: Sender<Event>,
}
struct OwnerData {
    owner: String,
    token: u64,
    events: Sender<Event>,
}
struct Bus(Ptr);
impl Drop for Bus {
    fn drop(&mut self) {
        unsafe {
            let mut error = ptr::null_mut();
            gio::g_dbus_connection_close_sync(self.0, ptr::null_mut(), &mut error);
            if !error.is_null() {
                gio::g_error_free(error);
            }
            gio::g_object_unref(self.0);
        }
    }
}

pub struct Session {
    bus: Bus,
    owner: String,
    path: String,
    node_subscription: u32,
    owner_subscription: u32,
    node_data: Option<Box<SignalData>>,
    owner_data: Option<Box<OwnerData>>,
    stopped: bool,
    _single_thread: PhantomData<Rc<()>>,
}

unsafe fn call(
    bus: Ptr,
    owner: &str,
    path: &str,
    iface: &str,
    method: &str,
    params: Ptr,
) -> Result<Variant, &'static str> {
    let mut error = ptr::null_mut();
    let result = gio::g_dbus_connection_call_sync(
        bus,
        c(owner).as_ptr(),
        c(path).as_ptr(),
        c(iface).as_ptr(),
        c(method).as_ptr(),
        params,
        ptr::null_mut(),
        0,
        2000,
        ptr::null_mut(),
        &mut error,
    );
    if !error.is_null() {
        gio::g_error_free(error);
    }
    Variant::from(result).ok_or("ScreenCast request failed.")
}
unsafe fn owner(bus: Ptr) -> Result<String, &'static str> {
    let result = call(
        bus,
        DBUS,
        DBUS_PATH,
        DBUS,
        "GetNameOwner",
        gio::tuple(&[gio::string(BUS)]),
    )?;
    if result.kind() != "(s)" {
        return Err("Invalid ScreenCast owner.");
    }
    let value = result
        .child(0)
        .and_then(|v| v.string())
        .ok_or("Invalid ScreenCast owner.")?;
    if gio::g_dbus_is_unique_name(c(&value).as_ptr()) == 0 {
        return Err("Invalid ScreenCast owner.");
    }
    Ok(value)
}
unsafe fn dict(entries: &[Ptr]) -> Result<Ptr, &'static str> {
    let ty = gio::g_variant_type_new(c("{sv}").as_ptr());
    if ty.is_null() {
        return Err("Cannot construct ScreenCast request.");
    }
    let value = gio::g_variant_new_array(ty, entries.as_ptr(), entries.len());
    gio::g_variant_type_free(ty);
    Ok(value)
}
fn valid_path(path: &str, prefix: &str) -> bool {
    path.len() <= 1024
        && path.strip_prefix(prefix).is_some_and(|tail| {
            !tail.is_empty()
                && tail.split('/').all(|v| {
                    !v.is_empty() && v.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
                })
        })
}
unsafe fn result_path(value: Variant, prefix: &str) -> Result<String, &'static str> {
    if value.kind() != "(o)" {
        return Err("Invalid ScreenCast response.");
    }
    let path = value
        .child(0)
        .and_then(|v| v.object_path())
        .ok_or("Invalid ScreenCast response.")?;
    if !valid_path(&path, prefix) {
        return Err("Invalid ScreenCast path.");
    }
    Ok(path)
}
extern "C" fn node_signal(
    _: Ptr,
    sender: *const c_char,
    path: *const c_char,
    _: *const c_char,
    _: *const c_char,
    params: Ptr,
    data: Ptr,
) {
    unsafe {
        let context = &mut *data.cast::<SignalData>();
        if gio::text(sender) != context.owner
            || gio::text(path) != context.stream
            || gio::text(gio::g_variant_get_type_string(params)) != "(u)"
        {
            return;
        }
        let Some(node) = Variant::from(gio::g_variant_get_child_value(params, 0))
            .and_then(|v| v.u32())
            .filter(|n| *n != 0)
        else {
            return;
        };
        match context.first {
            None => {
                context.first = Some(node);
                let _ = context.events.send(Event::Node {
                    token: context.token,
                    node,
                });
            }
            Some(first) if first != node => {
                let _ = context.events.send(Event::Changed {
                    token: context.token,
                });
            }
            _ => (),
        }
    }
}
extern "C" fn owner_signal(
    _: Ptr,
    _: *const c_char,
    _: *const c_char,
    _: *const c_char,
    _: *const c_char,
    params: Ptr,
    data: Ptr,
) {
    unsafe {
        let context = &*data.cast::<OwnerData>();
        if gio::text(gio::g_variant_get_type_string(params)) != "(sss)" {
            return;
        }
        let old = Variant::from(gio::g_variant_get_child_value(params, 1)).and_then(|v| v.string());
        let new = Variant::from(gio::g_variant_get_child_value(params, 2)).and_then(|v| v.string());
        if old.as_deref() == Some(&context.owner) && new.as_deref() != Some(&context.owner) {
            let _ = context.events.send(Event::OwnerLost {
                token: context.token,
            });
        }
    }
}
impl Session {
    /// Create a stream for a single explicit window on an explicit session-bus
    /// address. Each session has its own connection: on any uncertain failure,
    /// dropping it closes that connection and attempts to stop its session.
    ///
    /// # Safety
    /// Call on a live GLib context, keep polling that context while active,
    /// and drop on the same thread outside a Gio callback.
    pub unsafe fn start(
        address: &str,
        window: u64,
        token: u64,
        events: Sender<Event>,
    ) -> Result<Self, &'static str> {
        if address.is_empty() || address.contains('\0') || window == 0 {
            return Err("Invalid ScreenCast request.");
        }
        let mut error = ptr::null_mut();
        let connection = gio::g_dbus_connection_new_for_address_sync(
            c(address).as_ptr(),
            9,
            ptr::null_mut(),
            ptr::null_mut(),
            &mut error,
        );
        if !error.is_null() {
            gio::g_error_free(error);
        }
        if connection.is_null() {
            return Err("Cannot connect to the session bus.");
        }
        gio::g_dbus_connection_set_exit_on_close(connection, 0);
        let bus = Bus(connection);
        let pinned = owner(bus.0).map_err(|_| "ScreenCast service is unavailable.")?;
        let mut session = Self {
            bus,
            owner: pinned,
            path: String::new(),
            node_subscription: 0,
            owner_subscription: 0,
            node_data: None,
            owner_data: None,
            stopped: false,
            _single_thread: PhantomData,
        };
        let mut owner_data = Box::new(OwnerData {
            owner: session.owner.clone(),
            token,
            events: events.clone(),
        });
        session.owner_subscription = gio::g_dbus_connection_signal_subscribe(
            session.bus.0,
            c(DBUS).as_ptr(),
            c(DBUS).as_ptr(),
            c("NameOwnerChanged").as_ptr(),
            c(DBUS_PATH).as_ptr(),
            c(BUS).as_ptr(),
            0,
            Some(owner_signal),
            (&mut *owner_data as *mut OwnerData).cast(),
            ptr::null_mut(),
        );
        if session.owner_subscription == 0 {
            return Err("Cannot watch ScreenCast owner.");
        }
        session.owner_data = Some(owner_data);
        if owner(session.bus.0)? != session.owner {
            return Err("ScreenCast owner changed.");
        }
        let value = call(
            session.bus.0,
            &session.owner,
            ROOT,
            BUS,
            "CreateSession",
            gio::tuple(&[dict(&[])?]),
        )
        .map_err(|_| "Cannot create ScreenCast session.")?;
        session.path = result_path(value, "/org/gnome/Mutter/ScreenCast/Session/")?;
        if owner(session.bus.0)? != session.owner {
            return Err("ScreenCast owner changed.");
        }
        let entries = [
            gio::g_variant_new_dict_entry(
                gio::string("window-id"),
                gio::g_variant_new_variant(gio::g_variant_new_uint64(window)),
            ),
            gio::g_variant_new_dict_entry(
                gio::string("cursor-mode"),
                gio::g_variant_new_variant(gio::g_variant_new_uint32(0)),
            ),
        ];
        let value = call(
            session.bus.0,
            &session.owner,
            &session.path,
            SESSION,
            "RecordWindow",
            gio::tuple(&[dict(&entries)?]),
        )
        .map_err(|_| "Cannot select the ScreenCast window.")?;
        let stream = result_path(value, "/org/gnome/Mutter/ScreenCast/Stream/")?;
        if owner(session.bus.0)? != session.owner {
            return Err("ScreenCast owner changed.");
        }
        let mut node_data = Box::new(SignalData {
            owner: session.owner.clone(),
            stream: stream.clone(),
            token,
            first: None,
            events: events.clone(),
        });
        session.node_subscription = gio::g_dbus_connection_signal_subscribe(
            session.bus.0,
            c(&session.owner).as_ptr(),
            c(STREAM).as_ptr(),
            c("PipeWireStreamAdded").as_ptr(),
            c(&stream).as_ptr(),
            ptr::null(),
            0,
            Some(node_signal),
            (&mut *node_data as *mut SignalData).cast(),
            ptr::null_mut(),
        );
        if session.node_subscription == 0 {
            return Err("Cannot subscribe to ScreenCast stream.");
        }
        session.node_data = Some(node_data);
        let value = call(
            session.bus.0,
            &session.owner,
            &session.path,
            SESSION,
            "Start",
            ptr::null_mut(),
        )
        .map_err(|_| "Cannot start ScreenCast session.")?;
        if value.kind() != "()" || owner(session.bus.0)? != session.owner {
            return Err("ScreenCast owner changed.");
        }
        Ok(session)
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        unsafe {
            if self.node_subscription != 0 {
                gio::g_dbus_connection_signal_unsubscribe(self.bus.0, self.node_subscription);
            }
            if self.owner_subscription != 0 {
                gio::g_dbus_connection_signal_unsubscribe(self.bus.0, self.owner_subscription);
            }
            if !self.stopped && !self.path.is_empty() {
                let _ = call(
                    self.bus.0,
                    &self.owner,
                    &self.path,
                    SESSION,
                    "Stop",
                    ptr::null_mut(),
                );
                self.stopped = true;
            }
        }
    }
}
