//! JSON-lines Wi-Fi service for NetworkManager.
use macshell_gio_bridge::{self as gio, c, Ptr};
use macshell_network_agent::Event as AgentEvent;
use macshell_network_core::activation::{Action, Ticket};
use macshell_network_snapshot::{
    activate,
    join::{Job, Secret},
    radio,
    session::{Event, RadioAction, SecretIdentity, Selection, Session},
    Error,
};
use serde_json::{json, Value};
use std::ffi::CStr;
use std::io::{self, Write};
use std::ptr;
use std::time::{Duration, Instant};

struct Pending {
    ticket: Ticket,
    network: Value,
    initial: Option<Secret>,
    delivery: Option<u64>,
    canceled: bool,
}
struct Service {
    bus: Ptr,
    loop_: Ptr,
    session: Session<Job>,
    input: Vec<u8>,
    generation: Option<Value>,
    networks: Vec<Value>,
    pending: Option<Pending>,
    next_refresh: Instant,
    closed: bool,
}

fn username() -> Result<String, &'static str> {
    let mut buffer = vec![0u8; 16384];
    let mut entry = unsafe { std::mem::zeroed::<libc::passwd>() };
    let mut found = ptr::null_mut();
    let result = unsafe {
        libc::getpwuid_r(
            libc::getuid(),
            &mut entry,
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut found,
        )
    };
    if result != 0 || found.is_null() || entry.pw_name.is_null() {
        return Err("Cannot identify the current user.");
    }
    unsafe { CStr::from_ptr(entry.pw_name) }
        .to_str()
        .map(str::to_owned)
        .map_err(|_| "Cannot identify the current user.")
}

