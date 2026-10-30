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
    /// STIL commentary for what's playing.
    private(set) var stil: String?

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

    /// Set by menu commands; the main window presents the file importer.
    var isImporting = false

    let core: any PlayerCoreProtocol

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let phosphorHvscRoot: () -> String?
    @ObservationIgnored private var playlistRevision: UInt64?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Reads the saved settings from `defaults` and starts a core configured
    /// with them via `makeCore`. Until an HVSC folder is chosen, Phosphor's
    /// (`phosphorHvscRoot`) is used.
    init(
        defaults: UserDefaults = .standard,
        sessionPath: URL = AppPaths.sessionPlaylist,
        phosphorHvscRoot: @escaping () -> String? = { sharedDefaults().hvscRoot },
        makeCore: (CoreConfig) -> any PlayerCoreProtocol
    ) {
        let engine = Engine(storageValue: defaults.string(forKey: Pref.engine)) ?? .sidLite
        let volume = defaults.object(forKey: Pref.volume) as? Double ?? 0.8
        let shuffle = defaults.bool(forKey: Pref.shuffle)
        let repeatMode = Repeat(storageValue: defaults.string(forKey: Pref.repeatMode)) ?? .off
        let options = PlaybackOptions(from: defaults)
        let hvscRoot = (defaults.object(forKey: Pref.hvscRoot) as? String)
            .map { $0.isEmpty ? nil : $0 } ?? phosphorHvscRoot()
        self.defaults = defaults
        self.phosphorHvscRoot = phosphorHvscRoot
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
        update(\.queueActive, s.queueActive)
        update(\.surpriseActive, s.surpriseActive)
        update(\.nowPlaying, s.track)
        update(\.elapsed, TimeInterval(s.elapsedMs) / 1000)
        update(\.duration, s.durationMs.map { TimeInterval($0) / 1000 })
        update(\.loading, s.loading)
        update(\.error, s.error)
        update(\.trackRevision, s.trackRevision)
        update(\.hvscIndexing, s.hvscIndexing)
        update(\.stil, s.stil)
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
    /// alone; Next and Previous stay inside the list.
    func playQueue(_ urls: [URL], startAt start: URL) {
        guard !urls.isEmpty else { return }
        core.playQueue(paths: urls.map(\.path), start: start.path)
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

    /// Use the HVSC folder Phosphor is configured with.
    func usePhosphorHvscRoot() {
        hvscRoot = phosphorHvscRoot()
    }

    /// Start from the Iced Phosphor app's settings.
    func importPhosphorSettings() {
        let shared = sharedDefaults()
        engine = shared.engine
        volume = Double(shared.volume)
        options = shared.options
    }

    /// Save the playlist and stop the engine (app termination).
    func shutdown() {
        stopPolling()
        core.shutdown()
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
/// `~/Library/Application Support/phosphor`, whose config, Songlengths and
/// HVSC the core only reads.
nonisolated enum AppPaths {
    static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Resonance", directoryHint: .isDirectory)
    }

    static var sessionPlaylist: URL {
        supportDirectory.appending(path: "session.m3u")
    }
}
