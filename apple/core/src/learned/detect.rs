//! Works out how long a subtune lasts by running it, for tunes HVSC's
//! Songlengths database doesn't list. Method and measurements:
//! design/songlengths/README.md; change it only against
//! `core/examples/songlength_bench.rs`.

use std::collections::HashMap;

use residfp_sys::{Config, Player, Write as SidWrite};

/// How much of a tune to run. A loop takes 3 copies to confirm, so this finds
/// loops of up to 5 minutes.
const CAP_SECS: f64 = 900.0;
/// Quiet this long means the tune is over.
const SILENCE_SECS: f64 = 10.0;
/// Quiet from the very start is a tune that hasn't begun, not one that ended.
const MIN_ELAPSED_SECS: f64 = 1.0;
/// Still no writes after this long, with no answer: give up on the tune.
const GIVE_UP_SECS: f64 = 35.0;
/// A repeat shorter than this is a held note or a drum pattern.
const MIN_PERIOD_SECS: f32 = 8.0;
/// How often to look for a loop.
const CHECK_EVERY_SECS: f64 = 30.0;
/// Copies of the tune to see before calling it a loop: 2 would take a verse
/// played twice for the whole song.
const COPIES: usize = 3;
/// Writes that must match for a repeat to be looked at.
const WRITES_WINDOW: usize = 512;
/// Note-ons that must match. Repeating notes also catch the many tunes whose
/// filter or pulse sweeps never come round to the same writes.
const NOTES_WINDOW: usize = 24;
/// More writes than this is a digi tune, which only the notes can say
/// anything about: the search over them would take too much memory.
const MAX_WRITES: usize = 3_000_000;

