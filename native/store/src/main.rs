use macshell_store::{
    accept, list_appimage_argv, mutation_argv, needs_recheck, parse_rows, recheck_argv, row_json,
    search_argv, selection_from, updates_argv, PROTOCOL,
};
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use std::process::{Command, Stdio};

fn emit(output: &mut impl Write, mut value: Value, generation: &Option<Value>) -> io::Result<()> {
    if let Some(generation) = generation {
        value["generation"] = generation.clone();
    }
    output.write_all(&serde_json::to_vec(&value)?)?;
    output.write_all(b"\n")?;
    output.flush()
}

fn program() -> String {
    std::env::var("MACSHELL_SHELLY").unwrap_or_else(|_| "shelly".into())
}

fn shelly_ready(program: &str) -> bool {
    Command::new(program)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn detail(output: &std::process::Output) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let line = stderr
        .lines()
        .chain(stdout.lines())
        .find(|line| !line.trim().is_empty())
        .unwrap_or("Package operation failed");
    line.chars().take(200).collect()
}

fn run(argv: &[String]) -> Result<std::process::Output, String> {
    let (program, args) = argv.split_first().ok_or("Unknown source")?;
    Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|error| error.to_string())
}

fn rows_from(output: &std::process::Output) -> Result<Vec<macshell_store::Row>, String> {
    if !output.status.success() {
        return Err(detail(output));
    }
    let value = serde_json::from_slice::<Value>(&output.stdout).map_err(|_| detail(output))?;
    parse_rows(&value).map_err(|_| detail(output))
}

fn command(
    request: &Value,
    output: &mut impl Write,
    generation: &Option<Value>,
    shelly: bool,
) -> io::Result<()> {
    let action = request.get("action").and_then(Value::as_str).unwrap_or("");
    let data = request.get("data").cloned().unwrap_or_else(|| json!({}));
    let result = if action == "hello" {
        json!({"success": true, "shelly": shelly})
    } else if !shelly {
        json!({"success": false, "error": "shelly"})
    } else {
        dispatch(action, &data, output, generation)?
    };
    let mut message = result;
    message["type"] = json!("result");
    message["id"] = request.get("id").cloned().unwrap_or(Value::Null);
    emit(output, message, generation)
}

fn dispatch(
    action: &str,
    data: &Value,
    output: &mut impl Write,
    generation: &Option<Value>,
) -> io::Result<Value> {
    let program = program();
    let result = match action {
        "search" => search(&program, data),
        "updates" => updates(&program),
        "apply" => apply(&program, data, output, generation),
        _ => Err("Unknown action".into()),
    };
    Ok(match result {
        Ok(value) => value,
        Err(error) => json!({"success": false, "error": error}),
    })
}

fn search(program: &str, data: &Value) -> Result<Value, String> {
    let source = data.get("source").and_then(Value::as_str).unwrap_or("");
    let query = data.get("query").and_then(Value::as_str).unwrap_or("");
    let argv = search_argv(program, source, query)?;
    let output = run(&argv)?;
    let rows = rows_from(&output)?;
    Ok(json!({
        "success": true,
        "rows": rows.iter().map(row_json).collect::<Vec<_>>(),
    }))
}

fn updates(program: &str) -> Result<Value, String> {
    let mut body = json!({"success": true, "errors": {}});
    for source in ["standard", "flatpak", "appimage", "aur"] {
        match updates_argv(program, source)
            .and_then(|argv| run(&argv))
            .and_then(|output| rows_from(&output))
        {
            Ok(rows) => {
                body[source] = json!(rows.iter().map(row_json).collect::<Vec<_>>());
            }
            Err(error) => {
                body[source] = json!([]);
                body["errors"][source] = json!(error);
            }
        }
    }
    Ok(body)
}

fn apply(
    program: &str,
    data: &Value,
    output: &mut impl Write,
    generation: &Option<Value>,
) -> Result<Value, String> {
    let selection = selection_from(data)?;
    let mutation = mutation_argv(program, &selection)?;
    if needs_recheck(&selection) {
        let argv = if selection.source == "appimage" {
            list_appimage_argv(program)
        } else {
            recheck_argv(program, &selection)?
        };
        let listed = rows_from(&run(&argv)?)?;
        accept(&selection, &listed)?;
    }
    let _ = emit(
        output,
        json!({"type": "status", "state": "working"}),
        generation,
    );
    let ran = run(&mutation)?;
    if !ran.status.success() {
        return Err(detail(&ran));
    }
    Ok(json!({"success": true}))
}

fn run_service() -> io::Result<()> {
    let shelly = shelly_ready(&program());
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut output = stdout.lock();
    let mut generation = None;
    emit(
        &mut output,
        json!({"type": "ready", "shelly": shelly}),
        &None,
    )?;
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let request = match serde_json::from_str::<Value>(&line) {
            Ok(request) if request.is_object() => request,
            _ => {
                emit(
                    &mut output,
                    json!({"type": "error", "error": "Invalid service request"}),
                    &generation,
                )?;
                continue;
            }
        };
        let data = request.get("data").cloned().unwrap_or_else(|| json!({}));
        if !data.is_object() {
            emit(
                &mut output,
                json!({"type": "error", "error": "Invalid service request"}),
                &generation,
            )?;
            continue;
        }
        generation = request.get("generation").cloned();
        command(&request, &mut output, &generation, shelly)?;
    }
    Ok(())
}

fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("{PROTOCOL}");
        return;
    }
    if !args.is_empty() {
        eprintln!("macshell-store: unexpected argument");
        std::process::exit(1);
    }
    if let Err(error) = run_service() {
        if error.kind() != io::ErrorKind::BrokenPipe {
            eprintln!("macshell-store: {error}");
            std::process::exit(1);
        }
    }
}
