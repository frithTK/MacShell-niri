//! A fake process and a temporary file; never captures the user's screen.
use macshell_recording_core::{
    lifecycle::{Effect, Recorder, State},
    owned::{reserve, OwnedChild},
};
use std::io::{Read, Write};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

static SERIAL: AtomicU64 = AtomicU64::new(0);

#[test]
fn recorder_lifecycle_keeps_operation_owned_partial_file() {
    let path = std::env::temp_dir().join(format!(
        "macshell-fake-capture-{}-{}",
        std::process::id(),
        SERIAL.fetch_add(1, Ordering::Relaxed)
    ));
    let mut recorder = Recorder::default();
    recorder.start(0).unwrap();
    assert_eq!(recorder.tick(3000), [Effect::HideControls, Effect::Publish]);
    assert_eq!(recorder.tick(3400), [Effect::StartRecorder]);
    let mut output = reserve(&path).unwrap();
    output.write_all(b"partial-test-data").unwrap();
    drop(output);
    let mut child = OwnedChild::spawn(Command::new("/bin/sleep").arg("30")).unwrap();
    recorder.spawned(3400, true);
    assert!(recorder.ready(true, false).is_empty());
    recorder.ready(false, true);
    assert_eq!(recorder.state(), State::Recording);
    assert_eq!(
        recorder.fail(3500),
        [Effect::InterruptRecorder, Effect::Publish]
    );
    assert!(child.interrupt().unwrap());
    child.wait().unwrap();
    assert_eq!(
        recorder.child_exited(true),
        [Effect::Publish, Effect::CleanRoutes, Effect::ValidateFile]
    );
    recorder.validated(true);
    assert_eq!(recorder.state(), State::Error);
    let mut data = Vec::new();
    std::fs::File::open(&path)
        .unwrap()
        .read_to_end(&mut data)
        .unwrap();
    assert_eq!(data, b"partial-test-data");
    std::fs::remove_file(path).unwrap();
}
