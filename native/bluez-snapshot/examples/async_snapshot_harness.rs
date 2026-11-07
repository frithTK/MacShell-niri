//! Exercise the asynchronous reader on an explicitly supplied private bus.
use macshell_bluez_snapshot::reader::{Event, SnapshotReader};
use macshell_gio_bridge::{self as gio, Ptr};
use serde_json::{json, Value};
use std::io::{self, Write};
use std::ptr;
use std::sync::mpsc::{self, Receiver};

struct Harness {
    reader: Option<SnapshotReader>,
    events: Receiver<Event>,
    loop_: Ptr,
    input: Vec<u8>,
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
            let Ok(value) = serde_json::from_slice::<Value>(&bytes) else {
                continue;
            };
            match value["action"].as_str() {
                Some("owner") => {
                    let result = host
                        .reader
                        .as_ref()
                        .unwrap()
                        .owner_changed(value["owner"].as_str());
                    emit(match result {
                        Ok(epoch) => json!({"type":"owner","epoch":epoch}),
                        Err(error) => json!({"type":"error","message":error}),
                    });
                }
                Some("refresh") => {
                    let result = host.reader.as_ref().unwrap().refresh();
                    emit(match result {
                        Ok(result) => json!({"type":"refresh","result":format!("{result:?}")}),
                        Err(error) => json!({"type":"error","message":error}),
                    });
                }
                Some("drop") => {
                    host.reader.take();
                    emit(json!({"type":"dropped"}));
                }
                Some("ping") => emit(json!({"type":"pong"})),
                _ => (),
            }
        }
        1
    }
}
extern "C" fn events(data: Ptr) -> i32 {
    unsafe {
        let host = &mut *data.cast::<Harness>();
        while let Ok(event) = host.events.try_recv() {
            match event {
                Event::Snapshot { epoch, state } => {
                    emit(json!({"type":"snapshot","epoch":epoch,"state":state}))
                }
                Event::Error { epoch, message } => {
                    emit(json!({"type":"snapshot-error","epoch":epoch,"message":message}))
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
        let (tx, events_rx) = mpsc::channel();
        let reader = SnapshotReader::new(bus, tx).expect("create reader");
        let loop_ = gio::g_main_loop_new(ptr::null_mut(), 0);
        let mut host = Box::new(Harness {
            reader: Some(reader),
            events: events_rx,
            loop_,
            input: Vec::new(),
        });
        let data = (&mut *host as *mut Harness).cast();
        let fd = gio::g_unix_fd_add(
            libc::STDIN_FILENO,
            (libc::POLLIN | libc::POLLHUP) as u32,
            Some(input),
            data,
        );
        let timer = gio::g_timeout_add(10, Some(events), data);
        emit(json!({"type":"ready"}));
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
