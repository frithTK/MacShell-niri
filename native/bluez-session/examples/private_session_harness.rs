//! Integration harness for the experimental session on a private test bus.
use macshell_bluez_agent::Event as AgentEvent;
use macshell_bluez_session::{Event, Session};
use macshell_gio_bridge::{self as gio, Ptr};
use serde_json::{json, Value};
use std::io::{self, Write};
use std::ptr;
use std::sync::mpsc::{self, Receiver};

struct Harness {
    bus: Ptr,
    session: Option<Session>,
    events: Receiver<Event>,
    loop_: Ptr,
    input: Vec<u8>,
    polling: bool,
}
fn emit(value: Value) {
    let mut out = io::stdout().lock();
    let _ = serde_json::to_writer(&mut out, &value);
    let _ = out.write_all(b"\n");
    let _ = out.flush();
}
extern "C" fn input(fd: i32, _: u32, data: Ptr) -> i32 {
    unsafe {
        let host = &mut *data.cast::<Harness>();
        let mut bytes = [0u8; 4096];
        let n = libc::read(fd, bytes.as_mut_ptr().cast(), bytes.len());
        if n <= 0 {
            gio::g_main_loop_quit(host.loop_);
            return 0;
        }
        host.input.extend_from_slice(&bytes[..n as usize]);
        while let Some(end) = host.input.iter().position(|v| *v == b'\n') {
            let bytes: Vec<_> = host.input.drain(..=end).collect();
            let Ok(request) = serde_json::from_slice::<Value>(&bytes) else {
                continue;
            };
            let Some(session) = host.session.as_ref() else {
                emit(json!({"type":"command-error","message":"closed"}));
                continue;
            };
            match request["action"].as_str() {
                Some("refresh") => emit(match session.refresh() {
                    Ok(()) => json!({"type":"refreshed"}),
                    Err(e) => json!({"type":"command-error","message":e}),
                }),
                Some("discover") => emit(
                    match session.discover(request["now"].as_u64().unwrap_or(0)) {
                        Ok(()) => json!({"type":"discovering"}),
                        Err(e) => json!({"type":"command-error","message":e}),
                    },
                ),
                Some("stop") => {
                    session.stop_discovery();
                    emit(json!({"type":"stopping"}));
                }
                Some("tick") => {
                    session.tick(request["now"].as_u64().unwrap_or(0));
                    emit(json!({"type":"ticked"}));
                }
                Some("begin") => {
                    let result = session.begin_authorization(
                        request["id"].as_u64().unwrap_or(0),
                        request["device"].as_str().unwrap_or(""),
                        "Keyboard",
                        0,
                    );
                    emit(match result {
                        Ok(_) => json!({"type":"begun"}),
                        Err(e) => json!({"type":"command-error","message":e}),
                    });
                }
                Some("pair") => {
                    let result = session.pair(
                        request["id"].as_u64().unwrap_or(0),
                        request["device"].as_str().unwrap_or(""),
                        "Keyboard",
                        request["now"].as_u64().unwrap_or(0),
                    );
                    emit(match result {
                        Ok(()) => json!({"type":"pair-started"}),
                        Err(e) => json!({"type":"command-error","message":e}),
                    });
                }
                Some(action @ ("connect" | "disconnect")) => {
                    let result = session.set_connected(
                        request["id"].as_u64().unwrap_or(0),
                        request["device"].as_str().unwrap_or(""),
                        action == "connect",
                        request["now"].as_u64().unwrap_or(0),
                    );
                    emit(match result {
                        Ok(()) => json!({"type":"device-started"}),
                        Err(e) => json!({"type":"command-error","message":e}),
                    });
                }
                Some("power") => {
                    let result = session.set_power(
                        request["id"].as_u64().unwrap_or(0),
                        request["enabled"].as_bool().unwrap_or(false),
                        request["now"].as_u64().unwrap_or(0),
                    );
                    emit(match result {
                        Ok(()) => json!({"type":"power-started"}),
                        Err(e) => json!({"type":"command-error","message":e}),
                    });
                }
                Some("cancel") => {
                    session.cancel_pair(request["id"].as_u64().unwrap_or(0));
                    emit(json!({"type":"cancel-command"}));
                }
                Some("respond") => {
                    let result = session.respond(
                        request["prompt"].as_u64().unwrap_or(0),
                        request["accept"].as_bool().unwrap_or(false),
                        request["value"].as_str().unwrap_or(""),
                    );
                    emit(match result {
                        Ok(v) => json!({"type":"response","result":format!("{v:?}")}),
                        Err(e) => json!({"type":"command-error","message":e}),
                    });
                }
                Some("drop") => {
                    host.session.take();
                    emit(json!({"type":"dropped"}));
                }
                Some("ping") => emit(json!({"type":"pong"})),
                Some("pause-poll") => {
                    host.polling = false;
                    emit(json!({"type":"paused"}));
                }
                Some("resume-poll") => {
                    host.polling = true;
                    emit(json!({"type":"resumed"}));
                }
                _ => (),
            }
        }
        1
    }
}
extern "C" fn events(data: Ptr) -> i32 {
    unsafe {
        let host = &mut *data.cast::<Harness>();
        if host.polling {
            if let Some(session) = host.session.as_ref() {
                session.poll();
            }
        }
        while let Ok(event) = host.events.try_recv() {
            match event {
                Event::Owner { unique, generation } => {
                    emit(json!({"type":"owner","unique":unique,"generation":generation}))
                }
                Event::Registration {
                    generation,
                    success,
                } => emit(json!({"type":"registration","generation":generation,"success":success})),
                Event::Snapshot { generation, state } => {
                    emit(json!({"type":"snapshot","generation":generation,"state":state}))
                }
                Event::Discovery { owned } => emit(json!({"type":"discovery","owned":owned})),
                Event::Agent(AgentEvent::Prompt(p)) => emit(
                    json!({"type":"prompt","id":p.id,"request":p.request,"device":p.device,"code":p.code}),
                ),
                Event::Agent(AgentEvent::Cleared) => emit(json!({"type":"cleared"})),
                Event::Agent(AgentEvent::OwnerReset(reset)) => emit(
                    json!({"type":"owner-reset","failed":reset.failed_request,"cancelPrompt":reset.cancel_prompt}),
                ),
                Event::Agent(AgentEvent::PairCanceled { request, device }) => {
                    emit(json!({"type":"canceled","request":request,"device":device}))
                }
                Event::Agent(AgentEvent::Released) => emit(json!({"type":"released"})),
                Event::PairResult {
                    request,
                    success,
                    phase,
                    error,
                } => emit(
                    json!({"type":"pair-result","id":request,"success":success,"phase":phase,"error":error}),
                ),
                Event::DeviceResult {
                    request,
                    success,
                    phase,
                    error,
                } => emit(
                    json!({"type":"device-result","id":request,"success":success,"phase":phase,"error":error}),
                ),
                Event::PowerResult {
                    request,
                    success,
                    phase,
                    error,
                } => emit(
                    json!({"type":"power-result","id":request,"success":success,"phase":phase,"error":error}),
                ),
                Event::Error(message) => emit(json!({"type":"error","message":message})),
                Event::CloseConnection => {
                    host.session.take();
                    emit(json!({"type":"closed"}));
                }
            }
        }
        1
    }
}
fn main() {
    if std::env::var_os("DBUS_SYSTEM_BUS_ADDRESS").is_none() {
        eprintln!("test bus is required");
        std::process::exit(1);
    }
    unsafe {
        let mut error = ptr::null_mut();
        let bus = gio::g_bus_get_sync(1, ptr::null_mut(), &mut error);
        if bus.is_null() {
            eprintln!("{}", gio::error(error));
            std::process::exit(1);
        }
        let (tx, rx) = mpsc::channel();
        let pair_timeout = std::env::var("MACSHELL_TEST_PAIR_TIMEOUT_MS")
            .ok()
            .map(|v| v.parse().expect("invalid test pair timeout"))
            .unwrap_or(60_000);
        let device_timeout = std::env::var("MACSHELL_TEST_DEVICE_TIMEOUT_MS")
            .ok()
            .map(|v| v.parse().expect("invalid test device timeout"))
            .unwrap_or(20_000);
        let session = Session::new_with_timeouts(bus, tx, pair_timeout, device_timeout)
            .expect("create session");
        if let Ok(mode) = std::env::var("MACSHELL_TEST_RADIO") {
            session.set_radio_unblocker(Box::new(move || {
                emit(json!({"type":"radio-unblock"}));
                if mode == "deny" {
                    Err("Synthetic radio denial".into())
                } else {
                    Ok(())
                }
            }));
        }
        let loop_ = gio::g_main_loop_new(ptr::null_mut(), 0);
        let mut host = Box::new(Harness {
            bus,
            session: Some(session),
            events: rx,
            loop_,
            input: Vec::new(),
            polling: true,
        });
        let data = (&mut *host as *mut Harness).cast();
        let fd = gio::g_unix_fd_add(
            libc::STDIN_FILENO,
            (libc::POLLIN | libc::POLLHUP) as u32,
            Some(input),
            data,
        );
        let timer = gio::g_timeout_add(10, Some(events), data);
        emit(
            json!({"type":"ready","unique":gio::text(gio::g_dbus_connection_get_unique_name(host.bus))}),
        );
        gio::g_main_loop_run(loop_);
        let context = gio::g_main_context_default();
        for id in [fd, timer] {
            let source = gio::g_main_context_find_source_by_id(context, id);
            if !source.is_null() {
                gio::g_source_destroy(source);
            }
        }
        drop(host);
        gio::g_main_loop_unref(loop_);
        gio::g_object_unref(bus);
    }
}
