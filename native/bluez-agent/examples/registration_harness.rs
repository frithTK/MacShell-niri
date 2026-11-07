//! Test-only BlueZ owner/registration harness on an explicitly supplied bus.
use macshell_bluez_agent::host::{AgentHost, HostEvent};
use macshell_bluez_agent::Event;
use macshell_gio_bridge::{self as gio, Ptr};
use serde_json::{json, Value};
use std::io::{self, Write};
use std::ptr;
use std::sync::mpsc::{self, Receiver};

struct Harness {
    host: Option<AgentHost>,
    agent_events: Receiver<Event>,
    events: Receiver<HostEvent>,
    loop_: Ptr,
    input: Vec<u8>,
}
fn emit(value: Value) {
    let stdout = io::stdout();
    let mut out = stdout.lock();
    let _ = serde_json::to_writer(&mut out, &value);
    let _ = out.write_all(b"\n");
    let _ = out.flush();
}
extern "C" fn input(fd: i32, _: u32, data: Ptr) -> i32 {
    unsafe {
        let harness = &mut *data.cast::<Harness>();
        let mut bytes = [0u8; 4096];
        let size = libc::read(fd, bytes.as_mut_ptr().cast(), bytes.len());
        if size <= 0 {
            gio::g_main_loop_quit(harness.loop_);
            return 0;
        }
        harness.input.extend_from_slice(&bytes[..size as usize]);
        while let Some(end) = harness.input.iter().position(|v| *v == b'\n') {
            let bytes: Vec<_> = harness.input.drain(..=end).collect();
            let Ok(request) = serde_json::from_slice::<Value>(&bytes) else {
                continue;
            };
            match request["action"].as_str() {
                Some("begin") => {
                    let result = harness.host.as_ref().expect("host").with_agent(|agent| {
                        agent.begin(1, "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF", "Keyboard", 0)
                    });
                    emit(json!({"type":"begin","ok":result.is_ok()}));
                }
                Some("ping") => emit(json!({"type":"pong"})),
                Some("drop") => {
                    harness.host.take();
                    emit(json!({"type":"dropped"}));
                }
                _ => (),
            }
        }
        1
    }
}
extern "C" fn events(data: Ptr) -> i32 {
    unsafe {
        let harness = &mut *data.cast::<Harness>();
        while harness.agent_events.try_recv().is_ok() {}
        while let Ok(event) = harness.events.try_recv() {
            match event {
                HostEvent::Owner { unique, epoch } => {
                    emit(json!({"type":"owner","unique":unique,"epoch":epoch}))
                }
                HostEvent::Registration { epoch, success } => {
                    emit(json!({"type":"registration","epoch":epoch,"success":success}))
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
        let (agent_tx, agent_events) = mpsc::channel();
        let (tx, events_rx) = mpsc::channel();
        let host = AgentHost::new(bus, agent_tx, tx).expect("create host");
        let loop_ = gio::g_main_loop_new(ptr::null_mut(), 0);
        let mut harness = Box::new(Harness {
            host: Some(host),
            agent_events,
            events: events_rx,
            loop_,
            input: Vec::new(),
        });
        let data = (&mut *harness as *mut Harness).cast();
        let fd = gio::g_unix_fd_add(
            libc::STDIN_FILENO,
            (libc::POLLIN | libc::POLLHUP) as u32,
            Some(input),
            data,
        );
        let timer = gio::g_timeout_add(10, Some(events), data);
        emit(
            json!({"type":"ready","unique":gio::text(gio::g_dbus_connection_get_unique_name(bus))}),
        );
        gio::g_main_loop_run(loop_);
        let context = gio::g_main_context_default();
        for id in [fd, timer] {
            let source = gio::g_main_context_find_source_by_id(context, id);
            if !source.is_null() {
                gio::g_source_destroy(source);
            }
        }
        drop(harness);
        gio::g_main_loop_unref(loop_);
        gio::g_object_unref(bus);
    }
}
