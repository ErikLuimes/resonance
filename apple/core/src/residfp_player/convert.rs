//! A playing engine's sample rate, converted to another output's.
//!
//! Moving a tune to a listening device (48 kHz, Opus's rate) from speakers
//! at 44.1 kHz, or back, used to build a fresh engine at the new rate and
//! run it from the top to the same place: 16 ms per second of tune on
//! reSIDfp (design/scrubbing/README.md), so 2 s of silence two minutes in.
//! Converting keeps the engine playing, and the switch takes one output
//! buffer. The next tune starts at the output's own rate, without this.
//!
//! Windowed sinc: 32 taps (Kaiser, beta 8), a table of 256 phases with
//! linear interpolation between them, the cutoff at 95% of the lower
//! Nyquist frequency. It delays the sound by 15 input frames (0.3 ms).

use residfp_sys::Player as Engine;

const TAPS: usize = 32;
const HALF: usize = TAPS / 2;
const PHASES: usize = 256;
const BETA: f64 = 8.0;
const CUTOFF: f64 = 0.95;
/// Engine frames rendered at a time.
const PULL: usize = 512;
/// Consumed input is dropped once this much has piled up.
const KEEP: usize = 4096;

pub(super) struct Converter {
    /// Input frames per output frame.
    step: f64,
    /// Where the next output frame falls in `buf`, in input frames.
    pos: f64,
    /// Interleaved stereo input, as the engine's samples.
    buf: Vec<f32>,
    /// `PHASES + 1` rows of `TAPS`: row p is the kernel for a position p /
    /// PHASES of the way from one input frame to the next.
    table: Vec<f32>,
    pull: Vec<i16>,
}

impl Converter {
    /// Built off the audio thread: it allocates.
    pub(super) fn new(from: u32, to: u32) -> Self {
        let step = from as f64 / to as f64;
        // Relative to the input's Nyquist frequency.
        let cutoff = CUTOFF * (1.0 / step).min(1.0);
        let mut table = vec![0f32; (PHASES + 1) * TAPS];
        for p in 0..=PHASES {
            let frac = p as f64 / PHASES as f64;
            let row = &mut table[p * TAPS..(p + 1) * TAPS];
            let mut sum = 0.0;
            let mut taps = [0f64; TAPS];
            for (j, tap) in taps.iter_mut().enumerate() {
                // Distance from the output position to input frame j.
                let x = frac + (HALF - 1) as f64 - j as f64;
                *tap = cutoff * sinc(cutoff * x) * kaiser(x / HALF as f64);
                sum += *tap;
            }
            // Unity gain at DC in every phase.
            for (out, tap) in row.iter_mut().zip(taps) {
                *out = (tap / sum) as f32;
            }
        }
        let mut buf = Vec::with_capacity((KEEP + PULL + TAPS) * 2 * 2);
        // Silence before the first frame, so the first output has its taps.
        buf.resize((HALF - 1) * 2, 0.0);
        Converter {
            step,
            pos: (HALF - 1) as f64,
            buf,
            table,
            pull: vec![0; PULL * 2],
        }
    }

