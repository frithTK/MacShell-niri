//! NetworkManager SecretAgent endpoint, not yet connected to the shell.
//!
//! The owning service must keep the dedicated Gio connection and GLib context
//! alive, supply verified owner/registration changes, and finish operations.
//! Passwords stay with the owner until `reply`: this agent never stores them or
//! emits them in events. Gio/D-Bus can make its own copies during transmission.
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use macshell_network_core::secret_agent::{Request, Reset, SecretAgent, Ticket};
use std::ffi::{c_char, CString};
use std::marker::PhantomData;
use std::ptr;
use std::rc::Rc;
use std::sync::atomic::{compiler_fence, Ordering};
use std::sync::mpsc::Sender;

pub mod host;

pub const PATH: &str = "/org/freedesktop/NetworkManager/SecretAgent";
pub const IFACE: &str = "org.freedesktop.NetworkManager.SecretAgent";
const SETTING: &str = "802-11-wireless-security";
const XML: &str = r#"<node><interface name="org.freedesktop.NetworkManager.SecretAgent">
<method name="GetSecrets"><arg type="a{sa{sv}}" direction="in"/><arg type="o" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/><arg type="u" direction="in"/><arg type="a{sa{sv}}" direction="out"/></method>
<method name="CancelGetSecrets"><arg type="o" direction="in"/><arg type="s" direction="in"/></method>
<method name="SaveSecrets"><arg type="a{sa{sv}}" direction="in"/><arg type="o" direction="in"/></method>
<method name="DeleteSecrets"><arg type="a{sa{sv}}" direction="in"/><arg type="o" direction="in"/></method>
</interface></node>"#;
const NOT_AUTHORIZED: &str = "org.freedesktop.NetworkManager.SecretAgent.NotAuthorized";
const NO_SECRETS: &str = "org.freedesktop.NetworkManager.SecretAgent.NoSecrets";
const AGENT_CANCELED: &str = "org.freedesktop.NetworkManager.SecretAgent.AgentCanceled";
const USER_CANCELED: &str = "org.freedesktop.NetworkManager.SecretAgent.UserCanceled";
const INTERNAL_ERROR: &str = "org.freedesktop.NetworkManager.SecretAgent.InternalError";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// `provided` means the owner should return the initial secret for this
    /// operation, without prompting. Otherwise request a fresh user secret.
    NeedSecret {
        request: u64,
        delivery: u64,
        provided: bool,
        discard_provided: bool,
    },
    Canceled {
        request: u64,
        delivery: u64,
    },
    Cleared {
        request: u64,
        delivery: u64,
    },
}

struct Pending {
    invocation: Ptr,
    ticket: Ticket,
    delivery: u64,
    profile: String,
    prompt: Option<u64>,
}
struct Inner {
    core: SecretAgent,
    ticket: Option<Ticket>,
    pending: Option<Pending>,
    delivery: u64,
    events: Sender<Event>,
}
impl Inner {
    unsafe fn reject_pending(&mut self, name: &str) -> Option<Pending> {
        let pending = self.pending.take()?;
        gio::g_dbus_method_invocation_return_dbus_error(
            pending.invocation,
            c(name).as_ptr(),
            c("Request canceled").as_ptr(),
        );
        Some(pending)
    }
    fn emit(&self, event: Event) -> bool {
        self.events.send(event).is_ok()
    }
}

