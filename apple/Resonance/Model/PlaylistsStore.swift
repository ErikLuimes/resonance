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
    case favorites
    case playlist(String)
}

/// Your playlists, your favorites, and adding tunes to either.
///
/// Playlists are plain M3U files (one absolute path per line), so other
/// players open them too. Favorites are a favorites.json in Phosphor's
/// format, in Resonance's folder, read and written through the core.
@Observable
final class PlaylistsStore {
    /// Sorted by name.
    private(set) var playlists: [UserPlaylist] = []
    /// The favorites' files, newest first; nil until loaded.
    private(set) var favorites: [String]?
    /// Each playlist's files, by id; absent until read.
    private(set) var paths: [String: [String]] = [:]
    /// Rows for the lists shown, by id ("" for Favorites); absent until
    /// read from the files.
    private(set) var rows: [String: [LibraryRow]] = [:]
    /// A playlist whose name the sidebar should edit (one just made).
    var renaming: String?
    /// The last message about something that went wrong.
    private(set) var error: String?
    /// A playlist the sidebar should select (one just imported).
    var revealing: String?
    /// What's being read for an import or a drop, for the status banner.
    private(set) var importing: String?
    /// What an import or a drop couldn't find, until dismissed.
    var importNotice: String?

    let player: PlayerStore
    /// Where the M3U files are.
    let folder: URL
    @ObservationIgnored private let defaults: UserDefaults
    /// Observed: the hearts read it, and must fill the moment it changes.
    private var favoriteSet = Set<String>()

