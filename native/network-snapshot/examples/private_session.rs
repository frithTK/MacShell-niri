//! Integration harness: runs only against the explicitly supplied private bus.
use macshell_gio_bridge::{self as gio, c, Ptr};
use macshell_network_agent::Event as AgentEvent;
use macshell_network_core::activation::{Action, Ticket};
use macshell_network_snapshot::{
    activate,
    session::{Event, RadioAction, Session},
    Error,
};
use serde_json::{json, Value};
use std::io::{self, Write};
use std::ptr;
use std::time::Duration;

const DEV: &str = "/org/freedesktop/NetworkManager/Devices/1";
const AP: &str = "/org/freedesktop/NetworkManager/AccessPoint/1";
const PROFILE: &str = "/org/freedesktop/NetworkManager/Settings/1";
const NEW_UUID: &str = "d4ac1208-0a7b-4012-8abc-381d6ca41234";
struct Harness {
    session: Session<bool>,
    ticket: Option<Ticket>,
    loop_: Ptr,
    input: Vec<u8>,
}
fn emit(v: Value) {
    let mut out = io::stdout().lock();
    serde_json::to_writer(&mut out, &v).unwrap();
    writeln!(out).unwrap();
    out.flush().unwrap();
}
unsafe fn connection(address: &str) -> Option<Ptr> {
    let mut error = ptr::null_mut();
    let bus = gio::g_dbus_connection_new_for_address_sync(
        c(address).as_ptr(),
        9,
        ptr::null_mut(),
        ptr::null_mut(),
        &mut error,
    );
    if !error.is_null() {
        gio::g_error_free(error);
    }
    if bus.is_null() {
        None
    } else {
        Some(bus)
    }
}
unsafe fn close(bus: Ptr) {
    let mut error = ptr::null_mut();
    gio::g_dbus_connection_close_sync(bus, ptr::null_mut(), &mut error);
    if !error.is_null() {
        gio::g_error_free(error);
    }
    gio::g_object_unref(bus);
}
extern "C" fn input(fd: i32, _: u32, data: Ptr) -> i32 {
    unsafe {
        let h = &mut *data.cast::<Harness>();
        let mut bytes = [0; 4096];
        let n = libc::read(fd, bytes.as_mut_ptr().cast(), bytes.len());
        if n <= 0 {
            gio::g_main_loop_quit(h.loop_);
            return 0;
        }
        h.input.extend_from_slice(&bytes[..n as usize]);
        if h.input.len() > 65536 {
            gio::g_main_loop_quit(h.loop_);
            return 0;
        }
        while let Some(end) = h.input.iter().position(|v| *v == b'\n') {
            let line: Vec<_> = h.input.drain(..=end).collect();
            let Ok(v) = serde_json::from_slice::<Value>(&line) else {
                continue;
            };
            match v["action"].as_str() {
                Some("refresh") => {
                    emit(json!({"type":"refresh", "ok":h.session.refresh().unwrap_or(false)}))
                }
                Some("scan") => match h.session.radio(8, RadioAction::Scan) {
                    Ok(()) => emit(json!({"type":"scan_started"})),
                    Err(error) => emit(json!({"type":"error", "error":error})),
                },
                Some("disconnect") => match h.session.radio(
                    8,
                    RadioAction::Disconnect {
                        device: DEV.into(),
                        ap: AP.into(),
                    },
                ) {
                    Ok(()) => emit(json!({"type":"disconnect_started"})),
                    Err(error) => emit(json!({"type":"error", "error":error})),
                },
                Some("begin") | Some("create") => {
                    let new = v["action"].as_str() == Some("create");
                    match h.session.begin(
                        7,
                        macshell_network_snapshot::session::Selection {
                            device: DEV,
                            ap: AP,
                            secret: Some(macshell_network_snapshot::session::SecretIdentity {
                                uuid: if new { NEW_UUID } else { "test-id" },
                                profile: if new { None } else { Some(PROFILE) },
                                has_initial: false,
                            }),
                        },
                        new,
                    ) {
                        Ok(t) => {
                            h.ticket = Some(t);
                            emit(json!({"type":"begun"}));
                        }
                        Err(e) => emit(json!({"type":"error","error":e})),
                    }
                }
                Some("cancel") => {
                    if let Some(t) = h.ticket {
                        emit(json!({"type":"cancel","action":format!("{:?}",h.session.cancel(t))}));
                    }
                }
                Some("reply") => {
                    if let Some(t) = h.ticket {
                        emit(
                            json!({"type":"reply","accepted":h.session.reply(t, v["delivery"].as_u64().unwrap_or(0), v["password"].as_str().unwrap_or("")).unwrap_or(false)}),
                        );
                    }
                }
                _ => (),
            }
        }
        1
    }
}
extern "C" fn poll(data: Ptr) -> i32 {
    unsafe {
        let h = &mut *data.cast::<Harness>();
        for event in h.session.poll() {
            match event {
                Event::Owner(owner) => emit(json!({"type":"owner","unique":owner})),
                Event::Registration(ok) => emit(json!({"type":"registration","success":ok})),
                Event::Snapshot(Ok(state)) => emit(json!({"type":"snapshot","state":state})),
                Event::Snapshot(Err(error)) => {
                    emit(json!({"type":"snapshot_error","error":format!("{error:?}")}))
                }
                Event::Agent(AgentEvent::NeedSecret {
                    request, delivery, ..
                }) => emit(json!({"type":"need","request":request,"delivery":delivery})),
                Event::Agent(_) => (),
                Event::Activation { action, .. } => {
                    emit(json!({"type":"activation","action":format!("{action:?}")}));
                    if action == Action::CloseUncertain {
                        emit(json!({"type":"close"}));
                    }
                }
                Event::CloseConnection => emit(json!({"type":"close"})),
                Event::Radio { request, result } => {
                    emit(json!({"type":"radio", "request":request, "result":format!("{result:?}")}))
                }
            }
        }
        1
    }
}
fn main() {
    let address = std::env::var("DBUS_SYSTEM_BUS_ADDRESS")
        .ok()
        .filter(|a| !a.is_empty() && !a.contains('\0'))
        .expect("private bus required");
    unsafe {
        let bus = connection(&address).expect("private bus");
        gio::g_dbus_connection_set_exit_on_close(bus, 0);
        let reader_address = address.clone();
        let inspect_address = address.clone();
        let radio_address = address.clone();
        let session = Session::new(
            bus,
            move |owner| {
                let bus = connection(&reader_address).ok_or(Error::Unavailable)?;
                let result = macshell_network_snapshot::read(bus, owner, Duration::from_secs(4));
                close(bus);
                result
            },
            move |owner, new| {
                let bus = connection(&address).ok_or(activate::Error::Unavailable)?;
                let result = if new {
                    let input = macshell_network_core::new_profile::Input {
                        ssid: b"Test WiFi",
                        interface: "wlan0",
                        username: "tester",
                        security: "wpa-psk",
                        uuid: NEW_UUID,
                        password: "synthetic-password",
                    };
                    let selection = activate::NewSelection {
                        device: DEV,
                        ap: AP,
                        profile: input,
                    };
                    activate::create(bus, owner, &selection, Duration::from_secs(4)).map(|v| {
                        activate::Started {
                            active_path: v.active_path,
                            exclusively_owned: v.exclusively_owned,
                        }
                    })
                } else {
                    let selection = activate::Selection {
                        profile: PROFILE,
                        device: DEV,
                        ap: AP,
                        ssid: b"Test WiFi",
                        uuid: "test-id",
                        security: "wpa-psk",
                    };
                    activate::saved(bus, owner, &selection, Duration::from_secs(4))
                };
                close(bus);
                result
            },
            move |owner, path| {
                let bus = connection(&inspect_address).ok_or(activate::Error::Unavailable)?;
                let result = activate::inspect(bus, owner, &path, Duration::from_secs(4));
                close(bus);
                result
            },
            move |owner, action| {
                let bus = connection(&radio_address)
                    .ok_or(macshell_network_snapshot::radio::Error::Unavailable)?;
                let result = match action {
                    RadioAction::Scan => {
                        macshell_network_snapshot::radio::scan(bus, owner, Duration::from_secs(4))
                    }
                    RadioAction::CancelActivation { path } => {
                        activate::cancel(bus, owner, &path, Duration::from_secs(3))
                    }
                    RadioAction::Power(enabled) => macshell_network_snapshot::radio::set_power(
                        bus,
                        owner,
                        enabled,
                        Duration::from_secs(4),
                    )
                    .map(|()| 0),
                    RadioAction::Disconnect { device, ap } => {
                        macshell_network_snapshot::radio::disconnect(
                            bus,
                            owner,
                            &device,
                            &ap,
                            Duration::from_secs(4),
                        )
                        .map(|()| 0)
                    }
                };
                close(bus);
                result
            },
        )
        .expect("session");
        let loop_ = gio::g_main_loop_new(ptr::null_mut(), 0);
        let unique = gio::text(gio::g_dbus_connection_get_unique_name(bus));
        let mut h = Box::new(Harness {
            session,
            ticket: None,
            loop_,
            input: Vec::new(),
        });
        let data = (&mut *h as *mut Harness).cast();
        let fd = gio::g_unix_fd_add(
            libc::STDIN_FILENO,
            (libc::POLLIN | libc::POLLHUP) as u32,
            Some(input),
            data,
        );
        let timer = gio::g_timeout_add(10, Some(poll), data);
        emit(json!({"type":"ready","unique":unique}));
        gio::g_main_loop_run(loop_);
        for id in [fd, timer] {
            let source = gio::g_main_context_find_source_by_id(gio::g_main_context_default(), id);
            if !source.is_null() {
                gio::g_source_destroy(source);
            }
        }
        drop(h);
        close(bus);
        gio::g_main_loop_unref(loop_);
    }
}
