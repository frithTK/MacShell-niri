//! Stop owned discovery and change all observed adapter power states.
use super::{Event, State};
use macshell_bluetooth_core::discovery::valid_adapter;
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::ptr;
use std::rc::{Rc, Weak};

const ADAPTER: &str = "org.bluez.Adapter1";
const PROPS: &str = "org.freedesktop.DBus.Properties";
#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    Inventory,
    Waiting,
    Preflight,
    ReadySet,
    Set,
    Verify,
    Done,
}
pub(super) struct Operation {
    request: u64,
    sequence: u64,
    owner: String,
    generation: u64,
    deadline: u64,
    desired: bool,
    adapters: BTreeMap<String, Phase>,
    started: bool,
    inventory_pending: bool,
}
pub(super) fn begin(
    handle: &Rc<RefCell<State>>,
    state: &mut State,
    request: u64,
    desired: bool,
    now_ms: u64,
) -> Result<(), &'static str> {
    if state.power.is_some()
        || state.pair.is_some()
        || state.device.is_some()
        || state.agent.has_pending()
    {
        return Err("Wait for the current Bluetooth operation or cancel it.");
    }
    let owner = state
        .owner
        .clone()
        .ok_or("Bluetooth service is unavailable.")?;
    let deadline = now_ms
        .checked_add(20_000)
        .ok_or("Invalid operation deadline.")?;
    let sequence = state
        .power_sequence
        .checked_add(1)
        .ok_or("Operation sequence exhausted.")?;
    state.power_sequence = sequence;
    state.power = Some(Operation {
        request,
        sequence,
        owner,
        generation: state.generation,
        deadline,
        desired,
        adapters: BTreeMap::new(),
        started: false,
        inventory_pending: false,
    });
    state.discovery.stop();
    state.drain();
    drive(handle, state);
    Ok(())
}
pub(super) fn drive(handle: &Rc<RefCell<State>>, state: &mut State) {
    if state.closing || !state.discovery.is_idle() {
        return;
    }
    let Some(op) = state.power.as_mut() else {
        return;
    };
    if op.started {
        return;
    }
    op.started = true;
    op.inventory_pending = true;
    let pending = Box::new(Pending {
        state: Rc::downgrade(handle),
        sequence: op.sequence,
        owner: op.owner.clone(),
        generation: op.generation,
        path: String::new(),
        phase: Phase::Inventory,
    });
    unsafe {
        gio::g_dbus_connection_call(
            state.bus,
            c(&op.owner).as_ptr(),
            c("/").as_ptr(),
            c("org.freedesktop.DBus.ObjectManager").as_ptr(),
            c("GetManagedObjects").as_ptr(),
            ptr::null_mut(),
            ptr::null_mut(),
            0,
            5000,
            ptr::null_mut(),
            Some(done),
            Box::into_raw(pending).cast(),
        );
    }
}
fn has_set(op: &Operation) -> bool {
    op.adapters.values().any(|phase| *phase == Phase::Set)
}
fn complete(state: &mut State, success: bool, phase: &'static str, error: String, close: bool) {
    let Some(op) = state.power.take() else { return };
    state.emit(Event::PowerResult {
        request: op.request,
        success,
        phase,
        error,
    });
    if close {
        state.close_needed();
    } else if !state.closing && state.owner.is_some() {
        let _ = state.snapshot.refresh();
    }
}
pub(super) fn cancel(state: &mut State, request: u64) {
    let Some(op) = state.power.as_ref().filter(|op| op.request == request) else {
        return;
    };
    let close = has_set(op);
    complete(state, true, "canceled", String::new(), close);
}
pub(super) fn expire(state: &mut State, now_ms: u64) {
    let Some(op) = state.power.as_ref().filter(|op| now_ms > op.deadline) else {
        return;
    };
    let close = has_set(op);
    complete(
        state,
        false,
        "connected",
        "Bluetooth request timed out. Check the adapter and try again.".into(),
        close,
    );
}
/// The return value requires closing the connection before using a new owner.
pub(super) fn abort(state: &mut State, error: &str) -> bool {
    let Some(op) = state.power.take() else {
        return false;
    };
    let close = has_set(&op);
    state.emit(Event::PowerResult {
        request: op.request,
        success: false,
        phase: "connected",
        error: error.into(),
    });
    close
}

