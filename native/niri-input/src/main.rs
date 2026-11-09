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

fn profile() -> PathBuf {
    PathBuf::from(
        env::var_os("MACSHELL_NIRI_PROFILE")
            .unwrap_or_else(|| error("MACSHELL_NIRI_PROFILE is not set")),
    )
}

fn journal_argument(args: &mut impl Iterator<Item = String>) -> std::ffi::OsString {
    args.next()
        .map(std::ffi::OsString::from)
        .unwrap_or_else(|| {
            error("usage: macshell-niri-input <diagnose|resolve-cleanup> <journal-name>")
        })
}

fn journals(profile: &Path) -> Result<Vec<std::ffi::OsString>, String> {
    let mut result = Vec::new();
    for entry in fs::read_dir(profile).map_err(|e| format!("cannot inspect profile: {e}"))? {
        let name = entry
            .map_err(|e| format!("cannot inspect profile: {e}"))?
            .file_name();
        if macshell_niri_input::journal_store::journal_name(&name).is_ok() {
            result.push(name);
        }
    }
    Ok(result)
}

fn diagnostic_json(diagnostic: &macshell_niri_input::recovery::Diagnostic) -> Value {
    use macshell_niri_input::recovery::{Observation, ProfileObservation, ProgressAgreement};
    let observation = |value: &Observation| match value {
        Observation::Original => "original",
        Observation::Exchanged => "exchanged",
        Observation::Conflict => "conflict",
    };
    let profile = match diagnostic.files.profile {
        ProfileObservation::AllOriginal => "all_original",
        ProfileObservation::AllExchanged => "all_exchanged",
        ProfileObservation::PartiallyExchanged => "partially_exchanged",
        ProfileObservation::Conflict => "conflict",
    };
    let agreement = match diagnostic.agreement {
        ProgressAgreement::Consistent => "consistent",
        ProgressAgreement::PendingExchange => "pending_exchange",
        ProgressAgreement::Conflict => "conflict",
    };
    serde_json::json!({
        "status": if agreement == "consistent" && profile == "all_exchanged" { "cleanup_safe" } else if agreement == "pending_exchange" { "pending" } else { "conflict" },
        "profile": profile,
        "agreement": agreement,
        "files": diagnostic.files.files.iter().map(observation).collect::<Vec<_>>(),
        "progressEvents": diagnostic.ledger.as_ref().map(|ledger| ledger.events().len()),
        "cleanupAllowed": agreement == "consistent" && profile == "all_exchanged",
    })
}

fn main() {
    let mut args = env::args().skip(1);
    let first = args.next();
    if first.as_deref() == Some("--protocol-version") {
        println!("macshell-niri-input 1");
        return;
    }
    if first.as_deref() == Some("resolve-cleanup") {
        let profile = profile();
        let journal = journal_argument(&mut args);
        macshell_niri_input::recovery::cleanup_completed(&profile, &journal)
            .unwrap_or_else(|e| error(format!("cleanup refused: {e}")));
        println!(
            "{}",
            serde_json::json!({"status":"cleaned", "journal": journal.to_string_lossy()})
        );
        return;
    }
    if first.as_deref() == Some("diagnose") {
        let profile = profile();
        let journal = match args.next() {
            Some(value) => std::ffi::OsString::from(value),
            None => {
                let available = journals(&profile).unwrap_or_else(|e| error(e));
                if available.is_empty() {
                    println!(
                        "{}",
                        serde_json::json!({"status":"clear", "cleanupAllowed":false, "files":[]})
                    );
                    return;
                }
                if available.len() > 1 {
                    println!(
                        "{}",
                        serde_json::json!({"status":"conflict", "cleanupAllowed":false, "error":"Multiple input transaction journals require manual inspection."})
                    );
                    return;
                }
                available.into_iter().next().expect("checked non-empty")
            }
        };
        let diagnostic = macshell_niri_input::recovery::diagnose(&profile, &journal)
            .unwrap_or_else(|e| error(format!("diagnosis failed: {e}")));
        println!("{}", diagnostic_json(&diagnostic));
        return;
    }
    if first.as_deref() != Some("input") {
        error("usage: macshell-niri-input input <json>");
    }
    let values: Value = args
        .next()
        .and_then(|v| serde_json::from_str(&v).ok())
        .unwrap_or_else(|| error("invalid input JSON"));
    let profile = profile();
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
