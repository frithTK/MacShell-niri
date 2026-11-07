//! Pure lifecycle for a user-requested NetworkManager activation.
//!
//! This module does not send D-Bus calls. The transport must pin each call to
//! the captured unique owner, enforce deadlines, and execute each emitted action
//! at most once. Cancellation targets only the returned ActiveConnection and
//! checks it is still activating before dispatch. NetworkManager does not
//! offer an atomic compare-and-deactivate operation. Never retry uncertain calls.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ticket {
    epoch: u64,
    sequence: u64,
    pub request: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    Ignore,
    Wait,
    Observe(String),
    InspectForCancel(String),
    ConfirmCanceled(String),
    Deactivate(String),
    Connected,
    Canceled,
    Failed,
    /// The dedicated connection must be closed; an in-flight call may have
    /// taken effect. The caller must not repeat it automatically.
    CloseUncertain,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StartError {
    Rejected,
    Uncertain,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActiveState {
    Unknown,
    Activating,
    Activated,
    Deactivating,
    Deactivated,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Observation {
    Watch,
    CancelInspection,
    CancelConfirmation,
}

enum Phase {
    Starting { canceled: bool },
    Watching(String),
    Inspecting(String),
    Deactivating(String),
    ConfirmCancel(String),
}
struct Operation {
    ticket: Ticket,
    phase: Phase,
}

#[derive(Default)]
pub struct Activation {
    epoch: u64,
    sequence: u64,
    owner: Option<String>,
    operation: Option<Operation>,
    blocked: bool,
}

impl Activation {
    pub fn new() -> Self {
        Self::default()
    }

    /// Every transition invalidates the old ticket, even if the same unique
    /// owner later reacquires the well-known name.
    pub fn owner_changed(&mut self, owner: Option<&str>) -> Result<Action, &'static str> {
        if self.blocked {
            return Err("Close connection and recreate activation state");
        }
        if owner.is_some_and(|s| !valid_owner(s)) {
            return Err("Invalid NetworkManager owner");
        }
        let epoch = self.epoch.checked_add(1).ok_or("Owner epoch exhausted")?;
        let active = self.operation.take().is_some();
        self.owner = if active {
            None
        } else {
            owner.map(str::to_owned)
        };
        self.epoch = epoch;
        if active {
            self.blocked = true;
        }
        Ok(if active {
            Action::CloseUncertain
        } else {
            Action::Ignore
        })
    }

    /// Caller captures the AP and device identity before dispatching exactly
    /// one activation request, and supplies its eventual result to `started`.
    pub fn begin(&mut self, request: u64, device: &str, ap: &str) -> Result<Ticket, &'static str> {
        if self.owner.is_none() || self.blocked {
            return Err("NetworkManager is unavailable");
        }
        if self.operation.is_some() {
            return Err("Wi-Fi operation already in progress");
        }
        if !valid_path(device, "/org/freedesktop/NetworkManager/Devices/")
            || !valid_path(ap, "/org/freedesktop/NetworkManager/AccessPoint/")
        {
            return Err("Invalid Wi-Fi device or access point");
        }
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or("Operation sequence exhausted")?;
        let ticket = Ticket {
            epoch: self.epoch,
            sequence: self.sequence,
            request,
        };
        self.operation = Some(Operation {
            ticket,
            phase: Phase::Starting { canceled: false },
        });
        Ok(ticket)
    }

    /// The transport supplies the exact path returned by NetworkManager.
    pub fn started(&mut self, ticket: Ticket, result: Result<(&str, bool), StartError>) -> Action {
        let Some(op) = self.operation.as_mut().filter(|op| op.ticket == ticket) else {
            return Action::Ignore;
        };
        let Phase::Starting { canceled } = op.phase else {
            return Action::Ignore;
        };
        match result {
            Err(StartError::Uncertain) => self.finish(Action::CloseUncertain),
            Err(StartError::Rejected) => self.finish(if canceled {
                Action::Canceled
            } else {
                Action::Failed
            }),
            Ok((path, _))
                if !valid_path(path, "/org/freedesktop/NetworkManager/ActiveConnection/") =>
            {
                self.finish(Action::CloseUncertain)
            }
            Ok((path, _)) if canceled => {
                op.phase = Phase::Inspecting(path.into());
                Action::InspectForCancel(path.into())
            }
            Ok((path, _)) => {
                op.phase = Phase::Watching(path.into());
                Action::Observe(path.into())
            }
        }
    }

    /// Cancellation before the method reply waits for the returned connection
    /// identity; it never disconnects a guessed or pre-existing connection.
    pub fn cancel(&mut self, ticket: Ticket) -> Action {
        let Some(op) = self.operation.as_mut().filter(|op| op.ticket == ticket) else {
            return Action::Ignore;
        };
        match &mut op.phase {
            Phase::Starting { canceled } => {
                *canceled = true;
                Action::Wait
            }
            Phase::Watching(path) => {
                let path = path.clone();
                op.phase = Phase::Inspecting(path.clone());
                Action::InspectForCancel(path)
            }
            _ => Action::Ignore,
        }
    }

    /// State belongs to the exact path and purpose requested in the preceding
    /// action. The transport must serialize each observation and fence its
    /// own request ID so a duplicate or late reply cannot be delivered twice.
    pub fn observed(
        &mut self,
        ticket: Ticket,
        path: &str,
        purpose: Observation,
        state: Result<ActiveState, ()>,
    ) -> Action {
        let Some(op) = self.operation.as_mut().filter(|op| op.ticket == ticket) else {
            return Action::Ignore;
        };
        match &op.phase {
            Phase::Watching(expected) if expected == path && purpose == Observation::Watch => {
                match state {
                    Ok(ActiveState::Activated) => self.finish(Action::Connected),
                    Ok(ActiveState::Deactivated) => self.finish(Action::Failed),
                    Ok(_) => Action::Wait,
                    Err(()) => self.finish(Action::CloseUncertain),
                }
            }
            Phase::Inspecting(expected)
                if expected == path && purpose == Observation::CancelInspection =>
            {
                match state {
                    Ok(ActiveState::Activated) => self.finish(Action::Connected),
                    Ok(ActiveState::Activating) => {
                        let path = expected.clone();
                        op.phase = Phase::Deactivating(path.clone());
                        Action::Deactivate(path)
                    }
                    Ok(ActiveState::Deactivating) => Action::Wait,
                    Ok(ActiveState::Deactivated) => self.finish(Action::Canceled),
                    // Unknown or changing state is not safe to disconnect.
                    Ok(_) | Err(()) => self.finish(Action::CloseUncertain),
                }
            }
            Phase::ConfirmCancel(expected)
                if expected == path && purpose == Observation::CancelConfirmation =>
            {
                match state {
                    Ok(ActiveState::Deactivated) => self.finish(Action::Canceled),
                    Ok(_) => Action::Wait,
                    Err(()) => self.finish(Action::CloseUncertain),
                }
            }
            _ => Action::Ignore,
        }
    }

    pub fn deactivated(&mut self, ticket: Ticket, path: &str, success: bool) -> Action {
        let Some(op) = self.operation.as_mut().filter(|op| op.ticket == ticket) else {
            return Action::Ignore;
        };
        let Phase::Deactivating(expected) = &op.phase else {
            return Action::Ignore;
        };
        if expected != path {
            return Action::Ignore;
        }
        if !success {
            return self.finish(Action::CloseUncertain);
        }
        let path = expected.clone();
        op.phase = Phase::ConfirmCancel(path.clone());
        Action::ConfirmCanceled(path)
    }

    pub fn cancel_found_connected(&mut self, ticket: Ticket, path: &str) -> Action {
        let Some(op) = self.operation.as_ref().filter(|op| op.ticket == ticket) else {
            return Action::Ignore;
        };
        if matches!(&op.phase, Phase::Deactivating(expected) if expected == path) {
            self.finish(Action::Connected)
        } else {
            Action::Ignore
        }
    }

    /// A bounded deadline never guesses whether an outstanding call succeeded.
    pub fn timeout(&mut self, ticket: Ticket) -> Action {
        if self.operation.as_ref().is_none_or(|op| op.ticket != ticket) {
            return Action::Ignore;
        }
        self.finish(Action::CloseUncertain)
    }

    fn finish(&mut self, result: Action) -> Action {
        self.operation = None;
        if result == Action::CloseUncertain {
            self.owner = None;
            self.blocked = true;
        }
        result
    }
}

