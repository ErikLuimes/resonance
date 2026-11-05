import Foundation
import Observation
import PhosphorCore

/// The app's single source of playback truth.
///
/// Wraps the Rust `PlayerCore`: commands go straight through (they never
/// block), and a polling loop copies the core's published snapshot into
/// observable properties at 20 Hz. Each property is only assigned when its
/// value changes, so views re-render for what actually moved — the progress
/// bar while playing, the table only when the playlist revision bumps.
///
/// Settings live here too, persisted to UserDefaults and pushed to the core
/// on change, so the Settings window, menus and toolbar all bind to one place.
@Observable
final class PlayerStore {
    // MARK: Playback state (read from the core)

    private(set) var state: PlaybackState = .stopped
    /// The playlist row that's playing; nil while a library queue plays.
    private(set) var currentIndex: Int?
    /// Playing a temporary list of library tunes rather than the playlist.
    private(set) var queueActive = false
    /// That list is Surprise Me's endless random one.
    private(set) var surpriseActive = false
    /// That list is Shuffle Collection's walk through all of HVSC.
    private(set) var shuffleCollectionActive = false
    /// Where the playing temporary list came from (whatever started it
    /// says); nil while none plays.
    private(set) var queueSource: PlaybackSource?
    /// That list's tunes in order, for the menu bar player's Up Next; kept
    /// after it ends (check `queueActive`).
    private(set) var queue: [QueuedTune] = []
    /// What played before Surprise Me took over, which `endSurprise()`
    /// goes back to.
    @ObservationIgnored private var beforeSurprise: Resume?

    /// A list to go back to, at the tune that was playing.
    private enum Resume {
        case playlist(index: Int)
        case queue([QueuedTune], source: PlaybackSource, at: String)
    }
    private(set) var nowPlaying: TrackDetails?
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval?
    private(set) var rows: [TrackRow] = []
    private(set) var loading: String?
    private(set) var error: String?
    /// Changes on every track or subtune switch.
    private(set) var trackRevision: UInt64 = 0
    /// HVSC categories whose search index is being built.
    private(set) var hvscIndexing: [HvscCategory] = []
    /// Changes when the collection folder changes on disk (a new root, or
    /// the first sync filling the current one); the library drops its
    /// caches on a change.
    private(set) var hvscTreeRevision: UInt64 = 0

    // MARK: HVSC collection download (from the core)

    /// The download's latest status; nil until one has been started.
    private(set) var hvscSync: HvscSyncStatus?
    /// A failed `startHvscSync()` (no folder to download into, and no
    /// default either).
    private(set) var hvscSyncError: String?
    /// The HVSC Home's parsed metadata (release, latest update, counts,
    /// playlists, disks); refreshed on a tree-revision change.
    private(set) var hvscInfo: HvscInfo?
    /// The tree revision `hvscInfo` was read at.
    @ObservationIgnored private var hvscInfoRevision: UInt64?
    /// The newest release on the mirror; nil until checked.
    private(set) var latestHvsc: UInt32?
    private(set) var isCheckingHvscUpdate = false
    /// Why the last update check failed.
    private(set) var hvscUpdateError: String?
    /// The installed release, as checked against the mirror.
    @ObservationIgnored private var checkedHvsc: UInt32?
    /// The check in flight, which later callers wait for.
    @ObservationIgnored private var updateCheck: Task<Void, Never>?

    // MARK: Settings (persisted, pushed to the core)

    var engine: Engine {
        didSet {
            guard engine != oldValue else { return }
            defaults.set(engine.storageValue, forKey: Pref.engine)
            core.setEngine(engine: engine)
        }
    }

    /// 0...1
    var volume: Double {
        didSet {
            // Re-assigning runs didSet again, so only do it when clamping
            // actually changes the value.
            let clamped = min(max(volume, 0), 1)
            if clamped != volume {
                volume = clamped
                return
            }
            guard volume != oldValue else { return }
            defaults.set(volume, forKey: Pref.volume)
            core.setVolume(volume: Float(volume))
        }
    }

    var shuffle: Bool {
        didSet {
            guard shuffle != oldValue else { return }
            defaults.set(shuffle, forKey: Pref.shuffle)
            core.setShuffle(on: shuffle)
        }
    }

