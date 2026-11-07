//! Test-only harness. Requires an explicit private session bus.
use macshell_capture_session::{Event, Session};
use macshell_gio_bridge::{self as gio, Ptr};
use serde_json::{json, Value};
use std::io::{self, Write};
use std::ptr;
use std::sync::mpsc::{self, Receiver};

struct Harness {
    address: String,
    session: Option<Session>,
    tx: mpsc::Sender<Event>,
    rx: Receiver<Event>,
    buffer: Vec<u8>,
    loop_: Ptr,
}
fn emit(value: Value) {
    let mut out = io::stdout().lock();
    serde_json::to_writer(&mut out, &value).unwrap();
    writeln!(out).unwrap();
    out.flush().unwrap();
}
extern "C" fn input(fd: i32, _: u32, data: Ptr) -> i32 {
    unsafe {
        let h = &mut *data.cast::<Harness>();
        let mut bytes = [0u8; 4096];
        let n = libc::read(fd, bytes.as_mut_ptr().cast(), bytes.len());
        if n <= 0 {
            gio::g_main_loop_quit(h.loop_);
            return 0;
        }
        h.buffer.extend_from_slice(&bytes[..n as usize]);
        if h.buffer.len() > 65536 {
            gio::g_main_loop_quit(h.loop_);
            return 0;
        }
        while let Some(end) = h.buffer.iter().position(|b| *b == b'\n') {
            let line: Vec<_> = h.buffer.drain(..=end).collect();
            let Ok(value) = serde_json::from_slice::<Value>(&line) else {
                continue;
            };
            match value["action"].as_str() {
                Some("start") => {
                    if h.session.is_some() {
                        emit(json!({"type":"error","error":"busy"}));
                        continue;
                    }
                    match Session::start(
                        &h.address,
                        value["window"].as_u64().unwrap_or(0),
                        value["token"].as_u64().unwrap_or(0),
                        h.tx.clone(),
                    ) {
                        Ok(session) => {
                            h.session = Some(session);
                            emit(json!({"type":"started"}));
                        }
                        Err(error) => emit(json!({"type":"error","error":error})),
                    }
                }
                Some("stop") => {
                    h.session.take();
                    emit(json!({"type":"stopped"}));
                }
                _ => (),
            }
        }
        1
    }
}
extern "C" fn tick(data: Ptr) -> i32 {
    unsafe {
        let h = &mut *data.cast::<Harness>();
        while let Ok(event) = h.rx.try_recv() {
            match event {
                Event::Node { token, node } => {
                    emit(json!({"type":"node","token":token,"node":node}))
                }
                Event::Changed { token } => emit(json!({"type":"changed","token":token})),
                Event::OwnerLost { token } => emit(json!({"type":"lost","token":token})),
            }
        }
        1
    }
}
fn main() {
    let address = std::env::var("DBUS_SESSION_BUS_ADDRESS")
        .ok()
        .filter(|s| !s.is_empty() && !s.contains('\0'))
        .expect("explicit private bus required");
    unsafe {
        let loop_ = gio::g_main_loop_new(ptr::null_mut(), 0);
        let (tx, rx) = mpsc::channel();
        let mut h = Box::new(Harness {
            address,
            session: None,
            tx,
            rx,
            buffer: Vec::new(),
            loop_,
        });
        let data = (&mut *h as *mut Harness).cast();
        let fd = gio::g_unix_fd_add(
            libc::STDIN_FILENO,
            (libc::POLLIN | libc::POLLHUP) as u32,
            Some(input),
            data,
        );
        let timer = gio::g_timeout_add(10, Some(tick), data);
        emit(json!({"type":"ready"}));
        gio::g_main_loop_run(loop_);
        for id in [fd, timer] {
            let source = gio::g_main_context_find_source_by_id(gio::g_main_context_default(), id);
            if !source.is_null() {
                gio::g_source_destroy(source);
            }
        }
        drop(h);
        gio::g_main_loop_unref(loop_);
    }
}
