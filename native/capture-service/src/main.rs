//! Experimental capture worker; not installed or selected by default.
use macshell_capture_service::{Factory, Manager, Video};
use macshell_capture_stream::Pipeline;
use macshell_gio_bridge::{self as gio, Ptr};
use serde_json::{json, Value};
use std::io::{self, Write};
use std::path::PathBuf;
use std::ptr;

struct Service {
    manager: Manager,
    loop_: Ptr,
    buffer: Vec<u8>,
    closed: bool,
}
fn emit(value: Value) -> bool {
    let mut out = io::stdout().lock();
    serde_json::to_writer(&mut out, &value).is_ok() && writeln!(out).is_ok() && out.flush().is_ok()
}
impl Service {
    fn flush(&mut self) {
        for value in self.manager.take_output() {
            if !emit(value) {
                self.closed = true;
                unsafe {
                    gio::g_main_loop_quit(self.loop_);
                }
                break;
            }
        }
    }
}
extern "C" fn input(fd: i32, _: u32, data: Ptr) -> i32 {
    unsafe {
        let service = &mut *data.cast::<Service>();
        let mut bytes = [0u8; 8192];
        let n = libc::read(fd, bytes.as_mut_ptr().cast(), bytes.len());
        if n <= 0 {
            service.closed = true;
            gio::g_main_loop_quit(service.loop_);
            return 0;
        }
        service.buffer.extend_from_slice(&bytes[..n as usize]);
        if service.buffer.len() > 65536 {
            service.closed = true;
            gio::g_main_loop_quit(service.loop_);
            return 0;
        }
        while let Some(end) = service.buffer.iter().position(|v| *v == b'\n') {
            let line: Vec<_> = service.buffer.drain(..=end).collect();
            if let Ok(value) = serde_json::from_slice::<Value>(&line) {
                if let Some(id) = value.get("id").and_then(Value::as_u64).filter(|v| *v > 0) {
                    service.manager.request(id);
                }
            }
            service.flush();
            if service.closed {
                return 0;
            }
        }
        1
    }
}
extern "C" fn tick(data: Ptr) -> i32 {
    unsafe {
        let service = &mut *data.cast::<Service>();
        service.manager.tick();
        service.flush();
        if service.closed {
            0
        } else {
            1
        }
    }
}
extern "C" fn shutdown(data: Ptr) -> i32 {
    unsafe {
        let s = &mut *data.cast::<Service>();
        s.closed = true;
        gio::g_main_loop_quit(s.loop_);
    }
    0
}
fn setting(key: &str, default: u32, min: u32, max: u32) -> u32 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .unwrap_or(default)
        .clamp(min, max)
}
unsafe fn run() -> Result<(), &'static str> {
    let mut error = ptr::null_mut();
    let address = gio::g_dbus_address_get_for_bus_sync(2, ptr::null_mut(), &mut error);
    if address.is_null() {
        if !error.is_null() {
            gio::g_error_free(error);
        }
        return Err("Cannot connect to the session bus.");
    }
    let address_text = gio::text(address);
    gio::g_free(address.cast());
    let parent = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let fps = setting("MACSHELL_CAPTURE_FPS", 5, 1, 10);
    let width = setting("MACSHELL_CAPTURE_WIDTH", 512, 160, 1024);
    let limit = setting("MACSHELL_CAPTURE_LIMIT", 6, 1, 12) as usize;
    let factory: Factory = Box::new(|node, size| {
        Pipeline::pipewire(node, size).map(|v| Box::new(v) as Box<dyn Video>)
    });
    let manager = Manager::new(address_text, &parent, limit, width, fps, factory)?;
    let loop_ = gio::g_main_loop_new(ptr::null_mut(), 0);
    let mut service = Box::new(Service {
        manager,
        loop_,
        buffer: Vec::new(),
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
    for id in [fd, timer, term, interrupt] {
        let source = gio::g_main_context_find_source_by_id(gio::g_main_context_default(), id);
        if !source.is_null() {
            gio::g_source_destroy(source);
        }
    }
    drop(service);
    gio::g_main_loop_unref(loop_);
    Ok(())
}
fn main() {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args == ["--protocol-version"] {
        if !macshell_capture_stream::available() {
            std::process::exit(1);
        }
        println!("macshell-capture 1");
        return;
    }
    if !args.is_empty() {
        std::process::exit(1);
    }
    if let Err(error) = unsafe { run() } {
        let _ = emit(json!({"fatal":true,"error":error}));
        std::process::exit(1);
    }
}
