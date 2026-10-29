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

    /// The HVSC category on screen, if any; Surprise Me picks from it.
    var activeCategory: HvscCategory?

    let player: PlayerStore
    @ObservationIgnored private var cachedRoot: String?

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
    }

    // MARK: Actions

    func play(_ rows: [LibraryRow]) {
        player.add(rows.map(\.url), playFirst: true)
    }

    func addToPlaylist(_ rows: [LibraryRow]) {
        player.add(rows.map(\.url))
    }

    /// Add a whole author folder (or section) to the playlist.
    func addAll(authorPath: String) {
        player.add([URL(filePath: authorPath)])
    }

    /// Play a random tune from the category on screen, else all of HVSC.
    func surpriseMe() async {
        do {
            if let path = try await core.hvscSurprise(scope: activeCategory) {
                player.add([URL(filePath: path)], playFirst: true)
            }
        } catch {
            if let category = activeCategory {
                errors[category] = Self.message(for: error)
            }
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case HvscError.NoRoot: "Choose your HVSC folder in Settings."
        case HvscError.NotFound(let message), HvscError.Io(let message): message
        default: error.localizedDescription
        }
    }
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
