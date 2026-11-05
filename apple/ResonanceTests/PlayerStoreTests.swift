import Foundation
import Testing
import PhosphorCore
import STILKit
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
        state: .stopped, currentIndex: nil, queueActive: false, surpriseActive: false, shuffleCollectionActive: false, track: nil,
        elapsedMs: 0, durationMs: nil,
        shuffle: false, repeat: .off, engine: .sidLite, playlistRevision: 0, trackRevision: 0,
        loading: nil, error: nil, hvscIndexing: [], hvscTreeRevision: 0
    )

    // Library: canned answers, settable per test.
    private var _authors: [HvscAuthorItem] = []
    private var _stil: [String: String] = [:]
    private var _credited: [HvscTuneItem] = []
    private var _surprise: String?
    private var _authorLoads = 0
    private var _stilLoads = 0

    var authorLoads: Int { lock.withLock { _authorLoads } }
    var stilLoads: Int { lock.withLock { _stilLoads } }

    func set(authors: [HvscAuthorItem] = [], stil: [String: String] = [:], surprise: String? = nil) {
        lock.withLock {
            _authors = authors
            _stil = stil
            _surprise = surprise
        }
    }

    /// What `hvscTunesCrediting` finds, whatever it's asked.
    func set(credited: [HvscTuneItem]) {
        lock.withLock { _credited = credited }
    }

    func hvscAuthors(category: HvscCategory) async throws -> [HvscAuthorItem] {
        lock.withLock {
            _authorLoads += 1
            return _authors
        }
    }

    func hvscTunes(authorPath: String) async throws -> [HvscTuneItem] { [] }

    func hvscStil(path: String) async -> String? {
        lock.withLock {
            _stilLoads += 1
            return _stil[path]
        }
    }

    func hvscSearch(query: String, scope: HvscCategory?) async throws -> HvscSearchResult {
        record("search \(query) \(scope.map { "\($0)" } ?? "all")")
        return HvscSearchResult(items: [], totalMatches: 0, indexed: 0)
    }

    private var _recent: [RecentTune] = []
    private var _heard: UInt32 = 0

    func set(recent: [RecentTune], heard: UInt32) { lock.withLock { _recent = recent; _heard = heard } }

    func recentlyPlayed() async throws -> [RecentTune] { lock.withLock { _recent } }
    func heardCount() async -> UInt32 { lock.withLock { _heard } }
    func clearRecentlyPlayed() async {}
    func resetHeard() async {}
    func importFromPhosphor() async -> PhosphorImport {
        record("importFromPhosphor")
        return PhosphorImport(favorites: 2, recentlyPlayed: 1, heard: 0)
    }
    func hvscBugs(path: String) async -> [TuneBug] { [] }

    func hvscTunesAt(paths: [String]) async throws -> [HvscTuneItem] {
        record("tunesAt \(paths.count)")
        return []
    }

    func hvscTunesCrediting(names: [String]) async throws -> [HvscTuneItem] {
        record("crediting \(names.joined(separator: "|"))")
        return lock.withLock { _credited }
    }

    func hvscSurprise(scope: HvscCategory?) async throws -> String? {
        record("surprise \(scope.map { "\($0)" } ?? "all")")
        return lock.withLock { _surprise }
    }

    func surpriseMe() async { record("surpriseMe") }
    func shuffleCollection() async { record("shuffleCollection") }

    func setHvscRoot(root: String?) { record("hvscRoot \(root ?? "nil")") }

    // The collection download: a canned status, and a start that fails on
    // demand.
    private var _sync: HvscSyncStatus?
    private var _syncStartError: HvscError?

    func set(sync: HvscSyncStatus?) { lock.withLock { _sync = sync } }
    func set(syncStartError: HvscError?) { lock.withLock { _syncStartError = syncStartError } }

    private var _hvscInfo: HvscInfo?

    func set(hvscInfo: HvscInfo?) { lock.withLock { _hvscInfo = hvscInfo } }

    func hvscSyncStatus() -> HvscSyncStatus? { lock.withLock { _sync } }
    func hvscInfo() async -> HvscInfo? { lock.withLock { _hvscInfo } }
    func syncPublishedPlaylists(bundled: String?) async throws -> UInt32 { record("syncPlaylists"); return 0 }
    private var _filesTunes: [HvscTuneItem] = []
    func set(filesTunes: [HvscTuneItem]) { lock.withLock { _filesTunes = filesTunes } }
    func tunesFromFiles(paths: [String]) async -> [HvscTuneItem] {
        lock.withLock { _filesTunes.filter { paths.contains($0.path) } }
    }
    private var _composers: [HvscComposer] = []
    func set(composers: [HvscComposer]) { lock.withLock { _composers = composers } }
    func hvscComposers(category: HvscCategory) async throws -> [HvscComposer] { lock.withLock { _composers } }
    func similarComposers(authorPath: String, limit: UInt32) async -> [SimilarComposer] { [] }
    private var _favourites: [String] = []
    func favoritePaths() async -> [String] { lock.withLock { _favourites } }
    func setFavorite(path: String, favorite: Bool) async throws {
        lock.withLock { favorite ? _favourites.insert(path, at: 0) : _favourites.removeAll { $0 == path } }
    }
    func checkHvscUpdate() async throws -> HvscVersionCheck { record("checkHvscUpdate"); return HvscVersionCheck(latest: 86, installed: 85) }
    /// What `findSharedTune` answers; settable per test.
    private var _sharedMatch = SharedTuneMatch(path: nil, sameFile: false, installedHvsc: nil)
    func set(sharedMatch: SharedTuneMatch) { lock.withLock { _sharedMatch = sharedMatch } }
    func shareableTune(path: String) async -> ShareableTune? {
        path.hasSuffix(".sid") ? ShareableTune(md5: "6d019ecba831a9f853675aac29a61c10", hvscPath: "/MUSICIANS/H/Hubbard_Rob/Commando.sid") : nil
    }
    func findSharedTune(md5: String, hvscPath: String?) async -> SharedTuneMatch {
        record("findSharedTune \(md5) \(hvscPath ?? "-")")
        return lock.withLock { _sharedMatch }
    }
    func startHvscSync() throws {
        record("syncStart")
        if let error = lock.withLock({ _syncStartError }) {
            throw error
        }
    }
    func cancelHvscSync() { record("syncCancel") }
    func reloadHvsc() { record("reloadHvsc") }

    func startFingerprintScan() async throws { record("fingerprintScan") }
    func retryFailedFingerprints() async throws { record("retryFingerprints") }
    func importFingerprints(path: String) async throws -> UInt32 { record("importFingerprints"); return 0 }
    func downloadFingerprints() async throws -> UInt32 { record("downloadFingerprints"); return 12 }
    func hasEmbeddings() async -> Bool { false }
    func downloadEmbeddings() async throws -> UInt32 { 0 }
    func rebuildFingerprints() async throws { record("rebuildFingerprints") }
    func stopFingerprintScan() {}
    func setFingerprintScanPaused(paused: Bool) {}
    func fingerprintScanStatus() -> FingerprintScanStatus {
        FingerprintScanStatus(running: false, paused: false, finished: false, pass: 1, total: 0, done: 0, failed: 0, revision: 0, error: nil)
    }
    private var _fingerprints: [String: TuneFingerprint] = [:]
    private var _fingerprintLookups: [[String]] = []

    func set(fingerprints: [String: TuneFingerprint]) { lock.withLock { _fingerprints = fingerprints } }
    var fingerprintLookups: [[String]] { lock.withLock { _fingerprintLookups } }

    func fingerprint(path: String, subtune: UInt16?) async -> TuneFingerprint? { lock.withLock { _fingerprints[path] } }
    func fingerprints(paths: [String]) async -> [TuneFingerprint?] {
        lock.withLock {
            _fingerprintLookups.append(paths.sorted())
            return paths.map { _fingerprints[$0] }
        }
    }
    func similarTunes(path: String, subtune: UInt16?, limit: UInt32) async throws -> [SimilarTune] { [] }
    func similarity(seed: String, paths: [String]) async -> [Float?] {
        lock.withLock { paths.map { _fingerprints[$0] == nil ? nil : ($0 == seed ? 1 : 0.5) } }
    }

    func snapshot() -> Snapshot { lock.withLock { _snapshot } }
    func playlist() -> [PlaylistItem] {
        lock.withLock {
            _playlistFetches += 1
            return _items
        }
    }
    func vizLatest() -> VizSidFrame? { nil }
    func vizHistory(count: UInt32) -> [VizSidFrame] { [] }
    func vizScope(chip: UInt32, count: UInt32) -> VizScopeSamples { VizScopeSamples(sampleRate: 44_784, voices: [[], [], []]) }
    func vizStats() -> VizStats { VizStats(frames: 0, shadowMicros: 0, bufferMs: 100, outputLatencyMs: 12, offsetMs: 0) }
    func setVizOutputLatencyMs(ms: UInt32) {}
    func setVizOffsetMs(ms: Int32) {}

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
            phosphorHvscRoot: { phosphorHvscRoot },
            defaultHvscRoot: phosphorHvscRoot
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
        snapshot.shuffleCollectionActive = true
        snapshot.elapsedMs = 30_000
        snapshot.durationMs = 120_000
        fake.set(snapshot: snapshot)

        store.refresh()

        #expect(store.isPlaying)
        #expect(store.currentIndex == 3)
        #expect(store.queueActive)
        #expect(store.surpriseActive)
        #expect(store.shuffleCollectionActive)
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

    /// Turning Surprise Me off goes back to the playlist row that played.
    @Test func endingSurpriseResumesThePlaylist() {
        let (store, _) = makeStore()
        var snapshot = FakeCore.stoppedSnapshot
        snapshot.state = .playing
        snapshot.currentIndex = 1
        fake.set(snapshot: snapshot, items: [item("a"), item("b"), item("c")])
        store.refresh()
        store.noteBeforeSurprise()

        snapshot.currentIndex = nil
        snapshot.queueActive = true
        snapshot.surpriseActive = true
        fake.set(snapshot: snapshot)
        store.refresh()
        store.endSurprise()

        #expect(fake.calls.last == "play 1")
    }

    @Test func playQueueForwardsPathsAndStart() {
        let (store, _) = makeStore()
        store.playQueue([URL(filePath: "/a.sid"), URL(filePath: "/b.sid")], startAt: URL(filePath: "/b.sid"), from: .files)
        store.playQueue([], startAt: URL(filePath: "/a.sid"), from: .files)

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
        let store = PlayerStore(defaults: defaults, phosphorHvscRoot: { phosphor }, defaultHvscRoot: phosphor) {
            config = $0
            return fake
        }
        return (store, config!)
    }

    @Test func usesTheDefaultFolderUntilOneIsChosen() {
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

    @Test func offersANewerReleaseOnlyForACollection() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _) = makeStore(phosphor: root.path)
        await store.checkHvscUpdate()
        #expect(store.latestHvsc == 86)
        #expect(!store.hvscUpdateAvailable, "no collection to update")

        try FileManager.default.createDirectory(at: root.appending(path: "MUSICIANS"), withIntermediateDirectories: true)
        let (withCollection, _) = makeStore(phosphor: root.path)
        await withCollection.checkHvscUpdate()
        #expect(withCollection.hvscUpdateAvailable, "86 on the mirror, 85 installed")
    }

    @Test func clearingTheFolderSticksAcrossLaunches() {
        let (store, _) = makeStore(phosphor: "/HVSC")
        store.hvscRoot = nil
        let (_, relaunched) = makeStore(phosphor: "/HVSC")
        #expect(relaunched.hvscRoot == nil)
    }
}