pub struct Agent {
    bus: Ptr,
    node: Ptr,
    registration: u32,
    _vtable: Box<gio::InterfaceVTable>,
    inner: Box<Inner>,
    _not_send: PhantomData<Rc<()>>,
}
impl Agent {
    /// # Safety
    /// `bus` must be a dedicated live Gio connection on this GLib context,
    /// and remain alive until the agent is dropped on the same thread.
    pub unsafe fn new(bus: Ptr, events: Sender<Event>) -> Result<Self, String> {
        if bus.is_null() {
            return Err("Missing D-Bus connection".into());
        }
        let mut error = ptr::null_mut();
        let node = gio::g_dbus_node_info_new_for_xml(c(XML).as_ptr(), &mut error);
        if node.is_null() {
            return Err(gio::error(error));
        }
        let info = gio::g_dbus_node_info_lookup_interface(node, c(IFACE).as_ptr());
        if info.is_null() {
            gio::g_dbus_node_info_unref(node);
            return Err("Missing SecretAgent interface".into());
        }
        let mut inner = Box::new(Inner {
            core: SecretAgent::new(),
            ticket: None,
            pending: None,
            delivery: 0,
            events,
        });
        let vtable = Box::new(gio::InterfaceVTable {
            method_call: Some(method_call),
            get_property: ptr::null_mut(),
            set_property: ptr::null_mut(),
            padding: [ptr::null_mut(); 8],
        });
        let registration = gio::g_dbus_connection_register_object(
            bus,
            c(PATH).as_ptr(),
            info,
            &*vtable,
            (&mut *inner as *mut Inner).cast(),
            ptr::null_mut(),
            &mut error,
        );
        if registration == 0 {
            gio::g_dbus_node_info_unref(node);
            return Err(gio::error(error));
        }
        Ok(Self {
            bus,
            node,
            registration,
            _vtable: vtable,
            inner,
            _not_send: PhantomData,
        })
    }
    pub fn epoch(&self) -> u64 {
        self.inner.core.epoch()
    }
    pub fn registered(&mut self, epoch: u64, success: bool) -> bool {
        self.inner.core.registered(epoch, success)
    }
    /// Called for every observed owner loss or replacement, including a return
    /// of the same unique owner. Cancels any outstanding D-Bus invocation.
    pub fn owner_changed(&mut self, owner: Option<&str>) -> Result<Reset, &'static str> {
        let reset = self.inner.core.owner_changed(owner)?;
        self.inner.ticket = None;
        if let Some(pending) = unsafe { self.inner.reject_pending(AGENT_CANCELED) } {
            self.inner.emit(Event::Canceled {
                request: pending.ticket.request,
                delivery: pending.delivery,
            });
        }
        Ok(reset)
    }
    pub fn begin(
        &mut self,
        request: u64,
        uuid: &str,
        profile: Option<&str>,
        has_initial: bool,
    ) -> Result<Ticket, &'static str> {
        let ticket = self.inner.core.begin(request, uuid, profile, has_initial)?;
        self.inner.ticket = Some(ticket);
        Ok(ticket)
    }
    /// Answer only the exact ticket/delivery. The caller remains responsible
    /// for promptly erasing its password and any copies it created.
    pub fn reply(
        &mut self,
        ticket: Ticket,
        delivery: u64,
        password: &str,
    ) -> Result<bool, &'static str> {
        let Some(pending) = self
            .inner
            .pending
            .as_ref()
            .filter(|p| p.ticket == ticket && p.delivery == delivery)
        else {
            return Ok(false);
        };
        if password.is_empty() || password.len() > 1024 || password.contains('\0') {
            return Err("Invalid secret");
        }
        if let Some(prompt) = pending.prompt {
            if !self.inner.core.answer(ticket, prompt) {
                return Ok(false);
            }
        }
        let secret = CString::new(password.as_bytes()).map_err(|_| "Invalid secret")?;
        let pending = self.inner.pending.take().ok_or("Missing secret request")?;
        unsafe {
            return_secret(pending.invocation, &secret);
        }
        // Remove our transient C copy; the caller and Gio own separate copies.
        let mut bytes = secret.into_bytes_with_nul();
        for byte in &mut bytes {
            unsafe {
                ptr::write_volatile(byte, 0);
            }
        }
        compiler_fence(Ordering::SeqCst);
        self.inner.emit(Event::Cleared {
            request: ticket.request,
            delivery,
        });
        Ok(true)
    }
    /// Finish or cancel exactly this activation, rejecting a pending call.
    pub fn finish(&mut self, ticket: Ticket, canceled_by_user: bool) -> Option<Reset> {
        let reset = self.inner.core.finish(ticket)?;
        self.inner.ticket = None;
        if let Some(pending) = unsafe {
            self.inner.reject_pending(if canceled_by_user {
                USER_CANCELED
            } else {
                AGENT_CANCELED
            })
        } {
            self.inner.emit(Event::Canceled {
                request: ticket.request,
                delivery: pending.delivery,
            });
        }
        Some(reset)
    }
}
impl Drop for Agent {
    fn drop(&mut self) {
        unsafe {
            self.inner.reject_pending(AGENT_CANCELED);
            gio::g_dbus_connection_unregister_object(self.bus, self.registration);
            gio::g_dbus_node_info_unref(self.node);
        }
    }
}

