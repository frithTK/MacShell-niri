use macshell_cursor_pointer::{watch, PROTOCOL};
use std::io::{self, Write};
use std::process::ExitCode;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) if error.kind() == io::ErrorKind::BrokenPipe => ExitCode::SUCCESS,
        Err(error) => {
            let _ = writeln!(io::stderr(), "cursor-pointer: {error}");
            ExitCode::from(1)
        }
    }
}

fn run() -> io::Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args == ["--protocol-version"] {
        println!("{PROTOCOL}");
        return Ok(());
    }
    if args.len() > 1 || (!args.is_empty() && args[0] != "--check" && args[0] != "--once") {
        return Err(io::Error::other("unexpected argument"));
    }
    let stdout = io::stdout();
    let mut output = stdout.lock();
    if args.first().map(String::as_str) == Some("--check") {
        writeln!(
            output,
            "{}",
            macshell_cursor_pointer::image_line(&macshell_cursor_pointer::cache_dir())?
        )?;
        output.flush()?;
        return Ok(());
    }
    watch(
        &mut output,
        args.first().map(String::as_str) == Some("--once"),
    )
}
