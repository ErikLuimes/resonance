import Foundation
import ImageIO
import SceneKit
import simd
import SwiftUI
import Testing
import UniformTypeIdentifiers
import PhosphorCore
@testable import Resonance

private let rate: Float = 44_784

private func sine(_ hz: Float, amplitude: Float = 0.5, count: Int = FineSpectrum.samples) -> [Float] {
    (0..<count).map { amplitude * sin(2 * .pi * hz * Float($0) / rate) }
}

/// Saves a rendered frame where it can be looked at, and says where.
private func save(_ image: CGImage, as name: String) {
    let url = URL(filePath: NSTemporaryDirectory()).appending(path: name)
    if let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(out, image, nil)
        CGImageDestinationFinalize(out)
    }
    print("Rendered \(url.path)")
}

/// How many of an image's color bytes are brighter than `level`.
private func lit(_ image: CGImage, above level: UInt8 = 60) -> Int {
    guard let data = image.dataProvider?.data as Data? else { return 0 }
    return data.enumerated().filter { $0.offset % 4 != 3 && $0.element > level }.count
}

/// Three voices: a slow one, one on every half second, and a silent one.
private let track = NoteTrack(voices: [
    [.init(start: 1, end: 1.5, midi: 60), .init(start: 4, end: 5, midi: 72)],
    (0..<20).map { .init(start: Double($0) / 2, end: Double($0) / 2 + 0.4, midi: Float(48 + $0 % 5)) },
    [],
])

struct NoteTrackTests {
    @Test func theBallLandsOnEachNoteExactlyAsItStarts() throws {
        for note in track.voices[1] {
            let ball = try #require(track.ball(voice: 1, at: note.start))
            #expect(ball.height == 0)
            #expect(ball.place == track.place(note.midi, voice: 1))
            #expect(ball.sinceLanding == 0)
        }
    }

    @Test func betweenTwoNotesItIsInTheAirAndPartWayAcross() throws {
        let ball = try #require(track.ball(voice: 1, at: 0.75))
        let from = track.place(49, voice: 1), to = track.place(50, voice: 1)
        #expect(ball.height > 0)
        #expect(ball.place > from && ball.place < to)
    }

    @Test func withTimeToSpareItWaitsOnTheNoteThenHops() throws {
        // Voice 1's notes are 3 s apart: the hop takes the last 0.9 s.
        let waiting = try #require(track.ball(voice: 0, at: 2.5))
        #expect(waiting.height == 0)
        #expect(waiting.place == track.place(60, voice: 0))
        let hopping = try #require(track.ball(voice: 0, at: 3.6))
        #expect(hopping.height > 0)
    }

    @Test func itDropsOntoTheFirstNoteAndStaysOnTheLast() throws {
        let before = try #require(track.ball(voice: 0, at: 0.6))
        #expect(before.height > 0)
        #expect(before.sinceLanding == nil)
        let after = try #require(track.ball(voice: 0, at: 30))
        #expect(after.height == 0)
        #expect(after.place == track.place(72, voice: 0))
    }

    @Test func aVoiceWithNoNotesHasNoBall() {
        #expect(track.ball(voice: 2, at: 1) == nil)
    }

    @Test func aQuickHopIsLowerThanASlowOne() throws {
        let quick = NoteTrack(voices: [[.init(start: 0, end: 0.1, midi: 60), .init(start: 0.1, end: 0.2, midi: 62)]])
        let slow = NoteTrack(voices: [[.init(start: 0, end: 0.1, midi: 60), .init(start: 0.8, end: 1, midi: 62)]])
        let low = try #require(quick.ball(voice: 0, at: 0.05)).height
        let high = try #require(slow.ball(voice: 0, at: 0.4)).height
        #expect(low < high)
    }

    @Test func notesInAWindowIncludeOneStillSounding() {
        let notes = track.notes(voice: 0, in: 4.5...6)
        #expect(notes.map(\.midi) == [72])
        #expect(track.notes(voice: 0, in: 2...3).isEmpty)
    }

    @Test func aStaffSpansAtLeastAnOctave() {
        let range = track.ranges[1]
        #expect(range.upperBound - range.lowerBound >= 12)
        #expect((0...1).contains(track.place(50, voice: 1)))
    }

    @Test func aTrackerSongBecomesNotesWithTheirLengths() {
        func cell(_ note: String? = nil, off: Bool = false) -> TrackerCell {
            TrackerCell(note: note, instrument: 0, off: off, effect: .none)
        }
        func row(_ frame: UInt32, _ cells: [TrackerCell]) -> TrackerRow {
            TrackerRow(frame: frame, voices: cells, cutoff: 0, resonance: 0, filterRouting: 0, filterMode: 0)
        }
        let song = TrackerSong(isPal: true, frameRate: 50, framesPerRow: 5, onGrid: 1, hasGrid: true, chips: 1, rows: [
            row(0, [cell("C-4"), cell(), cell("A#3")]),
            row(5, [cell(), cell("F#5"), cell()]),
            row(10, [cell("D-4"), cell(), cell(off: true)]),
            row(15, [cell(), cell(), cell()]),
        ], instruments: [])
        let made = NoteTrack(song)
        #expect(made.voices[0] == [.init(start: 0, end: 0.2, midi: 60), .init(start: 0.2, end: 0.4, midi: 62)])
        #expect(made.voices[1] == [.init(start: 0.1, end: 0.4, midi: 78)])
        #expect(made.voices[2] == [.init(start: 0, end: 0.2, midi: 58)])
    }
}

