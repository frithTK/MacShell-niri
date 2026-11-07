//! Direct connect/disconnect, with owner and operation scoped completions.
use super::{Event, State};
use macshell_bluetooth_core::pairing::valid_device;
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use std::cell::RefCell;
use std::ptr;
use std::rc::{Rc, Weak};

const DEVICE: &str = "org.bluez.Device1";
const PROPS: &str = "org.freedesktop.DBus.Properties";

#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    Preflight,
    Invoke,
    Verify,
}
pub(super) struct Operation {
    request: u64,
    sequence: u64,
    owner: String,
    generation: u64,
    path: String,
    connected: bool,
    deadline: u64,
    phase: Phase,
}
pub(super) fn begin(
    handle: &Rc<RefCell<State>>,
    state: &mut State,
    request: u64,
    path: &str,
    connected: bool,
    now_ms: u64,
) -> Result<(), &'static str> {
    if state.pair.is_some()
        || state.device.is_some()
        || state.power.is_some()
        || state.agent.has_pending()
    {
        return Err("Wait for the current Bluetooth operation or cancel it.");
    }
    if !valid_device(path) {
        return Err("Invalid Bluetooth device.");
    }
    let owner = state
        .owner
        .clone()
        .ok_or("Bluetooth service is unavailable.")?;
    let deadline = now_ms
        .checked_add(30_000)
        .ok_or("Invalid operation deadline.")?;
    let sequence = state
        .device_sequence
        .checked_add(1)
        .ok_or("Operation sequence exhausted.")?;
    state.device_sequence = sequence;
    state.device = Some(Operation {
        request,
        sequence,
        owner,
        generation: state.generation,
        path: path.into(),
        connected,
        deadline,
        phase: Phase::Preflight,
    });
    unsafe {
        issue(handle, state, Phase::Preflight);
    }
    Ok(())
}
fn complete(state: &mut State, success: bool, phase: &'static str, error: String) {
    let Some(op) = state.device.take() else {
        return;
    };
    state.emit(Event::DeviceResult {
        request: op.request,
        success,
        phase,
        error,
    });
    if !state.closing && state.owner.is_some() {
        let _ = state.snapshot.refresh();
    }
}
pub(super) fn cancel(state: &mut State, request: u64) {
    if state
        .device
        .as_ref()
        .is_some_and(|op| op.request == request)
    {
        complete(state, true, "canceled", String::new());
    }
}
pub(super) fn expire(state: &mut State, now_ms: u64) {
    if state.device.as_ref().is_some_and(|op| now_ms > op.deadline) {
        complete(
            state,
            false,
            "connected",
            "Bluetooth request timed out. Check the device and try again.".into(),
        );
    }
}
pub(super) fn abort(state: &mut State, error: &str) {
    if let Some(op) = state.device.take() {
        state.emit(Event::DeviceResult {
            request: op.request,
            success: false,
            phase: "connected",
            error: error.into(),
        });
    }
}

struct Pending {
    state: Weak<RefCell<State>>,
    sequence: u64,
    owner: String,
    generation: u64,
    phase: Phase,
}
unsafe fn issue(handle: &Rc<RefCell<State>>, state: &mut State, phase: Phase) {
    let Some(op) = state.device.as_mut() else {
        return;
    };
    op.phase = phase;
    let pending = Box::new(Pending {
        state: Rc::downgrade(handle),
        sequence: op.sequence,
        owner: op.owner.clone(),
        generation: op.generation,
        phase,
    });
    let (interface, method, params, timeout) = match phase {
        Phase::Preflight | Phase::Verify => {
            (PROPS, "GetAll", gio::tuple(&[gio::string(DEVICE)]), 5000)
        }
        Phase::Invoke => (
            DEVICE,
            if op.connected {
                "Connect"
            } else {
                "Disconnect"
            },
            ptr::null_mut(),
            state.device_timeout_ms,
        ),
    };
    gio::g_dbus_connection_call(
        state.bus,
        c(&op.owner).as_ptr(),
        c(&op.path).as_ptr(),
        c(interface).as_ptr(),
        c(method).as_ptr(),
        params,
        ptr::null_mut(),
        0,
        timeout,
        ptr::null_mut(),
        Some(done),
        Box::into_raw(pending).cast(),
    );
}
unsafe fn connected(reply: &Variant) -> Option<bool> {
    if reply.kind() != "(a{sv})" {
        return None;
    }
    reply.child(0)?.lookup("Connected")?.boolean()
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
        let Some(op) = state.device.as_ref() else {
            return;
        };
        if state.closing
            || state.generation != pending.generation
            || state.owner.as_deref() != Some(&pending.owner)
            || op.sequence != pending.sequence
            || op.phase != pending.phase
        {
            return;
        }
        let desired = op.connected;
        if reply.is_none() {
            let message = message.unwrap_or_else(|| "Bluetooth request failed.".into());
            let reached = if desired {
                "org.bluez.Error.AlreadyConnected"
            } else {
                "org.bluez.Error.NotConnected"
            };
            if pending.phase == Phase::Invoke && (!remote || message.contains(reached)) {
                issue(&handle, &mut state, Phase::Verify);
            } else {
                complete(&mut state, false, "connected", message);
            }
            return;
        }
        let reply = reply.unwrap();
        match pending.phase {
            Phase::Preflight => {
                if connected(&reply).is_none() {
                    complete(
                        &mut state,
                        false,
                        "connected",
                        "Invalid Bluetooth device state.".into(),
                    );
                } else {
                    issue(&handle, &mut state, Phase::Invoke);
                }
            }
            Phase::Invoke => issue(&handle, &mut state, Phase::Verify),
            Phase::Verify => match connected(&reply) {
                Some(actual) if actual == desired => {
                    complete(&mut state, true, "connected", String::new())
                }
                Some(_) => complete(
                    &mut state,
                    false,
                    "connected",
                    "The device did not confirm the requested connection state.".into(),
                ),
                None => complete(
                    &mut state,
                    false,
                    "connected",
                    "Invalid Bluetooth device state.".into(),
                ),
            },
        }
    }
}
