use macshell_storage::{scan_payload, volumes_payload, StorageEnv, PROTOCOL};
use serde_json::{json, Value};
use std::io::{self, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;
use std::thread;

enum Event {
    Progress {
        visited: u64,
        id: Value,
        generation: Option<Value>,
    },
    Done {
        payload: Value,
        id: Value,
        generation: Option<Value>,
    },
}

fn emit(output: &mut impl Write, mut value: Value, generation: &Option<Value>) -> io::Result<()> {
    if let Some(generation) = generation {
        value["generation"] = generation.clone();
    }
    output.write_all(&serde_json::to_vec(&value)?)?;
    output.write_all(b"\n")?;
    output.flush()
}

fn spawn_scan(
    env: StorageEnv,
    cancel: Arc<AtomicBool>,
    id: Value,
    generation: Option<Value>,
    tx: Sender<Event>,
) {
    thread::spawn(move || {
        let progress_id = id.clone();
        let progress_generation = generation.clone();
        let progress_tx = tx.clone();
        let payload = scan_payload(
            &env,
            cancel.as_ref(),
            &move |visited| {
                let _ = progress_tx.send(Event::Progress {
                    visited,
                    id: progress_id.clone(),
                    generation: progress_generation.clone(),
                });
            },
        );
        let _ = tx.send(Event::Done {
            payload,
            id,
            generation,
        });
    });
}

fn run() -> io::Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("{PROTOCOL}");
        return Ok(());
    }
    if !args.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unexpected argument",
        ));
    }
    let env = StorageEnv::from_os();
    let stdout = io::stdout();
    let mut output = stdout.lock();
    let mut generation = None;
    let mut buffer = Vec::new();
    let (tx, rx): (Sender<Event>, Receiver<Event>) = mpsc::channel();
    let mut cancel = Arc::new(AtomicBool::new(false));
    let mut scanning = false;
    emit(&mut output, json!({"type": "ready"}), &generation)?;
    loop {
        let mut poll = libc::pollfd {
            fd: libc::STDIN_FILENO,
            events: libc::POLLIN,
            revents: 0,
        };
        let ready = unsafe { libc::poll(&mut poll, 1, if scanning { 50 } else { -1 }) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        while let Ok(event) = rx.try_recv() {
            match event {
                Event::Progress {
                    visited,
                    id,
                    generation,
                } => {
                    emit(
                        &mut output,
                        json!({"type": "progress", "scanId": id, "visited": visited}),
                        &generation,
                    )?;
                }
                Event::Done {
                    mut payload,
                    id,
                    generation,
                } => {
                    scanning = false;
                    payload["type"] = json!("result");
                    payload["id"] = id;
                    emit(&mut output, payload, &generation)?;
                }
            }
        }
        if poll.revents & libc::POLLNVAL != 0 {
            break;
        }
        if poll.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) == 0 {
            continue;
        }
        let mut bytes = [0u8; 65536];
        let count = unsafe { libc::read(libc::STDIN_FILENO, bytes.as_mut_ptr().cast(), bytes.len()) };
        if count <= 0 {
            break;
        }
        buffer.extend_from_slice(&bytes[..count as usize]);
        if buffer.len() > 1_048_576 {
            break;
        }
        while let Some(end) = buffer.iter().position(|byte| *byte == b'\n') {
            let line: Vec<_> = buffer.drain(..=end).collect();
            if let Ok(request) = serde_json::from_slice::<Value>(&line) {
                let data = request.get("data").cloned().unwrap_or_else(|| json!({}));
                if request.is_object() && data.is_object() && request.get("generation").is_some() {
                    generation = request.get("generation").cloned();
                    let action = request.get("action").and_then(Value::as_str).unwrap_or("");
                    let id = request.get("id").cloned().unwrap_or(Value::Null);
                    match action {
                        "scan" => {
                            if scanning {
                                cancel.store(true, Ordering::Relaxed);
                            }
                            cancel = Arc::new(AtomicBool::new(false));
                            scanning = true;
                            spawn_scan(env.clone(), cancel.clone(), id, generation.clone(), tx.clone());
                        }
                        "cancel" => {
                            cancel.store(true, Ordering::Relaxed);
                            if !scanning {
                                emit(
                                    &mut output,
                                    json!({"type":"result","id":id,"success":true,"action":"cancel","cancelled":true}),
                                    &generation,
                                )?;
                            }
                        }
                        _ => {
                            let mut result = if action == "volumes" {
                                volumes_payload(&env)
                            } else {
                                json!({"success": false, "error": "Unknown action"})
                            };
                            result["type"] = json!("result");
                            result["id"] = id;
                            emit(&mut output, result, &generation)?;
                        }
                    }
                    continue;
                }
            }
            emit(
                &mut output,
                json!({"type":"error", "error":"Invalid service request"}),
                &generation,
            )?;
        }
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        if error.kind() != io::ErrorKind::BrokenPipe {
            eprintln!("macshell-storage: {error}");
            std::process::exit(1);
        }
    }
}
