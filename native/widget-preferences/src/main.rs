mod schema;
use macshell_preferences_store::Store;
use schema::{defaults, Schema};
use serde_json::{json, Value};
use std::env;
use std::ffi::{CStr, OsStr};
use std::io::{self, Write};
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;

fn account_home() -> Option<PathBuf> {
    let mut size = 16_384;
    while size <= 1_048_576 {
        let mut buffer = vec![0u8; size];
        let mut entry = std::mem::MaybeUninit::<libc::passwd>::uninit();
        let mut result = std::ptr::null_mut();
        let status = unsafe {
            libc::getpwuid_r(
                libc::getuid(),
                entry.as_mut_ptr(),
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut result,
            )
        };
        if status == libc::ERANGE {
            size *= 2;
            continue;
        }
        if status != 0 || result.is_null() {
            return None;
        }
        let entry = unsafe { entry.assume_init() };
        if entry.pw_dir.is_null() {
            return None;
        }
        let bytes = unsafe { CStr::from_ptr(entry.pw_dir) }.to_bytes();
        return Some(PathBuf::from(OsStr::from_bytes(bytes)));
    }
    None
}
fn settings_path() -> io::Result<PathBuf> {
    let home = env::var_os("MACSHELL_SETTINGS_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            env::var_os("HOME")
                .map(|v| {
                    if v.is_empty() {
                        PathBuf::from("/")
                    } else {
                        PathBuf::from(v)
                    }
                })
                .or_else(account_home)
                .map(|v| v.join(".config"))
        })
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Settings home is unavailable"))?;
    Ok(home.join("macwidgets/settings.json"))
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
    mut state: Value,
    output: &mut impl Write,
    generation: &Option<Value>,
) -> io::Result<()> {
    state["type"] = json!("state");
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
        store.schema.origin = data
            .get("origin")
            .cloned()
            .filter(|v| !v.is_null())
            .unwrap_or_else(|| json!({}));
        let mut state = store.load();
        if state["migrationPending"] == true && state["readOnly"] == false {
            match store.commit(&state["values"], state["token"].as_str(), false) {
                Ok(mut result) => {
                    state = result
                        .as_object_mut()
                        .unwrap()
                        .shift_remove("state")
                        .unwrap();
                    if result["success"] != true {
                        state["readOnly"] = json!(true);
                        state["notice"] = result["error"].clone();
                    }
                }
                Err(error) => {
                    return emit(
                        output,
                        json!({"type":"result", "id":request.get("id"), "success":false, "error":format!("Widget settings could not be saved. {}",error.to_string().chars().take(120).collect::<String>())}),
                        generation,
                    )
                }
            }
        }
        return publish_state(state, output, generation);
    }
    let result = if action == "commit" || action == "recover" {
        let candidate = if action == "recover" {
            defaults()
        } else {
            data.get("values").cloned().unwrap_or(Value::Null)
        };
        store.commit(
            &candidate,
            data.get("token").and_then(Value::as_str),
            action == "recover",
        )
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Unknown widget action",
        ))
    };
    match result {
        Ok(mut result) => {
            let state = result
                .as_object_mut()
                .unwrap()
                .shift_remove("state")
                .unwrap();
            publish_state(state, output, generation)?;
            result["type"] = json!("result");
            result["id"] = request.get("id").cloned().unwrap_or(Value::Null);
            emit(output, result, generation)
        }
        Err(error) => emit(
            output,
            json!({"type":"result", "id":request.get("id"), "success":false,
            "error":format!("Widget settings could not be saved. {}",error.to_string().chars().take(120).collect::<String>())}),
            generation,
        ),
    }
}

fn run() -> io::Result<()> {
    let args: Vec<_> = env::args().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("macshell-widget-preferences 1");
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
            eprintln!("macshell-widget-preferences: {error}");
            std::process::exit(1);
        }
    }
}
