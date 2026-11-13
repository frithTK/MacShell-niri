//! One asynchronous, current-user fprintd operation.
//!
//! `unlock` listens on the first reader for any enrolled finger until a match,
//! the attempt limit, cancellation or an error. MacLock owns the decision to
//! end the session lock; this process only reports fprintd's result.
use macshell_biometric_probe::{valid_finger, Action, Effect, Operation, Phase};
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use serde_json::json;
use std::ffi::c_char;
use std::io::{self, Write};
use std::os::unix::fs::PermissionsExt;
use std::process::{Child, Command, Stdio};
use std::ptr;

const BUS: &str = "net.reactivated.Fprint";
const MANAGER: &str = "/net/reactivated/Fprint/Manager";
const DEVICE: &str = "net.reactivated.Fprint.Device";
const PROPS: &str = "org.freedesktop.DBus.Properties";

struct Context {
    bus: Ptr,
    loop_: Ptr,
    op: Operation,
    device: String,
    finger: String,
    input: Vec<u8>,
    authorizer: Option<Child>,
    subscriptions: Vec<u32>,
}

fn emit(value: serde_json::Value) {
    let mut out = io::stdout().lock();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

fn error_code(error: &str) -> &'static str {
    for (name, code) in [
        ("AlreadyInUse", "busy"),
        ("PermissionDenied", "permission"),
        ("NoEnrolledPrints", "no_finger"),
        ("NoSuchDevice", "device_gone"),
        ("InvalidFingername", "invalid_finger"),
        ("TimedOut", "timeout"),
    ] {
        if error.contains(name) {
            return code;
        }
    }
    "service_error"
}

