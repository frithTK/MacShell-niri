//! Test harness: exports Agent1 on a bus explicitly supplied by the test.
use macshell_bluetooth_core::pairing::{Reply, Ticket};
use macshell_bluez_agent::{Agent, Event};
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use serde_json::{json, Value};
use std::io::{self, Write};
use std::ptr;
use std::sync::mpsc::{self, Receiver};

struct Host {
    agent: Agent,
    rx: Receiver<Event>,
    loop_: Ptr,
    buffer: Vec<u8>,
    ticket: Option<Ticket>,
}
fn emit(value: Value) {
    let stdout = io::stdout();
    let mut output = stdout.lock();
    let _ = serde_json::to_writer(&mut output, &value);
    let _ = output.write_all(b"\n");
    let _ = output.flush();
}
fn reply_name(reply: &Reply) -> &str {
    match reply {
        Reply::Ignored => "ignored",
        Reply::Accepted => "accepted",
        Reply::Pin(_) => "pin",
        Reply::Passkey(_) => "passkey",
        Reply::Cancel { .. } => "cancel",
    }
}
extern "C" fn input(fd: i32, _: u32, data: Ptr) -> i32 {
    unsafe {
        let host = &mut *data.cast::<Host>();
        let mut bytes = [0u8; 8192];
        let n = libc::read(fd, bytes.as_mut_ptr().cast(), bytes.len());
        if n <= 0 {
            gio::g_main_loop_quit(host.loop_);
            return 0;
        }
        host.buffer.extend_from_slice(&bytes[..n as usize]);
        while let Some(end) = host.buffer.iter().position(|v| *v == b'\n') {
            let line: Vec<_> = host.buffer.drain(..=end).collect();
            let Ok(request) = serde_json::from_slice::<Value>(&line) else {
                continue;
            };
            let result = match request["action"].as_str().unwrap_or("") {
                "begin" => match host.agent.begin(
                    request["id"].as_u64().unwrap_or(0),
                    request["device"].as_str().unwrap_or(""),
                    "Keyboard",
                    0,
                ) {
                    Ok(ticket) => {
                        host.ticket = Some(ticket);
                        json!({"type":"begun","epoch":ticket.epoch,"operation":ticket.operation})
                    }
                    Err(error) => json!({"type":"error","error":error}),
                },
                "respond" => match host.agent.respond(
                    request["prompt"].as_u64().unwrap_or(0),
                    request["accept"].as_bool().unwrap_or(false),
                    request["value"].as_str().unwrap_or(""),
                ) {
                    Ok(reply) => json!({"type":"response","result":reply_name(&reply)}),
                    Err(error) => json!({"type":"error","error":error}),
                },
                "cancel" => {
                    json!({"type":"cancel","result":host.agent.cancel(request["id"].as_u64().unwrap_or(0)).map(|r|reply_name(&r).to_owned())})
                }
                "reset" => {
                    host.agent.owner_changed(request["owner"].as_str());
                    json!({"type":"reset"})
                }
                "paired" => {
                    let step = host.ticket.map(|t| {
                        host.agent
                            .paired(t, request["confirmed"].as_bool().unwrap_or(false))
                    });
                    json!({"type":"paired","step":format!("{step:?}")})
                }
                _ => json!({"type":"error","error":"unknown command"}),
            };
            emit(result);
        }
        1
    }
}
extern "C" fn events(data: Ptr) -> i32 {
    unsafe {
        let host = &mut *data.cast::<Host>();
        while let Ok(event) = host.rx.try_recv() {
            match event {
                Event::Prompt(p) => emit(
                    json!({"type":"prompt","id":p.id,"request":p.request,"device":p.device,"name":p.name,"method":p.method,"code":p.code,"entered":p.entered,"service":p.service,"deferred":p.deferred}),
                ),
                Event::Cleared => emit(json!({"type":"cleared"})),
                Event::PairCanceled { request, device } => {
                    emit(json!({"type":"canceled","request":request,"device":device}))
                }
                Event::OwnerReset(reset) => emit(
                    json!({"type":"owner-reset","failed":reset.failed_request,"cancelPrompt":reset.cancel_prompt}),
                ),
                Event::Released => emit(json!({"type":"released"})),
            }
        }
        1
    }
}
fn main() {
    // Fail closed: a caller must explicitly supply its private test bus.
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
        let owner_reply = gio::g_dbus_connection_call_sync(
            bus,
            c("org.freedesktop.DBus").as_ptr(),
            c("/org/freedesktop/DBus").as_ptr(),
            c("org.freedesktop.DBus").as_ptr(),
            c("GetNameOwner").as_ptr(),
            gio::tuple(&[gio::string("org.bluez")]),
            ptr::null_mut(),
            0,
            2000,
            ptr::null_mut(),
            &mut error,
        );
        let Some(owner) = Variant::from(owner_reply)
            .and_then(|v| v.child(0))
            .and_then(|v| v.string())
        else {
            eprintln!("No fake BlueZ owner");
            std::process::exit(1);
        };
        let (tx, rx) = mpsc::channel();
        let mut agent = Agent::new(bus, tx).expect("register Agent1");
        agent.owner_changed(Some(&owner));
        agent.registered(agent.epoch(), true);
        let loop_ = gio::g_main_loop_new(ptr::null_mut(), 0);
        let unique = gio::text(gio::g_dbus_connection_get_unique_name(bus));
        let mut host = Box::new(Host {
            agent,
            rx,
            loop_,
            buffer: Vec::new(),
            ticket: None,
        });
        let data = (&mut *host as *mut Host).cast();
        let fd = gio::g_unix_fd_add(
            libc::STDIN_FILENO,
            (libc::POLLIN | libc::POLLHUP) as u32,
            Some(input),
            data,
        );
        let timer = gio::g_timeout_add(10, Some(events), data);
        emit(json!({"type":"ready","unique":unique,"owner":owner}));
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