struct SmoothPlayheadTests {
    /// The feed's reports: the end of the 20 ms frame being heard.
    private func heard(_ t: Double) -> Double { (t / 0.02).rounded(.down) * 0.02 + 0.02 }

    @Test func itRunsSmoothlyWithinTheFrameBeingHeard() {
        var playhead = SmoothPlayhead()
        var last = -Double.infinity
        var steps: [Double] = []
        for frame in 0..<240 {
            let now = Double(frame) / 60
            let time = playhead.update(heard: heard(now), now: now)
            #expect(time <= heard(now) && time >= heard(now) - SmoothPlayhead.frame)
            if frame > 5 { steps.append(time - last) }
            last = time
        }
        // Every display frame moves it on by about a display frame.
        #expect(steps.allSatisfy { $0 > 0.01 && $0 < 0.024 })
    }

    @Test func itStopsWhenTheReportsStopAndJumpsOnASeek() {
        var playhead = SmoothPlayhead()
        var now = 0.0
        for _ in 0..<60 {
            now += 1.0 / 60
            _ = playhead.update(heard: heard(now), now: now)
        }
        let paused = heard(now)
        var held: [Double] = []
        for _ in 0..<60 {
            now += 1.0 / 60
            held.append(playhead.update(heard: paused, now: now))
        }
        #expect(held.last == paused)
        #expect(playhead.update(heard: 90, now: now + 0.016) > 89.9)
        // Stopped: it stays where it was.
        #expect(playhead.update(heard: nil, now: now + 0.032) > 89.9)
    }
}

struct NowPlayingLineupTests {
    @Test func aStoredLineupComesBackInListedOrder() {
        #expect(NowPlayingVisual.lineup(from: "terrain,halo,notes") == [.halo, .notes, .terrain])
    }

    @Test func nothingUsableGivesTheDefault() {
        #expect(NowPlayingVisual.lineup(from: "") == NowPlayingVisual.defaultLineup)
        #expect(NowPlayingVisual.lineup(from: "fireworks,,") == NowPlayingVisual.defaultLineup)
    }

    @Test func itHoldsAtMostThree() {
        let all = NowPlayingVisual.stored(NowPlayingVisual.allCases)
        #expect(NowPlayingVisual.lineup(from: all).count == NowPlayingVisual.lineupSize)
    }

    @Test func theDefaultFitsAndStoresBothWays() {
        let lineup = NowPlayingVisual.defaultLineup
        #expect(lineup.count <= NowPlayingVisual.lineupSize)
        #expect(NowPlayingVisual.lineup(from: NowPlayingVisual.stored(lineup)) == NowPlayingVisual.allCases.filter(lineup.contains))
    }

    @Test func chipAndRastersAreNotOfferedAndStoredOnesAreDropped() {
        #expect(!NowPlayingVisual.offered.contains(.chip) && !NowPlayingVisual.offered.contains(.rasters))
        #expect(NowPlayingVisual.offered.count == 12)
        #expect(NowPlayingVisual.lineup(from: "rasters,terrain") == [.terrain])
        #expect(NowPlayingVisual.lineup(from: "chip,halo") == [.halo])
        #expect(NowPlayingVisual.lineup(from: "chip") == NowPlayingVisual.defaultLineup)
    }
}

struct FineSpectrumTests {
    private func settled(_ voices: [[Float]], bands: Int = 160) -> FineSpectrum {
        let spectrum = FineSpectrum(bands: bands)
        for frame in 0..<60 {
            spectrum.update(voices: voices, sampleRate: rate, at: Date(timeIntervalSinceReferenceDate: Double(frame) / 60))
        }
        return spectrum
    }

    private func band(_ hz: Float, of bands: Int = 160) -> Int {
        Int(FineSpectrum.position(of: hz) * Float(bands))
    }

    @Test func aBassNoteIsANarrowPeakAtItsPitch() {
        let spectrum = settled([sine(55)])
        let levels = Array(spectrum.levels[0..<160])
        let peak = levels.indices.max { levels[$0] < levels[$1] }!
        #expect(abs(peak - band(55)) <= 1)
        // −6 dB for a sine of amplitude 0.5, on the −60…0 dB scale.
        #expect(abs(levels[peak] - 0.9) < 0.05)
        // An octave up, it's at least 40 dB down: the 2048-sample FFT alone
        // would still be within 15 dB there.
        #expect(levels[band(110)] < levels[peak] - 40.0 / 60)
    }

    @Test func aHighNoteIsReadFromTheShortFFT() {
        let spectrum = settled([[], sine(2000)])
        let levels = Array(spectrum.levels[160..<320])
        let peak = levels.indices.max { levels[$0] < levels[$1] }!
        #expect(abs(peak - band(2000)) <= 1)
        #expect(spectrum.levels[0..<160].allSatisfy { $0 == 0 })
    }

    @Test func peaksHoldWhileLevelsFall() {
        let spectrum = settled([sine(440)])
        let at = band(440)
        let before = spectrum.peaks[at]
        for frame in 60..<90 {
            spectrum.update(voices: [], sampleRate: rate, at: Date(timeIntervalSinceReferenceDate: Double(frame) / 60))
        }
        #expect(spectrum.levels[at] < before / 2)
        #expect(spectrum.peaks[at] > before - 0.2)
    }