fn valid_path(path: &str, prefix: &str) -> bool {
    path.len() <= 1024
        && path.strip_prefix(prefix).is_some_and(|tail| {
            !tail.is_empty()
                && tail.split('/').all(|part| {
                    !part.is_empty() && part.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
                })
        })
}
fn valid_owner(owner: &str) -> bool {
    owner.len() <= 255
        && owner.strip_prefix(':').is_some_and(|v| {
            let mut parts = v.split('.');
            let valid = |part: &str| {
                !part.is_empty()
                    && part
                        .bytes()
                        .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
            };
            parts.next().is_some_and(valid) && parts.next().is_some_and(valid) && parts.all(valid)
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    const DEV: &str = "/org/freedesktop/NetworkManager/Devices/1";
    const AP: &str = "/org/freedesktop/NetworkManager/AccessPoint/1";
    const ACTIVE: &str = "/org/freedesktop/NetworkManager/ActiveConnection/1";

    fn active() -> (Activation, Ticket) {
        let mut a = Activation::new();
        a.owner_changed(Some(":1.42")).unwrap();
        let ticket = a.begin(7, DEV, AP).unwrap();
        (a, ticket)
    }
    #[test]
    fn connection_is_confirmed_before_success() {
        let (mut a, t) = active();
        assert_eq!(
            a.started(t, Ok((ACTIVE, false))),
            Action::Observe(ACTIVE.into())
        );
        assert_eq!(
            a.observed(t, ACTIVE, Observation::Watch, Ok(ActiveState::Activating)),
            Action::Wait
        );
        assert_eq!(
            a.observed(t, ACTIVE, Observation::Watch, Ok(ActiveState::Activated)),
            Action::Connected
        );
        assert_eq!(
            a.observed(t, ACTIVE, Observation::Watch, Ok(ActiveState::Deactivated)),
            Action::Ignore
        );
        let next = a.begin(7, DEV, AP).unwrap();
        assert_ne!(t, next);
        assert_eq!(a.started(t, Ok((ACTIVE, true))), Action::Ignore);
    }
    #[test]
    fn cancel_before_reply_waits_then_inspects_exact_path() {
        let (mut a, t) = active();
        assert_eq!(a.cancel(t), Action::Wait);
        assert_eq!(
            a.started(t, Ok((ACTIVE, true))),
            Action::InspectForCancel(ACTIVE.into())
        );
        assert_eq!(
            a.observed(
                t,
                "/foreign",
                Observation::CancelInspection,
                Ok(ActiveState::Activating)
            ),
            Action::Ignore
        );
        assert_eq!(
            a.observed(
                t,
                ACTIVE,
                Observation::CancelInspection,
                Ok(ActiveState::Activating)
            ),
            Action::Deactivate(ACTIVE.into())
        );
        assert_eq!(a.deactivated(t, "/foreign", true), Action::Ignore);
        assert_eq!(
            a.deactivated(t, ACTIVE, true),
            Action::ConfirmCanceled(ACTIVE.into())
        );
        assert_eq!(
            a.observed(
                t,
                ACTIVE,
                Observation::CancelConfirmation,
                Ok(ActiveState::Deactivating)
            ),
            Action::Wait
        );
        assert_eq!(
            a.observed(
                t,
                ACTIVE,
                Observation::CancelConfirmation,
                Ok(ActiveState::Deactivated)
            ),
            Action::Canceled
        );
    }
    #[test]
    fn cancellation_targets_returned_attempt_and_preserves_already_active_connection() {
        let (mut a, t) = active();
        a.started(t, Ok((ACTIVE, false)));
        a.cancel(t);
        // A late normal poll must not be interpreted as the cancel preflight.
        assert_eq!(
            a.observed(t, ACTIVE, Observation::Watch, Ok(ActiveState::Activating)),
            Action::Ignore
        );
        assert_eq!(
            a.observed(
                t,
                ACTIVE,
                Observation::CancelInspection,
                Ok(ActiveState::Activating)
            ),
            Action::Deactivate(ACTIVE.into())
        );
        assert_eq!(
            a.deactivated(t, ACTIVE, true),
            Action::ConfirmCanceled(ACTIVE.into())
        );
        assert_eq!(
            a.observed(
                t,
                ACTIVE,
                Observation::CancelConfirmation,
                Ok(ActiveState::Deactivated)
            ),
            Action::Canceled
        );
        let (mut a, t) = active();
        a.started(t, Ok((ACTIVE, true)));
        a.cancel(t);
        assert_eq!(
            a.observed(
                t,
                ACTIVE,
                Observation::CancelInspection,
                Ok(ActiveState::Activated)
            ),
            Action::Connected
        );
        let (mut a, t) = active();
        a.started(t, Ok((ACTIVE, false)));
        a.cancel(t);
        assert_eq!(
            a.observed(
                t,
                ACTIVE,
                Observation::CancelInspection,
                Ok(ActiveState::Activating)
            ),
            Action::Deactivate(ACTIVE.into())
        );
        assert_eq!(a.cancel_found_connected(t, "/foreign"), Action::Ignore);
        assert_eq!(a.cancel_found_connected(t, ACTIVE), Action::Connected);
    }
    #[test]
    fn rejected_or_unknown_reply_never_retries() {
        let (mut a, t) = active();
        assert_eq!(
            a.started(t, Err(StartError::Uncertain)),
            Action::CloseUncertain
        );
        assert_eq!(a.started(t, Ok((ACTIVE, true))), Action::Ignore);
        let (mut a, t) = active();
        a.cancel(t);
        assert_eq!(a.started(t, Err(StartError::Rejected)), Action::Canceled);
        let (mut a, t) = active();
        assert_eq!(a.started(t, Ok(("/foreign", true))), Action::CloseUncertain);
    }
    #[test]
    fn owner_reacquisition_invalidates_all_callbacks() {
        let (mut a, old) = active();
        assert_eq!(
            a.owner_changed(Some(":1.42")).unwrap(),
            Action::CloseUncertain
        );
        assert!(a.begin(7, DEV, AP).is_err());
        assert!(a.owner_changed(Some(":1.42")).is_err());
        assert_eq!(a.started(old, Ok((ACTIVE, true))), Action::Ignore);
        assert_eq!(a.cancel(old), Action::Ignore);
    }
    #[test]
    fn timeout_and_unknown_cancel_state_close_without_disconnect() {
        let (mut a, t) = active();
        a.started(t, Ok((ACTIVE, true)));
        a.cancel(t);
        assert_eq!(
            a.observed(
                t,
                ACTIVE,
                Observation::CancelInspection,
                Ok(ActiveState::Unknown)
            ),
            Action::CloseUncertain
        );
        let (mut a, t) = active();
        a.cancel(t);
        assert_eq!(a.timeout(t), Action::CloseUncertain);
        assert_eq!(a.started(t, Ok((ACTIVE, true))), Action::Ignore);
    }
    #[test]
    fn duplicate_and_failure_responses_are_fenced() {
        let (mut a, t) = active();
        a.started(t, Ok((ACTIVE, true)));
        assert_eq!(a.started(t, Ok((ACTIVE, true))), Action::Ignore);
        a.cancel(t);
        a.observed(
            t,
            ACTIVE,
            Observation::CancelInspection,
            Ok(ActiveState::Activating),
        );
        assert_eq!(a.deactivated(t, ACTIVE, false), Action::CloseUncertain);
        assert_eq!(a.deactivated(t, ACTIVE, true), Action::Ignore);
    }
    #[test]
    fn invalid_input_and_overlapping_operations_are_rejected() {
        let mut a = Activation::new();
        assert!(a.begin(1, DEV, AP).is_err());
        assert!(a
            .owner_changed(Some("org.freedesktop.NetworkManager"))
            .is_err());
        a.owner_changed(Some(":1.1")).unwrap();
        assert!(a.begin(1, "/other", AP).is_err());
        assert!(a.begin(1, DEV, "/other").is_err());
        assert!(a.begin(1, DEV, AP).is_ok());
        assert!(a.begin(2, DEV, AP).is_err());
    }
}
