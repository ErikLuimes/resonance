import Foundation
import Testing
import PhosphorCore
@testable import Resonance

/// Records what the store sends to the core and serves canned snapshots.
nonisolated final class FakeCore: PlayerCoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _snapshot: Snapshot
    private var _items: [PlaylistItem] = []
    private var _playlistFetches = 0

    init(snapshot: Snapshot = FakeCore.stoppedSnapshot) {
        _snapshot = snapshot
    }

    var calls: [String] { lock.withLock { _calls } }
    var playlistFetches: Int { lock.withLock { _playlistFetches } }

    func set(snapshot: Snapshot, items: [PlaylistItem]? = nil) {
        lock.withLock {
            _snapshot = snapshot
            if let items { _items = items }
        }
    }

    private func record(_ call: String) {
        lock.withLock { _calls.append(call) }
    }

    static let stoppedSnapshot = Snapshot(
        state: .stopped, currentIndex: nil, queueActive: false, surpriseActive: false, track: nil,
        elapsedMs: 0, durationMs: nil,
        shuffle: false, repeat: .off, engine: .sidLite, playlistRevision: 0, trackRevision: 0,
        loading: nil, error: nil, hvscIndexing: [], stil: nil
    )

    // Library: canned answers, settable per test.
    private var _authors: [HvscAuthorItem] = []
    private var _surprise: String?
    private var _authorLoads = 0

    var authorLoads: Int { lock.withLock { _authorLoads } }

    func set(authors: [HvscAuthorItem] = [], surprise: String? = nil) {
        lock.withLock {
            _authors = authors
            _surprise = surprise
        }
    }

    func hvscAuthors(category: HvscCategory) async throws -> [HvscAuthorItem] {
        lock.withLock {
            _authorLoads += 1
            return _authors
        }
    }

    func hvscTunes(authorPath: String) async throws -> [HvscTuneItem] { [] }

    func hvscSearch(query: String, scope: HvscCategory?) async throws -> HvscSearchResult {
        record("search \(query) \(scope.map { "\($0)" } ?? "all")")
        return HvscSearchResult(items: [], totalMatches: 0, indexed: 0)
    }

    func hvscSurprise(scope: HvscCategory?) async throws -> String? {
        record("surprise \(scope.map { "\($0)" } ?? "all")")
        return lock.withLock { _surprise }
    }

    func surpriseMe() async { record("surpriseMe") }

    func setHvscRoot(root: String?) { record("hvscRoot \(root ?? "nil")") }

    func snapshot() -> Snapshot { lock.withLock { _snapshot } }
    func playlist() -> [PlaylistItem] {
        lock.withLock {
            _playlistFetches += 1
            return _items
        }
    }
    func vizFrame() -> VizFrame { VizFrame(seq: 0, voiceLevels: [], sidRegs: Data(), numSids: 1) }

    func addPaths(paths: [String], playFirst: Bool) { record("add \(paths) \(playFirst)") }
    func clear() { record("clear") }
    func moveEntries(from: [UInt32], to: UInt32) { record("move \(from) \(to)") }
    func next() { record("next") }
    func nextSubtune() { record("nextSubtune") }
    func playIndex(index: UInt32) { record("play \(index)") }
    func playQueue(paths: [String], start: String) { record("queue \(paths) from \(start)") }
    func playPause(fallback: UInt32?) { record("playPause \(fallback.map(String.init) ?? "nil")") }
    func prevSubtune() { record("prevSubtune") }
    func previous() { record("previous") }
    func remove(indices: [UInt32]) { record("remove \(indices)") }
    func setEngine(engine: Engine) { record("engine \(engine)") }
    func setOptions(options: PlaybackOptions) { record("options \(options.defaultSongLengthSecs)") }
    func setRepeat(repeat: Repeat) { record("repeat \(`repeat`)") }
    func setShuffle(on: Bool) { record("shuffle \(on)") }
    func setSubtune(song: UInt16) { record("subtune \(song)") }
    func setVolume(volume: Float) { record("volume \(volume)") }
    func shutdown() { record("shutdown") }
    func stop() { record("stop") }
}

