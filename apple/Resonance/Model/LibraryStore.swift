import Foundation
import Observation
import PhosphorCore

/// The HVSC collection as the sidebar browses it.
///
/// Author and tune lists are cached per folder for the current HVSC root
/// (and dropped when it changes); search results belong to the view that
/// asked. All loading is `async` on the Rust side, so nothing here blocks.
@Observable
final class LibraryStore {
    /// Authors (or sections) per category; absent until loaded.
    private(set) var authors: [HvscCategory: [HvscAuthorItem]] = [:]
    /// Tunes per author folder path; absent until loaded.
    private(set) var tunes: [String: [LibraryRow]] = [:]
    private(set) var errors: [HvscCategory: String] = [:]
    /// An author the browser should show (the inspector's author link). The
    /// window switches to Musicians and the browser selects the author,
    /// then hands the tune on to `revealedTune`.
    var reveal: LibraryReveal?
    /// A tune to select once a list shows it; the tune table clears it.
    var revealedTune: String?
    /// How often Surprise Me was started; the toolbar's dice wiggles on each.
    private(set) var surprises = 0

    let player: PlayerStore
    @ObservationIgnored private var cachedRoot: String?
    /// MUSICIANS folders by the words of their name, for matching a SID
    /// header's author ("Rob Hubbard") to a folder ("Hubbard_Rob").
    @ObservationIgnored private var composersByWords: [Set<String>: HvscAuthorItem] = [:]

    init(player: PlayerStore) {
        self.player = player
        cachedRoot = player.hvscRoot
    }

    private var core: any PlayerCoreProtocol { player.core }

    var hasRoot: Bool { player.hvscRoot != nil }

    // MARK: Loading

    func loadAuthors(_ category: HvscCategory) async {
        dropCachesIfRootChanged()
        guard authors[category] == nil else { return }
        do {
            let list = try await core.hvscAuthors(category: category)
            dropCachesIfRootChanged()
            if category == .musicians {
                composersByWords = Dictionary(
                    list.map { (Self.words($0.name), $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
            authors[category] = list
            errors[category] = nil
        } catch {
            errors[category] = Self.message(for: error)
        }
    }

    func loadTunes(authorPath: String) async {
        dropCachesIfRootChanged()
        guard tunes[authorPath] == nil else { return }
        do {
            let list = try await core.hvscTunes(authorPath: authorPath)
            dropCachesIfRootChanged()
            tunes[authorPath] = list.map(LibraryRow.init)
        } catch {
            tunes[authorPath] = []
        }
    }

    /// Fuzzy search; `nil` scope searches all of HVSC. Throws on failure or
    /// cancellation.
    func search(_ query: String, scope: HvscCategory?) async throws -> HvscSearchResult {
        try await core.hvscSearch(query: query, scope: scope)
    }

    private func dropCachesIfRootChanged() {
        guard player.hvscRoot != cachedRoot else { return }
        cachedRoot = player.hvscRoot
        authors = [:]
        tunes = [:]
        errors = [:]
        composersByWords = [:]
    }

    // MARK: Actions

    /// Play `rows` as a temporary list from `start` (else the first). The
    /// playlist is left alone: playing from the library never adds to it.
    func play(_ rows: [LibraryRow], startAt start: LibraryRow? = nil) {
        guard let first = rows.first else { return }
        player.playQueue(rows.map(\.url), startAt: (start ?? first).url)
    }

    func addToPlaylist(_ rows: [LibraryRow]) {
        player.add(rows.map(\.url))
    }

    /// Add a whole author folder (or section) to the playlist.
    func addAll(authorPath: String) {
        player.add([URL(filePath: authorPath)])
    }

    /// Random tunes from all of HVSC until something else plays: Next picks
    /// another, Previous goes back (the core runs it).
    func surpriseMe() async {
        surprises += 1
        await core.surpriseMe()
    }

    /// Where the inspector's author link goes: `track`'s composer folder in
    /// MUSICIANS. Nil when there isn't one, or MUSICIANS isn't loaded yet.
    ///
    /// A tune filed under its composer names the folder in its path. GAMES
    /// and DEMOS file tunes by title, so for those the header's author has
    /// to match a folder's name. When nothing matches there's no link: the
    /// search index (upstream's) has no author field to fall back on.
    func revealAuthor(of track: TrackDetails) -> LibraryReveal? {
        guard let root = player.hvscRoot, let composers = authors[.musicians] else { return nil }
        let rootParts = URL(filePath: root).standardizedFileURL.pathComponents
        let parts = URL(filePath: track.path).standardizedFileURL.pathComponents
        // MUSICIANS/<letter>/<composer>/<tune>
        if parts.starts(with: rootParts) {
            let inside = Array(parts.dropFirst(rootParts.count))
            if inside.count >= 4, inside[0] == "MUSICIANS",
               let composer = composers.first(where: { $0.name == inside[2] }) {
                return LibraryReveal(authorPath: composer.path, tunePath: track.path)
            }
        }
        for name in Self.names(in: track.author) {
            if let composer = composersByWords[Self.words(name)] {
                return LibraryReveal(authorPath: composer.path, tunePath: track.path)
            }
        }
        return nil
    }

    /// The names a SID header's author field may hold, most specific
    /// first: "Thomas E. Petersen (Laxity)" → the name, then the handle;
    /// "Jeroen Tel & Charles Deenen" → both, then each.
    nonisolated static func names(in author: String) -> [String] {
        var handles: [String] = []
        var base = ""
        var depth = 0
        var handle = ""
        for character in author {
            switch character {
            case "(":
                depth += 1
            case ")" where depth > 0:
                depth -= 1
                if depth == 0 {
                    handles.append(handle)
                    handle = ""
                }
            default:
                if depth > 0 { handle.append(character) } else { base.append(character) }
            }
        }
        let parts = base
            .replacing(" and ", with: "&")
            .split(whereSeparator: { "&,/".contains($0) })
            .map(String.init)
        var seen = Set<Set<String>>()
        return ([base] + parts + handles)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { name in
                let key = words(name)
                return !key.isEmpty && seen.insert(key).inserted
            }
    }

    /// Lowercased words without accents: "Hubbard_Rob" and "Rob Hubbard"
    /// both give {"hubbard", "rob"}.
    nonisolated static func words(_ name: String) -> Set<String> {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return Set(folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    static func message(for error: Error) -> String {
        switch error {
        case HvscError.NoRoot: "Choose your HVSC folder in Settings."
        case HvscError.NotFound(let message), HvscError.Io(let message): message
        default: error.localizedDescription
        }
    }
}

/// A composer the browser should show, from the inspector's author link.
nonisolated struct LibraryReveal: Equatable, Sendable {
    let id = UUID()
    /// The composer's MUSICIANS folder.
    let authorPath: String
    /// Selected if it's in that folder (a GAMES or DEMOS tune isn't).
    let tunePath: String
}

/// A tune in the library lists, with the sort keys `Table` needs.
nonisolated struct LibraryRow: Identifiable, Hashable, Sendable {
    let item: HvscTuneItem

    var id: String { item.path }
    var url: URL { URL(filePath: item.path) }

    var title: String { item.title }
    var author: String { item.author }
    var released: String { item.released }
    var songs: Int { Int(item.songs) }
    /// Unknown lengths sort last.
    var length: Int { item.durationSecs.map(Int.init) ?? .max }
    var stilSort: Int { item.hasStil ? 0 : 1 }

    var lengthText: String {
        item.durationSecs.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) } ?? "—"
    }
}
