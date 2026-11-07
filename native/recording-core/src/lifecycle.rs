//! Pure recorder lifecycle. The runtime owns all processes and files.
//! Times are monotonic milliseconds supplied by the runtime.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Choose,
    Selecting,
    Countdown,
    Starting,
    Mixing,
    Recording,
    Stopping,
    Saving,
    Result,
    Error,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Effect {
    Publish,
    HideControls,
    StartRecorder,
    StartSelector,
    StopSelector,
    InterruptRecorder,
    KillRecorder,
    CleanRoutes,
    ValidateFile,
}

pub struct Recorder {
    state: State,
    deadline: Option<u64>,
    child: bool,
    progress: bool,
    audio_ready: bool,
    needs_audio: bool,
    failed: bool,
    forced: bool,
    exit_ok: bool,
}
impl Default for Recorder {
    fn default() -> Self {
        Self {
            state: State::Choose,
            deadline: None,
            child: false,
            progress: false,
            audio_ready: false,
            needs_audio: false,
            failed: false,
            forced: false,
            exit_ok: false,
        }
    }
}
impl Recorder {
    pub fn state(&self) -> State {
        self.state
    }
    /// The caller must validate the selected output, region, audio devices and
    /// executables before beginning the countdown.
    pub fn start(&mut self, now: u64) -> Result<Vec<Effect>, &'static str> {
        if self.child || !matches!(self.state, State::Choose | State::Result | State::Error) {
            return Err("A recording operation is already in progress.");
        }
        self.state = State::Countdown;
        self.deadline = Some(now.saturating_add(3000));
        self.failed = false;
        self.forced = false;
        self.progress = false;
        self.audio_ready = false;
        self.exit_ok = false;
        Ok(vec![Effect::Publish])
    }
    pub fn select(&mut self, now: u64) -> Result<Vec<Effect>, &'static str> {
        if self.child || !matches!(self.state, State::Choose | State::Result | State::Error) {
            return Err("A recording operation is already in progress.");
        }
        self.state = State::Selecting;
        self.deadline = Some(now.saturating_add(400));
        Ok(vec![Effect::HideControls, Effect::Publish])
    }
    pub fn selection_done(&mut self) -> Vec<Effect> {
        if self.state != State::Selecting {
            return vec![];
        }
        self.state = State::Choose;
        self.deadline = None;
        vec![Effect::Publish]
    }
    pub fn mixing(&mut self, now: u64) -> Vec<Effect> {
        if self.state != State::Starting || self.child || self.deadline.is_some() {
            return vec![];
        }
        self.state = State::Mixing;
        self.deadline = Some(now.saturating_add(5000));
        vec![Effect::Publish]
    }
    pub fn mixer_ready(&mut self) -> Vec<Effect> {
        if self.state != State::Mixing {
            return vec![];
        }
        self.state = State::Starting;
        self.deadline = None;
        vec![Effect::Publish, Effect::StartRecorder]
    }
    pub fn tick(&mut self, now: u64) -> Vec<Effect> {
        if self.deadline.is_none_or(|deadline| now < deadline) {
            return vec![];
        }
        match self.state {
            State::Selecting => {
                self.deadline = None;
                vec![Effect::StartSelector]
            }
            State::Countdown => {
                self.state = State::Starting;
                self.deadline = Some(now.saturating_add(400));
                vec![Effect::HideControls, Effect::Publish]
            }
            State::Starting if !self.child => {
                self.deadline = None;
                vec![Effect::StartRecorder]
            }
            State::Starting => self.fail(now),
            State::Mixing => self.fail(now),
            State::Stopping if self.child && !self.forced => {
                self.forced = true;
                self.deadline = None;
                vec![Effect::KillRecorder]
            }
            _ => vec![],
        }
    }
    /// Called only after a child owned by this operation has started.
    pub fn spawned(&mut self, now: u64, needs_audio: bool) -> Vec<Effect> {
        if self.state != State::Starting || self.child || self.deadline.is_some() {
            return vec![];
        }
        self.child = true;
        self.needs_audio = needs_audio;
        self.audio_ready = !needs_audio;
        self.deadline = Some(now.saturating_add(10_000));
        vec![Effect::Publish]
    }
    /// Video output and the selected audio links must both be confirmed.
    pub fn ready(&mut self, video: bool, audio: bool) -> Vec<Effect> {
        if self.state != State::Starting || !self.child {
            return vec![];
        }
        self.progress |= video;
        self.audio_ready = !self.needs_audio || audio;
        if self.progress && self.audio_ready {
            self.state = State::Recording;
            self.deadline = None;
            vec![Effect::Publish]
        } else {
            vec![]
        }
    }
    pub fn stop(&mut self, now: u64) -> Vec<Effect> {
        if self.child {
            if self.state == State::Stopping {
                return vec![];
            }
            self.state = State::Stopping;
            self.deadline = Some(now.saturating_add(10_000));
            vec![Effect::InterruptRecorder, Effect::Publish]
        } else if matches!(
            self.state,
            State::Selecting | State::Countdown | State::Starting | State::Mixing
        ) {
            let selecting = self.state == State::Selecting;
            self.state = State::Choose;
            self.deadline = None;
            if selecting {
                vec![Effect::StopSelector, Effect::Publish]
            } else {
                vec![Effect::CleanRoutes, Effect::Publish]
            }
        } else {
            vec![]
        }
    }
    /// Failure stops only this recorder; the runtime retains any partial file.
    pub fn fail(&mut self, now: u64) -> Vec<Effect> {
        self.failed = true;
        if self.child {
            self.stop(now)
        } else {
            self.state = State::Error;
            self.deadline = None;
            vec![Effect::CleanRoutes, Effect::Publish]
        }
    }
    pub fn child_exited(&mut self, accepted_exit: bool) -> Vec<Effect> {
        if !self.child {
            return vec![];
        }
        self.child = false;
        self.exit_ok = accepted_exit;
        self.state = State::Saving;
        self.deadline = None;
        vec![Effect::Publish, Effect::CleanRoutes, Effect::ValidateFile]
    }
    /// The runtime validates the exact operation-owned file with ffprobe.
    pub fn validated(&mut self, valid: bool) -> Vec<Effect> {
        if self.state != State::Saving {
            return vec![];
        }
        self.state = if valid && self.exit_ok && !self.failed && !self.forced {
            State::Result
        } else {
            State::Error
        };
        vec![Effect::Publish]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cancel_countdown_never_starts_recorder() {
        let mut r = Recorder::default();
        r.start(10).unwrap();
        assert_eq!(r.stop(20), vec![Effect::CleanRoutes, Effect::Publish]);
        assert!(r.tick(10000).is_empty());
        assert_eq!(r.state(), State::Choose);
    }
    #[test]
    fn requires_hidden_controls_frames_audio_and_valid_file() {
        let mut r = Recorder::default();
        r.start(0).unwrap();
        assert_eq!(r.tick(3000), vec![Effect::HideControls, Effect::Publish]);
        assert!(r.tick(3399).is_empty());
        assert_eq!(r.tick(3400), vec![Effect::StartRecorder]);
        r.spawned(3400, true);
        assert!(r.ready(true, false).is_empty());
        assert_eq!(r.ready(false, true), vec![Effect::Publish]);
        assert_eq!(r.state(), State::Recording);
        assert_eq!(
            r.stop(4000),
            vec![Effect::InterruptRecorder, Effect::Publish]
        );
        assert_eq!(
            r.child_exited(true),
            vec![Effect::Publish, Effect::CleanRoutes, Effect::ValidateFile]
        );
        r.validated(true);
        assert_eq!(r.state(), State::Result);
    }
    #[test]
    fn failures_and_forced_termination_never_report_success() {
        for fail in [true, false] {
            let mut r = Recorder::default();
            r.start(0).unwrap();
            r.tick(3000);
            r.tick(3400);
            r.spawned(3400, false);
            if fail {
                r.fail(3500);
            } else {
                r.stop(3500);
                assert_eq!(r.tick(13500), vec![Effect::KillRecorder]);
            }
            r.child_exited(true);
            r.validated(true);
            assert_eq!(r.state(), State::Error);
        }
    }
    #[test]
    fn startup_timeout_stops_only_owned_child() {
        let mut r = Recorder::default();
        r.start(0).unwrap();
        r.tick(3000);
        r.tick(3400);
        r.spawned(3400, true);
        assert_eq!(
            r.tick(13400),
            vec![Effect::InterruptRecorder, Effect::Publish]
        );
        assert_eq!(r.state(), State::Stopping);
        assert!(r.stop(13401).is_empty());
    }
}
