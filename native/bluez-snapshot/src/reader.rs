//! Asynchronous, owner-scoped ObjectManager reads.
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use serde_json::Value;
use std::cell::RefCell;
use std::ptr;
use std::rc::{Rc, Weak};
use std::sync::mpsc::Sender;

#[derive(Debug, PartialEq)]
pub enum Event {
    Snapshot { epoch: u64, state: Value },
    Error { epoch: u64, message: String },
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refresh {
    Started,
    Coalesced,
}
struct State {
    bus: Ptr,
    owner: Option<String>,
    epoch: u64,
    sequence: u64,
    inflight: Option<u64>,
    dirty: bool,
    events: Sender<Event>,
}

/// Gio operations and access must remain on the owning GLib main context.
pub struct SnapshotReader {
    state: Rc<RefCell<State>>,
}
impl SnapshotReader {
    /// # Safety
    /// `bus` must be a live Gio connection and remain alive until this reader
    /// is dropped. All use must occur on its owning GLib main-context thread.
    pub unsafe fn new(bus: Ptr, events: Sender<Event>) -> Result<Self, &'static str> {
        if bus.is_null() {
            return Err("Missing D-Bus connection.");
        }
        Ok(Self {
            state: Rc::new(RefCell::new(State {
                bus,
                owner: None,
                epoch: 0,
                sequence: 0,
                inflight: None,
                dirty: false,
                events,
            })),
        })
    }
    /// Feed every owner loss/replacement from the bus watcher on the same
    /// context. Only a bus-provided unique name may be used as the owner.
    pub fn owner_changed(&self, owner: Option<&str>) -> Result<u64, &'static str> {
        if owner.is_some_and(|v| {
            v.contains('\0')
                || v.len() > 255
                || unsafe { gio::g_dbus_is_unique_name(c(v).as_ptr()) == 0 }
        }) {
            return Err("Invalid unique D-Bus owner.");
        }
        let mut state = self.state.borrow_mut();
        let epoch = state
            .epoch
            .checked_add(1)
            .ok_or("Owner sequence exhausted.")?;
        state.epoch = epoch;
        state.owner = owner.map(str::to_owned);
        state.inflight = None;
        state.dirty = false;
        Ok(epoch)
    }
    /// Coalesce repeated refreshes while a read is in flight into one follow-up.
    pub fn refresh(&self) -> Result<Refresh, &'static str> {
        let mut state = self.state.borrow_mut();
        if state.owner.is_none() {
            return Err("Bluetooth service is unavailable.");
        }
        if state.inflight.is_some() {
            state.dirty = true;
            return Ok(Refresh::Coalesced);
        }
        unsafe {
            start(&self.state, &mut state)?;
        }
        Ok(Refresh::Started)
    }
}

struct Pending {
    state: Weak<RefCell<State>>,
    owner: String,
    epoch: u64,
    sequence: u64,
}
unsafe fn start(handle: &Rc<RefCell<State>>, state: &mut State) -> Result<(), &'static str> {
    let owner = state
        .owner
        .clone()
        .ok_or("Bluetooth service is unavailable.")?;
    let sequence = state
        .sequence
        .checked_add(1)
        .ok_or("Snapshot sequence exhausted.")?;
    state.sequence = sequence;
    state.inflight = Some(sequence);
    let pending = Box::new(Pending {
        state: Rc::downgrade(handle),
        owner: owner.clone(),
        epoch: state.epoch,
        sequence,
    });
    gio::g_dbus_connection_call(
        state.bus,
        c(&owner).as_ptr(),
        c("/").as_ptr(),
        c("org.freedesktop.DBus.ObjectManager").as_ptr(),
        c("GetManagedObjects").as_ptr(),
        ptr::null_mut(),
        ptr::null_mut(),
        0,
        3000,
        ptr::null_mut(),
        Some(completed),
        Box::into_raw(pending).cast(),
    );
    Ok(())
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
        if state.epoch != pending.epoch
            || state.owner.as_deref() != Some(&pending.owner)
            || state.inflight != Some(pending.sequence)
        {
            return;
        }
        state.inflight = None;
        let event = match reply {
            Some(value) => match crate::parse(&value) {
                Ok(value) => Event::Snapshot {
                    epoch: pending.epoch,
                    state: value,
                },
                Err(message) => Event::Error {
                    epoch: pending.epoch,
                    message: message.into(),
                },
            },
            None => Event::Error {
                epoch: pending.epoch,
                message: failure.unwrap_or_else(|| "D-Bus request failed".into()),
            },
        };
        let _ = state.events.send(event);
        if state.dirty {
            state.dirty = false;
            if let Err(message) = start(&handle, &mut state) {
                let _ = state.events.send(Event::Error {
                    epoch: pending.epoch,
                    message: message.into(),
                });
            }
        }
    }
}
