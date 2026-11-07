//! Serialized worker for potentially mutating NetworkManager operations.
//!
//! Cancellation records intent, not cancellation of an already dispatched
//! D-Bus call. Its late result remains necessary for safe reconciliation.
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ticket {
    epoch: u64,
    serial: u64,
    pub request: u64,
}

pub enum Completion<R> {
    Finished {
        ticket: Ticket,
        result: R,
        canceled: bool,
    },
    Stale {
        ticket: Ticket,
        may_have_run: bool,
    },
    /// The thread exited during a request; a mutation may have been dispatched.
    WorkerStopped {
        ticket: Ticket,
    },
}

struct Job<J> {
    ticket: Ticket,
    owner: String,
    input: J,
}
struct Output<R> {
    ticket: Ticket,
    result: Option<R>,
}

pub struct ActionWorker<J: Send + 'static, R: Send + 'static> {
    jobs: mpsc::SyncSender<Job<J>>,
    results: mpsc::Receiver<Output<R>>,
    generation: Arc<AtomicU64>,
    owner: Option<String>,
    serial: u64,
    pending: Option<Ticket>,
    canceled: bool,
    stopped: bool,
}
impl<J: Send + 'static, R: Send + 'static> ActionWorker<J, R> {
    /// The callback must use its own dedicated connection with bounded I/O,
    /// close that connection, and never log inputs that may contain secrets.
    pub fn new(mut action: impl FnMut(&str, J) -> R + Send + 'static) -> Self {
        let (jobs, rx) = mpsc::sync_channel::<Job<J>>(1);
        let (tx, results) = mpsc::sync_channel(1);
        let generation = Arc::new(AtomicU64::new(0));
        let thread_generation = Arc::clone(&generation);
        thread::spawn(move || {
            while let Ok(job) = rx.recv() {
                let result = if thread_generation.load(Ordering::Acquire) == job.ticket.epoch {
                    Some(action(&job.owner, job.input))
                } else {
                    None
                };
                if tx
                    .send(Output {
                        ticket: job.ticket,
                        result,
                    })
                    .is_err()
                {
                    break;
                }
            }
        });
        Self {
            jobs,
            results,
            generation,
            owner: None,
            serial: 0,
            pending: None,
            canceled: false,
            stopped: false,
        }
    }

