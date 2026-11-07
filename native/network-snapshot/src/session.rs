//! Coordinates owner, secret agent, snapshot and activation on one GLib context.
//!
//! Workers use their own bounded connections; the host connection must outlive this session and be
//! closed after `CloseConnection` or when the session is dropped.
use crate::action_worker::{ActionWorker, Completion, Ticket as WorkerTicket};
use crate::activate::{Error as StartError, Started};
use crate::coordinator::Coordinator;
use crate::radio::Error as RadioError;
use crate::worker::Worker;
use crate::Error as SnapshotError;
use macshell_gio_bridge::Ptr;
use macshell_network_agent::{
    host::{AgentHost, HostEvent},
    Event as AgentEvent,
};
use macshell_network_core::activation::{Action, ActiveState, Observation, Ticket};
use macshell_network_core::secret_agent::Ticket as SecretTicket;
use serde_json::Value;
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

#[derive(Debug)]
pub enum Event {
    Owner(Option<String>),
    Registration(bool),
    Snapshot(Result<Value, SnapshotError>),
    Agent(AgentEvent),
    Activation {
        ticket: Ticket,
        action: Action,
    },
    Radio {
        request: u64,
        result: Result<usize, RadioError>,
    },
    CloseConnection,
}

#[derive(Clone, Debug)]
pub enum RadioAction {
    Scan,
    Power(bool),
    Disconnect { device: String, ap: String },
    CancelActivation { path: String },
}

pub struct SecretIdentity<'a> {
    pub uuid: &'a str,
    pub profile: Option<&'a str>,
    pub has_initial: bool,
}

pub struct Selection<'a> {
    pub device: &'a str,
    pub ap: &'a str,
    /// None for an open network; secure networks must carry an identity.
    pub secret: Option<SecretIdentity<'a>>,
}

struct Inspection {
    ticket: Ticket,
    path: String,
    purpose: Observation,
    after: Instant,
}

pub struct Session<J: Send + 'static> {
    host: AgentHost,
    host_events: Receiver<HostEvent>,
    agent_events: Receiver<AgentEvent>,
    snapshot: Worker,
    snapshot_busy: bool,
    snapshot_dirty: bool,
    activation: Coordinator<J>,
    inspector: ActionWorker<String, Result<ActiveState, StartError>>,
    radio: ActionWorker<RadioAction, Result<usize, RadioError>>,
    radio_pending: bool,
    canceling: Option<(Ticket, String)>,
    inspecting: Option<(WorkerTicket, Inspection)>,
    next_inspection: Option<Inspection>,
    deadline: Option<(Ticket, Instant)>,
    secret: Option<(Ticket, SecretTicket)>,
    owner: bool,
    registered: bool,
    closing: bool,
}