@MainActor
struct HvscSyncTests {
    let defaults: UserDefaults
    let fake = FakeCore()

    init() {
        let suite = "ResonanceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeStore(phosphor: String?) -> PlayerStore {
        PlayerStore(defaults: defaults, phosphorHvscRoot: { phosphor }, defaultHvscRoot: phosphor) { _ in fake }
    }

    @Test func startForwardsAndReportsACoresError() async {
        let store = makeStore(phosphor: "/HVSC")
        await store.checkHvscUpdate()
        store.startHvscSync()
        #expect(fake.calls == ["checkHvscUpdate", "syncStart"])
        #expect(store.hvscSyncError == nil)

        fake.set(syncStartError: HvscError.NoRoot)
        store.startHvscSync()
        #expect(store.hvscSyncError == "Choose your HVSC folder in Settings.")
    }

    @Test func aFirstDownloadAsksForTheNewestReleaseFirst() async throws {
        let store = makeStore(phosphor: "/HVSC")
        store.startHvscSync()
        #expect(fake.calls.isEmpty, "waits for the check")
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.calls == ["checkHvscUpdate", "syncStart"])
        #expect(store.latestHvsc == 86)
    }

    @Test func aFinishedDownloadIntoAnUnseenFolderAimsTheAppAtIt() {
        let store = makeStore(phosphor: nil)
        #expect(store.hvscRoot == nil)

        fake.set(sync: HvscSyncStatus(
            root: "/HVSC", running: false, error: nil, current: "Done. 61157 new files.",
            filesDone: 61_157, filesTotal: 61_157, bytesDone: 0, bytesTotal: 0
        ))
        store.refresh()

        #expect(store.hvscSync?.running == false)
        #expect(store.hvscRoot == "/HVSC", "the app now browses what was downloaded")
        #expect(fake.calls.last == "hvscRoot /HVSC")
    }

    @Test func aFinishedDownloadIntoTheSameFolderLeavesTheRootAlone() {
        let store = makeStore(phosphor: "/HVSC")
        fake.set(sync: HvscSyncStatus(
            root: "/HVSC", running: false, error: nil, current: "Done. 5 new files, 61152 already present.",
            filesDone: 61_157, filesTotal: 61_157, bytesDone: 0, bytesTotal: 0
        ))
        store.refresh()

        #expect(store.hvscRoot == "/HVSC")
        #expect(fake.calls.isEmpty, "no redundant setHvscRoot")
    }

    @Test func theTreeRevisionTravelsWithTheSnapshot() {
        let store = makeStore(phosphor: "/HVSC")
        var snapshot = FakeCore.stoppedSnapshot
        snapshot.hvscTreeRevision = 2
        fake.set(snapshot: snapshot)

        store.refresh()
        #expect(store.hvscTreeRevision == 2)
    }
}

