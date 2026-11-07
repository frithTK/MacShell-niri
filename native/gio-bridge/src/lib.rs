//! Narrow, unsafe declarations for the system GLib/Gio ABI.
//!
//! Callers must keep objects, callback data, and the GLib main context alive
//! for the lifetime of each registered source and asynchronous request. Values
//! returned as owned `GVariant` references belong in `Variant`; floating input
//! variants are transferred to the relevant Gio call. Never pass untrusted
//! strings containing NUL to `c` or retain borrowed C pointers across calls.
use std::ffi::{c_char, c_int, c_uint, c_void, CStr, CString};
use std::ptr;

pub type Ptr = *mut c_void;
#[repr(C)]
pub struct GError {
    pub domain: u32,
    pub code: c_int,
    pub message: *mut c_char,
}
pub type Source = extern "C" fn(c_int, c_uint, Ptr) -> c_int;
pub type Appeared = extern "C" fn(Ptr, *const c_char, *const c_char, Ptr);
pub type Vanished = extern "C" fn(Ptr, *const c_char, Ptr);
pub type Signal =
    extern "C" fn(Ptr, *const c_char, *const c_char, *const c_char, *const c_char, Ptr, Ptr);
pub type Done = extern "C" fn(Ptr, Ptr, Ptr);
pub type MethodCall =
    extern "C" fn(Ptr, *const c_char, *const c_char, *const c_char, *const c_char, Ptr, Ptr, Ptr);
