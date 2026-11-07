//! Coordinate a single activation and its serialized, potentially mutating call.
//!
//! This does not operate a bus, register an agent, or provide the shell service.
//! The caller must execute subsequent inspection actions on bounded workers and
//! close the dedicated connection on `CloseUncertain`.
use crate::action_worker::{ActionWorker, Completion, Ticket as WorkerTicket};
use crate::activate::{Error, Started};
use macshell_network_core::activation::{
    Action, Activation, ActiveState, Observation, StartError, Ticket,
};

pub struct Coordinator<J: Send + 'static> {
    worker: ActionWorker<J, Result<Started, Error>>,
    activation: Activation,
    pending: Option<(Ticket, WorkerTicket)>,
}

impl<J: Send + 'static> Coordinator<J> {
    pub fn new(action: impl FnMut(&str, J) -> Result<Started, Error> + Send + 'static) -> Self {
        Self {
            worker: ActionWorker::new(action),
            activation: Activation::new(),
            pending: None,
        }
    }

    pub fn owner_changed(&mut self, owner: Option<&str>) -> Result<Action, &'static str> {
        let result = self.activation.owner_changed(owner)?;
        self.worker.owner_changed(owner)?;
        Ok(result)
    }

    pub fn begin(
        &mut self,
        request: u64,
        device: &str,
        ap: &str,
        job: J,
    ) -> Result<Ticket, &'static str> {
        let ticket = self.activation.begin(request, device, ap)?;
        match self.worker.submit(request, job) {
            Ok(worker_ticket) => {
                self.pending = Some((ticket, worker_ticket));
                Ok(ticket)
            }
            Err(error) => {
                // No worker job was dispatched, so this failure is definite.
                self.activation.started(ticket, Err(StartError::Rejected));
                Err(error)
            }
        }
    }

    pub fn cancel(&mut self, ticket: Ticket) -> Action {
        let result = self.activation.cancel(ticket);
        if let Some((current, worker)) = self.pending {
            if current == ticket {
                self.worker.cancel(worker);
            }
        }
        result
    }

    pub fn poll_start(&mut self) -> Option<(Ticket, Action)> {
        let completion = self.worker.poll()?;
        let worker_ticket = match &completion {
            Completion::Finished { ticket, .. }
            | Completion::Stale { ticket, .. }
            | Completion::WorkerStopped { ticket } => *ticket,
        };
        let (ticket, expected) = self.pending?;
        if worker_ticket != expected {
            return None;
        }
        self.pending = None;
        let action = match completion {
            Completion::Finished {
                result: Ok(started),
                ..
            } => self.activation.started(
                ticket,
                Ok((&started.active_path, started.exclusively_owned)),
            ),
            // An uncertain result must never be retried or treated as canceled.
            Completion::Finished {
                result: Err(Error::Uncertain),
                ..
            }
            | Completion::Stale { .. }
            | Completion::WorkerStopped { .. } => {
                self.activation.started(ticket, Err(StartError::Uncertain))
            }
            Completion::Finished { result: Err(_), .. } => {
                self.activation.started(ticket, Err(StartError::Rejected))
            }
        };
        Some((ticket, action))
    }

    pub fn observed(
        &mut self,
        ticket: Ticket,
        path: &str,
        purpose: Observation,
        state: Result<ActiveState, ()>,
    ) -> Action {
        self.activation.observed(ticket, path, purpose, state)
    }

    pub fn deactivated(&mut self, ticket: Ticket, path: &str, success: bool) -> Action {
        self.activation.deactivated(ticket, path, success)
    }

    pub fn cancel_found_connected(&mut self, ticket: Ticket, path: &str) -> Action {
        self.activation.cancel_found_connected(ticket, path)
    }

    pub fn timeout(&mut self, ticket: Ticket) -> Action {
        self.activation.timeout(ticket)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::{Duration, Instant};
    const DEV: &str = "/org/freedesktop/NetworkManager/Devices/1";
    const AP: &str = "/org/freedesktop/NetworkManager/AccessPoint/1";
    const ACTIVE: &str = "/org/freedesktop/NetworkManager/ActiveConnection/1";
    fn poll(c: &mut Coordinator<()>) -> (Ticket, Action) {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(value) = c.poll_start() {
                return value;
            }
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
    }
    #[test]
    fn cancellation_waits_for_late_response_and_inspects_its_path() {
        let (sent, received) = mpsc::channel();
        let (release, wait) = mpsc::channel();
        let mut c = Coordinator::new(move |_, ()| {
            sent.send(()).unwrap();
            wait.recv().unwrap();
            Ok(Started {
                active_path: ACTIVE.into(),
                exclusively_owned: false,
            })
        });
        c.owner_changed(Some(":1.2")).unwrap();
        let t = c.begin(1, DEV, AP, ()).unwrap();
        received.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(c.cancel(t), Action::Wait);
        release.send(()).unwrap();
        assert_eq!(poll(&mut c), (t, Action::InspectForCancel(ACTIVE.into())));
        assert_eq!(
            c.observed(
                t,
                ACTIVE,
                Observation::CancelInspection,
                Ok(ActiveState::Activating)
            ),
            Action::Deactivate(ACTIVE.into())
        );
        assert_eq!(
            c.deactivated(t, ACTIVE, true),
            Action::ConfirmCanceled(ACTIVE.into())
        );
        assert_eq!(
            c.observed(
                t,
                ACTIVE,
                Observation::CancelConfirmation,
                Ok(ActiveState::Deactivated)
            ),
            Action::Canceled
        );
    }
    #[test]
    fn uncertain_start_is_never_reported_as_canceled() {
        let mut c = Coordinator::new(|_, ()| Err(Error::Uncertain));
        c.owner_changed(Some(":1.2")).unwrap();
        let t = c.begin(1, DEV, AP, ()).unwrap();
        c.cancel(t);
        assert_eq!(poll(&mut c), (t, Action::CloseUncertain));
        assert!(c.begin(2, DEV, AP, ()).is_err());
    }
}