@MainActor
struct LibraryStoreTests {
    let fake = FakeCore()

    private func makeLibrary(root: String? = "/HVSC") -> (LibraryStore, PlayerStore) {
        let suite = "ResonanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let player = PlayerStore(defaults: defaults, phosphorHvscRoot: { root }, defaultHvscRoot: root) { _ in fake }
        return (LibraryStore(player: player), player)
    }

    @Test func findsComposersByAnyWordsTheMostProlificFirst() async {
        let (library, _) = makeLibrary()
        let tel = author("Tel_Jeroen", displayName: "Tel, Jeroen")
        let kimmel = author("Kimmel_Jeroen", displayName: "Kimmel, Jeroen")
        let metal = author("Metal")
        fake.set(authors: [kimmel, metal, tel])
        fake.set(composers: [
            HvscComposer(path: tel.path, realName: nil, tunes: 180, firstYear: 1986, lastYear: 2018),
            HvscComposer(path: kimmel.path, realName: nil, tunes: 3, firstYear: nil, lastYear: nil),
            HvscComposer(path: metal.path, realName: "Torben Hansen", tunes: 137, firstYear: nil, lastYear: nil),
        ])
        await library.loadAuthors(.musicians)
        await library.loadComposers(.musicians)

        #expect(library.composers(matching: "jeroen tel", in: .musicians).map(\.name) == ["Tel_Jeroen"])
        #expect(library.composers(matching: "jeroen", in: .musicians).map(\.name) == ["Tel_Jeroen", "Kimmel_Jeroen"])
        #expect(library.composers(matching: "torben", in: .musicians).map(\.name) == ["Metal"], "by real name")
        #expect(library.composers(matching: "jer", in: .musicians).first?.name == "Tel_Jeroen", "a word's start")
    }

    private func author(_ name: String, displayName: String? = nil) -> HvscAuthorItem {
        HvscAuthorItem(name: name, displayName: displayName ?? name, letter: "H", path: "/HVSC/MUSICIANS/H/\(name)")
    }

