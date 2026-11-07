//! Exported BlueZ Agent1 endpoint; no adapter, discovery or pairing calls occur here.
//!
//! This module is not wired into the running shell. The owning transport must
//! keep the Gio connection and its main context alive, drain events without
//! reentrancy, and handle cancellation/owner changes before closing the bus.
use macshell_bluetooth_core::pairing::{
    AgentResult, Method, PairingCore, Prompt, Reply, Reset, Step, Ticket,
};
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use std::marker::PhantomData;
use std::ptr;
use std::rc::Rc;
use std::sync::mpsc::Sender;

pub mod host;

pub const PATH: &str = "/org/macshell/BluetoothAgent";
const IFACE: &str = "org.bluez.Agent1";
const XML: &str = r#"<node><interface name="org.bluez.Agent1">
<method name="Release"/>
<method name="RequestPinCode"><arg type="o" direction="in"/><arg type="s" direction="out"/></method>
<method name="DisplayPinCode"><arg type="o" direction="in"/><arg type="s" direction="in"/></method>
<method name="RequestPasskey"><arg type="o" direction="in"/><arg type="u" direction="out"/></method>
<method name="DisplayPasskey"><arg type="o" direction="in"/><arg type="u" direction="in"/><arg type="q" direction="in"/></method>
<method name="RequestConfirmation"><arg type="o" direction="in"/><arg type="u" direction="in"/></method>
<method name="RequestAuthorization"><arg type="o" direction="in"/></method>
<method name="AuthorizeService"><arg type="o" direction="in"/><arg type="s" direction="in"/></method>
<method name="Cancel"/></interface></node>"#;
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    Prompt(Prompt),
    Cleared,
    PairCanceled { request: u64, device: String },
    OwnerReset(Reset),
    Released,
}
struct Inner {
    core: PairingCore,
    invocation: Option<Ptr>,
    events: Sender<Event>,
}
impl Inner {
    unsafe fn cancel_invocation(&mut self) {
        if let Some(invocation) = self.invocation.take() {
            gio::g_dbus_method_invocation_return_dbus_error(
                invocation,
                c("org.bluez.Error.Canceled").as_ptr(),
                c("Canceled by user").as_ptr(),
            );
        }
    }
    fn emit(&self, event: Event) {
        let _ = self.events.send(event);
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
    /// `bus` must be a live Gio connection, used from its owning GLib main
    /// context and kept alive until this agent is dropped on that same thread.
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
            return Err("Missing Agent1 interface".into());
        }
        let mut inner = Box::new(Inner {
            core: PairingCore::new(),
            invocation: None,
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
    pub fn has_pending(&self) -> bool {
        self.inner.core.has_pending()
    }
    /// Supply only the unique owner obtained from the D-Bus name watcher.
    /// Call again for every owner loss or replacement, even if a name is reused.
    pub fn owner_changed(&mut self, owner: Option<&str>) -> Reset {
        let reset = self.inner.core.owner_changed(owner);
        if reset.cancel_prompt {
            unsafe {
                self.inner.cancel_invocation();
            }
        }
        self.inner.emit(Event::Cleared);
        self.inner.emit(Event::OwnerReset(reset.clone()));
        reset
    }
    /// Report the AgentManager registration result for the captured owner epoch.
    pub fn registered(&mut self, epoch: u64, success: bool) -> bool {
        self.inner.core.registered(epoch, success)
    }
    pub fn begin(
        &mut self,
        request: u64,
        device: &str,
        name: &str,
        now_ms: u64,
    ) -> Result<Ticket, &'static str> {
        self.inner.core.begin(request, device, name, now_ms)
    }
    pub fn respond(
        &mut self,
        prompt: u64,
        accept: bool,
        value: &str,
    ) -> Result<Reply, &'static str> {
        let reply = self.inner.core.respond(prompt, accept, value)?;
        unsafe {
            match &reply {
                Reply::Ignored => (),
                Reply::Cancel {
                    request,
                    device,
                    cancel_prompt,
                } => {
                    if *cancel_prompt {
                        self.inner.cancel_invocation();
                    }
                    self.inner.emit(Event::Cleared);
                    self.inner.emit(Event::PairCanceled {
                        request: *request,
                        device: device.clone(),
                    });
                }
                Reply::Accepted | Reply::Pin(_) | Reply::Passkey(_) => {
                    let invocation = self
                        .inner
                        .invocation
                        .take()
                        .ok_or("Missing pending BlueZ invocation")?;
                    let params = match &reply {
                        Reply::Pin(v) => gio::tuple(&[gio::string(v)]),
                        Reply::Passkey(v) => gio::tuple(&[gio::g_variant_new_uint32(*v)]),
                        _ => ptr::null_mut(),
                    };
                    gio::g_dbus_method_invocation_return_value(invocation, params);
                    self.inner.emit(Event::Cleared);
                }
            }
        }
        Ok(reply)
    }
    pub fn cancel(&mut self, request: u64) -> Option<Reply> {
        let result = self.inner.core.cancel(request)?;
        if let Reply::Cancel {
            request,
            device,
            cancel_prompt,
        } = &result
        {
            if *cancel_prompt {
                unsafe {
                    self.inner.cancel_invocation();
                }
            }
            self.inner.emit(Event::Cleared);
            self.inner.emit(Event::PairCanceled {
                request: *request,
                device: device.clone(),
            });
        }
        Some(result)
    }
    pub fn expired(&mut self, now_ms: u64) -> Option<Reply> {
        let result = self.inner.core.expired(now_ms)?;
        if let Reply::Cancel {
            request,
            device,
            cancel_prompt,
        } = &result
        {
            if *cancel_prompt {
                unsafe {
                    self.inner.cancel_invocation();
                }
            }
            self.inner.emit(Event::Cleared);
            self.inner.emit(Event::PairCanceled {
                request: *request,
                device: device.clone(),
            });
        }
        Some(result)
    }
    pub fn paired(&mut self, ticket: Ticket, confirmed: bool) -> Step {
        let step = self.inner.core.paired(ticket, confirmed);
        if matches!(
            &step,
            Step::Trust {
                cancel_prompt: true,
                ..
            } | Step::Finished {
                cancel_prompt: true,
                ..
            }
        ) {
            unsafe {
                self.inner.cancel_invocation();
            }
        }
        if !matches!(&step, Step::Ignored) {
            self.inner.emit(Event::Cleared);
        }
        step
    }
    pub fn trusted(&mut self, ticket: Ticket, success: bool) -> Step {
        self.inner.core.trusted(ticket, success)
    }
    pub fn connected(&mut self, ticket: Ticket, success: bool) -> Step {
        self.inner.core.connected(ticket, success)
    }
}
impl Drop for Agent {
    fn drop(&mut self) {
        unsafe {
            self.inner.cancel_invocation();
            gio::g_dbus_connection_unregister_object(self.bus, self.registration);
            gio::g_dbus_node_info_unref(self.node);
        }
    }
}
unsafe fn arg(params: Ptr, index: usize) -> Option<Variant> {
    if params.is_null() || index >= gio::g_variant_n_children(params) {
        None
    } else {
        Variant::from(gio::g_variant_get_child_value(params, index))
    }
}
unsafe fn parse(method: &str, params: Ptr) -> Option<(Option<String>, Method)> {
    if method == "Release" {
        return Some((None, Method::Release));
    }
    if method == "Cancel" {
        return Some((None, Method::Cancel));
    }
    let device = arg(params, 0)?.object_path()?;
    let method = match method {
        "RequestPinCode" => Method::RequestPinCode,
        "DisplayPinCode" => Method::DisplayPinCode(arg(params, 1)?.string()?),
        "RequestPasskey" => Method::RequestPasskey,
        "DisplayPasskey" => Method::DisplayPasskey {
            code: arg(params, 1)?.u32()?,
            entered: arg(params, 2)?.u16()?,
        },
        "RequestConfirmation" => Method::RequestConfirmation(arg(params, 1)?.u32()?),
        "RequestAuthorization" => Method::RequestAuthorization,
        "AuthorizeService" => Method::AuthorizeService(arg(params, 1)?.string()?),
        _ => return None,
    };
    Some((Some(device), method))
}
extern "C" fn method_call(
    _: Ptr,
    sender: *const std::ffi::c_char,
    _: *const std::ffi::c_char,
    _: *const std::ffi::c_char,
    method: *const std::ffi::c_char,
    params: Ptr,
    invocation: Ptr,
    data: Ptr,
) {
    unsafe {
        let inner = &mut *data.cast::<Inner>();
        let Some((device, method)) = parse(&gio::text(method), params) else {
            gio::g_dbus_method_invocation_return_dbus_error(
                invocation,
                c("org.bluez.Error.Rejected").as_ptr(),
                c("Invalid agent request").as_ptr(),
            );
            return;
        };
        match inner
            .core
            .agent(&gio::text(sender), device.as_deref(), method)
        {
            AgentResult::Rejected(message) => gio::g_dbus_method_invocation_return_dbus_error(
                invocation,
                c("org.bluez.Error.Rejected").as_ptr(),
                c(message).as_ptr(),
            ),
            AgentResult::Cleared {
                cancel_previous,
                released,
            } => {
                if cancel_previous {
                    inner.cancel_invocation();
                }
                gio::g_dbus_method_invocation_return_value(invocation, ptr::null_mut());
                inner.emit(Event::Cleared);
                if released {
                    inner.emit(Event::Released);
                }
            }
            AgentResult::Prompt {
                value,
                cancel_previous,
            } => {
                if cancel_previous {
                    inner.cancel_invocation();
                }
                if value.deferred {
                    inner.invocation = Some(invocation);
                } else {
                    gio::g_dbus_method_invocation_return_value(invocation, ptr::null_mut());
                }
                inner.emit(Event::Prompt(value));
            }
        }
    }
}
