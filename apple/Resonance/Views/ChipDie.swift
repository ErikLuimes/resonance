import AppKit
import SwiftUI

/// The Chip visualizer's picture: a SID with its lid off, seen from
/// straight above as under a microscope. The die sits in the package's
/// gold cavity with a bond wire from each of its 28 pads to a lead, and
/// its blocks are laid out as the chip works: three voices side by side
/// (oscillator, waveform, pulse width, envelope, converter), the filter,
/// the register file, and the mixer.
///
/// What lights up is the chip's real state, bit for bit: every cell is a
/// bit of a register, lit when it's 1. So a note is its frequency's bits
/// in the oscillator, a pulse-width sweep is a counter running, and the
/// register file is all 29 bytes as the tune's player writes them.
///
/// The floor plan is drawn in the manner of the 6581's die, with its
/// functional blocks and its real pins in package order; it isn't a
/// trace of the actual mask.
nonisolated enum ChipDie {
    /// The die within the whole picture (a square, 0–1).
    static let die = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)

    /// The 6581's pins, 1–28, in package order. The pads run round the
    /// die the same way: down the left, along the bottom, up the right
    /// and back along the top.
    static let pins = ["CAP1A", "CAP1B", "CAP2A", "CAP2B", "RES", "φ2", "R/W",
                       "CS", "A0", "A1", "A2", "A3", "A4", "GND",
                       "D0", "D1", "D2", "D3", "D4", "D5", "D6",
                       "D7", "POTY", "POTX", "VCC", "EXT", "AUDIO", "VDD"]

    enum Pin {
        static let filterCaps = 0...3
        static let clock = 5
        static let write = 6
        static let select = 7
        static let address = 8...12
        static let data = 14...21
        static let audio = 26
    }

    /// A pad's center on the die (0–1 within it), and which way its wire leaves.
    static func pad(_ pin: Int) -> (center: CGPoint, out: CGVector) {
        let along = 0.14 + Double(pin % 7) * 0.12
        switch pin / 7 {
        case 0: return (CGPoint(x: 0.033, y: along), CGVector(dx: -1, dy: 0))
        case 1: return (CGPoint(x: along, y: 0.967), CGVector(dx: 0, dy: 1))
        case 2: return (CGPoint(x: 0.967, y: 1 - along), CGVector(dx: 1, dy: 0))
        default: return (CGPoint(x: 1 - along, y: 0.033), CGVector(dx: 0, dy: -1))
        }
    }

    /// Where a pad's wire lands on its lead, in the whole picture.
    static func lead(_ pin: Int) -> CGPoint {
        let (center, out) = pad(pin)
        let onDie = point(center)
        // The leads fan out a little from the die's middle, as a lead frame's do.
        let spread = 1.22
        let fanned = CGPoint(x: 0.5 + (onDie.x - 0.5) * spread, y: 0.5 + (onDie.y - 0.5) * spread)
        return CGPoint(x: out.dx == 0 ? fanned.x : 0.5 + out.dx * 0.4, y: out.dy == 0 ? fanned.y : 0.5 + out.dy * 0.4)
    }

    /// A place on the die (0–1 within it) in the whole picture.
    static func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: die.minX + p.x * die.width, y: die.minY + p.y * die.height)
    }

    // MARK: The floor plan, 0–1 within the die

    static func column(_ voice: Int) -> (x: Double, width: Double) { (0.095 + Double(voice) * 0.275, 0.26) }
    static func oscillator(_ v: Int) -> CGRect { CGRect(x: column(v).x, y: 0.14, width: column(v).width, height: 0.06) }
    static func waveform(_ v: Int) -> CGRect { CGRect(x: column(v).x, y: 0.215, width: column(v).width, height: 0.085) }
    static func pulseWidth(_ v: Int) -> CGRect { CGRect(x: column(v).x, y: 0.315, width: column(v).width, height: 0.045) }
    static func envelope(_ v: Int) -> CGRect { CGRect(x: column(v).x, y: 0.375, width: column(v).width, height: 0.08) }
    static func converter(_ v: Int) -> CGRect { CGRect(x: column(v).x, y: 0.47, width: column(v).width, height: 0.05) }
    static let linkBus = 0.095...0.125
    static let routeBus = 0.55
    static let filter = CGRect(x: 0.095, y: 0.585, width: 0.405, height: 0.32)
    static let routing = CGRect(x: 0.11, y: 0.6, width: 0.17, height: 0.032)
    static let modes = CGRect(x: 0.315, y: 0.6, width: 0.17, height: 0.032)
    static let integrators = CGRect(x: 0.11, y: 0.65, width: 0.375, height: 0.15)
    static let cutoff = CGRect(x: 0.11, y: 0.82, width: 0.375, height: 0.03)
    static let resonance = CGRect(x: 0.11, y: 0.865, width: 0.14, height: 0.028)
    static let registers = CGRect(x: 0.525, y: 0.585, width: 0.38, height: 0.175)
    static let mixer = CGRect(x: 0.525, y: 0.785, width: 0.38, height: 0.12)
    static let volume = CGRect(x: 0.54, y: 0.8, width: 0.1, height: 0.03)
    static let output = CGRect(x: 0.665, y: 0.8, width: 0.225, height: 0.09)

    /// `count` cells in a row across `rect`, with a gap between them.
    static func cells(_ rect: CGRect, count: Int, gap: Double = 0.18) -> [CGRect] {
        let pitch = rect.width / Double(count)
        return (0..<count).map { i in
            CGRect(x: rect.minX + Double(i) * pitch + pitch * gap / 2, y: rect.minY,
                   width: pitch * (1 - gap), height: rect.height)
        }
    }

    // MARK: The picture

    /// The package and the die with nothing lit, `size` pixels square.
    /// Drawn once: every line on it is placed by a fixed sequence, so it's
    /// the same chip every time.
    static func art(size: Int = 1600) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = Double(size)
        // Top-left origin, in pixels.
        context.translateBy(x: 0, y: s)
        context.scaleBy(x: 1, y: -1)
        var random = Scatter(seed: 6581)
        func color(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
            CGColor(srgbRed: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                    blue: Double(hex & 0xFF) / 255, alpha: alpha)
        }
        func picture(_ r: CGRect) -> CGRect { CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s) }
        func onDie(_ r: CGRect) -> CGRect {
            picture(CGRect(x: die.minX + r.minX * die.width, y: die.minY + r.minY * die.height,
                           width: r.width * die.width, height: r.height * die.height))
        }
        func fill(_ rect: CGRect, _ c: CGColor, radius: Double = 0) {
            context.setFillColor(c)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        func line(_ a: CGPoint, _ b: CGPoint, _ c: CGColor, width: Double) {
            context.setStrokeColor(c)
            context.setLineWidth(width)
            context.move(to: a)
            context.addLine(to: b)
            context.strokePath()
        }
        func label(_ text: String, at point: CGPoint, size: Double, _ c: CGColor, centered: Bool = false) {
            let font = NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: c) ?? .white])
            let lineOfText = CTLineCreateWithAttributedString(string)
            let width = CTLineGetTypographicBounds(lineOfText, nil, nil, nil)
            context.saveGState()
            // Text draws bottom-up: flip it back at its own baseline.
            context.translateBy(x: point.x - (centered ? width / 2 : 0), y: point.y)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(lineOfText, context)
            context.restoreGState()
        }

        // The ceramic body, and the cavity's gold floor.
        fill(picture(CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96)), color(0x1B1420), radius: s * 0.035)
        for _ in 0..<2600 {
            let x = random.next() * s, y = random.next() * s
            fill(CGRect(x: x, y: y, width: 1.5, height: 1.5), color(0xFFFFFF, 0.025 + random.next() * 0.03))
        }
        let cavity = picture(CGRect(x: 0.125, y: 0.125, width: 0.75, height: 0.75))
        fill(cavity.insetBy(dx: -s * 0.012, dy: -s * 0.012), color(0x0C090E), radius: s * 0.022)
        fill(cavity, color(0x4A3B1A), radius: s * 0.014)
        // Brushed, as plating is.
        for _ in 0..<900 {
            let y = cavity.minY + random.next() * cavity.height
            let x = cavity.minX + random.next() * cavity.width
            line(CGPoint(x: x, y: y), CGPoint(x: min(x + 20 + random.next() * 160, cavity.maxX), y: y),
                 color(random.next() > 0.5 ? 0xE8C872 : 0x1A1206, 0.07), width: 1)
        }

        // The leads the wires land on, each with its pin's name.
        for pin in 0..<28 {
            let end = lead(pin), (_, out) = pad(pin)
            let across = CGVector(dx: -out.dy, dy: out.dx)
            let length = 0.068, half = 0.017
            let finger = CGMutablePath()
            let tip = CGPoint(x: (end.x - out.dx * 0.012) * s, y: (end.y - out.dy * 0.012) * s)
            let far = CGPoint(x: (end.x + out.dx * length) * s, y: (end.y + out.dy * length) * s)
            finger.move(to: CGPoint(x: tip.x + across.dx * half * 0.7 * s, y: tip.y + across.dy * half * 0.7 * s))
            finger.addLine(to: CGPoint(x: far.x + across.dx * half * s, y: far.y + across.dy * half * s))
            finger.addLine(to: CGPoint(x: far.x - across.dx * half * s, y: far.y - across.dy * half * s))
            finger.addLine(to: CGPoint(x: tip.x - across.dx * half * 0.7 * s, y: tip.y - across.dy * half * 0.7 * s))
            finger.closeSubpath()
            context.setFillColor(color(0xC9A44E))
            context.addPath(finger)
            context.fillPath()
            context.setStrokeColor(color(0xFFF0B8, 0.5))
            context.setLineWidth(1.5)
            context.addPath(finger)
            context.strokePath()
            let name = CGPoint(x: (end.x + out.dx * 0.042) * s, y: (end.y + out.dy * 0.042) * s + s * 0.0045)
            label(pins[pin], at: name, size: s * 0.0105, color(0x2A1E08), centered: true)
        }

        // The die: silicon, a scribe line round it, a seal ring inside that.
        let whole = onDie(CGRect(x: 0, y: 0, width: 1, height: 1))
        fill(whole.insetBy(dx: -s * 0.004, dy: -s * 0.004), color(0x05070A))
        fill(whole, color(0x101B22))
        context.setStrokeColor(color(0x7FA0AE, 0.35))
        context.setLineWidth(2)
        context.stroke(onDie(CGRect(x: 0.07, y: 0.07, width: 0.86, height: 0.86)))

        /// Rows of fine lines, broken here and there: logic, seen from far off.
        func logic(_ rect: CGRect, tint: UInt32, pitch: Double = 5, vertical: Bool = false) {
            let r = onDie(rect)
            fill(r, color(tint, 0.55))
            context.saveGState()
            context.clip(to: r)
            var at = 0.0
            while at < (vertical ? r.width : r.height) {
                var along = 0.0
                let extent = vertical ? r.height : r.width
                while along < extent {
                    let run = 6 + random.next() * 46
                    if random.next() > 0.22 {
                        let a = vertical ? CGPoint(x: r.minX + at, y: r.minY + along) : CGPoint(x: r.minX + along, y: r.minY + at)
                        let b = vertical ? CGPoint(x: r.minX + at, y: r.minY + min(along + run, extent))
                                         : CGPoint(x: r.minX + min(along + run, extent), y: r.minY + at)
                        line(a, b, color(random.next() > 0.8 ? 0xDCEBF0 : 0x86A4B0, 0.16 + random.next() * 0.2), width: 1.2)
                    }
                    along += run + 3
                }
                at += pitch
            }
            context.restoreGState()
            context.setStrokeColor(color(0xA9C4CE, 0.3))
            context.setLineWidth(1.2)
            context.stroke(r)
        }
        /// Empty cells for the bits that light up.
        func sockets(_ rects: [CGRect]) {
            for rect in rects {
                let r = onDie(rect)
                fill(r, color(0x060A0D, 0.85))
                context.setStrokeColor(color(0x9DB8C2, 0.4))
                context.setLineWidth(1)
                context.stroke(r)
            }
        }
        func name(_ text: String, in rect: CGRect) {
            let r = onDie(rect)
            label(text, at: CGPoint(x: r.minX + 3, y: r.minY - 4), size: s * 0.0072, color(0xB9D2DC, 0.6))
        }
        /// A bundle of metal lines between two places on the die.
        func metal(_ points: [CGPoint], lines: Int = 3, spacing: Double = 3) {
            for k in 0..<lines {
                let offset = (Double(k) - Double(lines - 1) / 2) * spacing
                context.setStrokeColor(color(0xB5C7CE, 0.42))
                context.setLineWidth(1.4)
                let onto = points.map { p -> CGPoint in
                    let q = onDie(CGRect(origin: p, size: .zero)).origin
                    return CGPoint(x: q.x + offset, y: q.y + offset)
                }
                context.addLines(between: onto)
                context.strokePath()
            }
        }

        for v in 0..<3 {
            logic(oscillator(v), tint: 0x16303A)
            sockets(cells(oscillator(v).insetBy(dx: 0.006, dy: 0.014), count: 16))
            name("OSC \(v + 1)  FREQ", in: oscillator(v))
            logic(waveform(v), tint: 0x1A2B40, pitch: 4, vertical: true)
            sockets(cells(waveform(v).insetBy(dx: 0.008, dy: 0.016), count: 4, gap: 0.12))
            name("WAVEFORM  TRI SAW PUL NOI", in: waveform(v))
            logic(pulseWidth(v), tint: 0x16303A)
            sockets(cells(pulseWidth(v).insetBy(dx: 0.006, dy: 0.01), count: 12))
            name("PULSE WIDTH", in: pulseWidth(v))
            logic(envelope(v), tint: 0x23263F, pitch: 4)
            let top = CGRect(x: envelope(v).minX + 0.006, y: envelope(v).minY + 0.01, width: envelope(v).width - 0.012, height: 0.024)
            sockets(cells(top, count: 17))
            sockets([CGRect(x: top.minX, y: top.maxY + 0.012, width: top.width, height: 0.02)])
            name("ENVELOPE  A D S R  GATE", in: envelope(v))
            logic(converter(v), tint: 0x2B2338, pitch: 7, vertical: true)
            name("D/A", in: converter(v))
            // Down to the routing bus.
            let middle = column(v).x + column(v).width / 2
            metal([CGPoint(x: middle, y: converter(v).maxY), CGPoint(x: middle, y: routeBus)], lines: 2)
        }
        // Ring and sync run from each voice to the next, and round from 3 to 1.
        metal([CGPoint(x: 0.1, y: 0.103), CGPoint(x: 0.9, y: 0.103)], lines: 2)
        metal([CGPoint(x: 0.1, y: 0.118), CGPoint(x: 0.9, y: 0.118)], lines: 2)
        metal([CGPoint(x: 0.1, y: routeBus), CGPoint(x: 0.9, y: routeBus)], lines: 4)
        metal([CGPoint(x: 0.715, y: routeBus), CGPoint(x: 0.715, y: registers.minY)], lines: 6, spacing: 2.5)
        metal([CGPoint(x: filter.maxX, y: 0.84), CGPoint(x: mixer.minX, y: 0.84)], lines: 2)

        // The filter is analog: big devices, not rows of logic.
        logic(filter, tint: 0x2A1F3A, pitch: 9)
        name("FILTER", in: filter)
        sockets(cells(routing, count: 4))
        sockets(cells(modes, count: 4))
        let analog = onDie(integrators)
        fill(analog, color(0x0A0D12, 0.9))
        for k in 0..<2 {
            // Two integrators: each a wide transistor and its capacitor's pads.
            let x = analog.minX + analog.width * (0.06 + Double(k) * 0.5), w = analog.width * 0.4
            for row in 0..<7 {
                let y = analog.minY + analog.height * (0.12 + Double(row) * 0.115)
                fill(CGRect(x: x, y: y, width: w, height: analog.height * 0.06), color(row % 2 == 0 ? 0x5B4A86 : 0x3A5C6E, 0.5))
            }
        }
        context.setStrokeColor(color(0xA9C4CE, 0.3))
        context.stroke(analog)
        sockets(cells(cutoff, count: 11))
        sockets(cells(resonance, count: 4))
        label("ROUTE 1 2 3 EXT", at: CGPoint(x: onDie(routing).minX, y: onDie(routing).maxY + s * 0.0085), size: s * 0.0062, color(0xB9D2DC, 0.5))
        label("LP BP HP 3OFF", at: CGPoint(x: onDie(modes).minX, y: onDie(modes).maxY + s * 0.0085), size: s * 0.0062, color(0xB9D2DC, 0.5))
        label("CUTOFF", at: CGPoint(x: onDie(cutoff).minX, y: onDie(cutoff).minY - 4), size: s * 0.0062, color(0xB9D2DC, 0.5))
        label("RES", at: CGPoint(x: onDie(resonance).maxX + 6, y: onDie(resonance).maxY - 3), size: s * 0.0062, color(0xB9D2DC, 0.5))

        logic(registers, tint: 0x14262C, pitch: 4)
        name("REGISTERS  $D400–$D41C", in: registers)
        sockets(registerCells().flatMap { $0 })
        logic(mixer, tint: 0x2B2338, pitch: 8, vertical: true)
        name("MIXER  VOLUME", in: mixer)
        sockets(cells(volume, count: 4))
        fill(onDie(output), color(0x060A0D, 0.9))
        context.stroke(onDie(output))
        label("6581  SID", at: CGPoint(x: onDie(CGRect(x: 0.74, y: 0, width: 0, height: 0)).minX,
                                      y: onDie(CGRect(x: 0, y: 0.935, width: 0, height: 0)).minY + s * 0.006),
              size: s * 0.008, color(0xB9D2DC, 0.45))

        // Light across the silicon, from the upper left.
        context.saveGState()
        context.clip(to: whole)
        if let sheen = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF, 0), color(0xCFE8FF, 0.09), color(0xFFFFFF, 0)] as CFArray,
                                  locations: [0.25, 0.5, 0.75]) {
            context.drawLinearGradient(sheen, start: CGPoint(x: whole.minX, y: whole.minY),
                                       end: CGPoint(x: whole.maxX, y: whole.maxY), options: [])
        }
        context.restoreGState()

        // Pads, and a gold wire from each to its lead.
        for pin in 0..<28 {
            let (center, _) = pad(pin)
            let r = onDie(CGRect(x: center.x - 0.019, y: center.y - 0.019, width: 0.038, height: 0.038))
            fill(r, color(0xC7D3D8))
            fill(r.insetBy(dx: r.width * 0.16, dy: r.width * 0.16), color(0xE9D08A))
            let from = CGPoint(x: r.midX, y: r.midY), to = CGPoint(x: lead(pin).x * s, y: lead(pin).y * s)
            for (c, width) in [(color(0x1A1206, 0.55), 7.0), (color(0xD8B45A), 4.0), (color(0xFFF3C4, 0.8), 1.4)] {
                line(from, to, c, width: width)
            }
            context.setFillColor(color(0xF2D680))
            context.fillEllipse(in: CGRect(x: from.x - 7, y: from.y - 7, width: 14, height: 14))
        }
        return context.makeImage()
    }

    /// The register file's cells: 29 registers across, each 8 bits down,
    /// bit 7 at the top.
    static func registerCells() -> [[CGRect]] {
        let inner = registers.insetBy(dx: 0.008, dy: 0.012)
        let pitch = inner.width / 29, row = inner.height / 8
        return (0..<29).map { register in
            (0..<8).map { bit in
                CGRect(x: inner.minX + Double(register) * pitch + pitch * 0.14, y: inner.minY + Double(7 - bit) * row + row * 0.14,
                       width: pitch * 0.72, height: row * 0.72)
            }
        }
    }

    /// Numbers between 0 and 1 that are the same every run.
    struct Scatter {
        private var state: UInt64

        init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }

        mutating func next() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state >> 11) / Double(1 << 53)
        }
    }
}

