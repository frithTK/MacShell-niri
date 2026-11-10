//! One owner watch coordinates the experimental BlueZ components.
use macshell_bluetooth_core::pairing::{Reply, Ticket};
use macshell_bluez_agent::{Agent, Event as AgentEvent, PATH};
use macshell_bluez_discovery::{Discovery, Event as DiscoveryEvent};
use macshell_bluez_snapshot::reader::{Event as SnapshotEvent, SnapshotReader};
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use serde_json::Value;
use std::cell::RefCell;
use std::ffi::c_char;
use std::ptr;
use std::rc::{Rc, Weak};
use std::sync::mpsc::{self, Receiver, Sender};

mod device;
mod pair;
mod power;

#[derive(Debug)]
pub enum Event {
    Owner {
        unique: Option<String>,
        generation: u64,
    },
    Registration {
        generation: u64,
        success: bool,
    },
    Snapshot {
        generation: u64,
        state: Value,
    },
    Discovery {
        owned: usize,
    },
    Agent(AgentEvent),
    PairResult {
        request: u64,
        success: bool,
        phase: &'static str,
        error: String,
    },
    DeviceResult {
        request: u64,
        success: bool,
        phase: &'static str,
        error: String,
    },
    PowerResult {
        request: u64,
        success: bool,
        phase: &'static str,
        error: String,
    },
    Error(String),
    /// The caller must close this dedicated connection and discard the session.
    CloseConnection,
}
struct State {
    bus: Ptr,
    agent: Agent,
    snapshot: SnapshotReader,
    discovery: Discovery,
    agent_rx: Receiver<AgentEvent>,
    snapshot_rx: Receiver<SnapshotEvent>,
    discovery_rx: Receiver<DiscoveryEvent>,
    events: Sender<Event>,
    owner: Option<String>,
    generation: u64,
    snapshot_epoch: u64,
    adapters: Option<Vec<(String, bool)>>,
    closing: bool,
    pair: Option<pair::Operation>,
    pair_timeout_ms: i32,
    device: Option<device::Operation>,
    device_sequence: u64,
    device_timeout_ms: i32,
    power: Option<power::Operation>,
    power_sequence: u64,
    radio_unblock: Option<Box<dyn FnMut() -> Result<(), String>>>,
}
impl State {
    fn mark_closing(&mut self) -> bool {
        if !self.closing {
            pair::abort(self, "Bluetooth connection was closed.", true);
            device::abort(self, "Bluetooth connection was closed.");
            power::abort(self, "Bluetooth connection was closed.");
            self.closing = true;
            self.owner = None;
            self.adapters = None;
            self.agent.owner_changed(None);
            let _ = self.snapshot.owner_changed(None);
            return true;
        }
        false
    }
    fn close_needed(&mut self) {
        if self.mark_closing() {
            self.emit(Event::CloseConnection);
        }
    }
    fn emit(&self, event: Event) {
        let _ = self.events.send(event);
    }
    /// Drain previous-owner messages before accepting the new owner's state.
    fn discard_stale(&mut self) {
        while let Ok(event) = self.agent_rx.try_recv() {
            pair::agent_event(self, &event);
            if matches!(
                event,
                AgentEvent::PairCanceled { .. } | AgentEvent::OwnerReset(_)
            ) {
                self.emit(Event::Agent(event));
            }
        }
        while self.snapshot_rx.try_recv().is_ok() {}
        while let Ok(event) = self.discovery_rx.try_recv() {
            if matches!(event, DiscoveryEvent::CloseConnection) {
                self.close_needed();
            }
        }
    }
    fn drain(&mut self) {
        let discovery: Vec<_> = self.discovery_rx.try_iter().collect();
        let close = discovery
            .iter()
            .any(|event| matches!(event, DiscoveryEvent::CloseConnection))
            && self.mark_closing();
        while let Ok(event) = self.agent_rx.try_recv() {
            pair::agent_event(self, &event);
            if !self.closing
                || matches!(
                    event,
                    AgentEvent::Cleared
                        | AgentEvent::PairCanceled { .. }
                        | AgentEvent::OwnerReset(_)
                )
            {
                self.emit(Event::Agent(event));
            }
        }
        while let Ok(event) = self.snapshot_rx.try_recv() {
            match event {
                SnapshotEvent::Snapshot { epoch, state }
                    if epoch == self.snapshot_epoch && !self.closing =>
                {
                    let adapters = state["adapters"].as_array().map(|values| {
                        values
                            .iter()
                            .filter_map(|a| {
                                Some((a["path"].as_str()?.to_owned(), a["enabled"].as_bool()?))
                            })
                            .collect()
                    });
                    self.adapters = adapters;
                    self.emit(Event::Snapshot {
                        generation: self.generation,
                        state,
                    });
                }
                SnapshotEvent::Error { epoch, message }
                    if epoch == self.snapshot_epoch && !self.closing =>
                {
                    self.emit(Event::Error(message))
                }
                _ => (),
            }
        }
        for event in discovery {
            match event {
                DiscoveryEvent::State { owned } if !self.closing => {
                    self.emit(Event::Discovery { owned })
                }
                DiscoveryEvent::Error { message, .. } if !self.closing => {
                    self.emit(Event::Error(message))
                }
                DiscoveryEvent::CloseConnection => (),
                _ => (),
            }
        }
        if close {
            self.emit(Event::CloseConnection);
        }
    }
    fn available(&mut self) -> Result<(), &'static str> {
        self.drain();
        if self.closing {
            return Err("Bluetooth connection must be closed.");
        }
        if self.owner.is_none() {
            return Err("Bluetooth service is unavailable.");
        }
        Ok(())
    }
}
/// This object exclusively owns use of a dedicated D-Bus connection.
pub struct Session {
    state: Rc<RefCell<State>>,
    watch: u32,
    subscriptions: Vec<u32>,
}
impl Session {
    /// # Safety
    /// `bus` must be a dedicated live Gio connection that remains alive until
    /// Session is dropped. It will be closed by Session on teardown. Construct,
    /// call and drop Session on the connection's GLib main-context thread.
    pub unsafe fn new(bus: Ptr, events: Sender<Event>) -> Result<Self, String> {
        Self::new_with_pair_timeout(bus, events, 60_000)
    }
    /// As `new`, with an explicit bounded Pair timeout in milliseconds.
    ///
    /// # Safety
    /// The same dedicated connection and GLib context contract as `new` applies.
    pub unsafe fn new_with_pair_timeout(
        bus: Ptr,
        events: Sender<Event>,
        pair_timeout_ms: i32,
    ) -> Result<Self, String> {
        Self::new_with_timeouts(bus, events, pair_timeout_ms, 20_000)
    }
    /// As `new`, with bounded Pair and device-operation timeouts in milliseconds.
    ///
    /// # Safety
    /// The same dedicated connection and GLib context contract as `new` applies.
    pub unsafe fn new_with_timeouts(
        bus: Ptr,
        events: Sender<Event>,
        pair_timeout_ms: i32,
        device_timeout_ms: i32,
    ) -> Result<Self, String> {
        if bus.is_null() {
            return Err("Missing D-Bus connection.".into());
        }
        if !(1..=60_000).contains(&pair_timeout_ms) {
            return Err("Invalid pairing timeout.".into());
        }
        if !(1..=20_000).contains(&device_timeout_ms) {
            return Err("Invalid device timeout.".into());
        }
        // Shared bus connections default to terminating the process on close.
        // This session deliberately closes its dedicated connection on reset.
        gio::g_dbus_connection_set_exit_on_close(bus, 0);
        let (agent_tx, agent_rx) = mpsc::channel();
        let (snapshot_tx, snapshot_rx) = mpsc::channel();
        let (discovery_tx, discovery_rx) = mpsc::channel();
        let agent = Agent::new(bus, agent_tx)?;
        let snapshot = SnapshotReader::new(bus, snapshot_tx).map_err(str::to_owned)?;
        let discovery = Discovery::new(bus, discovery_tx).map_err(str::to_owned)?;
        let state = Rc::new(RefCell::new(State {
            bus,
            agent,
            snapshot,
            discovery,
            agent_rx,
            snapshot_rx,
            discovery_rx,
            events,
            owner: None,
            generation: 0,
            snapshot_epoch: 0,
            adapters: None,
            closing: false,
            pair: None,
            pair_timeout_ms,
            device: None,
            device_sequence: 0,
            device_timeout_ms,
            power: None,
            power_sequence: 0,
            radio_unblock: None,
        }));
        let watch_data = Box::into_raw(Box::new(Rc::downgrade(&state))).cast();
        let watch = gio::g_bus_watch_name_on_connection(
            bus,
            c("org.bluez").as_ptr(),
            0,
            Some(appeared),
            Some(vanished),
            watch_data,
            drop_weak as *const () as Ptr,
        );
        if watch == 0 {
            drop(Box::from_raw(watch_data.cast::<Weak<RefCell<State>>>()));
            return Err("Could not watch Bluetooth service.".into());
        }
        let mut subscriptions = Vec::new();
        for (interface, signal, path) in [
            (
                "org.freedesktop.DBus.Properties",
                Some("PropertiesChanged"),
                None,
            ),
            ("org.freedesktop.DBus.ObjectManager", None, Some("/")),
        ] {
            let data = Box::into_raw(Box::new(Rc::downgrade(&state))).cast();
            let iface = c(interface);
            let member = signal.map(c);
            let object = path.map(c);
            let id = gio::g_dbus_connection_signal_subscribe(
                bus,
                ptr::null(),
                iface.as_ptr(),
                member.as_ref().map_or(ptr::null(), |s| s.as_ptr()),
                object.as_ref().map_or(ptr::null(), |s| s.as_ptr()),
                ptr::null(),
                0,
                Some(changed),
                data,
                drop_weak as *const () as Ptr,
            );
            if id != 0 {
                subscriptions.push(id);
            } else {
                drop(Box::from_raw(data.cast::<Weak<RefCell<State>>>()));
                for previous in &subscriptions {
                    gio::g_dbus_connection_signal_unsubscribe(bus, *previous);
                }
                gio::g_bus_unwatch_name(watch);
                return Err("Could not subscribe to Bluetooth changes.".into());
            }
        }
        Ok(Self {
            state,
            watch,
            subscriptions,
        })
    }
    /// Drain component events on the main context, including close requests.
    pub fn poll(&self) {
        let mut state = self.state.borrow_mut();
        state.drain();
        power::drive(&self.state, &mut state);
    }
    pub fn refresh(&self) -> Result<(), &'static str> {
        let mut state = self.state.borrow_mut();
        state.available()?;
        state.snapshot.refresh()?;
        Ok(())
    }
    pub fn discover(&self, now_ms: u64) -> Result<(), &'static str> {
        let mut state = self.state.borrow_mut();
        state.available()?;
        if state.power.is_some()
            || state.pair.is_some()
            || state.device.is_some()
            || state.agent.has_pending()
        {
            return Err("Wait for the current Bluetooth operation or cancel it.");
        }
        let adapters = state
            .adapters
            .clone()
            .ok_or("Bluetooth state is not available yet.")?;
        state.discovery.start(now_ms, &adapters)?;
        state.drain();
        Ok(())
    }
    pub fn hold_discovery(&self) -> Result<(), &'static str> {
        let mut state = self.state.borrow_mut();
        state.available()?;
        if state.power.is_some()
            || state.pair.is_some()
            || state.device.is_some()
            || state.agent.has_pending()
        {
            return Ok(());
        }
        let Some(adapters) = state.adapters.clone() else {
            return Ok(());
        };
        state.discovery.hold(&adapters)?;
        state.drain();
        Ok(())
    }
    pub fn release_hold(&self) {
        let mut state = self.state.borrow_mut();
        state.drain();
        if !state.closing {
            state.discovery.release_hold();
            state.drain();
        }
    }
    pub fn stop_discovery(&self) {
        let mut state = self.state.borrow_mut();
        state.drain();
        if !state.closing {
            state.discovery.stop();
            state.drain();
        }
    }
    pub fn tick(&self, now_ms: u64) {
        let mut state = self.state.borrow_mut();
        state.drain();
        if !state.closing {
            state.discovery.tick(now_ms);
            device::expire(&mut state, now_ms);
            power::expire(&mut state, now_ms);
            let expired = state.agent.expired(now_ms).is_some();
            state.drain();
            power::drive(&self.state, &mut state);
            if expired {
                state.emit(Event::Error(
                    "Bluetooth request timed out. Check the device and try again.".into(),
                ));
            }
        }
    }
    /// Pair, verify Paired/Bonded, enable and verify Trusted, then connect.
    pub fn pair(
        &self,
        request: u64,
        device: &str,
        name: &str,
        now_ms: u64,
    ) -> Result<(), &'static str> {
        let mut state = self.state.borrow_mut();
        state.available()?;
        pair::begin(&self.state, &mut state, request, device, name, now_ms)
    }
    pub fn cancel_pair(&self, request: u64) {
        let mut state = self.state.borrow_mut();
        state.drain();
        if !state.closing {
            state.agent.cancel(request);
            device::cancel(&mut state, request);
            power::cancel(&mut state, request);
            state.drain();
        }
    }
    /// Connect or disconnect a device, then confirm the resulting state.
    pub fn set_connected(
        &self,
        request: u64,
        path: &str,
        connected: bool,
        now_ms: u64,
    ) -> Result<(), &'static str> {
        let mut state = self.state.borrow_mut();
        state.available()?;
        device::begin(&self.state, &mut state, request, path, connected, now_ms)
    }
    /// Stop owned discovery and set/verify power on all observed adapters.
    pub fn set_power(&self, request: u64, enabled: bool, now_ms: u64) -> Result<(), &'static str> {
        let mut state = self.state.borrow_mut();
        state.available()?;
        power::begin(&self.state, &mut state, request, enabled, now_ms)
    }
    /// Install a Bluetooth-only radio unblocker. The caller owns its policy and
    /// must only configure it for the real system bus, never a test bus.
    pub fn set_radio_unblocker(&self, unblock: Box<dyn FnMut() -> Result<(), String>>) {
        self.state.borrow_mut().radio_unblock = Some(unblock);
    }
    /// Starts authorization only; the caller must also perform Device1.Pair.
    pub fn begin_authorization(
        &self,
        request: u64,
        device: &str,
        name: &str,
        now_ms: u64,
    ) -> Result<Ticket, &'static str> {
        let mut state = self.state.borrow_mut();
        state.available()?;
        if state.device.is_some() || state.power.is_some() {
            return Err("Wait for the current Bluetooth operation or cancel it.");
        }
        state.agent.begin(request, device, name, now_ms)
    }
    pub fn respond(&self, prompt: u64, accept: bool, value: &str) -> Result<Reply, &'static str> {
        let mut state = self.state.borrow_mut();
        state.available()?;
        let result = state.agent.respond(prompt, accept, value);
        state.drain();
        result
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        unsafe {
            gio::g_bus_unwatch_name(self.watch);
            let mut state = self.state.borrow_mut();
            for id in &self.subscriptions {
                gio::g_dbus_connection_signal_unsubscribe(state.bus, *id);
            }
            pair::abort(&mut state, "Bluetooth connection was closed.", true);
            device::abort(&mut state, "Bluetooth connection was closed.");
            power::abort(&mut state, "Bluetooth connection was closed.");
            state.agent.owner_changed(None);
            let mut error = ptr::null_mut();
            gio::g_dbus_connection_flush_sync(state.bus, ptr::null_mut(), &mut error);
            if !error.is_null() {
                let _ = gio::error(error);
            }
            let mut error = ptr::null_mut();
            gio::g_dbus_connection_close_sync(state.bus, ptr::null_mut(), &mut error);
            if !error.is_null() {
                let _ = gio::error(error);
            }
        }
    }
}
extern "C" fn drop_weak(data: Ptr) {
    unsafe {
        drop(Box::from_raw(data.cast::<Weak<RefCell<State>>>()));
    }
}
struct Registration {
    state: Weak<RefCell<State>>,
    owner: String,
    generation: u64,
    epoch: u64,
}
unsafe fn owner_changed(handle: &Rc<RefCell<State>>, owner: Option<String>) {
    let mut state = handle.borrow_mut();
    state.discard_stale();
    if state.closing {
        return;
    }
    pair::abort(&mut state, "Bluetooth restarted or disappeared.", false);
    device::abort(&mut state, "Bluetooth restarted or disappeared.");
    if power::abort(&mut state, "Bluetooth restarted or disappeared.") {
        state.close_needed();
        return;
    }
    let Some(generation) = state.generation.checked_add(1) else {
        state.close_needed();
        return;
    };
    state.generation = generation;
    state.owner = owner.clone();
    state.adapters = None;
    state.agent.owner_changed(owner.as_deref());
    let Ok(epoch) = state.snapshot.owner_changed(owner.as_deref()) else {
        state.close_needed();
        return;
    };
    state.snapshot_epoch = epoch;
    if state.discovery.owner_changed(owner.as_deref()).is_err() {
        state.close_needed();
        return;
    }
    state.emit(Event::Owner {
        unique: owner.clone(),
        generation,
    });
    state.drain();
    if state.closing {
        return;
    }
    if let Some(owner) = owner {
        if let Err(error) = state.snapshot.refresh() {
            state.emit(Event::Error(error.into()));
        }
        let pending = Box::new(Registration {
            state: Rc::downgrade(handle),
            owner: owner.clone(),
            generation,
            epoch: state.agent.epoch(),
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
extern "C" fn appeared(_: Ptr, _: *const c_char, owner: *const c_char, data: Ptr) {
    unsafe {
        if let Some(state) = (&*data.cast::<Weak<RefCell<State>>>()).upgrade() {
            owner_changed(&state, Some(gio::text(owner)));
        }
    }
}
extern "C" fn vanished(_: Ptr, _: *const c_char, data: Ptr) {
    unsafe {
        if let Some(state) = (&*data.cast::<Weak<RefCell<State>>>()).upgrade() {
            owner_changed(&state, None);
        }
    }
}
extern "C" fn registered(bus: Ptr, result: Ptr, data: Ptr) {
    unsafe {
        let pending = Box::from_raw(data.cast::<Registration>());
        let mut error = ptr::null_mut();
        let reply = Variant::from(gio::g_dbus_connection_call_finish(bus, result, &mut error));
        if !error.is_null() {
            let _ = gio::error(error);
        }
        let Some(handle) = pending.state.upgrade() else {
            return;
        };
        let mut state = handle.borrow_mut();
        state.drain();
        if state.closing
            || state.generation != pending.generation
            || state.owner.as_deref() != Some(&pending.owner)
        {
            return;
        }
        let success = reply.is_some();
        if state.agent.registered(pending.epoch, success) {
            state.emit(Event::Registration {
                generation: pending.generation,
                success,
            });
        }
    }
}
extern "C" fn changed(
    _: Ptr,
    sender: *const c_char,
    path: *const c_char,
    interface: *const c_char,
    signal: *const c_char,
    _: Ptr,
    data: Ptr,
) {
    unsafe {
        let Some(handle) = (&*data.cast::<Weak<RefCell<State>>>()).upgrade() else {
            return;
        };
        let mut state = handle.borrow_mut();
        state.drain();
        let sender = gio::text(sender);
        let path = gio::text(path);
        let interface = gio::text(interface);
        let signal = gio::text(signal);
        if state.closing || state.owner.as_deref() != Some(sender.as_str()) {
            return;
        }
        let relevant = (interface == "org.freedesktop.DBus.Properties"
            && signal == "PropertiesChanged"
            && path.starts_with("/org/bluez/"))
            || (interface == "org.freedesktop.DBus.ObjectManager"
                && path == "/"
                && (signal == "InterfacesAdded" || signal == "InterfacesRemoved"));
        if relevant {
            if let Err(error) = state.snapshot.refresh() {
                state.emit(Event::Error(error.into()));
            }
        }
    }
}