    /// Fills `out` (interleaved stereo) at the output's rate. Returns the
    /// output frames written and the engine frames rendered. Fewer frames
    /// than asked means the engine stopped (its error says why).
    pub(super) fn render(&mut self, engine: &mut Engine, out: &mut [i16]) -> (usize, usize) {
        let frames = out.len() / 2;
        let mut rendered = 0;
        for i in 0..frames {
            let base = self.pos as usize;
            // The last tap reads input frame base + HALF.
            while self.buf.len() / 2 <= base + HALF {
                let got = engine.render(&mut self.pull);
                rendered += got;
                self.buf.extend(self.pull[..got * 2].iter().map(|&s| s as f32));
                if got < PULL {
                    if self.buf.len() / 2 <= base + HALF {
                        return (i, rendered);
                    }
                    break;
                }
            }
            let at = (self.pos - base as f64) * PHASES as f64;
            let p = (at as usize).min(PHASES - 1);
            let t = (at - p as f64) as f32;
            let (a, b) = (&self.table[p * TAPS..(p + 1) * TAPS], &self.table[(p + 1) * TAPS..(p + 2) * TAPS]);
            let input = &self.buf[(base + 1 - HALF) * 2..(base + 1 + HALF) * 2];
            let (mut l, mut r) = (0f32, 0f32);
            for j in 0..TAPS {
                let k = a[j] + (b[j] - a[j]) * t;
                l += input[j * 2] * k;
                r += input[j * 2 + 1] * k;
            }
            out[i * 2] = l.round().clamp(-32768.0, 32767.0) as i16;
            out[i * 2 + 1] = r.round().clamp(-32768.0, 32767.0) as i16;
            self.pos += self.step;
        }
        // Input before the first tap of the next output isn't needed again.
        let first = (self.pos as usize + 1).saturating_sub(HALF);
        if first >= KEEP {
            self.buf.drain(..first * 2);
            self.pos -= first as f64;
        }
        (frames, rendered)
    }
}

fn sinc(x: f64) -> f64 {
    if x.abs() < 1e-12 {
        1.0
    } else {
        let px = std::f64::consts::PI * x;
        px.sin() / px
    }
}

fn kaiser(x: f64) -> f64 {
    if x.abs() >= 1.0 {
        return 0.0;
    }
    bessel_i0(BETA * (1.0 - x * x).sqrt()) / bessel_i0(BETA)
}

/// The modified Bessel function of the first kind, order 0, by its series.
fn bessel_i0(x: f64) -> f64 {
    let (mut sum, mut term, mut k) = (1.0, 1.0, 1.0);
    let half = x / 2.0;
    while term > sum * 1e-12 {
        term *= (half / k) * (half / k);
        sum += term;
        k += 1.0;
    }
    sum
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The kernel alone, on a plain signal: a sine at 1 kHz comes out a
    /// sine at 1 kHz, at the same level, with the delay the table has.
    fn convert(input: &[f32], from: u32, to: u32) -> Vec<f32> {
        let mut c = Converter::new(from, to);
        c.buf.extend(input.iter().flat_map(|&s| [s, s]));
        let mut out = Vec::new();
        while (c.pos as usize) + HALF < c.buf.len() / 2 {
            let base = c.pos as usize;
            let at = (c.pos - base as f64) * PHASES as f64;
            let p = (at as usize).min(PHASES - 1);
            let t = (at - p as f64) as f32;
            let mut l = 0f32;
            for j in 0..TAPS {
                let k = c.table[p * TAPS + j] + (c.table[(p + 1) * TAPS + j] - c.table[p * TAPS + j]) * t;
                l += c.buf[(base + 1 - HALF + j) * 2] * k;
            }
            out.push(l);
            c.pos += c.step;
        }
        out
    }

    fn worst_error(from: u32, to: u32) -> f32 {
        let hz = 1000.0;
        let input: Vec<f32> = (0..from as usize / 10)
            .map(|n| (2.0 * std::f64::consts::PI * hz * n as f64 / from as f64).sin() as f32)
            .collect();
        let out = convert(&input, from, to);
        // Output frame m sits at input position m × step, after the
        // HALF − 1 frames of silence in front.
        out.iter()
            .enumerate()
            .skip(TAPS)
            .take(out.len() - 2 * TAPS)
            .map(|(m, &y)| {
                let at = m as f64 * from as f64 / to as f64;
                let want = (2.0 * std::f64::consts::PI * hz * at / from as f64).sin() as f32;
                (y - want).abs()
            })
            .fold(0f32, f32::max)
    }

    #[test]
    fn a_sine_survives_44_1_to_48_khz() {
        let e = worst_error(44_100, 48_000);
        assert!(e < 1e-3, "worst error {e}");
    }

    #[test]
    fn a_sine_survives_48_to_44_1_khz() {
        let e = worst_error(48_000, 44_100);
        assert!(e < 1e-3, "worst error {e}");
    }
}