    @Test func recentHistoryKeepsTheCoresOrderAndTimes() async {
        let (library, _) = makeLibrary()
        let tune = { (title: String) in
            HvscTuneItem(path: "/HVSC/MUSICIANS/H/Hubbard_Rob/\(title).sid", title: title, author: "Rob Hubbard",
                         released: "1985", songs: 1, startSong: 1, durationSecs: nil, hasStil: false,
                         isRsid: false, category: .musicians)
        }
        fake.set(recent: [RecentTune(item: tune("Commando"), playedAt: 2_000),
                          RecentTune(item: tune("Delta"), playedAt: 1_000)], heard: 7)

        await library.loadRecent()
        #expect(library.recent?.map(\.row.title) == ["Commando", "Delta"])
        #expect(library.recent?.first?.playedAt == Date(timeIntervalSince1970: 2_000))
        #expect(library.heardCount == 7)
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

    /// The first-sync case: the folder stays, its tree appears, the core
    /// bumps the revision in the snapshot, and the cached lists go.
    @Test func aTreeRevisionBumpInvalidatesTheCaches() async {
        let (library, player) = makeLibrary()
        fake.set(authors: [author("Hubbard_Rob")])
        await library.loadAuthors(.musicians)
        #expect(fake.authorLoads == 1)

        var snapshot = FakeCore.stoppedSnapshot
        snapshot.hvscTreeRevision = 1
        fake.set(snapshot: snapshot)
        player.refresh()

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

    @Test func composerIsTheFolderTheTuneIsIn() async {
        let (library, _) = makeLibrary(root: "/HVSC/")
        let commando = "/HVSC/MUSICIANS/H/Hubbard_Rob/Commando.sid"
        let early = library.composer(of: track(commando, author: "Rob Hubbard"))
        #expect(early?.name == "Rob Hubbard")
        #expect(early?.authorPath == nil, "no folder before MUSICIANS is loaded")

        fake.set(authors: [author("Hubbard_Rob", displayName: "Hubbard, Rob")])
        await library.loadAuthors(.musicians)
        // The folder wins over the header, whatever it says; its name is
        // the header's spelling when that matches, the folder's otherwise.
        let composer = library.composer(of: track(commando, author: "<?>"))
        #expect(composer?.authorPath == "/HVSC/MUSICIANS/H/Hubbard_Rob")
        #expect(composer?.name == "Rob Hubbard")
        #expect(library.composer(of: track(commando, author: "ROB HUBBARD"))?.name == "ROB HUBBARD")
    }

    @Test func composerMatchesTheHeaderToAComposerFolder() async {
        let (library, _) = makeLibrary()
        fake.set(authors: [author("Hubbard_Rob"), author("Laxity"), author("Tel_Jeroen")])
        await library.loadAuthors(.musicians)
        let composer = { (author: String) in library.composer(of: self.track("/HVSC/GAMES/A-F/X.sid", author: author)) }

        #expect(composer("Rob Hubbard")?.authorPath == "/HVSC/MUSICIANS/H/Hubbard_Rob")
        #expect(composer("Thomas E. Petersen (Laxity)")?.authorPath == "/HVSC/MUSICIANS/H/Laxity")
        #expect(composer("Charles Deenen & Jeroen Tel")?.authorPath == "/HVSC/MUSICIANS/H/Tel_Jeroen")
        #expect(composer("Charles Deenen & Jeroen Tel")?.name == "Jeroen Tel")
        // No composer folder: a card with the header's name and no folder.
        let unfiled = composer("Krzysztof Niedzwiecki (Radius75)")
        #expect(unfiled?.authorPath == nil)
        #expect(unfiled?.name == "Krzysztof Niedzwiecki")
        #expect(unfiled?.subtitle == "Radius75")
        // Nobody named: no card.
        #expect(composer("<?>") == nil)
    }

    @Test func unfiledComposersAreTheHeadersFirstPerson() {
        #expect(LibraryStore.unfiledComposer("Exos") == Composer(authorPath: nil, name: "Exos"))
        #expect(LibraryStore.unfiledComposer("Jeroen Tel & Charles Deenen")
                == Composer(authorPath: nil, name: "Jeroen Tel", subtitle: "with Charles Deenen"))
        #expect(LibraryStore.unfiledComposer("(Fanta)")?.name == "Fanta")
        #expect(LibraryStore.unfiledComposer("<?>") == nil)
        #expect(LibraryStore.unfiledComposer("") == nil)
    }

    @Test func creditedTunesNameTheSamePerson() async {
        let (library, _) = makeLibrary()
        let tune = { (title: String, author: String) in
            HvscTuneItem(
                path: "/HVSC/DEMOS/A-F/\(title).sid", title: title, author: author, released: "1989",
                songs: 1, startSong: 1, durationSecs: nil, hasStil: false, isRsid: nil, category: .demos
            )
        }
        // What the core finds: headers that mention the name anywhere.
        fake.set(credited: [
            tune("Acid 2", "Exos"),
            tune("Creepin Death", "EXOS & Jeff"),
            tune("Bones", "Someone (Exos)"),
            tune("Shell", "Exoskeleton Crew"),
        ])

        await library.loadCredited(name: "Exos")
        #expect(library.credited["Exos"]?.map(\.title) == ["Acid 2", "Creepin Death", "Bones"])
        await library.loadCredited(name: "Exos")
        #expect(fake.calls.filter { $0.hasPrefix("crediting") }.count == 1, "loaded once")
    }

    @Test func tunesKnowWhichPartOfHvscTheyAreIn() {
        let (library, _) = makeLibrary()
        #expect(library.category(of: "/HVSC/DEMOS/A-F/Acid_2.sid") == .demos)
        #expect(library.category(of: "/HVSC/MUSICIANS/H/Hubbard_Rob/Commando.sid") == .musicians)
        #expect(library.category(of: "/HVSC/DOCUMENTS/STIL.txt") == nil)
        #expect(library.category(of: "/Users/me/Music/Tune.sid") == nil)
    }

    @Test func headerAuthorsSplitIntoNamesAndHandles() {
        #expect(LibraryStore.names(in: "Thomas E. Petersen (Laxity)") == ["Thomas E. Petersen", "Laxity"])
        #expect(LibraryStore.names(in: "A & B and C") == ["A & B and C", "A", "B", "C"])
        #expect(LibraryStore.words("Hubbard_Rob") == LibraryStore.words("Rob  Hubbard"))
        #expect(LibraryStore.words("Lukáš") == ["lukas"])
    }

    @Test func namesMatchWithUmlautsSpelledOut() {
        #expect(LibraryStore.sameName("Chris Hülsbeck", "Huelsbeck_Chris"))
        #expect(LibraryStore.sameName("Huelsbeck_Chris", "Chris Hülsbeck"))
        #expect(LibraryStore.sameName("Chris Hülsbeck", "Hulsbeck_Chris"))
        #expect(LibraryStore.sameName("Chris Hu\u{308}lsbeck", "Huelsbeck_Chris"), "decomposed")
        #expect(LibraryStore.sameName("JÖRG STRAUß", "Strauss_Joerg"))
        #expect(LibraryStore.sameName("Mäx", "Maex"))
        #expect(!LibraryStore.sameName("Chris Hülsbeck", "Huelsbeck_Chris_Jr"))
    }

    @Test func composerFolderMatchesAHeaderWithUmlauts() async {
        let (library, _) = makeLibrary()
        fake.set(authors: [author("Huelsbeck_Chris", displayName: "Huelsbeck, Chris")])
        await library.loadAuthors(.musicians)

        // The header's spelling, and who else it credits.
        let rType = library.composer(of: track("/HVSC/MUSICIANS/H/Huelsbeck_Chris/R-Type.sid",
                                               author: "Chris Hülsbeck & Ramiro Vaca"))
        #expect(rType?.name == "Chris Hülsbeck")
        #expect(rType?.subtitle == "with Ramiro Vaca")
        // Filed under GAMES, the header alone finds the folder.
        let game = library.composer(of: track("/HVSC/GAMES/S-Z/X.sid", author: "Chris Hülsbeck"))
        #expect(game?.authorPath == "/HVSC/MUSICIANS/H/Huelsbeck_Chris")
        #expect(game?.name == "Chris Hülsbeck")
    }

    @Test func composerSubtitlesAddTheOtherNamesInTheCredit() {
        #expect(LibraryStore.subtitle(for: "Fanta", in: "Alexander Rotzsch (Fanta)") == "Alexander Rotzsch")
        #expect(LibraryStore.subtitle(for: "Thomas E. Petersen", in: "Thomas E. Petersen (Laxity)") == "Laxity")
        #expect(LibraryStore.subtitle(for: "Jeroen Tel", in: "Jeroen Tel & Charles Deenen") == "with Charles Deenen")
        #expect(LibraryStore.subtitle(for: "Rob Hubbard", in: "Rob Hubbard") == nil)
        #expect(LibraryStore.subtitle(for: "Rob Hubbard", in: "<?>") == nil)
    }

    @Test func composerCardsCarryTheSubtitle() async {
        let (library, _) = makeLibrary()
        fake.set(authors: [author("Fanta")])
        await library.loadAuthors(.musicians)
        let composer = library.composer(of: track("/HVSC/MUSICIANS/F/Fanta/3DEH.sid", author: "Alexander Rotzsch (Fanta)"))
        #expect(composer?.name == "Fanta")
        #expect(composer?.subtitle == "Alexander Rotzsch")
    }

    @Test func composersAreNamedAndInitialledAsSpoken() {
        #expect(LibraryStore.spokenName("Hubbard, Rob") == "Rob Hubbard")
        #expect(LibraryStore.spokenName("Agemixer") == "Agemixer")
        #expect(Composer(authorPath: "", name: "Thomas E. Petersen").initials == "TP")
        #expect(Composer(authorPath: "", name: "Agemixer").initials == "A")
        #expect(Composer(authorPath: "", name: "<?>").initials == "")
    }

    @Test func stilIsLoadedOncePerPathAndParsedHere() async throws {
        let (library, player) = makeLibrary()
        let hubbard = "/HVSC/MUSICIANS/H/Hubbard_Rob"
        let commando = "/HVSC/MUSICIANS/H/Hubbard_Rob/Commando.sid"
        let folder = """
            /MUSICIANS/H/Hubbard_Rob/
            COMMENT: Hubbard's own comments are denoted (RH).
            """
        fake.set(stil: [
            hubbard: folder,
            commando: folder + """


                /MUSICIANS/H/Hubbard_Rob/Commando.sid
                COMMENT: "I got my cheque and was on a train home by 10.00 am..." (RH)
                """,
        ])

        await library.loadStil(path: commando, sidAuthor: "Rob Hubbard")
        await library.loadStil(path: commando, sidAuthor: "Rob Hubbard")
        await library.loadStil(path: "/HVSC/MUSICIANS/G/Galway_Martin")
        #expect(fake.stilLoads == 2)
        let quote = try #require(library.stil[commando] ?? nil).sections[0].comments[0].blocks[0]
        #expect(quote.kind == .quote)
        #expect(quote.by == "Rob Hubbard", "the folder declares (RH)")
        #expect(quote.role == .composer)
        #expect(quote.paragraphs[0].map(\.t).joined() == "I got my cheque and was on a train home by 10.00 am\u{2026}")
        #expect(library.stil["/HVSC/MUSICIANS/G/Galway_Martin"] == .some(nil), "none is remembered too")

        await library.loadStil(path: hubbard)
        #expect(library.stil[hubbard]??.path == "/MUSICIANS/H/Hubbard_Rob/")

        player.hvscRoot = "/Other"
        await library.loadStil(path: commando)
        #expect(fake.stilLoads == 4)
    }

    @Test func stilLinksRevealTheirTuneInItsSection() {
        let (library, _) = makeLibrary()
        library.reveal(hvscPath: "/GAMES/A-F/Catalypse.sid")
        #expect(library.reveal?.category == .games)
        #expect(library.reveal?.authorPath == "/HVSC/GAMES/A-F")
        #expect(library.reveal?.tunePath == "/HVSC/GAMES/A-F/Catalypse.sid")
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

struct InspectorHeaderTests {
    @Test func releasedFieldReadsAsASentence() {
        #expect(NowPlayingInspector.released("1985 Gremlin Graphics") == "Released 1985 by Gremlin Graphics")
        #expect(NowPlayingInspector.released("1987-88 Ocean") == "Released 1987-88 by Ocean")
        #expect(NowPlayingInspector.released("198? Zzap") == "Released 198? by Zzap")
        #expect(NowPlayingInspector.released("2009") == "Released 2009")
        #expect(NowPlayingInspector.released("Oxyron") == "Released by Oxyron")
        // HVSC's unknowns say nothing.
        #expect(NowPlayingInspector.released("19?? Taboo") == "Released by Taboo")
        #expect(NowPlayingInspector.released("1986 <?>") == "Released 1986")
        #expect(NowPlayingInspector.released("<?>") == nil)
        #expect(NowPlayingInspector.released("") == nil)
    }
}

struct StilNotesTests {
    /// Commando, as STIL has it: the composer's quote on the file, a medley
    /// as song 1, an unknown title as song 3.
    private let commando = STILEntry.parsing("""
        /MUSICIANS/H/Hubbard_Rob/
        COMMENT: Hubbard's own comments are denoted (RH).

        /MUSICIANS/H/Hubbard_Rob/Commando.sid
        COMMENT: "There is an interesting story behind Commando." (RH)
        (#1)
          TITLE: BGM1 [from the arcade game Commando] (0:00)
         ARTIST: Tamayo Kawamoto
          TITLE: Base [from the arcade game Commando] (0:53)
         ARTIST: Tamayo Kawamoto
        (#3)
          TITLE: <?> [from the arcade game Commando]
         ARTIST: Tamayo Kawamoto
        """, sidAuthor: "Rob Hubbard")!

    private func headings(_ cards: [StilNotesView.Card]) -> [String] {
        cards.map {
            switch $0 {
            case .memorial(let m): "memorial \(m.name)"
            case .section(_, .file(let quote)): quote ? "file quote" : "file"
            case .section(_, .song(let n)): "song \(n)"
            case .noNotes(let n): "no notes \(n)"
            }
        }
    }

    @Test func theFileComesFirstThenThePlayingSong() {
        #expect(headings(StilNotesView.cards(commando, song: 1, songs: 3)) == ["file quote", "song 1"])
        #expect(headings(StilNotesView.cards(commando, song: 3, songs: 3)) == ["file quote", "song 3"])
    }

    @Test func aSongWithoutNotesSaysSoWhenOthersHaveThem() {
        #expect(headings(StilNotesView.cards(commando, song: 2, songs: 3)) == ["file quote", "no notes 2"])
        let fileOnly = STILEntry.parsing("""
            /DEMOS/0-9/3_Oversample.sid
              TITLE: Get Ready
             ARTIST: Jeroen Tel
            COMMENT: Same as /MUSICIANS/T/Tel_Jeroen/Get_Ready.sid, but with digis added.
            """, sidAuthor: nil)!
        #expect(headings(StilNotesView.cards(fileOnly, song: 2, songs: 3)) == ["file"])
    }

    @Test func remembrancesGetACardOfTheirOwn() {
        let miles = STILEntry.parsing("""
            /DEMOS/0-9/53_Miles_West_of_Venus.sid
            COMMENT: Sadly, Radek Stypczynski passed away on May 6th, 2011.
            """, sidAuthor: nil)!
        #expect(headings(StilNotesView.cards(miles, song: 1, songs: 1)) == ["memorial Radek Stypczynski"])
        let (memorials, _) = miles.splittingMemorials()
        #expect(memorials.first?.details == "On May 6th, 2011.")
    }

    @Test func aMemorialLeavesTheRestOfItsCommentInTheNotes() {
        let ben = STILEntry.parsing("""
            /MUSICIANS/D/Daglish_Ben/
            COMMENT: Comments from Ben Daglish are denoted (BD)
                     Q: Is it Ben or Benn?
                     A: "Ben is my real name." (BD)
                     Sadly, Ben Daglish passed away on October 1st, 2018, at the age of 52,
                     due to complications from lung cancer.
            """, sidAuthor: nil)!
        let (memorials, rest) = ben.splittingMemorials()
        #expect(memorials == [STILMemorial(
            name: "Ben Daglish",
            details: "On October 1st, 2018, at the age of 52, due to complications from lung cancer.")])
        #expect(rest.sections[0].comments[0].blocks.map(\.kind) == [.note, .question, .quote])
    }

