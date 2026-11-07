//! Demand-driven window previews; called only from the owning GLib context.
use macshell_capture_session::{Event as SessionEvent, Session};
use macshell_capture_stream::{store::Store, Frame, Pipeline};
use macshell_recording_core::preview::{Effect, Previews, Ticket};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::Instant;

pub trait Video {
    fn poll(&mut self) -> Result<Option<Frame>, &'static str>;
    fn pause(&mut self) -> Result<(), &'static str>;
    fn resume(&mut self) -> Result<(), &'static str>;
    fn restart(&mut self) -> Result<(), &'static str>;
}
impl Video for Pipeline {
    fn poll(&mut self) -> Result<Option<Frame>, &'static str> {
        Pipeline::poll(self)
    }
    fn pause(&mut self) -> Result<(), &'static str> {
        Pipeline::pause(self)
    }
    fn resume(&mut self) -> Result<(), &'static str> {
        Pipeline::resume(self)
    }
    fn restart(&mut self) -> Result<(), &'static str> {
        Pipeline::restart(self)
    }
}
pub type Factory = Box<dyn FnMut(u32, u32) -> Result<Box<dyn Video>, &'static str>>;
struct Stream {
    video: Option<Box<dyn Video>>,
    _session: Session,
    ticket: Ticket,
    token: u64,
    last_demand: u64,
    next_frame: u64,
    first_deadline: u64,
    retries: u8,
    received_frame: bool,
}
pub struct Manager {
    streams: BTreeMap<u64, Stream>,
    scheduler: Previews,
    store: Store,
    address: String,
    width: u32,
    interval: u64,
    next_token: u64,
    start: Instant,
    tx: Sender<SessionEvent>,
    rx: Receiver<SessionEvent>,
    output: Vec<Value>,
    factory: Factory,
}
impl Manager {
    /// # Safety
    /// All calls and destruction must occur on the owning GLib context thread,
    /// outside Gio callbacks, while that context is actively dispatched.
    pub unsafe fn new(
        address: String,
        parent: &Path,
        limit: usize,
        width: u32,
        fps: u32,
        factory: Factory,
    ) -> Result<Self, &'static str> {
        if address.is_empty() || address.contains('\0') {
            return Err("Invalid session bus.");
        }
        let store = Store::new(parent).map_err(|_| "Cannot create private preview directory.")?;
        let (tx, rx) = mpsc::channel();
        Ok(Self {
            streams: BTreeMap::new(),
            scheduler: Previews::new(limit),
            store,
            address,
            width: width.clamp(160, 1024),
            interval: 1000_u64.div_ceil(u64::from(fps.clamp(1, 10))),
            next_token: 0,
            start: Instant::now(),
            tx,
            rx,
            output: Vec::new(),
            factory,
        })
    }
    fn now(&self) -> u64 {
        self.start.elapsed().as_millis().min(u64::MAX as u128) as u64
    }
    pub fn request(&mut self, id: u64) {
        let now = self.now();
        let effects = self.scheduler.request(id, now);
        if let Some(stream) = self.streams.get_mut(&id) {
            stream.last_demand = now;
        }
        self.apply(effects);
    }
    fn error(&mut self, ticket: Ticket, error: &str) {
        let effects = self.scheduler.failed(ticket, self.now());
        self.output.push(json!({"id":ticket.id,"error":error}));
        self.apply(effects);
    }
    fn apply(&mut self, effects: Vec<Effect>) {
        for effect in effects {
            match effect {
                Effect::Start(ticket) => {
                    let Some(token) = self.next_token.checked_add(1) else {
                        self.error(ticket, "Preview sequence exhausted.");
                        continue;
                    };
                    self.next_token = token;
                    match unsafe {
                        Session::start(&self.address, ticket.id, token, self.tx.clone())
                    } {
                        Ok(session) => {
                            self.streams.insert(
                                ticket.id,
                                Stream {
                                    video: None,
                                    _session: session,
                                    ticket,
                                    token,
                                    last_demand: self.now(),
                                    next_frame: 0,
                                    first_deadline: self.now().saturating_add(2000),
                                    retries: 0,
                                    received_frame: false,
                                },
                            );
                        }
                        Err(error) => self.error(ticket, error),
                    }
                }
                Effect::Close(ticket) => {
                    if self
                        .streams
                        .get(&ticket.id)
                        .is_some_and(|s| s.ticket == ticket)
                    {
                        self.streams.remove(&ticket.id);
                        let _ = self.store.remove(ticket.id);
                    }
                }
                Effect::Pause(ticket) | Effect::Resume(ticket) => {
                    let failure = self
                        .streams
                        .get_mut(&ticket.id)
                        .filter(|s| s.ticket == ticket)
                        .and_then(|s| s.video.as_mut())
                        .and_then(|v| {
                            let result = if matches!(effect, Effect::Pause(_)) {
                                v.pause()
                            } else {
                                v.resume()
                            };
                            result.err()
                        });
                    if let Some(error) = failure {
                        self.error(ticket, error);
                    }
                }
            }
        }
    }
    pub fn tick(&mut self) {
        while let Ok(event) = self.rx.try_recv() {
            let token = match event {
                SessionEvent::Node { token, .. }
                | SessionEvent::Changed { token }
                | SessionEvent::OwnerLost { token } => token,
            };
            let current = self
                .streams
                .iter()
                .find(|(_, v)| v.token == token)
                .map(|(id, v)| (*id, v.ticket));
            let Some((id, ticket)) = current else {
                continue;
            };
            match event {
                SessionEvent::Node { node, .. } => match (self.factory)(node, self.width) {
                    Ok(video) => {
                        if let Some(stream) = self.streams.get_mut(&id) {
                            stream.video = Some(video);
                            stream.first_deadline = now_millis(self.start).saturating_add(2000);
                            self.scheduler.pipeline_ready(ticket);
                        }
                    }
                    Err(error) => self.error(ticket, error),
                },
                SessionEvent::Changed { .. } | SessionEvent::OwnerLost { .. } => {
                    self.error(ticket, "Window preview stream changed.")
                }
            }
        }
        let now = self.now();
        let effects = self.scheduler.collect(now);
        self.apply(effects);
        let mut finished = Vec::new();
        for stream in self.streams.values_mut() {
            if now.saturating_sub(stream.last_demand) > 800 || now < stream.next_frame {
                continue;
            }
            let Some(video) = stream.video.as_mut() else {
                continue;
            };
            stream.next_frame = now.saturating_add(self.interval);
            if !stream.received_frame && now >= stream.first_deadline {
                if stream.retries >= 2 {
                    finished.push((
                        stream.ticket,
                        Err("Window preview did not produce a frame."),
                    ));
                    continue;
                }
                if let Err(error) = video.restart() {
                    finished.push((stream.ticket, Err(error)));
                    continue;
                }
                stream.retries += 1;
                stream.first_deadline = now.saturating_add(2000);
            }
            match video.poll() {
                Ok(Some(frame)) => {
                    stream.received_frame = true;
                    finished.push((stream.ticket, Ok(frame)));
                }
                Ok(None) => (),
                Err(error) => finished.push((stream.ticket, Err(error))),
            }
        }
        for (ticket, result) in finished {
            match result {
                Ok(frame) => match self.store.write(ticket.id, &frame) {
                    Ok(url) => self.output.push(
                        json!({"id":ticket.id,"url":url,"width":frame.width,"height":frame.height}),
                    ),
                    Err(_) => self.error(ticket, "Cannot save window preview."),
                },
                Err(error) => self.error(ticket, error),
            }
        }
    }
    pub fn take_output(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.output)
    }
}
fn now_millis(start: Instant) -> u64 {
    start.elapsed().as_millis().min(u64::MAX as u128) as u64
}
impl Drop for Manager {
    fn drop(&mut self) {
        self.streams.clear();
    }
}
