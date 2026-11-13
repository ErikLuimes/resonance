import SwiftUI
import PhosphorCore

/// The note and waveform under each voice, drawn the same way by every
/// visualizer that labels its voices.
enum VoiceLabels {
    /// Room to leave under a voice's drawing.
    static let height: CGFloat = 38

    /// Draw `voice`'s labels centered on `x`, below `top`. A released note
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

/// The same labels as two text layers, for the visualizers made of layers
/// (see `FrameLinkedNSView`). Each layer's text is set only when it changes.
final class VoiceLabelLayers {
    /// SwiftUI's `.gray`, which the drawn labels use.
    static let gray = CGColor(srgbRed: 0.557, green: 0.557, blue: 0.576, alpha: 1)
    /// A text layer would fade between notes otherwise, and a moved layer slide.
    static let noActions: [String: any CAAction] = [
        "contents": NSNull(), "string": NSNull(), "foregroundColor": NSNull(), "path": NSNull(),
        "strokeColor": NSNull(), "fillColor": NSNull(), "bounds": NSNull(), "position": NSNull(),
        "hidden": NSNull(), "backgroundColor": NSNull(), "colors": NSNull(), "cornerRadius": NSNull(),
    ]
    private static let noteFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .medium)
    private static let waveformFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    private let note = CATextLayer()
    private let waveform = CATextLayer()

    init(in parent: CALayer) {
        for (label, font) in [(note, Self.noteFont), (waveform, Self.waveformFont)] {
            label.font = font
            label.fontSize = font.pointSize
            label.alignmentMode = .center
            label.foregroundColor = Self.gray
            label.actions = Self.noActions
            parent.addSublayer(label)
        }
    }

    func setScale(_ scale: CGFloat) {
        note.contentsScale = scale
        waveform.contentsScale = scale
    }

    /// Centered on `x`, below `top`, both measured from the top left of a
    /// layer `height` tall whose origin is its bottom left. Wider than
    /// `width` if need be, as drawn text spills past its voice's column.
    func place(centeredAt x: CGFloat, top: CGFloat, width: CGFloat, in height: CGFloat) {
        let width = max(width, 140)
        Self.setFrame(note, Self.line(Self.noteFont, centerX: x, centerY: top + 16, width: width, in: height))
        Self.setFrame(waveform, Self.line(Self.waveformFont, centerX: x, centerY: top + 31, width: width, in: height))
    }

    /// As `VoiceLabels.draw` shows them: a released note still sounds, so
    /// its name stays, dimmed; nil shows placeholders.
    func show(_ voice: VizVoice?, color: CGColor) {
        let sounding = voice.map { $0.gate || $0.envLevel > 0 } ?? false
        let name = voice?.waveformName ?? ""
        Self.set(note, (sounding ? voice?.note : nil) ?? "·", color: voice?.gate == true ? color : Self.gray)
        Self.set(waveform, name.isEmpty ? "—" : name, color: Self.gray)
    }

    func removeFromSuperlayer() {
        note.removeFromSuperlayer()
        waveform.removeFromSuperlayer()
    }

    /// A text layer redraws when its string or color is set, even to the same thing.
    static func set(_ label: CATextLayer, _ string: String, color: CGColor) {
        if label.string as? String != string { label.string = string }
        if label.foregroundColor != color { label.foregroundColor = color }
    }

    static func setFrame(_ layer: CALayer, _ frame: CGRect) {
        if layer.frame != frame { layer.frame = frame }
    }

    /// One line of `font` centered on `centerX, centerY` from the top left.
    private static func line(_ font: NSFont, centerX: CGFloat, centerY: CGFloat, width: CGFloat, in height: CGFloat) -> CGRect {
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        return CGRect(x: centerX - width / 2, y: height - centerY - lineHeight / 2, width: width, height: lineHeight)
    }
}
