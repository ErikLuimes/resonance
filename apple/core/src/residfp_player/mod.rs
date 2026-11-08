//! The pull-driven engines: libsidplayfp with libresidfp (reSIDfp) or with
//! its own SIDLite chip, driven from the audio output callback.
//!
//! Phosphor's engines run the C64 on a player thread paced by the wall
//! clock and push samples through a mutex ring to cpal. Here the output
//! callback pulls: it renders exactly the frames the device asks for, so
//! there's no pacing, no spin wait and no ring. A control thread owns the
//! cpal stream and speaks upstream's `PlayerCmd` / `PlayerStatus` protocol,
//! so the session thread can't tell the difference; elapsed time is the
//! samples rendered.
//!
//! Each `Play` and `SetSubtune` builds a fresh libsidplayfp instance on the
//! control thread (loading a tune and running its init takes milliseconds)
//! and hands it to the callback through a channel; the callback swaps it in
//! between buffers and sends the old one back to be freed off the audio
//! thread. After each buffer the callback reports the chips' registers,
//! envelopes and scope samples; the control thread turns those into
//! statuses and visualizer frames.
//!
//! Seeking (`Seeker`): libsidplayfp can't save or restore state, so a seek
//! runs the emulation silently to the target on a worker thread, with the
//! chips' digital parts only (half the cost) and the last half second in
//! full so the filter has settled. Forward, the callback hands the playing
//! engine back and the worker runs it the rest of the way; backward, a
//! fresh instance with the track's power-on delay starts from the top.
//! The audio is silent meanwhile, elapsed time shows the target at once,
//! and `Seeker::seeking` tells the UI. See design/scrubbing/README.md.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use crossbeam_channel::{bounded, select, tick, Receiver, Sender};
use residfp_sys::{
    Chip, ChipState as RawChip, Config, EnvPhase, Player as Engine, SamplingMethod, SkipMode,
    Started, TuneInfo,
};

use crate::player::sid_file;
use crate::player::{DeviceConfigEvent, PlayState, PlayerCmd, PlayerStatus, TrackInfo};
use crate::session;
use crate::viz::{
    self, ChipState, EnvState, Frame, SharedFeed, CYCLES_PER_SAMPLE, FRAME_REGS, MAX_CHIPS,
};

#[cfg(test)]
mod tests;

/// Frames rendered per call into the engine; the callback loops for more.
const CHUNK: usize = 2048;
/// Scope samples a report holds per voice: a 4096-frame buffer at 44.1 kHz
/// is 92 ms, about 4200 samples at PAL; longer buffers lose a few.
const SCOPE_CAP: usize = 4096;
/// Reports in flight before the callback drops some.
const REPORT_QUEUE: usize = 32;
/// Reports kept for reuse, so the callback rarely allocates.
const POOL: usize = 8;
/// At most one status per this; writes accumulate across skipped reports.
const STATUS_PERIOD: Duration = Duration::from_millis(20);
const REGS_PER_CHIP: usize = 32;
/// How much of a seek is rendered in full rather than skipped digitally,
/// so the filter and resampler have settled when the audio resumes.
const RENDER_TAIL: Duration = Duration::from_millis(500);
/// How often the seek worker reports where it is, in tune time.
const SEEK_STEP: Duration = Duration::from_millis(100);

// ── Settings ─────────────────────────────────────────────────────────────────

static SAMPLING: AtomicU8 = AtomicU8::new(0);

/// The resampler for tunes started from now on: `Interpolate` (reSIDfp's
/// zero-order resampler, the default) or `Resample` (sinc, several times
/// the cost).
#[allow(dead_code)]
pub(crate) fn set_sampling(method: SamplingMethod) {
    SAMPLING.store(
        match method {
            SamplingMethod::Interpolate => 0,
            SamplingMethod::Resample => 1,
        },
        Ordering::Relaxed,
    );
}

fn sampling() -> SamplingMethod {
    match SAMPLING.load(Ordering::Relaxed) {
        1 => SamplingMethod::Resample,
        _ => SamplingMethod::Interpolate,
    }
}

// ── Spawning ─────────────────────────────────────────────────────────────────

/// Where the audio goes.
pub(crate) enum Output {
    /// The default output device, through cpal.
    Device,
    /// For tests: a thread that asks for `block` frames every `period`, as a
    /// device at `rate` would (faster, with a short period).
    #[allow(dead_code)]
    Fake {
        rate: u32,
        block: usize,
        period: Duration,
    },
}

/// The chip a pull-driven engine plays through; `None` for upstream's.
pub(crate) fn chip_for(engine: session::Engine) -> Option<Chip> {
    match engine {
        session::Engine::ReSidFp => Some(Chip::ReSidFp),
        session::Engine::SidLiteDirect => Some(Chip::SidLite),
        session::Engine::SidLite | session::Engine::ReSid => None,
    }
}

