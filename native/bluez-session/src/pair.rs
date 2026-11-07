//! Pairing transport. Every callback is bound to one owner and operation ticket.
use super::{Event, State};
use macshell_bluetooth_core::pairing::{Step, Ticket};
use macshell_bluez_agent::Event as AgentEvent;
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use std::cell::RefCell;
use std::ptr;
use std::rc::{Rc, Weak};

const DEVICE: &str = "org.bluez.Device1";
const PROPS: &str = "org.freedesktop.DBus.Properties";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Preflight,
    Pair,
    VerifyPair,
    SetTrust,
    VerifyTrust,
    Connect,
    VerifyConnect,
}
pub(super) struct Operation {
    ticket: Ticket,
    owner: String,
    generation: u64,
    path: String,
    phase: Phase,
}

pub(super) fn begin(
    handle: &Rc<RefCell<State>>,
    state: &mut State,
    request: u64,
    device: &str,
    name: &str,
    now_ms: u64,
) -> Result<(), &'static str> {
    if state.pair.is_some() || state.device.is_some() || state.power.is_some() {
        return Err("Wait for the current Bluetooth operation or cancel it.");
    }
    let owner = state
        .owner
        .clone()
        .ok_or("Bluetooth service is unavailable.")?;
    let ticket = state.agent.begin(request, device, name, now_ms)?;
    state.pair = Some(Operation {
        ticket,
        owner,
        generation: state.generation,
        path: device.into(),
        phase: Phase::Preflight,
    });
    unsafe {
        issue(handle, state, Phase::Preflight);
    }
    Ok(())
}

/// Complete a user rejection, explicit cancel, or timeout exactly once.
pub(super) fn agent_event(state: &mut State, event: &AgentEvent) {
    let AgentEvent::PairCanceled { request, .. } = event else {
        return;
    };
    if state
        .pair
        .as_ref()
        .is_none_or(|op| op.ticket.request != *request)
    {
        return;
    }
    let op = state.pair.take().unwrap();
    unsafe {
        cancel_inflight(state, &op);
    }
    state.emit(Event::PairResult {
        request: *request,
        success: true,
        phase: "canceled",
        error: String::new(),
    });
    refresh(state);
}

/// Fail an active operation when the owner or its connection goes away.
pub(super) fn abort(state: &mut State, message: &str, cancel: bool) {
    let Some(op) = state.pair.take() else { return };
    if cancel {
        unsafe {
            cancel_inflight(state, &op);
        }
    }
    state.agent.cancel(op.ticket.request);
    state.emit(Event::PairResult {
        request: op.ticket.request,
        success: false,
        phase: "connected",
        error: message.into(),
    });
}

unsafe fn cancel_inflight(state: &State, op: &Operation) {
    if op.phase != Phase::Pair || state.owner.as_deref() != Some(op.owner.as_str()) {
        return;
    }
    gio::g_dbus_connection_call(
        state.bus,
        c(&op.owner).as_ptr(),
        c(&op.path).as_ptr(),
        c(DEVICE).as_ptr(),
        c("CancelPairing").as_ptr(),
        ptr::null_mut(),
        ptr::null_mut(),
        0,
        3000,
        ptr::null_mut(),
        None,
        ptr::null_mut(),
    );
}
fn refresh(state: &State) {
    if !state.closing && state.owner.is_some() {
        let _ = state.snapshot.refresh();
    }
}

