import SwiftUI
import PhosphorCore

/// Chip: the SID itself with its lid off, seen from above as under a
/// microscope, working. The die sits in the package's gold cavity, wired
/// to its 28 pins, and what lights up on it is the chip's real state, bit
/// for bit: each voice's frequency, waveform, pulse width and envelope,
/// the filter's routing, modes, cutoff and resonance, the volume, and
/// all 29 registers as the tune's player writes them. Each voice's signal
/// runs from its converter into the filter or past it to the output, and
/// the pins glow as they're used: the data bus on every write, the
/// filter's capacitors while it's in use, the audio pin with the sound.
///
/// `ChipDie` draws the still picture once; `ChipDrawing` lights it every
/// frame. Shows the first chip, like the Halo.
struct ChipView: View {
    /// False pauses it, e.g. while Now Playing is slid away.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme
    @State private var chip = ChipModel()

    var body: some View {
        TimelineView(.animation(minimumInterval: VisualizerFeed.frameInterval, paused: !isActive)) { context in
            let _ = chip.update(feed: store.visualizer, at: context.date)
            let drawing = ChipDrawing(state: chip.state, colors: (0..<3).map(theme.voice), art: chip.art)
            Canvas { gc, size in
                drawing.draw(in: &gc, size: size)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Chip visualizer")
    }
}

/// The chip's state from frame to frame, read from the feed, and the Chip
/// visualizer's picture (made when first asked for: Silicon doesn't use it).
final class ChipModel {
    private(set) var state = ChipState()
    private(set) lazy var art = ChipDie.art()
    private var last: Date?

    func update(feed: VisualizerFeed, at date: Date) {
        let dt = min(max(last.map { date.timeIntervalSince($0) } ?? 0, 0), 0.1)
        last = date
        state.time = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
        guard let chip = feed.latest()?.chips.first else {
            // Stopped: what was lit fades with the last writes.
            state.write(state.registers, dt: dt)
            for v in 0..<3 {
                state.voices[v].level = 0
                state.voices[v].samples = []
            }
            return
        }
        let scope = feed.scope(chip: 0, count: 1024)
        for (v, voice) in chip.voices.prefix(3).enumerated() {
            state.voices[v] = ChipState.Voice(
                frequency: voice.freqReg, pulseWidth: voice.pulseWidth, waveform: voice.waveform, gate: voice.gate,
                ring: voice.ring, sync: voice.sync, attack: voice.attack, decay: voice.decay, sustain: voice.sustain,
                release: voice.release, level: voice.envLevel, filtered: chip.filterRouting >> v & 1 == 1,
                samples: v < scope.voices.count ? scope.voices[v] : [])
        }
        state.write([UInt8](chip.registers), dt: dt)
        state.cutoff = chip.cutoff
        state.resonance = chip.resonance
        state.lowPass = chip.filterMode & 0x1 != 0
        state.bandPass = chip.filterMode & 0x2 != 0
        state.highPass = chip.filterMode & 0x4 != 0
        state.voice3Off = chip.filterMode & 0x8 != 0
        state.volume = chip.volume
    }
}

#Preview {
    ChipView()
        .environment(PlayerStore.preview)
        .frame(width: 640, height: 400)
        .background(.black)
}