    var repeatMode: Repeat {
        didSet {
            guard repeatMode != oldValue else { return }
            defaults.set(repeatMode.storageValue, forKey: Pref.repeatMode)
            core.setRepeat(repeat: repeatMode)
        }
    }

    var options: PlaybackOptions {
        didSet {
            guard options != oldValue else { return }
            options.save(to: defaults)
            core.setOptions(options: options)
        }
    }

    /// The HVSC collection's root folder (the one holding MUSICIANS/), or
    /// nil when there's none.
    var hvscRoot: String? {
        didSet {
            guard hvscRoot != oldValue else { return }
            // "" records an explicit "none", so Phosphor's folder isn't
            // picked up again on the next launch.
            defaults.set(hvscRoot ?? "", forKey: Pref.hvscRoot)
            core.setHvscRoot(root: hvscRoot)
        }
    }

    /// Whether the folder actually holds a collection: any of MUSICIANS,
    /// GAMES or DEMOS is there. Reading the tree revision makes the views
    /// re-check when the first sync fills the folder in place.
    var hasCollection: Bool {
        _ = hvscTreeRevision
        guard let root = hvscRoot else { return false }
        return Self.holdsCollection(root)
    }

    nonisolated static func holdsCollection(_ root: String) -> Bool {
        let folder = URL(filePath: root)
        return ["MUSICIANS", "GAMES", "DEMOS"].contains {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
    }

    /// Set by menu commands; the main window presents the file importer.
    var isImporting = false

    /// The main window's Now Playing mode: the Halo and the playing tune
    /// over the whole window, instead of the library.
    var isShowingNowPlaying = false

    /// Into or out of Now Playing; the window animates the change.
    func toggleNowPlaying() {
        isShowingNowPlaying.toggle()
    }

    /// A shared tune link waiting to be opened: the main window shows it
    /// in a sheet.
    var sharedTune: SharedTuneLink?

    let core: any PlayerCoreProtocol
    /// The visualizers' shared per-frame read (see `VisualizerFeed`).
    @ObservationIgnored let vizFrames = FrameCache()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let phosphorHvscRoot: () -> String?
    /// Where Download puts the collection, in Resonance's own folder.
    @ObservationIgnored let downloadHvscRoot: String?
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var playlistRevision: UInt64?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Reads the saved settings from `defaults` and starts a core configured
    /// with them via `makeCore`. Until an HVSC folder is chosen (or
    /// imported from Phosphor, `phosphorHvscRoot`), it's `defaultHvscRoot`,
    /// where Download puts the collection.
    init(
        defaults: UserDefaults = .standard,
        sessionPath: URL = AppPaths.sessionPlaylist,
        phosphorHvscRoot: @escaping () -> String? = { sharedDefaults().hvscRoot },
        defaultHvscRoot: String? = AppPaths.hvscDirectory.path,
        makeCore: (CoreConfig) -> any PlayerCoreProtocol
    ) {
        let engine = Engine(storageValue: defaults.string(forKey: Pref.engine)) ?? .reSidFp
        let volume = defaults.object(forKey: Pref.volume) as? Double ?? 0.8
        let shuffle = defaults.bool(forKey: Pref.shuffle)
        let repeatMode = Repeat(storageValue: defaults.string(forKey: Pref.repeatMode)) ?? .off
        let options = PlaybackOptions(from: defaults)
        let hvscRoot = (defaults.object(forKey: Pref.hvscRoot) as? String)
            .map { $0.isEmpty ? nil : $0 } ?? defaultHvscRoot
        self.defaults = defaults
        self.phosphorHvscRoot = phosphorHvscRoot
        self.downloadHvscRoot = defaultHvscRoot
        self.engine = engine
        self.volume = volume
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.options = options
        self.hvscRoot = hvscRoot
        core = makeCore(CoreConfig(
            engine: engine,
            volume: Float(volume),
            options: options,
            shuffle: shuffle,
            repeat: repeatMode,
            sessionPath: sessionPath.path,
            hvscRoot: hvscRoot
        ))
    }

    /// The real player.
    static func live() -> PlayerStore {
        PlayerStore { PlayerCore(config: $0) }
    }

    // MARK: Polling

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Copy the core's latest snapshot into the observable properties.
    func refresh() {
        let s = core.snapshot()
        if s.playlistRevision != playlistRevision {
            playlistRevision = s.playlistRevision
            rows = core.playlist().enumerated().map { TrackRow(index: $0.offset, item: $0.element) }
        }
        update(\.state, s.state)
        update(\.currentIndex, s.currentIndex.map(Int.init))
        // The queue ended, or Surprise Me took over: it's no longer the
        // published playlist that plays. (Not on a still-inactive queue: a
        // queue just started shows up a snapshot later.)
        if (queueActive && !s.queueActive) || s.surpriseActive || s.shuffleCollectionActive {
            update(\.queueSource, nil)
        }
        update(\.queueActive, s.queueActive)
        update(\.surpriseActive, s.surpriseActive)
        update(\.shuffleCollectionActive, s.shuffleCollectionActive)
        update(\.nowPlaying, s.track)
        update(\.elapsed, TimeInterval(s.elapsedMs) / 1000)
        update(\.duration, s.durationMs.map { TimeInterval($0) / 1000 })
        update(\.loading, s.loading)
        update(\.error, s.error)
        update(\.trackRevision, s.trackRevision)
        update(\.hvscIndexing, s.hvscIndexing)
        update(\.hvscTreeRevision, s.hvscTreeRevision)

        let sync = core.hvscSyncStatus()
        update(\.hvscSync, sync)
        // A finished download into a folder the app isn't pointing at yet:
        // start browsing what just arrived.
        if let sync, !sync.running, sync.error == nil, hvscRoot != sync.root {
            hvscRoot = sync.root
        }
        if let sync, !sync.running { hvscSyncError = nil }
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<PlayerStore, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    // MARK: Commands

    func add(_ urls: [URL], playFirst: Bool = false) {
        guard !urls.isEmpty else { return }
        core.addPaths(paths: urls.map(\.path), playFirst: playFirst)
    }

    func play(index: Int) {
        core.playIndex(index: UInt32(index))
    }

    /// Play `urls` as a temporary list from `start`, leaving the playlist
    /// alone; Next and Previous stay inside the list. `source` is where
    /// the list comes from, which "Playing from" names.
    /// `tunes` names them for Up Next; without, their file names do.
    func playQueue(_ urls: [URL], startAt start: URL, from source: PlaybackSource, tunes: [QueuedTune]? = nil) {
        guard !urls.isEmpty else { return }
        core.playQueue(paths: urls.map(\.path), start: start.path)
        update(\.queueSource, source)
        queue = tunes ?? urls.map(QueuedTune.init)
    }

    /// Note what's playing, for `endSurprise()`, as Surprise Me starts.
    /// Not while it runs already: the list to go back to is the one
    /// before it.
    func noteBeforeSurprise() {
        guard !surpriseActive else { return }
        if queueActive, !shuffleCollectionActive, let source = queueSource, let path = nowPlaying?.path {
            beforeSurprise = .queue(queue, source: source, at: path)
        } else if !queueActive, let index = currentIndex {
            beforeSurprise = .playlist(index: index)
        } else {
            beforeSurprise = nil
        }
    }

    /// The list `endSurprise()` goes back to; nil when there's none.
    var beforeSurpriseSource: PlaybackSource? {
        switch beforeSurprise {
        case .playlist: .myPlaylist
        case .queue(_, let source, _): source
        case nil: nil
        }
    }

    /// Turn Surprise Me off: back to the list that played before it, at
    /// the tune it left; with none, just pause.
    func endSurprise() {
        guard surpriseActive else { return }
        switch beforeSurprise {
        case .playlist(let index) where index < rows.count:
            play(index: index)
        case .queue(let tunes, let source, let path) where !tunes.isEmpty:
            playQueue(tunes.map { URL(filePath: $0.path) }, startAt: URL(filePath: path), from: source, tunes: tunes)
        default:
            if isPlaying { playPause() }
        }
        beforeSurprise = nil
    }

    /// Where what's playing comes from; nil when nothing does.
    var source: PlaybackSource? {
        if surpriseActive { return .surprise }
        if shuffleCollectionActive { return .shuffleCollection }
        if queueActive { return queueSource }
        return currentIndex != nil ? .myPlaylist : nil
    }

    /// Pause / resume; when stopped, start `fallback` (the selection).
    func playPause(fallback: Int? = nil) {
        core.playPause(fallback: fallback.map(UInt32.init))
    }

    func stop() { core.stop() }
    func next() { core.next() }
    func previous() { core.previous() }
    func nextSubtune() { core.nextSubtune() }
    func previousSubtune() { core.prevSubtune() }

    func setSubtune(_ song: Int) {
        core.setSubtune(song: UInt16(clamping: song))
    }

    func remove(indices: some Sequence<Int>) {
        core.remove(indices: indices.map(UInt32.init))
    }

    /// Same semantics as `Array.move(fromOffsets:toOffset:)`.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        core.moveEntries(from: offsets.map(UInt32.init), to: UInt32(destination))
    }

    func clear() { core.clear() }

    func nudgeVolume(by delta: Double) {
        volume += delta
    }

    func cycleRepeat() {
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    /// Use the HVSC folder Phosphor is configured with (or downloaded to).
    func usePhosphorHvscRoot() {
        hvscRoot = phosphorHvscRoot()
    }

    // MARK: HVSC collection download

    /// Begin downloading the newest release into the current HVSC folder,
    /// or Phosphor's default folder when none is set. Progress arrives
    /// through `hvscSync` at the snapshot rate. Before the mirror has been
    /// asked for its newest release, it's asked first; if it can't say, the
    /// core falls back to the release it knows.
    func startHvscSync() {
        guard hvscSync?.running != true else { return }
        if latestHvsc == nil, hvscUpdateError == nil {
            Task {
                await checkHvscUpdate()
                startHvscSync()
            }
            return
        }
        do {
            try core.startHvscSync()
            hvscSyncError = nil
        } catch {
            hvscSyncError = LibraryStore.message(for: error)
        }
    }

    /// Cancel a running download; the next start resumes where it stopped
    /// (files already on disk are skipped).
    func cancelHvscSync() {
        core.cancelHvscSync()
    }

    /// Ask the mirror for its newest release; `startHvscSync()` then
    /// downloads that one.
    func checkHvscUpdate() async {
        if let updateCheck { return await updateCheck.value }
        let check = Task { await runHvscUpdateCheck() }
        updateCheck = check
        isCheckingHvscUpdate = true
        await check.value
        updateCheck = nil
        isCheckingHvscUpdate = false
    }

    private func runHvscUpdateCheck() async {
        do {
            let check = try await core.checkHvscUpdate()
            latestHvsc = check.latest
            checkedHvsc = check.installed
            hvscUpdateError = nil
        } catch {
            hvscUpdateError = LibraryStore.message(for: error)
        }
    }

    /// The installed release: the collection's HVSC.txt, else what the
    /// core's STIL says.
    var installedHvsc: UInt32? {
        hvscInfo?.version.flatMap { UInt32($0) } ?? checkedHvsc
    }

    /// A newer release than the installed one is on the mirror.
    var hvscUpdateAvailable: Bool {
        guard hasCollection, let latestHvsc, let installedHvsc else { return false }
        return latestHvsc > installedHvsc
    }

    /// The curated playlists: the copy inside the app fills an empty cache
    /// (so a fresh install has them, offline too), then they're brought up
    /// to date from Resonance's repository, as Phosphor does at launch. The
    /// Home's metadata, which lists them, is re-read either way: offline,
    /// the seeded ones still show.
    func syncPublishedPlaylists() async {
        let bundled = Bundle.main.url(forResource: "playlists", withExtension: nil)?.path
        _ = try? await core.syncPublishedPlaylists(bundled: bundled)
        hvscInfoRevision = nil
        await loadHvscInfo()
    }

    /// The HVSC Home's metadata: the collection's own DOCUMENTS, parsed by
    /// the core (which caches by tree revision), plus Phosphor's published
    /// playlists. One walk of the tree per revision.
    func loadHvscInfo() async {
        let revision = hvscTreeRevision
        guard hvscInfoRevision != revision else { return }
        hvscInfoRevision = revision
        hvscInfo = await core.hvscInfo()
    }

    /// Play one of Phosphor's published playlists as a temporary queue
    /// from the first tune.
    func playPublishedPlaylist(_ playlist: HvscPlaylist) {
        let tunes = publishedPlaylistTunes(playlist)
        guard let first = tunes.first else { return }
        playQueue(tunes, startAt: first, from: .curated(playlist))
    }

    /// The files of one of Phosphor's published playlists (its entries are
    /// HVSC-relative paths), in its order; those missing from the
    /// collection are left out.
    func publishedPlaylistTunes(_ playlist: HvscPlaylist) -> [URL] {
        guard let root = hvscRoot else { return [] }
        let directory = AppPaths.supportDirectory.appending(path: "published_playlists")
        let content = (try? String(contentsOf: directory.appending(path: playlist.file), encoding: .utf8)) ?? ""
        return content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { URL(filePath: root).appending(path: $0.trimmingCharacters(in: .alphanumerics.inverted)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Start from the Iced Phosphor app's settings.
    func importPhosphorSettings() {
        let shared = sharedDefaults()
        engine = shared.engine
        volume = Double(shared.volume)
        options = shared.options
    }

    /// Phosphor's settings, its favourites and play history added to
    /// Resonance's, and its HVSC collection while Resonance has none. What
    /// it did, in a sentence.
    func importFromPhosphor() async -> String {
        importPhosphorSettings()
        var collection = false
        if !hasCollection, let root = phosphorHvscRoot(), Self.holdsCollection(root) {
            hvscRoot = root
            collection = true
        }
        return Self.describe(await core.importFromPhosphor(), collection: collection)
    }

    nonisolated static func describe(_ imported: PhosphorImport, collection: Bool = false) -> String {
        func count(_ n: UInt32, _ one: String, _ many: String) -> String? {
            n == 0 ? nil : "\(n.formatted()) \(n == 1 ? one : many)"
        }
        let added = [
            count(imported.favorites, "favourite", "favourites"),
            count(imported.recentlyPlayed, "recently played tune", "recently played tunes"),
            count(imported.heard, "heard tune", "heard tunes"),
        ].compactMap(\.self)
        let summary = added.isEmpty
            ? "Settings imported. No new favourites or history."
            : "Settings imported. Added \(added.formatted(.list(type: .and)))."
        return collection ? summary + " Using Phosphor's HVSC collection." : summary
    }

    /// Save the playlist and stop the engine (app termination). Once.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        stopPolling()
        core.shutdown()
    }

    // MARK: Reset

    /// The collection in use is the one Download put in Resonance's own
    /// folder, so Settings can offer to remove it.
    var collectionIsDownloadedHere: Bool {
        _ = hvscTreeRevision
        guard let root = hvscRoot, root == downloadHvscRoot else { return false }
        return FileManager.default.fileExists(atPath: root)
    }

    /// Move the collection Download put in Resonance's folder to the Trash,
    /// stopping a download into it first.
    func trashDownloadedCollection(
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) async throws {
        guard let root = hvscRoot, root == downloadHvscRoot else { return }
        await stopDownload()
        try trash(URL(filePath: root))
        core.reloadHvsc()
        hvscInfo = nil
    }

    /// Start over: stop everything, move Resonance's folder (favourites,
    /// history, playlists, fingerprints, its HVSC) to the Trash and forget
    /// its settings. The app should restart right after. Phosphor's folder
    /// isn't touched.
    func resetEverything(
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) async throws {
        await stopDownload()
        // Saves the playlist one last time, so nothing writes into the
        // folder once it's gone.
        shutdown()
        if FileManager.default.fileExists(atPath: AppPaths.supportDirectory.path) {
            try trash(AppPaths.supportDirectory)
        }
        // Only the app's own settings; never a test's suite's host.
        if defaults == .standard, let id = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: id)
        }
    }

    /// Cancel a running download and wait (up to 10 s) until it has
    /// stopped writing.
    private func stopDownload() async {
        guard core.hvscSyncStatus()?.running == true else { return }
        core.cancelHvscSync()
        for _ in 0..<200 where core.hvscSyncStatus()?.running == true {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: Derived

    var isPlaying: Bool { state == .playing }

    var currentRow: TrackRow? {
        currentIndex.flatMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    /// 0...1, or nil when the length is unknown.
    var progress: Double? {
        guard let duration, duration > 0 else { return nil }
        return min(elapsed / duration, 1)
    }

    var hasSubtunes: Bool { (nowPlaying?.songs ?? 0) > 1 }
}

/// Where Resonance keeps its own files — separate from the Iced app's
/// `~/Library/Application Support/phosphor`, which only Import from
/// Phosphor reads. The engine's own files (favourites, play history, the
/// search index) go next to the session playlist; see
/// `core/src/config.rs`.
nonisolated enum AppPaths {
    static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Resonance", directoryHint: .isDirectory)
    }

    static var sessionPlaylist: URL {
        supportDirectory.appending(path: "session.m3u")
    }

    static var fingerprintDatabase: URL {
        supportDirectory.appending(path: "fingerprints.sqlite")
    }

    /// The HVSC folder until another is chosen, where Download puts it.
    static var hvscDirectory: URL {
        supportDirectory.appending(path: "HVSC", directoryHint: .isDirectory)
    }

    /// Phosphor's own folder: its config, play history, Songlengths and
    /// (by default) HVSC.
    static var phosphorDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "phosphor", directoryHint: .isDirectory)
    }
}

extension PhosphorCore.HvscSyncStatus {
    /// The progress bar's fill: files while the archive extracts, bytes
    /// while it streams; nil before either phase reports a total (a
    /// spinner).
    var fraction: Double? {
        if filesTotal > 0 { return Double(filesDone) / Double(filesTotal) }
        if bytesTotal > 0 { return Double(bytesDone) / Double(bytesTotal) }
        return nil
    }
}

/// A tune in a temporary list, as Up Next names it.
nonisolated struct QueuedTune: Equatable, Sendable, Identifiable {
    let path: String
    let title: String
    let author: String

    var id: String { path }

    init(path: String, title: String, author: String) {
        self.path = path
        self.title = title
        self.author = author
    }

    /// Named by its file: "Last_Ninja_2.sid" is "Last Ninja 2".
    init(_ url: URL) {
        self.init(path: url.path,
                  title: url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " "),
                  author: "")
    }
}

// MARK: Sharing

extension PlayerStore {
    /// The link to share for the tune at `path` (`subtune` nil: its start
    /// song), or nil when sharing is off or HVSC doesn't list the tune.
    func prepareShare(path: String, subtune: Int? = nil) async -> PreparedShare? {
        guard let base = SharedTuneLink.shareBase,
              let tune = await core.shareableTune(path: path)
        else { return nil }
        let item = await core.tunesFromFiles(paths: [path]).first
        // The start song needs no `s`: links stay shorter.
        let start = item.map { Int($0.startSong) }
        let link = SharedTuneLink(key: tune.md5, subtune: subtune == start ? nil : subtune, hvsc: installedHvsc.map(Int.init))
        let title = item?.title ?? URL(filePath: path).deletingPathExtension().lastPathComponent
        return PreparedShare(url: link.webURL(base: base), title: title, author: item?.author ?? "")
    }

    /// Open a shared link: the main window shows what it found. False when
    /// the URL isn't a tune link.
    @discardableResult
    func openShared(_ url: URL) -> Bool {
        guard let link = SharedTuneLink(url: url) else { return false }
        sharedTune = link
        return true
    }

    /// Where the shared tune is in this collection, and what to offer.
    func resolve(_ link: SharedTuneLink) async -> (SharedTuneOutcome, SharedTuneMatch) {
        let match = await core.findSharedTune(md5: link.key, hvscPath: link.hvscPath)
        let outcome = SharedTuneOutcome.decide(
            match: match,
            hasCollection: hasCollection,
            senderHvsc: link.hvsc,
            latestHvsc: latestHvsc.map(Int.init)
        )
        return (outcome, match)
    }

    /// Play a shared tune on its own, at the subtune the link names.
    func playShared(path: String, subtune: Int?) {
        let url = URL(filePath: path)
        playQueue([url], startAt: url, from: .shared)
        guard let subtune else { return }
        // The subtune applies to the loaded tune: wait for it to load.
        Task {
            for _ in 0..<100 {
                if nowPlaying?.path == path {
                    if Int(nowPlaying?.currentSong ?? 0) != subtune {
                        setSubtune(subtune)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
