import Foundation
import Observation
import PhosphorCore

/// The tunes' sound fingerprints, from the core's background scan of HVSC.
///
/// The scan starts once there's a collection and runs until every subtune
/// is done; pausing it is remembered across launches. Lists ask for their
/// rows' fingerprints with `load(_:)`; lookups are batched, and tunes the
/// scan hadn't reached yet are asked again as it saves more.
@Observable
final class FingerprintStore {
    /// Fingerprints of start songs, by path; absent until loaded or while
    /// the scan hasn't reached the tune.
    private(set) var fingerprints: [String: TuneFingerprint] = [:]
    /// The scan's progress, updated about once a second.
    private(set) var status: FingerprintScanStatus?
    /// "Sounds like" for a tune's start song, by path; absent until loaded.
    private(set) var similar: [String: [SimilarTune]] = [:]
    /// How common each sound is across the collection, 0–1; empty until asked
    /// for, or while nothing's fingerprinted.
    private(set) var tagShares: [SoundTag: Double] = [:]
    /// Downloading the published fingerprint set: whether it's under way,
    /// how many fingerprints it added, or why it failed.
    private(set) var setDownload = SetDownload.idle

    enum SetDownload: Equatable {
        case idle
        case downloading
        case added(Int)
        case failed(String)
    }

    /// How long the scan should take to finish, from its rate over the
    /// last couple of minutes; nil while paused or before it has a rate.
    private(set) var remaining: Duration?

    /// Pausing holds the scan's place, also across launches.
    var paused: Bool {
        didSet {
            guard paused != oldValue else { return }
            defaults.set(paused, forKey: Pref.fingerprintScanPaused)
            core.setFingerprintScanPaused(paused: paused)
            status = core.fingerprintScanStatus()
        }
    }

    let player: PlayerStore
    @ObservationIgnored private let defaults: UserDefaults
    /// Paths asked for that the scan hasn't reached; asked again as it goes.
    @ObservationIgnored private var missing = Set<String>()
    @ObservationIgnored private var pending = Set<String>()
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var scannedRoot: String?
    @ObservationIgnored private var refetchedRevision: UInt64 = 0
    @ObservationIgnored private var refetchedAt = Date.distantPast
    /// Whether this launch has looked at downloading the published set.
    @ObservationIgnored private var setChecked = false
    /// Whether this launch has looked at downloading the audio embeddings.
    @ObservationIgnored private var embeddingsChecked = false
    /// Recent (time, subtunes done) readings, for `remaining`.
    @ObservationIgnored private var samples: [(at: Date, done: UInt32)] = []

    init(player: PlayerStore, defaults: UserDefaults = .standard) {
        self.player = player
        self.defaults = defaults
        paused = defaults.bool(forKey: Pref.fingerprintScanPaused)
    }

    private var core: any PlayerCoreProtocol { player.core }

    // MARK: Scan

    /// Start the scan when there's a collection (again whenever the folder
    /// changes) and follow its progress.
    func startPolling() {
        guard pollTask == nil else { return }
        core.setFingerprintScanPaused(paused: paused)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func tick() async {
        if player.hvscRoot != scannedRoot, player.hasCollection {
            scannedRoot = player.hvscRoot
            fingerprints = [:]
            similar = [:]
            missing = []
            try? await core.startFingerprintScan()
        }
        let s = core.fingerprintScanStatus()
        if s != status { status = s }
        estimate(s)
        // Once, with a collection that's mostly unscanned: fetch the
        // published set instead of hours of scanning. Quietly: if it can't
        // be had, the scan goes on as before.
        if !setChecked, player.hasCollection, s.total > 0 {
            setChecked = true
            if !defaults.bool(forKey: Pref.fingerprintSetImported), s.done * 2 < s.total {
                Task { await downloadSet(quietly: true) }
            }
        }
        // Once: the audio embeddings that sharpen Sounds Like. Quietly: it
        // goes by the fingerprints alone without them.
        if !embeddingsChecked, player.hasCollection {
            embeddingsChecked = true
            Task {
                guard await !core.hasEmbeddings(),
                      (try? await core.downloadEmbeddings()) != nil else { return }
                similar = [:]
            }
        }
        // New fingerprints: ask again for the tunes lists are waiting on,
        // at most every few seconds.
        if s.revision != refetchedRevision, !missing.isEmpty, Date.now.timeIntervalSince(refetchedAt) > 4 {
            refetchedRevision = s.revision
            refetchedAt = .now
            pending.formUnion(missing)
            await flush()
        }
    }

    /// Update `remaining` from the subtunes done over the last two minutes.
    /// The rate needs half a minute of scanning; pausing starts it over.
    private func estimate(_ s: FingerprintScanStatus) {
        guard s.running, !s.paused, !s.finished else {
            samples = []
            if remaining != nil { remaining = nil }
            return
        }
        let now = Date.now
        samples.append((now, s.done))
        samples.removeAll { now.timeIntervalSince($0.at) > 120 }
        var estimate: Duration?
        if let first = samples.first, now.timeIntervalSince(first.at) >= 30, s.done > first.done {
            let rate = Double(s.done - first.done) / now.timeIntervalSince(first.at)
            let left = Double(max(Int(s.total) - Int(s.done) - Int(s.failed), 0))
            estimate = .seconds((left / rate).rounded())
        }
        if estimate != remaining { remaining = estimate }
    }

    /// Scan the tunes the scan gave up on again.
    func retryFailed() async {
        try? await core.retryFailedFingerprints()
        status = core.fingerprintScanStatus()
    }

    /// Forget every fingerprint and scan the collection from the start.
    func rebuild() async {
        fingerprints = [:]
        similar = [:]
        missing = []
        samples = []
        remaining = nil
        try? await core.rebuildFingerprints()
        status = core.fingerprintScanStatus()
    }

    /// Download the published fingerprint set and merge it in; the scan
    /// fills in what it doesn't have. `quietly` (at launch) leaves no error
    /// behind if it fails.
    func downloadSet(quietly: Bool = false) async {
        guard setDownload != .downloading else { return }
        setDownload = .downloading
        do {
            let added = try await core.downloadFingerprints()
            defaults.set(true, forKey: Pref.fingerprintSetImported)
            fingerprints = [:]
            similar = [:]
            missing = []
            samples = []
            remaining = nil
            status = core.fingerprintScanStatus()
            setDownload = .added(Int(added))
        } catch {
            setDownload = quietly ? .idle : .failed(LibraryStore.message(for: error))
        }
    }

    /// Whether the scan hasn't got everywhere yet.
    var isScanning: Bool {
        guard let status else { return false }
        return status.running && !status.finished
    }

    // MARK: Lookups

    func fingerprint(_ path: String) -> TuneFingerprint? {
        fingerprints[path]
    }

    /// Fetch the fingerprints of the tunes at `paths` (batched with other
    /// requests made at about the same time).
    func load(_ paths: [String]) {
        let new = paths.filter { fingerprints[$0] == nil && !missing.contains($0) }
        guard !new.isEmpty else { return }
        pending.formUnion(new)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            await self?.flush()
            self?.flushTask = nil
        }
    }