/// The seek side of the player, which upstream's `PlayerCmd` has no room for.
pub(crate) struct Seeker {
    /// Where to go, from the start of the subtune. Beyond its end is the
    /// caller's problem (the session advances when elapsed passes the
    /// length).
    pub targets: Sender<Duration>,
    /// True from a seek's start until its audio plays.
    pub seeking: Arc<AtomicBool>,
    /// While seeking: where the emulation is, in milliseconds from the
    /// start of the subtune, as the worker runs it toward the target.
    pub position_ms: Arc<AtomicU64>,
}

/// Start the player thread for `engine` (a pull-driven one). The first
/// three are the same shape as upstream's `spawn_player`, so the driver
/// treats both alike; `viz` receives the visualizer frames.
pub(crate) fn spawn(
    viz: SharedFeed,
    engine: session::Engine,
) -> (
    Sender<PlayerCmd>,
    Receiver<PlayerStatus>,
    Receiver<DeviceConfigEvent>,
    Seeker,
) {
    spawn_with(viz, chip_for(engine).unwrap_or_default(), Output::Device)
}

pub(crate) fn spawn_with(
    viz: SharedFeed,
    chip: Chip,
    output: Output,
) -> (
    Sender<PlayerCmd>,
    Receiver<PlayerStatus>,
    Receiver<DeviceConfigEvent>,
    Seeker,
) {
    let (cmd_tx, cmd_rx) = bounded::<PlayerCmd>(64);
    let (status_tx, status_rx) = bounded::<PlayerStatus>(16);
    let (device_tx, device_rx) = bounded::<DeviceConfigEvent>(16);
    let (seek_tx, seek_rx) = bounded::<Duration>(16);
    let seeking = Arc::new(AtomicBool::new(false));
    let position_ms = Arc::new(AtomicU64::new(0));
    let (flag, position) = (seeking.clone(), position_ms.clone());
    thread::Builder::new()
        .name("resonance-residfp".into())
        .spawn(move || {
            Control::new(status_tx, device_tx, viz, chip, output, flag, position).run(cmd_rx, seek_rx)
        })
        .expect("failed to spawn the pull-driven player thread");
    (
        cmd_tx,
        status_rx,
        device_rx,
        Seeker {
            targets: seek_tx,
            seeking,
            position_ms,
        },
    )
}

// ── Audio side ───────────────────────────────────────────────────────────────

enum ToAudio {
    /// Play this from the next buffer on.
    Swap(Box<Live>),
    /// Silence; the engine goes back to be freed.
    Drop,
    Pause(bool),
    /// Hand the playing engine back to the control thread (a forward seek
    /// runs it on from where it is); silence until the next Swap.
    Return,
}

/// A started tune, owned by the callback while it plays.
struct Live {
    engine: Engine,
    /// Ties reports to the track the control thread started.
    id: u64,
    chips: usize,
    /// Frames rendered so far.
    samples: u64,
    rate: u32,
    cpu_hz: f64,
}

impl Live {
    /// Run silently from `from` to `target`: digitally, then the last
    /// `RENDER_TAIL` in full, reporting where it is in `position_ms` every
    /// `SEEK_STEP`. Afterward the sample count says `target`.
    fn skip_to(&mut self, from: Duration, target: Duration, position_ms: &AtomicU64) {
        let cycles = ((target.saturating_sub(from)).as_secs_f64() * self.cpu_hz) as u64;
        let tail = ((RENDER_TAIL.as_secs_f64() * self.cpu_hz) as u64).min(cycles);
        let step = (SEEK_STEP.as_secs_f64() * self.cpu_hz) as u64;
        let mut done = 0;
        while done < cycles - tail {
            let n = step.min(cycles - tail - done);
            self.engine.skip(n, SkipMode::Digital);
            done += n;
            let at = from + Duration::from_secs_f64(done as f64 / self.cpu_hz);
            position_ms.store(at.as_millis() as u64, Ordering::Relaxed);
        }
        self.engine.skip(tail, SkipMode::Render);
        position_ms.store(target.as_millis() as u64, Ordering::Relaxed);
        self.samples = (target.as_secs_f64() * self.rate as f64) as u64;
    }
}

/// What one buffer's worth of rendering produced.
struct Report {
    id: u64,
    /// Frames rendered for the track, after this buffer.
    samples_end: u64,
    chips: usize,
    state: [RawChip; MAX_CHIPS],
    /// Per chip, three voices of `SCOPE_CAP` samples each.
    scope: Vec<f32>,
    /// Samples per voice in `scope`, per chip.
    scope_len: [usize; MAX_CHIPS],
    /// Register writes across all chips.
    writes: u32,
    /// When the callback ran: the buffer plays after the output device's
    /// latency, which the feed's reads add.
    at: Instant,
    /// Emulation time.
    took: Duration,
    error: Option<String>,
}

impl Report {
    fn new() -> Self {
        Self {
            id: 0,
            samples_end: 0,
            chips: 0,
            state: [RawChip::default(); MAX_CHIPS],
            scope: Vec::new(),
            scope_len: [0; MAX_CHIPS],
            writes: 0,
            at: Instant::now(),
            took: Duration::ZERO,
            error: None,
        }
    }

