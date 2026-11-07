//! Watch NetworkManager and register the agent on its current unique owner.
use crate::{Agent, Event};
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use std::cell::RefCell;
use std::ffi::c_char;
use std::ptr;
use std::rc::{Rc, Weak};
use std::sync::mpsc::Sender;

const NM: &str = "org.freedesktop.NetworkManager";
const MANAGER: &str = "/org/freedesktop/NetworkManager/AgentManager";
const MANAGER_IFACE: &str = "org.freedesktop.NetworkManager.AgentManager";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostEvent {
    Owner {
        unique: Option<String>,
        epoch: u64,
        abandoned: Option<u64>,
    },
    Registration {
        epoch: u64,
        success: bool,
    },
    /// The caller must close the dedicated connection before retrying. A
    /// registration may have succeeded despite an uncertain or stale reply.
    CloseConnection,
}

struct State {
    bus: Ptr,
    agent: Agent,
    owner: Option<String>,
    pending: Option<u64>,
    closing: bool,
    timeout_ms: i32,
    events: Sender<HostEvent>,
}
impl State {
    fn close_needed(&mut self) {
        if self.closing {
            return;
        }
        self.closing = true;
        self.owner = None;
        self.pending = None;
        if let Ok(reset) = self.agent.owner_changed(None) {
            let _ = self.events.send(HostEvent::Owner {
                unique: None,
                epoch: self.agent.epoch(),
                abandoned: reset.request,
            });
        }
        let _ = self.events.send(HostEvent::CloseConnection);
    }
}

/// The caller must close this dedicated connection on `CloseConnection` and
/// after dropping the host, including when registration is still in flight.
/// Drain both event channels outside Gio callbacks to avoid reentrancy.
pub struct AgentHost {
    state: Rc<RefCell<State>>,
    watch: u32,
}
impl AgentHost {
    /// # Safety
    /// The dedicated live Gio connection and its GLib main context must
    /// outlive this host. Construct, use and drop it on that context's thread.
    pub unsafe fn new(
        bus: Ptr,
        agent_events: Sender<Event>,
        events: Sender<HostEvent>,
    ) -> Result<Self, String> {
        Self::new_with_timeout(bus, agent_events, events, 5000)
    }
    /// As `new`, with a bounded registration timeout in milliseconds.
    ///
    /// # Safety
    /// The connection and context requirements of `new` apply.
    pub unsafe fn new_with_timeout(
        bus: Ptr,
        agent_events: Sender<Event>,
        events: Sender<HostEvent>,
        timeout_ms: i32,
    ) -> Result<Self, String> {
        if !(1..=5000).contains(&timeout_ms) {
            return Err("Invalid registration timeout".into());
        }
        let agent = Agent::new(bus, agent_events)?;
        let state = Rc::new(RefCell::new(State {
            bus,
            agent,
            owner: None,
            pending: None,
            closing: false,
            timeout_ms,
            events,
        }));
        let data = Box::into_raw(Box::new(Rc::downgrade(&state))).cast();
        let watch = gio::g_bus_watch_name_on_connection(
            bus,
            c(NM).as_ptr(),
            0,
            Some(appeared),
            Some(vanished),
            data,
            drop_watch as *const () as Ptr,
        );
        if watch == 0 {
            drop(Box::from_raw(data.cast::<Weak<RefCell<State>>>()));
            return Err("Could not watch NetworkManager".into());
        }
        Ok(Self { state, watch })
    }
    /// Use only on the owning GLib context, never reentrantly from a callback.
    pub fn with_agent<T>(&self, f: impl FnOnce(&mut Agent) -> T) -> T {
        f(&mut self.state.borrow_mut().agent)
    }
}
impl Drop for AgentHost {
    fn drop(&mut self) {
        unsafe { gio::g_bus_unwatch_name(self.watch) }
    }
}
extern "C" fn drop_watch(data: Ptr) {
    unsafe { drop(Box::from_raw(data.cast::<Weak<RefCell<State>>>())) }
}
struct Pending {
    state: Weak<RefCell<State>>,
    owner: String,
    epoch: u64,
}

extern "C" fn appeared(_: Ptr, _: *const c_char, owner: *const c_char, data: Ptr) {
    unsafe {
        let Some(handle) = (&*data.cast::<Weak<RefCell<State>>>()).upgrade() else {
            return;
        };
        let mut state = handle.borrow_mut();
        if state.closing {
            return;
        }
        if state.pending.is_some() || state.owner.is_some() {
            state.close_needed();
            return;
        }
        let owner = gio::text(owner);
        let Ok(reset) = state.agent.owner_changed(Some(&owner)) else {
            state.close_needed();
            return;
        };
        state.owner = Some(owner.clone());
        let epoch = state.agent.epoch();
        if state
            .events
            .send(HostEvent::Owner {
                unique: Some(owner.clone()),
                epoch,
                abandoned: reset.request,
            })
            .is_err()
        {
            state.close_needed();
            return;
        }
        state.pending = Some(epoch);
        let pending = Box::new(Pending {
            state: Rc::downgrade(&handle),
            owner: owner.clone(),
            epoch,
        });
        gio::g_dbus_connection_call(
            state.bus,
            c(&owner).as_ptr(),
            c(MANAGER).as_ptr(),
            c(MANAGER_IFACE).as_ptr(),
            c("Register").as_ptr(),
            gio::tuple(&[gio::string("org.macshell.niri")]),
            ptr::null_mut(),
            0,
            state.timeout_ms,
            ptr::null_mut(),
            Some(registered),
            Box::into_raw(pending).cast(),
        );
    }
}
extern "C" fn registered(bus: Ptr, result: Ptr, data: Ptr) {
    unsafe {
        let pending = Box::from_raw(data.cast::<Pending>());
        let mut error = ptr::null_mut();
        let reply = Variant::from(gio::g_dbus_connection_call_finish(bus, result, &mut error));
        let remote = !error.is_null() && gio::g_dbus_error_is_remote_error(error) != 0;
        if !error.is_null() {
            gio::g_error_free(error);
        }
        let Some(handle) = pending.state.upgrade() else {
            return;
        };
        let mut state = handle.borrow_mut();
        if state.closing {
            return;
        }
        if state.pending != Some(pending.epoch) || state.owner.as_deref() != Some(&pending.owner) {
            state.close_needed();
            return;
        }
        state.pending = None;
        let success = reply.as_ref().is_some_and(|v| v.kind() == "()");
        if !success && !remote {
            state.close_needed();
            return;
        }
        if !state.agent.registered(pending.epoch, success) {
            state.close_needed();
            return;
        }
        if state
            .events
            .send(HostEvent::Registration {
                epoch: pending.epoch,
                success,
            })
            .is_err()
        {
            state.close_needed();
        }
    }
}
extern "C" fn vanished(_: Ptr, _: *const c_char, data: Ptr) {
    unsafe {
        let Some(handle) = (&*data.cast::<Weak<RefCell<State>>>()).upgrade() else {
            return;
        };
        let mut state = handle.borrow_mut();
        if state.closing {
            return;
        }
        if state.pending.is_some() || state.owner.is_some() {
            state.close_needed();
            return;
        }
        state.owner = None;
        let Ok(reset) = state.agent.owner_changed(None) else {
            state.close_needed();
            return;
        };
        let epoch = state.agent.epoch();
        if state
            .events
            .send(HostEvent::Owner {
                unique: None,
                epoch,
                abandoned: reset.request,
            })
            .is_err()
        {
            state.close_needed();
        }
    }
}
