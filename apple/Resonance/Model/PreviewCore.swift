import Foundation
import PhosphorCore

/// A `PlayerCoreProtocol` that plays nothing: canned data for SwiftUI
/// previews, and the stand-in core while unit tests run inside the app (so
/// tests don't start audio or touch the saved session).
nonisolated final class PreviewCore: PlayerCoreProtocol {
    let items: [PlaylistItem]
    let current: Int?

    init(items: [PlaylistItem], current: Int? = nil) {
        self.items = items
        self.current = current
    }

    static let empty = PreviewCore(items: [])

    static let sample = PreviewCore(
        items: [
            item("Commando", "Rob Hubbard", "1985 Elite", songs: 19, seconds: 236),
            item("Monty on the Run", "Rob Hubbard", "1985 Gremlin Graphics", songs: 1, seconds: 344),
            item("Last Ninja 2", "Matt Gray", "1988 System 3", songs: 16, seconds: 205),
            item("Cybernoid II", "Jeroen Tel", "1988 Hewson", songs: 3, seconds: nil),
        ],
        current: 0
    )

    private static func item(_ title: String, _ author: String, _ released: String, songs: UInt16, seconds: UInt32?) -> PlaylistItem {
        PlaylistItem(
            path: "/HVSC/\(title).sid", title: title, author: author, released: released,
            songs: songs, selectedSong: 1, durationSecs: seconds, isRsid: false, isPal: true,
            numSids: 1, md5: nil
        )
    }

    func snapshot() -> Snapshot {
        let track = current.map { i in
            let it = items[i]
            return TrackDetails(
                path: it.path, title: it.title, author: it.author, released: it.released,
                songs: it.songs, currentSong: it.selectedSong, isPal: it.isPal, isRsid: it.isRsid,
                numSids: it.numSids, sidType: "PSID", sidModel: 1, md5: ""
            )
        }
        return Snapshot(
            state: current == nil ? .stopped : .playing,
            currentIndex: current.map(UInt32.init),
            queueActive: false,
            surpriseActive: false,
            track: track,
            elapsedMs: current == nil ? 0 : 83_000,
            durationMs: current.flatMap { items[$0].durationSecs }.map { UInt64($0) * 1000 },
            shuffle: false, repeat: .off, engine: .sidLite,
            playlistRevision: 1, trackRevision: 1, loading: nil, error: nil,
            hvscIndexing: [], hvscTreeRevision: 0
        )
    }

    func playlist() -> [PlaylistItem] { items }

    /// Triangle, pulse and saw on A4, E5 and C3, their envelopes breathing.
    private static let previewVoices: [(hz: Double, midi: Double, note: String, waveform: UInt8)] = [
        (440.0, 69, "A4", 0x1), (659.26, 76, "E5", 0x4), (130.81, 48, "C3", 0x2),
    ]
    private static let previewRate: Float = 44_784

    func vizLatest() -> VizSidFrame? {
        let t = Date().timeIntervalSinceReferenceDate
        let voices = Self.previewVoices.enumerated().map { i, v in
            VizVoice(
                freqReg: UInt16(v.hz * 16_777_216 / 985_248), hz: v.hz, midi: v.midi, note: v.note,
                gate: true, waveform: v.waveform, test: false, ring: false, sync: false,
                pulseWidth: 0x800, attack: UInt8(2 * i), decay: 9, sustain: 10, release: 6,
                envLevel: Float(0.5 + 0.45 * sin(t * (2 + Double(i)))), envPhase: [.attack, .decay, .sustain][i]
            )
        }
        let chip = VizChip(
            voices: voices, registers: Data(count: 29), cutoff: 0x400, resonance: 8,
            filterRouting: 0x1, filterMode: 0x1, volume: 15
        )
        return VizSidFrame(index: UInt64(t * 50), isPal: true, chips: [chip])
    }

    func vizHistory(count: UInt32) -> [VizSidFrame] {
        vizLatest().map { [$0] } ?? []
    }

    func vizScope(chip: UInt32, count: UInt32) -> VizScope {
        guard chip == 0 else { return VizScope(sampleRate: Self.previewRate, voices: [[], [], []]) }
        let voices = Self.previewVoices.map { v in
            (0..<Int(min(count, 2048))).map { n -> Float in
                let phase = Float((Double(n) * v.hz / Double(Self.previewRate)).truncatingRemainder(dividingBy: 1))
                switch v.waveform {
                case 0x1: return abs(phase * 4 - 2) - 1
                case 0x4: return phase < 0.5 ? 0.8 : -0.8
                default: return phase * 2 - 1
                }
            }
        }
        return VizScope(sampleRate: Self.previewRate, voices: voices)
    }

    func vizStats() -> VizStats {
        VizStats(frames: 0, shadowMicros: 0, bufferMs: 100, outputLatencyMs: 12, offsetMs: 0)
    }

    func setVizOutputLatencyMs(ms: UInt32) {}
    func setVizOffsetMs(ms: Int32) {}

    func hvscAuthors(category: HvscCategory) async throws -> [HvscAuthorItem] {
        [("G", "Galway_Martin"), ("H", "Hubbard_Rob"), ("T", "Tel_Jeroen")].map { letter, name in
            HvscAuthorItem(
                name: name, displayName: name.replacing("_", with: ", "), letter: letter,
                path: "/HVSC/MUSICIANS/\(letter)/\(name)"
            )
        }
    }

    func hvscTunes(authorPath: String) async throws -> [HvscTuneItem] {
        items.map(Self.tune)
    }

    func hvscStil(path: String) async -> String? {
        if path.hasSuffix("/Hubbard_Rob") { return Self.hubbardStil }
        if path.hasSuffix("/Commando.sid") { return Self.hubbardStil + "\n\n" + Self.commandoStil }
        return nil
    }

    private static let hubbardStil = """
        /MUSICIANS/H/Hubbard_Rob/
        COMMENT: People have often stolen Hubbard's routine causing some tunes to be
                 falsely credited to him.
                 Hubbard's own comments are denoted (RH).
        """

    private static let commandoStil = """
        /MUSICIANS/H/Hubbard_Rob/Commando.sid
        COMMENT: "There is an interesting story behind Commando. I went down to their
                 office and started working on it late at night, and worked on it
                 through the night. I took one listen to the original arcade version
                 and started working on the C64 version." (RH)
        (#1)
          TITLE: BGM1 [from the arcade game Commando] (0:00)
         ARTIST: Tamayo Kawamoto
          TITLE: Base [from the arcade game Commando] (0:53)
         ARTIST: Tamayo Kawamoto
          TITLE: Level Complete [from the arcade game Commando] (1:16-1:32)
         ARTIST: Tamayo Kawamoto
        """

    func hvscSearch(query: String, scope: HvscCategory?) async throws -> HvscSearchResult {
        let hits = items.filter { $0.title.localizedStandardContains(query) }.map(Self.tune)
        return HvscSearchResult(items: hits, totalMatches: UInt32(hits.count), indexed: 61_157)
    }

    func hvscTunesCrediting(names: [String]) async throws -> [HvscTuneItem] {
        items.filter { item in names.contains { item.author.localizedStandardContains($0) } }.map(Self.tune)
    }

    func hvscSurprise(scope: HvscCategory?) async throws -> String? { items.randomElement()?.path }
    func surpriseMe() async {}

    private static func tune(_ it: PlaylistItem) -> HvscTuneItem {
        HvscTuneItem(
            path: it.path, title: it.title, author: it.author, released: it.released, songs: it.songs,
            startSong: 1, durationSecs: it.durationSecs, hasStil: true, isRsid: false, category: .musicians
        )
    }

    func setHvscRoot(root: String?) {}
    func hvscSyncStatus() -> HvscSyncStatus? { nil }
    func startHvscSync() throws {}
    func cancelHvscSync() {}
    func hvscInfo() async -> HvscInfo? { nil }
    func addPaths(paths: [String], playFirst: Bool) {}
    func clear() {}
    func moveEntries(from: [UInt32], to: UInt32) {}
    func next() {}
    func nextSubtune() {}
    func playIndex(index: UInt32) {}
    func playQueue(paths: [String], start: String) {}
    func playPause(fallback: UInt32?) {}
    func prevSubtune() {}
    func previous() {}
    func remove(indices: [UInt32]) {}
    func setEngine(engine: Engine) {}
    func setOptions(options: PlaybackOptions) {}
    func setRepeat(repeat: Repeat) {}
    func setShuffle(on: Bool) {}
    func setSubtune(song: UInt16) {}
    func setVolume(volume: Float) {}
    func shutdown() {}
    func stop() {}
}

extension PlayerStore {
    static var preview: PlayerStore {
        let store = PlayerStore(defaults: UserDefaults(suiteName: "preview")!) { _ in PreviewCore.sample }
        store.refresh()
        return store
    }
}
