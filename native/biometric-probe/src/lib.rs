//! Pure lifecycle model for one fprintd operation. No hardware is accessed here.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Enroll,
    Verify,
    Delete,
    Unlock,
}

/// Rejected scans before the lock screen stops listening and requires the password.
pub const UNLOCK_ATTEMPTS: u32 = 5;

pub fn valid_finger(finger: &str) -> bool {
    let Some((side, name)) = finger.split_once('-') else {
        return false;
    };
    matches!(side, "left" | "right")
        && matches!(
            name,
            "thumb" | "index-finger" | "middle-finger" | "ring-finger" | "little-finger"
        )
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Devices,
    Authorization,
    Claim,
    Fingers,
    Properties,
    Starting,
    Scanning,
    Deleting,
    Disconnected,
    Restarting,
    Stopping,
    Releasing,
    Finished,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResultMessage {
    pub success: bool,
    pub code: String,
    pub cleanup_failed: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Effect {
    Authorize,
    Claim,
    ListFingers,
    GetProperties,
    Start,
    Delete,
    GetDevices,
    Stop,
    Release,
    TerminateAuthorization,
    Status {
        code: String,
        stage: u32,
        total: u32,
    },
    Presence(Option<bool>),
    Result(ResultMessage),
}

pub struct Operation {
    pub action: Action,
    pub phase: Phase,
    pub stage: u32,
    pub total: u32,
    claimed: bool,
    active: bool,
    pending: bool,
    cancellation: Option<String>,
    result: Option<ResultMessage>,
    early: Vec<(String, bool)>,
    presence: Option<bool>,
    presence_seen: bool,
    early_overflow: bool,
}

impl Operation {
    pub fn new(action: Action) -> Self {
        Self {
            action,
            phase: Phase::Devices,
            stage: 0,
            total: 0,
            claimed: false,
            active: false,
            pending: true,
            cancellation: None,
            result: None,
            early: Vec::new(),
            presence: None,
            presence_seen: false,
            early_overflow: false,
        }
    }

    fn pending(&mut self, phase: Phase, effect: Effect) -> Vec<Effect> {
        self.phase = phase;
        self.pending = true;
        vec![effect]
    }

    fn finish(&mut self, success: bool, code: &str) -> Vec<Effect> {
        if self.result.is_none() {
            self.result = Some(ResultMessage {
                success,
                code: code.into(),
                cleanup_failed: false,
            });
        }
        self.cleanup()
    }

    fn cleanup(&mut self) -> Vec<Effect> {
        if self.active {
            self.active = false;
            return self.pending(Phase::Stopping, Effect::Stop);
        }
        if self.claimed {
            self.claimed = false;
            return self.pending(Phase::Releasing, Effect::Release);
        }
        self.phase = Phase::Finished;
        self.pending = false;
        vec![Effect::Result(
            self.result.clone().expect("finish before cleanup"),
        )]
    }

    fn cancelled(&mut self) -> Option<Vec<Effect>> {
        self.cancellation
            .clone()
            .map(|reason| self.finish(false, &reason))
    }

    pub fn cancel(&mut self, reason: &str) -> Vec<Effect> {
        if self.phase == Phase::Finished || self.result.is_some() {
            return vec![];
        }
        self.cancellation = Some(reason.into());
        if self.phase == Phase::Authorization {
            let mut effects = vec![Effect::TerminateAuthorization];
            effects.extend(self.finish(false, reason));
            return effects;
        }
        if self.pending {
            return vec![];
        }
        self.finish(false, reason)
    }

    pub fn devices(&mut self, found: bool, error: Option<&str>, authorize: bool) -> Vec<Effect> {
        if self.phase != Phase::Devices {
            return vec![];
        }
        self.pending = false;
        if let Some(error) = error {
            return self.finish(false, error);
        }
        if let Some(effects) = self.cancelled() {
            return effects;
        }
        if !found {
            return self.finish(false, "device_gone");
        }
        if authorize && matches!(self.action, Action::Enroll | Action::Delete) {
            self.phase = Phase::Authorization;
            return vec![Effect::Authorize];
        }
        self.pending(Phase::Claim, Effect::Claim)
    }

    pub fn authorized(&mut self, allowed: bool) -> Vec<Effect> {
        if self.phase != Phase::Authorization {
            return vec![];
        }
        if !allowed {
            return self.finish(false, "permission");
        }
        self.pending(Phase::Claim, Effect::Claim)
    }

    pub fn claimed(&mut self, error: Option<&str>) -> Vec<Effect> {
        if self.phase != Phase::Claim {
            return vec![];
        }
        self.pending = false;
        if let Some(error) = error {
            let code = self.cancellation.clone().unwrap_or_else(|| error.into());
            return self.finish(false, &code);
        }
        self.claimed = true;
        if let Some(effects) = self.cancelled() {
            return effects;
        }
        self.pending(Phase::Fingers, Effect::ListFingers)
    }

    pub fn fingers(&mut self, enrolled: bool, error: Option<&str>) -> Vec<Effect> {
        if self.phase != Phase::Fingers {
            return vec![];
        }
        self.pending = false;
        if let Some(effects) = self.cancelled() {
            return effects;
        }
        if let Some(error) = error {
            return self.finish(false, error);
        }
        if self.action == Action::Enroll && enrolled {
            return self.finish(false, "already_enrolled");
        }
        if self.action != Action::Enroll && !enrolled {
            return self.finish(false, "no_finger");
        }
        if self.action == Action::Delete {
            return self.pending(Phase::Deleting, Effect::Delete);
        }
        self.pending(Phase::Properties, Effect::GetProperties)
    }

    pub fn properties(&mut self, total: u32, presence: Option<bool>) -> Vec<Effect> {
        if self.phase != Phase::Properties {
            return vec![];
        }
        self.pending = false;
        if let Some(effects) = self.cancelled() {
            return effects;
        }
        self.total = if self.action == Action::Unlock {
            UNLOCK_ATTEMPTS
        } else {
            total.min(100)
        };
        if !self.presence_seen {
            self.presence = presence;
        }
        self.pending(Phase::Starting, Effect::Start)
    }

    pub fn presence(&mut self, present: Option<bool>) -> Vec<Effect> {
        if !matches!(
            self.phase,
            Phase::Properties | Phase::Starting | Phase::Scanning
        ) || self.cancellation.is_some()
        {
            return vec![];
        }
        self.presence_seen = true;
        self.presence = present;
        if self.phase == Phase::Scanning {
            vec![Effect::Presence(present)]
        } else {
            vec![]
        }
    }

    pub fn started(&mut self, error: Option<&str>) -> Vec<Effect> {
        if self.phase != Phase::Starting {
            return vec![];
        }
        self.pending = false;
        if let Some(error) = error {
            let code = self.cancellation.clone().unwrap_or_else(|| error.into());
            return self.finish(false, &code);
        }
        self.active = true;
        if let Some(effects) = self.cancelled() {
            return effects;
        }
        if self.early_overflow {
            return self.finish(false, "service_error");
        }
        self.phase = Phase::Scanning;
        let mut effects = vec![Effect::Status {
            code: "scan".into(),
            stage: self.stage,
            total: self.total,
        }];
        if self.presence_seen || self.presence.is_some() {
            effects.push(Effect::Presence(self.presence));
        }
        for (code, done) in std::mem::take(&mut self.early) {
            if self.phase != Phase::Scanning {
                break;
            }
            effects.extend(self.signal(&code, done));
        }
        effects
    }

    pub fn signal(&mut self, code: &str, done: bool) -> Vec<Effect> {
        if self.phase == Phase::Starting {
            if self.early.len() < 256 {
                self.early.push((code.into(), done));
            } else {
                self.early_overflow = true;
            }
            return vec![];
        }
        if self.phase != Phase::Scanning {
            return vec![];
        }
        if code == "enroll-stage-passed" {
            self.stage = self.stage.saturating_add(1);
        }
        if code.ends_with("-disconnected") {
            self.active = false;
            self.claimed = false;
            return self.pending(Phase::Disconnected, Effect::GetDevices);
        }
        if done && self.action == Action::Unlock && code == "verify-no-match" {
            self.stage = self.stage.saturating_add(1);
            let status = Effect::Status {
                code: code.into(),
                stage: self.stage,
                total: self.total,
            };
            let mut effects = vec![status];
            if self.stage >= UNLOCK_ATTEMPTS {
                effects.extend(self.finish(false, "too_many_attempts"));
            } else {
                self.active = false;
                effects.extend(self.pending(Phase::Restarting, Effect::Stop));
            }
            return effects;
        }
        if done {
            return self.finish(matches!(code, "enroll-completed" | "verify-match"), code);
        }
        vec![Effect::Status {
            code: code.into(),
            stage: self.stage,
            total: self.total,
        }]
    }

    pub fn disconnected(&mut self, still_present: bool) -> Vec<Effect> {
        if self.phase != Phase::Disconnected {
            return vec![];
        }
        self.pending = false;
        let code = self.cancellation.clone().unwrap_or_else(|| {
            if still_present {
                "driver_error"
            } else {
                "device_gone"
            }
            .into()
        });
        self.finish(false, &code)
    }

    pub fn deleted(&mut self, error: Option<&str>) -> Vec<Effect> {
        if self.phase != Phase::Deleting {
            return vec![];
        }
        self.pending = false;
        match error {
            Some(code) => self.finish(false, code),
            None => self.finish(true, "deleted"),
        }
    }

    /// The rejected verification has stopped; listen for the next scan unless the run ended meanwhile.
    pub fn restarted(&mut self, failed: bool) -> Vec<Effect> {
        if self.phase != Phase::Restarting {
            return vec![];
        }
        self.pending = false;
        if let Some(effects) = self.cancelled() {
            return effects;
        }
        if failed {
            return self.finish(false, "driver_error");
        }
        self.pending(Phase::Starting, Effect::Start)
    }

    pub fn cleaned(&mut self, failed: bool) -> Vec<Effect> {
        if !matches!(self.phase, Phase::Stopping | Phase::Releasing) {
            return vec![];
        }
        self.pending = false;
        if failed {
            self.result.as_mut().unwrap().cleanup_failed = true;
        }
        self.cleanup()
    }

    pub fn owner_lost(&mut self) -> Vec<Effect> {
        if self.phase == Phase::Finished
            || !(self.claimed
                || self.active
                || matches!(
                    self.phase,
                    Phase::Starting | Phase::Stopping | Phase::Releasing
                ))
        {
            return vec![];
        }
        if matches!(self.phase, Phase::Stopping | Phase::Releasing) {
            self.claimed = false;
            self.active = false;
            self.pending = false;
            if let Some(result) = self.result.as_mut() {
                result.cleanup_failed = true;
            }
            return self.cleanup();
        }
        self.claimed = false;
        self.active = false;
        self.pending = false;
        self.finish(false, "service_error")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn claimed(action: Action) -> Operation {
        let mut op = Operation::new(action);
        assert_eq!(op.devices(true, None, false), vec![Effect::Claim]);
        assert_eq!(op.claimed(None), vec![Effect::ListFingers]);
        op
    }

    #[test]
    fn cancel_during_claim_releases_and_late_events_are_ignored() {
        let mut op = Operation::new(Action::Enroll);
        op.devices(true, None, false);
        assert!(op.cancel("cancelled").is_empty());
        assert_eq!(op.claimed(None), vec![Effect::Release]);
        assert_eq!(
            op.cleaned(false),
            vec![Effect::Result(ResultMessage {
                success: false,
                code: "cancelled".into(),
                cleanup_failed: false
            })]
        );
        assert!(op.claimed(None).is_empty());
    }

    #[test]
    fn early_terminal_signal_and_cleanup_failure_preserve_result() {
        let mut op = claimed(Action::Enroll);
        assert_eq!(op.fingers(false, None), vec![Effect::GetProperties]);
        assert_eq!(op.properties(3, None), vec![Effect::Start]);
        assert!(op.signal("enroll-completed", true).is_empty());
        let effects = op.started(None);
        assert!(effects.contains(&Effect::Stop));
        assert!(op.signal("enroll-data-full", true).is_empty());
        assert_eq!(op.cleaned(true), vec![Effect::Release]);
        assert_eq!(
            op.cleaned(false),
            vec![Effect::Result(ResultMessage {
                success: true,
                code: "enroll-completed".into(),
                cleanup_failed: true
            })]
        );
    }

    #[test]
    fn presence_signal_wins_over_older_snapshot() {
        let mut op = claimed(Action::Verify);
        op.fingers(true, None);
        op.presence(Some(true));
        op.properties(0, Some(false));
        assert_eq!(op.started(None)[1], Effect::Presence(Some(true)));
        assert_eq!(op.presence(None), vec![Effect::Presence(None)]);
    }

    #[test]
    fn duplicate_and_absent_fingers_never_mutate() {
        let mut enroll = claimed(Action::Enroll);
        assert_eq!(enroll.fingers(true, None), vec![Effect::Release]);
        assert!(
            matches!(&enroll.cleaned(false)[0], Effect::Result(r) if r.code == "already_enrolled")
        );
        let mut delete = claimed(Action::Delete);
        assert_eq!(delete.fingers(false, None), vec![Effect::Release]);
        assert!(matches!(&delete.cleaned(false)[0], Effect::Result(r) if r.code == "no_finger"));
    }

    #[test]
    fn completed_delete_is_not_retroactively_cancelled() {
        let mut op = claimed(Action::Delete);
        assert_eq!(op.fingers(true, None), vec![Effect::Delete]);
        assert!(op.cancel("cancelled").is_empty());
        assert_eq!(op.deleted(None), vec![Effect::Release]);
        assert!(
            matches!(&op.cleaned(false)[0], Effect::Result(r) if r.success && r.code == "deleted")
        );
    }

    #[test]
    fn authorization_and_owner_loss_do_not_leak_claims() {
        let mut op = Operation::new(Action::Enroll);
        assert_eq!(op.devices(true, None, true), vec![Effect::Authorize]);
        assert!(op.owner_lost().is_empty());
        assert!(matches!(
            &op.cancel("cancelled")[..],
            [Effect::TerminateAuthorization, Effect::Result(_)]
        ));
        let mut claimed = claimed(Action::Verify);
        assert!(matches!(&claimed.owner_lost()[0], Effect::Result(r) if r.code == "service_error"));
        assert!(claimed.fingers(true, None).is_empty());
    }

    #[test]
    fn disconnected_queries_manager_and_never_sends_stop_or_release() {
        let mut op = claimed(Action::Verify);
        op.fingers(true, None);
        op.properties(0, None);
        op.started(None);
        assert_eq!(
            op.signal("verify-disconnected", true),
            vec![Effect::GetDevices]
        );
        assert!(matches!(&op.disconnected(true)[0], Effect::Result(r) if r.code == "driver_error"));
    }

    #[test]
    fn bounded_early_signal_overflow_fails_and_cleans_up() {
        let mut op = claimed(Action::Enroll);
        op.fingers(false, None);
        op.properties(3, None);
        for _ in 0..257 {
            op.signal("enroll-stage-passed", false);
        }
        assert_eq!(op.started(None), vec![Effect::Stop]);
        assert_eq!(op.cleaned(false), vec![Effect::Release]);
        assert!(matches!(&op.cleaned(false)[0], Effect::Result(r) if r.code == "service_error"));
    }

    #[test]
    fn daemon_loss_during_release_keeps_completed_result() {
        let mut op = claimed(Action::Delete);
        op.fingers(true, None);
        op.deleted(None);
        assert!(
            matches!(&op.owner_lost()[0], Effect::Result(r) if r.success && r.code == "deleted" && r.cleanup_failed)
        );
        assert!(op.cleaned(false).is_empty());
    }

    fn scanning_unlock() -> Operation {
        let mut op = Operation::new(Action::Unlock);
        assert_eq!(op.devices(true, None, true), vec![Effect::Claim]);
        assert_eq!(op.claimed(None), vec![Effect::ListFingers]);
        assert_eq!(op.fingers(true, None), vec![Effect::GetProperties]);
        assert_eq!(op.properties(15, None), vec![Effect::Start]);
        assert!(matches!(&op.started(None)[0], Effect::Status { code, stage: 0, total } if code == "scan" && *total == UNLOCK_ATTEMPTS));
        op
    }

    #[test]
    fn unlock_never_asks_for_authorization_and_requires_any_enrolled_finger() {
        let mut op = Operation::new(Action::Unlock);
        assert_eq!(op.devices(true, None, true), vec![Effect::Claim]);
        op.claimed(None);
        assert_eq!(op.fingers(false, None), vec![Effect::Release]);
        assert!(matches!(&op.cleaned(false)[0], Effect::Result(r) if !r.success && r.code == "no_finger"));
    }

    #[test]
    fn unlock_restarts_after_a_rejected_scan_and_succeeds_on_match() {
        let mut op = scanning_unlock();
        let effects = op.signal("verify-no-match", true);
        assert!(matches!(&effects[0], Effect::Status { code, stage: 1, .. } if code == "verify-no-match"));
        assert_eq!(effects[1], Effect::Stop);
        assert_eq!(op.phase, Phase::Restarting);
        assert!(op.signal("verify-match", true).is_empty());
        assert_eq!(op.restarted(false), vec![Effect::Start]);
        assert!(matches!(&op.started(None)[0], Effect::Status { code, stage: 1, .. } if code == "scan"));
        assert!(matches!(&op.signal("verify-retry-scan", false)[0], Effect::Status { code, .. } if code == "verify-retry-scan"));
        assert_eq!(op.signal("verify-match", true), vec![Effect::Stop]);
        assert_eq!(op.cleaned(false), vec![Effect::Release]);
        assert!(matches!(&op.cleaned(false)[0], Effect::Result(r) if r.success && r.code == "verify-match"));
    }

    #[test]
    fn unlock_stops_listening_after_the_attempt_limit() {
        let mut op = scanning_unlock();
        for attempt in 1..UNLOCK_ATTEMPTS {
            let effects = op.signal("verify-no-match", true);
            assert!(matches!(&effects[0], Effect::Status { stage, .. } if *stage == attempt));
            op.restarted(false);
            op.started(None);
        }
        let effects = op.signal("verify-no-match", true);
        assert!(matches!(&effects[0], Effect::Status { stage, .. } if *stage == UNLOCK_ATTEMPTS));
        assert_eq!(effects[1], Effect::Stop);
        assert_eq!(op.cleaned(false), vec![Effect::Release]);
        assert!(matches!(&op.cleaned(false)[0], Effect::Result(r) if !r.success && r.code == "too_many_attempts"));
    }

    #[test]
    fn unlock_cancel_while_restarting_releases_without_starting_again() {
        let mut op = scanning_unlock();
        op.signal("verify-no-match", true);
        assert!(op.cancel("cancelled").is_empty());
        assert_eq!(op.restarted(false), vec![Effect::Release]);
        assert!(matches!(&op.cleaned(false)[0], Effect::Result(r) if r.code == "cancelled"));
        let mut failed = scanning_unlock();
        failed.signal("verify-no-match", true);
        assert_eq!(failed.restarted(true), vec![Effect::Release]);
        assert!(matches!(&failed.cleaned(false)[0], Effect::Result(r) if r.code == "driver_error"));
    }

    #[test]
    fn plain_verify_still_finishes_on_the_first_rejection() {
        let mut op = claimed(Action::Verify);
        op.fingers(true, None);
        op.properties(0, None);
        op.started(None);
        assert_eq!(op.signal("verify-no-match", true), vec![Effect::Stop]);
    }

    #[test]
    fn finger_validation_excludes_wildcards_and_unknown_names() {
        assert!(valid_finger("right-index-finger"));
        assert!(valid_finger("left-thumb"));
        for name in [
            "any",
            "delete-all",
            "right-index",
            "right-thumb-extra",
            "left-",
            "LEFT-thumb",
        ] {
            assert!(!valid_finger(name));
        }
    }
}
