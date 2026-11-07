use gio::{c, Ptr, Variant};
use macshell_gio_bridge as gio;
use serde_json::{json, Value};
use std::io::{self, Write};
use std::ptr;

const CURRENT: (&str, &str) = (
    "org.freedesktop.UPower.PowerProfiles",
    "/org/freedesktop/UPower/PowerProfiles",
);
const LEGACY: (&str, &str) = ("net.hadess.PowerProfiles", "/net/hadess/PowerProfiles");
const DBUS: &str = "org.freedesktop.DBus";
const DBUS_PATH: &str = "/org/freedesktop/DBus";
const PROPS: &str = "org.freedesktop.DBus.Properties";

unsafe fn sync(
    bus: Ptr,
    name: &str,
    path: &str,
    interface: &str,
    method: &str,
    args: Ptr,
) -> Result<Variant, String> {
    let mut error = ptr::null_mut();
    let value = gio::g_dbus_connection_call_sync(
        bus,
        c(name).as_ptr(),
        c(path).as_ptr(),
        c(interface).as_ptr(),
        c(method).as_ptr(),
        args,
        ptr::null_mut(),
        0,
        2000,
        ptr::null_mut(),
        &mut error,
    );
    Variant::from(value).ok_or_else(|| gio::error(error))
}
unsafe fn owner_exists(bus: Ptr, name: &str) -> Result<bool, String> {
    let reply = sync(
        bus,
        DBUS,
        DBUS_PATH,
        DBUS,
        "NameHasOwner",
        gio::tuple(&[gio::string(name)]),
    )?;
    reply
        .child(0)
        .and_then(|v| v.boolean())
        .ok_or_else(|| "Invalid D-Bus reply".into())
}
unsafe fn endpoint(bus: Ptr) -> Result<(&'static str, &'static str), String> {
    for endpoint in [CURRENT, LEGACY] {
        if owner_exists(bus, endpoint.0)? {
            return Ok(endpoint);
        }
    }
    let reply = sync(
        bus,
        DBUS,
        DBUS_PATH,
        DBUS,
        "ListActivatableNames",
        ptr::null_mut(),
    )?;
    let names = reply
        .child(0)
        .ok_or_else(|| "Invalid D-Bus reply".to_owned())?;
    let mut legacy = false;
    let mut current = false;
    if names.kind() != "as" {
        return Err("Invalid D-Bus reply".into());
    }
    for i in 0..names.len() {
        if let Some(s) = names.child(i).and_then(|v| v.string()) {
            legacy |= s == LEGACY.0;
            current |= s == CURRENT.0;
        }
    }
    Ok(if legacy && !current { LEGACY } else { CURRENT })
}
fn friendly(message: &str) -> String {
    message
        .split_once(": ")
        .map_or(message, |(_, rest)| rest)
        .chars()
        .take(220)
        .collect()
}
fn truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(v) => *v,
        Value::Number(v) => v.as_f64().is_some_and(|v| v != 0.0),
        Value::String(v) => !v.is_empty(),
        Value::Array(v) => !v.is_empty(),
        Value::Object(v) => !v.is_empty(),
    }
}

