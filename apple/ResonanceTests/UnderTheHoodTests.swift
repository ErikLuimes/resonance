import AppKit
import SwiftUI
import Testing
import PhosphorCore
@testable import Resonance

@MainActor
struct UnderTheHoodTests {
    private func cell(_ note: String? = nil, instrument: UInt8 = 0, off: Bool = false, effect: TrackerEffect = .none) -> TrackerCell {
        TrackerCell(note: note, instrument: instrument, off: off, effect: effect)
    }

    private func song(rows: Int = 200) -> TrackerSong {
        TrackerSong(
            isPal: true, frameRate: 50, framesPerRow: 6, onGrid: 1, hasGrid: true, chips: 1,
            rows: (0..<rows).map { n in
                TrackerRow(
                    frame: UInt32(n * 6),
                    voices: [
                        n % 4 == 0 ? cell("C-4", instrument: 1, effect: .arpeggio) : cell(),
                        n % 8 == 2 ? cell("A#2", instrument: 2) : (n % 8 == 5 ? cell(off: true) : cell()),
                        n % 2 == 0 ? cell("G-5", instrument: 3, effect: .vibrato) : cell(effect: .vibrato),
                    ],
                    cutoff: 1024, resonance: 7, filterRouting: 3, filterMode: 1
                )
            },
            instruments: [
                TrackerInstrument(name: "Saw", attackDecay: 0x09, sustainRelease: 0xA9),
                TrackerInstrument(name: "Noise › Pulse", attackDecay: 0x0A, sustainRelease: 0x09),
                TrackerInstrument(name: "Pulse", attackDecay: 0x29, sustainRelease: 0x5F),
            ]
        )
    }

    private func frame(_ index: UInt64, change: UInt8 = 0) -> VizSidFrame {
        let midis = [60.0 + 12 * sin(Double(index) * 0.03), 48.0 + Double(index % 96 / 8), 72.0]
        let voices = (0..<3).map { v in
            VizVoice(
                freqReg: 0x1167, hz: 262, midi: midis[v], note: ["C-4", "C-3", "C-5"][v],
                gate: index % UInt64(20 + v * 13) < 14, waveform: [4, 2, 8][v], test: false, ring: false, sync: false,
                pulseWidth: UInt16(2048 + 1800 * sin(Double(index) * 0.05)), attack: 0, decay: 9, sustain: 10, release: 6,
                envLevel: 0.6, envPhase: .sustain
            )
        }
        var registers = Data(count: 29)
        registers[0] = 0x67
        registers[2] = change
        registers[4] = 0x41
        let chip = VizChip(
            voices: voices, registers: registers, cutoff: UInt16(1024 + 900 * sin(Double(index) * 0.02)), resonance: 7,
            filterRouting: 3, filterMode: 1, volume: 15
        )
        return VizSidFrame(index: index, isPal: true, chips: [chip])
    }

    /// A frame of `chips` chips that each do something else.
    private func frame(_ index: UInt64, chips: Int) -> VizSidFrame {
        let all = (0..<chips).map { frame(index &* UInt64($0 + 2) + UInt64($0 * 40), change: UInt8(truncatingIfNeeded: index >> UInt64($0))).chips[0] }
        return VizSidFrame(index: index, isPal: true, chips: all)
    }

    @Test func controlBytesReadAsWords() {
        #expect(VoiceLines.waveName(0) == "—")
        #expect(VoiceLines.waveName(0x40) == "PUL")
        #expect(VoiceLines.waveName(0x50) == "T+P")
        #expect(VoiceLines.bitsName(0x10) == "—")
        #expect(VoiceLines.bitsName(1) == "GATE")
        #expect(VoiceLines.bitsName(3) == "GATE SYNC")
        #expect(VoiceLines.bitsName(7) == "G S R")
    }

    @Test func aTabCollapsesWhenEveryChipWontFit() {
        let roomy = CGSize(width: 1100, height: 700)
        for tab in UnderTheHoodTab.allCases {
            #expect(UnderTheHoodView.everyChipFits(tab: tab, chips: 3, in: roomy))
            #expect(UnderTheHoodView.everyChipFits(tab: tab, chips: 1, in: CGSize(width: 200, height: 100)))
        }
        #expect(!UnderTheHoodView.everyChipFits(tab: .registers, chips: 3, in: CGSize(width: 400, height: 700)))
        #expect(!UnderTheHoodView.everyChipFits(tab: .registers, chips: 3, in: CGSize(width: 1100, height: 300)))
        #expect(!UnderTheHoodView.everyChipFits(tab: .sweeps, chips: 3, in: CGSize(width: 400, height: 700)))
        #expect(!UnderTheHoodView.everyChipFits(tab: .pitch, chips: 3, in: CGSize(width: 1100, height: 300)))
        #expect(UnderTheHoodView.everyChipFits(tab: .tracker, chips: 3, in: CGSize(width: 300, height: 200)))
    }

    @Test func eachChipLightsOnItsOwn() {
        let flashes = [RegisterFlash(), RegisterFlash()]
        var quiet = frame(2, chips: 2)
        var registers = quiet.chips[1].registers
        registers[2] = 0x7F
        quiet.chips[1].registers = registers
        let before = VizSidFrame(index: 1, isPal: true, chips: [quiet.chips[0], frame(1).chips[0]])
        for (chip, flash) in flashes.enumerated() { flash.take([before, quiet], chip: chip) }
        #expect(flashes[1].isLit(2))
        #expect(!flashes[0].isLit(2), "the first chip didn't change between the two")
    }