fn has_executable(name: &str) -> bool {
    std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
        .map(|p| p.join(name))
        .any(|p| {
            std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
}

unsafe fn call(
    ctx: &mut Context,
    path: &str,
    interface: &str,
    method: &str,
    arg: Option<&str>,
    data: Ptr,
) {
    let params = arg
        .map(|s| gio::tuple(&[gio::string(s)]))
        .unwrap_or(ptr::null_mut());
    let request = Box::into_raw(Box::new((data, ctx.op.phase))).cast();
    // fprintd exits when idle; only the manager lookup may activate it. A daemon that
    // vanishes while a device is claimed must surface as an error, not as a fresh instance.
    let flags = if path == MANAGER { 0 } else { 1 };
    gio::g_dbus_connection_call(
        ctx.bus,
        c(BUS).as_ptr(),
        c(path).as_ptr(),
        c(interface).as_ptr(),
        c(method).as_ptr(),
        params,
        ptr::null_mut(),
        flags,
        10_000,
        ptr::null_mut(),
        Some(completed),
        request,
    );
}

unsafe fn apply(data: Ptr, effects: Vec<Effect>) {
    for effect in effects {
        let ctx = &mut *(data as *mut Context);
        match effect {
            Effect::GetDevices => call(
                ctx,
                MANAGER,
                "net.reactivated.Fprint.Manager",
                "GetDevices",
                None,
                data,
            ),
            Effect::Claim
            | Effect::ListFingers
            | Effect::GetProperties
            | Effect::Start
            | Effect::Delete
            | Effect::Stop
            | Effect::Release => {
                let device = ctx.device.clone();
                let finger = ctx.finger.clone();
                let action = match ctx.op.action {
                    Action::Enroll => "Enroll",
                    Action::Verify | Action::Unlock => "Verify",
                    Action::Delete => "Delete",
                };
                let method;
                let (interface, name, arg) = match effect {
                    Effect::Claim => (DEVICE, "Claim", Some("")),
                    Effect::ListFingers => (DEVICE, "ListEnrolledFingers", Some("")),
                    Effect::GetProperties => (PROPS, "GetAll", Some(DEVICE)),
                    Effect::Start => {
                        method = format!("{action}Start");
                        (DEVICE, method.as_str(), Some(finger.as_str()))
                    }
                    Effect::Stop => {
                        method = format!("{action}Stop");
                        (DEVICE, method.as_str(), None)
                    }
                    Effect::Delete => (DEVICE, "DeleteEnrolledFinger", Some(finger.as_str())),
                    Effect::Release => (DEVICE, "Release", None),
                    _ => unreachable!(),
                };
                call(ctx, &device, interface, name, arg, data);
            }
            Effect::Authorize => {
                let name = gio::text(gio::g_dbus_connection_get_unique_name(ctx.bus));
                ctx.authorizer = Command::new("pkcheck")
                    .args([
                        "--action-id",
                        "net.reactivated.fprint.device.enroll",
                        "--system-bus-name",
                        &name,
                        "--allow-user-interaction",
                    ])
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .ok();
                if ctx.authorizer.is_some() {
                    emit(json!({"type":"status","code":"checking"}));
                    gio::g_timeout_add(100, Some(authorizer_tick), data);
                } else {
                    let effects = ctx.op.authorized(false);
                    apply(data, effects);
                }
            }
            Effect::TerminateAuthorization => stop_authorizer(ctx),
            Effect::Status { code, stage, total } => {
                emit(json!({"type":"status","code":code,"stage":stage,"total":total}))
            }
            Effect::Presence(present) => emit(json!({"type":"finger-presence","present":present})),
            Effect::Result(result) => {
                let mut message =
                    json!({"type":"result","success":result.success,"code":result.code});
                if result.cleanup_failed {
                    message["cleanupFailed"] = json!(true);
                }
                emit(message);
                gio::g_main_loop_quit(ctx.loop_);
            }
        }
    }
}

fn stop_authorizer(ctx: &mut Context) {
    if let Some(mut child) = ctx.authorizer.take() {
        let _ = child.kill();
        let _ = child.wait();
    }
}

extern "C" fn authorizer_tick(data: Ptr) -> i32 {
    unsafe {
        let ctx = &mut *(data as *mut Context);
        let Some(child) = ctx.authorizer.as_mut() else {
            return 0;
        };
        match child.try_wait() {
            Ok(None) => 1,
            result => {
                let ok = result.ok().flatten().is_some_and(|s| s.success());
                stop_authorizer(ctx);
                let effects = ctx.op.authorized(ok);
                apply(data, effects);
                0
            }
        }
    }
}

extern "C" fn completed(bus: Ptr, result: Ptr, data: Ptr) {
    unsafe {
        let request = Box::from_raw(data as *mut (Ptr, Phase));
        let (data, expected) = *request;
        let ctx = &mut *(data as *mut Context);
        let mut error = ptr::null_mut();
        let reply = Variant::from(gio::g_dbus_connection_call_finish(bus, result, &mut error));
        let error = if reply.is_none() {
            Some(gio::error(error))
        } else {
            None
        };
        if ctx.op.phase != expected {
            return;
        }
        let code = error.as_deref().map(error_code);
        let phase = ctx.op.phase;
        let effects = match phase {
            Phase::Devices | Phase::Disconnected => {
                let devices = reply
                    .as_ref()
                    .filter(|r| r.kind() == "(ao)")
                    .and_then(|r| r.child(0));
                if phase == Phase::Devices && ctx.device.is_empty() {
                    if let Some(first) = devices
                        .as_ref()
                        .filter(|a| a.len() > 0)
                        .and_then(|a| a.child(0))
                        .and_then(|v| v.object_path())
                    {
                        ctx.device = first;
                    }
                }
                let found = !ctx.device.is_empty()
                    && devices.as_ref().is_some_and(|a| {
                        (0..a.len()).any(|i| {
                            a.child(i).and_then(|v| v.object_path()).as_deref()
                                == Some(ctx.device.as_str())
                        })
                    });
                if phase == Phase::Devices {
                    ctx.op.devices(
                        found,
                        code.or(if devices.is_none() {
                            Some("service_error")
                        } else {
                            None
                        }),
                        has_executable("pkcheck"),
                    )
                } else {
                    ctx.op.disconnected(found && error.is_none())
                }
            }
            Phase::Claim => ctx.op.claimed(code),
            Phase::Fingers => {
                let fingers = reply
                    .as_ref()
                    .filter(|r| r.kind() == "(as)")
                    .and_then(|r| r.child(0));
                let any = ctx.op.action == Action::Unlock;
                let enrolled = fingers.as_ref().is_some_and(|a| {
                    (0..a.len()).any(|i| {
                        let name = a.child(i).and_then(|v| v.string());
                        if any {
                            name.as_deref().is_some_and(valid_finger)
                        } else {
                            name.as_deref() == Some(ctx.finger.as_str())
                        }
                    })
                });
                ctx.op.fingers(
                    enrolled,
                    if code == Some("no_finger") {
                        None
                    } else if code.is_none() && fingers.is_none() {
                        Some("service_error")
                    } else {
                        code
                    },
                )
            }
            Phase::Properties => {
                let properties = reply.as_ref().and_then(|r| r.child(0));
                let total = properties
                    .as_ref()
                    .and_then(|v| v.lookup("num-enroll-stages"))
                    .filter(|v| v.kind() == "i")
                    .map(|v| gio::g_variant_get_int32(v.0).clamp(0, 100) as u32)
                    .unwrap_or(0);
                let presence = properties
                    .as_ref()
                    .and_then(|v| v.lookup("finger-present"))
                    .and_then(|v| v.boolean());
                if ctx.op.action == Action::Unlock {
                    let scan_type = properties
                        .as_ref()
                        .and_then(|v| v.lookup("scan-type"))
                        .and_then(|v| v.string())
                        .filter(|v| v == "swipe" || v == "press")
                        .unwrap_or_default();
                    emit(json!({"type":"device","scanType":scan_type}));
                }
                ctx.op.properties(total, presence)
            }
            Phase::Starting => ctx.op.started(code),
            Phase::Restarting => ctx.op.restarted(error.is_some()),
            Phase::Deleting => ctx.op.deleted(code),
            Phase::Stopping | Phase::Releasing => ctx.op.cleaned(error.is_some()),
            _ => vec![],
        };
        apply(data, effects);
    }
}

extern "C" fn signal(
    _bus: Ptr,
    _sender: *const c_char,
    path: *const c_char,
    interface: *const c_char,
    name: *const c_char,
    params: Ptr,
    data: Ptr,
) {
    unsafe {
        let ctx = &mut *(data as *mut Context);
        let interface = gio::text(interface);
        let name = gio::text(name);
        if (interface == DEVICE || interface == PROPS)
            && (ctx.device.is_empty() || gio::text(path) != ctx.device)
        {
            return;
        }
        let signature = gio::text(gio::g_variant_get_type_string(params));
        // The signal's variant is borrowed; take owned children only.
        let child = |i| Variant::from(gio::g_variant_get_child_value(params, i));
        let effects = if interface == DEVICE
            && (name == "EnrollStatus" || name == "VerifyStatus")
            && signature == "(sb)"
        {
            match (
                child(0).and_then(|v| v.string()),
                child(1).and_then(|v| v.boolean()),
            ) {
                (Some(code), Some(done)) => ctx.op.signal(&code, done),
                _ => vec![],
            }
        } else if interface == PROPS && name == "PropertiesChanged" && signature == "(sa{sv}as)" {
            if child(0).and_then(|v| v.string()).as_deref() != Some(DEVICE) {
                return;
            }
            let changed = child(1);
            let invalidated = child(2);
            if invalidated.as_ref().is_some_and(|v| {
                (0..v.len()).any(|i| {
                    v.child(i).and_then(|v| v.string()).as_deref() == Some("finger-present")
                })
            }) {
                ctx.op.presence(None)
            } else if let Some(value) = changed
                .and_then(|v| v.lookup("finger-present"))
                .and_then(|v| v.boolean())
            {
                ctx.op.presence(Some(value))
            } else {
                vec![]
            }
        } else if interface == "org.freedesktop.DBus"
            && name == "NameOwnerChanged"
            && signature == "(sss)"
        {
            let old = child(1).and_then(|v| v.string()).unwrap_or_default();
            let new = child(2).and_then(|v| v.string()).unwrap_or_default();
            if !old.is_empty() && old != new {
                ctx.op.owner_lost()
            } else {
                vec![]
            }
        } else {
            vec![]
        };
        apply(data, effects);
    }
}

extern "C" fn input_ready(fd: i32, condition: u32, data: Ptr) -> i32 {
    unsafe {
        let ctx = &mut *(data as *mut Context);
        if condition & (8 | 16 | 32) != 0 {
            let effects = ctx.op.cancel("cancelled");
            apply(data, effects);
            return 0;
        }
        let mut bytes = [0u8; 4096];
        let n = libc::read(fd, bytes.as_mut_ptr().cast(), bytes.len());
        if n <= 0 {
            let effects = ctx.op.cancel("cancelled");
            apply(data, effects);
            return 0;
        }
        ctx.input.extend_from_slice(&bytes[..n as usize]);
        if ctx.input.len() > 4096 {
            let effects = ctx.op.cancel("cancelled");
            apply(data, effects);
            return 0;
        }
        while let Some(i) = ctx.input.iter().position(|b| *b == b'\n') {
            let line: Vec<_> = ctx.input.drain(..=i).collect();
            if line == b"cancel\n" {
                let effects = ctx.op.cancel("cancelled");
                apply(data, effects);
            }
        }
        1
    }
}
extern "C" fn timeout(data: Ptr) -> i32 {
    unsafe {
        let ctx = &mut *(data as *mut Context);
        let effects = ctx.op.cancel("timeout");
        apply(data, effects);
    }
    0
}

unsafe fn subscribe(
    ctx: &mut Context,
    sender: &str,
    interface: &str,
    signal_name: &str,
    path: Option<&str>,
    arg: Option<&str>,
    data: Ptr,
) {
    let arg = arg.map(c);
    let path = path.map(c);
    let id = gio::g_dbus_connection_signal_subscribe(
        ctx.bus,
        c(sender).as_ptr(),
        c(interface).as_ptr(),
        c(signal_name).as_ptr(),
        path.as_ref().map_or(ptr::null(), |v| v.as_ptr()),
        arg.as_ref().map_or(ptr::null(), |v| v.as_ptr()),
        0,
        Some(signal),
        data,
        ptr::null_mut(),
    );
    ctx.subscriptions.push(id);
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("macshell-fingerprint-operation 1");
        return;
    }
    if args == ["--unlock-protocol-version"] {
        println!("macshell-fingerprint-unlock 1");
        return;
    }
    let (action, device, finger) = if args == ["unlock"] {
        (Action::Unlock, String::new(), "any".to_string())
    } else {
        if args.len() != 3
            || !valid_finger(&args[2])
            || !args[1].starts_with('/')
            || args[1].contains('\0')
        {
            eprintln!("invalid fingerprint operation arguments");
            std::process::exit(2);
        }
        let action = match args[0].as_str() {
            "enroll" => Action::Enroll,
            "verify" => Action::Verify,
            "delete" => Action::Delete,
            _ => {
                eprintln!("invalid fingerprint action");
                std::process::exit(2);
            }
        };
        // Device paths must be valid D-Bus object paths, not arbitrary strings.
        if !args[1]
            .split('/')
            .skip(1)
            .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_'))
        {
            eprintln!("invalid device path");
            std::process::exit(2);
        }
        (action, args[1].clone(), args[2].clone())
    };
    unsafe {
        let mut error = ptr::null_mut();
        let address = gio::g_dbus_address_get_for_bus_sync(1, ptr::null_mut(), &mut error);
        if address.is_null() {
            let _ = gio::error(error);
            emit(json!({"type":"result","success":false,"code":"service_error"}));
            return;
        }
        let bus = gio::g_dbus_connection_new_for_address_sync(
            address,
            1 | 8,
            ptr::null_mut(),
            ptr::null_mut(),
            &mut error,
        );
        gio::g_free(address.cast());
        if bus.is_null() {
            let _ = gio::error(error);
            emit(json!({"type":"result","success":false,"code":"service_error"}));
            return;
        }
        gio::g_dbus_connection_set_exit_on_close(bus, 0);
        let loop_ = gio::g_main_loop_new(ptr::null_mut(), 0);
        let mut ctx = Box::new(Context {
            bus,
            loop_,
            op: Operation::new(action),
            device,
            finger,
            input: Vec::new(),
            authorizer: None,
            subscriptions: Vec::new(),
        });
        let data = (&mut *ctx as *mut Context).cast();
        let device = (!ctx.device.is_empty()).then(|| ctx.device.clone());
        subscribe(
            &mut ctx,
            BUS,
            DEVICE,
            if matches!(action, Action::Verify | Action::Unlock) {
                "VerifyStatus"
            } else {
                "EnrollStatus"
            },
            device.as_deref(),
            None,
            data,
        );
        subscribe(
            &mut ctx,
            BUS,
            PROPS,
            "PropertiesChanged",
            device.as_deref(),
            Some(DEVICE),
            data,
        );
        subscribe(
            &mut ctx,
            "org.freedesktop.DBus",
            "org.freedesktop.DBus",
            "NameOwnerChanged",
            Some("/org/freedesktop/DBus"),
            Some(BUS),
            data,
        );
        gio::g_unix_fd_add(0, 1 | 8 | 16 | 32, Some(input_ready), data);
        if action != Action::Unlock {
            gio::g_timeout_add_seconds(120, Some(timeout), data);
        }
        emit(json!({"type":"status","code":"checking"}));
        call(
            &mut ctx,
            MANAGER,
            "net.reactivated.Fprint.Manager",
            "GetDevices",
            None,
            data,
        );
        gio::g_main_loop_run(loop_);
        stop_authorizer(&mut ctx);
        for id in &ctx.subscriptions {
            gio::g_dbus_connection_signal_unsubscribe(bus, *id);
        }
        let mut close_error = ptr::null_mut();
        gio::g_dbus_connection_close_sync(bus, ptr::null_mut(), &mut close_error);
        if !close_error.is_null() {
            let _ = gio::error(close_error);
        }
        gio::g_object_unref(bus);
        gio::g_main_loop_unref(loop_);
    }
}