    private func flush() async {
        let paths = Array(pending)
        pending = []
        guard !paths.isEmpty else { return }
        let found = await core.fingerprints(paths: paths)
        var added = fingerprints
        for (path, fp) in zip(paths, found) {
            if let fp {
                added[path] = fp
                missing.remove(path)
            } else {
                missing.insert(path)
            }
        }
        if added.count != fingerprints.count { fingerprints = added }
    }

    /// How alike each tune at `paths` sounds to the one at `seed`, 0–1;
    /// absent for tunes not scanned yet.
    func similarity(to seed: String, of paths: [String]) async -> [String: Double] {
        let scores = await core.similarity(seed: seed, paths: paths)
        var out: [String: Double] = [:]
        for (path, score) in zip(paths, scores) {
            if let score { out[path] = Double(max(0, score)) }
        }
        return out
    }

    /// How common each sound is across the collection, as it stands now.
    func loadTagShares() async {
        let found = await core.soundTagShares()
        let shares = Dictionary(found.map { ($0.tag, Double($0.share)) }, uniquingKeysWith: { first, _ in first })
        if shares != tagShares { tagShares = shares }
    }

    /// The tunes in all of HVSC that sound most like the one at `path`.
    func loadSimilar(_ path: String) async {
        guard similar[path]?.isEmpty != false else { return }
        let found = (try? await core.similarTunes(path: path, subtune: nil, limit: 7)) ?? []
        similar[path] = found
    }
}

// MARK: - Describing a sound

nonisolated extension SoundTag {
    static let filters: [SoundTag] = [.arpeggios, .filterSweeps, .noiseDrums, .ringMod, .syncLeads, .digiSamples]
    static let all: [SoundTag] = filters + [.pulseBass, .vibratoLeads]

    var name: String {
        switch self {
        case .arpeggios: "Arpeggios"
        case .filterSweeps: "Filter sweeps"
        case .noiseDrums: "Noise drums"
        case .ringMod: "Ring mod"
        case .syncLeads: "Sync leads"
        case .digiSamples: "Digi samples"
        case .pulseBass: "Pulse bass"
        case .vibratoLeads: "Vibrato leads"
        }
    }
}

nonisolated extension TuneFingerprint {
    /// The waveforms by share, largest first, leaving out the ones that
    /// barely sound.
    var waveforms: [(name: String, share: Double)] {
        [("Triangle", mix.triangle), ("Saw", mix.saw), ("Pulse", mix.pulse), ("Noise", mix.noise)]
            .map { ($0.0, Double($0.1)) }
            .filter { $0.1 >= 0.02 }
            .sorted { $0.1 > $1.1 }
    }

    /// The sound in a sentence: "Mostly pulse, with noise drums and fast
    /// arpeggios."
    var summary: String {
        if silent { return "Silent in the part that was scanned." }
        let waves = waveforms
        var opening: String
        if let first = waves.first, first.share >= 0.6 {
            opening = "Mostly \(first.name.lowercased())"
        } else if waves.count >= 2 {
            opening = "\(waves[0].name) and \(waves[1].name.lowercased())"
        } else {
            opening = waves.first?.name ?? "Quiet"
        }
        var traits: [String] = []
        for tag in tags {
            switch tag {
            case .arpeggios: traits.append(arpeggioRate >= 25 ? "fast arpeggios" : "arpeggios")
            case .filterSweeps: traits.append("filter sweeps")
            case .noiseDrums: traits.append("noise drums")
            case .ringMod: traits.append("ring modulation")
            case .syncLeads: traits.append("sync leads")
            case .digiSamples: traits.append("sampled sounds")
            case .pulseBass: traits.append("pulse bass")
            case .vibratoLeads: traits.append("vibrato")
            }
        }
        if !traits.isEmpty {
            opening += ", with " + traits.formatted(.list(type: .and))
        }
        return opening + "."
    }
}