@MainActor
struct PlayerStoreTests {
    let defaults: UserDefaults
    let fake = FakeCore()

    init() {
        let suite = "ResonanceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeStore(phosphorHvscRoot: String? = nil) -> (PlayerStore, CoreConfig) {
        var config: CoreConfig?
        let store = PlayerStore(
            defaults: defaults,
            sessionPath: URL(filePath: "/tmp/session.m3u"),
            phosphorHvscRoot: { phosphorHvscRoot }
        ) {
            config = $0
            return fake
        }
        return (store, config!)
    }

    private func item(_ title: String) -> PlaylistItem {
        PlaylistItem(path: "/t/\(title).sid", title: title, author: "A", released: "1987", songs: 1,
                     selectedSong: 1, durationSecs: 60, isRsid: false, isPal: true, numSids: 1, md5: nil)
    }

    @Test func startsCoreWithSavedSettings() {
        defaults.set("resid", forKey: Pref.engine)
        defaults.set(0.5, forKey: Pref.volume)
        defaults.set("all", forKey: Pref.repeatMode)
        defaults.set(120, forKey: Pref.defaultSongLength)
        defaults.set("wide", forKey: Pref.pseudoStereo)

        let (_, config) = makeStore()

        #expect(config.engine == .reSid)
        #expect(config.volume == 0.5)
        #expect(config.repeat == .all)
        #expect(config.options.defaultSongLengthSecs == 120)
        #expect(config.options.pseudoStereo == .wide)
        #expect(config.sessionPath == "/tmp/session.m3u")
    }

    @Test func settingChangesReachTheCoreAndPersist() {
        let (store, _) = makeStore()
        store.engine = .reSid
        store.shuffle = true
        store.repeatMode = .one
        store.options.defaultSongLengthSecs = 90
        store.volume = 1.7  // clamped

        #expect(fake.calls == ["engine reSid", "shuffle true", "repeat one", "options 90", "volume 1.0"])
        #expect(defaults.string(forKey: Pref.engine) == "resid")
        #expect(defaults.bool(forKey: Pref.shuffle))
        #expect(defaults.integer(forKey: Pref.defaultSongLength) == 90)
        #expect(store.volume == 1)
    }

    @Test func unchangedSettingsAreNotResent() {
        let (store, _) = makeStore()
        store.engine = .sidLite
        store.shuffle = false
        #expect(fake.calls.isEmpty)
    }

    @Test func playlistIsRefetchedOnlyWhenTheRevisionChanges() {
        let (store, _) = makeStore()
        var snapshot = FakeCore.stoppedSnapshot
        snapshot.playlistRevision = 1
        fake.set(snapshot: snapshot, items: [item("a"), item("b")])

        store.refresh()
        store.refresh()
        #expect(fake.playlistFetches == 1)
        #expect(store.rows.map(\.title) == ["a", "b"])
        #expect(store.rows.map(\.index) == [0, 1])

        snapshot.playlistRevision = 2
        fake.set(snapshot: snapshot, items: [item("b")])
        store.refresh()
        #expect(fake.playlistFetches == 2)
        #expect(store.rows.map(\.title) == ["b"])
    }

    @Test func snapshotFieldsMapToStoreState() {
        let (store, _) = makeStore()
        var snapshot = FakeCore.stoppedSnapshot
        snapshot.state = .playing
        snapshot.currentIndex = 3
        snapshot.queueActive = true
        snapshot.surpriseActive = true
        snapshot.elapsedMs = 30_000
        snapshot.durationMs = 120_000
        fake.set(snapshot: snapshot)

        store.refresh()

        #expect(store.isPlaying)
        #expect(store.currentIndex == 3)
        #expect(store.queueActive)
        #expect(store.surpriseActive)
        #expect(store.elapsed == 30)
        #expect(store.progress == 0.25)
    }

