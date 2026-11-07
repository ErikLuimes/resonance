import CoreSpotlight
import Foundation
import PhosphorCore
import UniformTypeIdentifiers

/// Puts the collection's tunes in Spotlight, so typing a tune's or composer's
/// name there finds them; clicking one comes back through AppDelegate.
///
/// At low priority, and only when the collection has changed: which folder it
/// is and how many tunes it has, which a new HVSC release always changes.
/// Stopping halfway leaves no mark, so the next launch starts over.
final class SpotlightIndex {
    /// Spotlight's side of it, so tests can stand in for it.
    struct Backend {
        var deleteAll: @Sendable () async throws -> Void
        var add: @Sendable ([CSSearchableItem]) async throws -> Void

        static let live = Backend(
            deleteAll: { try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [SpotlightTunes.domain]) },
            add: { try await CSSearchableIndex.default().indexSearchableItems($0) }
        )
    }

    /// Long enough to stay out of launch's way.
    private static let launchDelay = Duration.seconds(20)

    private let store: PlayerStore
    private let defaults: UserDefaults
    private let backend: Backend
    private var running: Task<Void, Never>?

    init(store: PlayerStore, defaults: UserDefaults = .standard, backend: Backend = .live) {
        self.store = store
        self.defaults = defaults
        self.backend = backend
    }

    func start() {
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = (store.hvscRoot, store.hvscTreeRevision, store.hasCollection, store.hvscSync?.running)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        running?.cancel()
        running = Task(priority: .background) { [weak self] in
            try? await Task.sleep(for: Self.launchDelay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Bring Spotlight up to date with the collection.
    func refresh() async {
        guard store.core.hvscSyncStatus()?.running != true else { return }
        guard store.hasCollection, let root = store.hvscRoot else {
            // Gone: its tunes shouldn't stay findable.
            if defaults.string(forKey: Pref.spotlightIndexed) != nil, (try? await backend.deleteAll()) != nil {
                defaults.removeObject(forKey: Pref.spotlightIndexed)
            }
            return
        }
        let tunes = await store.core.hvscAllTunes()
        guard !tunes.isEmpty, !Task.isCancelled else { return }
        let mark = SpotlightTunes.mark(root: root, tunes: tunes.count)
        guard defaults.string(forKey: Pref.spotlightIndexed) != mark else { return }
        defaults.removeObject(forKey: Pref.spotlightIndexed)
        do {
            try await backend.deleteAll()
            for start in stride(from: 0, to: tunes.count, by: SpotlightTunes.batch) {
                guard !Task.isCancelled else { return }
                let slice = tunes[start..<min(start + SpotlightTunes.batch, tunes.count)]
                try await backend.add(slice.map(SpotlightTunes.item))
            }
            defaults.set(mark, forKey: Pref.spotlightIndexed)
        } catch {
            // Quietly: Spotlight is a nicety, and the next launch tries again.
        }
    }
}

/// How a tune appears in Spotlight.
nonisolated enum SpotlightTunes {
    static let domain = "app.useresonance.resonance.hvsc"
    static let batch = 2000

    static func mark(root: String, tunes: Int) -> String { "\(root)|\(tunes)" }

    static func item(_ tune: HvscTuneItem) -> CSSearchableItem {
        CSSearchableItem(uniqueIdentifier: tune.path, domainIdentifier: domain, attributeSet: attributes(tune))
    }

    static func attributes(_ tune: HvscTuneItem) -> CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .audio)
        attributes.title = tune.title
        let composer = composer(of: tune)
        attributes.artist = composer
        attributes.contentDescription = [composer, tune.released].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        // Filed "Hubbard, Rob": found by "rob hubbard" too.
        attributes.keywords = [composer, "SID", "Commodore 64", "C64"].compactMap { $0 }
        return attributes
    }

    /// "Rob Hubbard". Search's items carry their folder as the author, which
    /// is only a person in MUSICIANS (in GAMES and DEMOS it's "0-9").
    static func composer(of tune: HvscTuneItem) -> String? {
        guard tune.category == .musicians, !tune.author.isEmpty else { return nil }
        let parts = tune.author.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 ? "\(parts[1]) \(parts[0])" : tune.author
    }

    /// The tune a Spotlight click is about.
    static func path(from activity: NSUserActivity) -> String? {
        guard activity.activityType == CSSearchableItemActionType else { return nil }
        return activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
    }
}
