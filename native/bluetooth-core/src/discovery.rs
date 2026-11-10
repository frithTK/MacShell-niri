//! Track only discovery references acquired by this connection.
use std::collections::{BTreeMap, BTreeSet};
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Effect {
    Start {
        path: String,
        epoch: u64,
        token: u64,
    },
    Stop {
        path: String,
        epoch: u64,
        token: u64,
    },
    CloseConnection,
    Error {
        path: String,
    },
}
#[derive(Clone, Debug, PartialEq, Eq)]
enum Phase {
    Starting(u64),
    Owned,
    Stopping(u64),
}
#[derive(Default, Debug)]
pub struct DiscoveryCore {
    epoch: u64,
    serial: u64,
    desired: bool,
    hold: bool,
    deadline: Option<u64>,
    poisoned: bool,
    wanted: BTreeSet<String>,
    adapters: BTreeMap<String, Phase>,
}
pub fn valid_adapter(path: &str) -> bool {
    path.strip_prefix("/org/bluez/hci")
        .is_some_and(|suffix| !suffix.is_empty() && suffix.bytes().all(|v| v.is_ascii_digit()))
}
impl DiscoveryCore {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn epoch(&self) -> u64 {
        self.epoch
    }
    pub fn owned(&self) -> usize {
        self.adapters
            .values()
            .filter(|v| matches!(v, Phase::Owned | Phase::Stopping(_)))
            .count()
    }
    fn next(&mut self) -> u64 {
        self.serial = self.serial.wrapping_add(1);
        self.serial
    }
    pub fn owner_changed(&mut self) -> Vec<Effect> {
        let close = self.poisoned || !self.adapters.is_empty();
        self.epoch = self.epoch.wrapping_add(1);
        self.desired = false;
        self.hold = false;
        self.deadline = None;
        self.poisoned = close;
        self.wanted.clear();
        self.adapters.clear();
        if close {
            vec![Effect::CloseConnection]
        } else {
            vec![]
        }
    }
    /// Call only after the previous D-Bus connection has actually closed.
    pub fn connection_replaced(&mut self) {
        self.epoch = self.epoch.wrapping_add(1);
        self.desired = false;
        self.hold = false;
        self.deadline = None;
        self.poisoned = false;
        self.wanted.clear();
        self.adapters.clear();
    }
    pub fn start(
        &mut self,
        now_ms: u64,
        adapters: &[(String, bool)],
    ) -> Result<Vec<Effect>, &'static str> {
        self.begin(
            Some(
                now_ms
                    .checked_add(30_000)
                    .ok_or("Invalid discovery deadline.")?,
            ),
            adapters,
        )
    }
    /// Keep StartDiscovery running without the pairing timeout so AirPods ads
    /// can refresh. User scans still apply their own 30 s deadline.
    pub fn hold(&mut self, adapters: &[(String, bool)]) -> Result<Vec<Effect>, &'static str> {
        self.hold = true;
        self.begin(self.deadline, adapters)
    }
    pub fn release_hold(&mut self) -> Vec<Effect> {
        self.hold = false;
        if self.deadline.is_some() {
            vec![]
        } else {
            self.stop()
        }
    }
    fn begin(
        &mut self,
        deadline: Option<u64>,
        adapters: &[(String, bool)],
    ) -> Result<Vec<Effect>, &'static str> {
        if self.poisoned {
            return Err("Discovery connection must be replaced.");
        }
        self.deadline = deadline;
        self.desired = true;
        self.wanted = adapters
            .iter()
            .filter(|(path, enabled)| *enabled && valid_adapter(path))
            .map(|(path, _)| path.clone())
            .collect();
        let mut effects = Vec::new();
        let obsolete: Vec<_> = self
            .adapters
            .iter()
            .filter(|(path, phase)| **phase == Phase::Owned && !self.wanted.contains(*path))
            .map(|(path, _)| path.clone())
            .collect();
        for path in obsolete {
            let token = self.next();
            self.adapters.insert(path.clone(), Phase::Stopping(token));
            effects.push(Effect::Stop {
                path,
                epoch: self.epoch,
                token,
            });
        }
        for (path, enabled) in adapters {
            if *enabled && valid_adapter(path) && !self.adapters.contains_key(path) {
                let token = self.next();
                self.adapters.insert(path.clone(), Phase::Starting(token));
                effects.push(Effect::Start {
                    path: path.clone(),
                    epoch: self.epoch,
                    token,
                });
            }
        }
        Ok(effects)
    }
    pub fn stop(&mut self) -> Vec<Effect> {
        self.desired = false;
        self.hold = false;
        self.deadline = None;
        self.wanted.clear();
        let paths: Vec<_> = self
            .adapters
            .iter()
            .filter(|(_, phase)| **phase == Phase::Owned)
            .map(|(path, _)| path.clone())
            .collect();
        let mut effects = Vec::new();
        for path in paths {
            let token = self.next();
            self.adapters.insert(path.clone(), Phase::Stopping(token));
            effects.push(Effect::Stop {
                path,
                epoch: self.epoch,
                token,
            });
        }
        effects
    }
    pub fn tick(&mut self, now_ms: u64) -> Vec<Effect> {
        if self.deadline.is_some_and(|deadline| now_ms > deadline) {
            self.deadline = None;
            if self.hold {
                vec![]
            } else {
                self.stop()
            }
        } else {
            vec![]
        }
    }
    pub fn started(&mut self, path: &str, epoch: u64, token: u64, success: bool) -> Vec<Effect> {
        if self.poisoned
            || epoch != self.epoch
            || self.adapters.get(path) != Some(&Phase::Starting(token))
        {
            return vec![];
        }
        if !success {
            self.adapters.remove(path);
            return vec![Effect::Error { path: path.into() }];
        }
        if self.desired && self.wanted.contains(path) {
            self.adapters.insert(path.into(), Phase::Owned);
            vec![]
        } else {
            let token = self.next();
            self.adapters.insert(path.into(), Phase::Stopping(token));
            vec![Effect::Stop {
                path: path.into(),
                epoch: self.epoch,
                token,
            }]
        }
    }
    /// A timed-out or disconnected StartDiscovery may still have succeeded.
    /// Close the connection to release any reference before starting again.
    pub fn start_uncertain(&mut self, path: &str, epoch: u64, token: u64) -> Vec<Effect> {
        if self.poisoned
            || epoch != self.epoch
            || self.adapters.get(path) != Some(&Phase::Starting(token))
        {
            return vec![];
        }
        self.poisoned = true;
        self.desired = false;
        self.hold = false;
        self.deadline = None;
        vec![Effect::CloseConnection]
    }
    pub fn stopped(&mut self, path: &str, epoch: u64, token: u64, success: bool) -> Vec<Effect> {
        if self.poisoned
            || epoch != self.epoch
            || self.adapters.get(path) != Some(&Phase::Stopping(token))
        {
            return vec![];
        }
        if !success {
            self.poisoned = true;
            self.desired = false;
            self.hold = false;
            self.deadline = None;
            return vec![Effect::CloseConnection];
        }
        self.adapters.remove(path);
        if self.desired && self.wanted.contains(path) {
            let token = self.next();
            self.adapters.insert(path.into(), Phase::Starting(token));
            vec![Effect::Start {
                path: path.into(),
                epoch: self.epoch,
                token,
            }]
        } else {
            vec![]
        }
    }
}