impl<J: Send + 'static> Session<J> {
    /// # Safety
    /// `bus` is a dedicated live connection, owned by the caller, and its GLib
    /// context must outlive this object. Use only on that context's thread.
    /// All callbacks must use their own bounded connections and close them.
    pub unsafe fn new(
        bus: Ptr,
        reader: impl FnMut(&str) -> Result<Value, SnapshotError> + Send + 'static,
        starter: impl FnMut(&str, J) -> Result<Started, StartError> + Send + 'static,
        inspector: impl FnMut(&str, String) -> Result<ActiveState, StartError> + Send + 'static,
        radio: impl FnMut(&str, RadioAction) -> Result<usize, RadioError> + Send + 'static,
    ) -> Result<Self, String> {
        let (agent_tx, agent_events) = mpsc::channel();
        let (host_tx, host_events) = mpsc::channel();
        Ok(Self {
            host: AgentHost::new(bus, agent_tx, host_tx)?,
            host_events,
            agent_events,
            snapshot: Worker::new(reader),
            snapshot_busy: false,
            snapshot_dirty: false,
            activation: Coordinator::new(starter),
            inspector: ActionWorker::new(inspector),
            radio: ActionWorker::new(radio),
            radio_pending: false,
            canceling: None,
            inspecting: None,
            next_inspection: None,
            deadline: None,
            secret: None,
            owner: false,
            registered: false,
            closing: false,
        })
    }

    pub fn refresh(&mut self) -> Result<bool, &'static str> {
        if self.closing {
            return Err("NetworkManager is unavailable");
        }
        if self.snapshot_busy {
            self.snapshot_dirty = true;
            return Ok(true);
        }
        let accepted = self.snapshot.request()?;
        self.snapshot_busy = accepted;
        self.snapshot_dirty = !accepted;
        Ok(accepted)
    }

    pub fn begin(
        &mut self,
        request: u64,
        selected: Selection<'_>,
        job: J,
    ) -> Result<Ticket, &'static str> {
        if self.closing || !self.owner || (selected.secret.is_some() && !self.registered) {
            return Err("NetworkManager or its password agent is unavailable");
        }
        if self.radio_pending {
            return Err("Wi-Fi operation already in progress");
        }
        let secret = if let Some(identity) = selected.secret {
            Some(self.host.with_agent(|a| {
                a.begin(
                    request,
                    identity.uuid,
                    identity.profile,
                    identity.has_initial,
                )
            })?)
        } else {
            None
        };
        match self
            .activation
            .begin(request, selected.device, selected.ap, job)
        {
            Ok(ticket) => {
                self.deadline = Some((ticket, Instant::now() + Duration::from_secs(45)));
                if let Some(secret) = secret {
                    self.secret = Some((ticket, secret));
                }
                Ok(ticket)
            }
            Err(error) => {
                if let Some(secret) = secret {
                    self.host.with_agent(|a| a.finish(secret, false));
                }
                Err(error)
            }
        }
    }

    pub fn radio(&mut self, request: u64, action: RadioAction) -> Result<(), &'static str> {
        if self.closing || !self.owner {
            return Err("NetworkManager is unavailable");
        }
        if self.radio_pending || self.deadline.is_some() {
            return Err("Wi-Fi operation already in progress");
        }
        self.radio.submit(request, action)?;
        self.radio_pending = true;
        Ok(())
    }

    pub fn reply(
        &self,
        ticket: Ticket,
        delivery: u64,
        password: &str,
    ) -> Result<bool, &'static str> {
        match self.secret.filter(|(current, _)| *current == ticket) {
            Some((_, secret)) if !self.closing => self
                .host
                .with_agent(|a| a.reply(secret, delivery, password)),
            _ => Ok(false),
        }
    }

    pub fn cancel(&mut self, ticket: Ticket) -> Action {
        let action = self.activation.cancel(ticket);
        if action != Action::Ignore {
            self.finish_secret(ticket, true);
            if let Some((current, deadline)) = &mut self.deadline {
                if *current == ticket {
                    *deadline = (*deadline).min(Instant::now() + Duration::from_secs(4));
                }
            }
        }
        self.finalize(ticket, action)
    }

    pub fn deactivated(&mut self, ticket: Ticket, path: &str, success: bool) -> Action {
        let action = self.activation.deactivated(ticket, path, success);
        self.finalize(ticket, action)
    }

    pub fn timeout(&mut self, ticket: Ticket) -> Action {
        let action = self.activation.timeout(ticket);
        self.finalize(ticket, action)
    }

    fn finish_secret(&mut self, ticket: Ticket, canceled: bool) {
        if self.secret.is_some_and(|(current, _)| current == ticket) {
            if let Some((_, secret)) = self.secret.take() {
                self.host.with_agent(|a| a.finish(secret, canceled));
            }
        }
    }

    fn finalize(&mut self, ticket: Ticket, action: Action) -> Action {
        if let Action::Deactivate(path) = &action {
            if self.radio_pending
                || self
                    .radio
                    .submit(
                        ticket.request,
                        RadioAction::CancelActivation { path: path.clone() },
                    )
                    .is_err()
            {
                let timeout = self.activation.timeout(ticket);
                return self.finalize(ticket, timeout);
            }
            self.radio_pending = true;
            self.canceling = Some((ticket, path.clone()));
        }
        let inspection = match &action {
            Action::Observe(path) => Some((path, Observation::Watch)),
            Action::InspectForCancel(path) => Some((path, Observation::CancelInspection)),
            Action::ConfirmCanceled(path) => Some((path, Observation::CancelConfirmation)),
            _ => None,
        };
        if let Some((path, purpose)) = inspection {
            self.next_inspection = Some(Inspection {
                ticket,
                path: path.clone(),
                purpose,
                after: Instant::now(),
            });
        }
        if matches!(
            action,
            Action::Connected | Action::Canceled | Action::Failed | Action::CloseUncertain
        ) {
            self.finish_secret(ticket, false);
            self.next_inspection = None;
            if self.deadline.is_some_and(|(current, _)| current == ticket) {
                self.deadline = None;
            }
        }
        if action == Action::CloseUncertain {
            self.closing = true;
            self.snapshot.cancel();
        }
        action
    }

    /// Drain on the owning context, outside Gio callbacks. The caller handles
    /// `CloseUncertain` and `CloseConnection` by closing the host connection.
    pub fn poll(&mut self) -> Vec<Event> {
        let mut events = Vec::new();
        while let Ok(event) = self.host_events.try_recv() {
            match event {
                HostEvent::Owner { unique, .. } => {
                    self.owner = unique.is_some();
                    self.registered = false;
                    let snapshot = self.snapshot.owner_changed(unique.as_deref());
                    self.snapshot_busy = false;
                    self.snapshot_dirty = false;
                    let activation = self.activation.owner_changed(unique.as_deref());
                    let inspector = self.inspector.owner_changed(unique.as_deref());
                    let radio = self.radio.owner_changed(unique.as_deref());
                    self.next_inspection = None;
                    if snapshot.is_err()
                        || inspector.is_err()
                        || radio.is_err()
                        || self.radio_pending
                        || !matches!(activation, Ok(Action::Ignore))
                    {
                        self.closing = true;
                    }
                    events.push(Event::Owner(unique));
                    if self.closing {
                        events.push(Event::CloseConnection);
                    }
                }
                HostEvent::Registration { success, .. } => {
                    self.registered = success && !self.closing;
                    events.push(Event::Registration(self.registered));
                }
                HostEvent::CloseConnection => {
                    self.closing = true;
                    self.snapshot.cancel();
                    events.push(Event::CloseConnection);
                }
            }
        }
        while let Ok(event) = self.agent_events.try_recv() {
            events.push(Event::Agent(event));
        }
        if !self.closing {
            if let Some(completion) = self.radio.poll() {
                self.radio_pending = false;
                let (ticket, result) = match completion {
                    Completion::Finished { ticket, result, .. } => (ticket, result),
                    Completion::Stale { ticket, .. } | Completion::WorkerStopped { ticket } => {
                        (ticket, Err(RadioError::Uncertain))
                    }
                };
                if let Some((ticket, path)) = self.canceling.take() {
                    let action = if result == Ok(1) {
                        self.activation.cancel_found_connected(ticket, &path)
                    } else {
                        self.activation.deactivated(ticket, &path, result == Ok(0))
                    };
                    let action = self.finalize(ticket, action);
                    events.push(Event::Activation { ticket, action });
                } else {
                    if result == Err(RadioError::Uncertain) {
                        self.closing = true;
                        self.snapshot.cancel();
                    }
                    events.push(Event::Radio {
                        request: ticket.request,
                        result,
                    });
                    if self.closing {
                        events.push(Event::CloseConnection);
                    }
                }
            }
        }
        if !self.closing {
            if let Some((ticket, deadline)) = self.deadline {
                if Instant::now() >= deadline {
                    let action = self.activation.timeout(ticket);
                    let action = self.finalize(ticket, action);
                    events.push(Event::Activation { ticket, action });
                }
            }
        }
        if !self.closing {
            if let Some(state) = self.snapshot.poll() {
                self.snapshot_busy = false;
                events.push(Event::Snapshot(state));
            }
            if self.owner && self.snapshot_dirty && !self.snapshot_busy {
                match self.snapshot.request() {
                    Ok(true) => {
                        self.snapshot_busy = true;
                        self.snapshot_dirty = false;
                    }
                    Ok(false) => (),
                    Err(_) => {
                        self.snapshot_dirty = false;
                        events.push(Event::Snapshot(Err(SnapshotError::Unavailable)));
                    }
                }
            }
            if let Some((ticket, action)) = self.activation.poll_start() {
                let action = self.finalize(ticket, action);
                events.push(Event::Activation { ticket, action });
            }
            if let Some(completion) = self.inspector.poll() {
                if let Some((expected, request)) = self.inspecting.take() {
                    let (worker, state) = match completion {
                        Completion::Finished { ticket, result, .. } => {
                            (ticket, result.map_err(|_| ()))
                        }
                        Completion::Stale { ticket, .. } | Completion::WorkerStopped { ticket } => {
                            (ticket, Err(()))
                        }
                    };
                    if worker == expected {
                        let action = self.activation.observed(
                            request.ticket,
                            &request.path,
                            request.purpose,
                            state,
                        );
                        if action == Action::Wait && self.next_inspection.is_none() {
                            self.next_inspection = Some(Inspection {
                                after: Instant::now() + Duration::from_secs(1),
                                ..request
                            });
                        } else {
                            let ticket = request.ticket;
                            let action = self.finalize(ticket, action);
                            if action != Action::Ignore {
                                events.push(Event::Activation { ticket, action });
                            }
                        }
                    }
                }
            }
            if !self.closing
                && self.inspecting.is_none()
                && self
                    .next_inspection
                    .as_ref()
                    .is_some_and(|v| v.after <= Instant::now())
            {
                let request = self.next_inspection.take().expect("inspection present");
                match self
                    .inspector
                    .submit(request.ticket.request, request.path.clone())
                {
                    Ok(worker) => self.inspecting = Some((worker, request)),
                    Err(_) => {
                        let ticket = request.ticket;
                        let action = self.activation.timeout(ticket);
                        let action = self.finalize(ticket, action);
                        events.push(Event::Activation { ticket, action });
                    }
                }
            }
        }
        events
    }
}
