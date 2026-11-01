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
        let note = Text((sounding ? voice?.note : nil) ?? "·")
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .foregroundStyle(voice?.gate == true ? color : .gray)
        gc.draw(note, at: CGPoint(x: x, y: top + 16))
        let waveform = voice?.waveformName ?? ""
        let wave = Text(waveform.isEmpty ? "—" : waveform)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.gray)
        gc.draw(wave, at: CGPoint(x: x, y: top + 31))
    }
}