    @Test func theTeaserIsTheFirstThingStilSays() {
        let teaser = Teaser(commando)
        #expect(teaser?.isQuote == true)
        #expect(teaser?.plain == "\u{201C}There is an interesting story behind Commando.\u{201D} \u{2014} Rob Hubbard")
        let note = STILEntry.parsing("""
            /MUSICIANS/M/Mega_Apocalypse.sid
            COMMENT: Mega Apocalypse was the sequel to Crazy Comets. It has more.
            """, sidAuthor: nil)!
        #expect(Teaser(note)?.plain == "Mega Apocalypse was the sequel to Crazy Comets.")
    }

    @Test func theEpitaphSaysWhenTheyPassedAway() {
        #expect(MemorialCard.passed("On May 6th, 2011.") == "Passed away on May 6th, 2011")
        #expect(MemorialCard.passed(nil) == "Passed away")
    }

    @Test func initialsInANameDontEndTheSentence() {
        let (memorial, rest) = STILMemorial.find(in: "Sadly, Scott T. Etherton passed away on April 20th, 2001. He wrote it.")!
        #expect(memorial.name == "Scott T. Etherton")
        #expect(memorial.details == "On April 20th, 2001.")
        #expect(rest.location == 0)
    }

    @Test func passingMentionsArentMemorials() {
        let ninja = STILEntry.parsing("""
            /MUSICIANS/D/Daglish_Ben/Last_Ninja.sid
            COMMENT: Since Anthony passed away, we can't verify it anymore.
            """, sidAuthor: nil)!
        #expect(headings(StilNotesView.cards(ninja, song: 1, songs: 1)) == ["file"])
    }

