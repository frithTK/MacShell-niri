//! Execute connection-owned BlueZ discovery operations on one GLib context.
use macshell_bluetooth_core::discovery::{DiscoveryCore, Effect};
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::ptr;
use std::rc::{Rc, Weak};
use std::sync::mpsc::Sender;

#[derive(Debug, PartialEq, Eq)]
pub enum Event {
    State {
        owned: usize,
    },
    Error {
        path: String,
        message: String,
    },
    /// Close the entire connection before replacing this transport. BlueZ may
    /// have accepted an operation whose result is unknown to this process.
    CloseConnection,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Operation {
    Start,
    Stop,
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct Call {
    epoch: u64,
    token: u64,
    operation: Operation,
}
struct State {
    bus: Ptr,
    owner: Option<String>,
    core: DiscoveryCore,
    calls: BTreeMap<String, Call>,
    closing: bool,
    events: Sender<Event>,
}
/// The caller owns the connection and must process events without reentry.
/// On drop with outstanding discovery, the caller must still close the old
/// connection; a CloseConnection event is emitted as a reminder.
pub struct Discovery {
    state: Rc<RefCell<State>>,
}
impl Discovery {
    /// # Safety
    /// `bus` must be a live Gio connection kept alive until this object is
    /// dropped. Construct, use and drop it on its owning GLib context thread.
    pub unsafe fn new(bus: Ptr, events: Sender<Event>) -> Result<Self, &'static str> {
        if bus.is_null() {
            return Err("Missing D-Bus connection.");
        }
        Ok(Self {
            state: Rc::new(RefCell::new(State {
                bus,
                owner: None,
                core: DiscoveryCore::new(),
                calls: BTreeMap::new(),
                closing: false,
                events,
            })),
        })
    }
    /// Feed every owner loss/replacement from the bus watcher. When an effect
    /// requires closing the connection, no further operations are accepted.
    pub fn owner_changed(&self, owner: Option<&str>) -> Result<(), &'static str> {
        if owner.is_some_and(|v| {
            v.contains('\0')
                || v.len() > 255
                || unsafe { gio::g_dbus_is_unique_name(c(v).as_ptr()) == 0 }
        }) {
            return Err("Invalid unique D-Bus owner.");
        }
        let mut state = self.state.borrow_mut();
        if state.closing {
            return Err("Discovery connection must be closed.");
        }
        let effects = state.core.owner_changed();
        state.calls.clear();
        state.owner = owner.map(str::to_owned);
        unsafe {
            apply(&self.state, &mut state, effects);
        }
        Ok(())
    }
    pub fn start(&self, now_ms: u64, adapters: &[(String, bool)]) -> Result<(), &'static str> {
        let mut state = self.state.borrow_mut();
        if state.closing {
            return Err("Discovery connection must be closed.");
        }
        if state.owner.is_none() {
            return Err("Bluetooth service is unavailable.");
        }
        let effects = state.core.start(now_ms, adapters)?;
        unsafe {
            apply(&self.state, &mut state, effects);
        }
        Ok(())
    }
    pub fn stop(&self) {
        let mut state = self.state.borrow_mut();
        if !state.closing {
            let effects = state.core.stop();
            unsafe {
                apply(&self.state, &mut state, effects);
            }
        }
    }
    pub fn tick(&self, now_ms: u64) {
        let mut state = self.state.borrow_mut();
        if !state.closing {
            let effects = state.core.tick(now_ms);
            unsafe {
                apply(&self.state, &mut state, effects);
            }
        }
    }
    /// True only after this connection has no discovery calls or references.
    pub fn is_idle(&self) -> bool {
        let state = self.state.borrow();
        !state.closing && state.calls.is_empty() && state.core.owned() == 0
    }
}
impl Drop for Discovery {
    fn drop(&mut self) {
        let mut state = self.state.borrow_mut();
        if !state.closing && !state.core.owner_changed().is_empty() {
            state.closing = true;
            let _ = state.events.send(Event::CloseConnection);
        }
    }
}
struct Pending {
    state: Weak<RefCell<State>>,
    path: String,
    owner: String,
    call: Call,
}
unsafe fn apply(handle: &Rc<RefCell<State>>, state: &mut State, effects: Vec<Effect>) {
    for effect in effects {
        let is_start = matches!(&effect, Effect::Start { .. });
        match effect {
            Effect::CloseConnection => {
                if !state.closing {
                    state.closing = true;
                    state.calls.clear();
                    let _ = state.events.send(Event::CloseConnection);
                }
            }
            Effect::Error { path } => {
                let _ = state.events.send(Event::Error {
                    path,
                    message: "Bluetooth discovery failed.".into(),
                });
            }
            Effect::Start { path, epoch, token } | Effect::Stop { path, epoch, token } => {
                let operation = if is_start {
                    Operation::Start
                } else {
                    Operation::Stop
                };
                let Some(owner) = state.owner.clone() else {
                    continue;
                };
                let call = Call {
                    epoch,
                    token,
                    operation,
                };
                state.calls.insert(path.clone(), call.clone());
                let pending = Box::new(Pending {
                    state: Rc::downgrade(handle),
                    path: path.clone(),
                    owner: owner.clone(),
                    call,
                });
                gio::g_dbus_connection_call(
                    state.bus,
                    c(&owner).as_ptr(),
                    c(&path).as_ptr(),
                    c("org.bluez.Adapter1").as_ptr(),
                    c(if operation == Operation::Start {
                        "StartDiscovery"
                    } else {
                        "StopDiscovery"
                    })
                    .as_ptr(),
                    ptr::null_mut(),
                    ptr::null_mut(),
                    0,
                    3000,
                    ptr::null_mut(),
                    Some(completed),
                    Box::into_raw(pending).cast(),
                );
            }
        }
    }
    let _ = state.events.send(Event::State {
        owned: state.core.owned(),
    });
}
extern "C" fn completed(bus: Ptr, result: Ptr, data: Ptr) {
    unsafe {
        let pending = Box::from_raw(data.cast::<Pending>());
        let mut error = ptr::null_mut();
        let reply = Variant::from(gio::g_dbus_connection_call_finish(bus, result, &mut error));
        let failure = if error.is_null() {
            None
        } else {
            Some(gio::error(error))
        };
        let Some(handle) = pending.state.upgrade() else {
            return;
        };
        let mut state = handle.borrow_mut();
        if state.closing
            || state.owner.as_deref() != Some(&pending.owner)
            || state.calls.get(&pending.path) != Some(&pending.call)
        {
            return;
        }
        state.calls.remove(&pending.path);
        let ok = reply.is_some();
        if !ok {
            let _ = state.events.send(Event::Error {
                path: pending.path.clone(),
                message: failure.unwrap_or_else(|| "Bluetooth discovery failed.".into()),
            });
        }
        let effects = match (pending.call.operation, ok) {
            (Operation::Start, true) => {
                state
                    .core
                    .started(&pending.path, pending.call.epoch, pending.call.token, true)
            }
            // Even a failed or timed-out Start may have acquired a reference.
            (Operation::Start, false) => {
                state
                    .core
                    .start_uncertain(&pending.path, pending.call.epoch, pending.call.token)
            }
            (Operation::Stop, _) => {
                state
                    .core
                    .stopped(&pending.path, pending.call.epoch, pending.call.token, ok)
            }
        };
        apply(&handle, &mut state, effects);
    }
}
