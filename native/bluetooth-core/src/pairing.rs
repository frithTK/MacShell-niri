//! Authorization and lifecycle for one explicit user-initiated pairing.

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Method {
    RequestPinCode,
    DisplayPinCode(String),
    RequestPasskey,
    DisplayPasskey { code: u32, entered: u16 },
    RequestConfirmation(u32),
    RequestAuthorization,
    AuthorizeService(String),
    Cancel,
    Release,
}
impl Method {
    fn display(&self) -> bool {
        matches!(self, Self::DisplayPinCode(_) | Self::DisplayPasskey { .. })
    }
    fn name(&self) -> &'static str {
        match self {
            Self::RequestPinCode => "RequestPinCode",
            Self::DisplayPinCode(_) => "DisplayPinCode",
            Self::RequestPasskey => "RequestPasskey",
            Self::DisplayPasskey { .. } => "DisplayPasskey",
            Self::RequestConfirmation(_) => "RequestConfirmation",
            Self::RequestAuthorization => "RequestAuthorization",
            Self::AuthorizeService(_) => "AuthorizeService",
            Self::Cancel => "Cancel",
            Self::Release => "Release",
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Prompt {
    pub id: u64,
    pub request: u64,
    pub device: String,
    pub name: String,
    pub method: &'static str,
    pub code: String,
    pub entered: u16,
    pub service: String,
    pub deferred: bool,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AgentResult {
    Rejected(&'static str),
    Cleared {
        cancel_previous: bool,
        released: bool,
    },
    Prompt {
        value: Prompt,
        cancel_previous: bool,
    },
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Reply {
    Ignored,
    Accepted,
    Pin(String),
    Passkey(u32),
    Cancel {
        request: u64,
        device: String,
        cancel_prompt: bool,
    },
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Step {
    Ignored,
    Trust {
        request: u64,
        device: String,
        cancel_prompt: bool,
    },
    Connect {
        request: u64,
        device: String,
    },
    Finished {
        request: u64,
        success: bool,
        phase: &'static str,
        error: &'static str,
        cancel_prompt: bool,
    },
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reset {
    pub failed_request: Option<u64>,
    pub cancel_prompt: bool,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ticket {
    pub epoch: u64,
    pub operation: u64,
    pub request: u64,
}
#[derive(Clone, Debug, PartialEq, Eq)]
enum Phase {
    Pair,
    Trust,
    Connect,
}
#[derive(Clone, Debug)]
struct Pairing {
    request: u64,
    device: String,
    name: String,
    ticket: Ticket,
    deadline: u64,
    phase: Phase,
}
#[derive(Default, Debug)]
pub struct PairingCore {
    owner: Option<String>,
    epoch: u64,
    registered: bool,
    pending: Option<Pairing>,
    prompt: Option<Prompt>,
    sequence: u64,
    operation: u64,
}

pub fn valid_device(path: &str) -> bool {
    let Some(rest) = path.strip_prefix("/org/bluez/hci") else {
        return false;
    };
    let Some((adapter, address)) = rest.split_once("/dev_") else {
        return false;
    };
    if adapter.is_empty() || !adapter.bytes().all(|c| c.is_ascii_digit()) {
        return false;
    }
    let parts: Vec<_> = address.split('_').collect();
    parts.len() == 6
        && parts
            .iter()
            .all(|part| part.len() == 2 && part.bytes().all(|c| c.is_ascii_hexdigit()))
}
impl PairingCore {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn epoch(&self) -> u64 {
        self.epoch
    }
    pub fn current_prompt(&self) -> Option<&Prompt> {
        self.prompt.as_ref()
    }
    pub fn has_pending(&self) -> bool {
        self.pending.is_some()
    }
    pub fn owner_changed(&mut self, owner: Option<&str>) -> Reset {
        self.epoch = self.epoch.wrapping_add(1);
        self.owner = owner.filter(|s| !s.is_empty()).map(str::to_owned);
        self.registered = false;
        let failed_request = self.pending.take().map(|v| v.request);
        let cancel_prompt = self.prompt.take().is_some_and(|p| p.deferred);
        Reset {
            failed_request,
            cancel_prompt,
        }
    }
    pub fn registered(&mut self, epoch: u64, success: bool) -> bool {
        if epoch != self.epoch || self.owner.is_none() {
            return false;
        }
        self.registered = success;
        true
    }
    pub fn begin(
        &mut self,
        request: u64,
        device: &str,
        name: &str,
        now_ms: u64,
    ) -> Result<Ticket, &'static str> {
        if self.pending.is_some() {
            return Err("Wait for the current Bluetooth operation or cancel it.");
        }
        if !valid_device(device) {
            return Err("Invalid Bluetooth device.");
        }
        if self.owner.is_none() || !self.registered {
            return Err("The pairing agent is unavailable. Reopen Bluetooth and try again.");
        }
        let deadline = now_ms
            .checked_add(65_000)
            .ok_or("Invalid operation deadline.")?;
        self.operation = self
            .operation
            .checked_add(1)
            .ok_or("Operation sequence exhausted.")?;
        let ticket = Ticket {
            epoch: self.epoch,
            operation: self.operation,
            request,
        };
        self.pending = Some(Pairing {
            request,
            device: device.into(),
            name: name.into(),
            ticket,
            deadline,
            phase: Phase::Pair,
        });
        Ok(ticket)
    }
    pub fn agent(&mut self, sender: &str, device: Option<&str>, method: Method) -> AgentResult {
        if self.owner.as_deref() != Some(sender) {
            return AgentResult::Rejected("Unknown caller");
        }
        if matches!(method, Method::Cancel | Method::Release) {
            let released = matches!(method, Method::Release);
            if released {
                self.registered = false;
            }
            return AgentResult::Cleared {
                cancel_previous: self.prompt.take().is_some_and(|p| p.deferred),
                released,
            };
        }
        let Some(p) = self.pending.as_ref() else {
            return AgentResult::Rejected("No user-initiated pairing for this device");
        };
        if p.ticket.epoch != self.epoch
            || p.phase != Phase::Pair
            || device != Some(p.device.as_str())
        {
            return AgentResult::Rejected("No user-initiated pairing for this device");
        }
        if matches!(&method,Method::RequestConfirmation(code)|Method::DisplayPasskey{code,..} if *code>999_999)
        {
            return AgentResult::Rejected("Invalid passkey");
        }
        let Some(sequence) = self.sequence.checked_add(1) else {
            return AgentResult::Rejected("Prompt sequence exhausted");
        };
        let cancel_previous = self.prompt.take().is_some_and(|p| p.deferred);
        self.sequence = sequence;
        let (code, entered, service) = match &method {
            Method::DisplayPinCode(code) => (code.clone(), 0, String::new()),
            Method::DisplayPasskey { code, entered } => {
                (format!("{code:06}"), *entered, String::new())
            }
            Method::RequestConfirmation(code) => (format!("{code:06}"), 0, String::new()),
            Method::AuthorizeService(service) => (String::new(), 0, service.clone()),
            _ => (String::new(), 0, String::new()),
        };
        let value = Prompt {
            id: self.sequence,
            request: p.request,
            device: p.device.clone(),
            name: p.name.clone(),
            method: method.name(),
            code,
            entered,
            service,
            deferred: !method.display(),
        };
        self.prompt = Some(value.clone());
        AgentResult::Prompt {
            value,
            cancel_previous,
        }
    }
    pub fn respond(
        &mut self,
        prompt_id: u64,
        accept: bool,
        value: &str,
    ) -> Result<Reply, &'static str> {
        let Some(prompt) = self.prompt.as_ref() else {
            return Ok(Reply::Ignored);
        };
        let Some(pending) = self.pending.as_ref() else {
            return Ok(Reply::Ignored);
        };
        if prompt.id != prompt_id
            || prompt.request != pending.request
            || pending.ticket.epoch != self.epoch
        {
            return Ok(Reply::Ignored);
        }
        if !accept {
            return Ok(self.cancel(pending.request).unwrap_or(Reply::Ignored));
        }
        if !prompt.deferred {
            return Ok(Reply::Ignored);
        }
        let reply = match prompt.method {
            "RequestPinCode" => {
                if value.is_empty() || value.len() > 16 || value.as_bytes().contains(&0) {
                    return Err("PIN must contain 1–16 bytes.");
                }
                Reply::Pin(value.into())
            }
            "RequestPasskey" => {
                if value.is_empty() || value.len() > 6 || !value.bytes().all(|c| c.is_ascii_digit())
                {
                    return Err("Passkey must contain up to six digits.");
                }
                Reply::Passkey(value.parse().map_err(|_| "Invalid passkey")?)
            }
            _ => Reply::Accepted,
        };
        self.prompt = None;
        Ok(reply)
    }
    pub fn cancel(&mut self, request: u64) -> Option<Reply> {
        if self.pending.as_ref().is_none_or(|p| p.request != request) {
            return None;
        }
        let pending = self.pending.take().unwrap();
        let cancel_prompt = self.prompt.take().is_some_and(|p| p.deferred);
        Some(Reply::Cancel {
            request,
            device: pending.device,
            cancel_prompt,
        })
    }
    pub fn expired(&mut self, now_ms: u64) -> Option<Reply> {
        let p = self.pending.as_ref()?;
        if now_ms <= p.deadline {
            return None;
        }
        self.cancel(p.request)
    }
    pub fn paired(&mut self, ticket: Ticket, confirmed: bool) -> Step {
        let request = ticket.request;
        let Some(p) = self
            .pending
            .as_mut()
            .filter(|p| p.ticket == ticket && ticket.epoch == self.epoch && p.phase == Phase::Pair)
        else {
            return Step::Ignored;
        };
        let cancel_prompt = self.prompt.take().is_some_and(|p| p.deferred);
        if !confirmed {
            self.pending = None;
            return Step::Finished {
                request,
                success: false,
                phase: "connected",
                error: "The device did not confirm pairing.",
                cancel_prompt,
            };
        }
        p.phase = Phase::Trust;
        Step::Trust {
            request,
            device: p.device.clone(),
            cancel_prompt,
        }
    }
    pub fn trusted(&mut self, ticket: Ticket, success: bool) -> Step {
        let request = ticket.request;
        let Some(p) = self.pending.as_mut().filter(|p| {
            p.ticket == ticket && ticket.epoch == self.epoch && p.phase == Phase::Trust
        }) else {
            return Step::Ignored;
        };
        if !success {
            self.pending = None;
            return Step::Finished{request,success:false,phase:"paired",error:"Paired, but automatic reconnection could not be enabled. You can connect manually.",cancel_prompt:false};
        }
        p.phase = Phase::Connect;
        Step::Connect {
            request,
            device: p.device.clone(),
        }
    }
    pub fn connected(&mut self, ticket: Ticket, success: bool) -> Step {
        let request = ticket.request;
        if self.pending.as_ref().is_none_or(|p| {
            p.ticket != ticket || ticket.epoch != self.epoch || p.phase != Phase::Connect
        }) {
            return Step::Ignored;
        }
        self.pending = None;
        Step::Finished {
            request,
            success,
            phase: if success { "connected" } else { "paired" },
            error: if success { "" } else { "Connection failed." },
            cancel_prompt: false,
        }
    }
}
