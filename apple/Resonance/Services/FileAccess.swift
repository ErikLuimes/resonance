import Foundation

/// The folders and files the user handed the sandboxed app (a panel, Finder's
/// Open With, a drop), opened again at every launch from security-scoped
/// bookmarks: design/sandbox/README.md. Everything else keeps using paths.
nonisolated final class FileAccess: @unchecked Sendable {
    static let shared = FileAccess(defaults: .standard, container: NSHomeDirectory())

    private let defaults: UserDefaults
    /// The app's own folder (the sandbox's home): open without asking.
    private let container: String
    private let lock = NSLock()
    /// By path, the bookmark that opens it.
    private var bookmarks: [String: Data]

    init(defaults: UserDefaults, container: String) {
        self.defaults = defaults
        self.container = container
        bookmarks = defaults.dictionary(forKey: Pref.fileAccess) as? [String: Data] ?? [:]
    }

    /// What's kept, by path.
    var paths: [String] { lock.withLock { bookmarks.keys.sorted() } }

    /// Open everything kept. Gone ones are forgotten; moved ones are kept
    /// under their new path.
    func restore() {
        lock.withLock {
            var kept: [String: Data] = [:]
            for data in bookmarks.values {
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                         bookmarkDataIsStale: &stale),
                      url.startAccessingSecurityScopedResource()
                else { continue }
                kept[url.standardizedFileURL.path] = stale ? (try? Self.bookmark(url)) ?? data : data
            }
            bookmarks = kept
            save()
        }
    }

    /// Keep `urls`, just handed over. They stay open until the app quits.
    func keep(_ urls: [URL]) {
        lock.withLock {
            var changed = false
            for url in urls where url.isFileURL {
                let path = url.standardizedFileURL.path
                guard !covers(path) else { continue }
                let opened = url.startAccessingSecurityScopedResource()
                guard let data = try? Self.bookmark(url) else {
                    if opened { url.stopAccessingSecurityScopedResource() }
                    continue
                }
                // A folder covers what was kept inside it.
                bookmarks = bookmarks.filter { !Self.path($0.key, isIn: path) }
                bookmarks[path] = data
                changed = true
            }
            if changed { save() }
        }
    }

    /// Whether `path` is open without a bookmark of its own.
    func isCovered(_ path: String) -> Bool {
        lock.withLock { covers(URL(filePath: path).standardizedFileURL.path) }
    }

    private func covers(_ path: String) -> Bool {
        Self.path(path, isIn: container) || bookmarks.keys.contains { Self.path(path, isIn: $0) }
    }

    private static func path(_ path: String, isIn folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    private static func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func save() {
        defaults.set(bookmarks, forKey: Pref.fileAccess)
    }
}

/// The user's own home folder. Inside the sandbox `HOME`,
/// `NSHomeDirectory()` and `homeDirectoryForCurrentUser` are the app's
/// container, so code that means the real one asks here.
nonisolated enum RealHome {
    static var url: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(filePath: String(cString: dir), directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// A path to show: "~" for the real home, and the container (which
    /// `abbreviatingWithTildeInPath` would also call "~") by name.
    static func displayPath(_ path: String, container: String = NSHomeDirectory(),
                            support: String = AppPaths.supportDirectory.path) -> String {
        let path = URL(filePath: path).standardizedFileURL.path
        if path == support || path.hasPrefix(support + "/") {
            return "Resonance's folder" + path.dropFirst(support.count)
        }
        if path == container || path.hasPrefix(container + "/") {
            return String(localized: "Resonance's container") + path.dropFirst(container.count)
        }
        let home = url.path
        if path == home || path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
