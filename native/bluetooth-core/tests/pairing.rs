use macshell_bluetooth_core::pairing::{
    valid_device, AgentResult, Method, PairingCore, Reply, Step,
};
const DEVICE: &str = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF";
fn started() -> (PairingCore, macshell_bluetooth_core::pairing::Ticket) {
    let mut core = PairingCore::new();
    core.owner_changed(Some(":1.42"));
    assert!(core.registered(core.epoch(), true));
    let ticket = core.begin(7, DEVICE, "Keyboard", 100).unwrap();
    (core, ticket)
}
fn prompt(core: &mut PairingCore, method: Method) -> macshell_bluetooth_core::pairing::Prompt {
    match core.agent(":1.42", Some(DEVICE), method) {
        AgentResult::Prompt { value, .. } => value,
        other => panic!("unexpected: {other:?}"),
    }
}
#[test]
fn rejects_unsolicited_wrong_owner_wrong_device_and_invalid_path() {
    let mut core = PairingCore::new();
    core.owner_changed(Some(":1.42"));
    core.registered(core.epoch(), true);
    assert!(matches!(
        core.agent(":1.42", Some(DEVICE), Method::RequestAuthorization),
        AgentResult::Rejected(_)
    ));
    for path in [
        "/org/bluez/hci0",
        "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF;bad",
        "/org/bluez/hciX/dev_AA_BB_CC_DD_EE_FF",
        "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_GG",
    ] {
        assert!(!valid_device(path));
        assert!(core.begin(1, path, "x", 0).is_err());
    }
    assert!(valid_device(DEVICE));
    assert!(valid_device("/org/bluez/hci42/dev_aa_bb_cc_dd_ee_ff"));
    core.begin(7, DEVICE, "Keyboard", 0).unwrap();
    assert!(matches!(
        core.agent(":1.attacker", Some(DEVICE), Method::RequestConfirmation(42)),
        AgentResult::Rejected(_)
    ));
    assert!(matches!(
        core.agent(
            ":1.42",
            Some("/org/bluez/hci0/dev_00_00_00_00_00_00"),
            Method::RequestConfirmation(42)
        ),
        AgentResult::Rejected(_)
    ));
    assert!(core.current_prompt().is_none());
}
#[test]
fn confirmation_needs_matching_prompt_and_preserves_leading_zeroes() {
    let (mut core, _) = started();
    let p = prompt(&mut core, Method::RequestConfirmation(42));
    assert_eq!(p.code, "000042");
    assert!(p.deferred);
    assert_eq!(p.request, 7);
    assert_eq!(core.respond(p.id + 1, true, "").unwrap(), Reply::Ignored);
    assert!(core.current_prompt().is_some());
    assert_eq!(core.respond(p.id, true, "").unwrap(), Reply::Accepted);
    assert!(core.current_prompt().is_none());
    assert_eq!(core.respond(p.id, true, "").unwrap(), Reply::Ignored);
}
#[test]
fn pin_passkey_and_replaced_prompt_are_validated_without_losing_pending_reply() {
    let (mut core, _) = started();
    let p = prompt(&mut core, Method::RequestPinCode);
    assert!(core.respond(p.id, true, "").is_err());
    assert!(core.respond(p.id, true, "12345678901234567").is_err());
    assert!(core.respond(p.id, true, "bad\0pin").is_err());
    assert!(core.current_prompt().is_some());
    assert_eq!(
        core.respond(p.id, true, "001234").unwrap(),
        Reply::Pin("001234".into())
    );
    let p = prompt(&mut core, Method::RequestPasskey);
    assert!(core.respond(p.id, true, "1234567").is_err());
    assert!(core.respond(p.id, true, "１２").is_err());
    assert_eq!(
        core.respond(p.id, true, "000042").unwrap(),
        Reply::Passkey(42)
    );
    let old = prompt(&mut core, Method::RequestAuthorization);
    let next = core.agent(
        ":1.42",
        Some(DEVICE),
        Method::DisplayPasskey {
            code: 8,
            entered: 2,
        },
    );
    let AgentResult::Prompt {
        value,
        cancel_previous,
    } = next
    else {
        panic!()
    };
    assert!(cancel_previous);
    assert!(!value.deferred);
    assert_eq!(value.code, "000008");
    assert_eq!(value.entered, 2);
    assert_eq!(core.respond(old.id, true, "").unwrap(), Reply::Ignored);
    assert_eq!(core.respond(value.id, true, "").unwrap(), Reply::Ignored);
}
#[test]
fn canceled_and_stale_callbacks_never_trust_or_connect() {
    let (mut core, old) = started();
    let p = prompt(&mut core, Method::RequestAuthorization);
    assert_eq!(
        core.respond(p.id, false, "").unwrap(),
        Reply::Cancel {
            request: 7,
            device: DEVICE.into(),
            cancel_prompt: true
        }
    );
    let new = core.begin(7, DEVICE, "Keyboard", 200).unwrap();
    assert_ne!(old, new);
    assert_eq!(core.paired(old, true), Step::Ignored);
    assert_eq!(core.trusted(old, true), Step::Ignored);
    assert_eq!(core.connected(old, true), Step::Ignored);
    assert_eq!(
        core.paired(new, true),
        Step::Trust {
            request: 7,
            device: DEVICE.into(),
            cancel_prompt: false
        }
    );
    assert_eq!(
        core.trusted(new, true),
        Step::Connect {
            request: 7,
            device: DEVICE.into()
        }
    );
    assert!(matches!(
        core.connected(new, true),
        Step::Finished {
            success: true,
            phase: "connected",
            ..
        }
    ));
    assert_eq!(core.connected(new, true), Step::Ignored);
}
#[test]
fn owner_restart_and_timeout_clear_inflight_authorization() {
    let (mut core, ticket) = started();
    let p = prompt(&mut core, Method::RequestPinCode);
    let reset = core.owner_changed(Some(":1.42"));
    assert_eq!(reset.failed_request, Some(7));
    assert!(reset.cancel_prompt);
    assert_eq!(core.respond(p.id, true, "1234").unwrap(), Reply::Ignored);
    assert_eq!(core.paired(ticket, true), Step::Ignored);
    assert!(!core.registered(ticket.epoch, true));
    assert!(core.registered(core.epoch(), true));
    core.begin(9, DEVICE, "Keyboard", 100).unwrap();
    assert_eq!(core.expired(65_100), None);
    assert_eq!(
        core.expired(65_101),
        Some(Reply::Cancel {
            request: 9,
            device: DEVICE.into(),
            cancel_prompt: false
        })
    );
    assert_eq!(core.expired(100_000), None);
}
#[test]
fn no_trust_without_confirmation_and_trust_failure_does_not_connect() {
    let (mut core, ticket) = started();
    assert!(matches!(
        core.paired(ticket, false),
        Step::Finished { success: false, .. }
    ));
    assert_eq!(core.trusted(ticket, true), Step::Ignored);
    let ticket = core.begin(8, DEVICE, "Keyboard", 200).unwrap();
    let _ = core.paired(ticket, true);
    assert!(matches!(
        core.trusted(ticket, false),
        Step::Finished {
            success: false,
            phase: "paired",
            ..
        }
    ));
    assert_eq!(core.connected(ticket, true), Step::Ignored);
}
#[test]
fn release_and_cancel_return_deferred_prompt_to_transport_for_rejection() {
    let (mut core, _) = started();
    let _ = prompt(&mut core, Method::RequestAuthorization);
    assert_eq!(
        core.agent(":1.bad", None, Method::Release),
        AgentResult::Rejected("Unknown caller")
    );
    assert_eq!(
        core.agent(":1.42", None, Method::Release),
        AgentResult::Cleared {
            cancel_previous: true,
            released: true
        }
    );
    core.cancel(7);
    assert!(core.begin(8, DEVICE, "Keyboard", 0).is_err());
}