unsafe fn return_secret(invocation: Ptr, secret: &CString) {
    let value = gio::g_variant_new_string(secret.as_ptr());
    let entry =
        gio::g_variant_new_dict_entry(gio::string("psk"), gio::g_variant_new_variant(value));
    let inner = gio::g_variant_new_array(ptr::null_mut(), [entry].as_ptr(), 1);
    let outer_entry = gio::g_variant_new_dict_entry(gio::string(SETTING), inner);
    let outer = gio::g_variant_new_array(ptr::null_mut(), [outer_entry].as_ptr(), 1);
    gio::g_dbus_method_invocation_return_value(invocation, gio::tuple(&[outer]));
}
unsafe fn arg(params: Ptr, index: usize) -> Option<Variant> {
    if params.is_null() || index >= gio::g_variant_n_children(params) {
        None
    } else {
        Variant::from(gio::g_variant_get_child_value(params, index))
    }
}
unsafe fn get_args(params: Ptr) -> Option<(String, String, String, u32)> {
    let settings = arg(params, 0)?;
    if settings.kind() != "a{sa{sv}}" {
        return None;
    }
    let uuid = settings.lookup("connection")?.lookup("uuid")?.string()?;
    let path = arg(params, 1)?.object_path()?;
    let setting = arg(params, 2)?.string()?;
    let flags = arg(params, 4)?.u32()?;
    Some((uuid, path, setting, flags))
}
unsafe fn reject(invocation: Ptr, name: &str) {
    gio::g_dbus_method_invocation_return_dbus_error(
        invocation,
        c(name).as_ptr(),
        c("Secret request rejected").as_ptr(),
    );
}
extern "C" fn method_call(
    _: Ptr,
    sender: *const c_char,
    _: *const c_char,
    _: *const c_char,
    method: *const c_char,
    params: Ptr,
    invocation: Ptr,
    data: Ptr,
) {
    unsafe {
        let inner = &mut *data.cast::<Inner>();
        let sender = gio::text(sender);
        if !inner.core.authorized(&sender) {
            reject(invocation, NOT_AUTHORIZED);
            return;
        }
        match gio::text(method).as_str() {
            "GetSecrets" => {
                if inner.pending.is_some() {
                    reject(invocation, NO_SECRETS);
                    return;
                }
                let Some((uuid, profile, setting, flags)) = get_args(params) else {
                    reject(invocation, NO_SECRETS);
                    return;
                };
                let request = inner
                    .core
                    .get_secrets(&sender, &uuid, &profile, &setting, flags);
                let (request, prompt, provided, discard) = match request {
                    Request::NotAuthorized => {
                        reject(invocation, NOT_AUTHORIZED);
                        return;
                    }
                    Request::NoSecrets => {
                        reject(invocation, NO_SECRETS);
                        return;
                    }
                    Request::UseProvided { request } => (request, None, true, false),
                    Request::Prompt {
                        request,
                        prompt,
                        discard_provided,
                    } => (request, Some(prompt), false, discard_provided),
                };
                let Some(ticket) = inner.ticket.filter(|ticket| ticket.request == request) else {
                    if prompt.is_some() {
                        inner.core.cancel_get(&sender, &profile, &setting);
                    }
                    reject(invocation, INTERNAL_ERROR);
                    return;
                };
                let Some(delivery) = inner.delivery.checked_add(1) else {
                    if prompt.is_some() {
                        inner.core.cancel_get(&sender, &profile, &setting);
                    }
                    reject(invocation, INTERNAL_ERROR);
                    return;
                };
                inner.delivery = delivery;
                inner.pending = Some(Pending {
                    invocation,
                    ticket,
                    delivery,
                    profile: profile.clone(),
                    prompt,
                });
                if !inner.emit(Event::NeedSecret {
                    request,
                    delivery,
                    provided,
                    discard_provided: discard,
                }) {
                    if prompt.is_some() {
                        inner.core.cancel_get(&sender, &profile, &setting);
                    }
                    inner.reject_pending(AGENT_CANCELED);
                }
            }
            "CancelGetSecrets" => {
                let path = arg(params, 0).and_then(|v| v.object_path());
                let setting = arg(params, 1).and_then(|v| v.string());
                if let (Some(path), Some(setting)) = (path, setting) {
                    let matches = inner
                        .pending
                        .as_ref()
                        .is_some_and(|p| p.profile == path && setting == SETTING);
                    if matches {
                        inner.core.cancel_get(&sender, &path, &setting);
                        if let Some(pending) = inner.reject_pending(AGENT_CANCELED) {
                            inner.emit(Event::Canceled {
                                request: pending.ticket.request,
                                delivery: pending.delivery,
                            });
                        }
                    }
                }
                gio::g_dbus_method_invocation_return_value(invocation, ptr::null_mut());
            }
            // No persistent secret store exists. Never claim to have saved one.
            "SaveSecrets" => reject(invocation, INTERNAL_ERROR),
            "DeleteSecrets" => {
                gio::g_dbus_method_invocation_return_value(invocation, ptr::null_mut())
            }
            _ => reject(invocation, INTERNAL_ERROR),
        }
    }
}