    @Test func theMixIsAtLeastTheLoudestVoice() {
        let spectrum = settled([sine(440), sine(440), sine(1000)])
        let mix = spectrum.mix()
        let at = band(440)
        #expect(mix[at] > spectrum.levels[at])
        #expect(mix[at] < spectrum.levels[at] + 0.1)
    }

    @Test func positionsAndFrequenciesAgree() {
        for hz: Float in [30, 440, 16_000] {
            #expect(abs(FineSpectrum.frequency(at: FineSpectrum.position(of: hz)) - hz) < hz * 0.001)
        }
    }
}

struct VisualizerQualityTests {
    private let frame = VisualizerQuality.frame

    /// A second of frames that each took the GPU `share` of a frame.
    private func run(_ quality: VisualizerQuality, share: Double, from start: Double, seconds: Double = 1) {
        for n in 0..<Int(seconds * 60) { quality.record(gpuSeconds: share * frame, at: start + Double(n) / 60) }
    }

    @Test func aMacThatKeepsUpStaysAtFullQuality() {
        let quality = VisualizerQuality(startingAt: .full)
        run(quality, share: 0.3, from: 0, seconds: 30)
        #expect(quality.level == .full)
        #expect(quality.framesPerSecond == 60)
    }

    @Test func oneThatCannotDropsAStepAtATimeToHalfTheFrames() {
        let quality = VisualizerQuality(startingAt: .full)
        run(quality, share: 0.9, from: 0)
        #expect(quality.level == .reduced)
        // The step helped, but not enough.
        run(quality, share: 0.7, from: 1, seconds: 3)
        #expect(quality.level == .low)
        #expect(quality.framesPerSecond == 30)
        run(quality, share: 0.9, from: 4, seconds: 5)
        #expect(quality.level == .low)
    }

    @Test func itRisesOnlyWithPlentyOfRoomAndAfterAWhile() {
        let quality = VisualizerQuality(startingAt: .reduced)
        run(quality, share: 0.3, from: 0, seconds: 20)
        #expect(quality.level == .reduced)
        run(quality, share: 0.1, from: 20, seconds: 2)
        #expect(quality.level == .full)
    }

    @Test func aStepUpThatCostsThreeTimesAsMuchDoesNotBounceBack() {
        let quality = VisualizerQuality(startingAt: .reduced)
        run(quality, share: 0.14, from: 0, seconds: 10)
        #expect(quality.level == .full)
        run(quality, share: 0.14 * 3, from: 10, seconds: 30)
        #expect(quality.level == .full)
    }

    @Test func savingPowerKeepsItAStepDown() {
        let quality = VisualizerQuality(startingAt: .full) { .reduced }
        #expect(quality.level == .reduced)
        run(quality, share: 0.05, from: 0, seconds: 30)
        #expect(quality.level == .reduced)
    }

    @Test func eachFerrofluidLevelIsCoarser() {
        let levels: [VisualizerQuality.Level] = [.full, .reduced, .low]
        let work = levels.map { level -> Float in
            let detail = FerroRenderer.detail(level)
            return Float(detail.steps) / (detail.pointsPerSample * detail.pointsPerSample)
        }
        #expect(work[0] > work[1] * 2.5 && work[1] > work[2] * 2)
        // A step up never costs more than the gap between the thresholds allows.
        #expect(work[0] / work[1] < Float(VisualizerQuality.tooMuch / VisualizerQuality.room))
        #expect(work[1] / work[2] < Float(VisualizerQuality.tooMuch / VisualizerQuality.room))
    }
}

struct ChipTests {
    @Test func theDieHasItsTwentyEightPinsInPackageOrder() {
        #expect(ChipDie.pins.count == 28)
        #expect(ChipDie.pins[0] == "CAP1A" && ChipDie.pins[13] == "GND" && ChipDie.pins[26] == "AUDIO" && ChipDie.pins[27] == "VDD")
        // Seven pads a side, each inside the die, each wire landing outside it.
        for pin in 0..<28 {
            let pad = ChipDie.pad(pin).center
            #expect((0...1).contains(pad.x) && (0...1).contains(pad.y))
            #expect(!ChipDie.die.contains(ChipDie.lead(pin)))
        }
        #expect(Set((0..<28).map { ChipDie.pad($0).center.x * 1000 + ChipDie.pad($0).center.y }).count == 28)
    }

    @Test func everyRegisterBitHasACellInsideTheRegisterFile() {
        let cells = ChipDie.registerCells()
        #expect(cells.count == 29)
        #expect(cells.allSatisfy { $0.count == 8 && $0.allSatisfy(ChipDie.registers.contains) })
        // Bit 7 is at the top.
        #expect(cells[0][7].minY < cells[0][0].minY)
    }

    @Test func aWrittenRegisterFlashesAndFades() {
        var state = ChipState()
        var registers = [UInt8](repeating: 0, count: 29)
        registers[4] = 0x41
        state.write(registers, dt: 0.016)
        #expect(state.registers[4] == 0x41)
        #expect(state.written[4] == 1)
        #expect(state.written[5] == 0)
        for _ in 0..<60 { state.write(registers, dt: 0.016) }
        #expect(state.written[4] < 0.01)
    }

    @Test func theFilterCurveFollowsItsModes() {
        var state = ChipState()
        state.cutoff = 1024
        #expect(state.response(at: 0.5) == -60)
        state.lowPass = true
        #expect(abs(state.response(at: 0.1)) < 1)
        #expect(state.response(at: 0.9) < -20)
        state.lowPass = false
        state.highPass = true
        #expect(state.response(at: 0.1) < -20)
        #expect(abs(state.response(at: 0.9)) < 1)
        // Resonance lifts it at the cutoff.
        let flat = state.response(at: 0.5)
        state.resonance = 15
        #expect(state.response(at: 0.5) > flat + 6)
    }

