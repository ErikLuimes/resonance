import Foundation

/// What a release offers to play: a tune already in HVSC, or a .sid to
/// download. Most other downloads are C64 programs (.prg, .d64), which only
/// run on a C64, so a player can't play them.
nonisolated struct CSDbReleaseFiles: Equatable, Sendable {
    var hvscPath: String?
    /// HVSC's name for the tune and who made it: not always who CSDb's
    /// credits lead here from. A remix credits the original's composer too.
    var hvscTitle: String?
    var hvscAuthor: String?
    var sidDownload: URL?
    var cover: URL?
    var year: Int?
    var month: Int?
    /// Its first placing at a party, as CSDb lists them.
    var placing: CSDbResult?

    /// Who made it, by the name people know them by here: HVSC writes
    /// "Michael P. Bridgewater (Mibri)".
    var composerHandle: String? {
        guard let author = hvscAuthor else { return nil }
        guard author.hasSuffix(")"), let open = author.lastIndex(of: "(") else { return author }
        let handle = author[author.index(after: open)...].dropLast()
        return handle.isEmpty ? author : String(handle)
    }

    /// "3rd, Mixed Music at Revision 2025", or else "Released Sep 2025".
    var story: String? {
        if let placing {
            return "\(placing.placeText), \(placing.compo)" + (placing.event.map { " at \($0)" } ?? "")
        }
        let date = CSDbCredit(id: 0, name: "", kind: "", year: year, month: month).dateText
        return date.map { "Released \($0)" }
    }

    /// A release from the webservice (`type=release`, depth 2).
    static func parse(_ data: Data) -> CSDbReleaseFiles {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        let placing = reader.place.flatMap { place in
            reader.compo.map { CSDbResult(place: place, compo: $0, title: "", event: reader.event, year: nil) }
        }
        return CSDbReleaseFiles(hvscPath: reader.hvscPath, hvscTitle: reader.hvscTitle,
                                hvscAuthor: reader.hvscAuthor, sidDownload: reader.sid, cover: reader.cover,
                                year: reader.year, month: reader.month, placing: placing)
    }

    /// PSID and RSID are the only headers a SID file can start with.
    static func isSID(_ data: Data) -> Bool {
        let magic = data.prefix(4)
        return magic.elementsEqual("PSID".utf8) || magic.elementsEqual("RSID".utf8)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var hvscPath: String?
        var hvscTitle: String?
        var hvscAuthor: String?
        var sid: URL?
        var cover: URL?
        var year: Int?
        var month: Int?
        var event: String?
        var compo: String?
        var place: Int?
        private var path: [String] = []
        private var text = ""
        private var link: String?
        private var counter: String?
        private var status: String?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            path.append(name)
            text = ""
            if name == "DownloadLink" {
                link = nil
                counter = nil
                status = nil
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            defer {
                path.removeLast()
                text = ""
            }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only the release itself: credits can hold other releases.
            switch path.joined(separator: "/") {
            case "CSDbData/Release/ScreenShot": cover = Self.safeURL(value)
            case "CSDbData/Release/ReleaseYear": year = Int(value)
            case "CSDbData/Release/ReleaseMonth": month = Int(value)
            case "CSDbData/Release/ReleasedAt/Event/Name":
                if event == nil, !value.isEmpty { event = value }
            case "CSDbData/Release/Achievement/Compo":
                if compo == nil, !value.isEmpty { compo = value }
            case "CSDbData/Release/Achievement/Place":
                if place == nil { place = Int(value) }
            case "CSDbData/Release/UsedSIDs/SID/HVSCPath":
                if hvscPath == nil, !value.isEmpty { hvscPath = value }
            case "CSDbData/Release/UsedSIDs/SID/Name":
                if hvscTitle == nil, !value.isEmpty { hvscTitle = value }
            case "CSDbData/Release/UsedSIDs/SID/Author":
                if hvscAuthor == nil, !value.isEmpty { hvscAuthor = value }
            case "CSDbData/Release/DownloadLinks/DownloadLink/Link": link = value
            case "CSDbData/Release/DownloadLinks/DownloadLink/CounterLink": counter = value
            case "CSDbData/Release/DownloadLinks/DownloadLink/Status": status = value
            case "CSDbData/Release/DownloadLinks/DownloadLink":
                guard sid == nil, status == nil || status == "Ok",
                      link?.lowercased().hasSuffix(".sid") == true else { return }
                // The counter link, so the download counts on CSDb.
                sid = Self.safeURL(counter) ?? Self.safeURL(link)
            default: break
            }
        }

        /// CSDb's own server over https: links can point anywhere.
        private static func safeURL(_ text: String?) -> URL? {
            guard let text, let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
                  var parts = URLComponents(string: encoded),
                  parts.host == "csdb.dk" || parts.host == "www.csdb.dk" else { return nil }
            parts.scheme = "https"
            return parts.url
        }
    }
}

/// How playing a release from CSDb stands, by release; absent once it plays.
enum CSDbPlayState: Equatable {
    case loading
    /// The release has no SID file, or none in reach.
    case unavailable
    case failed(String)
}

