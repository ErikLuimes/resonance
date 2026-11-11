import Foundation
import simd

/// A SID's die for the Silicon visualizer: where each block, pad and
/// signal is on it, and what's lit for a given state of the chip. There
/// are two, `mos6581` and `mos8580`: different chips on different
/// processes, laid out alike.
///
/// The 6581's blocks are read off Tommi Lempinen's map of the R3's die
/// (MOS_6581_R3_blocks.jpg). He made no such map of the 8580, so its
/// blocks are placed by eye on his photograph of the R5, which shows the
/// same arrangement: three voices side by side, each with its
/// oscillator's columns above its envelope generator, and the filter
/// along one edge. Both are turned half a turn to match the layers
/// (design/visualizers/silicon/README.md). The pads are found on each
/// metal layer.
///
/// Ours, not the chip's: which way the bits run within a block (they're
/// laid in even slices along it), the routes drawn for the signals (they
/// follow the gaps between blocks, not the real wires), which voice
/// column is voice 1 (left to right on the map), and which pad is which
/// pin beyond the audio output's.
nonisolated struct SiliconDie: Sendable {
    enum Package: Sendable, Equatable {
        /// Ceramic with a gold lid, as early 6581s came.
        case ceramic
        /// Black plastic, as the 8580 came.
        case plastic
    }

    /// "6581" or "8580".
    let name: String
    /// What's printed on the package, line by line.
    let marking: [String]
    /// The packed layers' file in the app (without its extension).
    let layers: String
    let package: Package
    /// The die's height over its width, from the layers.
    let aspect: Float

    /// A rectangle on the die: x0, y0, x1, y1, each 0–1 of its width or
    /// height, on the layers.
    typealias Place = SIMD4<Float>

    // The map the blocks are measured on, in its own pixels, and where
    // voice 1's parts are on it. Every voice's block is given in the
    // 6581 map's pixels and fitted to this die's.
    private let map: SIMD2<Float>
    private let voiceX: ClosedRange<Float>
    private let voicePitch: Float
    private let upperY: ClosedRange<Float>
    private let converterY: ClosedRange<Float>
    private let envelopeY: ClosedRange<Float>

    // The 6581 map's own figures, which the voices' blocks are given in.
    private static let fromX: ClosedRange<Float> = 203...575
    private static let fromUpper: ClosedRange<Float> = 183...632
    private static let fromConverter: ClosedRange<Float> = 680...724
    private static let fromEnvelope: ClosedRange<Float> = 740...1125

    private static func fit(_ value: Float, _ from: ClosedRange<Float>, _ to: ClosedRange<Float>) -> Float {
        to.lowerBound + (value - from.lowerBound) / (from.upperBound - from.lowerBound) * (to.upperBound - to.lowerBound)
    }

    /// A point of a voice, given on the 6581's map, on this die's map.
    private func voice(_ x: Float, _ y: Float, _ v: Int) -> SIMD2<Float> {
        let fitted = y < 675 ? Self.fit(y, Self.fromUpper, upperY)
            : y < 732 ? Self.fit(y, Self.fromConverter, converterY) : Self.fit(y, Self.fromEnvelope, envelopeY)
        return SIMD2(Self.fit(x, Self.fromX, voiceX) + Float(v) * voicePitch, fitted)
    }

    /// A point on this die's map, on the layers: half a turn round.
    private func turned(_ p: SIMD2<Float>) -> SIMD2<Float> { SIMD2(1 - p.x / map.x, 1 - p.y / map.y) }

    /// A rectangle between two points on this die's map, on the layers.
    private func place(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Place {
        let p = turned(a), q = turned(b)
        return SIMD4(min(p.x, q.x), min(p.y, q.y), max(p.x, q.x), max(p.y, q.y))
    }

    private func block(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, _ v: Int) -> Place {
        place(voice(x0, y0, v), voice(x1, y1, v))
    }

    // Each voice's blocks, as the 6581's map names them.
    func accumulator(_ v: Int) -> Place { block(432, 183, 574, 632, v) }
    func pulseWidth(_ v: Int) -> Place { block(396, 183, 430, 632, v) }
    func triangleSaw(_ v: Int) -> Place { block(378, 183, 392, 595, v) }
    func noise(_ v: Int) -> Place { block(336, 183, 378, 632, v) }
    func selector(_ v: Int) -> Place { block(293, 183, 313, 632, v) }
    func control(_ v: Int) -> Place { block(265, 183, 290, 490, v) }
    func waveformControl(_ v: Int) -> Place { block(238, 183, 260, 632, v) }
    func waveformDAC(_ v: Int) -> Place { block(203, 210, 236, 648, v) }
    func ringMod(_ v: Int) -> Place { block(413, 640, 444, 668, v) }
    func sync(_ v: Int) -> Place { block(448, 640, 500, 668, v) }
    func envelopeDAC(_ v: Int) -> Place { block(212, 680, 516, 724, v) }
    func envelope(_ v: Int) -> Place { block(200, 740, 575, 1125, v) }

    // The chip's shared parts, each on this die's own map.
    private let shared: [String: SIMD4<Float>]
    private func part(_ name: String) -> Place {
        let r = shared[name] ?? .zero
        return place(SIMD2(r.x, r.y), SIMD2(r.z, r.w))
    }

    var decoders: [Place] { [part("decoder1"), part("decoder2")] }
    var volume: Place { part("volume") }
    var filterMode: Place { part("filterMode") }
    var resonance: Place { part("resonance") }
    var bypass: Place { part("bypass") }
    var cutoff: Place { part("cutoff") }
    var filter: Place { part("filter") }
    var outputAmplifier: Place { part("outputAmplifier") }
    /// Where the output's waveform is drawn: somewhere with room, by the output.
    var outputScope: Place { part("outputScope") }
    var osc3Read: Place { part("osc3Read") }
    var env3Read: Place { part("env3Read") }

    /// The 28 bond pads, going round the die from the audio output's in
    /// the package's pin order: pin 27 first, then 28, 1, 2 and so on.
    let pads: [SIMD2<Float>]

    /// The pin (0–27, as `ChipDie.pins`) a pad is bonded to.
    static func pin(ofPad pad: Int) -> Int { (pad + 26) % 28 }
    static func pad(ofPin pin: Int) -> Int { (pin + 2) % 28 }

    /// Where the camera can go to look at something, on the die (0–1),
    /// and how much of the die's width it takes in there.
    var sights: [(center: SIMD2<Float>, across: Float)] {
        func middle(_ p: Place) -> SIMD2<Float> { SIMD2((p.x + p.z) / 2, (p.y + p.w) / 2) }
        return [
            (middle(accumulator(0)), 0.2),
            (middle(noise(0)), 0.13),
            (middle(envelope(0)), 0.3),
            (middle(accumulator(1)) + SIMD2(0.05, 0), 0.34),
            (middle(cutoff), 0.24),
            (middle(filter), 0.2),
            (middle(accumulator(2)), 0.2),
            (middle(envelope(2)), 0.3),
            (middle(decoders[0]), 0.45),
        ]
    }

    // MARK: The two chips

    /// The 6581 R3, from Tommi Lempinen's layers and his map of its blocks.
    static let mos6581 = SiliconDie(
        name: "6581", marking: ["MOS", "6581", "0483"], layers: "SIDDie6581R3", package: .ceramic,
        aspect: 14629.0 / 16820.0, map: SIMD2(1500, 1304), voiceX: fromX, voicePitch: 379,
        upperY: fromUpper, converterY: fromConverter, envelopeY: fromEnvelope,
        shared: [
            "decoder1": SIMD4(168, 122, 842, 172), "decoder2": SIMD4(882, 108, 1362, 158),
            "volume": SIMD4(632, 1130, 696, 1212), "filterMode": SIMD4(700, 1135, 788, 1212),
            "resonance": SIMD4(812, 1145, 896, 1212), "bypass": SIMD4(898, 1135, 990, 1212),
            "cutoff": SIMD4(994, 1145, 1330, 1275), "filter": SIMD4(692, 1215, 848, 1278),
            "outputAmplifier": SIMD4(566, 1236, 624, 1280), "outputScope": SIMD4(200, 1135, 630, 1232),
            "osc3Read": SIMD4(132, 340, 176, 632), "env3Read": SIMD4(132, 650, 176, 890),
        ],
        // Found on the metal layer; two couldn't be told from test
        // structures and are placed by eye.
        pads: [
            SIMD2(0.5552, 0.0492), SIMD2(0.4105, 0.0306), SIMD2(0.3533, 0.0306), SIMD2(0.2300, 0.0310),
            SIMD2(0.1019, 0.0317), SIMD2(0.0495, 0.0350), SIMD2(0.0438, 0.0963), SIMD2(0.0467, 0.2823),
            SIMD2(0.0467, 0.4387), SIMD2(0.0467, 0.5558), SIMD2(0.0457, 0.7232), SIMD2(0.0457, 0.8676),
            SIMD2(0.1019, 0.9475), SIMD2(0.2029, 0.9475), SIMD2(0.3267, 0.9475), SIMD2(0.5267, 0.9508),
            SIMD2(0.6467, 0.9508), SIMD2(0.7648, 0.9497), SIMD2(0.8848, 0.9497), SIMD2(0.9552, 0.8851),
            SIMD2(0.9552, 0.7495), SIMD2(0.9552, 0.6138), SIMD2(0.9552, 0.4256), SIMD2(0.9571, 0.3523),
            SIMD2(0.9571, 0.1204), SIMD2(0.8457, 0.0317), SIMD2(0.6880, 0.0310), SIMD2(0.6200, 0.0310),
        ])

    /// The 8580 R5, from Tommi Lempinen's layers; its blocks placed by
    /// eye on his photograph of the die (1400 × 1323 as measured).
    static let mos8580: SiliconDie = {
        let shared: [String: SIMD4<Float>] = [
            "decoder1": SIMD4(150, 168, 740, 200), "decoder2": SIMD4(800, 150, 1205, 200),
            "volume": SIMD4(205, 1125, 330, 1200), "filterMode": SIMD4(335, 1125, 470, 1200),
            "resonance": SIMD4(475, 1125, 640, 1200), "bypass": SIMD4(205, 1205, 400, 1265),
            "cutoff": SIMD4(955, 1125, 1200, 1210), "filter": SIMD4(690, 1120, 905, 1275),
            "outputAmplifier": SIMD4(410, 1205, 640, 1265), "outputScope": SIMD4(700, 1040, 1165, 1110),
            "osc3Read": SIMD4(135, 330, 190, 640), "env3Read": SIMD4(135, 650, 190, 830),
        ]
        // 25 found on the metal layer, three placed by eye, in no order yet.
        let found: [SIMD2<Float>] = [
            SIMD2(0.0800, 0.4673), SIMD2(0.0800, 0.4131), SIMD2(0.0768, 0.1682), SIMD2(0.0928, 0.0869),
            SIMD2(0.1503, 0.0666), SIMD2(0.2697, 0.0598), SIMD2(0.5437, 0.0598), SIMD2(0.8134, 0.0688),
            SIMD2(0.8678, 0.0564), SIMD2(0.9520, 0.2020), SIMD2(0.9520, 0.3860), SIMD2(0.9488, 0.4537),
            SIMD2(0.9488, 0.6174), SIMD2(0.9488, 0.7325), SIMD2(0.9488, 0.8465), SIMD2(0.8731, 0.9255),
            SIMD2(0.7644, 0.9255), SIMD2(0.6557, 0.9255), SIMD2(0.5480, 0.9255), SIMD2(0.3454, 0.9199),
            SIMD2(0.2527, 0.9199), SIMD2(0.1578, 0.9199), SIMD2(0.0821, 0.8330), SIMD2(0.0821, 0.6727),
            SIMD2(0.0789, 0.5745), SIMD2(0.6300, 0.0600), SIMD2(0.4350, 0.9250), SIMD2(0.0800, 0.2700),
        ]
        var die = SiliconDie(
            name: "8580", marking: ["MOS", "8580R5", "1286 S"], layers: "SIDDie8580R5", package: .plastic,
            aspect: 14202.0 / 15012.0, map: SIMD2(1400, 1323), voiceX: 205...522, voicePitch: 323,
            upperY: 215...628, converterY: 645...690, envelopeY: 695...1030, shared: shared, pads: found)
        die = SiliconDie(
            name: die.name, marking: die.marking, layers: die.layers, package: die.package, aspect: die.aspect,
            map: die.map, voiceX: die.voiceX, voicePitch: die.voicePitch, upperY: die.upperY, converterY: die.converterY,
            envelopeY: die.envelopeY, shared: shared, pads: die.ordered(found))
        return die
    }()

    /// `pads` in pin order: round the die the way the 6581's go, starting
    /// from the one nearest the output amplifier.
    private func ordered(_ pads: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let out = outputAmplifier
        let amplifier = SIMD2((out.x + out.z) / 2, (out.y + out.w) / 2)
        func angle(_ p: SIMD2<Float>) -> Float { atan2(p.y - 0.5, p.x - 0.5) }
        let round = pads.sorted { angle($0) > angle($1) }
        let first = round.indices.min { simd_length(round[$0] - amplifier) < simd_length(round[$1] - amplifier) } ?? 0
        return Array(round[first...] + round[..<first])
    }

    // MARK: What's lit

    /// A patch of the die that's lit: a block at work, or one bit of it.
    struct Cell {
        var place: Place
        /// 0–2 a voice, in its color; 3 the chip's shared parts.
        var owner: Int
        var level: Float
    }

    /// `count` even slices of a block along its longer side, the first at
    /// its top or left.
    func slices(_ place: Place, count: Int) -> [Place] {
        let wide = place.z - place.x, tall = (place.w - place.y) * aspect
        return (0..<count).map { i in
            let a = Float(i) / Float(count), b = Float(i + 1) / Float(count)
            // A hair between two, so they read as separate bits.
            let gap = 0.12 / Float(count)
            return tall >= wide
                ? SIMD4(place.x, place.y + (place.w - place.y) * (a + gap), place.z, place.y + (place.w - place.y) * (b - gap))
                : SIMD4(place.x + wide * (a + gap), place.y, place.x + wide * (b - gap), place.w)
        }
    }

    /// Everything lit for `state`: each block faintly by how hard it's
    /// working, and each of its bits brightly where it's 1. `clock` runs
    /// the counters whose value changes faster than the feed reports
    /// (the accumulators, the noise registers).
    func cells(_ state: ChipState, clock: Double) -> [Cell] {
        var cells: [Cell] = []
        func block(_ place: Place, _ owner: Int, _ level: Float) {
            if level > 0.01 { cells.append(Cell(place: place, owner: owner, level: level * 0.28)) }
        }
        func bits(_ value: UInt32, _ count: Int, in place: Place, _ owner: Int, _ level: Float = 1) {
            for (i, slice) in slices(place, count: count).enumerated() where value >> UInt32(count - 1 - i) & 1 == 1 {
                cells.append(Cell(place: slice, owner: owner, level: level))
            }
        }
        var filterLevel: Float = 0, bypassLevel: Float = 0, loudest: Float = 0
        for v in 0..<3 {
            let voice = state.voices[v]
            let level = voice.level
            let running: Float = voice.frequency > 0 ? 0.3 + 0.7 * level : 0
            // The accumulator adds the frequency to itself every cycle of
            // the chip's clock: where it is now, give or take its start.
            let phase = UInt32(truncatingIfNeeded: UInt64(clock * 985_248) &* UInt64(voice.frequency)) & 0xFF_FFFF
            block(accumulator(v), v, running)
            if voice.frequency > 0 { bits(phase, 24, in: accumulator(v), v, running) }
            let pulse = voice.waveform & 0x4 != 0
            block(pulseWidth(v), v, pulse ? running : 0)
            bits(UInt32(voice.pulseWidth), 12, in: pulseWidth(v), v, pulse ? 1 : 0.25)
            block(triangleSaw(v), v, voice.waveform & 0x3 != 0 ? running : 0)
            if voice.waveform & 0x8 != 0 {
                // The noise register shifts on with the accumulator.
                var shifted = UInt32(truncatingIfNeeded: (phase >> 19) &* 2_654_435_761) ^ UInt32(v + 1) &* 0x9E37
                shifted ^= shifted >> 7
                block(noise(v), v, running)
                bits(shifted & 0x7F_FFFF, 23, in: noise(v), v, running)
            }
            block(selector(v), v, voice.waveform != 0 ? 0.4 + 0.6 * level : 0)
            let control = UInt32(voice.gate ? 1 : 0) | UInt32(voice.sync ? 2 : 0) | UInt32(voice.ring ? 4 : 0) | UInt32(voice.waveform) << 4
            bits(control, 8, in: self.control(v), v)
            block(waveformControl(v), v, level)
            block(waveformDAC(v), v, level)
            if let sample = voice.samples.last {
                bits(UInt32(max(0, min(4095, (sample + 1) / 2 * 4095))), 12, in: waveformDAC(v), v, 0.4 + 0.6 * level)
            }
            block(ringMod(v), v, voice.ring ? 3 : 0)
            block(sync(v), v, voice.sync ? 3 : 0)
            block(envelopeDAC(v), v, level)
            bits(UInt32(level * 255), 8, in: envelopeDAC(v), v, 0.5 + 0.5 * level)
            block(envelope(v), v, voice.gate ? 0.4 + 0.6 * level : level * 0.8)
            let adsr = UInt32(voice.attack) << 12 | UInt32(voice.decay) << 8 | UInt32(voice.sustain) << 4 | UInt32(voice.release)
            bits(adsr, 16, in: envelope(v), v, voice.gate ? 0.55 : 0.2)
            let heard = state.isHeard(v) ? level : 0
            if voice.filtered { filterLevel = max(filterLevel, level) } else { bypassLevel = max(bypassLevel, heard) }
            loudest = max(loudest, heard)
        }
        // The address decoder: the register being written, one of 25.
        for (i, slice) in slices(decoders[0], count: 14).enumerated() where state.written[i] > 0.03 {
            cells.append(Cell(place: slice, owner: i < 7 ? 0 : 1, level: state.written[i]))
        }
        for (i, slice) in slices(decoders[1], count: 11).enumerated() where state.written[14 + i] > 0.03 {
            cells.append(Cell(place: slice, owner: i < 7 ? 2 : 3, level: state.written[14 + i]))
        }
        let volumeLevel = Float(state.volume) / 15
        block(volume, 3, volumeLevel * (0.3 + 0.7 * loudest))
        bits(UInt32(state.volume), 4, in: volume, 3, 0.6)
        let anyMode = state.lowPass || state.bandPass || state.highPass
        block(filterMode, 3, anyMode ? 0.4 + 0.6 * filterLevel : 0)
        let mode = UInt32(state.lowPass ? 8 : 0) | UInt32(state.bandPass ? 4 : 0) | UInt32(state.highPass ? 2 : 0) | UInt32(state.voice3Off ? 1 : 0)
        bits(mode, 4, in: filterMode, 3, 0.6)
        bits(UInt32(state.resonance), 4, in: resonance, 3, 0.4 + 0.6 * filterLevel)
        block(bypass, 3, bypassLevel)
        block(cutoff, 3, anyMode ? 0.3 + 0.7 * filterLevel : 0)
        bits(UInt32(state.cutoff), 11, in: cutoff, 3, anyMode ? 0.45 + 0.55 * filterLevel : 0.2)
        block(filter, 3, filterLevel * 2)
        block(outputAmplifier, 3, loudest * volumeLevel * 3)
        block(osc3Read, 2, state.voices[2].level * 0.5)
        block(env3Read, 2, state.voices[2].level * 0.5)
        return cells
    }

    /// A signal's way across the die, for the beads of light that run
    /// along it: from a voice's converter to the filter or past it, and
    /// from there to the output. Drawn in the gaps between blocks.
    struct Flow {
        var points: [SIMD2<Float>]
        var owner: Int
        var level: Float
    }

    func flows(_ state: ChipState) -> [Flow] {
        func middle(_ p: Place) -> SIMD2<Float> { SIMD2((p.x + p.z) / 2, (p.y + p.w) / 2) }
        var flows: [Flow] = []
        var filterLevel: Float = 0, loudest: Float = 0
        // On the layers the voices' converters face the filter's side of
        // the die: which side that is tells which way "down" a voice runs.
        let filterSide: Float = middle(filter).y < 0.5 ? -1 : 1
        func toward(_ p: Place) -> Float { filterSide < 0 ? p.y : p.w }
        for v in 0..<3 {
            let voice = state.voices[v]
            let heard = state.isHeard(v) ? voice.level : 0
            // Out of the waveform converter, past the envelope's, down the
            // voice's edge to the channel between the voices and the filter.
            let converter = waveformDAC(v), generator = envelope(v)
            let edge = max(converter.z, generator.z) + 0.004
            let lane = toward(generator) + filterSide * (0.004 + 0.003 * Float(v))
            var points = [SIMD2(middle(converter).x, toward(converter)), SIMD2(middle(converter).x, toward(envelopeDAC(v))),
                          SIMD2(edge, toward(envelopeDAC(v))), SIMD2(edge, lane)]
            if voice.filtered {
                filterLevel = max(filterLevel, voice.level)
                points += [SIMD2(middle(filter).x, lane), SIMD2(middle(filter).x, filterSide < 0 ? filter.w : filter.y)]
                flows.append(Flow(points: points, owner: v, level: voice.level))
            } else {
                points += [SIMD2(middle(bypass).x, lane), middle(bypass), SIMD2(middle(volume).x, middle(bypass).y), middle(volume)]
                flows.append(Flow(points: points, owner: v, level: heard))
            }
            loudest = max(loudest, heard)
        }
        if filterLevel > 0.01 {
            flows.append(Flow(points: [middle(filter), SIMD2(middle(volume).x, middle(filter).y), middle(volume)], owner: 3, level: filterLevel))
        }
        // From the volume to the output amplifier and its pad.
        let out = pads[0]
        flows.append(Flow(points: [middle(volume), SIMD2(middle(outputAmplifier).x, middle(volume).y), middle(outputAmplifier),
                                   SIMD2(out.x, middle(outputAmplifier).y), out],
                          owner: 3, level: loudest * Float(state.volume) / 15))
        return flows
    }
}