    @Test func voiceThreeCanBeCutFromTheOutput() {
        var state = ChipState()
        #expect(state.isHeard(2))
        state.voice3Off = true
        #expect(!state.isHeard(2))
        #expect(state.isHeard(0))
        state.voices[2].filtered = true
        #expect(state.isHeard(2))
    }
}

struct RasterShowTests {
    @Test func higherNotesAreHigherOnTheScreen() {
        #expect(RasterShow.line(of: 72) < RasterShow.line(of: 48))
        #expect(RasterShow.lines.contains(RasterShow.line(of: 0)))
        #expect(RasterShow.lines.contains(RasterShow.line(of: 127)))
    }

    @Test func aVoiceIsABarOnItsNotesLineAndLeavesEchoes() {
        var show = RasterShow()
        for _ in 0..<30 { show.update(voices: [.init(level: 0.8, midi: 60)], dt: 1.0 / 60) }
        #expect(show.bars.count == 1)
        #expect(abs(show.bars[0].line - RasterShow.line(of: 60)) < 0.5)
        for _ in 0..<30 { show.update(voices: [.init(level: 0.8, midi: 72)], dt: 1.0 / 60) }
        // The old note's bar, fading, behind the new one.
        #expect(show.bars.count == 2)
        #expect(abs(show.bars[0].line - RasterShow.line(of: 60)) < 0.5)
        #expect(show.bars[0].brightness < show.bars[1].brightness)
        #expect(abs(show.bars[1].line - RasterShow.line(of: 72)) < 0.5)
        for _ in 0..<120 { show.update(voices: [.init(level: 0.8, midi: 72)], dt: 1.0 / 60) }
        #expect(show.bars.count == 1)
    }

    @Test func aDrumFlashesTheBorderAndHasNoBar() {
        var show = RasterShow()
        show.update(voices: [.init(level: 1, midi: 90, isNoise: true)], dt: 1.0 / 60)
        #expect(show.flash == 1)
        #expect(show.bars.isEmpty)
        for _ in 0..<30 { show.update(voices: [.init(level: 1, midi: 90, isNoise: true)], dt: 1.0 / 60) }
        #expect(show.flash < 0.01)
    }
}

struct SiliconDieTests {
    private let dies = [SiliconDie.mos6581, .mos8580]

    private func working() -> ChipState {
        var state = ChipState()
        state.voices[1] = .init(frequency: 0x2000, pulseWidth: 0x0F0, waveform: 4, gate: true, attack: 3, decay: 5, sustain: 9,
                                release: 2, level: 1, samples: sine(440, count: 1024))
        state.volume = 15
        return state
    }

    @Test func everyBlockAndPadIsOnItsDie() {
        for die in dies {
            let places = (0..<3).flatMap { v in
                [die.accumulator(v), die.pulseWidth(v), die.noise(v), die.envelope(v), die.waveformDAC(v), die.envelopeDAC(v)]
            } + die.decoders + [die.cutoff, die.filter, die.volume, die.outputAmplifier, die.outputScope, die.bypass]
            for place in places {
                #expect(place.x < place.z && place.y < place.w)
                #expect(place.x >= 0 && place.z <= 1 && place.y >= 0 && place.w <= 1)
            }
            #expect(die.pads.count == 28)
            #expect(die.pads.allSatisfy { min($0.x, $0.y, 1 - $0.x, 1 - $0.y) < 0.1 })
            // The first pad is the audio output's: the nearest of them to the output amplifier.
            let out = die.outputAmplifier
            let amplifier = SIMD2((out.x + out.z) / 2, (out.y + out.w) / 2)
            let nearest = die.pads.map { simd_length($0 - amplifier) }.min() ?? 0
            #expect(simd_length(die.pads[0] - amplifier) < nearest + 0.12)
            #expect(die.sights.allSatisfy { (0...1).contains($0.center.x) && (0...1).contains($0.center.y) })
        }
        #expect(ChipDie.pins[SiliconDie.pin(ofPad: 0)] == "AUDIO")
        #expect(Set((0..<28).map(SiliconDie.pin(ofPad:))).count == 28)
        #expect((0..<28).allSatisfy { SiliconDie.pad(ofPin: SiliconDie.pin(ofPad: $0)) == $0 })
    }