/// What the chip is doing in one frame, as the Chip visualizer draws it.
nonisolated struct ChipState {
    struct Voice {
        var frequency: UInt16 = 0
        var pulseWidth: UInt16 = 0
        /// 1 triangle, 2 saw, 4 pulse, 8 noise.
        var waveform: UInt8 = 0
        var gate = false
        var ring = false
        var sync = false
        var attack: UInt8 = 0
        var decay: UInt8 = 0
        var sustain: UInt8 = 0
        var release: UInt8 = 0
        /// The envelope, 0–1.
        var level: Float = 0
        var filtered = false
        /// Its latest output, −1…1, oldest first.
        var samples: [Float] = []
    }

    var voices = [Voice](repeating: Voice(), count: 3)
    /// $D400–$D41C.
    var registers = [UInt8](repeating: 0, count: 29)
    /// How lately each register changed: 1 just now, fading to 0.
    var written = [Float](repeating: 0, count: 29)
    var cutoff: UInt16 = 0
    var resonance: UInt8 = 0
    var lowPass = false
    var bandPass = false
    var highPass = false
    var voice3Off = false
    var volume: UInt8 = 0
    /// Any steady clock, in seconds: it moves what flows.
    var time = 0.0

    /// Fades each register's flash, and starts one where `registers`
    /// differs from the last frame's.
    mutating func write(_ next: [UInt8], dt: Double) {
        let fade = Float(exp(-dt / 0.12))
        for i in 0..<29 {
            written[i] *= fade
            if i < next.count, next[i] != registers[i] {
                written[i] = 1
                registers[i] = next[i]
            }
        }
    }

    /// Whether a voice reaches the output: voice 3 can be cut off from it.
    func isHeard(_ voice: Int) -> Bool {
        voice != 2 || !voice3Off || voices[2].filtered
    }

    /// The filter's response where it's `x` of the way along the cutoff's
    /// range, in decibels: the enabled modes of a two-pole filter added
    /// up, with the peak the resonance gives. For the picture, not exact.
    func response(at x: Double) -> Double {
        guard lowPass || bandPass || highPass else { return -60 }
        let ratio = pow(2, (x - Double(cutoff) / 2047) * 9)
        let q = 0.7 + Double(resonance) / 15 * 3.5
        // 1 / (1 − r² + j·r/q), times 1, j·r/q and −r² for the three modes.
        let real = 1 - ratio * ratio, imaginary = ratio / q
        let size = real * real + imaginary * imaginary
        var sumReal = 0.0, sumImaginary = 0.0
        if lowPass { sumReal += real / size; sumImaginary += -imaginary / size }
        if bandPass { sumReal += imaginary * imaginary / size; sumImaginary += imaginary * real / size }
        if highPass { sumReal += -ratio * ratio * real / size; sumImaginary += ratio * ratio * imaginary / size }
        return 20 * log10(max((sumReal * sumReal + sumImaginary * sumImaginary).squareRoot(), 1e-3))
    }
}