extension CSDbStore {
    /// A SID file is tiny; anything this big isn't one.
    private static let largestSID = 2_000_000

    /// Plays a release: your collection's copy if CSDb says it's in HVSC,
    /// else its SID, downloaded once.
    func play(release id: Int, title: String, author: String, on library: LibraryStore) async {
        guard isEnabled, playStates[id] != .loading else { return }
        playStates[id] = .loading
        do {
            // Already downloaded: no need to ask CSDb anything.
            let saved = Self.sidFolder.appending(path: "\(id).sid")
            if FileManager.default.fileExists(atPath: saved.path) {
                start(saved, source: .scene, title: title, author: author, id: id, player: library.player)
                return
            }
            let files = try await files(ofRelease: id)
            if let tune = hvscTune(ofRelease: id, library: library) {
                // A tune of the collection like any other, so "Playing from"
                // leads to it in the library, under who really made it.
                let name = files.hvscAuthor ?? author
                start(tune, source: .folder(name: name, category: library.category(of: tune.path) ?? .musicians),
                      title: files.hvscTitle ?? title, author: name, id: id, player: library.player)
            } else if let file = try await download(files, release: id) {
                start(file, source: .scene, title: title, author: author, id: id, player: library.player)
            } else {
                playStates[id] = .unavailable
            }
        } catch {
            playStates[id] = .failed(error.localizedDescription)
        }
    }

    private func start(_ file: URL, source: PlaybackSource, title: String, author: String, id: Int, player: PlayerStore) {
        playStates[id] = nil
        player.playQueue([file], startAt: file, from: source,
                         tunes: [QueuedTune(path: file.path, title: title, author: author)])
    }

    /// What's on a chart, one release at a time: no need to hit CSDb all at
    /// once for a card.
    func loadChartDetails(_ releases: [CSDbTopRelease]) async {
        guard isEnabled else { return }
        for release in releases {
            _ = try? await files(ofRelease: release.id)
        }
    }

    /// What a release offers, kept on disk for a week: a release's cover,
    /// tunes and placings hardly change.
    @discardableResult
    func files(ofRelease id: Int) async throws -> CSDbReleaseFiles {
        if let known = releaseFiles[id] { return known }
        let service = URL(string: "https://csdb.dk/webservice/?type=release&id=\(id)&depth=2")!
        let (xml, _) = try await fetch(service, file: "release-\(id).xml", lifetime: 7 * 86400, force: false)
        let files = await Task.detached { CSDbReleaseFiles.parse(xml) }.value
        releaseFiles[id] = files
        return files
    }

    /// The release's tune in your collection, once CSDb has said which it is.
    func hvscTune(ofRelease id: Int, library: LibraryStore) -> URL? {
        guard let path = releaseFiles[id]?.hvscPath, let tune = library.file(atHvscPath: path),
              FileManager.default.fileExists(atPath: tune.path) else { return nil }
        return tune
    }

    private func download(_ files: CSDbReleaseFiles, release id: Int) async throws -> URL? {
        let saved = Self.sidFolder.appending(path: "\(id).sid")
        guard let download = files.sidDownload else { return nil }
        let (data, response) = try await session.data(from: download)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= Self.largestSID,
              CSDbReleaseFiles.isSID(data) else { return nil }
        try FileManager.default.createDirectory(at: Self.sidFolder, withIntermediateDirectories: true)
        try data.write(to: saved, options: .atomic)
        downloadedIDs.insert(id)
        return saved
    }

    // ── Downloads ──

    /// The downloaded files, newest first.
    func downloadedFiles() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.sidFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { Self.releaseID(ofFile: $0) != nil }
            .map { file in
                (file.path, (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Deletes downloaded files. Only ever files in the downloads folder,
    /// whatever paths come in.
    func removeDownloads(_ paths: Set<String>) {
        for path in paths {
            let file = URL(filePath: path)
            guard let id = Self.releaseID(ofFile: file),
                  file.deletingLastPathComponent().standardizedFileURL.path == Self.sidFolder.standardizedFileURL.path
            else { continue }
            try? FileManager.default.removeItem(at: file)
            downloadedIDs.remove(id)
            playStates[id] = nil
        }
    }

    /// The page a downloaded file came from.
    static func releaseURL(ofDownload path: String) -> URL? {
        releaseID(ofFile: URL(filePath: path)).flatMap { URL(string: "https://csdb.dk/release/?id=\($0)") }
    }

    static func scanDownloads() -> Set<Int> {
        let files = (try? FileManager.default.contentsOfDirectory(at: sidFolder, includingPropertiesForKeys: nil)) ?? []
        return Set(files.compactMap(releaseID(ofFile:)))
    }

    /// Downloads are named by their release: "265707.sid".
    private static func releaseID(ofFile file: URL) -> Int? {
        file.pathExtension == "sid" ? Int(file.deletingPathExtension().lastPathComponent) : nil
    }

    /// Kept for good, not in Caches: a downloaded tune can end up in your
    /// playlists and history.
    static var sidFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Resonance/CSDb", directoryHint: .isDirectory)
    }
}
