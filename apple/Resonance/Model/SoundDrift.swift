import Foundation
import PhosphorCore

/// A radio that wanders: each tune sounds like the one before, so it slowly
/// crosses the collection, where Surprise Me jumps at random and Sounds Like
/// stays close to one tune.
///
/// The core can only replace a list, not add to one, so this works out the next
/// stretch early and swaps it in the moment the list's last tune starts, when
/// starting that tune again can't be heard.
final class SoundDrift {
    /// How many tunes each stretch adds: a good half hour of music.
    static let stretch = 10
    /// How far ahead to start on the next stretch.
    static let margin = 3
    /// How many tunes back Previous can go.
    static let kept = 30
    /// The matches each step chooses from.
    static let candidates: UInt32 = 20

    private let player: PlayerStore
    private let library: LibraryStore
    private var title: String
    private var chain: [HvscTuneItem] = []
    private var visited = Set<String>()
    private var next: [HvscTuneItem]?
    private var extending: Task<Void, Never>?
    private var stopped = false
    /// Whether the player has started on it: until then, its source is still
    /// what played before.
    private var underway = false
    private let onEnd: () -> Void

    init(player: PlayerStore, library: LibraryStore, title: String, onEnd: @escaping () -> Void) {
        self.player = player
        self.library = library
        self.title = title
        self.onEnd = onEnd
    }

    /// Set off from `seed`. False when nothing sounds like it: it isn't scanned.
    /// With `playsSeed`, the seed is heard first, else the first step is.
    func start(seed: HvscTuneItem, playsSeed: Bool) async -> Bool {
        visited.insert(seed.path)
        let first = await walk(from: seed, count: Self.stretch)
        guard !first.isEmpty else { return false }
        chain = (playsSeed ? [seed] : []) + first
        library.play(chain.map(LibraryRow.init), startAt: chain.first.map(LibraryRow.init), from: .drift(title: title))
        observe()
        return true
    }

    func stop() {
        stopped = true
        extending?.cancel()
    }

    private func walk(from start: HvscTuneItem, count: Int) async -> [HvscTuneItem] {
        var tunes: [HvscTuneItem] = []
        var current = start
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<count {
            guard !Task.isCancelled,
                  let found = try? await player.core.similarTunes(path: current.path, subtune: nil, limit: Self.candidates) else { break }
            let recent = ([start] + tunes).suffix(Self.recentComposers).map(\.author)
            guard let step = Self.step(from: found.map(\.item), visited: visited, recentComposers: recent, using: &rng) else { break }
            visited.insert(step.path)
            tunes.append(step)
            current = step
        }
        return tunes
    }

    /// Composers to move on from, so a drift doesn't sit in one composer's work,
    /// whose tunes are often each other's closest matches.
    static let recentComposers = 2
    /// How far down the matches a step may go. The closest would walk the same
    /// path every time; further out, a step stops sounding like the last.
    nonisolated static let spread = 5

    /// The next tune: not heard on this drift, by someone else if possible, and
    /// among the closest of those.
    nonisolated static func step(from matches: [HvscTuneItem], visited: Set<String>, recentComposers: [String],
                                 using rng: inout some RandomNumberGenerator) -> HvscTuneItem? {
        let unheard = matches.filter { !visited.contains($0.path) }
        let elsewhere = unheard.filter { !recentComposers.contains($0.author) }
        let choices = elsewhere.isEmpty ? unheard : elsewhere
        return choices.prefix(spread).randomElement(using: &rng)
    }

    private func observe() {
        guard !stopped else { return }
        withObservationTracking {
            _ = (player.nowPlaying?.path, player.queueSource, player.surpriseActive, player.queueActive)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        update()
    }

    private func update() {
        guard case .drift? = player.source else {
            // Something else plays now: this drift is over.
            if underway {
                stop()
                onEnd()
            }
            return
        }
        underway = true
        guard let path = player.nowPlaying?.path, let at = chain.firstIndex(where: { $0.path == path }) else { return }
        let left = chain.count - 1 - at
        if left <= Self.margin, next == nil, extending == nil, let last = chain.last {
            extending = Task { [weak self] in
                guard let self else { return }
                let more = await walk(from: last, count: Self.stretch)
                next = more
                extending = nil
                // The last tune may have started while this worked.
                update()
            }
        }
        if left == 0, let more = next, !more.isEmpty, player.elapsed < 2 {
            next = nil
            chain = Array((chain + more).suffix(Self.kept + more.count))
            player.playQueue(chain.map { URL(filePath: $0.path) }, startAt: URL(filePath: path),
                             from: .drift(title: title), tunes: chain.map { QueuedTune(path: $0.path, title: $0.title, author: $0.author) })
        }
    }
}