    fn capture(&mut self, live: &mut Live, at: Instant, took: Duration, error: Option<String>) {
        self.id = live.id;
        self.samples_end = live.samples;
        self.chips = live.chips.min(MAX_CHIPS);
        self.at = at;
        self.took = took;
        self.error = error;
        self.writes = 0;
        let need = self.chips * 3 * SCOPE_CAP;
        if self.scope.len() < need {
            self.scope.resize(need, 0.0);
        }
        for c in 0..self.chips {
            self.state[c] = live.engine.chip_state(c).unwrap_or_default();
            let part = &mut self.scope[c * 3 * SCOPE_CAP..(c + 1) * 3 * SCOPE_CAP];
            self.scope_len[c] = live.engine.take_scope(c, part);
            let (_, total) = live.engine.take_writes(c, &mut []);
            self.writes += total;
        }
    }

    /// Voice `v` of chip `c`.
    fn voice(&self, c: usize, v: usize) -> &[f32] {
        let base = (c * 3 + v) * SCOPE_CAP;
        &self.scope[base..base + self.scope_len[c]]
    }
}

/// The callback's state.
struct Source {
    inbox: Receiver<ToAudio>,
    reports: Sender<Box<Report>>,
    pool: Receiver<Box<Report>>,
    retired: Sender<Box<Live>>,
    /// Answers `ToAudio::Return`: the engine, or None when nothing plays.
    returned: Sender<Option<Box<Live>>>,
    live: Option<Box<Live>>,
    paused: bool,
    scratch: Vec<i16>,
}

impl Source {
    /// Fill `data` (interleaved stereo f32) with the next frames.
    fn fill(&mut self, data: &mut [f32]) {
        let at = Instant::now();
        for msg in self.inbox.try_iter() {
            match msg {
                ToAudio::Swap(live) => {
                    if let Some(old) = self.live.replace(live) {
                        let _ = self.retired.try_send(old);
                    }
                    self.paused = false;
                }
                ToAudio::Drop => {
                    if let Some(old) = self.live.take() {
                        let _ = self.retired.try_send(old);
                    }
                }
                ToAudio::Pause(paused) => self.paused = paused,
                ToAudio::Return => {
                    let _ = self.returned.try_send(self.live.take());
                }
            }
        }
        let frames = data.len() / 2;
        let Some(live) = self.live.as_mut().filter(|_| !self.paused) else {
            data.fill(0.0);
            return;
        };

        let gain = crate::audio_volume::scale() / 32768.0;
        let began = Instant::now();
        let mut done = 0;
        let mut error = None;
        while done < frames {
            let n = (frames - done).min(CHUNK);
            let got = live.engine.render(&mut self.scratch[..n * 2]);
            for (out, &s) in data[done * 2..(done + got) * 2]
                .iter_mut()
                .zip(&self.scratch[..got * 2])
            {
                *out = s as f32 * gain;
            }
            done += got;
            if got < n {
                error = Some(live.engine.error());
                data[done * 2..].fill(0.0);
                break;
            }
        }
        live.samples += done as u64;

        let mut report = self
            .pool
            .try_recv()
            .unwrap_or_else(|_| Box::new(Report::new()));
        report.capture(live, at, began.elapsed(), error.clone());
        // Full means the control thread is behind; this buffer's frame is
        // lost to the visualizers, nothing else.
        let _ = self.reports.try_send(report);
        if error.is_some() {
            if let Some(old) = self.live.take() {
                let _ = self.retired.try_send(old);
            }
        }
    }
}

/// The open output: dropping it ends the audio thread and its stream.
struct Sink {
    rate: u32,
    _stop: Sender<()>,
}

fn open_sink(output: &Output, mut source: Source) -> Result<Sink, String> {
    let (stop_tx, stop_rx) = bounded::<()>(0);
    match *output {
        Output::Device => {
            let (ready_tx, ready_rx) = bounded::<Result<u32, String>>(1);
            thread::Builder::new()
                .name("residfp-audio".into())
                .spawn(move || {
                    let opened = (|| -> Result<(cpal::Stream, u32), String> {
                        let host = cpal::default_host();
                        let device = host
                            .default_output_device()
                            .ok_or_else(|| "No audio output device found".to_string())?;
                        let name = device.name().unwrap_or_else(|_| "unknown".into());
                        let default = device
                            .default_output_config()
                            .map_err(|e| format!("No default output config: {e}"))?;
                        let rate = default.sample_rate().0;
                        eprintln!("[residfp] Audio device: '{name}', {rate} Hz");
                        let config = cpal::StreamConfig {
                            channels: 2,
                            sample_rate: cpal::SampleRate(rate),
                            buffer_size: cpal::BufferSize::Default,
                        };
                        let stream = device
                            .build_output_stream(
                                &config,
                                move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                                    source.fill(data)
                                },
                                |err| eprintln!("[residfp] Audio error: {err}"),
                                None,
                            )
                            .map_err(|e| format!("build_output_stream failed: {e}"))?;
                        stream
                            .play()
                            .map_err(|e| format!("stream.play() failed: {e}"))?;
                        Ok((stream, rate))
                    })();
                    match opened {
                        Ok((stream, rate)) => {
                            let _ = ready_tx.send(Ok(rate));
                            // Until the Sink is dropped.
                            let _ = stop_rx.recv();
                            drop(stream);
                        }
                        Err(e) => {
                            let _ = ready_tx.send(Err(e));
                        }
                    }
                })
                .map_err(|e| format!("spawn audio thread: {e}"))?;
            let rate = ready_rx
                .recv()
                .map_err(|_| "audio thread died before reporting".to_string())??;
            Ok(Sink {
                rate,
                _stop: stop_tx,
            })
        }
        Output::Fake {
            rate,
            block,
            period,
        } => {
            thread::Builder::new()
                .name("residfp-fake-audio".into())
                .spawn(move || {
                    let mut buf = vec![0f32; block * 2];
                    while let Err(crossbeam_channel::RecvTimeoutError::Timeout) =
                        stop_rx.recv_timeout(period)
                    {
                        source.fill(&mut buf);
                    }
                })
                .map_err(|e| format!("spawn fake audio thread: {e}"))?;
            Ok(Sink {
                rate,
                _stop: stop_tx,
            })
        }
    }
}

