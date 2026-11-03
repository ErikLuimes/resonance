import Foundation
import Observation
import PhosphorCore
import STILKit

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
    /// What STIL says per tune or author folder path, ready to show; nil
    /// when it says nothing, absent until loaded.
    private(set) var stil: [String: STILEntry?] = [:]
    /// Tunes whose header credits a name, per name; absent until loaded.
    private(set) var credited: [String: [LibraryRow]] = [:]
    /// Tunes STIL links to, by HVSC path, nil when the file can't be read;
    /// absent until loaded.
    private(set) var linkedTunes: [String: LinkedTune?] = [:]
    private(set) var errors: [HvscCategory: String] = [:]
    /// An author the browser should show (the composer card's link, or a
    /// tune STIL links to). The window switches to its category and the
    /// browser selects the author, then hands the tune on to
    /// `revealedTune`.
    var reveal: LibraryReveal?
    /// A composer without a MUSICIANS folder the browser should show the
    /// tunes of (the composer card's link). The window switches to
    /// `category`, and the browser lists the tunes credited to them.
    var credits: LibraryCredits?
    /// A tune to select once a list shows it; the tune table clears it.
    var revealedTune: String?
    /// What HVSC's bugged-tunes list says about tunes, by path; absent
    /// until loaded, empty for most.
    private(set) var bugs: [String: [TuneBug]] = [:]
    /// The rows of Phosphor's published playlists, by playlist file;
    /// absent until loaded, nil when the lookup failed.
    private(set) var playlistTunes: [String: [LibraryRow]?] = [:]
    /// The play history shared with Phosphor, newest first; nil until
    /// loaded. Reloaded on every track change (the core records the play
    /// before it reports the new track).
    private(set) var recent: [RecentPlay]?
    /// How many different tunes have ever been played, in either app.
    private(set) var heardCount: Int?
    /// A sidebar section the window should show (the inspector's link to
    /// the playlist that's playing, a Home playlist card); the window
    /// clears it.
    var shownSection: SidebarItem?
    /// How often Surprise Me was started; the toolbar's dice wiggles on each.
    private(set) var surprises = 0

    let player: PlayerStore
    @ObservationIgnored private var cachedRoot: String?
    @ObservationIgnored private var cachedTreeRevision: UInt64 = 0
    /// MUSICIANS folders by the words of their name in each of its
    /// `spellings`, for matching a SID header's author ("Rob Hubbard") to a
    /// folder ("Hubbard_Rob").
    @ObservationIgnored private var composersByWords: [Set<String>: HvscAuthorItem] = [:]

    init(player: PlayerStore) {
        self.player = player
        cachedRoot = player.hvscRoot
        cachedTreeRevision = player.hvscTreeRevision
    }

    private var core: any PlayerCoreProtocol { player.core }

    var hasRoot: Bool { player.hvscRoot != nil }

    // MARK: Loading

    func loadAuthors(_ category: HvscCategory) async {
        dropCachesIfStale()
        guard authors[category] == nil else { return }
        do {
            let list = try await core.hvscAuthors(category: category)
            dropCachesIfStale()
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
        dropCachesIfStale()
        guard tunes[authorPath] == nil else { return }
        do {
            let list = try await core.hvscTunes(authorPath: authorPath)
            dropCachesIfStale()
            tunes[authorPath] = list.map(LibraryRow.init)
        } catch {
            tunes[authorPath] = []
        }
    }

    /// STIL's entry on a tune or author folder, which the core hands over
    /// as STIL.txt has it; parsed here. `sidAuthor` is a tune header's
    /// author, which tells whose voice a quote is in.
    func loadStil(path: String, sidAuthor: String? = nil) async {
        dropCachesIfStale()
        guard stil[path] == nil else { return }
        let excerpt = await core.hvscStil(path: path)
        dropCachesIfStale()
        stil[path] = excerpt.flatMap { STILEntry.parsing($0, sidAuthor: sidAuthor) }
    }

    /// The bugs HVSC's bugged-tunes list reports on the tune at `path`.
    func loadBugs(path: String) async {
        dropCachesIfStale()
        guard bugs[path] == nil else { return }
        let found = await core.hvscBugs(path: path)
        dropCachesIfStale()
        bugs[path] = found
    }

    /// The title and author of a tune STIL links to (an HVSC path).
    func loadLinkedTune(_ hvscPath: String) async {
        dropCachesIfStale()
        guard linkedTunes[hvscPath] == nil, let file = file(atHvscPath: hvscPath) else { return }
        let tune = await LinkedTune.read(file)
        dropCachesIfStale()
        linkedTunes[hvscPath] = tune
    }

    /// Every tune in HVSC whose header credits `name`: "Exos" or "EXOS &
    /// Jeff", not "Exoskeleton". The core finds the headers that mention
    /// the name; this keeps those that name the same person. Empty when the
    /// lookup fails.
    func loadCredited(name: String) async {
        dropCachesIfStale()
        guard credited[name] == nil else { return }
        let found = (try? await core.hvscTunesCrediting(names: Array(Set([name, Self.spelledOut(name)])))) ?? []
        dropCachesIfStale()
        credited[name] = found
            .filter { item in Self.names(in: item.author).contains { Self.sameName($0, name) } }
            .map(LibraryRow.init)
    }

    /// The tunes of one of Phosphor's published playlists, in its order.
    /// The first load in a category waits for its search index.
    func loadPlaylist(_ playlist: HvscPlaylist) async {
        dropCachesIfStale()
        guard playlistTunes[playlist.file] == nil else { return }
        let paths = player.publishedPlaylistTunes(playlist).map(\.path)
        let found = try? await core.hvscTunesAt(paths: paths)
        dropCachesIfStale()
        playlistTunes[playlist.file] = found.map { $0.map(LibraryRow.init) }
    }

    /// Re-read the play history and the heard count.
    func loadRecent() async {
        let tunes = (try? await core.recentlyPlayed()) ?? []
        let heard = await core.heardCount()
        let plays = tunes.map(RecentPlay.init)
        if plays != recent { recent = plays }
        if Int(heard) != heardCount { heardCount = Int(heard) }
    }

    /// Empty the play history (Phosphor's too: the apps share it).
    func clearRecent() async {
        await core.clearRecentlyPlayed()
        await loadRecent()
    }

    /// Forget every tune ever heard, in both apps.
    func resetHeard() async {
        await core.resetHeard()
        await loadRecent()
    }

    /// Fuzzy search; `nil` scope searches all of HVSC. Throws on failure or
    /// cancellation.
    func search(_ query: String, scope: HvscCategory?) async throws -> HvscSearchResult {
        try await core.hvscSearch(query: query, scope: scope)
    }

    /// Drop every list and cache if the root changed, or the same root's
    /// tree did (the first sync filling the folder; the core bumps its
    /// revision in both cases).
    private func dropCachesIfStale() {
        guard player.hvscRoot != cachedRoot || player.hvscTreeRevision != cachedTreeRevision else { return }
        cachedRoot = player.hvscRoot
        cachedTreeRevision = player.hvscTreeRevision
        authors = [:]
        tunes = [:]
        stil = [:]
        credited = [:]
        errors = [:]
        composersByWords = [:]
        linkedTunes = [:]
        playlistTunes = [:]
        bugs = [:]
    }

    // MARK: Actions

    /// Play `rows` as a temporary list from `start` (else the first). The
    /// playlist is left alone: playing from the library never adds to it.
    /// `source` is where the rows come from, which "Playing from" names.
    func play(_ rows: [LibraryRow], startAt start: LibraryRow? = nil, from source: PlaybackSource) {
        guard let first = rows.first else { return }
        player.playQueue(rows.map(\.url), startAt: (start ?? first).url, from: source)
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

    /// Every tune in HVSC in a new random order, one after another; Next
    /// and Previous walk it (the core runs it). Starts once the search
    /// indexes are loaded.
    func shuffleCollection() async {
        await core.shuffleCollection()
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

    /// The file at an HVSC path in the HVSC folder.
    func file(atHvscPath hvscPath: String) -> URL? {
        player.hvscRoot.map { URL(filePath: $0).appending(path: hvscPath.trimmingPrefix("/")) }
    }

    /// Show a tune STIL links to (an HVSC path) in the library, in its
    /// author's folder or its section.
    func reveal(hvscPath: String) {
        guard let tune = file(atHvscPath: hvscPath), let category = category(of: tune.path) else { return }
        reveal = LibraryReveal(
            authorPath: tune.deletingLastPathComponent().path,
            tunePath: tune.path,
            category: category
        )
    }

    /// Show a tune (a file in the collection) in the library, in its
    /// author's folder or its section.
    func reveal(tunePath: String) {
        guard let category = category(of: tunePath) else { return }
        reveal = LibraryReveal(
            authorPath: URL(filePath: tunePath).deletingLastPathComponent().path,
            tunePath: tunePath,
            category: category
        )
    }

    /// Show where the playing tune comes from: `source`'s sidebar section,
    /// or (a composer, a search, Surprise Me) the tune at `path` in the
    /// library.
    func open(_ source: PlaybackSource, playing path: String?) {
        if let section = source.section {
            shownSection = section
        } else if let path {
            reveal(tunePath: path)
        }
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

/// An author (or section) the browser should show, from the composer
/// card's link or a tune STIL links to.
nonisolated struct LibraryReveal: Equatable, Sendable {
    let id = UUID()
    /// The composer's MUSICIANS folder, or a GAMES or DEMOS section.
    let authorPath: String
    /// Selected if it's in that folder (a GAMES or DEMOS tune isn't in a
    /// composer's).
    let tunePath: String
    var category: HvscCategory = .musicians
}

/// A tune from the play history and when it last started.
nonisolated struct RecentPlay: Equatable, Sendable {
    let row: LibraryRow
    let playedAt: Date

    init(_ tune: RecentTune) {
        row = LibraryRow(item: tune.item)
        playedAt = Date(timeIntervalSince1970: TimeInterval(tune.playedAt))
    }

    /// "5 minutes ago", "yesterday".
    var playedText: String {
        playedAt.formatted(.relative(presentation: .named))
    }
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
