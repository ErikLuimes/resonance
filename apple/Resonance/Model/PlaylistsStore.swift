import AppKit
import Foundation
import Observation
import PhosphorCore

/// One of your playlists: an M3U file in Resonance's Playlists folder,
/// named after it.
nonisolated struct UserPlaylist: Identifiable, Hashable, Sendable {
    let url: URL
    /// The file name, "Late night chill.m3u".
    var id: String { url.lastPathComponent }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Where a tune can be added: the Add to menu's entries.
nonisolated enum AddTarget: Hashable, Sendable {
    case myPlaylist
    case favourites
    case playlist(String)
}

/// Your playlists, the favourites Resonance shares with Phosphor, and
/// adding tunes to either.
///
/// Playlists are plain M3U files (one absolute path per line), so other
/// players open them too. Favourites are Phosphor's favorites.json, read
/// and written through the core.
@Observable
final class PlaylistsStore {
    /// Sorted by name.
    private(set) var playlists: [UserPlaylist] = []
    /// The favourites' files, newest first; nil until loaded.
    private(set) var favourites: [String]?
    /// Each playlist's files, by id; absent until read.
    private(set) var paths: [String: [String]] = [:]
    /// Rows for the lists shown, by id ("" for Favourites); absent until
    /// read from the files.
    private(set) var rows: [String: [LibraryRow]] = [:]
    /// A playlist whose name the sidebar should edit (one just made).
    var renaming: String?
    /// The last message about something that went wrong.
    private(set) var error: String?

    let player: PlayerStore
    /// Where the M3U files are.
    let folder: URL
    @ObservationIgnored private let defaults: UserDefaults
    /// Observed: the hearts read it, and must fill the moment it changes.
    private var favouriteSet = Set<String>()

    static let favouritesID = ""

    init(
        player: PlayerStore,
        folder: URL = AppPaths.supportDirectory.appending(path: "Playlists", directoryHint: .isDirectory),
        defaults: UserDefaults = .standard
    ) {
        self.player = player
        self.folder = folder
        self.defaults = defaults
        reload()
    }

    private var core: any PlayerCoreProtocol { player.core }

    // MARK: Playlists

    /// Re-read the folder.
    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        playlists = files
            .filter { $0.pathExtension.lowercased() == "m3u" }
            .map { UserPlaylist(url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func playlist(_ id: String) -> UserPlaylist? { playlists.first { $0.id == id } }

    /// Your playlists, the one added to last first: the Add to menu's order.
    var recentlyUsed: [UserPlaylist] {
        let order = defaults.stringArray(forKey: Pref.playlistsRecent) ?? []
        return playlists.sorted { a, b in
            let ia = order.firstIndex(of: a.id) ?? .max, ib = order.firstIndex(of: b.id) ?? .max
            return ia == ib ? a.name.localizedStandardCompare(b.name) == .orderedAscending : ia < ib
        }
    }

    /// A new, empty playlist named `name` (else "Untitled Playlist"), made
    /// unique with a number.
    @discardableResult
    func create(named name: String? = nil) -> UserPlaylist? {
        let base = Self.cleaned(name ?? "") ?? "Untitled Playlist"
        var candidate = base
        var n = 2
        while playlists.contains(where: { $0.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(base) \(n)"
            n += 1
        }
        let playlist = UserPlaylist(url: folder.appending(path: candidate + ".m3u"))
        guard write([], to: playlist) else { return nil }
        reload()
        return playlist
    }

    /// Rename `playlist`; nil when the name is empty or taken.
    @discardableResult
    func rename(_ playlist: UserPlaylist, to name: String) -> UserPlaylist? {
        guard let name = Self.cleaned(name) else { return nil }
        if name == playlist.name { return playlist }
        guard !playlists.contains(where: { $0.id != playlist.id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            error = "There's already a playlist called “\(name)”."
            return nil
        }
        let renamed = UserPlaylist(url: folder.appending(path: name + ".m3u"))
        do {
            try FileManager.default.moveItem(at: playlist.url, to: renamed.url)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
        paths[renamed.id] = paths.removeValue(forKey: playlist.id)
        rows[renamed.id] = rows.removeValue(forKey: playlist.id)
        touch(renamed.id, replacing: playlist.id)
        reload()
        return renamed
    }

    @discardableResult
    func duplicate(_ playlist: UserPlaylist) -> UserPlaylist? {
        guard let copy = create(named: "\(playlist.name) copy") else { return nil }
        write(read(playlist), to: copy)
        return copy
    }

    /// Move `playlist`'s file to the Trash.
    func delete(_ playlist: UserPlaylist) {
        do {
            try FileManager.default.trashItem(at: playlist.url, resultingItemURL: nil)
        } catch {
            self.error = error.localizedDescription
        }
        paths[playlist.id] = nil
        rows[playlist.id] = nil
        reload()
    }

    /// `playlist`'s files, in order.
    func read(_ playlist: UserPlaylist) -> [String] {
        if let cached = paths[playlist.id] { return cached }
        let text = (try? String(contentsOf: playlist.url, encoding: .utf8)) ?? ""
        let found = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        paths[playlist.id] = found
        return found
    }

    @discardableResult
    private func write(_ files: [String], to playlist: UserPlaylist) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try (["#EXTM3U"] + files).joined(separator: "\n").appending("\n")
                .write(to: playlist.url, atomically: true, encoding: .utf8)
        } catch {
            self.error = error.localizedDescription
            return false
        }
        paths[playlist.id] = files
        rows[playlist.id] = nil
        return true
    }

    /// Put `files` in `playlist` before `target` (a file in it), or at the
    /// end: moving those already in it, adding the others.
    func place(_ files: [String], before target: String?, in playlist: UserPlaylist) {
        let moving = files.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        var rest = read(playlist).filter { !moving.contains($0) }
        let at = target.flatMap { rest.firstIndex(of: $0) } ?? rest.count
        rest.insert(contentsOf: moving, at: at)
        write(rest, to: playlist)
        touch(playlist.id)
    }

    /// Take the rows of `playlist` at `ids` out of it.
    func remove(_ ids: Set<String>, from playlist: UserPlaylist) {
        write(read(playlist).filter { !ids.contains($0) }, to: playlist)
    }

    // MARK: Favourites

    func isFavourite(_ path: String) -> Bool { favouriteSet.contains(path) }

    func loadFavourites() async {
        let found = await core.favoritePaths()
        favourites = found
        favouriteSet = Set(found)
        rows[Self.favouritesID] = nil
    }

    func setFavourite(_ path: String, _ favourite: Bool) async {
        do {
            try await core.setFavorite(path: path, favorite: favourite)
        } catch {
            self.error = LibraryStore.message(for: error)
        }
        await loadFavourites()
    }

    // MARK: Adding

    /// Add `files` to `target`. A playlist added to moves to the top of
    /// the Add to menu.
    func add(_ files: [String], to target: AddTarget) async {
        guard !files.isEmpty else { return }
        switch target {
        case .myPlaylist:
            let present = Set(player.rows.map(\.id))
            let new = files.filter { !present.contains($0) }
            if !new.isEmpty { player.add(new.map { URL(filePath: $0) }) }
        case .favourites:
            for file in files where !isFavourite(file) {
                try? await core.setFavorite(path: file, favorite: true)
            }
            await loadFavourites()
        case .playlist(let id):
            guard let playlist = playlist(id) else { return }
            let existing = read(playlist)
            write(existing + files.filter { !existing.contains($0) }, to: playlist)
            touch(id)
        }
    }

    /// Make a playlist (named `name`, else "Untitled Playlist") holding
    /// `files`, and have the sidebar edit its name when none was given.
    @discardableResult
    func addToNew(_ files: [String], named name: String? = nil) async -> UserPlaylist? {
        guard let playlist = create(named: name) else { return nil }
        await add(files, to: .playlist(playlist.id))
        if name == nil { renaming = playlist.id }
        return playlist
    }

    private func touch(_ id: String, replacing old: String? = nil) {
        var order = defaults.stringArray(forKey: Pref.playlistsRecent) ?? []
        order.removeAll { $0 == id || $0 == old }
        order.insert(id, at: 0)
        defaults.set(Array(order.prefix(50)), forKey: Pref.playlistsRecent)
    }

    // MARK: Rows

    /// Read the rows of a playlist (or Favourites, `favouritesID`) from
    /// its files' headers.
    func loadRows(_ id: String) async {
        let files: [String]
        if id == Self.favouritesID {
            if favourites == nil { await loadFavourites() }
            files = favourites ?? []
        } else {
            guard let playlist = playlist(id) else { return }
            files = read(playlist)
        }
        let found = await core.tunesFromFiles(paths: files)
        rows[id] = found.map(LibraryRow.init)
    }

    /// A playlist name without what a file name can't hold; nil if empty.
    private static func cleaned(_ name: String) -> String? {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? nil : cleaned
    }
}
