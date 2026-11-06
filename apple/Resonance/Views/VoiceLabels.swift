import SwiftUI
import PhosphorCore

/// The note and waveform under each voice, drawn the same way by every
/// visualizer that labels its voices.
enum VoiceLabels {
    /// Room to leave under a voice's drawing.
    static let height: CGFloat = 38

    /// Draw `voice`'s labels centred on `x`, below `top`. A released note
    /// still sounds, so its name stays, dimmed; nil draws placeholders.
    static func draw(_ voice: VizVoice?, color: Color, centeredAt x: CGFloat, top: CGFloat, in gc: GraphicsContext) {
        let sounding = voice.map { $0.gate || $0.envLevel > 0 } ?? false
        let waveform = voice?.waveformName ?? ""
        draw(note: (sounding ? voice?.note : nil) ?? "·", waveform: waveform.isEmpty ? "—" : waveform,
             gate: voice?.gate == true, color: color, centeredAt: x, top: top, in: gc)
    }

    /// The same labels from plain text.
    static func draw(note: String, waveform: String, gate: Bool, color: Color, centeredAt x: CGFloat, top: CGFloat, in gc: GraphicsContext) {
        let note = Text(note)
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .foregroundStyle(gate ? color : .gray)
        gc.draw(note, at: CGPoint(x: x, y: top + 16))
        let wave = Text(waveform)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.gray)
        gc.draw(wave, at: CGPoint(x: x, y: top + 31))
    }
}