struct Pending {
    state: Weak<RefCell<State>>,
    sequence: u64,
    owner: String,
    generation: u64,
    path: String,
    phase: Phase,
}
unsafe fn issue(handle: &Rc<RefCell<State>>, state: &mut State, path: &str, phase: Phase) {
    let Some(op) = state.power.as_mut() else {
        return;
    };
    let Some(slot) = op.adapters.get_mut(path) else {
        return;
    };
    *slot = phase;
    let pending = Box::new(Pending {
        state: Rc::downgrade(handle),
        sequence: op.sequence,
        owner: op.owner.clone(),
        generation: op.generation,
        path: path.into(),
        phase,
    });
    let (method, params) = match phase {
        Phase::Preflight | Phase::Verify => ("GetAll", gio::tuple(&[gio::string(ADAPTER)])),
        Phase::Set => (
            "Set",
            gio::tuple(&[
                gio::string(ADAPTER),
                gio::string("Powered"),
                gio::g_variant_new_variant(gio::g_variant_new_boolean(i32::from(op.desired))),
            ]),
        ),
        _ => return,
    };
    gio::g_dbus_connection_call(
        state.bus,
        c(&op.owner).as_ptr(),
        c(path).as_ptr(),
        c(PROPS).as_ptr(),
        c(method).as_ptr(),
        params,
        ptr::null_mut(),
        0,
        5000,
        ptr::null_mut(),
        Some(done),
        Box::into_raw(pending).cast(),
    );
}
unsafe fn powered(reply: &Variant) -> Option<bool> {
    if reply.kind() != "(a{sv})" {
        return None;
    }
    reply.child(0)?.lookup("Powered")?.boolean()
}
extern "C" fn done(bus: Ptr, result: Ptr, data: Ptr) {
    unsafe {
        let pending = Box::from_raw(data.cast::<Pending>());
        let mut error = ptr::null_mut();
        let reply = Variant::from(gio::g_dbus_connection_call_finish(bus, result, &mut error));
        let remote = !error.is_null() && gio::g_dbus_error_is_remote_error(error) != 0;
        let message = if error.is_null() {
            None
        } else {
            Some(gio::error(error))
        };
        let Some(handle) = pending.state.upgrade() else {
            return;
        };
        let mut state = handle.borrow_mut();
        state.drain();
        let Some(op) = state.power.as_ref() else {
            return;
        };
        if state.closing
            || state.generation != pending.generation
            || state.owner.as_deref() != Some(&pending.owner)
            || op.sequence != pending.sequence
            || (pending.phase == Phase::Inventory && !op.inventory_pending)
            || (pending.phase != Phase::Inventory
                && op.adapters.get(&pending.path) != Some(&pending.phase))
        {
            return;
        }
        let desired = op.desired;
        let other_set = op
            .adapters
            .iter()
            .any(|(path, phase)| path != &pending.path && *phase == Phase::Set);
        if reply.is_none() {
            let close = other_set || (pending.phase == Phase::Set && !remote);
            complete(
                &mut state,
                false,
                "connected",
                message.unwrap_or_else(|| "Bluetooth power request failed.".into()),
                close,
            );
            return;
        }
        let reply = reply.unwrap();
        match pending.phase {
            Phase::Inventory => {
                let Some(paths) = macshell_bluez_snapshot::parse(&reply)
                    .ok()
                    .and_then(|snapshot| snapshot["adapters"].as_array().cloned())
                    .and_then(|adapters| {
                        adapters
                            .iter()
                            .map(|adapter| {
                                adapter["path"]
                                    .as_str()
                                    .filter(|path| valid_adapter(path))
                                    .map(str::to_owned)
                            })
                            .collect::<Option<Vec<_>>>()
                    })
                else {
                    complete(
                        &mut state,
                        false,
                        "connected",
                        "Invalid Bluetooth adapter state.".into(),
                        false,
                    );
                    return;
                };
                let op = state.power.as_mut().unwrap();
                op.inventory_pending = false;
                op.adapters = paths
                    .into_iter()
                    .map(|path| (path, Phase::Waiting))
                    .collect();
                let paths: Vec<_> = op.adapters.keys().cloned().collect();
                if paths.is_empty() {
                    complete(&mut state, true, "connected", String::new(), false);
                    return;
                }
                for path in paths {
                    issue(&handle, &mut state, &path, Phase::Preflight);
                }
            }
            Phase::Preflight | Phase::Verify => match powered(&reply) {
                None => complete(
                    &mut state,
                    false,
                    "connected",
                    "Invalid Bluetooth adapter state.".into(),
                    other_set,
                ),
                Some(actual) if actual != desired && pending.phase == Phase::Verify => complete(
                    &mut state,
                    false,
                    "connected",
                    "The adapter did not confirm its power state.".into(),
                    other_set,
                ),
                Some(actual) => {
                    let op = state.power.as_mut().unwrap();
                    let next = if pending.phase == Phase::Preflight && actual != desired {
                        Phase::ReadySet
                    } else {
                        Phase::Done
                    };
                    op.adapters.insert(pending.path.clone(), next);
                    if pending.phase == Phase::Preflight
                        && op
                            .adapters
                            .values()
                            .all(|phase| matches!(phase, Phase::Done | Phase::ReadySet))
                    {
                        let paths: Vec<_> = op
                            .adapters
                            .iter()
                            .filter(|(_, phase)| **phase == Phase::ReadySet)
                            .map(|(path, _)| path.clone())
                            .collect();
                        // A user-requested enable must first clear a software
                        // radio block, even if BlueZ still reports Powered.
                        if desired {
                            if let Some(unblock) = state.radio_unblock.as_mut() {
                                if let Err(error) = unblock() {
                                    complete(&mut state, false, "connected", error, false);
                                    return;
                                }
                            }
                        }
                        if paths.is_empty() {
                            complete(&mut state, true, "connected", String::new(), false);
                        } else {
                            for path in paths {
                                issue(&handle, &mut state, &path, Phase::Set);
                            }
                        }
                    } else if pending.phase == Phase::Verify
                        && op.adapters.values().all(|phase| *phase == Phase::Done)
                    {
                        complete(&mut state, true, "connected", String::new(), false);
                    }
                }
            },
            Phase::Set => issue(&handle, &mut state, &pending.path, Phase::Verify),
            _ => (),
        }
    }
}