// ── Control side ─────────────────────────────────────────────────────────────

/// The playing track, as the control thread tracks it.
struct Track {
    info: TrackInfo,
    id: u64,
    rate: u32,
    chips: usize,
    is_pal: bool,
    mono_2sid: bool,
    /// What the engine was started with, so a seek's fresh instance lines
    /// up with this one.
    power_on_delay: u16,
    elapsed: Duration,
    regs: Vec<u8>,
    levels: Vec<f32>,
    /// The visualizer frame being gathered from reports.
    frame_index: u64,
    frame_start: Duration,
    frame_at: Option<Instant>,
    frame_took: Duration,
    frame_scope: Vec<Vec<f32>>,
    frame_chips: [ChipState; MAX_CHIPS],
}

struct Roms {
    kernal: Option<Vec<u8>>,
    basic: Option<Vec<u8>>,
    chargen: Option<Vec<u8>>,
}

struct Control {
    status_tx: Sender<PlayerStatus>,
    /// Device-config replies: only ever "not available" here.
    device_tx: Sender<DeviceConfigEvent>,
    viz: SharedFeed,
    chip: Chip,
    output: Output,
    sink: Option<Sink>,
    to_audio: Sender<ToAudio>,
    reports_tx: Sender<Box<Report>>,
    reports_rx: Receiver<Box<Report>>,
    pool_tx: Sender<Box<Report>>,
    retired_tx: Sender<Box<Live>>,
    retired_rx: Receiver<Box<Live>>,
    state: PlayState,
    track: Option<Track>,
    last_error: Option<String>,
    next_id: u64,
    roms: Roms,
    last_status: Instant,
    pending_writes: usize,
    warned_pseudo: bool,
    // ── seeking ──
    seeking: Arc<AtomicBool>,
    seek_position_ms: Arc<AtomicU64>,
    seek: Option<Seek>,
    returned_tx: Sender<Option<Box<Live>>>,
    returned_rx: Receiver<Option<Box<Live>>>,
    seek_done_tx: Sender<SeekDone>,
    seek_done_rx: Receiver<SeekDone>,
}

/// A seek in flight.
struct Seek {
    target: Duration,
    started: Instant,
    /// The track id when it started; a result for another track is dropped.
    for_track: u64,
    /// Asked for while this one ran; starts when it lands.
    pending: Option<Duration>,
}

/// The worker's result: the engine at `target`.
struct SeekDone {
    live: Box<Live>,
    target: Duration,
    for_track: u64,
}

/// What `build` makes of a tune file.
struct Built {
    engine: Engine,
    tune: TuneInfo,
    started: Started,
    data: Vec<u8>,
    is_mus: bool,
}

impl Control {
    fn new(
        status_tx: Sender<PlayerStatus>,
        device_tx: Sender<DeviceConfigEvent>,
        viz: SharedFeed,
        chip: Chip,
        output: Output,
        seeking: Arc<AtomicBool>,
        seek_position_ms: Arc<AtomicU64>,
    ) -> Self {
        let (reports_tx, reports_rx) = bounded(REPORT_QUEUE);
        let (retired_tx, retired_rx) = bounded(8);
        let (returned_tx, returned_rx) = bounded(1);
        let (seek_done_tx, seek_done_rx) = bounded(2);
        // Replaced when the sink opens; until then nothing listens.
        let (to_audio, _) = bounded(1);
        let (pool_tx, _) = bounded(1);
        Self {
            status_tx,
            device_tx,
            viz,
            chip,
            output,
            sink: None,
            to_audio,
            reports_tx,
            reports_rx,
            pool_tx,
            retired_tx,
            retired_rx,
            state: PlayState::Stopped,
            track: None,
            last_error: None,
            next_id: 1,
            roms: find_roms(),
            last_status: Instant::now(),
            pending_writes: 0,
            warned_pseudo: false,
            seeking,
            seek_position_ms,
            seek: None,
            returned_tx,
            returned_rx,
            seek_done_tx,
            seek_done_rx,
        }
    }