    @Test func aNoteThatOnlyRelatesToATuneBecomesALinkCard() {
        let remix = [STILRun(t: "Remix of "), STILRun(t: "/MUSICIANS/O/Ouwehand_Reyn/Peppered_Pizza.sid", link: "/MUSICIANS/O/Ouwehand_Reyn/Peppered_Pizza.sid")]
        #expect(RelationLink(remix)?.relation == "Remix of")
        #expect(RelationLink(remix)?.hvscPath == "/MUSICIANS/O/Ouwehand_Reyn/Peppered_Pizza.sid")
        // More to say stays a sentence with the link in it.
        #expect(RelationLink(remix + [STILRun(t: ", but with digis added.")]) == nil)
        #expect(RelationLink([STILRun(t: "Composed for "), remix[1]]) == nil)
    }

    @Test func theSongMenuNamesSongsFromStil() {
        let names = STILEntry.parsing("""
            /DEMOS/A-F/Battle_Hymn.sid
            (#1)
               NAME: Two Violins
              TITLE: Something Else
            (#2)
              TITLE: Shades
            """, sidAuthor: nil)
        #expect(NowPlayingBar.songTitle(nil, song: 2) == "Song 2")
        #expect(NowPlayingBar.songTitle(names, song: 1) == "Song 1: Two Violins")
        #expect(NowPlayingBar.songTitle(names, song: 2) == "Song 2: Shades")
        #expect(NowPlayingBar.songTitle(commando, song: 1) == "Song 1: Medley")
        #expect(NowPlayingBar.songTitle(commando, song: 3) == "Song 3", "its title is <?>")
        #expect(NowPlayingBar.songTitle(commando, song: 2) == "Song 2")
    }

