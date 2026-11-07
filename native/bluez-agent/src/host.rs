//! Watch the unique BlueZ owner and register our non-default agent.
use crate::{Agent, Event, PATH};
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use std::cell::RefCell;
use std::ffi::c_char;
use std::ptr;
use std::rc::{Rc, Weak};
use std::sync::mpsc::Sender;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HostEvent {
    Owner { unique: Option<String>, epoch: u64 },
    Registration { epoch: u64, success: bool },
}

struct State {
    bus: Ptr,
    agent: Agent,
    owner: Option<String>,
    events: Sender<HostEvent>,
}

/// Owns an exported Agent1 and watches BlueZ on its connection's main context.
/// The events channel must be drained outside Gio callbacks to avoid reentry.
pub struct AgentHost {
    state: Rc<RefCell<State>>,
    watch: u32,
}

impl AgentHost {
    /// # Safety
    /// The live Gio connection and GLib main context must outlive this host.
    /// Construct, use and drop the host on the owning context's thread.
    pub unsafe fn new(
        bus: Ptr,
        agent_events: Sender<Event>,
        events: Sender<HostEvent>,
    ) -> Result<Self, String> {
        let agent = Agent::new(bus, agent_events)?;
        let state = Rc::new(RefCell::new(State {
            bus,
            agent,
            owner: None,
            events,
        }));
        let data = Box::into_raw(Box::new(Rc::downgrade(&state))).cast();
        let watch = gio::g_bus_watch_name_on_connection(
            bus,
            c("org.bluez").as_ptr(),
            0,
            Some(appeared),
            Some(vanished),
            data,
            drop_watch as *const () as Ptr,
        );
        if watch == 0 {
            drop(Box::from_raw(data.cast::<Weak<RefCell<State>>>()));
            return Err("Could not watch Bluetooth service".into());
        }
        Ok(Self { state, watch })
    }

    /// Access the agent on the owning GLib thread, never from an event callback.
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
        let Some(state_rc) = (&*data.cast::<Weak<RefCell<State>>>()).upgrade() else {
            return;
        };
        let mut state = state_rc.borrow_mut();
        let owner = gio::text(owner);
        state.owner = Some(owner.clone());
        state.agent.owner_changed(Some(&owner));
        let epoch = state.agent.epoch();
        let _ = state.events.send(HostEvent::Owner {
            unique: Some(owner.clone()),
            epoch,
        });
        let pending = Box::new(Pending {
            state: Rc::downgrade(&state_rc),
            owner: owner.clone(),
            epoch,
        });
        gio::g_dbus_connection_call(
            state.bus,
            c(&owner).as_ptr(),
            c("/org/bluez").as_ptr(),
            c("org.bluez.AgentManager1").as_ptr(),
            c("RegisterAgent").as_ptr(),
            gio::tuple(&[
                gio::g_variant_new_object_path(c(PATH).as_ptr()),
                gio::string("KeyboardDisplay"),
            ]),
            ptr::null_mut(),
            0,
            5000,
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
        let success = reply.is_some();
        if !error.is_null() {
            let _ = gio::error(error);
        }
        let Some(state) = pending.state.upgrade() else {
            return;
        };
        let mut state = state.borrow_mut();
        if state.owner.as_deref() != Some(&pending.owner)
            || !state.agent.registered(pending.epoch, success)
        {
            return;
        }
        let _ = state.events.send(HostEvent::Registration {
            epoch: pending.epoch,
            success,
        });
    }
}

extern "C" fn vanished(_: Ptr, _: *const c_char, data: Ptr) {
    unsafe {
        let Some(state) = (&*data.cast::<Weak<RefCell<State>>>()).upgrade() else {
            return;
        };
        let mut state = state.borrow_mut();
        state.owner = None;
        state.agent.owner_changed(None);
        let _ = state.events.send(HostEvent::Owner {
            unique: None,
            epoch: state.agent.epoch(),
        });
    }
}
