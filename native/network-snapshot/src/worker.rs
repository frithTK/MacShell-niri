//! Bounded background snapshot scheduling with owner-generation fencing.
//!
//! The worker owns its reader and runs it on a separate thread. A caller must
//! invoke `owner_changed` on every watcher transition, including reacquisition
//! by the same unique name, and retry a request rejected as busy. Dropping the
//! worker does not wait for an in-flight reader; its output is discarded.
use crate::Error;
use serde_json::Value;
use std::sync::mpsc::{self, Receiver, SyncSender, TryRecvError, TrySendError};
use std::thread;

struct Job {
    epoch: u64,
    sequence: u64,
    owner: String,
}
struct ResultMessage {
    epoch: u64,
    sequence: u64,
    result: Result<Value, Error>,
}

pub struct Worker {
    jobs: SyncSender<Job>,
    results: Receiver<ResultMessage>,
    owner: Option<String>,
    epoch: u64,
    sequence: u64,
    pending: Option<u64>,
}

impl Worker {
    /// `reader` must use an independent connection and bounded I/O. It must
    /// never log or return secret settings. It runs only on the worker thread.
    pub fn new(mut reader: impl FnMut(&str) -> Result<Value, Error> + Send + 'static) -> Self {
        let (jobs, receiver) = mpsc::sync_channel::<Job>(1);
        let (sender, results) = mpsc::sync_channel(1);
        thread::spawn(move || {
            while let Ok(job) = receiver.recv() {
                let result = reader(&job.owner);
                if sender
                    .send(ResultMessage {
                        epoch: job.epoch,
                        sequence: job.sequence,
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
            owner: None,
            epoch: 0,
            sequence: 0,
            pending: None,
        }
    }

    pub fn owner_changed(&mut self, owner: Option<&str>) -> Result<(), &'static str> {
        self.epoch = self.epoch.checked_add(1).ok_or("Owner epoch exhausted")?;
        self.owner = owner.map(str::to_owned);
        self.pending = None;
        Ok(())
    }

    /// Schedule a read. `Ok(false)` means the one-item queue is full; the
    /// caller must retry after draining completion events.
    pub fn request(&mut self) -> Result<bool, &'static str> {
        let owner = self.owner.clone().ok_or("NetworkManager is unavailable")?;
        let sequence = self
            .sequence
            .checked_add(1)
            .ok_or("Snapshot sequence exhausted")?;
        match self.jobs.try_send(Job {
            epoch: self.epoch,
            sequence,
            owner,
        }) {
            Ok(()) => {
                self.sequence = sequence;
                self.pending = Some(sequence);
                Ok(true)
            }
            Err(TrySendError::Full(_)) => Ok(false),
            Err(TrySendError::Disconnected(_)) => Err("Snapshot worker stopped"),
        }
    }

    /// A result is visible only while it is the latest accepted request for
    /// the current owner generation. Earlier replies are consumed silently.
    pub fn poll(&mut self) -> Option<Result<Value, Error>> {
        loop {
            match self.results.try_recv() {
                Ok(message)
                    if message.epoch == self.epoch && self.pending == Some(message.sequence) =>
                {
                    self.pending = None;
                    return Some(message.result);
                }
                Ok(_) => (),
                Err(TryRecvError::Empty) => return None,
                Err(TryRecvError::Disconnected) => {
                    return self.pending.take().map(|_| Err(Error::Unavailable))
                }
            }
        }
    }

    pub fn cancel(&mut self) {
        self.pending = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    fn wait(worker: &mut Worker) -> Result<Value, Error> {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(value) = worker.poll() {
                return value;
            }
            assert!(Instant::now() < deadline, "worker did not complete");
            thread::yield_now();
        }
    }

    #[test]
    fn old_owner_and_old_request_never_publish() {
        let (started_tx, started_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let mut worker = Worker::new(move |owner| {
            started_tx.send(owner.to_owned()).unwrap();
            release_rx.recv().unwrap();
            Ok(json!({"owner":owner}))
        });
        worker.owner_changed(Some(":1.3")).unwrap();
        assert!(worker.request().unwrap());
        assert_eq!(
            started_rx.recv_timeout(Duration::from_secs(1)).unwrap(),
            ":1.3"
        );
        worker.owner_changed(Some(":1.3")).unwrap();
        assert!(worker.request().unwrap());
        release_tx.send(()).unwrap();
        assert_eq!(
            started_rx.recv_timeout(Duration::from_secs(1)).unwrap(),
            ":1.3"
        );
        assert!(worker.poll().is_none());
        release_tx.send(()).unwrap();
        assert_eq!(wait(&mut worker).unwrap()["owner"], ":1.3");
    }

    #[test]
    fn newer_request_supersedes_old_and_queue_is_bounded() {
        let (started_tx, started_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let mut worker = Worker::new(move |_| {
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Ok(json!("snapshot"))
        });
        worker.owner_changed(Some(":1.1")).unwrap();
        assert!(worker.request().unwrap());
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(worker.request().unwrap());
        assert!(!worker.request().unwrap());
        release_tx.send(()).unwrap();
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(worker.poll().is_none());
        release_tx.send(()).unwrap();
        assert_eq!(wait(&mut worker).unwrap(), json!("snapshot"));
    }

    #[test]
    fn cancel_and_owner_loss_drop_results() {
        let (started_tx, started_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let mut worker = Worker::new(move |_| {
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Err(Error::Unavailable)
        });
        worker.owner_changed(Some(":1.1")).unwrap();
        assert!(worker.request().unwrap());
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        worker.cancel();
        worker.owner_changed(None).unwrap();
        assert!(worker.request().is_err());
        release_tx.send(()).unwrap();
        drop(worker);
    }

    #[test]
    fn crashed_worker_reports_pending_request_unavailable() {
        let mut worker = Worker::new(|_| -> Result<Value, Error> { panic!("synthetic failure") });
        worker.owner_changed(Some(":1.1")).unwrap();
        assert!(worker.request().unwrap());
        assert_eq!(wait(&mut worker), Err(Error::Unavailable));
        assert!(worker.request().is_err());
    }
}