    nonisolated static let favoritesID = ""

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
        let base = Self.cleaned(name ?? "") ?? String(localized: "Untitled Playlist")
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
            error = String(localized: "There's already a playlist called “\(name)”.")
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
        guard let copy = create(named: String(localized: "\(playlist.name) copy")) else { return nil }
        write(read(playlist), to: copy)
        return copy
    }

    /// A list's files as they'd be exported, with any sub-tune chosen by
    /// file: only My Playlist remembers those.
    func exportContents(of target: AddTarget) -> (files: [String], songs: [String: UInt16]) {
        switch target {
        case .favorites:
            return (favorites ?? [], [:])
        case .myPlaylist:
            let chosen = player.rows.filter { $0.item.selectedSong != 1 }
            return (player.rows.map(\.id), Dictionary(chosen.map { ($0.id, $0.item.selectedSong) }) { first, _ in first })
        case .playlist(let id):
            return (playlist(id).map(read) ?? [], [:])
        }
    }

    /// Save a copy of a list for someone else, or another Mac: tunes in the
    /// collection get HVSC-relative paths like the curated playlists, which
    /// work wherever HVSC is. Others keep their full path.
    @discardableResult
    func export(_ target: AddTarget, to url: URL) -> Bool {
        let (files, songs) = exportContents(of: target)
        let text = Self.exportedM3U(files, songs: songs, hvscRoot: player.hvscRoot)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            importNotice = String(localized: "Couldn't export \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    static func exportedM3U(_ files: [String], songs: [String: UInt16] = [:], hvscRoot: String?) -> String {
        let prefix = hvscRoot.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var lines = ["#EXTM3U"]
        for file in files {
            if let song = songs[file] { lines.append("#PHOSPHOR:song=\(song)") }
            if let prefix, file.hasPrefix(prefix) {
                lines.append(String(file.dropFirst(prefix.count)))
            } else {
                lines.append(file)
            }
        }
        return lines.joined(separator: "\n") + "\n"
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

    // MARK: Tunes in several lists

    /// Rows for files that aren't in any list, from their headers.
    func tunes(from files: [String]) async -> [LibraryRow] {
        await core.tunesFromFiles(paths: files).map(LibraryRow.init)
    }

    /// The names of the lists holding any of `files`.
    func lists(holding files: Set<String>) -> [String] {
        var names: [String] = []
        if !files.isDisjoint(with: favoriteSet) { names.append(String(localized: "Favorites")) }
        if player.rows.contains(where: { files.contains($0.id) }) { names.append(String(localized: "My Playlist")) }
        names += playlists.filter { !files.isDisjoint(with: read($0)) }.map(\.name)
        return names
    }

    /// Takes `files` out of every list.
    func takeOut(_ files: Set<String>) async {
        for playlist in playlists where !files.isDisjoint(with: read(playlist)) {
            remove(files, from: playlist)
        }
        for path in files where isFavorite(path) {
            await setFavorite(path, false)
        }
        player.remove(indices: player.rows.filter { files.contains($0.id) }.map(\.index))
    }

    // MARK: Favorites

    func isFavorite(_ path: String) -> Bool { favoriteSet.contains(path) }

    func loadFavorites() async {
        let found = await core.favoritePaths()
        favorites = found
        favoriteSet = Set(found)
        rows[Self.favoritesID] = nil
    }

    func setFavorite(_ path: String, _ favorite: Bool) async {
        do {
            try await core.setFavorite(path: path, favorite: favorite)
        } catch {
            self.error = LibraryStore.message(for: error)
        }
        await loadFavorites()
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
        case .favorites:
            for file in files where !isFavorite(file) {
                try? await core.setFavorite(path: file, favorite: true)
            }
            await loadFavorites()
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

    // MARK: Files from outside

    /// Whether the file is a playlist, as the core reads them.
    static func isPlaylistFile(_ url: URL) -> Bool {
        ["m3u", "m3u8", "pls"].contains(url.pathExtension.lowercased())
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// Make playlists from files dropped or opened from outside: one for
    /// each playlist file and folder, named after it, and one for the
    /// loose tunes, whose name the sidebar edits. The sidebar selects the
    /// last one made. The files themselves stay as they are.
    func importAsNew(_ urls: [URL]) async {
        var notices: [String] = []
        var made: UserPlaylist?
        for url in urls where Self.isPlaylistFile(url) || Self.isFolder(url) {
            let name = Self.isFolder(url) ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
            if let playlist = await importTunes(of: [url], named: name, notices: &notices) {
                made = playlist
            }
        }
        let loose = urls.filter { !Self.isPlaylistFile($0) && !Self.isFolder($0) }
        if !loose.isEmpty, let playlist = await importTunes(of: loose, named: nil, notices: &notices) {
            made = playlist
        }
        if !notices.isEmpty { importNotice = notices.joined(separator: " ") }
        if let made { revealing = made.id }
    }

    /// Add what's behind files dropped or opened from outside to `target`.
    func addFiles(_ urls: [URL], to target: AddTarget) async {
        // Through the core's own route, like a drop on the window: it keeps
        // what a playlist file says about sub-tunes, and the session's order.
        if target == .myPlaylist {
            player.add(urls)
            return
        }
        let resolved = await resolve(urls, label: urls.first?.lastPathComponent ?? "")
        await add(resolved.paths, to: target)
        if let notice = Self.notice(for: resolved, name: Self.displayName(of: urls), hvscRoot: player.hvscRoot) {
            importNotice = notice
        }
    }

    private func importTunes(of urls: [URL], named name: String?, notices: inout [String]) async -> UserPlaylist? {
        let resolved = await resolve(urls, label: name ?? urls.first?.lastPathComponent ?? "")
        let label = name ?? Self.displayName(of: urls)
        if let notice = Self.notice(for: resolved, name: label, hvscRoot: player.hvscRoot) {
            notices.append(notice)
        }
        guard !resolved.paths.isEmpty else { return nil }
        return await addToNew(resolved.paths, named: name)
    }

    private func resolve(_ urls: [URL], label: String) async -> ResolvedFiles {
        importing = String(localized: "Reading \(label)…")
        defer { importing = nil }
        return await core.resolveFiles(paths: urls.map(\.path))
    }

    private static func displayName(of urls: [URL]) -> String {
        urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : String(localized: "The dropped files")
    }

    /// What to say about tunes that didn't load; nil when they all did.
    static func notice(for resolved: ResolvedFiles, name: String, hvscRoot: String?) -> String? {
        if resolved.paths.isEmpty {
            let hint = hvscRoot == nil ? String(localized: " Choose your HVSC folder in Settings, then try again.") : ""
            return String(localized: "No playable SID files found in \(name).\(hint)")
        }
        guard resolved.found < resolved.listed else { return nil }
        return String(localized: "\(name): \(resolved.found) of \(resolved.listed) tunes found.")
    }

    // MARK: Rows

    /// Read the rows of a playlist (or Favorites, `favoritesID`) from
    /// its files' headers.
    func loadRows(_ id: String) async {
        let files: [String]
        if id == Self.favoritesID {
            if favorites == nil { await loadFavorites() }
            files = favorites ?? []
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
