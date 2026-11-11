use macshell_drop_tools::{handle, ToolEnv, PROTOCOL};
use serde_json::{json, Value};
use std::io::{self, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;
use std::thread;

enum Event {
    Progress {
        done: usize,
        total: usize,
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

fn spawn_run(
    env: ToolEnv,
    data: Value,
    cancel: Arc<AtomicBool>,
    id: Value,
    generation: Option<Value>,
    tx: Sender<Event>,
) {
    thread::spawn(move || {
        let payload = handle("run", &data, &env, cancel.as_ref());
        if let Some(results) = payload.get("results").and_then(Value::as_array) {
            let _ = tx.send(Event::Progress {
                done: results.len(),
                total: results.len(),
                id: id.clone(),
                generation: generation.clone(),
            });
        }
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
    if args.first().map(String::as_str) == Some("--convert") {
        let code = macshell_drop_tools::convert_from_args(&args[1..])?;
        if code != 0 {
            std::process::exit(code);
        }
        return Ok(());
    }
    if !args.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unexpected argument",
        ));
    }
    let env = ToolEnv::from_os();
    let stdout = io::stdout();
    let mut output = stdout.lock();
    let mut generation = None;
    let mut buffer = Vec::new();
    let (tx, rx): (Sender<Event>, Receiver<Event>) = mpsc::channel();
    let mut cancel = Arc::new(AtomicBool::new(false));
    let mut running = false;
    emit(&mut output, json!({"type": "ready"}), &generation)?;
    loop {
        let mut poll = libc::pollfd {
            fd: libc::STDIN_FILENO,
            events: libc::POLLIN,
            revents: 0,
        };
        let ready = unsafe { libc::poll(&mut poll, 1, if running { 50 } else { -1 }) };
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
                    done,
                    total,
                    id,
                    generation,
                } => {
                    emit(
                        &mut output,
                        json!({"type": "progress", "runId": id, "done": done, "total": total}),
                        &generation,
                    )?;
                }
                Event::Done {
                    mut payload,
                    id,
                    generation,
                } => {
                    running = false;
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
                        "run" => {
                            if running {
                                cancel.store(true, Ordering::Relaxed);
                            }
                            cancel = Arc::new(AtomicBool::new(false));
                            running = true;
                            spawn_run(
                                env.clone(),
                                data,
                                cancel.clone(),
                                id,
                                generation.clone(),
                                tx.clone(),
                            );
                        }
                        "cancel" => {
                            cancel.store(true, Ordering::Relaxed);
                            if !running {
                                emit(
                                    &mut output,
                                    json!({"type":"result","id":id,"success":true,"action":"cancel","cancelled":true}),
                                    &generation,
                                )?;
                            }
                        }
                        _ => {
                            let mut result = handle(action, &data, &env, cancel.as_ref());
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
            eprintln!("macshell-drop-tools: {error}");
            std::process::exit(1);
        }
    }
}
