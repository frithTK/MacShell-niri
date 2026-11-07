//! Request authorization for a future NetworkManager SecretAgent.
//!
//! This state machine never receives, stores, returns or logs passwords. The
//! transport must associate any provided secret with its operation ticket and
//! erase it on completion or owner change. Owner identity and registration
//! results must come from the D-Bus name watcher and captured owner epoch.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ticket {
    epoch: u64,
    operation: u64,
    pub request: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Request {
    NotAuthorized,
    NoSecrets,
    UseProvided {
        request: u64,
    },
    /// If `discard_provided` is true, NetworkManager explicitly rejected the
    /// prior secret and the transport must erase it before prompting.
    Prompt {
        request: u64,
        prompt: u64,
        discard_provided: bool,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reset {
    pub request: Option<u64>,
    pub cancel_prompt: bool,
}

struct Operation {
    ticket: Ticket,
    uuid: String,
    profile: Option<String>,
    provided: bool,
    prompt: Option<(u64, String)>,
}

#[derive(Default)]
pub struct SecretAgent {
    owner: Option<String>,
    epoch: u64,
    sequence: u64,
    prompt_sequence: u64,
    registered: bool,
    registration_pending: bool,
    operation: Option<Operation>,
}

impl SecretAgent {
    pub fn new() -> Self {
        Self::default()
    }

    /// Every loss or replacement invalidates tickets, including reacquisition
    /// by the same unique owner. The transport must reject a pending call.
    pub fn owner_changed(&mut self, owner: Option<&str>) -> Result<Reset, &'static str> {
        if owner.is_some_and(|value| !valid_owner(value)) {
            return Err("Invalid NetworkManager owner");
        }
        let epoch = self.epoch.checked_add(1).ok_or("Owner epoch exhausted")?;
        let reset = self.reset_operation();
        self.epoch = epoch;
        self.owner = owner.map(str::to_owned);
        self.registered = false;
        self.registration_pending = self.owner.is_some();
        Ok(reset)
    }

    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    /// The sender must be the unique owner observed for the current epoch.
    pub fn authorized(&self, sender: &str) -> bool {
        self.registered && self.owner.as_deref() == Some(sender)
    }

    pub fn registered(&mut self, epoch: u64, success: bool) -> bool {
        if epoch != self.epoch || self.owner.is_none() || !self.registration_pending {
            return false;
        }
        self.registration_pending = false;
        self.registered = success;
        true
    }

    /// The UUID and optional profile path identify only this activation.
    /// `provided` says whether the transport has an initial password; no
    /// password passes through this state machine.
    pub fn begin(
        &mut self,
        request: u64,
        uuid: &str,
        profile: Option<&str>,
        provided: bool,
    ) -> Result<Ticket, &'static str> {
        if self.owner.is_none() || !self.registered {
            return Err("Wi-Fi password agent is unavailable");
        }
        if self.operation.is_some() {
            return Err("Wi-Fi operation already in progress");
        }
        if uuid.is_empty()
            || uuid.len() > 128
            || uuid.contains('\0')
            || profile.is_some_and(|path| !valid_profile(path))
        {
            return Err("Invalid Wi-Fi connection identity");
        }
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or("Operation sequence exhausted")?;
        let ticket = Ticket {
            epoch: self.epoch,
            operation: self.sequence,
            request,
        };
        self.operation = Some(Operation {
            ticket,
            uuid: uuid.into(),
            profile: profile.map(str::to_owned),
            provided,
            prompt: None,
        });
        Ok(ticket)
    }

    /// Accept only the current owner and matching connection, once at a time.
    pub fn get_secrets(
        &mut self,
        sender: &str,
        uuid: &str,
        profile: &str,
        setting: &str,
        flags: u32,
    ) -> Request {
        if self.owner.as_deref() != Some(sender) || !self.registered {
            return Request::NotAuthorized;
        }
        let Some(op) = self.operation.as_mut() else {
            return Request::NoSecrets;
        };
        if op.uuid != uuid
            || !(valid_profile(profile) || (op.profile.is_none() && profile == "/"))
            || op
                .profile
                .as_deref()
                .is_some_and(|expected| expected != profile)
            || setting != "802-11-wireless-security"
            || flags & 0x8000_0000 != 0
            || op.prompt.is_some()
        {
            return Request::NoSecrets;
        }
        let request_new = flags & 0x2 != 0;
        if op.provided && !request_new {
            op.provided = false;
            return Request::UseProvided {
                request: op.ticket.request,
            };
        }
        // NM allows interaction only with ALLOW_INTERACTION or REQUEST_NEW.
        if flags & 0x3 == 0 {
            return Request::NoSecrets;
        }
        let Some(next) = self.prompt_sequence.checked_add(1) else {
            return Request::NoSecrets;
        };
        let discard_provided = request_new && op.provided;
        if discard_provided {
            op.provided = false;
        }
        self.prompt_sequence = next;
        op.prompt = Some((next, profile.into()));
        Request::Prompt {
            request: op.ticket.request,
            prompt: next,
            discard_provided,
        }
    }

    /// A response may only satisfy its exact outstanding prompt and operation.
    pub fn answer(&mut self, ticket: Ticket, prompt: u64) -> bool {
        let Some(op) = self.operation.as_mut().filter(|op| op.ticket == ticket) else {
            return false;
        };
        if !op.prompt.as_ref().is_some_and(|(id, _)| *id == prompt) {
            return false;
        }
        op.prompt = None;
        true
    }

    /// NetworkManager can cancel only the pending request it identifies.
    pub fn cancel_get(&mut self, sender: &str, profile: &str, setting: &str) -> Option<u64> {
        if self.owner.as_deref() != Some(sender)
            || !self.registered
            || setting != "802-11-wireless-security"
        {
            return None;
        }
        let op = self.operation.as_mut()?;
        if !op.prompt.as_ref().is_some_and(|(_, path)| path == profile) {
            return None;
        }
        op.prompt = None;
        Some(op.ticket.request)
    }

    pub fn finish(&mut self, ticket: Ticket) -> Option<Reset> {
        if self.operation.as_ref().is_none_or(|op| op.ticket != ticket) {
            return None;
        }
        Some(self.reset_operation())
    }

    fn reset_operation(&mut self) -> Reset {
        let op = self.operation.take();
        Reset {
            request: op.as_ref().map(|op| op.ticket.request),
            cancel_prompt: op.as_ref().is_some_and(|op| op.prompt.is_some()),
        }
    }
}