#[repr(C)]
pub struct InterfaceVTable {
    pub method_call: Option<MethodCall>,
    pub get_property: Ptr,
    pub set_property: Ptr,
    pub padding: [Ptr; 8],
}
#[link(name = "gio-2.0")]
extern "C" {
    pub fn g_dbus_is_unique_name(name: *const c_char) -> c_int;
    pub fn g_dbus_address_get_for_bus_sync(
        bus_type: c_int,
        cancellable: Ptr,
        error: *mut *mut GError,
    ) -> *mut c_char;
    pub fn g_dbus_connection_new_for_address_sync(
        address: *const c_char,
        flags: c_uint,
        observer: Ptr,
        cancellable: Ptr,
        error: *mut *mut GError,
    ) -> Ptr;
    pub fn g_dbus_connection_is_closed(connection: Ptr) -> c_int;
    pub fn g_dbus_error_is_remote_error(error: *const GError) -> c_int;
    pub fn g_bus_get_sync(bus_type: c_int, cancellable: Ptr, error: *mut *mut GError) -> Ptr;
    pub fn g_bus_watch_name_on_connection(
        connection: Ptr,
        name: *const c_char,
        flags: c_uint,
        appeared: Option<Appeared>,
        vanished: Option<Vanished>,
        data: Ptr,
        destroy: Ptr,
    ) -> c_uint;
    pub fn g_bus_unwatch_name(watcher: c_uint);
    pub fn g_dbus_connection_signal_subscribe(
        connection: Ptr,
        sender: *const c_char,
        interface: *const c_char,
        signal: *const c_char,
        path: *const c_char,
        arg0: *const c_char,
        flags: c_uint,
        callback: Option<Signal>,
        data: Ptr,
        destroy: Ptr,
    ) -> c_uint;
    pub fn g_dbus_connection_signal_unsubscribe(connection: Ptr, id: c_uint);
    pub fn g_dbus_connection_call_sync(
        connection: Ptr,
        bus_name: *const c_char,
        path: *const c_char,
        interface: *const c_char,
        method: *const c_char,
        parameters: Ptr,
        reply_type: Ptr,
        flags: c_uint,
        timeout: c_int,
        cancellable: Ptr,
        error: *mut *mut GError,
    ) -> Ptr;
    pub fn g_dbus_connection_call(
        connection: Ptr,
        bus_name: *const c_char,
        path: *const c_char,
        interface: *const c_char,
        method: *const c_char,
        parameters: Ptr,
        reply_type: Ptr,
        flags: c_uint,
        timeout: c_int,
        cancellable: Ptr,
        callback: Option<Done>,
        data: Ptr,
    );
    pub fn g_dbus_connection_call_finish(
        connection: Ptr,
        result: Ptr,
        error: *mut *mut GError,
    ) -> Ptr;
    pub fn g_dbus_connection_get_unique_name(connection: Ptr) -> *const c_char;
    pub fn g_dbus_connection_set_exit_on_close(connection: Ptr, exit_on_close: c_int);
    pub fn g_dbus_connection_flush_sync(
        connection: Ptr,
        cancellable: Ptr,
        error: *mut *mut GError,
    ) -> c_int;
    pub fn g_dbus_connection_close_sync(
        connection: Ptr,
        cancellable: Ptr,
        error: *mut *mut GError,
    ) -> c_int;
    pub fn g_dbus_node_info_new_for_xml(xml: *const c_char, error: *mut *mut GError) -> Ptr;
    pub fn g_dbus_node_info_lookup_interface(info: Ptr, name: *const c_char) -> Ptr;
    pub fn g_dbus_node_info_unref(info: Ptr);
    pub fn g_dbus_connection_register_object(
        connection: Ptr,
        path: *const c_char,
        info: Ptr,
        vtable: *const InterfaceVTable,
        data: Ptr,
        destroy: Ptr,
        error: *mut *mut GError,
    ) -> c_uint;
    pub fn g_dbus_connection_unregister_object(connection: Ptr, id: c_uint) -> c_int;
    pub fn g_dbus_method_invocation_return_value(invocation: Ptr, parameters: Ptr);
    pub fn g_dbus_method_invocation_return_dbus_error(
        invocation: Ptr,
        name: *const c_char,
        message: *const c_char,
    );
}
#[link(name = "glib-2.0")]
extern "C" {
    pub fn g_get_monotonic_time() -> i64;
    pub fn g_unix_signal_add(
        signum: c_int,
        function: Option<extern "C" fn(Ptr) -> c_int>,
        data: Ptr,
    ) -> c_uint;
    pub fn g_utf8_casefold(value: *const c_char, length: isize) -> *mut c_char;
    pub fn g_free(memory: Ptr);
    pub fn g_main_loop_new(context: Ptr, running: c_int) -> Ptr;
    pub fn g_main_loop_run(loop_: Ptr);
    pub fn g_main_loop_quit(loop_: Ptr);
    pub fn g_main_loop_unref(loop_: Ptr);
    pub fn g_unix_fd_add(
        fd: c_int,
        condition: c_uint,
        callback: Option<Source>,
        data: Ptr,
    ) -> c_uint;
    pub fn g_timeout_add_seconds(
        interval: c_uint,
        callback: Option<extern "C" fn(Ptr) -> c_int>,
        data: Ptr,
    ) -> c_uint;
    pub fn g_timeout_add(
        interval: c_uint,
        callback: Option<extern "C" fn(Ptr) -> c_int>,
        data: Ptr,
    ) -> c_uint;
    pub fn g_main_context_default() -> Ptr;
    pub fn g_main_context_find_source_by_id(context: Ptr, id: c_uint) -> Ptr;
    pub fn g_source_destroy(source: Ptr);
    pub fn g_error_free(error: *mut GError);
    pub fn g_variant_new_string(value: *const c_char) -> Ptr;
    pub fn g_variant_new_object_path(value: *const c_char) -> Ptr;
    pub fn g_variant_new_boolean(value: c_int) -> Ptr;
    pub fn g_variant_new_uint32(value: u32) -> Ptr;
    pub fn g_variant_new_uint64(value: u64) -> Ptr;
    pub fn g_variant_new_byte(value: u8) -> Ptr;
    pub fn g_variant_ref_sink(value: Ptr) -> Ptr;
    pub fn g_variant_new_variant(value: Ptr) -> Ptr;
    pub fn g_variant_new_dict_entry(key: Ptr, value: Ptr) -> Ptr;
    pub fn g_variant_new_array(child_type: Ptr, children: *const Ptr, n: usize) -> Ptr;
    pub fn g_variant_type_new(type_string: *const c_char) -> Ptr;
    pub fn g_variant_type_free(type_: Ptr);
    pub fn g_variant_new_tuple(children: *const Ptr, n: usize) -> Ptr;
    pub fn g_variant_unref(value: Ptr);
    pub fn g_variant_n_children(value: Ptr) -> usize;
    pub fn g_variant_get_child_value(value: Ptr, index: usize) -> Ptr;
    pub fn g_variant_lookup_value(value: Ptr, key: *const c_char, expected: Ptr) -> Ptr;
    pub fn g_variant_get_type_string(value: Ptr) -> *const c_char;
    pub fn g_variant_get_string(value: Ptr, length: *mut usize) -> *const c_char;
    pub fn g_variant_get_boolean(value: Ptr) -> c_int;
    pub fn g_variant_get_uint32(value: Ptr) -> u32;
    pub fn g_variant_get_uint64(value: Ptr) -> u64;
    pub fn g_variant_get_uint16(value: Ptr) -> u16;
    pub fn g_variant_get_byte(value: Ptr) -> u8;
}
#[link(name = "gobject-2.0")]
extern "C" {
    pub fn g_object_unref(object: Ptr);
}

