//! JSON-lines Bluetooth service used by MacShell.
use macshell_bluez_agent::Event as AgentEvent;
use macshell_bluez_session::{Event, Session};
use macshell_gio_bridge::{self as gio, Ptr};
use serde_json::{json, Value};
use std::io::{self, Write};
use std::ptr;
use std::sync::mpsc::{self, Receiver};

mod rfkill;

struct Service {
    bus: Ptr,
    loop_: Ptr,
    session: Session,
    events: Receiver<Event>,
    buffer: Vec<u8>,
    generation: Option<Value>,
    snapshot: Option<Value>,
    discovering: bool,
    registered: bool,
    owner_available: bool,
    next_refresh: u64,
    closed: bool,
}
fn now_ms() -> u64 {
    unsafe { gio::g_get_monotonic_time().max(0) as u64 / 1000 }
}
fn friendly(message: &str) -> String {
    let lower = message.to_lowercase();
    let fixed = if message.contains("NotReady")
        || message.contains("Blocked")
        || lower.contains("rfkill")
    {
        Some("Bluetooth is off or blocked by the hardware switch.")
    } else if message.contains("NotAuthorized") || message.contains("AccessDenied") {
        Some("Bluetooth access was denied.")
    } else if message.contains("Authentication") {
        Some("Pairing needs attention. Pair the device again using your Bluetooth manager.")
    } else if message.contains("InProgress") {
        Some("This device is already connecting. Try again in a moment.")
    } else if message.contains("UnknownObject") || message.contains("DoesNotExist") {
        Some("This device is no longer available.")
    } else if lower.contains("timeout") || lower.contains("timed out") {
        Some("The device did not respond. Check that it is on and nearby.")
    } else if message.contains("ServiceUnknown")
        || message.contains("NameHasNoOwner")
        || message.contains("Could not connect")
    {
        Some("The Bluetooth service is unavailable.")
    } else {
        None
    };
    fixed
        .unwrap_or_else(|| message.split_once(": ").map_or(message, |(_, tail)| tail))
        .chars()
        .take(240)
        .collect()
}
impl Service {
    fn emit(&mut self, mut message: Value) {
        if let Some(generation) = &self.generation {
            message["generation"] = generation.clone();
        }
        let mut out = io::stdout().lock();
        let result = serde_json::to_writer(&mut out, &message)
            .map_err(io::Error::other)
            .and_then(|_| out.write_all(b"\n"))
            .and_then(|_| out.flush());
        if result.is_err() {
            self.closed = true;
            unsafe {
                gio::g_main_loop_quit(self.loop_);
            }
        }
    }
    fn emit_state(&mut self) {
        let Some(mut state) = self.snapshot.clone() else {
            return;
        };
        state["type"] = json!("state");
        state["discovering"] = json!(self.discovering);
        state["pairingAvailable"] = json!(self.registered);
        self.emit(state);
    }
    fn events(&mut self) {
        self.session.poll();
        while let Ok(event) = self.events.try_recv() {
            match event {
                Event::Owner { unique, .. } => {
                    self.snapshot = None;
                    self.discovering = false;
                    self.registered = false;
                    if unique.is_some() {
                        self.owner_available = true;
                        self.emit(json!({"type":"ready"}));
                    } else {
                        if self.owner_available {
                            self.emit(json!({"type":"prompt","prompt":null}));
                        }
                        self.owner_available = false;
                        self.emit(
                            json!({"type":"unavailable","error":"System service is unavailable."}),
                        );
                    }
                }
                Event::Registration { success, .. } => {
                    self.registered = success;
                    if !success {
                        self.emit(json!({"type":"error","error":"Bluetooth pairing agent could not register."}));
                    }
                    self.emit_state();
                }
                Event::Snapshot { state, .. } => {
                    self.snapshot = Some(state);
                    self.emit_state();
                }
                Event::Discovery { owned } => {
                    self.discovering = owned > 0;
                    self.emit_state();
                }
                Event::Agent(AgentEvent::Prompt(p)) => self.emit(json!({"type":"prompt","prompt":{
                    "id":p.id,"request":p.request,"method":p.method,"device":p.device,"name":p.name,
                    "code":p.code,"entered":p.entered,"service":p.service}})),
                Event::Agent(AgentEvent::Cleared) => {
                    if self.owner_available {
                        self.emit(json!({"type":"prompt","prompt":null}));
                    }
                }
                Event::Agent(AgentEvent::Released) => {
                    self.registered = false;
                    self.emit_state();
                }
                Event::Agent(_) => (),
                Event::PairResult {
                    request,
                    success,
                    phase,
                    error,
                }
                | Event::DeviceResult {
                    request,
                    success,
                    phase,
                    error,
                }
                | Event::PowerResult {
                    request,
                    success,
                    phase,
                    error,
                } => {
                    self.emit(json!({"type":"result","id":request,"ok":success,"phase":phase,"error":if error.is_empty() { String::new() } else { friendly(&error) }}));
                }
                Event::Error(error) => self.emit(json!({"type":"error","error":friendly(&error)})),
                Event::CloseConnection => {
                    self.emit(json!({"type":"unavailable","error":"Bluetooth connection restarted; retrying…"}));
                    self.closed = true;
                    unsafe {
                        gio::g_main_loop_quit(self.loop_);
                    }
                }
            }
        }
    }
    fn device_name(&self, path: &str) -> String {
        self.snapshot
            .as_ref()
            .and_then(|s| {
                ["devices", "others"]
                    .iter()
                    .flat_map(|key| s[*key].as_array().into_iter().flatten())
                    .find(|d| d["path"].as_str() == Some(path))
                    .and_then(|d| d["name"].as_str())
            })
            .unwrap_or("Bluetooth device")
            .to_owned()
    }
    fn command(&mut self, value: &Value) -> Result<(), String> {
        let request = value
            .get("id")
            .and_then(Value::as_u64)
            .ok_or("Invalid service request")?;
        let action = value
            .get("action")
            .and_then(Value::as_str)
            .ok_or("Invalid service request")?;
        let empty = json!({});
        let data = value.get("data").unwrap_or(&empty);
        if !data.is_object() {
            return Err("Invalid service request".into());
        }
        let path = data.get("path").and_then(Value::as_str).unwrap_or("");
        let result = match action {
            "refresh" => self.session.refresh(),
            "discover" => self.session.discover(now_ms()),
            "stopDiscovery" => {
                self.session.stop_discovery();
                Ok(())
            }
            "power" => match data.get("enabled").and_then(Value::as_bool) {
                Some(enabled) => self.session.set_power(request, enabled, now_ms()),
                None => Err("Invalid Bluetooth power state."),
            },
            "pair" => self
                .session
                .pair(request, path, &self.device_name(path), now_ms()),
            "connect" | "disconnect" => {
                self.session
                    .set_connected(request, path, action == "connect", now_ms())
            }
            "cancel" => {
                if let Some(id) = data.get("request").and_then(Value::as_u64) {
                    self.session.cancel_pair(id);
                }
                Ok(())
            }
            "respond" => {
                let prompt = data
                    .get("prompt")
                    .and_then(Value::as_u64)
                    .ok_or("Invalid Bluetooth prompt.")?;
                let accept = data.get("accept").and_then(Value::as_bool).unwrap_or(false);
                let text = data.get("value").and_then(Value::as_str).unwrap_or("");
                self.session.respond(prompt, accept, text).map(|_| ())
            }
            _ => Err("Unknown Bluetooth action."),
        };
        result.map_err(str::to_owned)
    }
    fn input(&mut self, bytes: &[u8]) {
        self.buffer.extend_from_slice(bytes);
        if self.buffer.len() > 1_048_576 {
            self.closed = true;
            unsafe {
                gio::g_main_loop_quit(self.loop_);
            }
            return;
        }
        while let Some(end) = self.buffer.iter().position(|b| *b == b'\n') {
            let line: Vec<_> = self.buffer.drain(..=end).collect();
            let value = match serde_json::from_slice::<Value>(&line) {
                Ok(value) if value.is_object() => value,
                _ => {
                    self.emit(json!({"type":"error","error":"Invalid service request"}));
                    continue;
                }
            };
            if let Some(generation) = value.get("generation").filter(|v| !v.is_null()) {
                if self
                    .generation
                    .as_ref()
                    .is_some_and(|current| current != generation)
                {
                    continue;
                }
                self.generation = Some(generation.clone());
            }
            if let Err(error) = self.command(&value) {
                self.emit(json!({"type":"error","id":value.get("id"),"error":friendly(&error)}));
            }
            self.events();
            if self.closed {
                return;
            }
        }
    }
}
extern "C" fn input(fd: i32, _: u32, data: Ptr) -> i32 {
    unsafe {
        let service = &mut *data.cast::<Service>();
        let mut bytes = [0u8; 8192];
        let read = libc::read(fd, bytes.as_mut_ptr().cast(), bytes.len());
        if read <= 0 {
            service.closed = true;
            gio::g_main_loop_quit(service.loop_);
            return 0;
        }
        service.input(&bytes[..read as usize]);
        if service.closed {
            0
        } else {
            1
        }
    }
}
extern "C" fn tick(data: Ptr) -> i32 {
    unsafe {
        let service = &mut *data.cast::<Service>();
        if gio::g_dbus_connection_is_closed(service.bus) != 0 {
            service.emit(
                json!({"type":"unavailable","error":"Cannot reach the system D-Bus service."}),
            );
            service.closed = true;
            gio::g_main_loop_quit(service.loop_);
            return 0;
        }
        let now = now_ms();
        service.session.tick(now);
        if now >= service.next_refresh {
            let _ = service.session.refresh();
            service.next_refresh = now.saturating_add(2000);
        }
        service.events();
        if service.closed {
            0
        } else {
            1
        }
    }
}
extern "C" fn shutdown(data: Ptr) -> i32 {
    unsafe {
        let service = &mut *data.cast::<Service>();
        service.closed = true;
        gio::g_main_loop_quit(service.loop_);
    }
    0
}
unsafe fn run() -> Result<(), String> {
    let mut error = ptr::null_mut();
    let address = gio::g_dbus_address_get_for_bus_sync(1, ptr::null_mut(), &mut error);
    if address.is_null() {
        return Err(gio::error(error));
    }
    let bus = gio::g_dbus_connection_new_for_address_sync(
        address,
        9,
        ptr::null_mut(),
        ptr::null_mut(),
        &mut error,
    );
    gio::g_free(address.cast());
    if bus.is_null() {
        return Err(gio::error(error));
    }
    let (tx, rx) = mpsc::channel();
    let session = match Session::new(bus, tx) {
        Ok(session) => session,
        Err(error) => {
            gio::g_object_unref(bus);
            return Err(error);
        }
    };
    // An explicitly overridden bus may be a synthetic BlueZ. Never let a test
    // bus operate the real machine's radio, even if it contains fake adapters.
    if std::env::var_os("DBUS_SYSTEM_BUS_ADDRESS").is_none() {
        session.set_radio_unblocker(Box::new(rfkill::unblock_bluetooth));
    }
    let loop_ = gio::g_main_loop_new(ptr::null_mut(), 0);
    let mut service = Box::new(Service {
        bus,
        loop_,
        session,
        events: rx,
        buffer: Vec::new(),
        generation: None,
        snapshot: None,
        discovering: false,
        registered: false,
        owner_available: false,
        next_refresh: now_ms().saturating_add(2000),
        closed: false,
    });
    let data = (&mut *service as *mut Service).cast();
    let fd = gio::g_unix_fd_add(
        libc::STDIN_FILENO,
        (libc::POLLIN | libc::POLLHUP | libc::POLLERR) as u32,
        Some(input),
        data,
    );
    let timer = gio::g_timeout_add(50, Some(tick), data);
    let term = gio::g_unix_signal_add(libc::SIGTERM, Some(shutdown), data);
    let interrupt = gio::g_unix_signal_add(libc::SIGINT, Some(shutdown), data);
    gio::g_main_loop_run(loop_);
    let context = gio::g_main_context_default();
    for id in [fd, timer, term, interrupt] {
        let source = gio::g_main_context_find_source_by_id(context, id);
        if !source.is_null() {
            gio::g_source_destroy(source);
        }
    }
    drop(service);
    gio::g_main_loop_unref(loop_);
    gio::g_object_unref(bus);
    Ok(())
}
fn main() {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("macshell-bluetooth 1");
        return;
    }
    if !args.is_empty() {
        eprintln!("macshell-bluetooth: unexpected argument");
        std::process::exit(1);
    }
    if unsafe { run() }.is_err() {
        println!(
            "{{\"type\":\"unavailable\",\"error\":\"Cannot reach the system D-Bus service.\"}}"
        );
        std::process::exit(1);
    }
}
