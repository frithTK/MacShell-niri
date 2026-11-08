use macshell_niri_input::{coordinator::Outcome, prepare};
use serde_json::Value;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

fn error(message: impl Into<String>) -> ! {
    eprintln!("{}", message.into());
    std::process::exit(1)
}

fn main() {
    let mut args = env::args().skip(1);
    let first = args.next();
    if first.as_deref() == Some("--protocol-version") {
        println!("macshell-niri-input 1");
        return;
    }
    if first.as_deref() == Some("resolve-cleanup") {
        let profile = PathBuf::from(
            env::var_os("MACSHELL_NIRI_PROFILE")
                .unwrap_or_else(|| error("MACSHELL_NIRI_PROFILE is not set")),
        );
        let journal = args
            .next()
            .unwrap_or_else(|| error("usage: macshell-niri-input resolve-cleanup <journal-name>"));
        macshell_niri_input::recovery::cleanup_completed(&profile, std::ffi::OsStr::new(&journal))
            .unwrap_or_else(|e| error(format!("cleanup refused: {e}")));
        return;
    }
    if first.as_deref() != Some("input") {
        error("usage: macshell-niri-input input <json>");
    }
    let values: Value = args
        .next()
        .and_then(|v| serde_json::from_str(&v).ok())
        .unwrap_or_else(|| error("invalid input JSON"));
    let profile = PathBuf::from(
        env::var_os("MACSHELL_NIRI_PROFILE")
            .unwrap_or_else(|| error("MACSHELL_NIRI_PROFILE is not set")),
    );
    let fragment = PathBuf::from(
        env::var_os("MACSHELL_INPUT_FRAGMENT")
            .unwrap_or_else(|| error("MACSHELL_INPUT_FRAGMENT is not set")),
    );
    let validator = Path::new("niri");
    let relative = fragment
        .strip_prefix(&profile)
        .unwrap_or_else(|_| error("Input fragment is outside profile"));
    if relative != Path::new("macshell-input.kdl") {
        error("Input fragment must be the managed profile fragment");
    }
    let entries =
        fs::read_dir(&profile).unwrap_or_else(|e| error(format!("cannot inspect profile: {e}")));
    for entry in entries {
        let name = entry
            .unwrap_or_else(|e| error(format!("cannot inspect profile: {e}")))
            .file_name();
        let text = name.to_string_lossy();
        if text.starts_with(".macshell-input-journal-") {
            error("An unfinished input transaction requires explicit resolution");
        }
    }
    let prepared = prepare::prepare_single_locked(
        &profile,
        relative,
        &values,
        validator,
        Duration::from_secs(10),
    )
    .unwrap_or_else(|e| error(format!("input preparation failed: {e}")));
    let staged = match prepared
        .stage_single(&profile, relative)
        .unwrap_or_else(|e| error(format!("input staging failed: {e}")))
    {
        macshell_niri_input::staging::StageResult::Ready(value) => value,
        macshell_niri_input::staging::StageResult::Incomplete {
            name,
            error: stage_error,
        } => error(format!(
            "input staging incomplete ({:?}): {stage_error}",
            name
        )),
    };
    let (manifest, journal) = prepared
        .begin_single_transaction(&profile, relative, &staged)
        .unwrap_or_else(|e| error(format!("input manifest failed: {e}")));
    let outcome = prepared
        .commit_single_transaction(&profile, relative, staged, manifest, journal)
        .unwrap_or_else(|e| error(format!("input commit failed: {e}")));
    match outcome {
        Outcome::Complete => {}
        Outcome::Interrupted { stage, reason, .. } => error(format!(
            "input transaction interrupted at {stage:?}: {reason:?}"
        )),
    }
}
