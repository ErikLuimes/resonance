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
    /// STIL's note per author folder path, "" when it has none; absent
    /// until loaded.
    private(set) var authorNotes: [String: String] = [:]
    /// Tunes whose header credits a name, per name; absent until loaded.
    private(set) var credited: [String: [LibraryRow]] = [:]
    private(set) var errors: [HvscCategory: String] = [:]
    /// An author the browser should show (the composer card's link). The
    /// window switches to Musicians and the browser selects the author,
    /// then hands the tune on to `revealedTune`.
    var reveal: LibraryReveal?
    /// A composer without a MUSICIANS folder the browser should show the
    /// tunes of (the composer card's link). The window switches to
    /// `category`, and the browser lists the tunes credited to them.
    var credits: LibraryCredits?
    /// A tune to select once a list shows it; the tune table clears it.
    var revealedTune: String?
    /// How often Surprise Me was started; the toolbar's dice wiggles on each.
    private(set) var surprises = 0

    let player: PlayerStore
    @ObservationIgnored private var cachedRoot: String?
    /// MUSICIANS folders by the words of their name in each of its
    /// `spellings`, for matching a SID header's author ("Rob Hubbard") to a
    /// folder ("Hubbard_Rob").
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
                    list.flatMap { folder in Self.spellings(folder.name).map { ($0, folder) } },
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

    func loadAuthorNote(authorPath: String) async {
        dropCachesIfRootChanged()
        guard authorNotes[authorPath] == nil else { return }
        let note = try? await core.hvscAuthorNote(authorPath: authorPath)
        dropCachesIfRootChanged()
        authorNotes[authorPath] = note ?? ""
    }

    /// Every tune in HVSC whose header credits `name`: "Exos" or "EXOS &
    /// Jeff", not "Exoskeleton". The core finds the headers that mention
    /// the name; this keeps those that name the same person. Empty when the
    /// lookup fails.
    func loadCredited(name: String) async {
        dropCachesIfRootChanged()
        guard credited[name] == nil else { return }
        let found = (try? await core.hvscTunesCrediting(names: Array(Set([name, Self.spelledOut(name)])))) ?? []
        dropCachesIfRootChanged()
        credited[name] = found
            .filter { item in Self.names(in: item.author).contains { Self.sameName($0, name) } }
            .map(LibraryRow.init)
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
        authorNotes = [:]
        credited = [:]
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

    /// Who the inspector's composer card is about: `track`'s composer folder
    /// in MUSICIANS, else just the header's author (see `unfiledComposer`).
    /// Nil when the header names no one.
    func composer(of track: TrackDetails) -> Composer? {
        composerFolder(of: track) ?? Self.unfiledComposer(track.author)
    }

    /// `track`'s composer folder in MUSICIANS. Nil when there isn't one, or
    /// MUSICIANS isn't loaded yet.
    ///
    /// A tune filed under its composer names the folder in its path. GAMES
    /// and DEMOS file tunes by title, so for those the header's author has
    /// to match a folder's name.
    private func composerFolder(of track: TrackDetails) -> Composer? {
        guard let root = player.hvscRoot, let composers = authors[.musicians] else { return nil }
        let names = Self.names(in: track.author)
        let rootParts = URL(filePath: root).standardizedFileURL.pathComponents
        let parts = URL(filePath: track.path).standardizedFileURL.pathComponents
        // MUSICIANS/<letter>/<composer>/<tune>
        if parts.starts(with: rootParts) {
            let inside = Array(parts.dropFirst(rootParts.count))
            if inside.count >= 4, inside[0] == "MUSICIANS",
               let folder = composers.first(where: { $0.name == inside[2] }) {
                // The header's spelling ("Thomas E. Petersen") when it names
                // this folder; the folder's otherwise.
                if let name = names.first(where: { Self.sameName($0, folder.name) }) {
                    let subtitle = Self.subtitle(for: name, in: track.author)
                    return Composer(authorPath: folder.path, name: name, subtitle: subtitle)
                }
                return Composer(authorPath: folder.path, name: Self.spokenName(folder.displayName))
            }
        }
        for name in names {
            if let folder = Self.spellings(name).compactMap({ composersByWords[$0] }).first {
                let subtitle = Self.subtitle(for: name, in: track.author)
                return Composer(authorPath: folder.path, name: name, subtitle: subtitle)
            }
        }
        return nil
    }

    /// A card for an author MUSICIANS has no folder for, like most demo
    /// groups' musicians: the header's first person ("Exos"), with the rest
    /// of the credit as the subtitle. Nil when it names no one ("<?>").
    nonisolated static func unfiledComposer(_ author: String) -> Composer? {
        let credit = Self.credit(in: author)
        let candidates = Self.people(in: credit.base) + credit.handles.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = candidates.first(where: { !words($0).isEmpty }) else { return nil }
        return Composer(authorPath: nil, name: name, subtitle: subtitle(for: name, in: author))
    }

    /// Which part of HVSC `path` is in, if any.
    func category(of path: String) -> HvscCategory? {
        guard let root = player.hvscRoot else { return nil }
        let rootParts = URL(filePath: root).standardizedFileURL.pathComponents
        let parts = URL(filePath: path).standardizedFileURL.pathComponents
        guard parts.starts(with: rootParts), parts.count > rootParts.count else { return nil }
        switch parts[rootParts.count] {
        case "MUSICIANS": return .musicians
        case "GAMES": return .games
        case "DEMOS": return .demos
        default: return nil
        }
    }

    /// The card's line under `name`, one of the names in a header's
    /// `author`: the real name behind a handle ("Alexander Rotzsch (Fanta)"
    /// → "Alexander Rotzsch"), the handle behind a name, or who else is
    /// credited ("with Charles Deenen"). Nil when there's nothing more.
    nonisolated static func subtitle(for name: String, in author: String) -> String? {
        let key = words(name)
        let credit = Self.credit(in: author)
        let people = Self.people(in: credit.base)
        if credit.handles.contains(where: { words($0) == key }) {
            return people.count == 1 ? people[0] : nil
        }
        guard let index = people.firstIndex(where: { words($0) == key }) else { return nil }
        if people.count > 1 {
            var others = people
            others.remove(at: index)
            return "with \(others.formatted(.list(type: .and)))"
        }
        return credit.handles.count == 1 ? credit.handles[0] : nil
    }

    /// A folder's display name as you'd say it: "Hubbard, Rob" → "Rob
    /// Hubbard". Handles and other names stay as they are.
    nonisolated static func spokenName(_ displayName: String) -> String {
        let parts = displayName.split(separator: ", ", maxSplits: 1)
        return parts.count == 2 ? "\(parts[1]) \(parts[0])" : displayName
    }

    /// The names a SID header's author field may hold, most specific
    /// first: "Thomas E. Petersen (Laxity)" → the name, then the handle;
    /// "Jeroen Tel & Charles Deenen" → both, then each.
    nonisolated static func names(in author: String) -> [String] {
        let credit = Self.credit(in: author)
        var seen = Set<Set<String>>()
        return ([credit.base] + Self.people(in: credit.base) + credit.handles)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { name in
                let key = words(name)
                return !key.isEmpty && seen.insert(key).inserted
            }
    }

    /// A header's author split into the text outside parentheses and the
    /// handles inside them: "Thomas E. Petersen (Laxity)" → ("Thomas E.
    /// Petersen ", ["Laxity"]).
    private nonisolated static func credit(in author: String) -> (base: String, handles: [String]) {
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
        return (base, handles)
    }

    /// The people in an author field: "Jeroen Tel & Charles Deenen" → both.
    private nonisolated static func people(in base: String) -> [String] {
        base.replacing(" and ", with: "&")
            .split(whereSeparator: { "&,/".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Lowercased words without accents: "Hubbard_Rob" and "Rob Hubbard"
    /// both give {"hubbard", "rob"}.
    nonisolated static func words(_ name: String) -> Set<String> {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return Set(folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// Whether two names are one: "Chris Hülsbeck" is "Huelsbeck_Chris".
    nonisolated static func sameName(_ a: String, _ b: String) -> Bool {
        let other = spellings(b)
        return spellings(a).contains(where: other.contains)
    }

    /// The `words` of `name` with accents dropped ("hulsbeck"), then with
    /// German umlauts and ß spelled out as HVSC's folder names do
    /// ("huelsbeck").
    private nonisolated static func spellings(_ name: String) -> [Set<String>] {
        [words(name), words(spelledOut(name))]
    }

    /// `name` lowercased, with German umlauts and ß spelled out: "jörg
    /// strauss".
    private nonisolated static func spelledOut(_ name: String) -> String {
        name.lowercased()
            .replacing("ä", with: "ae")
            .replacing("ö", with: "oe")
            .replacing("ü", with: "ue")
            .replacing("ß", with: "ss")
    }

    static func message(for error: Error) -> String {
        switch error {
        case HvscError.NoRoot: "Choose your HVSC folder in Settings."
        case HvscError.NotFound(let message), HvscError.Io(let message): message
        default: error.localizedDescription
        }
    }
}

/// A tune's composer, as the inspector's composer card shows them.
nonisolated struct Composer: Equatable, Sendable {
    /// Their MUSICIANS folder; nil when they have none, and the card's link
    /// lists the tunes credited to them instead.
    let authorPath: String?
    /// "Rob Hubbard".
    let name: String
    /// A real name, handle or co-authors; see `LibraryStore.subtitle`.
    var subtitle: String? = nil

    /// "RH": the first letters of the first and last word of the name.
    var initials: String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let picked = words.count > 1 ? [words[0], words[words.count - 1]] : words
        return String(picked.compactMap(\.first)).uppercased()
    }
}

/// A composer the browser should show, from the composer card's link.
nonisolated struct LibraryReveal: Equatable, Sendable {
    let id = UUID()
    /// The composer's MUSICIANS folder.
    let authorPath: String
    /// Selected if it's in that folder (a GAMES or DEMOS tune isn't).
    let tunePath: String
}

/// A composer without a MUSICIANS folder whose tunes the browser should
/// list, from the composer card's link.
nonisolated struct LibraryCredits: Equatable, Sendable {
    let id = UUID()
    /// As the card names them: "Exos".
    let name: String
    /// The sidebar section to show them in: where the playing tune is.
    let category: HvscCategory
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