pub fn c(value: &str) -> CString {
    CString::new(value).expect("static or D-Bus-validated string")
}
pub unsafe fn text(value: *const c_char) -> String {
    if value.is_null() {
        String::new()
    } else {
        CStr::from_ptr(value).to_string_lossy().into_owned()
    }
}
pub unsafe fn error(error: *mut GError) -> String {
    if error.is_null() {
        return "D-Bus request failed".into();
    }
    let result = text((*error).message);
    g_error_free(error);
    result
}
pub struct Variant(pub Ptr);
impl Variant {
    pub unsafe fn from(ptr: Ptr) -> Option<Self> {
        if ptr.is_null() {
            None
        } else {
            Some(Self(ptr))
        }
    }
    pub unsafe fn kind(&self) -> String {
        text(g_variant_get_type_string(self.0))
    }
    pub unsafe fn child(&self, index: usize) -> Option<Self> {
        if index >= g_variant_n_children(self.0) {
            None
        } else {
            Self::from(g_variant_get_child_value(self.0, index))
        }
    }
    pub unsafe fn lookup(&self, key: &str) -> Option<Self> {
        Self::from(g_variant_lookup_value(
            self.0,
            c(key).as_ptr(),
            ptr::null_mut(),
        ))
    }
    pub unsafe fn string(&self) -> Option<String> {
        if self.kind() != "s" {
            None
        } else {
            Some(text(g_variant_get_string(self.0, ptr::null_mut())))
        }
    }
    pub unsafe fn object_path(&self) -> Option<String> {
        if self.kind() != "o" {
            None
        } else {
            Some(text(g_variant_get_string(self.0, ptr::null_mut())))
        }
    }
    pub unsafe fn u16(&self) -> Option<u16> {
        if self.kind() != "q" {
            None
        } else {
            Some(g_variant_get_uint16(self.0))
        }
    }
    pub unsafe fn byte(&self) -> Option<u8> {
        if self.kind() != "y" {
            None
        } else {
            Some(g_variant_get_byte(self.0))
        }
    }
    pub unsafe fn u32(&self) -> Option<u32> {
        if self.kind() != "u" {
            None
        } else {
            Some(g_variant_get_uint32(self.0))
        }
    }
    pub unsafe fn u64(&self) -> Option<u64> {
        if self.kind() != "t" {
            None
        } else {
            Some(g_variant_get_uint64(self.0))
        }
    }
    pub unsafe fn boolean(&self) -> Option<bool> {
        if self.kind() != "b" {
            None
        } else {
            Some(g_variant_get_boolean(self.0) != 0)
        }
    }
    pub unsafe fn len(&self) -> usize {
        g_variant_n_children(self.0)
    }
}
impl Drop for Variant {
    fn drop(&mut self) {
        unsafe {
            g_variant_unref(self.0);
        }
    }
}
pub unsafe fn string(value: &str) -> Ptr {
    g_variant_new_string(c(value).as_ptr())
}
pub unsafe fn tuple(children: &[Ptr]) -> Ptr {
    g_variant_new_tuple(children.as_ptr(), children.len())
}