fn valid_profile(path: &str) -> bool {
    const PREFIX: &str = "/org/freedesktop/NetworkManager/Settings/";
    path.len() <= 1024
        && path.strip_prefix(PREFIX).is_some_and(|tail| {
            !tail.is_empty()
                && tail.split('/').all(|segment| {
                    !segment.is_empty()
                        && segment
                            .bytes()
                            .all(|c| c.is_ascii_alphanumeric() || c == b'_')
                })
        })
}

fn valid_owner(value: &str) -> bool {
    value.len() <= 255
        && value.strip_prefix(':').is_some_and(|name| {
            let segments: Vec<_> = name.split('.').collect();
            segments.len() >= 2
                && segments.iter().all(|part| {
                    !part.is_empty()
                        && part
                            .bytes()
                            .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
                })
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    const PROFILE: &str = "/org/freedesktop/NetworkManager/Settings/3";
    const OTHER: &str = "/org/freedesktop/NetworkManager/Settings/4";
    const SETTING: &str = "802-11-wireless-security";

    fn ready() -> SecretAgent {
        let mut a = SecretAgent::new();
        a.owner_changed(Some(":1.7")).unwrap();
        assert!(a.registered(a.epoch(), true));
        assert!(!a.registered(a.epoch(), false));
        a
    }

    #[test]
    fn secrets_are_confined_to_current_owner_and_connection() {
        let mut a = ready();
        let ticket = a.begin(4, "uuid", Some(PROFILE), true).unwrap();
        assert_eq!(
            a.get_secrets(":1.8", "uuid", PROFILE, SETTING, 1),
            Request::NotAuthorized
        );
        assert_eq!(
            a.get_secrets(":1.7", "other", PROFILE, SETTING, 1),
            Request::NoSecrets
        );
        assert_eq!(
            a.get_secrets(":1.7", "uuid", OTHER, SETTING, 1),
            Request::NoSecrets
        );
        assert_eq!(
            a.get_secrets(":1.7", "uuid", PROFILE, "802-1x", 1),
            Request::NoSecrets
        );
        assert_eq!(
            a.get_secrets(":1.7", "uuid", PROFILE, SETTING, 1),
            Request::UseProvided { request: 4 }
        );
        let Request::Prompt {
            request: 4, prompt, ..
        } = a.get_secrets(":1.7", "uuid", PROFILE, SETTING, 1)
        else {
            panic!("expected prompt")
        };
        assert_eq!(
            a.get_secrets(":1.7", "uuid", PROFILE, SETTING, 1),
            Request::NoSecrets
        );
        assert!(!a.answer(ticket, prompt + 1));
        assert!(a.answer(ticket, prompt));
        assert!(!a.answer(ticket, prompt));
        assert_eq!(
            a.finish(ticket).unwrap(),
            Reset {
                request: Some(4),
                cancel_prompt: false
            }
        );
    }

    #[test]
    fn owner_replacement_cancels_prompt_and_stale_callbacks() {
        let mut a = ready();
        let old_epoch = a.epoch();
        let ticket = a.begin(7, "uuid", None, false).unwrap();
        let Request::Prompt { prompt, .. } = a.get_secrets(":1.7", "uuid", PROFILE, SETTING, 1)
        else {
            panic!("expected prompt")
        };
        assert_eq!(
            a.owner_changed(Some(":1.7")).unwrap(),
            Reset {
                request: Some(7),
                cancel_prompt: true
            }
        );
        assert!(!a.registered(old_epoch, true));
        assert!(!a.answer(ticket, prompt));
        assert_eq!(
            a.get_secrets(":1.7", "uuid", PROFILE, SETTING, 1),
            Request::NotAuthorized
        );
        assert!(a.registered(a.epoch(), true));
        let next = a.begin(7, "uuid", None, false).unwrap();
        assert_ne!(next, ticket);
        assert!(a.finish(ticket).is_none());
        assert!(a.finish(next).is_some());
    }

    #[test]
    fn cancellation_is_scoped_and_new_prompts_have_new_ids() {
        let mut a = ready();
        let ticket = a.begin(1, "id", None, false).unwrap();
        let Request::Prompt { prompt, .. } = a.get_secrets(":1.7", "id", PROFILE, SETTING, 1)
        else {
            panic!("expected prompt")
        };
        assert_eq!(a.cancel_get(":1.8", PROFILE, SETTING), None);
        assert_eq!(a.cancel_get(":1.7", OTHER, SETTING), None);
        assert_eq!(a.cancel_get(":1.7", PROFILE, "802-1x"), None);
        assert_eq!(a.cancel_get(":1.7", PROFILE, SETTING), Some(1));
        assert!(!a.answer(ticket, prompt));
        let Request::Prompt { prompt: next, .. } = a.get_secrets(":1.7", "id", PROFILE, SETTING, 1)
        else {
            panic!("expected prompt")
        };
        assert_ne!(prompt, next);
        assert!(a.finish(ticket).unwrap().cancel_prompt);
    }

    #[test]
    fn unavailable_and_invalid_operations_fail_closed() {
        let mut a = SecretAgent::new();
        assert!(a.begin(1, "id", None, true).is_err());
        assert!(a
            .owner_changed(Some("org.freedesktop.NetworkManager"))
            .is_err());
        a.owner_changed(Some(":1.7")).unwrap();
        a.registered(a.epoch(), true);
        assert!(a.begin(1, "", None, true).is_err());
        assert!(a.begin(1, "id", Some("/foreign"), true).is_err());
        let ticket = a.begin(1, "id", None, true).unwrap();
        assert!(a.begin(2, "id", None, true).is_err());
        assert_eq!(
            a.get_secrets(":1.7", "id", "/foreign", SETTING, 1),
            Request::NoSecrets
        );
        assert!(a.finish(ticket).is_some());
    }

    #[test]
    fn not_yet_saved_connection_may_use_root_object_path() {
        let mut a = ready();
        let ticket = a.begin(8, "new-uuid", None, true).unwrap();
        assert_eq!(
            a.get_secrets(":1.7", "new-uuid", "/", SETTING, 0),
            Request::UseProvided { request: 8 }
        );
        assert!(a.finish(ticket).is_some());
        let saved = a.begin(9, "saved-uuid", Some(PROFILE), true).unwrap();
        assert_eq!(
            a.get_secrets(":1.7", "saved-uuid", "/", SETTING, 0),
            Request::NoSecrets
        );
        assert!(a.finish(saved).is_some());
    }

    #[test]
    fn interaction_flags_and_request_new_are_respected() {
        let mut a = ready();
        let ticket = a.begin(5, "uuid", None, true).unwrap();
        assert!(matches!(
            a.get_secrets(":1.7", "uuid", PROFILE, SETTING, 2),
            Request::Prompt {
                request: 5,
                discard_provided: true,
                ..
            }
        ));
        assert!(a.finish(ticket).unwrap().cancel_prompt);

        let next = a.begin(6, "uuid", None, false).unwrap();
        assert_eq!(
            a.get_secrets(":1.7", "uuid", PROFILE, SETTING, 0x8000_0001),
            Request::NoSecrets
        );
        assert_eq!(
            a.get_secrets(":1.7", "uuid", PROFILE, SETTING, 0),
            Request::NoSecrets
        );
        assert!(matches!(
            a.get_secrets(":1.7", "uuid", PROFILE, SETTING, 1),
            Request::Prompt {
                request: 6,
                discard_provided: false,
                ..
            }
        ));
        assert!(a.finish(next).unwrap().cancel_prompt);
    }
}