    fn run(mut self, commands: Receiver<PlayerCmd>, seeks: Receiver<Duration>) {
        let reports = self.reports_rx.clone();
        let retired = self.retired_rx.clone();
        let returned = self.returned_rx.clone();
        let seek_done = self.seek_done_rx.clone();
        let mut seeks = seeks;
        let idle = tick(Duration::from_millis(100));
        loop {
            select! {
                recv(commands) -> msg => match msg {
                    Ok(PlayerCmd::Quit) | Err(_) => break,
                    Ok(cmd) => self.handle(cmd),
                },
                recv(seeks) -> target => match target {
                    Ok(target) => self.seek(target),
                    // The seeker was dropped; the thread ends with the commands.
                    Err(_) => seeks = crossbeam_channel::never(),
                },
                recv(returned) -> live => {
                    if let Ok(live) = live {
                        self.seek_from_live(live);
                    }
                }
                recv(seek_done) -> done => {
                    if let Ok(done) = done {
                        self.seek_done(done);
                    }
                }
                recv(reports) -> report => {
                    if let Ok(report) = report {
                        self.report(report);
                    }
                }
                recv(retired) -> live => drop(live),
                recv(idle) -> _ => {
                    if self.state != PlayState::Playing {
                        self.send_status();
                    }
                }
            }
        }
        self.stop_playback();
        self.sink = None;
        eprintln!("[residfp] Player thread exiting");
    }

    fn handle(&mut self, cmd: PlayerCmd) {
        match cmd {
            PlayerCmd::Play {
                path,
                song,
                force_stereo,
                pseudo_stereo,
                ..
            } => {
                self.last_error = None;
                if pseudo_stereo.is_some() && !self.warned_pseudo {
                    eprintln!("[residfp] pseudo-stereo isn't supported on this engine");
                    self.warned_pseudo = true;
                }
                self.begin(path, song, force_stereo);
            }
            PlayerCmd::Stop => {
                self.stop_playback();
                self.send_status();
            }
            PlayerCmd::TogglePause => {
                match self.state {
                    PlayState::Playing => {
                        self.state = PlayState::Paused;
                        let _ = self.to_audio.try_send(ToAudio::Pause(true));
                    }
                    PlayState::Paused => {
                        self.state = PlayState::Playing;
                        let _ = self.to_audio.try_send(ToAudio::Pause(false));
                    }
                    PlayState::Stopped => {}
                }
                self.send_status();
            }
            PlayerCmd::SetSubtune(song) => {
                if let Some(track) = &self.track {
                    let (path, mono) = (track.info.path.clone(), track.mono_2sid);
                    self.last_error = None;
                    self.begin(path, song, mono);
                }
            }
            PlayerCmd::SetEngine(name, ..) => {
                // Between the pull-driven engines the thread stays; the
                // session replays the track on the new chip.
                match name.as_str() {
                    "residfp" => self.chip = Chip::ReSidFp,
                    "sidlite-direct" => self.chip = Chip::SidLite,
                    other => eprintln!("[residfp] not an engine of this player: {other}"),
                }
                self.stop_playback();
                self.send_status();
            }
            PlayerCmd::SetMacosUsbMode(_) => {
                self.stop_playback();
                self.send_status();
            }
            PlayerCmd::UpdateU64Config(..) | PlayerCmd::SetPedalboard(_) => {}
            PlayerCmd::DeviceConfig(_) => {
                let _ = self.device_tx.try_send(Err(
                    "device configuration is only available on the USB engine".into(),
                ));
            }
            PlayerCmd::Quit => {}
        }
    }

    /// Play `song` of the tune at `path`; on failure, stop with the error.
    fn begin(&mut self, path: PathBuf, song: u16, mono_2sid: bool) {
        match self.start(&path, song, mono_2sid) {
            Ok(()) => self.state = PlayState::Playing,
            Err(e) => {
                eprintln!("[residfp] {e}");
                self.stop_playback();
                self.last_error = Some(e);
            }
        }
        self.send_status();
    }

    /// Load the tune at `path` and start `song` on a fresh engine, with
    /// `power_on_delay` or a random one.
    fn build(
        &self,
        path: &Path,
        song: u16,
        mono_2sid: bool,
        rate: u32,
        power_on_delay: Option<u16>,
    ) -> Result<Built, String> {
        let data =
            std::fs::read(path).map_err(|e| format!("Cannot read {}: {e}", path.display()))?;
        let is_mus = path
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| e.eq_ignore_ascii_case("mus"));

