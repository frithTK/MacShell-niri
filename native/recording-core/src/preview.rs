//! Demand scheduling for window previews; no screen capture occurs here.
use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ticket {
    pub id: u64,
    serial: u64,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Effect {
    Start(Ticket),
    Resume(Ticket),
    Pause(Ticket),
    Close(Ticket),
}
struct Stream {
    ticket: Ticket,
    last: u64,
    pipeline: bool,
    paused: bool,
}

pub struct Previews {
    limit: usize,
    streams: BTreeMap<u64, Stream>,
    failed: BTreeMap<u64, u64>,
    serial: u64,
}
impl Previews {
    pub fn new(limit: usize) -> Self {
        Self {
            limit: limit.clamp(1, 12),
            streams: BTreeMap::new(),
            failed: BTreeMap::new(),
            serial: 0,
        }
    }
    /// Timestamp is monotonic milliseconds. A full set of recently demanded
    /// streams never evicts one currently being viewed.
    pub fn request(&mut self, id: u64, now: u64) -> Vec<Effect> {
        if id == 0 || self.failed.get(&id).is_some_and(|deadline| *deadline > now) {
            return vec![];
        }
        if let Some(stream) = self.streams.get_mut(&id) {
            stream.last = now;
            if stream.pipeline && stream.paused {
                stream.paused = false;
                return vec![Effect::Resume(stream.ticket)];
            }
            return vec![];
        }
        let mut effects = Vec::new();
        if self.streams.len() >= self.limit {
            let Some((&oldest, old)) = self.streams.iter().min_by_key(|(_, stream)| stream.last)
            else {
                return effects;
            };
            if now.saturating_sub(old.last) < 800 {
                return effects;
            }
            if let Some(stream) = self.streams.remove(&oldest) {
                effects.push(Effect::Close(stream.ticket));
            }
        }
        let Some(serial) = self.serial.checked_add(1) else {
            return effects;
        };
        self.serial = serial;
        let ticket = Ticket { id, serial };
        self.streams.insert(
            id,
            Stream {
                ticket,
                last: now,
                pipeline: false,
                paused: false,
            },
        );
        effects.push(Effect::Start(ticket));
        effects
    }
    pub fn pipeline_ready(&mut self, ticket: Ticket) {
        if let Some(stream) = self
            .streams
            .get_mut(&ticket.id)
            .filter(|s| s.ticket == ticket)
        {
            stream.pipeline = true;
        }
    }
    /// A failed stream is closed and suppressed for ten seconds.
    pub fn failed(&mut self, ticket: Ticket, now: u64) -> Vec<Effect> {
        if self
            .streams
            .get(&ticket.id)
            .is_none_or(|s| s.ticket != ticket)
        {
            return vec![];
        }
        self.failed.retain(|_, deadline| *deadline > now);
        if self.failed.len() >= 4096 {
            if let Some((&oldest, _)) = self.failed.iter().min_by_key(|(_, deadline)| *deadline) {
                self.failed.remove(&oldest);
            }
        }
        self.failed.insert(ticket.id, now.saturating_add(10_000));
        self.streams.remove(&ticket.id);
        vec![Effect::Close(ticket)]
    }
    pub fn collect(&mut self, now: u64) -> Vec<Effect> {
        let mut effects = Vec::new();
        self.streams.retain(|_, stream| {
            let age = now.saturating_sub(stream.last);
            if age > 5000 {
                effects.push(Effect::Close(stream.ticket));
                return false;
            }
            if age > 800 && stream.pipeline && !stream.paused {
                stream.paused = true;
                effects.push(Effect::Pause(stream.ticket));
            }
            true
        });
        self.failed.retain(|_, deadline| *deadline > now);
        effects
    }
    pub fn close_all(&mut self) -> Vec<Effect> {
        let effects = self
            .streams
            .values()
            .map(|s| Effect::Close(s.ticket))
            .collect();
        self.streams.clear();
        self.failed.clear();
        effects
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn idle_streams_pause_resume_and_close() {
        let mut p = Previews::new(2);
        let Effect::Start(t) = p.request(1, 0)[0] else {
            panic!("missing start")
        };
        p.pipeline_ready(t);
        assert!(p.collect(800).is_empty());
        assert_eq!(p.collect(801), [Effect::Pause(t)]);
        assert!(p.collect(900).is_empty());
        assert_eq!(p.request(1, 1000), [Effect::Resume(t)]);
        assert_eq!(p.collect(6001), [Effect::Close(t)]);
    }
    #[test]
    fn capacity_failure_and_shutdown_never_keep_extra_streams() {
        let mut p = Previews::new(1);
        let Effect::Start(first) = p.request(1, 0)[0] else {
            panic!("missing start")
        };
        assert!(p.request(2, 799).is_empty());
        let switched = p.request(2, 800);
        let Effect::Start(second) = switched[1] else {
            panic!("missing start")
        };
        assert_eq!(switched, [Effect::Close(first), Effect::Start(second)]);
        assert_eq!(p.failed(second, 1000), [Effect::Close(second)]);
        assert!(p.request(2, 10999).is_empty());
        let Effect::Start(third) = p.request(2, 11000)[0] else {
            panic!("missing start")
        };
        assert_eq!(p.close_all(), [Effect::Close(third)]);
        assert!(p.close_all().is_empty());
    }
    #[test]
    fn late_pipeline_does_not_revive_a_closed_stream() {
        let mut p = Previews::new(1);
        let Effect::Start(old) = p.request(1, 0)[0] else {
            panic!("missing start")
        };
        p.collect(5001);
        let Effect::Start(new) = p.request(1, 6000)[0] else {
            panic!("missing start")
        };
        p.pipeline_ready(old);
        assert!(p.failed(old, 6000).is_empty());
        assert!(p.collect(6801).is_empty());
        p.pipeline_ready(new);
        assert_eq!(p.collect(6802), [Effect::Pause(new)]);
        assert!(p.request(0, 7000).is_empty());
        assert_eq!(p.close_all(), [Effect::Close(new)]);
    }
}