    @Test func theTwoChipsAreDifferentDiesInDifferentPackages() {
        #expect(SiliconDie.mos6581.package == .ceramic && SiliconDie.mos8580.package == .plastic)
        #expect(SiliconDie.mos6581.layers != SiliconDie.mos8580.layers)
        #expect(SiliconDie.mos6581.aspect != SiliconDie.mos8580.aspect)
        #expect(SiliconDie.mos6581.marking.contains("6581") && SiliconDie.mos8580.marking.contains("8580R5"))
        // The 8580's voices are the 6581's, fitted to its own die: in the same order, not in the same place.
        #expect(SiliconDie.mos8580.accumulator(0) != SiliconDie.mos6581.accumulator(0))
        for die in dies { #expect(die.accumulator(0).x > die.accumulator(1).x && die.accumulator(1).x > die.accumulator(2).x) }
    }

    @Test func aBlocksBitsAreEvenSlicesInsideIt() {
        for die in dies {
            let block = die.accumulator(0)
            let slices = die.slices(block, count: 24)
            #expect(slices.count == 24)
            for (i, slice) in slices.enumerated() {
                #expect(slice.x >= block.x && slice.z <= block.z && slice.y >= block.y && slice.w <= block.w)
                if i > 0 { #expect(slice.y > slices[i - 1].w || slice.x > slices[i - 1].z) }
            }
        }
    }

    @Test func aSilentChipIsNearlyDarkAndAVoiceLightsOnlyItsOwn() {
        for die in dies {
            let quiet = die.cells(ChipState(), clock: 1)
            #expect(quiet.allSatisfy { $0.level <= 0.25 })
            let lit = die.cells(working(), clock: 1).filter { $0.level > 0.5 }
            #expect(lit.contains { $0.owner == 1 })
            // Its own bits, and the chip's shared parts it passes through: no other voice's.
            #expect(!lit.contains { $0.owner == 0 || $0.owner == 2 })
        }
    }

    @Test func thePulseWidthsBitsAreTheRegisters() {
        for die in dies {
            let slices = die.slices(die.pulseWidth(1), count: 12)
            let lit = die.cells(working(), clock: 1).filter { cell in slices.contains { $0 == cell.place } && cell.level > 0.5 }
            // 0x0F0: four bits.
            #expect(lit.count == 4)
        }
    }

    @Test func aVoicesSignalRunsToTheFilterOnlyWhenRoutedThere() {
        for die in dies {
            var state = working()
            let past = die.flows(state).first { $0.owner == 1 }
            state.voices[1].filtered = true
            let through = die.flows(state).first { $0.owner == 1 }
            #expect(past?.points.last != through?.points.last)
            #expect(die.flows(state).contains { $0.owner == 3 && $0.level > 0.5 })
            // The last leg ends on the audio output's pad.
            #expect(die.flows(state).last?.points.last == die.pads[0])
        }
    }
}

struct NimbusVoicesTests {
    private func run(_ voices: inout NimbusVoices, _ playing: [InkJets.Voice], seconds: Double) {
        for _ in 0..<Int(seconds * 60) { voices.update(voices: playing, dt: 1.0 / 60) }
    }

    @Test func aBillowFollowsItsVoicesLevelClosely() {
        var voices = NimbusVoices()
        run(&voices, [.init(level: 1, midi: 60)], seconds: 0.5)
        #expect(voices.swell.x > 0.95)
        #expect(voices.swell.y == 0)
        // A quarter of a second of quiet and it's well down.
        run(&voices, [], seconds: 0.25)
        #expect(voices.swell.x < 0.85)
        run(&voices, [], seconds: 4)
        #expect(voices.swell.x < 0.01)
    }

    @Test func aNewNoteKicksItsBillowAndItsGlow() {
        var voices = NimbusVoices()
        run(&voices, [.init(level: 0.5, midi: 60)], seconds: 2)
        let held = (voices.swell.x, voices.glow.x)
        voices.update(voices: [.init(level: 0.5, midi: 64)], dt: 1.0 / 60)
        #expect(voices.swell.x > held.0 + 0.25)
        #expect(voices.glow.x > held.1 + 0.3)
        #expect(voices.swell.y == 0 && voices.glow.y == 0)
    }

    @Test func aBillowRisesWithItsVoicesPitch() {
        var voices = NimbusVoices()
        run(&voices, [.init(level: 0.5, midi: 36), .init(level: 0.5, midi: 84)], seconds: 2)
        #expect(voices.lift.x < -0.5 && voices.lift.y > 0.5)
        // A drum has no pitch: its billow stays where it was.
        let before = voices.lift.x
        run(&voices, [.init(level: 1, midi: 100, isNoise: true)], seconds: 0.5)
        #expect(voices.lift.x == before)
    }

    @Test func theBallsRoamPartingAndMeetingAndStayInTheCloudsReach() {
        let voices = NimbusVoices()
        var nearest = Float.infinity, farthest: Float = 0
        for step in 0..<600 {
            let balls = (0..<6).map { voices.ball($0, churn: Double(step) * 0.5) }
            for ball in balls { #expect(simd_length(SIMD3(ball.x, ball.y, ball.z)) + ball.w < 5.6) }
            let apart = simd_length(SIMD3(balls[0].x, balls[0].y, balls[0].z) - SIMD3(balls[1].x, balls[1].y, balls[1].z))
            nearest = min(nearest, apart)
            farthest = max(farthest, apart)
        }
        // Two of them are sometimes on top of each other and sometimes far apart.
        #expect(nearest < 1 && farthest > 3.5)
    }

    @Test func theCloudChurnsFasterTheLouderItIs() {
        var quiet = NimbusVoices(), loud = NimbusVoices()
        run(&quiet, [], seconds: 2)
        run(&loud, (0..<3).map { _ in .init(level: 1, midi: 60) }, seconds: 2)
        // It still drifts in a silence, at about a seventh of the pace.
        #expect(loud.churn > quiet.churn * 5)
        #expect(quiet.churn > 0)
    }
}

struct InkJetsTests {
    private let colors = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]

    @Test func aSilentVoicePoursNothing() {
        var jets = InkJets()
        let pours = jets.pours(voices: [.init(level: 0, midi: 60), .init(level: 0.5, midi: 48)], colors: colors, aspect: 1.5, clock: 0)
        #expect(pours.count == 1)
        #expect(pours[0].color == colors[1])
        #expect(pours[0].flow == 0.5)
    }

    @Test func aNoteStartIsAPuffAndHoldingItIsNot() {
        var jets = InkJets()
        func burst(_ midi: Float, level: Float = 0.8) -> Float? {
            jets.pours(voices: [.init(level: level, midi: midi)], colors: colors, aspect: 1.5, clock: 0).first?.burst
        }
        #expect(burst(60) == 1)
        #expect(burst(60) == 0)
        #expect(burst(60.2) == 0)
        #expect(burst(64) == 1)
        #expect(burst(64, level: 0) == nil)
        #expect(burst(64) == 1)
    }

    @Test func streamsStartOnTheRingAndAimAcrossIt() {
        var jets = InkJets()
        // The middle of the octave aims straight at the ring's middle.
        let voices = (0..<3).map { _ in InkJets.Voice(level: 1, midi: 66) }
        let pours = jets.pours(voices: voices, colors: colors, aspect: 1, clock: 0)
        #expect(pours.count == 3)
        for pour in pours {
            let out = pour.position - InkJets.center
            #expect(abs(simd_length(out) - InkJets.radius) < 0.001)
            #expect(abs(simd_length(pour.direction) - 1) < 0.001)
            #expect(simd_dot(simd_normalize(out), pour.direction) < -0.99)
        }
        // Another note in the octave steers it off the middle.
        let steered = jets.pours(voices: [.init(level: 1, midi: 61)], colors: colors, aspect: 1, clock: 0)[0]
        #expect(simd_dot(simd_normalize(steered.position - InkJets.center), steered.direction) > -0.9)
    }
}

struct FerroFieldTests {
    @Test func aVoicePullsWhileItSoundsAndLetsGoSlowly() {
        var field = FerroField()
        for frame in 0..<30 { field.update(voices: [.init(level: 0.8, midi: 60)], dt: 1.0 / 60, clock: Double(frame) / 60) }
        #expect(abs(field.magnets[0].pull - 0.8) < 0.05)
        #expect(field.magnets[1].pull == 0)
        for frame in 30..<36 { field.update(voices: [], dt: 1.0 / 60, clock: Double(frame) / 60) }
        // A tenth of a second on, most of it is still there.
        #expect(field.magnets[0].pull > 0.5)
        for frame in 36..<150 { field.update(voices: [], dt: 1.0 / 60, clock: Double(frame) / 60) }
        #expect(field.magnets[0].pull < 0.02)
    }

    @Test func aNewNoteKicksAndSlidesTheMagnet() {
        var field = FerroField()
        for _ in 0..<60 { field.update(voices: [.init(level: 0.5, midi: 60)], dt: 1.0 / 60, clock: 0) }
        let near = simd_length(field.magnets[0].position)
        #expect(abs(near - FerroField.nearest) < 0.01)
        field.update(voices: [.init(level: 0.5, midi: 71)], dt: 1.0 / 60, clock: 0)
        #expect(field.magnets[0].pull > 0.7)
        for _ in 0..<60 { field.update(voices: [.init(level: 0.5, midi: 71)], dt: 1.0 / 60, clock: 0) }
        #expect(simd_length(field.magnets[0].position) > near + 0.4)
    }

    @Test func theCameraKeepsItsDistanceAndHeight() {
        for second in stride(from: 0.0, to: 600, by: 7) {
            let (position, target) = FerroRenderer.camera(clock: second)
            let away = simd_length(SIMD2(position.x, position.z))
            #expect(away > 2.6 && away < 4.4)
            #expect(position.y > 0.9 && position.y < 2.2)
            #expect(simd_length(target) < 0.3)
        }
    }
}

@MainActor
struct NowPlayingVisualizerRenderTests {
    private let colors: [SIMD3<Float>] = VoiceTheme.resonance.voices.map { SIMD3(Float($0.red), Float($0.green), Float($0.blue)) }

    @Test func notesDrawsTheStavesTheNotesAndTheBalls() throws {
        let renderer = NotesRenderer()
        renderer.voiceColors = colors
        let empty = try #require(renderer.image(width: 1100, height: 700, time: 5.2))
        renderer.track = track
        let start = Date()
        for k in 0..<60 { _ = renderer.render(width: 3024, height: 1964, time: 5 + Double(k) / 60) }
        let perFrame = Date().timeIntervalSince(start) / 60
        let picture = try #require(renderer.image(width: 1100, height: 700, time: 5.2))
        save(picture, as: "Notes.png")
        print("Notes render: \(String(format: "%.2f", perFrame * 1000)) ms per full-screen frame")
        // Lit notes and balls, which the empty staves don't have.
        #expect(lit(picture, above: 150) > lit(empty, above: 150) + 2000)
    }

    @Test func terrainRisesWhereTheSpectrumDoes() throws {
        let renderer = TerrainRenderer()
        renderer.voiceColors = colors
        let spectrum = FineSpectrum(bands: TerrainRenderer.columns)
        let flat = try #require(renderer.image(width: 1100, height: 700, levels: spectrum.levels, clock: 0))
        let start = Date()
        for frame in 1...120 {
            let t = Double(frame) / 60
            let hz: Float = frame % 60 < 30 ? 220 : 330
            spectrum.update(voices: [sine(hz), sine(55), sine(hz * 4, amplitude: 0.2)], sampleRate: rate,
                            at: Date(timeIntervalSinceReferenceDate: t))
            _ = renderer.render(width: 3024, height: 1964, levels: spectrum.levels, clock: t)
        }
        let perFrame = Date().timeIntervalSince(start) / 120
        let picture = try #require(renderer.image(width: 1100, height: 700, levels: spectrum.levels, clock: 2))
        save(picture, as: "Terrain.png")
        print("Terrain render: \(String(format: "%.2f", perFrame * 1000)) ms per full-screen frame, with the spectrum")
        #expect(lit(picture, above: 120) > lit(flat, above: 120) + 2000)
    }

    @Test func inkPoursAndSpreadsInBothStyles() throws {
        for (style, name) in [(InkRenderer.Style.ink, "Ink"), (.liquidLight, "LiquidLight")] {
            let renderer = InkRenderer(style: style)
            var jets = InkJets()
            let still = try #require(renderer.image(width: 1100, height: 700, pours: [], dt: 1.0 / 60))
            #expect(lit(still, above: 40) == 0)
            let start = Date()
            for frame in 0..<240 {
                let t = Double(frame) / 60
                let voices = (0..<3).map { v in
                    InkJets.Voice(level: Float(exp(-(t * 2).truncatingRemainder(dividingBy: 1) * 1.5)), midi: Float(48 + v * 12 + Int(t * 2) % 7))
                }
                let pours = jets.pours(voices: voices, colors: colors, aspect: 1100.0 / 700, clock: t)
                _ = renderer.render(width: 1100, height: 700, pours: pours, dt: 1.0 / 60)
            }
            let perFrame = Date().timeIntervalSince(start) / 240
            let picture = try #require(renderer.image(width: 1100, height: 700, pours: [], dt: 1.0 / 60))
            save(picture, as: "\(name).png")
            print("\(name) render: \(String(format: "%.2f", perFrame * 1000)) ms per frame")
            // The dye has spread well beyond the three nozzles.
            #expect(lit(picture, above: 40) > 200_000)
        }
    }

    @Test func ferrofluidGleamsWhereAVoiceSounds() throws {
        let renderer = FerroRenderer()
        renderer.voiceColors = colors
        var field = FerroField()
        let still = try #require(renderer.image(width: 1100, height: 700, magnets: field.magnets, clock: 3))
        for frame in 0..<60 {
            field.update(voices: [.init(level: 1, midi: 60), .init(level: 0.8, midi: 52), .init(level: 0.6, midi: 43)],
                         dt: 1.0 / 60, clock: Double(frame) / 60)
        }
        let start = Date()
        for _ in 0..<30 { _ = renderer.render(width: 3024, height: 1964, magnets: field.magnets, clock: 3) }
        let perFrame = Date().timeIntervalSince(start) / 30
        let picture = try #require(renderer.image(width: 1100, height: 700, magnets: field.magnets, clock: 3))
        // The lowest quality still draws the pool, for much less.
        let lowStart = Date()
        for _ in 0..<30 { _ = renderer.render(width: 3024, height: 1964, magnets: field.magnets, clock: 3, quality: .low) }
        let lowPerFrame = Date().timeIntervalSince(lowStart) / 30
        let coarse = try #require(renderer.image(width: 1100, height: 700, magnets: field.magnets, clock: 3, quality: .low))
        #expect(lit(coarse, above: 120) > lit(still, above: 120) + 3000)
        print("Ferrofluid at low quality: \(String(format: "%.2f", lowPerFrame * 1000)) ms per full-screen frame")
        save(picture, as: "Ferrofluid.png")
        print("Ferrofluid render: \(String(format: "%.2f", perFrame * 1000)) ms per full-screen frame")
        #expect(lit(picture, above: 120) > lit(still, above: 120) + 3000)
    }

    @Test func siliconBuildsEachChipsSceneAndLightsWhatWorks() throws {
        for die in [SiliconDie.mos6581, .mos8580] {
            let silicon = SiliconScene(die: die)
            #expect(silicon.isReady)
            silicon.voiceColors = colors
            let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
            renderer.scene = silicon.scene
            renderer.pointOfView = silicon.cameraNode
            func picture(_ state: ChipState, clock: Double) throws -> CGImage {
                silicon.update(state: state, clock: clock)
                _ = renderer.snapshot(atTime: clock, with: CGSize(width: 550, height: 350), antialiasingMode: .none)
                let image = renderer.snapshot(atTime: clock, with: CGSize(width: 1100, height: 700), antialiasingMode: .none)
                return try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
            // Sliding across the die's voices, close.
            let clock = silicon.moves.prefix(5).reduce(0) { $0 + $1.seconds } + 6
            let dark = try picture(ChipState(), clock: clock)
            var state = ChipState()
            for v in 0..<3 {
                state.voices[v] = .init(frequency: 0x1CD6, pulseWidth: 0x800, waveform: 2, gate: true, level: 0.9, filtered: v == 0,
                                        samples: sine(440, count: 1024))
            }
            state.lowPass = true
            state.cutoff = 1200
            state.volume = 15
            let lively = try picture(state, clock: clock)
            save(lively, as: "Silicon\(die.name).png")
            #expect(lit(lively, above: 200) > lit(dark, above: 200) + 3000)

            // The camera is always moving, and never lurches or leaves
            // the chip: over two whole tours, it never stops for a
            // moment, never moves far for how far off it is, and stays
            // above the package looking at something on it.
            let tour = silicon.moves.reduce(0) { $0 + $1.seconds }
            #expect(silicon.moves.count >= 10 && tour > 120)
            var last = silicon.camera(clock: 0)
            for step in 1..<Int(tour * 2 * 10) {
                let now = silicon.camera(clock: Double(step) / 10)
                #expect(now.position.y > 0.05)
                #expect(now.distance > 0.15 && now.distance < 12)
                #expect(abs(now.target.x) < 4 && abs(now.target.z) < 2)
                let moved = simd_length(now.position - last.position)
                #expect(moved < 0.1 * max(now.distance, last.distance))
                #expect(moved > 0.0004 * now.distance)
                last = now
            }
        }
    }

    @Test func nimbusDrawsACloudThatGlowsWithTheVoices() throws {
        let renderer = NimbusRenderer()
        renderer.voiceColors = colors
        var voices = NimbusVoices()
        let quiet = try #require(renderer.image(width: 1100, height: 700, voices: voices, clock: 3))
        for _ in 0..<90 {
            voices.update(voices: [.init(level: 1, midi: 60), .init(level: 0.8, midi: 52), .init(level: 0.7, midi: 43)], dt: 1.0 / 60)
        }
        let start = Date()
        for _ in 0..<30 { _ = renderer.render(width: 3024, height: 1964, voices: voices, clock: 3) }
        let perFrame = Date().timeIntervalSince(start) / 30
        let picture = try #require(renderer.image(width: 1100, height: 700, voices: voices, clock: 3))
        save(picture, as: "Nimbus.png")
        print("Nimbus render: \(String(format: "%.2f", perFrame * 1000)) ms per full-screen frame")
        // The sky is pale either way; what changes is the cloud, which is
        // far larger and colored once the voices play.
        let before = try #require(quiet.dataProvider?.data as Data?), after = try #require(picture.dataProvider?.data as Data?)
        let changed = zip(before, after).count { abs(Int($0) - Int($1)) > 24 }
        #expect(changed > 100_000)
    }

    @Test func rastersDrawsBarsStarsAndLetters() throws {
        let renderer = RasterRenderer()
        renderer.voiceColors = colors
        renderer.setText("Commando     ·     Rob Hubbard")
        renderer.setStatus("1:SAW A-4  2:PUL C-3  3:TRI ---")
        var show = RasterShow()
        let empty = try #require(renderer.image(width: 1100, height: 700, show: show, clock: 2))
        for _ in 0..<30 {
            show.update(voices: [.init(level: 1, midi: 72), .init(level: 0.7, midi: 55), .init(level: 0.5, midi: 36)], dt: 1.0 / 60)
        }
        let start = Date()
        for _ in 0..<30 { _ = renderer.render(width: 3024, height: 1964, show: show, clock: 2) }
        let perFrame = Date().timeIntervalSince(start) / 30
        let picture = try #require(renderer.image(width: 1100, height: 700, show: show, clock: 2))
        save(picture, as: "Rasters.png")
        print("Rasters render: \(String(format: "%.2f", perFrame * 1000)) ms per full-screen frame")
        #expect(lit(picture, above: 150) > lit(empty, above: 150) + 20_000)
    }

    @Test func chipDrawsTheDieAndLightsItsBits() throws {
        let art = try #require(ChipDie.art(size: 800))
        #expect(art.width == 800)
        func picture(_ state: ChipState) throws -> CGImage {
            let drawing = ChipDrawing(state: state, colors: (0..<3).map(VoiceTheme.resonance.voice), art: art)
            let renderer = ImageRenderer(content: Canvas { gc, size in drawing.draw(in: &gc, size: size) }
                .frame(width: 1100, height: 700)
                .background(VoiceTheme.resonance.background.color))
            return try #require(renderer.cgImage)
        }
        var state = ChipState()
        let dark = try picture(state)
        state.voices[0] = .init(frequency: 0x1CD6, pulseWidth: 0x800, waveform: 2, gate: true, attack: 0, decay: 9, sustain: 10,
                                release: 4, level: 0.9, filtered: true, samples: sine(440, count: 1024))
        state.write((0..<29).map { UInt8(truncatingIfNeeded: $0 &* 73 &+ 41) }, dt: 0.016)
        state.cutoff = 1200
        state.lowPass = true
        state.volume = 15
        let lively = try picture(state)
        save(lively, as: "Chip.png")
        #expect(lit(lively, above: 200) > lit(dark, above: 200) + 3000)
    }

    @Test func spectrumDrawsItsCurvesAndNotes() throws {
        let spectrum = FineSpectrum(bands: SpectrumView.bands)
        func saw(_ hz: Float) -> [Float] {
            (0..<FineSpectrum.samples).map { n in
                (1...24).reduce(Float(0)) { $0 + 0.4 / Float($1) * sin(2 * .pi * hz * Float($1) * Float(n) / rate) }
            }
        }
        for frame in 0..<60 {
            spectrum.update(voices: [saw(440), sine(880), sine(65.4)], sampleRate: rate,
                            at: Date(timeIntervalSinceReferenceDate: Double(frame) / 60))
        }
        let plot = SpectrumView.Plot(
            levels: spectrum.levels, peaks: spectrum.peaks, mix: spectrum.mix(),
            notes: [.init(name: "A-4", hz: 440), .init(name: "A-5", hz: 880), .init(name: "C-2", hz: 65.4)],
            colors: (0..<3).map(VoiceTheme.resonance.voice))
        let renderer = ImageRenderer(content: Canvas { gc, size in plot.draw(in: &gc, size: size) }
            .frame(width: 1100, height: 700)
            .background(VoiceTheme.resonance.background.color))
        renderer.scale = 2
        let picture = try #require(renderer.cgImage)
        save(picture, as: "Spectrum.png")
        #expect(lit(picture, above: 120) > 5000)
    }
}