    /// Must be called for every owner transition, including reacquisition by
    /// the same unique name. An in-flight action continues to occupy the slot.
    pub fn owner_changed(&mut self, owner: Option<&str>) -> Result<(), &'static str> {
        let next = self
            .generation
            .load(Ordering::Relaxed)
            .checked_add(1)
            .ok_or("Owner epoch exhausted")?;
        self.owner = owner.map(str::to_owned);
        self.generation.store(next, Ordering::Release);
        Ok(())
    }
    pub fn submit(&mut self, request: u64, input: J) -> Result<Ticket, &'static str> {
        if self.stopped {
            return Err("Action worker stopped");
        }
        if self.pending.is_some() {
            return Err("Wi-Fi operation already in progress");
        }
        let owner = self.owner.clone().ok_or("NetworkManager is unavailable")?;
        let serial = self
            .serial
            .checked_add(1)
            .ok_or("Action sequence exhausted")?;
        let ticket = Ticket {
            epoch: self.generation.load(Ordering::Acquire),
            serial,
            request,
        };
        self.jobs
            .try_send(Job {
                ticket,
                owner,
                input,
            })
            .map_err(|_| "Action worker unavailable")?;
        self.serial = serial;
        self.pending = Some(ticket);
        self.canceled = false;
        Ok(ticket)
    }
    /// Records cancellation without discarding the late response: the caller
    /// may need its returned object identity to reconcile the operation.
    pub fn cancel(&mut self, ticket: Ticket) -> bool {
        if self.pending != Some(ticket) {
            return false;
        }
        self.canceled = true;
        true
    }
    pub fn poll(&mut self) -> Option<Completion<R>> {
        match self.results.try_recv() {
            Ok(output) => {
                if self.pending != Some(output.ticket) {
                    return None;
                }
                self.pending = None;
                let stale = output.ticket.epoch != self.generation.load(Ordering::Acquire);
                let canceled = self.canceled;
                self.canceled = false;
                match output.result {
                    Some(result) if !stale => Some(Completion::Finished {
                        ticket: output.ticket,
                        result,
                        canceled,
                    }),
                    Some(_) => Some(Completion::Stale {
                        ticket: output.ticket,
                        may_have_run: true,
                    }),
                    None => Some(Completion::Stale {
                        ticket: output.ticket,
                        may_have_run: false,
                    }),
                }
            }
            Err(mpsc::TryRecvError::Empty) => None,
            Err(mpsc::TryRecvError::Disconnected) => {
                self.stopped = true;
                self.pending
                    .take()
                    .map(|ticket| Completion::WorkerStopped { ticket })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};
    fn wait<R: Send + 'static>(worker: &mut ActionWorker<u8, R>) -> Completion<R> {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(result) = worker.poll() {
                return result;
            }
            assert!(Instant::now() < deadline);
            thread::yield_now();
        }
    }
    #[test]
    fn serializes_and_returns_matching_completion() {
        let (started, entered) = mpsc::channel();
        let (release, resume) = mpsc::channel();
        let mut worker = ActionWorker::new(move |owner, value| {
            started.send(owner.to_owned()).unwrap();
            resume.recv().unwrap();
            value + 1
        });
        worker.owner_changed(Some(":1.1")).unwrap();
        let ticket = worker.submit(3, 10).unwrap();
        assert_eq!(
            entered.recv_timeout(Duration::from_secs(1)).unwrap(),
            ":1.1"
        );
        assert!(worker.submit(4, 11).is_err());
        release.send(()).unwrap();
        assert!(
            matches!(wait(&mut worker), Completion::Finished { ticket: t, result: 11, canceled: false } if t == ticket)
        );
        assert!(worker.submit(4, 11).is_ok());
        release.send(()).unwrap();
    }
    #[test]
    fn owner_change_and_cancel_do_not_falsely_claim_mutation_stopped() {
        let (started, entered) = mpsc::channel();
        let (release, resume) = mpsc::channel();
        let mut worker = ActionWorker::new(move |_, value| {
            started.send(()).unwrap();
            resume.recv().unwrap();
            value
        });
        worker.owner_changed(Some(":1.1")).unwrap();
        let ticket = worker.submit(1, 9).unwrap();
        entered.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(worker.cancel(ticket));
        worker.owner_changed(Some(":1.1")).unwrap();
        assert!(worker.submit(2, 10).is_err());
        release.send(()).unwrap();
        assert!(
            matches!(wait(&mut worker), Completion::Stale { ticket: t, may_have_run: true } if t == ticket)
        );
    }
    #[test]
    fn canceled_inflight_result_is_delivered_for_reconciliation() {
        let (started, entered) = mpsc::channel();
        let (release, resume) = mpsc::channel();
        let mut worker = ActionWorker::new(move |_, value| {
            started.send(()).unwrap();
            resume.recv().unwrap();
            value
        });
        worker.owner_changed(Some(":1.1")).unwrap();
        let ticket = worker.submit(4, 9).unwrap();
        entered.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(worker.cancel(ticket));
        assert!(worker.submit(5, 10).is_err());
        release.send(()).unwrap();
        assert!(
            matches!(wait(&mut worker), Completion::Finished { ticket: t, result: 9, canceled: true } if t == ticket)
        );
    }
    #[test]
    fn panic_during_action_is_unknown_and_worker_is_not_reused() {
        let mut worker = ActionWorker::new(|_, _: u8| -> u8 { panic!("synthetic failure") });
        worker.owner_changed(Some(":1.1")).unwrap();
        let ticket = worker.submit(1, 2).unwrap();
        assert!(
            matches!(wait(&mut worker), Completion::WorkerStopped { ticket: t } if t == ticket)
        );
        assert!(worker.submit(2, 3).is_err());
    }
}
