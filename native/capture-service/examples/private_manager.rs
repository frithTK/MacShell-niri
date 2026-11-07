//! Synthetic video + explicit private D-Bus. Never reads a screen or PipeWire.
use macshell_capture_service::{Factory, Manager, Video};
use macshell_capture_stream::{Frame, Pipeline};
use macshell_gio_bridge::{self as gio, Ptr};
use serde_json::{json, Value};
use std::io::{self, Write};
use std::path::PathBuf;
use std::ptr;

struct Harness {
    manager: Manager,
    loop_: Ptr,
    buffer: Vec<u8>,
}
struct DelayedVideo {
    pipeline: Pipeline,
    waiting: bool,
}
impl Video for DelayedVideo {
    fn poll(&mut self) -> Result<Option<Frame>, &'static str> {
        if self.waiting {
            Ok(None)
        } else {
            self.pipeline.poll()
        }
    }
    fn pause(&mut self) -> Result<(), &'static str> {
        self.pipeline.pause()
    }
    fn resume(&mut self) -> Result<(), &'static str> {
        self.pipeline.resume()
    }
    fn restart(&mut self) -> Result<(), &'static str> {
        self.pipeline.restart()?;
        self.waiting = false;
        Ok(())
    }
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
            if let Ok(value) = serde_json::from_slice::<Value>(&line) {
                if let Some(id) = value["id"].as_u64() {
                    h.manager.request(id);
                }
            }
        }
        1
    }
}
extern "C" fn tick(data: Ptr) -> i32 {
    unsafe {
        let h = &mut *data.cast::<Harness>();
        h.manager.tick();
        for value in h.manager.take_output() {
            emit(value);
        }
        1
    }
}
fn main() {
    if std::env::args_os().skip(1).collect::<Vec<_>>() == ["--protocol-version"] {
        println!("macshell-capture 1");
        return;
    }
    let address = std::env::var("DBUS_SESSION_BUS_ADDRESS")
        .ok()
        .filter(|s| !s.is_empty())
        .expect("private bus required");
    let parent = PathBuf::from(
        std::env::var_os("MACSHELL_TEST_CAPTURE_PARENT").expect("test directory required"),
    );
    let factory: Factory = Box::new(|node, size| {
        if node == 42 {
            Pipeline::synthetic(size).map(|v| {
                Box::new(DelayedVideo {
                    pipeline: v,
                    waiting: std::env::var_os("MACSHELL_TEST_CAPTURE_DELAY_FIRST_FRAME").is_some(),
                }) as Box<dyn Video>
            })
        } else {
            Err("synthetic node rejected")
        }
    });
    unsafe {
        let manager = Manager::new(address, &parent, 1, 160, 10, factory).expect("test manager");
        let loop_ = gio::g_main_loop_new(ptr::null_mut(), 0);
        let mut h = Box::new(Harness {
            manager,
            loop_,
            buffer: Vec::new(),
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