struct State {
    bus: Ptr,
    loop_: Ptr,
    name: &'static str,
    path: &'static str,
    owner: String,
    owner_epoch: u64,
    generation: Option<Value>,
    buffer: Vec<u8>,
    closed: bool,
    pending: bool,
    profile: String,
    profiles: Vec<String>,
    inhibited: String,
    degraded: String,
    error: String,
    game: bool,
    game_override: bool,
    hold: Option<u32>,
}
impl State {
    fn emit(&mut self, mut msg: Value) {
        if let Some(generation) = self.generation.as_ref().filter(|v| !v.is_null()) {
            msg["generation"] = generation.clone();
        }
        let stdout = io::stdout();
        let mut output = stdout.lock();
        let sent = serde_json::to_vec(&msg)
            .map_err(io::Error::other)
            .and_then(|bytes| output.write_all(&bytes))
            .and_then(|_| output.write_all(b"\n"))
            .and_then(|_| output.flush());
        if sent.is_err() {
            self.closed = true;
            unsafe { gio::g_main_loop_quit(self.loop_) };
        }
    }
    unsafe fn snapshot(&mut self) {
        if self.owner.is_empty() || self.closed {
            return;
        }
        let response = sync(
            self.bus,
            &self.owner,
            self.path,
            PROPS,
            "GetAll",
            gio::tuple(&[gio::string(self.name)]),
        );
        match response {
            Ok(reply) => {
                let Some(props) = reply.child(0).filter(|v| v.kind() == "a{sv}") else {
                    self.emit(json!({"type":"unavailable","error":"Invalid power profile data."}));
                    return;
                };
                self.profile = props
                    .lookup("ActiveProfile")
                    .and_then(|v| v.string())
                    .unwrap_or_default();
                self.inhibited = props
                    .lookup("PerformanceInhibited")
                    .and_then(|v| v.string())
                    .unwrap_or_default();
                self.degraded = props
                    .lookup("PerformanceDegraded")
                    .and_then(|v| v.string())
                    .unwrap_or_default();
                self.profiles.clear();
                if let Some(profiles) = props.lookup("Profiles").filter(|v| v.kind() == "aa{sv}") {
                    for i in 0..profiles.len() {
                        if let Some(profile) = profiles
                            .child(i)
                            .and_then(|v| v.lookup("Profile"))
                            .and_then(|v| v.string())
                            .filter(|v| !v.is_empty())
                        {
                            self.profiles.push(profile);
                        }
                    }
                }
                self.emit(json!({"type":"state","available":true,"profile":self.profile,"profiles":self.profiles,
                    "inhibited":self.inhibited,"degraded":self.degraded,"busy":self.pending,"gameHold":self.hold.is_some(),"error":self.error}));
            }
            Err(error) => self.emit(json!({"type":"unavailable","error":friendly(&error)})),
        }
    }
    unsafe fn call(&mut self, interface: &str, method: &str, args: Ptr, action: Action) {
        let pending = Box::new(Pending {
            state: self as *mut State,
            owner: self.owner.clone(),
            epoch: self.owner_epoch,
            action,
        });
        gio::g_dbus_connection_call(
            self.bus,
            c(&self.owner).as_ptr(),
            c(self.path).as_ptr(),
            c(interface).as_ptr(),
            c(method).as_ptr(),
            args,
            ptr::null_mut(),
            0,
            15000,
            ptr::null_mut(),
            Some(done),
            Box::into_raw(pending).cast(),
        );
    }
    unsafe fn complete(&mut self, error: Option<String>) {
        self.pending = false;
        self.error = error.as_deref().map(friendly).unwrap_or_default();
        self.snapshot();
        if error.is_none() {
            self.reconcile();
        }
    }
    unsafe fn close_uncertain_hold(&mut self, error: &str) {
        self.pending = false;
        self.hold = None;
        self.emit(json!({"type":"unavailable","error":friendly(error)}));
        // Closing this process's D-Bus connection releases holds owned by it.
        // A missing response cannot establish whether a hold was created or
        // released, so never retry that operation on the same connection.
        self.closed = true;
        gio::g_main_loop_quit(self.loop_);
    }
    unsafe fn select_set(&mut self, profile: String) {
        let args = gio::tuple(&[
            gio::string(self.name),
            gio::string("ActiveProfile"),
            gio::g_variant_new_variant(gio::string(&profile)),
        ]);
        self.call(PROPS, "Set", args, Action::Set(profile));
    }
    unsafe fn select(&mut self, profile: &str) -> Result<(), String> {
        if self.pending {
            return Err("A power profile change is already in progress.".into());
        }
        if self.owner.is_empty() {
            return Err("The power profiles service is unavailable.".into());
        }
        if !self.profiles.iter().any(|p| p == profile) {
            return Err("This power profile is not supported on this device.".into());
        }
        if profile == "performance" && !self.inhibited.is_empty() {
            return Err(format!("Performance is unavailable: {}", self.inhibited));
        }
        self.pending = true;
        self.game_override = self.game;
        self.error.clear();
        self.snapshot();
        if let Some(cookie) = self.hold {
            self.call(
                self.name,
                "ReleaseProfile",
                gio::tuple(&[gio::g_variant_new_uint32(cookie)]),
                Action::ReleaseForSelect(cookie, profile.into()),
            );
        } else {
            self.select_set(profile.into());
        }
        Ok(())
    }
    unsafe fn reconcile(&mut self) {
        if self.pending || self.owner.is_empty() || self.closed {
            return;
        }
        if !self.game && self.hold.is_some() {
            self.pending = true;
            self.snapshot();
            let cookie = self.hold.unwrap();
            self.call(
                self.name,
                "ReleaseProfile",
                gio::tuple(&[gio::g_variant_new_uint32(cookie)]),
                Action::Release(cookie),
            );
        } else if self.game && !self.game_override && self.hold.is_none() {
            if !self.profiles.iter().any(|p| p == "performance") || !self.inhibited.is_empty() {
                self.game_override = true;
                self.error = if self.inhibited.is_empty() {
                    "Performance profile is unavailable.".into()
                } else {
                    format!("Performance profile is unavailable: {}", self.inhibited)
                };
                self.snapshot();
                return;
            }
            self.pending = true;
            self.snapshot();
            self.call(
                self.name,
                "HoldProfile",
                gio::tuple(&[
                    gio::string("performance"),
                    gio::string("Game Mode"),
                    gio::string("org.macshell.niri"),
                ]),
                Action::Hold,
            );
        }
    }
    unsafe fn command(&mut self, request: &Value) -> Result<(), String> {
        let action = request
            .get("action")
            .and_then(Value::as_str)
            .ok_or_else(|| "Unknown power operation.".to_owned())?;
        let data = request.get("data").cloned().unwrap_or_else(|| json!({}));
        match action {
            "refresh" => self.snapshot(),
            "select" => self.select(data.get("profile").and_then(Value::as_str).unwrap_or(""))?,
            "game" => {
                let desired = data.get("enabled").is_some_and(truthy);
                if desired != self.game {
                    self.game = desired;
                    self.game_override = false;
                }
                self.reconcile();
                self.snapshot();
            }
            _ => return Err("Unknown power operation.".into()),
        }
        Ok(())
    }
}
enum Action {
    Hold,
    Release(u32),
    ReleaseForSelect(u32, String),
    Set(String),
}
struct Pending {
    state: *mut State,
    owner: String,
    epoch: u64,
    action: Action,
}
extern "C" fn done(bus: Ptr, result: Ptr, data: Ptr) {
    unsafe {
        let pending = Box::from_raw(data.cast::<Pending>());
        let state = &mut *pending.state;
        let mut error = ptr::null_mut();
        let reply = Variant::from(gio::g_dbus_connection_call_finish(bus, result, &mut error));
        let error = if reply.is_none() {
            Some(gio::error(error))
        } else {
            None
        };
        if state.closed || state.owner != pending.owner || state.owner_epoch != pending.epoch {
            return;
        }
        match pending.action {
            Action::Hold => {
                let cookie = reply.and_then(|v| v.child(0)).and_then(|v| v.u32());
                if error.is_some() || cookie.is_none() {
                    state.game_override = true;
                    state.close_uncertain_hold(
                        error.as_deref().unwrap_or("Invalid power hold response."),
                    );
                } else {
                    state.hold = cookie;
                    state.complete(None);
                }
            }
            Action::Release(cookie) => {
                if let Some(error) = error {
                    state.close_uncertain_hold(&error);
                } else {
                    if state.hold == Some(cookie) {
                        state.hold = None;
                    }
                    state.complete(None);
                }
            }
            Action::ReleaseForSelect(cookie, profile) => {
                if error.is_none() {
                    if state.hold == Some(cookie) {
                        state.hold = None;
                    }
                    state.select_set(profile);
                } else {
                    state.close_uncertain_hold(error.as_deref().unwrap());
                }
            }
            Action::Set(profile) => {
                if error.is_some() {
                    state.complete(error);
                } else {
                    let confirmed = sync(
                        state.bus,
                        &state.owner,
                        state.path,
                        PROPS,
                        "GetAll",
                        gio::tuple(&[gio::string(state.name)]),
                    );
                    let result = match confirmed {
                        Ok(reply) => {
                            if reply
                                .child(0)
                                .filter(|v| v.kind() == "a{sv}")
                                .and_then(|v| v.lookup("ActiveProfile"))
                                .and_then(|v| v.string())
                                .as_deref()
                                == Some(&profile)
                            {
                                None
                            } else {
                                Some(
                                    "The system did not activate the requested power profile."
                                        .into(),
                                )
                            }
                        }
                        Err(e) => Some(e),
                    };
                    state.complete(result);
                }
            }
        }
    }
}
extern "C" fn appeared(_: Ptr, _: *const libc::c_char, owner: *const libc::c_char, data: Ptr) {
    unsafe {
        let state = &mut *data.cast::<State>();
        state.owner_epoch = state.owner_epoch.wrapping_add(1);
        state.owner = gio::text(owner);
        state.emit(json!({"type":"ready"}));
        state.snapshot();
        state.reconcile();
    }
}
extern "C" fn vanished(_: Ptr, _: *const libc::c_char, data: Ptr) {
    unsafe {
        let state = &mut *data.cast::<State>();
        let uncertain = state.pending || state.hold.is_some();
        state.owner_epoch = state.owner_epoch.wrapping_add(1);
        state.owner.clear();
        state.pending = false;
        state.hold = None;
        state.profile.clear();
        state.profiles.clear();
        state.emit(json!({"type":"unavailable","error":"System service is unavailable."}));
        if uncertain {
            // The old daemon may have processed an operation whose reply has
            // not arrived. Closing this connection releases any owned hold.
            state.closed = true;
            gio::g_main_loop_quit(state.loop_);
        }
    }
}
extern "C" fn changed(
    _: Ptr,
    sender: *const libc::c_char,
    _: *const libc::c_char,
    _: *const libc::c_char,
    signal: *const libc::c_char,
    params: Ptr,
    data: Ptr,
) {
    unsafe {
        let state = &mut *data.cast::<State>();
        if state.closed || state.owner.is_empty() || gio::text(sender) != state.owner {
            return;
        }
        if gio::text(signal) == "ProfileReleased" {
            // The borrowed signal parameter remains owned by Gio.
            let cookie = if gio::g_variant_n_children(params) > 0 {
                Variant::from(gio::g_variant_get_child_value(params, 0)).and_then(|v| v.u32())
            } else {
                None
            };
            if cookie.is_some() && state.hold == cookie {
                state.hold = None;
                state.game_override = state.game;
                state.snapshot();
            }
        } else {
            state.snapshot();
        }
    }
}
extern "C" fn tick(data: Ptr) -> i32 {
    unsafe {
        let state = &mut *data.cast::<State>();
        if state.closed {
            return 0;
        }
        state.snapshot();
        1
    }
}
extern "C" fn input(fd: i32, _: u32, data: Ptr) -> i32 {
    unsafe {
        let state = &mut *data.cast::<State>();
        let mut bytes = [0u8; 65536];
        let n = libc::read(fd, bytes.as_mut_ptr().cast(), bytes.len());
        if n < 0
            && matches!(
                io::Error::last_os_error().kind(),
                io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
            )
        {
            return 1;
        }
        if n <= 0 {
            state.closed = true;
            gio::g_main_loop_quit(state.loop_);
            return 0;
        }
        state.buffer.extend_from_slice(&bytes[..n as usize]);
        if state.buffer.len() > 1_048_576 {
            state.closed = true;
            gio::g_main_loop_quit(state.loop_);
            return 0;
        }
        while let Some(end) = state.buffer.iter().position(|v| *v == b'\n') {
            let line: Vec<_> = state.buffer.drain(..=end).collect();
            match serde_json::from_slice::<Value>(&line) {
                Ok(request)
                    if request.is_object()
                        && request.get("data").map_or(true, Value::is_object) =>
                {
                    state.generation = request.get("generation").cloned();
                    if let Err(error) = state.command(&request) {
                        state.emit(
                            json!({"type":"error","id":request.get("id"),"error":friendly(&error)}),
                        );
                    }
                }
                _ => {
                    state.emit(json!({"type":"error","id":null,"error":"Invalid service request"}))
                }
            }
        }
        if state.closed {
            0
        } else {
            1
        }
    }
}
fn run() -> Result<(), String> {
    unsafe {
        let mut error = ptr::null_mut();
        let bus = gio::g_bus_get_sync(1, ptr::null_mut(), &mut error);
        if bus.is_null() {
            return Err(gio::error(error));
        }
        let (name, path) = match endpoint(bus) {
            Ok(endpoint) => endpoint,
            Err(error) => {
                gio::g_object_unref(bus);
                return Err(error);
            }
        };
        let loop_ = gio::g_main_loop_new(ptr::null_mut(), 0);
        if loop_.is_null() {
            gio::g_object_unref(bus);
            return Err("Cannot create main loop".into());
        }
        let mut state = Box::new(State {
            bus,
            loop_,
            name,
            path,
            owner: String::new(),
            owner_epoch: 0,
            generation: None,
            buffer: Vec::new(),
            closed: false,
            pending: false,
            profile: String::new(),
            profiles: Vec::new(),
            inhibited: String::new(),
            degraded: String::new(),
            error: String::new(),
            game: false,
            game_override: false,
            hold: None,
        });
        let data = (&mut *state as *mut State).cast();
        let watch = gio::g_bus_watch_name_on_connection(
            bus,
            c(name).as_ptr(),
            0,
            Some(appeared),
            Some(vanished),
            data,
            ptr::null_mut(),
        );
        let signal1 = gio::g_dbus_connection_signal_subscribe(
            bus,
            c(name).as_ptr(),
            c(PROPS).as_ptr(),
            c("PropertiesChanged").as_ptr(),
            c(path).as_ptr(),
            c(name).as_ptr(),
            0,
            Some(changed),
            data,
            ptr::null_mut(),
        );
        let signal2 = gio::g_dbus_connection_signal_subscribe(
            bus,
            c(name).as_ptr(),
            c(name).as_ptr(),
            c("ProfileReleased").as_ptr(),
            c(path).as_ptr(),
            ptr::null(),
            0,
            Some(changed),
            data,
            ptr::null_mut(),
        );
        let fd = gio::g_unix_fd_add(
            libc::STDIN_FILENO,
            (libc::POLLIN | libc::POLLHUP | libc::POLLERR) as u32,
            Some(input),
            data,
        );
        let timer = gio::g_timeout_add_seconds(15, Some(tick), data);
        gio::g_main_loop_run(loop_);
        state.closed = true;
        gio::g_bus_unwatch_name(watch);
        gio::g_dbus_connection_signal_unsubscribe(bus, signal1);
        gio::g_dbus_connection_signal_unsubscribe(bus, signal2);
        let context = gio::g_main_context_default();
        for id in [fd, timer] {
            let source = gio::g_main_context_find_source_by_id(context, id);
            if !source.is_null() {
                gio::g_source_destroy(source);
            }
        }
        gio::g_main_loop_unref(loop_);
        gio::g_object_unref(bus);
        // Pending Gio callbacks may still hold this address. No new calls are
        // issued after shutdown, and the process exits immediately afterwards.
        std::mem::forget(state);
        Ok(())
    }
}
fn main() {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("macshell-power-profiles 1");
        return;
    }
    if !args.is_empty() {
        eprintln!("macshell-power-profiles: unexpected argument");
        std::process::exit(1);
    }
    if run().is_err() {
        println!(
            "{{\"type\":\"unavailable\",\"error\":\"Cannot reach the system D-Bus service.\"}}"
        );
        std::process::exit(1);
    }
}