    @Test func theRowComesFromTheTimeHeard() {
        let song = song()
        #expect(song.row(atSecs: 0) == 0)
        #expect(song.row(atSecs: 2.4) == 20)
        #expect(song.row(atSecs: -1) == 0)
        #expect(song.row(atSecs: 1000) == 199)
    }

    @Test func eachVoiceKeepsTheInstrumentItLastStarted() {
        let current = song().currentInstruments(atRow: 7)
        #expect(current[0]?.name == "Saw")
        #expect(current[1]?.name == "Noise › Pulse")
        #expect(current[2]?.name == "Pulse")
    }

    @Test func aVoiceThatHasntStartedHasNoInstrument() {
        #expect(song().currentInstruments(atRow: 0)[1] == nil)
        let none = TrackerSong(isPal: true, frameRate: 50, framesPerRow: 6, onGrid: 0, hasGrid: false, chips: 1, rows: [], instruments: [])
        #expect(none.currentInstruments(atRow: 0).allSatisfy { $0 == nil })
        #expect(none.row(atSecs: 3) == 0)
    }

    @Test func aRegisterStaysLitForAFewFramesThenGoesOut() {
        let flash = RegisterFlash()
        flash.take([frame(1, change: 1), frame(2, change: 2)], chip: 0)
        #expect(flash.isLit(2))
        #expect(!flash.isLit(0))
        flash.take((3...12).map { frame(UInt64($0), change: 2) }, chip: 0)
        #expect(!flash.isLit(2))
    }

    @Test func batchesThatOverlapDontForgetWhatChanged() {
        let flash = RegisterFlash()
        flash.take((1...8).map { frame(UInt64($0), change: UInt8($0 == 8 ? 1 : 0)) }, chip: 0)
        #expect(flash.isLit(2))
        // The same frames again, with two new ones that change nothing.
        flash.take((3...10).map { frame(UInt64($0), change: UInt8($0 >= 8 ? 1 : 0)) }, chip: 0)
        #expect(flash.isLit(2), "lit since frame 8, two frames ago")
        flash.take((5...20).map { frame(UInt64($0), change: 1) }, chip: 0)
        #expect(!flash.isLit(2))
    }

    @Test func aRewindForgetsWhatLit() {
        let flash = RegisterFlash()
        flash.take([frame(100, change: 1), frame(101, change: 2)], chip: 0)
        #expect(flash.isLit(2))
        flash.take([frame(1, change: 2)], chip: 0)
        #expect(!flash.isLit(2))
    }

    @Test func aChipTheTuneDoesntHaveIsIgnored() {
        let flash = RegisterFlash()
        flash.take([frame(1), frame(2, change: 9)], chip: 3)
        #expect(!flash.isLit(2))
    }

    /// With `UNDER_THE_HOOD_RENDER` set to a folder, draws each view there to look at.
    @Test func renders() throws {
        guard let folder = ProcessInfo.processInfo.environment["UNDER_THE_HOOD_RENDER"] else { return }
        let colours = VoiceTheme.resonance.voices.map(\.color)
        let frames = (0..<512).map { frame(UInt64($0 + 1), change: UInt8($0 % 3)) }
        let flash = RegisterFlash()
        flash.take(Array(frames.suffix(8)), chip: 0)
        let background = VoiceTheme.resonance.background.color
        func save<V: View>(_ name: String, _ view: V) throws {
            let renderer = ImageRenderer(content: view.frame(width: 980, height: 500).background(background).environment(\.colorScheme, .dark))
            renderer.scale = 1
            let image = try #require(renderer.nsImage)
            let data = try #require(NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?.representation(using: .png, properties: [:]))
            try data.write(to: URL(filePath: folder).appending(path: "\(name).png"))
        }
        try save("tracker", TrackerPage(song: song(), tuneID: "a", row: 40, height: 500, width: 980, colours: colours))
        try save("registers", RegistersCanvas(frame: frames.last, chip: 0, flash: flash))
        try save("registers-narrow", RegistersCanvas(frame: frames.last, chip: 0, flash: flash).frame(width: 500, height: 370))
        try save("sweeps", SweepsCanvas(frames: frames, shown: [0], colours: colours))
        try save("pitch", PitchCanvas(frames: Array(frames.suffix(256)), shown: [0], colours: colours))
        for chips in [2, 3] {
            let many = (0..<512).map { frame(UInt64($0 + 1), chips: chips) }
            let flashes = (0..<3).map { _ in RegisterFlash() }
            for (chip, flash) in flashes.enumerated() { flash.take(Array(many.suffix(8)), chip: chip) }
            let all = Array(0..<chips)
            try save("registers-\(chips)", VoiceLines(frame: many.last, shown: all, flashes: flashes))
            try save("registers-\(chips)-collapsed", VoiceLines(frame: many.last, shown: [1], flashes: flashes))
            try save("registers-\(chips)-plain", VoiceLines(frame: many.last, shown: all, flashes: flashes).frame(width: 520, height: 500))
            try save("sweeps-\(chips)", SweepsCanvas(frames: many, shown: all, colours: colours))
            try save("pitch-\(chips)", PitchCanvas(frames: Array(many.suffix(256)), shown: all, colours: colours))
        }
    }
}