    @Test func commandsForwardIndices() {
        let (store, _) = makeStore()
        store.play(index: 2)
        store.playPause(fallback: 4)
        store.remove(indices: [1, 3])
        store.move(fromOffsets: IndexSet([0, 1]), toOffset: 3)
        store.cycleRepeat()

        #expect(fake.calls == ["play 2", "playPause 4", "remove [1, 3]", "move [0, 1] 3", "repeat all"])
    }

    @Test func playQueueForwardsPathsAndStart() {
        let (store, _) = makeStore()
        store.playQueue([URL(filePath: "/a.sid"), URL(filePath: "/b.sid")], startAt: URL(filePath: "/b.sid"))
        store.playQueue([], startAt: URL(filePath: "/a.sid"))

        #expect(fake.calls == ["queue [\"/a.sid\", \"/b.sid\"] from /b.sid"])
    }
}

@MainActor
struct HvscSettingsTests {
    let defaults: UserDefaults
    let fake = FakeCore()

    init() {
        let suite = "ResonanceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeStore(phosphor: String?) -> (PlayerStore, CoreConfig) {
        var config: CoreConfig?
        let store = PlayerStore(defaults: defaults, phosphorHvscRoot: { phosphor }) {
            config = $0
            return fake
        }
        return (store, config!)
    }

    @Test func usesPhosphorsFolderUntilOneIsChosen() {
        let (store, config) = makeStore(phosphor: "/HVSC")
        #expect(config.hvscRoot == "/HVSC")
        #expect(store.hvscRoot == "/HVSC")
    }

    @Test func aChosenFolderIsPushedAndRemembered() {
        let (store, _) = makeStore(phosphor: "/HVSC")
        store.hvscRoot = "/Music/C64"
        #expect(fake.calls == ["hvscRoot /Music/C64"])

        let (_, relaunched) = makeStore(phosphor: "/HVSC")
        #expect(relaunched.hvscRoot == "/Music/C64")
    }

    @Test func clearingTheFolderSticksAcrossLaunches() {
        let (store, _) = makeStore(phosphor: "/HVSC")
        store.hvscRoot = nil
        let (_, relaunched) = makeStore(phosphor: "/HVSC")
        #expect(relaunched.hvscRoot == nil)
    }
}

@MainActor
struct LibraryStoreTests {
    let fake = FakeCore()

    private func makeLibrary(root: String? = "/HVSC") -> (LibraryStore, PlayerStore) {
        let suite = "ResonanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let player = PlayerStore(defaults: defaults, phosphorHvscRoot: { root }) { _ in fake }
        return (LibraryStore(player: player), player)
    }

    private func author(_ name: String) -> HvscAuthorItem {
        HvscAuthorItem(name: name, displayName: name, letter: "H", path: "/HVSC/MUSICIANS/H/\(name)")
    }

    @Test func authorsAreLoadedOncePerFolder() async {
        let (library, player) = makeLibrary()
        fake.set(authors: [author("Hubbard_Rob")])

        await library.loadAuthors(.musicians)
        await library.loadAuthors(.musicians)
        #expect(fake.authorLoads == 1)
        #expect(library.authors[.musicians]?.map(\.name) == ["Hubbard_Rob"])

        // A new HVSC folder invalidates the cache.
        player.hvscRoot = "/Other"
        await library.loadAuthors(.musicians)
        #expect(fake.authorLoads == 2)
    }

    @Test func surpriseLeavesThePickingToTheCore() async {
        let (library, _) = makeLibrary()
        await library.surpriseMe()
        #expect(fake.calls == ["surpriseMe"])
        #expect(library.surprises == 1)
    }

    private func track(_ path: String, author: String) -> TrackDetails {
        TrackDetails(
            path: path, title: "Tune", author: author, released: "1987", songs: 1, currentSong: 1,
            isPal: true, isRsid: false, numSids: 1, sidType: "PSID", sidModel: 1, md5: ""
        )
    }

