import Foundation

/// How to find a list again: what Recently Played needs to put you back in
/// the list a tune played from. The list itself isn't kept, only its key:
/// random and one-off lists (Surprise Me, files, a shared link) have none.
nonisolated struct SourceRecipe: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case myPlaylist, favorites, playlist, curated, folder, search, soundsLike, drift, other
    }

    let kind: Kind
    /// The playlist's id, the curated list's file, the folder's path, the
    /// search's words, or the seed tune's path.
    let key: String?
    /// "Playing from" as it read then: "Sounds like Commando".
    let name: String
}

/// Where each tune in the play history was played from, newest first.
/// The core's own history (`recently_played.json`) stays in Phosphor's
/// format, so this is a file of its own beside it, `play_sources.json`.
@MainActor
final class SourceHistory {
    struct Entry: Codable, Equatable {
        let path: String
        /// Seconds since 1970, as the core's history has it.
        let playedAt: Double
        let source: SourceRecipe
    }

    /// As many as the core's history holds, and room for repeats.
    static let kept = 300

    private let url: URL
    private(set) var entries: [Entry]

    init(url: URL = AppPaths.supportDirectory.appending(path: "play_sources.json")) {
        self.url = url
        entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))) ?? []
    }

    /// `path` started playing from `source`. A tune that starts again
    /// right away (a subtune, a restart) keeps one entry.
    func record(path: String, source: SourceRecipe, at date: Date = .now) {
        let entry = Entry(path: path, playedAt: date.timeIntervalSince1970, source: source)
        if entries.first?.path == path {
            entries[0] = entry
        } else {
            entries.insert(entry, at: 0)
        }
        if entries.count > Self.kept { entries.removeLast(entries.count - Self.kept) }
        save()
    }

    /// Where `path` played from when it played at `playedAt` (the core's
    /// time for it), or most recently without one. The two clocks are
    /// stamped a moment apart, so it's the newest entry no later than a
    /// minute after.
    func source(of path: String, playedAt: Double? = nil) -> SourceRecipe? {
        entries.first { entry in
            guard entry.path == path else { return false }
            guard let playedAt else { return true }
            return entry.playedAt <= playedAt + 60
        }?.source
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}
