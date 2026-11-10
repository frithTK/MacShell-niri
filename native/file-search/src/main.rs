use macshell_file_search::{search, SearchEnv, PROTOCOL};
use std::env;
use std::io::{self, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "--protocol-version") {
        println!("{PROTOCOL}");
        return ExitCode::SUCCESS;
    }
    let mut limit = None;
    let mut query = Vec::new();
    let mut seen_end = false;
    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        if !seen_end && arg == "--" {
            seen_end = true;
            i += 1;
            continue;
        }
        if !seen_end && (arg == "--limit" || arg == "-l") {
            i += 1;
            let Some(value) = args.get(i) else {
                eprintln!("Usage: macshell-file-search [--limit N] -- QUERY");
                return ExitCode::from(2);
            };
            limit = Some(value.clone());
            i += 1;
            continue;
        }
        query.push(arg.clone());
        i += 1;
    }
    let query = query.join(" ");
    let mut env = SearchEnv::from_os();
    if let Some(limit) = limit.and_then(|value| value.parse().ok()) {
        if limit > 0 {
            env.limit = limit;
        }
    }
    match search(&query, &env) {
        Ok(hits) => {
            let mut stdout = io::stdout().lock();
            for path in hits {
                let text = path.to_string_lossy();
                if writeln!(stdout, "{text}").is_err() {
                    return ExitCode::from(1);
                }
            }
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("macshell-file-search: {error}");
            ExitCode::from(1)
        }
    }
}
