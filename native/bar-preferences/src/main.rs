mod schema;

use macshell_preferences_store::Store;
use schema::Schema;
use serde_json::{json, Value};
use std::env;
use std::io::{self, Write};
use std::path::PathBuf;

fn settings_path() -> io::Result<PathBuf> {
    let directory = ["MACSHELL_SETTINGS_HOME", "XDG_CONFIG_HOME"]
        .iter()
        .filter_map(env::var_os)
        .find(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Settings home is unavailable"))?;
    Ok(directory.join("macbar/layout.json"))
}

fn emit(output: &mut impl Write, mut value: Value, generation: &Option<Value>) -> io::Result<()> {
    if let Some(generation) = generation {
        value["generation"] = generation.clone();
    }
    output.write_all(&serde_json::to_vec(&value)?)?;
    output.write_all(b"\n")?;
    output.flush()
}

fn publish_state(
    store: &Store<Schema>,
    mut state: Value,
    output: &mut impl Write,
    generation: &Option<Value>,
) -> io::Result<()> {
    state["type"] = json!("state");
    state["catalog"] = json!(store.schema.catalog);
    emit(output, state, generation)
}

fn command(
    store: &mut Store<Schema>,
    request: &Value,
    output: &mut impl Write,
    generation: &Option<Value>,
) -> io::Result<()> {
    let data = request.get("data").cloned().unwrap_or_else(|| json!({}));
    let action = request.get("action").and_then(Value::as_str).unwrap_or("");
    if action == "load" {
        store.schema.defaults = store
            .schema
            .make_defaults(data.get("legacy").unwrap_or(&Value::Null));
        return publish_state(store, store.load(), output, generation);
    }
    let result = if action == "commit" || action == "recover" {
        let defaults = Value::Object(store.schema.make_defaults(&Value::Null));
        let candidate = if action == "recover" {
            &defaults
        } else {
            data.get("values").unwrap_or(&Value::Null)
        };
        store.commit(
            candidate,
            data.get("token").and_then(Value::as_str),
            action == "recover",
        )
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Unknown menu bar action",
        ))
    };
    match result {
        Ok(mut result) => {
            let state = result
                .as_object_mut()
                .and_then(|object| object.shift_remove("state"))
                .unwrap();
            publish_state(store, state, output, generation)?;
            result["type"] = json!("result");
            result["id"] = request.get("id").cloned().unwrap_or(Value::Null);
            emit(output, result, generation)
        }
        Err(error) => emit(
            output,
            json!({"type":"result", "id":request.get("id"), "success":false,
            "error": format!("Menu bar settings could not be saved. {}", error.to_string().chars().take(120).collect::<String>())}),
            generation,
        ),
    }
}

fn run() -> io::Result<()> {
    let args: Vec<_> = env::args().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("macshell-bar-preferences 1");
        return Ok(());
    }
    if !args.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unexpected argument",
        ));
    }
    let mut store = Store::new(settings_path()?, Schema::new());
    let stdout = io::stdout();
    let mut output = stdout.lock();
    let mut generation = None;
    let mut buffer = Vec::new();
    emit(&mut output, json!({"type":"ready"}), &generation)?;
    loop {
        let mut poll = libc::pollfd {
            fd: libc::STDIN_FILENO,
            events: libc::POLLIN,
            revents: 0,
        };
        let ready = unsafe { libc::poll(&mut poll, 1, -1) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if poll.revents & libc::POLLNVAL != 0 {
            break;
        }
        if poll.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
            let mut bytes = [0u8; 65536];
            let count =
                unsafe { libc::read(libc::STDIN_FILENO, bytes.as_mut_ptr().cast(), bytes.len()) };
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
                    if request.is_object()
                        && data.is_object()
                        && request.get("generation").is_some()
                    {
                        generation = request.get("generation").cloned();
                        command(&mut store, &request, &mut output, &generation)?;
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
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        if error.kind() != io::ErrorKind::BrokenPipe {
            eprintln!("macshell-bar-preferences: {error}");
            std::process::exit(1);
        }
    }
}