/// Draws the chip: the still picture, then everything that's lit.
struct ChipDrawing {
    var state: ChipState
    var colors: [Color]
    /// The picture from `ChipDie.art`, made once.
    var art: CGImage?

    func draw(in gc: inout GraphicsContext, size: CGSize) {
        // A square in the middle, a little above it: Now Playing's title
        // and transport sit over the lower part of the view.
        let side = min(size.width * 0.7, size.height * 0.96)
        let frame = CGRect(x: (size.width - side) / 2, y: (size.height - side) * 0.4, width: side, height: side)
        if let art {
            gc.draw(Image(decorative: art, scale: 1), in: frame)
        }
        func place(_ r: CGRect) -> CGRect {
            let d = ChipDie.die
            return CGRect(x: frame.minX + (d.minX + r.minX * d.width) * side, y: frame.minY + (d.minY + r.minY * d.height) * side,
                          width: r.width * d.width * side, height: r.height * d.height * side)
        }
        func place(_ p: CGPoint) -> CGPoint { place(CGRect(origin: p, size: .zero)).origin }
        func picture(_ p: CGPoint) -> CGPoint { CGPoint(x: frame.minX + p.x * side, y: frame.minY + p.y * side) }
        let unit = side / 700
        let white = Color.white

        // Everything lit goes into one path per color, drawn twice: soft
        // and wide for the glow, then sharp.
        var lit: [Int: Path] = [:]
        func light(_ rect: CGRect, _ key: Int) { lit[key, default: Path()].addRect(place(rect)) }
        func bits(_ value: Int, in rects: [CGRect], _ key: Int) {
            for (i, rect) in rects.enumerated() where value >> (rects.count - 1 - i) & 1 == 1 { light(rect, key) }
        }
        var traces: [(Path, Color, Double)] = []
        func scope(_ samples: [Float], in rect: CGRect, _ color: Color, gain: Float = 1) {
            let r = place(rect).insetBy(dx: 2, dy: 2)
            guard samples.count > 8 else { return }
            // From a rising zero crossing, so a steady note stands still.
            let window = min(samples.count / 2, 420)
            var start = samples.count - window * 2
            for i in max(start, 1)..<(samples.count - window) where samples[i - 1] <= 0 && samples[i] > 0 {
                start = i
                break
            }
            var path = Path()
            for i in 0..<window {
                let p = CGPoint(x: r.minX + r.width * Double(i) / Double(window - 1),
                                y: r.midY - Double(max(-1, min(1, samples[start + i] * gain))) * r.height * 0.46)
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            traces.append((path, color, 1.2 * unit))
        }
        /// A line along `points` (on the die), lit by `level`, with beads
        /// of light running along it.
        func wire(_ points: [CGPoint], _ color: Color, level: Double) {
            guard level > 0.01 else { return }
            let onto = points.map { place($0) }
            var path = Path()
            path.addLines(onto)
            traces.append((path, color.opacity(0.25 + 0.6 * level), 1.6 * unit))
            var lengths: [Double] = [0]
            for i in 1..<onto.count { lengths.append(lengths[i - 1] + hypot(onto[i].x - onto[i - 1].x, onto[i].y - onto[i - 1].y)) }
            guard let total = lengths.last, total > 1 else { return }
            let spacing = 26 * unit
            var at = (state.time * 90 * unit).truncatingRemainder(dividingBy: spacing)
            var beads = Path()
            while at < total {
                let segment = max(1, lengths.firstIndex { $0 >= at } ?? onto.count - 1)
                let t = (at - lengths[segment - 1]) / max(lengths[segment] - lengths[segment - 1], 1e-6)
                let p = CGPoint(x: onto[segment - 1].x + (onto[segment].x - onto[segment - 1].x) * t,
                                y: onto[segment - 1].y + (onto[segment].y - onto[segment - 1].y) * t)
                beads.addEllipse(in: CGRect(x: p.x - 1.7 * unit, y: p.y - 1.7 * unit, width: 3.4 * unit, height: 3.4 * unit))
                at += spacing
            }
            traces.append((beads, white.opacity(0.35 + 0.65 * level), 0))
        }

        var filterLevel = 0.0
        for v in 0..<3 {
            let voice = state.voices[v]
            let level = Double(voice.level)
            bits(Int(voice.frequency), in: ChipDie.cells(ChipDie.oscillator(v).insetBy(dx: 0.006, dy: 0.014), count: 16), v)
            bits(Int(voice.waveform & 0x1) << 3 | Int(voice.waveform & 0x2) << 1 | Int(voice.waveform & 0x4) >> 1 | Int(voice.waveform & 0x8) >> 3,
                 in: ChipDie.cells(ChipDie.waveform(v).insetBy(dx: 0.008, dy: 0.016), count: 4, gap: 0.12), v)
            bits(Int(voice.pulseWidth), in: ChipDie.cells(ChipDie.pulseWidth(v).insetBy(dx: 0.006, dy: 0.01), count: 12), v)
            let envelope = ChipDie.envelope(v)
            let top = CGRect(x: envelope.minX + 0.006, y: envelope.minY + 0.01, width: envelope.width - 0.012, height: 0.024)
            let adsr = Int(voice.attack) << 13 | Int(voice.decay) << 9 | Int(voice.sustain) << 5 | Int(voice.release) << 1 | (voice.gate ? 1 : 0)
            bits(adsr, in: ChipDie.cells(top, count: 17), v)
            // The envelope's level, as far along its bar as it has risen.
            light(CGRect(x: top.minX, y: top.maxY + 0.012, width: top.width * level, height: 0.02), v)
            scope(voice.samples, in: ChipDie.converter(v), colors[v], gain: 1.6)

            // Out of the converter, along the bus, into the filter or past it.
            let middle = ChipDie.column(v).x + ChipDie.column(v).width / 2
            let heard = state.isHeard(v) ? level : 0
            if voice.filtered {
                filterLevel = max(filterLevel, level)
                let entry = ChipDie.cells(ChipDie.routing, count: 4)[v].midX
                wire([CGPoint(x: middle, y: ChipDie.converter(v).maxY), CGPoint(x: middle, y: ChipDie.routeBus),
                      CGPoint(x: entry, y: ChipDie.routeBus), CGPoint(x: entry, y: ChipDie.routing.minY)], colors[v], level: level)
            } else {
                let down = 0.93 - Double(v) * 0.012
                wire([CGPoint(x: middle, y: ChipDie.converter(v).maxY), CGPoint(x: middle, y: ChipDie.routeBus - 0.006 * Double(v + 1)),
                      CGPoint(x: down, y: ChipDie.routeBus - 0.006 * Double(v + 1)), CGPoint(x: down, y: 0.845),
                      CGPoint(x: ChipDie.mixer.maxX, y: 0.845)], colors[v], level: heard)
            }
            // Ring and sync come from the voice before: 3 feeds 1.
            let source = (v + 2) % 3
            let from = ChipDie.column(source).x + ChipDie.column(source).width / 2
            if voice.ring {
                wire([CGPoint(x: from, y: ChipDie.oscillator(source).minY), CGPoint(x: from, y: 0.103), CGPoint(x: middle - 0.02, y: 0.103),
                      CGPoint(x: middle - 0.02, y: ChipDie.oscillator(v).minY)], colors[source], level: 0.9)
            }
            if voice.sync {
                wire([CGPoint(x: from + 0.02, y: ChipDie.oscillator(source).minY), CGPoint(x: from + 0.02, y: 0.118),
                      CGPoint(x: middle + 0.02, y: 0.118), CGPoint(x: middle + 0.02, y: ChipDie.oscillator(v).minY)], colors[source], level: 0.9)
            }
        }

        // The filter.
        let routes = ChipDie.cells(ChipDie.routing, count: 4)
        for v in 0..<3 where state.voices[v].filtered { light(routes[v], v) }
        let modes = ChipDie.cells(ChipDie.modes, count: 4)
        for (i, on) in [state.lowPass, state.bandPass, state.highPass, state.voice3Off].enumerated() where on { light(modes[i], 3) }
        bits(Int(state.cutoff), in: ChipDie.cells(ChipDie.cutoff, count: 11), 3)
        bits(Int(state.resonance), in: ChipDie.cells(ChipDie.resonance, count: 4), 3)
        bits(Int(state.volume), in: ChipDie.cells(ChipDie.volume, count: 4), 3)
        let curveArea = place(ChipDie.integrators).insetBy(dx: 3, dy: 3)
        var curve = Path()
        for i in 0...80 {
            let x = Double(i) / 80
            let decibels = min(18, max(-36, state.response(at: x)))
            let p = CGPoint(x: curveArea.minX + curveArea.width * x, y: curveArea.minY + curveArea.height * (18 - decibels) / 54)
            i == 0 ? curve.move(to: p) : curve.addLine(to: p)
        }
        let filtered = (0..<3).filter { state.voices[$0].filtered }
        let filterColor = filtered.count == 1 ? colors[filtered[0]] : white
        traces.append((curve, filterColor.opacity(0.35 + 0.65 * filterLevel), 1.4 * unit))
        if filterLevel > 0.01 {
            wire([CGPoint(x: ChipDie.filter.maxX, y: 0.84), CGPoint(x: ChipDie.mixer.minX, y: 0.84)], filterColor, level: filterLevel)
        }

        // The registers: every bit, in its voice's color, white as it's written.
        let cells = ChipDie.registerCells()
        var flashes: [(CGRect, Double)] = []
        for (register, column) in cells.enumerated() {
            let key = register < 21 ? register / 7 : 3
            bits(Int(state.registers[register]), in: column.reversed(), key)
            if state.written[register] > 0.03 {
                let whole = column[0].union(column[7])
                flashes.append((place(whole).insetBy(dx: -1, dy: -1), Double(state.written[register])))
            }
        }

        // The output: the three voices together.
        let count = state.voices.map(\.samples.count).min() ?? 0
        var mix = [Float](repeating: 0, count: count)
        var loudest: Float = 0
        for v in 0..<3 where state.isHeard(v) {
            for i in 0..<count { mix[i] += state.voices[v].samples[state.voices[v].samples.count - count + i] / 3 }
        }
        let scale = Float(state.volume) / 15
        for i in 0..<count {
            mix[i] *= scale
            loudest = max(loudest, abs(mix[i]))
        }
        scope(mix, in: ChipDie.output, white, gain: 2.2)

        let palette = colors + [Color(red: 0.86, green: 0.93, blue: 1)]

        // The pins at work: the clock always, the bus as registers are
        // written, the filter's capacitors and the audio out as they're used.
        var pinsLit: [(Path, CGPoint, Color, Double)] = []
        func pin(_ index: Int, _ color: Color, _ strength: Double) {
            guard strength > 0.02 else { return }
            let from = place(ChipDie.pad(index).center), to = picture(ChipDie.lead(index))
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            pinsLit.append((path, from, color, min(1, strength)))
        }
        let writing = Double(state.written.max() ?? 0)
        pin(ChipDie.Pin.clock, white, 0.25 + 0.2 * sin(state.time * 12))
        pin(ChipDie.Pin.write, white, writing * 0.8)
        pin(ChipDie.Pin.select, white, writing * 0.8)
        let latest = state.written.indices.max { state.written[$0] < state.written[$1] } ?? 0
        for (bit, index) in ChipDie.Pin.address.enumerated() where latest >> bit & 1 == 1 { pin(index, white, writing * 0.8) }
        for (bit, index) in ChipDie.Pin.data.enumerated() where state.registers[latest] >> bit & 1 == 1 {
            pin(index, palette[latest < 21 ? latest / 7 : 3], writing)
        }
        for index in ChipDie.Pin.filterCaps { pin(index, filterColor, filterLevel * 0.8) }
        pin(ChipDie.Pin.audio, white, min(1, Double(loudest) * 3))

        gc.drawLayer { layer in
            layer.blendMode = .plusLighter
            layer.drawLayer { glow in
                glow.addFilter(.blur(radius: 5 * unit))
                for (key, path) in lit { glow.fill(path, with: .color(palette[key].opacity(0.45))) }
                for (path, color, width) in traces {
                    width > 0 ? glow.stroke(path, with: .color(color), lineWidth: width * 2.5) : glow.fill(path, with: .color(color))
                }
            }
            for (key, path) in lit { layer.fill(path, with: .color(palette[key].opacity(0.82))) }
            for (path, color, width) in traces {
                width > 0 ? layer.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineJoin: .round))
                          : layer.fill(path, with: .color(color))
            }
            for (rect, strength) in flashes { layer.fill(Path(rect), with: .color(white.opacity(0.5 * strength))) }
            for (path, from, color, strength) in pinsLit {
                layer.drawLayer { glow in
                    glow.addFilter(.blur(radius: 4 * unit))
                    glow.stroke(path, with: .color(color.opacity(strength)), lineWidth: 5 * unit)
                    glow.fill(Path(ellipseIn: CGRect(x: from.x - 7 * unit, y: from.y - 7 * unit, width: 14 * unit, height: 14 * unit)),
                              with: .color(color.opacity(strength)))
                }
                layer.stroke(path, with: .color(color.opacity(strength * 0.7)), lineWidth: 1.2 * unit)
            }
        }
    }
}