    @Test func authorLinkOpensTheFolderTheTuneIsIn() async {
        let (library, _) = makeLibrary(root: "/HVSC/")
        #expect(library.revealAuthor(of: track("/HVSC/MUSICIANS/H/Hubbard_Rob/Commando.sid", author: "Rob Hubbard")) == nil,
                "not before MUSICIANS is loaded")

        fake.set(authors: [author("Hubbard_Rob")])
        await library.loadAuthors(.musicians)
        // The folder wins over the header, whatever it says.
        let reveal = library.revealAuthor(of: track("/HVSC/MUSICIANS/H/Hubbard_Rob/Commando.sid", author: "<?>"))
        #expect(reveal?.authorPath == "/HVSC/MUSICIANS/H/Hubbard_Rob")
        #expect(reveal?.tunePath == "/HVSC/MUSICIANS/H/Hubbard_Rob/Commando.sid")
    }

    @Test func authorLinkMatchesTheHeaderToAComposerFolder() async {
        let (library, _) = makeLibrary()
        fake.set(authors: [author("Hubbard_Rob"), author("Laxity"), author("Tel_Jeroen")])
        await library.loadAuthors(.musicians)
        let path = { (author: String) in library.revealAuthor(of: self.track("/HVSC/GAMES/A-F/X.sid", author: author))?.authorPath }

        #expect(path("Rob Hubbard") == "/HVSC/MUSICIANS/H/Hubbard_Rob")
        #expect(path("Thomas E. Petersen (Laxity)") == "/HVSC/MUSICIANS/H/Laxity")
        #expect(path("Charles Deenen & Jeroen Tel") == "/HVSC/MUSICIANS/H/Tel_Jeroen")
        // No composer folder, and nothing else to search: no link.
        #expect(path("Krzysztof Niedzwiecki (Radius75)") == nil)
        #expect(path("<?>") == nil)
    }

    @Test func headerAuthorsSplitIntoNamesAndHandles() {
        #expect(LibraryStore.names(in: "Thomas E. Petersen (Laxity)") == ["Thomas E. Petersen", "Laxity"])
        #expect(LibraryStore.names(in: "A & B and C") == ["A & B and C", "A", "B", "C"])
        #expect(LibraryStore.words("Hubbard_Rob") == LibraryStore.words("Rob  Hubbard"))
        #expect(LibraryStore.words("Lukáš") == ["lukas"])
    }

    @Test func searchPassesItsScope() async throws {
        let (library, _) = makeLibrary()
        _ = try await library.search("commando", scope: .musicians)
        _ = try await library.search("commando", scope: nil)
        #expect(fake.calls == ["search commando musicians", "search commando all"])
    }

    @Test func noFolderMeansNoLibrary() {
        let (library, _) = makeLibrary(root: nil)
        #expect(!library.hasRoot)
    }
}

struct SIDVoiceTests {
    @Test func decodesConcertA() {
        // 440 Hz on a PAL machine: 440 × 16777216 / 985248 ≈ 7493.
        #expect(SIDVoice.noteName(frequencyRegister: 7493, clock: 985_248) == "A4")
        #expect(SIDVoice.noteName(frequencyRegister: 0, clock: 985_248) == nil)
    }

    @Test func decodesWaveformsAndGate() {
        var regs = [UInt8](repeating: 0, count: 32)
        regs[0] = 0x45; regs[1] = 0x1D; regs[4] = 0x41   // voice 1: A4, pulse, gate on
        regs[7 + 4] = 0x20                                 // voice 2: saw, gate off
        let voices = SIDVoice.decode(regs: regs, chips: 1, pal: true)

        #expect(voices.count == 3)
        #expect(voices[0] == SIDVoice(note: "A4", waveform: "PUL", gate: true))
        #expect(voices[1] == SIDVoice(note: nil, waveform: "SAW", gate: false))
        #expect(voices[2].waveform == "")
    }
}