unsafe fn connect(address: &str) -> Option<Ptr> {
    let mut error = ptr::null_mut();
    let bus = gio::g_dbus_connection_new_for_address_sync(
        c(address).as_ptr(),
        9,
        ptr::null_mut(),
        ptr::null_mut(),
        &mut error,
    );
    if !error.is_null() {
        gio::g_error_free(error);
    }
    if bus.is_null() {
        None
    } else {
        Some(bus)
    }
}
unsafe fn close(bus: Ptr) {
    let mut error = ptr::null_mut();
    gio::g_dbus_connection_close_sync(bus, ptr::null_mut(), &mut error);
    if !error.is_null() {
        gio::g_error_free(error);
    }
    gio::g_object_unref(bus);
}
impl Service {
    fn emit(&mut self, mut value: Value) {
        if let Some(generation) = &self.generation {
            value["generation"] = generation.clone();
        }
        let mut out = io::stdout().lock();
        if serde_json::to_writer(&mut out, &value).is_err()
            || writeln!(out).is_err()
            || out.flush().is_err()
        {
            self.closed = true;
            unsafe {
                gio::g_main_loop_quit(self.loop_);
            }
        }
    }
    fn stop(&mut self) {
        self.closed = true;
        unsafe {
            gio::g_main_loop_quit(self.loop_);
        }
    }
    fn network(&self, id: &str) -> Option<Value> {
        self.networks
            .iter()
            .find(|n| n["id"].as_str() == Some(id))
            .cloned()
    }
    fn command(&mut self, mut request: Value) -> Result<(), &'static str> {
        let id = request["id"]
            .as_u64()
            .ok_or("Invalid request identifier.")?;
        let action = request["action"]
            .as_str()
            .ok_or("Invalid Wi-Fi action.")?
            .to_owned();
        let data = &mut request["data"];
        match action.as_str() {
            "refresh" => {
                self.session.refresh()?;
            }
            "scan" => self.session.radio(id, RadioAction::Scan)?,
            "power" => self.session.radio(
                id,
                RadioAction::Power(
                    data["enabled"]
                        .as_bool()
                        .ok_or("Invalid Wi-Fi power state.")?,
                ),
            )?,
            "disconnect" => {
                let net = self
                    .network(data["network"].as_str().ok_or("Invalid Wi-Fi network.")?)
                    .ok_or("This access point is no longer available. Scan again.")?;
                let device = net["device"].as_str().ok_or("Invalid Wi-Fi network.")?;
                let ap = net["id"].as_str().ok_or("Invalid Wi-Fi network.")?;
                self.session.radio(
                    id,
                    RadioAction::Disconnect {
                        device: device.into(),
                        ap: ap.into(),
                    },
                )?;
            }
            "join" => {
                if self.pending.is_some() {
                    return Err("Wait for the current Wi-Fi request or cancel it.");
                }
                let network = self
                    .network(data["network"].as_str().ok_or("Invalid Wi-Fi network.")?)
                    .ok_or("This access point is no longer available. Scan again.")?;
                let password = match data["password"].take() {
                    Value::String(v) => v,
                    Value::Null => String::new(),
                    _ => return Err("Invalid Wi-Fi password."),
                };
                let initial = Secret::new(password)?;
                let has_initial = !initial.as_str().is_empty();
                let job = Job::from_snapshot(
                    &network,
                    &username()?,
                    Secret::new(initial.as_str().to_owned())?,
                )?;
                let device = job.device.clone();
                let ap = job.ap.clone();
                let uuid = job.uuid.clone();
                let profile = job.profile.clone();
                let secure = job.security != "open";
                let ticket = self.session.begin(
                    id,
                    Selection {
                        device: &device,
                        ap: &ap,
                        secret: secure.then_some(SecretIdentity {
                            uuid: &uuid,
                            profile: profile.as_deref(),
                            has_initial,
                        }),
                    },
                    job,
                )?;
                self.pending = Some(Pending {
                    ticket,
                    network,
                    initial: has_initial.then_some(initial),
                    delivery: None,
                    canceled: false,
                });
            }
            "cancel" => {
                if let Some(p) = &mut self.pending {
                    if data["request"].as_u64() == Some(p.ticket.request) {
                        p.initial = None;
                        p.delivery = None;
                        p.canceled = true;
                        let t = p.ticket;
                        self.session.cancel(t);
                    }
                }
            }
            "secret" => {
                let password = match data["password"].take() {
                    Value::String(v) => Secret::new(v)?,
                    _ => return Err("Invalid Wi-Fi password."),
                };
                if let Some(p) = &mut self.pending {
                    if !p.canceled && data["request"].as_u64() == Some(p.ticket.request) {
                        if let Some(delivery) = p.delivery.take() {
                            self.session.reply(p.ticket, delivery, password.as_str())?;
                        }
                    }
                }
            }
            _ => return Err("Unknown Wi-Fi action."),
        }
        Ok(())
    }
    fn events(&mut self) {
        for event in self.session.poll() {
            match event {
                Event::Owner(Some(_)) => {
                    self.networks.clear();
                    self.emit(json!({"type":"ready"}));
                    let _ = self.session.refresh();
                }
                Event::Owner(None) => {
                    self.networks.clear();
                    self.emit(
                        json!({"type":"unavailable","error":"NetworkManager is unavailable."}),
                    );
                }
                Event::Registration(false) => self.emit(
                    json!({"type":"error","error":"The Wi-Fi password agent is unavailable."}),
                ),
                Event::Registration(true) => (),
                Event::Snapshot(Ok(state)) => {
                    self.networks = state["networks"].as_array().cloned().unwrap_or_default();
                    self.emit(state);
                }
                Event::Snapshot(Err(_)) => {
                    self.emit(json!({"type":"error","error":"Cannot read Wi-Fi status."}))
                }
                Event::Radio { result, .. } => {
                    if result.is_err() {
                        self.emit(json!({"type":"error","error":"Wi-Fi operation failed."}));
                    }
                    let _ = self.session.refresh();
                }
                Event::Agent(AgentEvent::NeedSecret {
                    request,
                    delivery,
                    provided,
                    discard_provided,
                }) => {
                    let mut prompt = None;
                    if let Some(p) = &mut self.pending {
                        if p.ticket.request == request && !p.canceled {
                            if discard_provided {
                                p.initial = None;
                            }
                            if provided && p.initial.is_some() {
                                let secret = p.initial.take().expect("initial secret");
                                let _ = self.session.reply(p.ticket, delivery, secret.as_str());
                            } else {
                                p.delivery = Some(delivery);
                                prompt = Some(p.network.clone());
                            }
                        }
                    }
                    if let Some(network) = prompt {
                        self.emit(json!({"type":"secret","id":request,"network":network,"error":"Enter the password for this network."}));
                    }
                }
                Event::Agent(_) => (),
                Event::Activation { ticket, action } => {
                    let result = match action {
                        Action::Connected => Some((true, "connected", "")),
                        Action::Canceled => Some((true, "canceled", "")),
                        Action::Failed => Some((
                            false,
                            "failed",
                            "Connection failed. Check the password and signal.",
                        )),
                        Action::CloseUncertain => Some((
                            false,
                            "unknown",
                            "Connection status is uncertain. Check Wi-Fi before trying again.",
                        )),
                        _ => None,
                    };
                    if let Some((ok, state, error)) = result {
                        if self.pending.as_ref().is_some_and(|p| p.ticket == ticket) {
                            self.pending = None;
                        }
                        self.emit(json!({"type":"result","id":ticket.request,"ok":ok,"state":state,"error":error}));
                        if action == Action::CloseUncertain {
                            self.stop();
                            return;
                        }
                    }
                }
                Event::CloseConnection => {
                    self.emit(
                        json!({"type":"unavailable","error":"NetworkManager connection changed."}),
                    );
                    self.stop();
                    return;
                }
            }
        }
    }
    fn input(&mut self, bytes: &[u8]) {
        self.input.extend_from_slice(bytes);
        if self.input.len() > 65536 {
            self.stop();
            return;
        }
        while let Some(end) = self.input.iter().position(|b| *b == b'\n') {
            let mut line: Vec<_> = self.input.drain(..=end).collect();
            let request = serde_json::from_slice::<Value>(&line);
            line.fill(0);
            let Ok(value) = request else {
                self.emit(json!({"type":"error","error":"Invalid service request."}));
                continue;
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
            let id = value.get("id").cloned();
            if let Err(error) = self.command(value) {
                self.emit(json!({"type":"error","id":id,"error":error}));
            }
            self.events();
        }
    }
}
extern "C" fn input(fd: i32, _: u32, data: Ptr) -> i32 {
    unsafe {
        let s = &mut *data.cast::<Service>();
        let mut bytes = [0u8; 8192];
        let n = libc::read(fd, bytes.as_mut_ptr().cast(), bytes.len());
        if n <= 0 {
            s.stop();
            return 0;
        }
        s.input(&bytes[..n as usize]);
        bytes.fill(0);
        if s.closed {
            0
        } else {
            1
        }
    }
}
extern "C" fn tick(data: Ptr) -> i32 {
    unsafe {
        let s = &mut *data.cast::<Service>();
        if gio::g_dbus_connection_is_closed(s.bus) != 0 {
            s.stop();
            return 0;
        }
        if Instant::now() >= s.next_refresh {
            let _ = s.session.refresh();
            s.next_refresh = Instant::now() + Duration::from_secs(5);
        }
        s.events();
        if s.closed {
            0
        } else {
            1
        }
    }
}
extern "C" fn shutdown(data: Ptr) -> i32 {
    unsafe {
        (&mut *data.cast::<Service>()).stop();
    }
    0
}
unsafe fn run() -> Result<(), String> {
    let mut error = ptr::null_mut();
    let address = gio::g_dbus_address_get_for_bus_sync(1, ptr::null_mut(), &mut error);
    if address.is_null() {
        return Err(gio::error(error));
    }
    let address_text = gio::text(address);
    gio::g_free(address.cast());
    let bus = connect(&address_text).ok_or("System bus unavailable")?;
    gio::g_dbus_connection_set_exit_on_close(bus, 0);
    let reader_address = address_text.clone();
    let starter_address = address_text.clone();
    let inspect_address = address_text.clone();
    let session = Session::new(
        bus,
        move |owner| {
            let bus = connect(&reader_address).ok_or(Error::Unavailable)?;
            let result = macshell_network_snapshot::read(bus, owner, Duration::from_secs(8));
            close(bus);
            result
        },
        move |owner, job: Job| {
            let bus = connect(&starter_address).ok_or(activate::Error::Unavailable)?;
            let result = job.start(bus, owner, Duration::from_secs(20));
            close(bus);
            result
        },
        move |owner, path| {
            let bus = connect(&inspect_address).ok_or(activate::Error::Unavailable)?;
            let result = activate::inspect(bus, owner, &path, Duration::from_secs(5));
            close(bus);
            result
        },
        move |owner, action| {
            let bus = connect(&address_text).ok_or(radio::Error::Unavailable)?;
            let result = match action {
                RadioAction::Scan => radio::scan(bus, owner, Duration::from_secs(8)),
                RadioAction::Power(enabled) => {
                    radio::set_power(bus, owner, enabled, Duration::from_secs(8)).map(|()| 0)
                }
                RadioAction::Disconnect { device, ap } => {
                    radio::disconnect(bus, owner, &device, &ap, Duration::from_secs(8)).map(|()| 0)
                }
                RadioAction::CancelActivation { path } => {
                    activate::cancel(bus, owner, &path, Duration::from_secs(3))
                }
            };
            close(bus);
            result
        },
    )
    .inspect_err(|_| {
        close(bus);
    })?;
    let loop_ = gio::g_main_loop_new(ptr::null_mut(), 0);
    let mut s = Box::new(Service {
        bus,
        loop_,
        session,
        input: Vec::new(),
        generation: None,
        networks: Vec::new(),
        pending: None,
        next_refresh: Instant::now() + Duration::from_secs(5),
        closed: false,
    });
    let data = (&mut *s as *mut Service).cast();
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
    for id in [fd, timer, term, interrupt] {
        let source = gio::g_main_context_find_source_by_id(gio::g_main_context_default(), id);
        if !source.is_null() {
            gio::g_source_destroy(source);
        }
    }
    drop(s);
    gio::g_main_loop_unref(loop_);
    close(bus);
    Ok(())
}
fn main() {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("macshell-network 1");
        return;
    }
    if !args.is_empty() {
        std::process::exit(1);
    }
    if unsafe { run() }.is_err() {
        println!(
            "{{\"type\":\"unavailable\",\"error\":\"Cannot reach the system D-Bus service.\"}}"
        );
        std::process::exit(1);
    }
}