struct Pending {
    state: Weak<RefCell<State>>,
    ticket: Ticket,
    owner: String,
    generation: u64,
    phase: Phase,
}
unsafe fn issue(handle: &Rc<RefCell<State>>, state: &mut State, phase: Phase) {
    let Some(op) = state.pair.as_mut() else {
        return;
    };
    op.phase = phase;
    let pending = Box::new(Pending {
        state: Rc::downgrade(handle),
        ticket: op.ticket,
        owner: op.owner.clone(),
        generation: op.generation,
        phase,
    });
    let (interface, method, params, timeout) = match phase {
        Phase::Preflight | Phase::VerifyPair | Phase::VerifyTrust | Phase::VerifyConnect => {
            (PROPS, "GetAll", gio::tuple(&[gio::string(DEVICE)]), 5000)
        }
        Phase::Pair => (DEVICE, "Pair", ptr::null_mut(), state.pair_timeout_ms),
        Phase::SetTrust => (
            PROPS,
            "Set",
            gio::tuple(&[
                gio::string(DEVICE),
                gio::string("Trusted"),
                gio::g_variant_new_variant(gio::g_variant_new_boolean(1)),
            ]),
            5000,
        ),
        Phase::Connect => (DEVICE, "Connect", ptr::null_mut(), 20000),
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

unsafe fn properties(reply: &Variant) -> Option<Variant> {
    if reply.kind() == "(a{sv})" {
        reply.child(0)
    } else {
        None
    }
}
unsafe fn flag(props: &Variant, name: &str) -> bool {
    props
        .lookup(name)
        .and_then(|value| value.boolean())
        .unwrap_or(false)
}
fn finish(state: &mut State, ticket: Ticket, success: bool, phase: &'static str, error: String) {
    if state.pair.as_ref().is_none_or(|op| op.ticket != ticket) {
        return;
    }
    state.pair = None;
    state.emit(Event::PairResult {
        request: ticket.request,
        success,
        phase,
        error,
    });
    refresh(state);
}
fn failure(state: &mut State, ticket: Ticket, phase: Phase, error: String) {
    match phase {
        Phase::Preflight | Phase::Pair | Phase::VerifyPair => {
            state.agent.paired(ticket, false);
            finish(state, ticket, false, "connected", error);
        }
        Phase::SetTrust | Phase::VerifyTrust => {
            if let Step::Finished { phase, error, .. } = state.agent.trusted(ticket, false) {
                finish(state, ticket, false, phase, error.into());
            }
        }
        Phase::Connect | Phase::VerifyConnect => {
            state.agent.connected(ticket, false);
            finish(state, ticket, false, "paired", error);
        }
    }
}
unsafe fn trust(handle: &Rc<RefCell<State>>, state: &mut State, ticket: Ticket) {
    if matches!(state.agent.paired(ticket, true), Step::Trust { .. }) {
        issue(handle, state, Phase::SetTrust);
    }
}
extern "C" fn done(bus: Ptr, result: Ptr, data: Ptr) {
    unsafe {
        let pending = Box::from_raw(data.cast::<Pending>());
        let mut error = ptr::null_mut();
        let reply = Variant::from(gio::g_dbus_connection_call_finish(bus, result, &mut error));
        let remote_error = !error.is_null() && gio::g_dbus_error_is_remote_error(error) != 0;
        let failure_message = if error.is_null() {
            None
        } else {
            Some(gio::error(error))
        };
        let Some(handle) = pending.state.upgrade() else {
            return;
        };
        let mut state = handle.borrow_mut();
        state.drain();
        if state.closing
            || state.generation != pending.generation
            || state.owner.as_deref() != Some(&pending.owner)
            || state
                .pair
                .as_ref()
                .is_none_or(|op| op.ticket != pending.ticket || op.phase != pending.phase)
        {
            return;
        }
        let ticket = pending.ticket;
        if reply.is_none() {
            let message = failure_message.unwrap_or_else(|| "Bluetooth request failed.".into());
            if pending.phase == Phase::Pair && !remote_error {
                if let Some(op) = state.pair.as_ref() {
                    cancel_inflight(&state, op);
                }
            }
            if pending.phase == Phase::Connect
                && message.contains("org.bluez.Error.AlreadyConnected")
            {
                issue(&handle, &mut state, Phase::VerifyConnect);
            } else {
                failure(&mut state, ticket, pending.phase, message);
            }
            return;
        }
        let reply = reply.unwrap();
        match pending.phase {
            Phase::Preflight | Phase::VerifyPair | Phase::VerifyTrust | Phase::VerifyConnect => {
                let Some(props) = properties(&reply) else {
                    failure(
                        &mut state,
                        ticket,
                        pending.phase,
                        "Invalid Bluetooth device state.".into(),
                    );
                    return;
                };
                match pending.phase {
                    Phase::Preflight if flag(&props, "Paired") || flag(&props, "Bonded") => {
                        trust(&handle, &mut state, ticket)
                    }
                    Phase::Preflight => issue(&handle, &mut state, Phase::Pair),
                    Phase::VerifyPair if flag(&props, "Paired") || flag(&props, "Bonded") => {
                        trust(&handle, &mut state, ticket)
                    }
                    Phase::VerifyPair => failure(
                        &mut state,
                        ticket,
                        pending.phase,
                        "The device did not confirm pairing.".into(),
                    ),
                    Phase::VerifyTrust if flag(&props, "Trusted") => {
                        if matches!(state.agent.trusted(ticket, true), Step::Connect { .. }) {
                            issue(&handle, &mut state, Phase::Connect);
                        }
                    }
                    Phase::VerifyTrust => failure(
                        &mut state,
                        ticket,
                        pending.phase,
                        "The device did not confirm trust.".into(),
                    ),
                    Phase::VerifyConnect => {
                        let connected = flag(&props, "Connected");
                        state.agent.connected(ticket, connected);
                        finish(
                            &mut state,
                            ticket,
                            connected,
                            if connected { "connected" } else { "paired" },
                            if connected {
                                String::new()
                            } else {
                                "The device did not confirm connection.".into()
                            },
                        );
                    }
                    _ => unreachable!(),
                }
            }
            Phase::Pair => issue(&handle, &mut state, Phase::VerifyPair),
            Phase::SetTrust => issue(&handle, &mut state, Phase::VerifyTrust),
            Phase::Connect => issue(&handle, &mut state, Phase::VerifyConnect),
        }
    }
}