    @Test func linkedTunesAreNamedByTheirFileUntilTheirHeaderIsRead() {
        #expect(LinkedTune.fallbackTitle("/MUSICIANS/T/Tel_Jeroen/Get_Ready.sid") == "Get Ready")
        #expect(StilLink.path(StilLink.url("/GAMES/A-F/Catalypse.sid")!) == "/GAMES/A-F/Catalypse.sid")
        #expect(StilLink.path(URL(string: "https://hvsc.c64.org")!) == nil)
    }
}

struct VisualizerFeedTests {
    // Frequencies, notes and the rest of the register decoding are tested
    // in the core (core/src/viz/tests.rs).

    private func voice(waveform: UInt8) -> VizVoice {
        VizVoice(
            freqReg: 7493, hz: 440, midi: 69, note: "A4", gate: true, waveform: waveform,
            test: false, ring: false, sync: false, pulseWidth: 0x800,
            attack: 0, decay: 0, sustain: 15, release: 0, envLevel: 1, envPhase: .sustain
        )
    }

    @Test func namesWaveforms() {
        #expect(voice(waveform: 0x4).waveformName == "PUL")
        #expect(voice(waveform: 0x6).waveformName == "SAW+PUL")
        #expect(voice(waveform: 0x9).waveformName == "TRI+NOI")
        #expect(voice(waveform: 0).waveformName == "")
    }

    private func envelope(_ phase: EnvelopePhase, level: Float, sustain: UInt8 = 6) -> VizVoice {
        VizVoice(
            freqReg: 7493, hz: 440, midi: 69, note: "A4", gate: phase != .release, waveform: 0x4,
            test: false, ring: false, sync: false, pulseWidth: 0x800,
            attack: 2, decay: 4, sustain: sustain, release: 3, envLevel: level, envPhase: phase
        )
    }