        let mut engine = Engine::new()?;
        engine.set_roms(
            self.roms.kernal.as_deref(),
            self.roms.basic.as_deref(),
            self.roms.chargen.as_deref(),
        );
        // By path for MUS, so the companion .str is found.
        let tune = if is_mus {
            engine.load_path(path)?
        } else {
            engine.load_bytes(&data)?
        };
        let cfg = Config {
            sample_rate: rate,
            sampling: sampling(),
            mono_2sid: mono_2sid && tune.chips == 2,
            scope_cycles: CYCLES_PER_SAMPLE as u8,
            chip: self.chip,
            power_on_delay,
            ..Config::default()
        };
        let started = engine.start(song, &cfg)?;
        Ok(Built {
            engine,
            tune,
            started,
            data,
            is_mus,
        })
    }

    fn start(&mut self, path: &Path, song: u16, mono_2sid: bool) -> Result<(), String> {
        let rate = match &self.sink {
            Some(sink) => sink.rate,
            None => self.open_output()?,
        };
        let Built {
            engine,
            tune,
            started,
            data,
            is_mus,
        } = self.build(path, song, mono_2sid, rate, None)?;
        let mono_2sid = mono_2sid && tune.chips == 2;

        // The same MD5 as the other engines (upstream's parser), with
        // libsidplayfp's as the fallback.
        let md5 = sid_file::load_sid(&data)
            .ok()
            .or_else(|| is_mus.then(|| sid_file::load_mus_stub(&data, Some(path))))
            .map(|f| sid_file::compute_hvsc_md5(&f))
            .or_else(|| engine.md5())
            .unwrap_or_default();
        let name = if tune.title.is_empty() {
            path.file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default()
        } else {
            tune.title.clone()
        };
        let sid_type = if mono_2sid {
            "2SID → Stereo (forced mono)".to_string()
        } else {
            match started.chips {
                1 => "Mono".to_string(),
                2 => "2SID Stereo".to_string(),
                n => format!("{n}SID"),
            }
        };
        let info = TrackInfo {
            path: path.to_path_buf(),
            name,
            author: tune.author.clone(),
            released: tune.released.clone(),
            songs: tune.songs,
            current_song: started.song,
            is_pal: started.is_pal,
            is_rsid: tune.is_rsid(),
            num_sids: started.chips,
            sid_type,
            sid_model: tune.models[0],
            md5,
            mus_comments: tune.comments.clone(),
        };
        eprintln!(
            "[residfp] Loading: \"{}\" by {} — song {}/{} [{}] {} {}, {} at {} Hz on {}",
            info.name,
            info.author,
            info.current_song,
            info.songs,
            tune.format,
            if started.is_pal { "PAL" } else { "NTSC" },
            started.models[..started.chips]
                .iter()
                .map(|m| match m {
                    residfp_sys::ChipModel::Mos6581 => "6581",
                    residfp_sys::ChipModel::Mos8580 => "8580",
                })
                .collect::<Vec<_>>()
                .join("+"),
            info.sid_type,
            rate,
            match self.chip {
                Chip::ReSidFp => "reSIDfp",
                Chip::SidLite => "SIDLite",
            },
        );

        let id = self.next_id;
        self.next_id += 1;
        let live = Box::new(Live {
            engine,
            id,
            chips: started.chips,
            samples: 0,
            rate,
            cpu_hz: started.cpu_hz,
        });
        self.to_audio
            .try_send(ToAudio::Swap(live))
            .map_err(|_| "the audio output isn't taking commands".to_string())?;

        self.cancel_seek();
        viz::lock(&self.viz).begin_track(started.is_pal);
        let chips = started.chips.min(MAX_CHIPS);
        self.track = Some(Track {
            info,
            id,
            rate,
            chips,
            is_pal: started.is_pal,
            mono_2sid,
            power_on_delay: started.power_on_delay,
            elapsed: Duration::ZERO,
            regs: vec![0; MAX_CHIPS * REGS_PER_CHIP],
            levels: vec![0.0; chips * 3],
            frame_index: 0,
            frame_start: Duration::ZERO,
            frame_at: None,
            frame_took: Duration::ZERO,
            frame_scope: (0..chips * 3).map(|_| Vec::with_capacity(2048)).collect(),
            frame_chips: [ChipState::default(); MAX_CHIPS],
        });
        self.pending_writes = 0;
        Ok(())
    }

    // ── Seeking ──

    /// Go to `target` in the playing track: silence, then the audio
    /// resumes there once the emulation has caught up.
    fn seek(&mut self, target: Duration) {
        if self.state == PlayState::Stopped {
            return;
        }
        let Some(track) = self.track.as_mut() else { return };
        if let Some(seek) = &mut self.seek {
            seek.pending = Some(target);
            return;
        }
        let forward = target >= track.elapsed;
        self.seek = Some(Seek {
            target,
            started: Instant::now(),
            for_track: track.id,
            pending: None,
        });
        // Where the run starts: here, or the top for a fresh instance.
        let start = if forward { track.elapsed } else { Duration::ZERO };
        self.seek_position_ms
            .store(start.as_millis() as u64, Ordering::Relaxed);
        self.seeking.store(true, Ordering::Relaxed);
        // The bar jumps now; the audio follows.
        track.elapsed = target;
        track.frame_start = target;
        track.frame_at = None;
        track.frame_took = Duration::ZERO;
        track.frame_scope.iter_mut().for_each(Vec::clear);
        self.send_status();
        if forward {
            // The callback hands the engine back (`seek_from_live`).
            if self.to_audio.try_send(ToAudio::Return).is_err() {
                self.cancel_seek();
            }
        } else {
            let _ = self.to_audio.try_send(ToAudio::Pause(true));
            self.seek_fresh();
        }
    }

    /// The callback's answer to `Return`: run on from where it was, or
    /// from the top when the audio had already passed the target.
    fn seek_from_live(&mut self, live: Option<Box<Live>>) {
        let Some(seek) = &self.seek else {
            drop(live);
            return;
        };
        match live {
            None => self.cancel_seek(),
            Some(live) => {
                let from = Duration::from_secs_f64(live.samples as f64 / live.rate as f64);
                if from <= seek.target {
                    self.run_seek(live, from);
                } else {
                    drop(live);
                    self.seek_fresh();
                }
            }
        }
    }

    /// A new instance of the track, from the top.
    fn seek_fresh(&mut self) {
        let Some(track) = &self.track else {
            self.cancel_seek();
            return;
        };
        let built = self.build(
            &track.info.path,
            track.info.current_song,
            track.mono_2sid,
            track.rate,
            Some(track.power_on_delay),
        );
        match built {
            Ok(built) => {
                let live = Box::new(Live {
                    engine: built.engine,
                    id: track.id,
                    chips: built.started.chips,
                    samples: 0,
                    rate: track.rate,
                    cpu_hz: built.started.cpu_hz,
                });
                self.run_seek(live, Duration::ZERO);
            }
            Err(e) => {
                eprintln!("[residfp] seek: {e}");
                self.cancel_seek();
            }
        }
    }

    /// Skip on a worker thread; the result comes back as a `SeekDone`.
    fn run_seek(&mut self, mut live: Box<Live>, from: Duration) {
        let Some(seek) = &self.seek else {
            drop(live);
            return;
        };
        let (target, for_track) = (seek.target, seek.for_track);
        let tx = self.seek_done_tx.clone();
        let position = self.seek_position_ms.clone();
        self.seek_position_ms
            .store(from.as_millis() as u64, Ordering::Relaxed);
        let spawned = thread::Builder::new()
            .name("residfp-seek".into())
            .spawn(move || {
                live.skip_to(from, target, &position);
                let _ = tx.send(SeekDone {
                    live,
                    target,
                    for_track,
                });
            });
        if let Err(e) = spawned {
            eprintln!("[residfp] seek thread: {e}");
            self.cancel_seek();
        }
    }

    fn seek_done(&mut self, done: SeekDone) {
        // Not this seek's result (the track changed and a newer seek runs).
        if self.seek.as_ref().map(|s| s.for_track) != Some(done.for_track) {
            drop(done.live);
            return;
        }
        let seek = self.seek.take().expect("checked above");
        self.seeking.store(false, Ordering::Relaxed);
        eprintln!(
            "[residfp] seek to {:.1} s took {} ms",
            done.target.as_secs_f64(),
            seek.started.elapsed().as_millis()
        );
        let Some(track) = self
            .track
            .as_mut()
            .filter(|t| t.id == done.for_track && self.state != PlayState::Stopped)
        else {
            drop(done.live);
            return;
        };
        let mut live = done.live;
        // A new id, so reports from before the seek are ignored.
        let id = self.next_id;
        self.next_id += 1;
        live.id = id;
        track.id = id;
        track.elapsed = done.target;
        track.frame_index = 0;
        track.frame_start = done.target;
        track.frame_at = None;
        track.frame_took = Duration::ZERO;
        track.frame_scope.iter_mut().for_each(Vec::clear);
        let is_pal = track.is_pal;
        viz::lock(&self.viz).begin_track(is_pal);
        if self.to_audio.try_send(ToAudio::Swap(live)).is_err() {
            eprintln!("[residfp] seek: the audio output isn't taking commands");
        }
        if self.state == PlayState::Paused {
            let _ = self.to_audio.try_send(ToAudio::Pause(true));
        }
        self.send_status();
        if let Some(next) = seek.pending {
            self.seek(next);
        }
    }

    /// Forget a seek in flight; its result, if any, is dropped on arrival.
    fn cancel_seek(&mut self) {
        self.seek = None;
        self.seeking.store(false, Ordering::Relaxed);
    }

    /// Open the output device and start its callback.
    fn open_output(&mut self) -> Result<u32, String> {
        let (to_audio, inbox) = bounded(8);
        let (pool_tx, pool) = bounded(POOL);
        let source = Source {
            inbox,
            reports: self.reports_tx.clone(),
            pool,
            retired: self.retired_tx.clone(),
            returned: self.returned_tx.clone(),
            live: None,
            paused: false,
            scratch: vec![0; CHUNK * 2],
        };
        let sink = open_sink(&self.output, source)?;
        let rate = sink.rate;
        self.sink = Some(sink);
        self.to_audio = to_audio;
        self.pool_tx = pool_tx;
        Ok(rate)
    }

    fn stop_playback(&mut self) {
        let _ = self.to_audio.try_send(ToAudio::Drop);
        self.cancel_seek();
        self.state = PlayState::Stopped;
        if self.track.take().is_some() {
            viz::lock(&self.viz).stop();
        }
    }

    fn report(&mut self, mut report: Box<Report>) {
        if let Some(error) = report.error.take() {
            if self.track.as_ref().is_some_and(|t| t.id == report.id) {
                eprintln!("[residfp] playback stopped: {error}");
                self.stop_playback();
                self.last_error = Some(error);
                self.send_status();
            }
        } else if let Some(track) = self.track.as_mut().filter(|t| t.id == report.id) {
            track.elapsed = Duration::from_secs_f64(report.samples_end as f64 / track.rate as f64);
            self.pending_writes += report.writes as usize;
            for c in 0..track.chips.min(report.chips) {
                let raw = &report.state[c];
                track.regs[c * REGS_PER_CHIP..(c + 1) * REGS_PER_CHIP].copy_from_slice(&raw.regs);
                for v in 0..3 {
                    track.levels[c * 3 + v] = raw.env[v] as f32 / 255.0;
                    track.frame_scope[c * 3 + v].extend_from_slice(report.voice(c, v));
                }
                track.frame_chips[c] = chip_state(raw);
            }
            track.frame_at.get_or_insert(report.at);
            track.frame_took += report.took;
            // One visualizer frame per video frame, as the other engines
            // produce them, however long the device's buffers are.
            if track.elapsed.saturating_sub(track.frame_start) >= nominal_frame(track.is_pal) {
                let frame = Frame::rendered(
                    track.frame_index,
                    track.is_pal,
                    track.chips,
                    track.frame_chips,
                    track.frame_start,
                    track.elapsed,
                );
                let mut refs: [&[f32]; MAX_CHIPS * 3] = [&[]; MAX_CHIPS * 3];
                for (slot, voice) in refs.iter_mut().zip(&track.frame_scope) {
                    *slot = voice;
                }
                viz::lock(&self.viz).push_rendered(
                    frame,
                    &refs[..track.chips * 3],
                    track.frame_at.unwrap_or(report.at),
                    track.frame_took,
                );
                track.frame_index += 1;
                track.frame_start = track.elapsed;
                track.frame_at = None;
                track.frame_took = Duration::ZERO;
                track.frame_scope.iter_mut().for_each(Vec::clear);
            }
            if self.state == PlayState::Playing && self.last_status.elapsed() >= STATUS_PERIOD {
                self.send_status();
            }
        }
        // Back to the callback for reuse.
        report.scope_len = [0; MAX_CHIPS];
        let _ = self.pool_tx.try_send(report);
    }

    fn send_status(&mut self) {
        let mut status = PlayerStatus {
            state: self.state.clone(),
            error: self.last_error.clone(),
            ..PlayerStatus::default()
        };
        if let Some(track) = &self.track {
            status.track_info = Some(track.info.clone());
            status.elapsed = track.elapsed;
            status.voice_levels = track.levels.clone();
            status.writes_per_frame = self.pending_writes;
            status.sid_regs = track.regs.clone();
        }
        self.pending_writes = 0;
        self.last_status = Instant::now();
        let _ = self.status_tx.try_send(status);
    }
}

