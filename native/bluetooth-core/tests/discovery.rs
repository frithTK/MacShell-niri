use macshell_bluetooth_core::discovery::{DiscoveryCore, Effect};
const A: &str = "/org/bluez/hci0";
const B: &str = "/org/bluez/hci1";
fn start(core: &mut DiscoveryCore, path: &str, now: u64) -> (u64, u64) {
    let effects = core.start(now, &[(path.into(), true)]).unwrap();
    match &effects[..] {
        [Effect::Start { epoch, token, .. }] => (*epoch, *token),
        other => panic!("unexpected: {other:?}"),
    }
}
fn stopped(effects: &[Effect]) -> (u64, u64) {
    match effects {
        [Effect::Stop { epoch, token, .. }] => (*epoch, *token),
        other => panic!("unexpected: {other:?}"),
    }
}
#[test]
fn only_enabled_adapters_are_started_and_our_reference_is_released_once() {
    let mut core = DiscoveryCore::new();
    let effects = core
        .start(
            0,
            &[
                (A.into(), true),
                (B.into(), false),
                ("/org/bluez/not-adapter".into(), true),
            ],
        )
        .unwrap();
    let [Effect::Start { epoch, token, path }] = effects.as_slice() else {
        panic!()
    };
    assert_eq!(path, A);
    assert!(core.started(A, *epoch, *token, true).is_empty());
    assert_eq!(core.owned(), 1);
    assert!(core.start(1, &[(A.into(), true)]).unwrap().is_empty());
    let effects = core.stop();
    let (epoch, token) = stopped(&effects);
    assert!(core.stop().is_empty());
    assert!(core.stopped(A, epoch, token, true).is_empty());
    assert_eq!(core.owned(), 0);
}
#[test]
fn cancel_during_start_stops_the_late_acquired_reference() {
    let mut core = DiscoveryCore::new();
    let (epoch, start_token) = start(&mut core, A, 0);
    assert!(core.stop().is_empty());
    let late = core.started(A, epoch, start_token, true);
    let (epoch, stop_token) = stopped(&late);
    assert_eq!(core.owned(), 1);
    assert!(core.stopped(A, epoch, stop_token, true).is_empty());
    assert_eq!(core.owned(), 0);
    assert!(core.started(A, epoch, start_token, true).is_empty());
}
#[test]
fn restart_while_stop_pending_waits_for_release_then_starts_again() {
    let mut core = DiscoveryCore::new();
    let (epoch, token) = start(&mut core, A, 0);
    core.started(A, epoch, token, true);
    let (epoch, stop_token) = stopped(&core.stop());
    assert!(core.start(10, &[(A.into(), true)]).unwrap().is_empty());
    let effects = core.stopped(A, epoch, stop_token, true);
    let [Effect::Start {
        epoch: new_epoch,
        token: new_token,
        ..
    }] = effects.as_slice()
    else {
        panic!()
    };
    assert_ne!(*new_token, token);
    assert!(core.started(A, *new_epoch, *new_token, true).is_empty());
    assert_eq!(core.owned(), 1);
}
#[test]
fn unknown_release_result_requires_new_connection_before_retry() {
    let mut core = DiscoveryCore::new();
    let (epoch, token) = start(&mut core, A, 0);
    core.started(A, epoch, token, true);
    let (epoch, token) = stopped(&core.stop());
    assert_eq!(
        core.stopped(A, epoch, token, false),
        vec![Effect::CloseConnection]
    );
    assert!(core.start(100, &[(A.into(), true)]).is_err());
    assert_eq!(core.owner_changed(), vec![Effect::CloseConnection]);
    assert!(core.start(200, &[(A.into(), true)]).is_err());
    core.connection_replaced();
    assert!(core.start(200, &[(A.into(), true)]).is_ok());
}
#[test]
fn expiry_and_owner_changes_reject_stale_async_completions() {
    let mut core = DiscoveryCore::new();
    let (epoch, token) = start(&mut core, A, 100);
    assert!(core.tick(30_100).is_empty());
    assert!(core.tick(30_101).is_empty());
    assert_eq!(core.owner_changed(), vec![Effect::CloseConnection]);
    core.connection_replaced();
    let (next_epoch, next_token) = start(&mut core, A, 40_000);
    assert_ne!(next_epoch, epoch);
    assert!(core.started(A, epoch, token, true).is_empty());
    assert_eq!(core.owned(), 0);
    assert!(core.started(A, next_epoch, next_token, true).is_empty());
    assert_eq!(core.owned(), 1);
    assert_eq!(core.tick(70_001).len(), 1);
}
#[test]
fn an_adapter_no_longer_requested_is_released_after_its_late_start() {
    let mut core = DiscoveryCore::new();
    let (epoch, token) = start(&mut core, A, 0);
    assert!(core.start(1, &[(A.into(), false)]).unwrap().is_empty());
    let (epoch, stop_token) = stopped(&core.started(A, epoch, token, true));
    assert!(core.stopped(A, epoch, stop_token, true).is_empty());
    assert_eq!(core.owned(), 0);
}
#[test]
fn an_owned_adapter_no_longer_requested_is_released() {
    let mut core = DiscoveryCore::new();
    let (epoch, token) = start(&mut core, A, 0);
    core.started(A, epoch, token, true);
    let effects = core.start(1, &[(A.into(), false)]).unwrap();
    let (epoch, token) = stopped(&effects);
    assert!(core.stopped(A, epoch, token, true).is_empty());
    assert_eq!(core.owned(), 0);
}
#[test]
fn uncertain_start_closes_connection_and_rejects_stale_results() {
    let mut core = DiscoveryCore::new();
    let (epoch, token) = start(&mut core, A, 0);
    assert!(core.start_uncertain(A, epoch, token + 1).is_empty());
    assert_eq!(
        core.start_uncertain(A, epoch, token),
        vec![Effect::CloseConnection]
    );
    assert!(core.started(A, epoch, token, true).is_empty());
    assert!(core.start(1, &[(A.into(), true)]).is_err());
    core.connection_replaced();
    assert!(core.start(2, &[(A.into(), true)]).is_ok());
}
