//! Test-only owner watcher and registration harness on an explicit private bus.
use macshell_gio_bridge::{self as gio, c, Ptr};
use macshell_network_agent::{
    host::{AgentHost, HostEvent},
    Event,
};
use macshell_network_core::secret_agent::Ticket;
use serde_json::{json, Value};
use std::io::{self, Write};
use std::ptr;
use std::sync::mpsc::{self, Receiver};

struct Harness {
    host: Option<AgentHost>,
    host_events: Receiver<HostEvent>,
    agent_events: Receiver<Event>,
    loop_: Ptr,
    buffer: Vec<u8>,
    ticket: Option<Ticket>,
}
fn emit(value: Value) {
    let mut out = io::stdout().lock();
    let _ = serde_json::to_writer(&mut out, &value);
    let _ = out.write_all(b"\n");
    let _ = out.flush();
}
extern "C" fn input(fd: i32, _: u32, data: Ptr) -> i32 {
    unsafe {
        let harness = &mut *data.cast::<Harness>();
        let mut bytes = [0u8; 4096];
        let n = libc::read(fd, bytes.as_mut_ptr().cast(), bytes.len());
        if n <= 0 {
            gio::g_main_loop_quit(harness.loop_);
            return 0;
        }
        harness.buffer.extend_from_slice(&bytes[..n as usize]);
        if harness.buffer.len() > 65536 {
            gio::g_main_loop_quit(harness.loop_);
            return 0;
        }
        while let Some(end) = harness.buffer.iter().position(|v| *v == b'\n') {
            let line: Vec<_> = harness.buffer.drain(..=end).collect();
            let Ok(request) = serde_json::from_slice::<Value>(&line) else {
                continue;
            };
            let Some(host) = harness.host.as_ref() else {
                emit(json!({"type":"error","error":"dropped"}));
                continue;
            };
            let value = match request["action"].as_str() {
                Some("begin") => {
                    let result = host.with_agent(|a| {
                        a.begin(
                            request["id"].as_u64().unwrap_or(0),
                            request["uuid"].as_str().unwrap_or(""),
                            request["profile"].as_str(),
                            false,
                        )
                    });
                    match result {
                        Ok(ticket) => {
                            harness.ticket = Some(ticket);
                            json!({"type":"begun"})
                        }
                        Err(error) => json!({"type":"error","error":error}),
                    }
                }
                Some("reply") => {
                    let value = harness.ticket.map(|ticket| {
                        host.with_agent(|a| {
                            a.reply(
                                ticket,
                                request["delivery"].as_u64().unwrap_or(0),
                                request["password"].as_str().unwrap_or(""),
                            )
                        })
                    });
                    match value {
                        Some(Ok(accepted)) => json!({"type":"reply","accepted":accepted}),
                        Some(Err(error)) => json!({"type":"error","error":error}),
                        None => json!({"type":"reply","accepted":false}),
                    }
                }
                _ => json!({"type":"error","error":"unknown command"}),
            };
            emit(value);
        }
        1
    }
}
extern "C" fn events(data: Ptr) -> i32 {
    unsafe {
        let h = &mut *data.cast::<Harness>();
        while let Ok(event) = h.host_events.try_recv() {
            match event {
                HostEvent::Owner {
                    unique,
                    epoch,
                    abandoned,
                } => emit(
                    json!({"type":"owner","unique":unique,"epoch":epoch,"abandoned":abandoned}),
                ),
                HostEvent::Registration { epoch, success } => {
                    emit(json!({"type":"registration","epoch":epoch,"success":success}))
                }
                HostEvent::CloseConnection => emit(json!({"type":"close"})),
            }
        }
        while let Ok(event) = h.agent_events.try_recv() {
            match event {
                Event::NeedSecret {
                    request,
                    delivery,
                    provided,
                    discard_provided,
                } => emit(
                    json!({"type":"need","request":request,"delivery":delivery,"provided":provided,"discard":discard_provided}),
                ),
                Event::Canceled { request, delivery } => {
                    emit(json!({"type":"canceled","request":request,"delivery":delivery}))
                }
                Event::Cleared { request, delivery } => {
                    emit(json!({"type":"cleared","request":request,"delivery":delivery}))
                }
            }
        }
        1
    }
}
fn main() {
    let Some(address) = std::env::var_os("DBUS_SYSTEM_BUS_ADDRESS") else {
        std::process::exit(2)
    };
    let Some(address) = address
        .to_str()
        .filter(|s| !s.is_empty() && !s.contains('\0'))
    else {
        std::process::exit(2)
    };
    unsafe {
        let mut error = ptr::null_mut();
        let bus = gio::g_dbus_connection_new_for_address_sync(
            c(address).as_ptr(),
            9,
            ptr::null_mut(),
            ptr::null_mut(),
            &mut error,
        );
        if bus.is_null() {
            if !error.is_null() {
                gio::g_error_free(error);
            }
            std::process::exit(2);
        }
        gio::g_dbus_connection_set_exit_on_close(bus, 0);
        let (agent_tx, agent_rx) = mpsc::channel();
        let (host_tx, host_rx) = mpsc::channel();
        let timeout = std::env::var("MACSHELL_TEST_NM_REGISTER_TIMEOUT")
            .ok()
            .map(|v| v.parse().expect("timeout"))
            .unwrap_or(5000);
        let host = AgentHost::new_with_timeout(bus, agent_tx, host_tx, timeout).expect("test host");
        let loop_ = gio::g_main_loop_new(ptr::null_mut(), 0);
        let unique = gio::text(gio::g_dbus_connection_get_unique_name(bus));
        let mut h = Box::new(Harness {
            host: Some(host),
            host_events: host_rx,
            agent_events: agent_rx,
            loop_,
            buffer: Vec::new(),
            ticket: None,
        });
        let data = (&mut *h as *mut Harness).cast();
        let fd = gio::g_unix_fd_add(
            libc::STDIN_FILENO,
            (libc::POLLIN | libc::POLLHUP) as u32,
            Some(input),
            data,
        );
        let timer = gio::g_timeout_add(10, Some(events), data);
        emit(json!({"type":"ready","unique":unique}));
        gio::g_main_loop_run(loop_);
        for id in [fd, timer] {
            let source = gio::g_main_context_find_source_by_id(gio::g_main_context_default(), id);
            if !source.is_null() {
                gio::g_source_destroy(source);
            }
        }
        h.host.take();
        let mut close_error = ptr::null_mut();
        gio::g_dbus_connection_close_sync(bus, ptr::null_mut(), &mut close_error);
        if !close_error.is_null() {
            gio::g_error_free(close_error);
        }
        gio::g_object_unref(bus);
        gio::g_main_loop_unref(loop_);
    }
}