const FRAMES_PER_SEC: f64 = 50.0;
/// Rendered, not skipped: `rsfp_skip` forgets the writes it logged. The rate
/// only has to show whether there is sound.
const RATE: u32 = 8_000;
/// Peak to peak, in a frame of 16-bit audio: about -70 dB.
const FLAT: i32 = 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LengthMethod {
    /// The tune went quiet.
    Silence,
    /// The tune started over.
    Loop,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LengthEstimate {
    pub secs: f64,
    pub method: LengthMethod,
}

/// A stream to search for repeats, with when each element happened.
#[derive(Default)]
struct Stream {
    tokens: Vec<u32>,
    at: Vec<f32>,
}

impl Stream {
    fn push(&mut self, token: u32, at: f32) {
        self.tokens.push(token);
        self.at.push(at);
    }
}

/// How long `song` (1-based) of a tune lasts; `None` when running it didn't
/// tell, or `cancelled` said to stop.
pub fn estimate_length(
    data: &[u8],
    song: u16,
    cancelled: &dyn Fn() -> bool,
) -> Result<Option<LengthEstimate>, String> {
    let mut player = Player::new()?;
    player.load_bytes(data)?;
    let config = Config { sample_rate: RATE, power_on_delay: Some(0x800), ..Config::default() };
    let started = player.start(song, &config)?;
    let chips = player.chips();

    let mut audio = vec![0i16; (f64::from(RATE) / FRAMES_PER_SEC) as usize * 2];
    let mut log = vec![SidWrite { cycle: 0, reg: 0, val: 0 }; 4096];
    let mut batch: Vec<(u8, SidWrite)> = Vec::new();
    let mut regs = vec![[0u8; 32]; chips];
    let mut gates = vec![[false; 3]; chips];
    let (mut writes, mut notes) = (Stream::default(), Stream::default());
    let mut quiet = QuietRuns::default();
    let check_every = (CHECK_EVERY_SECS * FRAMES_PER_SEC) as usize;

    for frame in 0..(CAP_SECS * FRAMES_PER_SEC) as usize {
        if frame % 50 == 0 && cancelled() {
            return Ok(None);
        }
        if player.render(&mut audio) < audio.len() / 2 {
            break;
        }
        let (low, high) = audio.iter().fold((i32::MAX, i32::MIN), |(low, high), &v| {
            (low.min(i32::from(v)), high.max(i32::from(v)))
        });

        batch.clear();
        for chip in 0..chips {
            let (copied, _) = player.take_writes(chip, &mut log);
            batch.extend(log[..copied].iter().map(|w| (chip as u8, *w)));
        }
        batch.sort_by_key(|(_, w)| w.cycle);

        let mut audible = false;
        for (chip, w) in &batch {
            let (chip, reg) = (*chip as usize, (w.reg & 0x1f) as usize);
            // A changing volume is a digi: audible whatever the envelopes do.
            if reg == 24 && regs[chip][reg] & 15 != w.val & 15 {
                audible = true;
            }
            regs[chip][reg] = w.val;
            let at = (f64::from(w.cycle) / started.cpu_hz) as f32;
            if writes.tokens.len() < MAX_WRITES {
                writes.push((chip as u32) << 16 | (reg as u32) << 8 | u32::from(w.val), at);
            }
            if reg < 21 && reg % 7 == 4 {
                let voice = reg / 7;
                let on = w.val & 1 != 0;
                if on && !gates[chip][voice] {
                    let token = (chip as u32) << 20
                        | (voice as u32) << 16
                        | u32::from(w.val & 0xf0) << 8
                        | u32::from(regs[chip][voice * 7 + 1]);
                    notes.push(token, at);
                }
                gates[chip][voice] = on;
            }
        }
        for chip in 0..chips {
            if let Some(state) = player.chip_state(chip) {
                if state.regs[24] & 15 != 0 && state.env.iter().any(|&e| e > 0) {
                    audible = true;
                }
            }
        }

        let silence = quiet.step(!batch.is_empty(), audible, high - low < FLAT);
        let check = frame % check_every == check_every - 1;
        if silence.is_some() || check {
            if let Some(estimate) = earliest(silence, &writes, &notes) {
                return Ok(Some(estimate));
            }
        }
        if quiet.no_writes.len as f64 >= GIVE_UP_SECS * FRAMES_PER_SEC {
            return Ok(None);
        }
    }
    Ok(earliest(None, &writes, &notes))
}

/// The earliest answer so far: the tune ends at whichever came first.
fn earliest(silence: Option<f64>, writes: &Stream, notes: &Stream) -> Option<LengthEstimate> {
    let search = |stream: &Stream, window| {
        (stream.tokens.len() < MAX_WRITES)
            .then(|| find_loop(&stream.tokens, &stream.at, window, COPIES))
            .flatten()
    };
    let looped = [search(writes, WRITES_WINDOW), search(notes, NOTES_WINDOW)]
        .into_iter()
        .flatten()
        .min_by(f64::total_cmp);
    match (silence, looped) {
        (Some(s), Some(l)) if l < s => Some(LengthEstimate { secs: l, method: LengthMethod::Loop }),
        (Some(s), _) => Some(LengthEstimate { secs: s, method: LengthMethod::Silence }),
        (None, Some(l)) => Some(LengthEstimate { secs: l, method: LengthMethod::Loop }),
        (None, None) => None,
    }
}

/// The three ways a tune can go quiet. Each misses tunes the others catch:
/// a tune can stop writing on a held note, keep writing to closed envelopes,
/// or leave only a hum the envelopes don't explain.
#[derive(Default)]
struct QuietRuns {
    frame: usize,
    no_writes: Run,
    closed: Run,
    flat: Run,
}

#[derive(Default)]
struct Run {
    len: usize,
}

impl Run {
    /// Where this run started, once it's long enough and began after the
    /// tune did.
    fn step(&mut self, quiet: bool, frame: usize) -> Option<f64> {
        self.len = if quiet { self.len + 1 } else { 0 };
        let start = frame + 1 - self.len;
        (self.len as f64 >= SILENCE_SECS * FRAMES_PER_SEC
            && start as f64 >= MIN_ELAPSED_SECS * FRAMES_PER_SEC)
            .then(|| start as f64 / FRAMES_PER_SEC)
    }
}

impl QuietRuns {
    fn step(&mut self, wrote: bool, audible: bool, flat: bool) -> Option<f64> {
        let frame = self.frame;
        self.frame += 1;
        [
            self.no_writes.step(!wrote, frame),
            self.closed.step(!audible, frame),
            self.flat.step(flat, frame),
        ]
        .into_iter()
        .flatten()
        .min_by(f64::total_cmp)
    }
}

/// The first point from which the stream repeats what came before it, for
/// `copies` whole copies counting the one before. With 3, a verse played
/// twice and followed by something else doesn't pass.
fn find_loop(tokens: &[u32], at: &[f32], window: usize, copies: usize) -> Option<f64> {
    let n = tokens.len();
    if n <= window {
        return None;
    }
    const BASE: u64 = 0x100_0000_01B3;
    let top = (0..window - 1).fold(1u64, |h, _| h.wrapping_mul(BASE));
    let mut hash = tokens[..window]
        .iter()
        .fold(0u64, |h, &t| h.wrapping_mul(BASE).wrapping_add(u64::from(t) + 1));
    let mut seen: HashMap<u64, u32> = HashMap::with_capacity(n);
    let mut skip_until = 0;
    for i in 0..=n - window {
        if i >= skip_until {
            if let Some(&earlier) = seen.get(&hash) {
                let earlier = earlier as usize;
                let period = i - earlier;
                if at[i] - at[earlier] >= MIN_PERIOD_SECS {
                    let need = (copies - 1) * period;
                    let mismatch =
                        (0..need.min(n - i)).find(|&k| tokens[i + k] != tokens[i + k - period]);
                    match mismatch {
                        // Past the mismatch: everything up to it would fail the same way.
                        Some(k) => skip_until = i + k + 1,
                        // Not all the copies have played yet.
                        None if i + need > n => return None,
                        None => return Some(f64::from(at[i])),
                    }
                }
            }
        }
        seen.entry(hash).or_insert(i as u32);
        if i + window < n {
            hash = hash
                .wrapping_sub((u64::from(tokens[i]) + 1).wrapping_mul(top))
                .wrapping_mul(BASE)
                .wrapping_add(u64::from(tokens[i + window]) + 1);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A stream of `tokens` one per 100 ms.
    fn timed(tokens: &[u32]) -> Vec<f32> {
        (0..tokens.len()).map(|i| i as f32 * 0.1).collect()
    }

    /// `len` tokens no other section shares.
    fn section(seed: u32, len: u32) -> Vec<u32> {
        (0..len).map(|i| seed * 1000 + i).collect()
    }

    #[test]
    fn a_loop_is_found_where_it_starts_over() {
        let intro = section(1, 30);
        let body = section(2, 200);
        let tokens = [intro.clone(), body.clone(), body.clone(), body.clone()].concat();
        let found = find_loop(&tokens, &timed(&tokens), 24, 3).unwrap();
        assert!((found - 23.0).abs() < 0.01, "after the intro and one copy: {found}");
    }

    #[test]
    fn a_verse_played_twice_is_not_the_end_of_the_song() {
        let (verse, chorus) = (section(1, 100), section(2, 100));
        let tune = [verse.clone(), verse.clone(), chorus.clone()].concat();
        let tokens = [tune.clone(), tune.clone(), tune.clone()].concat();
        let found = find_loop(&tokens, &timed(&tokens), 24, 3).unwrap();
        assert!((found - 30.0).abs() < 0.01, "after the whole song: {found}");
    }

    #[test]
    fn too_few_copies_is_no_answer_yet() {
        let body = section(1, 200);
        let tokens = [body.clone(), body.clone()].concat();
        assert_eq!(find_loop(&tokens, &timed(&tokens), 24, 3), None);
    }

    #[test]
    fn a_short_repeat_is_not_a_loop() {
        // A 5 s bar, played three times and then on to something else.
        let bar = section(1, 50);
        let tokens = [bar.clone(), bar.clone(), bar, section(2, 500)].concat();
        assert_eq!(find_loop(&tokens, &timed(&tokens), 24, 3), None);
    }

    #[test]
    fn music_that_never_repeats_has_no_loop() {
        let tokens = section(1, 2000);
        assert_eq!(find_loop(&tokens, &timed(&tokens), 24, 3), None);
    }

    #[test]
    fn silence_reports_where_it_began() {
        let mut quiet = QuietRuns::default();
        for _ in 0..100 {
            assert_eq!(quiet.step(true, true, false), None);
        }
        let answers: Vec<_> = (0..500).filter_map(|_| quiet.step(false, false, true)).collect();
        assert_eq!(answers, vec![2.0]);
    }

    #[test]
    fn quiet_from_the_start_is_not_an_ending() {
        let mut quiet = QuietRuns::default();
        assert!((0..2000).all(|_| quiet.step(false, false, true).is_none()));
    }

    #[test]
    fn a_pause_shorter_than_the_silence_is_not_an_ending() {
        let mut quiet = QuietRuns::default();
        for _ in 0..3 {
            for _ in 0..100 {
                assert_eq!(quiet.step(true, true, false), None);
            }
            for _ in 0..200 {
                assert_eq!(quiet.step(false, false, true), None);
            }
        }
    }

    #[test]
    fn any_one_kind_of_quiet_is_enough() {
        // Writes keep coming and the audio hums, with every envelope closed.
        let mut closed = QuietRuns::default();
        for _ in 0..100 {
            closed.step(true, true, false);
        }
        assert!((0..500).any(|_| closed.step(true, false, false).is_some()));
        // A note held for good: no writes, but it sounds.
        let mut held = QuietRuns::default();
        for _ in 0..100 {
            held.step(true, true, false);
        }
        assert!((0..500).any(|_| held.step(false, true, false).is_some()));
    }

    #[test]
    fn a_real_tune_runs_through_the_engine() {
        // The test tune's play routine counts through a byte: it repeats
        // every 256 frames, and only that exactly, so it's a loop.
        let tune = residfp_sys::testing::tiny_psid(1);
        let estimate = estimate_length(&tune, 1, &|| false).unwrap().unwrap();
        assert_eq!(estimate.method, LengthMethod::Loop);
        assert!(estimate.secs > 8.0 && estimate.secs < 30.0, "{estimate:?}");
    }

    #[test]
    fn cancelling_stops_the_run() {
        let tune = residfp_sys::testing::tiny_psid(1);
        assert_eq!(estimate_length(&tune, 1, &|| true).unwrap(), None);
    }

    #[test]
    fn something_that_is_no_tune_is_an_error() {
        assert!(estimate_length(b"not a tune", 1, &|| false).is_err());
    }
}