/// One video frame of emulated time.
fn nominal_frame(is_pal: bool) -> Duration {
    let cycles = if is_pal { 19_656.0 } else { 17_095.0 };
    Duration::from_secs_f64(cycles / viz::clock_hz(is_pal))
}

/// The feed's chip state from the chip's own report: registers as written,
/// OSC3 and ENV3 from the chip.
fn chip_state(raw: &RawChip) -> ChipState {
    let mut regs = [0u8; FRAME_REGS];
    regs.copy_from_slice(&raw.regs[..FRAME_REGS]);
    regs[0x1B] = raw.osc3;
    regs[0x1C] = raw.env3;
    ChipState {
        regs,
        env: raw.env,
        env_state: std::array::from_fn(|v| match raw.phase(v) {
            EnvPhase::Attack => EnvState::Attack,
            EnvPhase::DecaySustain => EnvState::DecaySustain,
            EnvPhase::Release => EnvState::Release,
        }),
    }
}

/// C64 ROM images, if the user has put them where Phosphor's libsidplayfp
/// path looks (plus Resonance's own `ROMs` folder). Without them
/// libsidplayfp's built-in stubs play PSIDs and nearly every RSID.
fn find_roms() -> Roms {
    let mut dirs: Vec<PathBuf> = Vec::new();
    if let Some(data) = crate::config::config_dir() {
        dirs.push(data.join("ROMs"));
    }
    if let Ok(dir) = std::env::var("C64_ROM_DIR") {
        dirs.push(PathBuf::from(dir));
    }
    if let Ok(home) = std::env::var("HOME") {
        dirs.push(PathBuf::from(home).join(".local/share/c64/roms"));
    }
    dirs.push(PathBuf::from("/usr/share/vice/C64"));
    let find = |names: &[&str], len: usize| {
        dirs.iter()
            .flat_map(|dir| names.iter().map(move |n| dir.join(n)))
            .find_map(|p| std::fs::read(p).ok().filter(|d| d.len() == len))
    };
    let roms = Roms {
        kernal: find(&["kernal", "kernal.rom", "kernal.bin"], 8192),
        basic: find(&["basic", "basic.rom", "basic.bin"], 8192),
        chargen: find(&["chargen", "chargen.rom", "chargen.bin"], 4096),
    };
    if roms.kernal.is_some() {
        eprintln!("[residfp] C64 ROM images found");
    }
    roms
}
