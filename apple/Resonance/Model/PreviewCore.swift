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
            hvscIndexing: [],
            stil: current == nil ? nil : TuneStil(
                comment: "Rob Hubbard's arrangement for Elite's arcade conversion.",
                blocks: [StilBlock(
                    subtune: 1, name: nil, title: "Commando (arcade)", artist: "Tamayo Kawamoto", author: nil,
                    comment: "Based on /MUSICIANS/H/Hubbard_Rob/Commando.sid"
                )]
            )
        )
    }

    func playlist() -> [PlaylistItem] { items }

    func vizFrame() -> VizFrame {
        let t = Date().timeIntervalSinceReferenceDate
        let levels = (0..<3).map { Float(0.5 + 0.45 * sin(t * (2 + Double($0)))) }
        // Gate on, triangle/pulse/saw, A4/E5/C3-ish frequencies.
        let regs: [UInt8] = [0x40, 0x1D, 0, 0, 0x11, 0, 0, 0xAE, 0x2B, 0, 0, 0x41, 0, 0, 0x8F, 0x08, 0, 0, 0x21]
            + Array(repeating: 0, count: 128 - 19)
        return VizFrame(seq: UInt64(t * 50), voiceLevels: levels, sidRegs: Data(regs), numSids: 1)
    }

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

    func hvscAuthorNote(authorPath: String) async throws -> String? {
        guard authorPath.hasSuffix("/Hubbard_Rob") else { return nil }
        return "People have often stolen Hubbard's routine causing some tunes to be falsely credited to him.\n"
            + "Hubbard's own comments are denoted (RH)."
    }

    func hvscSearch(query: String, scope: HvscCategory?) async throws -> HvscSearchResult {
        let hits = items.filter { $0.title.localizedStandardContains(query) }.map(Self.tune)
        return HvscSearchResult(items: hits, totalMatches: UInt32(hits.count), indexed: 61_157)
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