    @Test func envelopeDotRidesTheShape() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let shape = EnvelopeShape(envelope(.attack, level: 0), in: rect)
        let p = shape.points
        // Halfway up the attack, at the plateau, partway down the decay.
        #expect(shape.dot(for: envelope(.attack, level: 0.5), releasedFrom: 1) == CGPoint(x: p[1].x / 2, y: 50))
        #expect(shape.dot(for: envelope(.sustain, level: 0.4), releasedFrom: 1)?.y == p[2].y)
        let decaying = shape.dot(for: envelope(.decay, level: 0.7), releasedFrom: 1)!
        #expect(decaying.x > p[1].x && decaying.x < p[2].x)
        // A release that began at 0.4 is halfway down at 0.2, gone at 0.
        let releasing = shape.dot(for: envelope(.release, level: 0.2), releasedFrom: 0.4)!
        #expect(abs(releasing.x - (p[3].x + p[4].x) / 2) < 0.001)
        #expect(shape.dot(for: envelope(.release, level: 0), releasedFrom: 0.4) == nil)
    }

    @Test func haloRingsRestAsCirclesAndWobbleWhenSounding() {
        let halo = HaloShape()
        let start = Date()
        halo.update(voices: [], frame: nil, at: start)
        #expect(halo.radii.count == 3 * HaloShape.samples)
        for v in 0..<3 {
            let ring = halo.radii[v * HaloShape.samples..<(v + 1) * HaloShape.samples]
            #expect(ring.allSatisfy { $0 == HaloShape.baseRadii[v] })
        }

        var saw = envelope(.sustain, level: 1)
        saw.waveform = 0x2
        // Half a second at 60 fps.
        for n in 1...30 {
            halo.update(voices: [saw], frame: UInt64(n), at: start + Double(n) / 60)
        }
        let ring = halo.radii.prefix(HaloShape.samples)
        #expect(ring.max()! - ring.min()! > 0.1)
        #expect(halo.levels[0] > 0.99 && halo.levels[1] == 0)
    }

    /// How much of harmonic `k` a wave's ring has, by a plain DFT.
    private func harmonic(_ k: Int, of wave: HaloShape.Wave) -> Double {
        var re = 0.0, im = 0.0
        for j in 0..<256 {
            let theta = 2 * Double.pi * Double(j) / 256
            let s = Double(wave.shape(at: theta, time: 0))
            re += s * cos(Double(k) * theta)
            im += s * sin(Double(k) * theta)
        }
        return hypot(re, im) / 128
    }

    @Test func haloShapeFollowsTheWaveform() {
        let saw = HaloShape.Wave(waveform: 0x2, pulseWidth: 0.5, noiseSeed: 0)
        let pulse = HaloShape.Wave(waveform: 0x4, pulseWidth: 0.5, noiseSeed: 0)
        // Saw has every harmonic at 1/k; pulse only odd ones.
        #expect(abs(harmonic(2, of: saw) - 0.5) < 0.01)
        #expect(harmonic(2, of: pulse) < 1e-6)
        #expect(harmonic(3, of: pulse) > 0.5)
        // The pulse width shapes it: at a third, the 3rd harmonic vanishes.
        let third = HaloShape.Wave(waveform: 0x4, pulseWidth: 1.0 / 3, noiseSeed: 0)
        #expect(harmonic(3, of: third) < 1e-6)
    }

    @Test func haloNoiseChangesOnlyWithTheFrame() {
        let a = HaloShape.Wave(waveform: 0x8, pulseWidth: 0.5, noiseSeed: 7)
        let b = HaloShape.Wave(waveform: 0x8, pulseWidth: 0.5, noiseSeed: 7)
        let c = HaloShape.Wave(waveform: 0x8, pulseWidth: 0.5, noiseSeed: 8)
        #expect(a.shape(at: 1, time: 0) == b.shape(at: 1, time: 0))
        #expect(a.shape(at: 1, time: 0) != c.shape(at: 1, time: 0))
    }

    @Test func spectrumFindsASinesBand() {
        let spectrum = VoiceSpectrum()
        let rate: Float = 44_800
        let sine = (0..<VoiceSpectrum.size).map { sin(2 * Float.pi * 440 * Float($0) / rate) }
        let bands = spectrum.bands(of: sine, sampleRate: rate)
        let ratio = VoiceSpectrum.highHz / VoiceSpectrum.lowHz
        let band = Int(log(440 / VoiceSpectrum.lowHz) / log(ratio) * Float(VoiceSpectrum.bands))
        // Full scale reads as 0 dB; two octaves away it's far down.
        #expect(abs(bands[band] - 1) < 0.05)
        #expect(bands[band + 2 * VoiceSpectrum.bands / 8] < 0.5)
        #expect(spectrum.bands(of: [Float](repeating: 0, count: 2048), sampleRate: rate).allSatisfy { $0 == 0 })
    }

    @Test func spectrumRisesFastAndFallsSlowly() {
        let spectrum = VoiceSpectrum()
        let rate: Float = 44_800
        let sine = (0..<VoiceSpectrum.size).map { sin(2 * Float.pi * 440 * Float($0) / rate) }
        let start = Date()
        spectrum.update(voices: [sine], sampleRate: rate, at: start)
        spectrum.update(voices: [sine], sampleRate: rate, at: start + 1.0 / 60)
        let peak = spectrum.levels.prefix(VoiceSpectrum.bands).max()!
        #expect(peak > 0.4)
        spectrum.update(voices: [], sampleRate: rate, at: start + 2.0 / 60)
        #expect(spectrum.levels.prefix(VoiceSpectrum.bands).max()! > peak * 0.8)
    }

    private func frame(_ index: UInt64, gate: Bool) -> VizSidFrame {
        var v = envelope(.sustain, level: gate ? 1 : 0)
        v.gate = gate
        let chip = VizChip(voices: [v, v, v], registers: Data(count: 29), cutoff: 0,
                           resonance: 0, filterRouting: 0, filterMode: 0, volume: 15)
        return VizSidFrame(index: index, isPal: true, chips: [chip])
    }

    @Test func particleWaveStartsOnANewNote() {
        let sphere = ParticleSphere()
        let start = Date()
        sphere.update(history: [frame(1, gate: false)], at: start)
        #expect(sphere.hits[0] < 0)
        // The gate opened in a frame not seen yet.
        sphere.update(history: [frame(1, gate: false), frame(2, gate: true)], at: start + 0.02)
        let hit = sphere.hits[0]
        #expect(abs(hit - 0.02) < 1e-5)
        // Seen already: no new wave.
        sphere.update(history: [frame(1, gate: false), frame(2, gate: true)], at: start + 0.04)
        #expect(sphere.hits[0] == hit)
        #expect(sphere.levels[0] > 0)
    }

    @Test func meterHoldsASustainAndSoftensADrop() {
        let meter = VoiceMeter()
        let start = Date()
        meter.update(levels: [0.5], at: start)
        meter.update(levels: [0.5], at: start + 0.5)
        #expect(meter.levels == [0.5])

        // One 30 fps reference frame after the envelope drops to zero.
        meter.update(levels: [0], at: start + 0.5 + 1.0 / 30)
        #expect(abs(meter.levels[0] - 0.5 * 0.92) < 1e-6)
        #expect(meter.peaks[0] > meter.levels[0] && meter.peaks[0] < 0.5)
    }

    /// A saw at `hz`, `count` samples long, starting `offset` samples in.
    private func saw(hz: Double, offset: Int, count: Int = 2048) -> [Float] {
        (0..<count).map { n in
            let phase = Double(n + offset) * hz / 44_784
            return Float(2 * (phase - phase.rounded(.down)) - 1)
        }
    }

    @Test func triggerHoldsAWaveformStillAcrossFrames() {
        // Two display frames whose sample windows end at different points
        // of the wave: both should start at the same point of it.
        let a = ScopeTrigger.window(saw(hz: 440, offset: 0), hz: 440, sampleRate: 44_784, pitched: true)
        let b = ScopeTrigger.window(saw(hz: 440, offset: 37), hz: 440, sampleRate: 44_784, pitched: true)
        #expect(a.count == b.count)
        #expect(abs(Double(a.count) - 2.5 * 44_784 / 440) < 2)
        for (x, y) in zip(a.prefix(200), b.prefix(200)) {
            #expect(abs(x - y) < 0.05)
        }
        #expect(abs(a.first!) < 0.05)
    }

    @Test func triggerFallsBackForNoiseAndLowNotes() {
        let samples = saw(hz: 440, offset: 0)
        #expect(ScopeTrigger.window(samples, hz: 440, sampleRate: 44_784, pitched: false).count == 512)
        // 30 Hz: a period is ~1500 samples, so fewer cycles fit, but a
        // crossing still has room to be found.
        let low = ScopeTrigger.window(saw(hz: 30, offset: 0), hz: 30, sampleRate: 44_784, pitched: true)
        #expect(low.count >= ScopeTrigger.minLength && low.count + 44_784 / 30 < 2048)
        #expect(ScopeTrigger.window([], hz: 440, sampleRate: 44_784, pitched: true).isEmpty)
    }
}
