mod config;
mod connect;
mod session;
use serde_json::{json, Value};
use std::env;
use std::io::{self, Write};
fn emit(output: &mut impl Write, mut value: Value, generation: &Option<Value>) -> io::Result<()> {
    if let Some(generation) = generation {
        value["generation"] = generation.clone();
    }
    output.write_all(&serde_json::to_vec(&value)?)?;
    output.write_all(b"\n")?;
    output.flush()
}
fn number(value: &Value) -> Option<f64> {
    match value {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse().ok(),
        Value::Bool(b) => Some(if *b { 1.0 } else { 0.0 }),
        _ => None,
    }
}
fn command(request: &Value, output: &mut impl Write, generation: &Option<Value>) -> io::Result<()> {
    let state = (|| -> Result<Value, session::Error> {
        let identity = session::active_profile()?;
        if request.get("action").and_then(Value::as_str) == Some("apply") {
            let data = request.get("data").cloned().unwrap_or_else(|| json!({}));
            let level = data
                .get("level")
                .map(number)
                .unwrap_or(Some(5.0))
                .filter(|v| v.is_finite())
                .ok_or_else(|| session::Error::Message("Invalid blur strength.".into()))?;
            config::apply(&identity, level)?;
        }
        let owned = config::read_owned(
            &identity
                .config()
                .parent()
                .unwrap()
                .join("macshell-blur.kdl"),
        )?;
        let level = config::level(owned.as_deref()).and_then(|n| i64::try_from(n).ok());
        Ok(
            json!({"type":"state","available":true,"managed":level.is_some(),"level":level.unwrap_or(-1),"error":""}),
        )
    })();
    let value = match state {
        Ok(state) => state,
        Err(error) => json!({"type":"state","available":false,"managed":false,"level":-1,
            "error":match error { session::Error::Message(s)=>s, session::Error::Io=>"Could not apply native blur. Check that the MacShell niri profile is active and valid.".into() }}),
    };
    emit(output, value, generation)
}

fn run() -> io::Result<()> {
    let args: Vec<_> = env::args().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("macshell-native-blur 1");
        return Ok(());
    }
    if !args.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unexpected argument",
        ));
    }
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
                        command(&request, &mut output, &generation)?;
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
            eprintln!("macshell-native-blur: {error}");
            std::process::exit(1);
        }
    }
}
