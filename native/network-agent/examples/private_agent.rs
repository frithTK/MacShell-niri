//! Test-only SecretAgent harness. An explicit private bus is required.
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use macshell_network_agent::{Agent, Event};
use macshell_network_core::secret_agent::Ticket;
use serde_json::{json, Value};
use std::io::{self, Write};
use std::ptr;
use std::sync::mpsc::{self, Receiver};

struct Host {
    agent: Option<Agent>,
    events: Option<Receiver<Event>>,
    loop_: Ptr,
    buffer: Vec<u8>,
    ticket: Option<Ticket>,
    previous: Option<Ticket>,
}
fn emit(value: Value) {
    let mut out = io::stdout().lock();
    let _ = serde_json::to_writer(&mut out, &value);
    let _ = out.write_all(b"\n");
    let _ = out.flush();
}
extern "C" fn input(fd: i32, _: u32, data: Ptr) -> i32 {
    unsafe {
        let host = &mut *data.cast::<Host>();
        let mut bytes = [0u8; 4096];
        let n = libc::read(fd, bytes.as_mut_ptr().cast(), bytes.len());
        if n <= 0 {
            gio::g_main_loop_quit(host.loop_);
            return 0;
        }
        host.buffer.extend_from_slice(&bytes[..n as usize]);
        if host.buffer.len() > 65536 {
            gio::g_main_loop_quit(host.loop_);
            return 0;
        }
        while let Some(end) = host.buffer.iter().position(|v| *v == b'\n') {
            let line: Vec<_> = host.buffer.drain(..=end).collect();
            let Ok(request) = serde_json::from_slice::<Value>(&line) else {
                continue;
            };
            let Some(agent) = host.agent.as_mut() else {
                emit(json!({"type":"error","error":"dropped"}));
                continue;
            };
            let value = match request["action"].as_str() {
                Some("begin") => match agent.begin(
                    request["id"].as_u64().unwrap_or(0),
                    request["uuid"].as_str().unwrap_or(""),
                    request["profile"].as_str(),
                    request["provided"].as_bool().unwrap_or(false),
                ) {
                    Ok(ticket) => {
                        host.previous = host.ticket.replace(ticket);
                        json!({"type":"begun"})
                    }
                    Err(error) => json!({"type":"error","error":error}),
                },
                Some("reply") => {
                    let ticket = if request["stale"].as_bool().unwrap_or(false) {
                        host.previous
                    } else {
                        host.ticket
                    };
                    match ticket.map(|ticket| {
                        agent.reply(
                            ticket,
                            request["delivery"].as_u64().unwrap_or(0),
                            request["password"].as_str().unwrap_or(""),
                        )
                    }) {
                        Some(Ok(ok)) => json!({"type":"reply","accepted":ok}),
                        Some(Err(error)) => json!({"type":"error","error":error}),
                        None => json!({"type":"reply","accepted":false}),
                    }
                }
                Some("finish") => {
                    let result = host.ticket.and_then(|ticket| {
                        agent.finish(ticket, request["user"].as_bool().unwrap_or(false))
                    });
                    json!({"type":"finished","found":result.is_some(),"cancelPrompt":result.map(|r|r.cancel_prompt)})
                }
                Some("reset") => match agent.owner_changed(request["owner"].as_str()) {
                    Ok(reset) => {
                        json!({"type":"reset","epoch":agent.epoch(),"request":reset.request,"cancelPrompt":reset.cancel_prompt})
                    }
                    Err(error) => json!({"type":"error","error":error}),
                },
                Some("register") => {
                    json!({"type":"registered","accepted":agent.registered(request["epoch"].as_u64().unwrap_or(agent.epoch()), request["success"].as_bool().unwrap_or(true))})
                }
                Some("drop") => {
                    host.agent.take();
                    json!({"type":"dropped"})
                }
                Some("drop-events") => {
                    host.events.take();
                    json!({"type":"events-dropped"})
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
        let host = &mut *data.cast::<Host>();
        let Some(receiver) = host.events.as_ref() else {
            return 1;
        };
        while let Ok(event) = receiver.try_recv() {
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
    if std::env::var_os("DBUS_SYSTEM_BUS_ADDRESS").is_none() {
        std::process::exit(2);
    }
    unsafe {
        let mut error = ptr::null_mut();
        let bus = gio::g_bus_get_sync(1, ptr::null_mut(), &mut error);
        if bus.is_null() {
            if !error.is_null() {
                gio::g_error_free(error);
            }
            std::process::exit(2);
        }
        let reply = gio::g_dbus_connection_call_sync(
            bus,
            c("org.freedesktop.DBus").as_ptr(),
            c("/org/freedesktop/DBus").as_ptr(),
            c("org.freedesktop.DBus").as_ptr(),
            c("GetNameOwner").as_ptr(),
            gio::tuple(&[gio::string("org.freedesktop.NetworkManager")]),
            ptr::null_mut(),
            0,
            1000,
            ptr::null_mut(),
            &mut error,
        );
        let owner = Variant::from(reply)
            .and_then(|v| v.child(0))
            .and_then(|v| v.string());
        if !error.is_null() {
            gio::g_error_free(error);
        }
        let Some(owner) = owner else {
            gio::g_object_unref(bus);
            std::process::exit(2)
        };
        let (tx, rx) = mpsc::channel();
        let mut agent = Agent::new(bus, tx).expect("test agent");
        agent.owner_changed(Some(&owner)).expect("test owner");
        agent.registered(agent.epoch(), true);
        let loop_ = gio::g_main_loop_new(ptr::null_mut(), 0);
        let unique = gio::text(gio::g_dbus_connection_get_unique_name(bus));
        let mut host = Box::new(Host {
            agent: Some(agent),
            events: Some(rx),
            loop_,
            buffer: Vec::new(),
            ticket: None,
            previous: None,
        });
        let data = (&mut *host as *mut Host).cast();
        let fd = gio::g_unix_fd_add(
            libc::STDIN_FILENO,
            (libc::POLLIN | libc::POLLHUP) as u32,
            Some(input),
            data,
        );
        let timer = gio::g_timeout_add(10, Some(events), data);
        emit(
            json!({"type":"ready","unique":unique,"owner":owner,"epoch":host.agent.as_ref().unwrap().epoch()}),
        );
        gio::g_main_loop_run(loop_);
        for id in [fd, timer] {
            let source = gio::g_main_context_find_source_by_id(gio::g_main_context_default(), id);
            if !source.is_null() {
                gio::g_source_destroy(source);
            }
        }
        host.agent.take();
        gio::g_object_unref(bus);
        gio::g_main_loop_unref(loop_);
    }
}
