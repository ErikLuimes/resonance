# Implementation notes

## Shared data model (sketch)

```swift
struct VoiceFrame {
    var freqReg: UInt16         // raw $D400/01 etc.
    var hz: Double              // freqReg * clock / 16_777_216  (PAL 985_248, NTSC 1_022_727)
    var midi: Double            // 69 + 12 * log2(hz / 440)
    var gate: Bool
    var waveform: UInt8         // CTRL high nibble: NOI PUL SAW TRI
    var test, ring, sync: Bool
    var pulseWidth: UInt16      // 12-bit
    var attack, decay, sustain, release: UInt8
    var envLevel: Float         // 0…1 from the emulator's envelope counter
}

struct SIDFrame {
    var index: UInt64           // frame counter
    var registers: [UInt8]      // 29 bytes, $D400–$D41C (use a fixed-size tuple/InlineArray to avoid allocation)
    var voices: (VoiceFrame, VoiceFrame, VoiceFrame)
    var cutoff: UInt16          // 11-bit
    var resonance: UInt8
    var filterRouting: UInt8    // bits V1 V2 V3 EXT
    var filterMode: UInt8       // LP BP HP 3OFF
    var volume: UInt8
}
```

- **Audio thread** writes `SIDFrame` into a lock-free single-producer ring (history ~512 frames) and per-voice samples into three sample rings (~2048 each).
- **UI** reads the newest frame and copies the history and sample windows it needs once per display frame (`TimelineView(.animation)` or a `CADisplayLink`/`MTKView` draw callback).
- Per-voice samples are needed for the scope and FFT. If the emulator only mixes, add a tap per voice before the mixer. Many emulators (reSID / reSIDfp) can expose voice outputs.

## Rendering choices

| Concept | Suggested tech |
|---|---|
| Oscilloscope, Lanes, Envelope, Pitch trail, Sweeps, Overview strip, Fingerprints | SwiftUI `Canvas` + `TimelineView`, which is plenty fast for a few hundred points |
| Registers, Tracker | Plain SwiftUI views with monospaced text; drive change-flash from frame diffs |
| Radial spectrum | `Canvas` is fine; Metal if you want glow |
| Halo | Metal fragment shader (signed-distance rings + additive glow) |
| Particle sphere | Metal compute (displace points) + instanced point sprites, additive blending |
| Spectrogram | Metal: write one FFT column per frame into a ring texture and sample with an offset (no copying) |

**FFT:** `vDSP.FFT` / `vDSP_DFT_zrop` on each voice's sample window (1024–2048, Hann window), log-frequency mapping for display, and attack/release smoothing (fast rise, slow fall) for calm bars.

## Behavior details worth keeping from the mockups

- Gate-off and rests fade gently. Use envelope level, not gate alone, so nothing snaps to zero.
- Bars and levels rise fast and fall slowly.
- Particle ripples start from a different point on the sphere per voice, so bass, lead and drums read as separate waves.
- Register cells flash for about 6 frames after a change.
- Halo blob shape comes from the waveform's harmonic content: saw uses all harmonics at 1/k, pulse uses odd harmonics weighted by |sin(πk·pw)|/k, and noise is random.

## Visual tokens

| Token | Value |
|---|---|
| Voice 1 | `#5AC8E8` |
| Voice 2 | `#A27CF6` |
| Voice 3 | `#F2A154` |
| Visualizer card background | `#0E0E10` |
| Panel background | `#0B0B0C` / `#111113` |
| Dim text | `#8D8E96` |
| Gate-off / empty | `#33333A` |
| Mono font | SF Mono (the mockups use JetBrains Mono as a stand-in) |
| UI font | SF Pro |
| Accent | `#2F7CF6` (matches the sidebar selection) |

Make voice colors a setting from the start. Some people will want the classic C64 palette.

## Sound Map timings (measured)

Measured from the user's reference recording (7.7 s, 57 fps) with OpenCV: optical flow between frames 0.1 s apart, and the brightness of the brightest spots tracked over time.

| What | Measured | Used |
|---|---|---|
| Camera framing | The cloud's center stays at 0.48–0.69 × width, 0.50–0.60 × height; its spread stays at 0.20–0.33 of the frame, even while the camera dollies | Orbit the center of all nodes, at 1.9 × the radius that holds 85% of them (measured spread 0.17 at 2.7×, so moved in; both eased over 2 s). On top, it zooms out while more than 2% of the nodes are off screen, and back in slowly once 98% sit within 70% of the way to the edge (the user asked for this) |
| Orbit speed | 0.63–0.70 rad/s while notes arrive, slowing to 0.33 rad/s after about 3.5 s without new ones | 0.3 rad/s plus up to 0.38 with activity (about 6 notes/s is busy), which calms with a 3 s time constant |
| Fresh node | Holds full brightness for about 1 s | White and fully lit for 1 s |
| Fade | Lit pixels halve about every 0.65 s once no new notes arrive; tracked spots fall from 255 to about 40% in 2.5–3 s | Exponential, 1 s time constant, shifted to reach zero at 4 s: labels, links and paths are gone by then (the user asked for 4 s), leaving a faint dot |
| Glow | A soft halo on fresh nodes only; never saturates into blobs | Bloom 0.35, a soft shoulder rather than a hard clip, and max blending for squares and labels so repeated notes don't stack |
