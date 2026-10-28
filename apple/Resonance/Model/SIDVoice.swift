import Foundation

/// What one SID voice is doing, decoded from the register shadow.
nonisolated struct SIDVoice: Equatable, Sendable {
    /// e.g. "C#4"; nil when the gate is off or the frequency is zero.
    let note: String?
    /// Waveform abbreviations from the control register, e.g. "TRI", "PUL+SAW".
    let waveform: String
    let gate: Bool

    /// Voices for every chip in `regs` (32 registers per SID, 3 voices each,
    /// voice n's registers at n × 7).
    static func decode(regs: [UInt8], chips: Int, pal: Bool) -> [SIDVoice] {
        let clock = pal ? 985_248.0 : 1_022_727.0
        return (0..<max(chips, 1) * 3).map { voice in
            let base = (voice / 3) * 32 + (voice % 3) * 7
            guard base + 4 < regs.count else {
                return SIDVoice(note: nil, waveform: "", gate: false)
            }
            let freq = Int(regs[base]) | Int(regs[base + 1]) << 8
            let control = regs[base + 4]
            let gate = control & 0x01 != 0
            return SIDVoice(
                note: gate ? noteName(frequencyRegister: freq, clock: clock) : nil,
                waveform: waveformName(control: control),
                gate: gate
            )
        }
    }

    private static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// Nearest equal-tempered note for a 16-bit SID frequency register value.
    static func noteName(frequencyRegister freq: Int, clock: Double) -> String? {
        guard freq > 0 else { return nil }
        let hz = Double(freq) * clock / 16_777_216
        let midi = Int((12 * log2(hz / 440) + 69).rounded())
        guard (0...127).contains(midi) else { return nil }
        return "\(names[midi % 12])\(midi / 12 - 1)"
    }

    static func waveformName(control: UInt8) -> String {
        var parts: [String] = []
        if control & 0x10 != 0 { parts.append("TRI") }
        if control & 0x20 != 0 { parts.append("SAW") }
        if control & 0x40 != 0 { parts.append("PUL") }
        if control & 0x80 != 0 { parts.append("NOI") }
        return parts.joined(separator: "+")
    }
}

/// Bar levels with fast attack, slow release and a peak-hold marker — the
/// Iced visualizer's smoothing (src/ui/visualizer.rs `update`), made
/// frame-rate independent: its per-frame factors were tuned at ~30 fps.
nonisolated final class VoiceMeter {
    private(set) var levels: [Double] = []
    private(set) var peaks: [Double] = []
    private var lastUpdate: Date?
    private var lastSeq: UInt64?

    private static let decayPerFrame = 0.92
    private static let peakDecayPerFrame = 0.985
    private static let referenceFPS = 30.0

    func update(levels input: [Float], seq: UInt64, at date: Date) {
        let dt = lastUpdate.map { min(date.timeIntervalSince($0), 0.25) } ?? 0
        lastUpdate = date
        let frames = dt * Self.referenceFPS
        let decay = pow(Self.decayPerFrame, frames)
        let peakDecay = pow(Self.peakDecayPerFrame, frames)

        if levels.count != input.count {
            levels = Array(repeating: 0, count: input.count)
            peaks = levels
        }
        // Only take new values from new player frames; otherwise just decay.
        let fresh = seq != lastSeq
        lastSeq = seq
        for i in input.indices {
            let new = fresh ? Double(min(max(input[i], 0), 1)) : 0
            levels[i] = new > levels[i] ? new : levels[i] * decay
            peaks[i] = levels[i] > peaks[i] ? levels[i] : peaks[i] * peakDecay
        }
    }

    func reset() {
        levels = levels.map { _ in 0 }
        peaks = levels
        lastUpdate = nil
    }
}
