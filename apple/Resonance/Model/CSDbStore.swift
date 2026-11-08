#if CSDB // Off unless Config/Signing.local.xcconfig turns it on, until CSDb's admins have had their say.

import Foundation
import Observation

/// A release on CSDb, the Commodore 64 Scene Database.
struct CSDbRelease: Identifiable, Hashable {
    let id: Int
    let title: String
    let groups: [String]
    /// CSDb's release type: "C64 Music", "C64 Demo" and so on.
    let kind: String
    let date: Date
    let url: URL
    let imageURL: URL?

    /// "2SID" or "3SID" when the title says so; nil for a plain tune.
    var sidFormat: String? {
        guard let range = title.range(of: #"\[\s*(\d)\s*sid\s*\]"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let digits = title[range].filter(\.isNumber)
        return digits.isEmpty ? nil : "\(digits)SID"
    }

    /// The title without its "[2SID]" tag, which shows as a badge instead.
    var displayTitle: String {
        title.replacingOccurrences(of: #"\s*\[\s*\d\s*sid\s*\]"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
    }

    var byline: String { groups.isEmpty ? String(localized: "Unknown group") : groups.joined(separator: ", ") }
}

/// An event on CSDb: a party, a compo, a meeting.
struct CSDbEvent: Identifiable, Hashable {
    let id: Int
    let title: String
    let kind: String
    /// As CSDb writes it: "6 - 8 November 2026".
    let when: String
    let tagline: String?
    let url: URL
    let imageURL: URL?

    /// The days of `when`, however CSDb writes it: "6 - 8 November 2026",
    /// "1 October - 31 December 2026", "28 November 2026", "November 2026".
    static func days(of when: String, calendar: Calendar = .current) -> ClosedRange<Date>? {
        let months = ["january", "february", "march", "april", "may", "june", "july",
                      "august", "september", "october", "november", "december"]
        let ends = when.components(separatedBy: " - ")
        guard (1...2).contains(ends.count) else { return nil }
        func parts(_ text: String) -> (day: Int?, month: Int?, year: Int?) {
            var found: (day: Int?, month: Int?, year: Int?) = (nil, nil, nil)
            for word in text.split(separator: " ") {
                if let number = Int(word) {
                    if number > 31 { found.year = number } else { found.day = number }
                } else if let month = months.firstIndex(of: word.lowercased()) {
                    found.month = month + 1
                }
            }
            return found
        }
        let last = parts(ends[ends.count - 1])
        guard let month = last.month, let year = last.year else { return nil }
        let first = ends.count == 2 ? parts(ends[0]) : last
        let start = calendar.date(from: DateComponents(year: first.year ?? year, month: first.month ?? month, day: first.day ?? 1))
        var end = calendar.date(from: DateComponents(year: year, month: month, day: last.day ?? 1))
        if last.day == nil, let day = end, let span = calendar.range(of: .day, in: .month, for: day) {
            end = calendar.date(from: DateComponents(year: year, month: month, day: span.count))
        }
        guard let start, let end, start <= end else { return nil }
        return start...end
    }
}

/// How long the top of Scene Pulse has shown something, and when to move on.
/// Time only counts while it isn't paused, so a pointer over it leaves as long
/// as there was.
nonisolated struct SceneFeatureClock {
    static let duration = 8.0
    static let tick = 1.0 / 30

    private(set) var elapsed = 0.0

    var progress: Double { min(elapsed / Self.duration, 1) }

    /// Whether it's time to move on.
    mutating func advance(by seconds: Double, isPaused: Bool) -> Bool {
        guard !isPaused else { return false }
        elapsed += seconds
        return elapsed >= Self.duration
    }

    mutating func reset() { elapsed = 0 }
}

/// What the top of Scene Pulse can feature.
enum SceneFeature: Identifiable, Hashable {
    case release(CSDbRelease)
    case event(CSDbEvent)
    case top(CSDbTopRelease)

    var id: String {
        switch self {
        case .release(let release): "release \(release.id)"
        case .event(let event): "event \(event.id)"
        case .top(let release): "top \(release.id)"
        }
    }

    /// What kind of thing it is: "Just Released", "On Now", "Highest Rated".
    func typeName(today: Date) -> String {
        switch self {
        case .release(let release):
            today.timeIntervalSince(release.date) < 14 * 86400 ? "Just Released" : "Newest Music"
        case .event: "On Now"
        case .top: "Highest Rated"
        }
    }

    /// The newest music, what's on today, and the best on the chart. Of
    /// several events on, a party first: compos run for months.
    static func pick(music: [CSDbRelease], events: [CSDbEvent], top: [CSDbTopRelease],
                     today: Date, calendar: Calendar = .current) -> [SceneFeature] {
        let day = calendar.startOfDay(for: today)
        let running = events.filter { CSDbEvent.days(of: $0.when, calendar: calendar)?.contains(day) == true }
        var features: [SceneFeature] = []
        if let newest = music.first { features.append(.release(newest)) }
        if let event = running.first(where: { $0.kind.localizedCaseInsensitiveContains("party") }) ?? running.first {
            features.append(.event(event))
        }
        if let best = top.first, best.id != music.first?.id { features.append(.top(best)) }
        return features
    }
}

/// One line of CSDb's scene news: someone joined, left or entered the scene.
struct CSDbNewsItem: Identifiable, Hashable {
    let id: String
    let text: String
    /// The scener or group it's about.
    let url: URL?
    var date: Date?
}

/// What CSDb's webservice has on the scener or group a news item is about.
nonisolated struct CSDbNewsDetail: Equatable, Sendable {
    let name: String
    /// "Germany", "Coder, Musician", "Formed 1985": whatever it knows.
    let lines: [String]
}

/// A place on CSDb's chart of C64 music.
nonisolated struct CSDbTopRelease: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let groups: [String]
    /// CSDb's weighted average, out of 10.
    let rating: Double
    let votes: Int

    var url: URL { URL(string: "https://csdb.dk/release/?id=\(id)")! }
    var byline: String { groups.joined(separator: ", ") }

    /// "2SID" from a title's "[2sid]".
    var sidFormat: String? {
        guard let range = title.range(of: #"\[\s*(\d)\s*sid\s*\]"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let digits = title[range].filter(\.isNumber)
        return digits.isEmpty ? nil : "\(digits)SID"
    }

    /// The title without its "[2SID]" tag, which shows as a badge instead.
    var displayTitle: String {
        title.replacingOccurrences(of: #"\s*\[\s*\d\s*sid\s*\]"#, with: "", options: [.regularExpression, .caseInsensitive])
    }
}

/// CSDb's top list, which has no feed: read from the page itself.
nonisolated enum CSDbTopList {
    /// The rating these all have, if they do: then it's said once, not on
    /// every row. A chart's top is mostly tied at 10.00.
    static func commonRating(_ releases: [CSDbTopRelease]) -> Double? {
        guard let first = releases.first, releases.allSatisfy({ $0.rating == first.rating }) else { return nil }
        return first.rating
    }

    /// The chart's rows, best first. CSDb leaves ties unranked and a lot of
    /// tunes tie at 10.00, so ties go to the one with more votes.
    static func music(from html: String) -> [CSDbTopRelease] {
        // Only the chart: the page's sidebars list other top releases too.
        guard let head = html.range(of: "Release Name") else { return [] }
        let tail = html[head.upperBound...]
        let chart = tail.range(of: "</table>").map { String(tail[..<$0.lowerBound]) } ?? String(tail)
        let pattern = #"<tr><td align=right>[^<]*</td><td><a href="/release/\?id=(\d+)">([^<]*)</a>(.*?)</td><td align=center><font size=1>([\d.]+)</font></td><td></td><td align=center>(\d+)</td></tr>"#
        guard let row = try? NSRegularExpression(pattern: pattern) else { return [] }
        let rows: [CSDbTopRelease] = row.matches(in: chart, range: NSRange(chart.startIndex..., in: chart)).compactMap { found in
            func field(_ index: Int) -> String? {
                Range(found.range(at: index), in: chart).map { String(chart[$0]) }
            }
            guard let id = field(1).flatMap(Int.init), let title = field(2),
                  let rating = field(4).flatMap(Double.init), let votes = field(5).flatMap(Int.init)
            else { return nil }
            let by = (field(3) ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            let groups = unescape(by.trimmingCharacters(in: .whitespaces))
                .replacingOccurrences(of: #"^by\s+"#, with: "", options: .regularExpression)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return CSDbTopRelease(id: id, title: unescape(title), groups: groups, rating: rating, votes: votes)
        }
        return rows.sorted { ($0.rating, $0.votes) > ($1.rating, $1.votes) }
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// The C64 scene, from CSDb: new music, upcoming events and scene news from
/// its RSS feeds, and its chart of C64 music. Nothing is fetched until a view
/// asks. Each feed is kept on disk for an hour (CSDb's own refresh interval)
/// and the chart, a much larger page that moves slowly, for a day. An older
/// copy stands in when the network is down.
@Observable
@MainActor
final class CSDbStore {
    enum State: Equatable {
        case idle
        case loading
        case failed(String)
    }

    /// The last refresh failed, whatever the message.
    var isFailed: Bool {
        if case .failed = state { true } else { false }
    }

    /// Music releases only, newest first.
    private(set) var music: [CSDbRelease] = []
    private(set) var events: [CSDbEvent] = []
    private(set) var news: [CSDbNewsItem] = []
    /// Empty if CSDb's chart couldn't be read; the rest works without it.
    private(set) var topMusic: [CSDbTopRelease] = []
    /// By news item URL, once someone has hovered over the item.
    private(set) var newsDetails: [URL: CSDbNewsDetail] = [:]
    /// Releases being fetched to play, or that couldn't be (CSDbPlayback.swift).
    var playStates: [Int: CSDbPlayState] = [:]
    /// The releases whose SID is on disk (CSDbPlayback.swift).
    var downloadedIDs: Set<Int> = CSDbStore.scanDownloads()
    /// What releases offer to play, once asked.
    var releaseFiles: [Int: CSDbReleaseFiles] = [:]
    /// Composers' photos, by the name asked for (WikimediaPhoto.swift).
    var composerPhotos: [String: WikimediaPhoto] = [:]
    var checkedPhotos = Set<String>()
    private(set) var updated: Date?
    private(set) var state = State.idle
    /// Composers looked up on CSDb, by normalized name (see CSDbProfile.swift).
    var profiles: [String: CSDbLookup] = [:]

    private static let base = URL(string: "https://csdb.dk/rss/")!
    private static let lifetime: TimeInterval = 3600
    private static let chartLifetime: TimeInterval = 86400
    private static let chart = URL(string: "https://csdb.dk/toplist.php?type=release&subtype=%287%29")!

    let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        config.httpAdditionalHeaders = ["User-Agent": "Resonance/\(version) (https://useresonance.app; SID player)"]
        return URLSession(configuration: config)
    }()

    /// The Settings switch: while it's off, nothing goes to csdb.dk.
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Pref.csdbEnabled) as? Bool ?? false
    }

    /// Loads the three feeds, from disk when they are fresh. `force` skips
    /// the cache, for the Refresh button.
    func refresh(force: Bool = false) async {
        guard isEnabled, state != .loading else { return }
        if !force, let updated, Date().timeIntervalSince(updated) < Self.lifetime { return }
        state = .loading
        do {
            async let releaseData = feed("latestreleases.php", force: force)
            async let eventData = feed("upcomingevents.php", force: force)
            async let newsData = feed("scenenews.php", force: force)
            let (releases, events, news) = try await (releaseData, eventData, newsData)
            self.music = CSDbFeeds.releases(from: releases.data).filter { $0.kind.localizedCaseInsensitiveContains("music") }
            self.events = CSDbFeeds.events(from: events.data)
            self.news = CSDbFeeds.news(from: news.data)
            self.updated = [releases.fetched, events.fetched, news.fetched].min()
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
        // Never forced: Refresh is for the news, and this page is large.
        if let page = try? await fetch(Self.chart, file: "toplist-music.html", lifetime: Self.chartLifetime, force: false) {
            let bytes = page.data
            topMusic = await Task.detached {
                CSDbTopList.music(from: String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? "")
            }.value
        }
    }

    /// Fills in `newsDetails` for an item. The feed has only the one line,
    /// so this asks the webservice who it's about. Once per item a launch;
    /// a failure just leaves the popover with the line and date.
    func loadNewsDetail(_ item: CSDbNewsItem) async {
        guard isEnabled, let url = item.url, newsDetails[url] == nil,
              let id = url.query?.split(separator: "=").last.map(String.init), Int(id) != nil else { return }
        let type = url.path.contains("group") ? "group" : "scener"
        guard let service = URL(string: "https://csdb.dk/webservice/?type=\(type)&id=\(id)&depth=1"),
              let (data, _) = try? await session.data(from: service) else { return }
        let detail: CSDbNewsDetail?
        if type == "group" {
            detail = CSDbGroupInfo.detail(from: data)
        } else {
            detail = CSDbScener.profile(from: data).map { profile in
                let lines = [profile.country, profile.aka.map { String(localized: "Also known as \($0)") },
                             profile.roles.isEmpty ? nil : profile.roles.joined(separator: ", ")]
                return CSDbNewsDetail(name: profile.name, lines: lines.compactMap { $0 })
            }
        }
        if let detail { newsDetails[url] = detail }
    }

    /// One feed's bytes and when they were fetched: the cached copy while
    /// it's fresh, else the network, else the stale copy.
    private func feed(_ name: String, force: Bool) async throws -> (data: Data, fetched: Date) {
        try await fetch(Self.base.appendingPathComponent(name), file: name + ".xml", lifetime: Self.lifetime, force: force)
    }

    func fetch(_ url: URL, file name: String, lifetime: TimeInterval, force: Bool) async throws -> (data: Data, fetched: Date) {
        let file = Self.cacheFolder.appendingPathComponent(name)
        let cached = try? Data(contentsOf: file)
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if !force, let cached, let modified, Date().timeIntervalSince(modified) < lifetime {
            return (cached, modified)
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try? FileManager.default.createDirectory(at: Self.cacheFolder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return (data, Date())
        } catch {
            if let cached { return (cached, modified ?? .distantPast) }
            throw error
        }
    }

    private static var cacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CSDb", isDirectory: true)
    }
}

/// A group from the webservice (`type=group`, depth 1).
nonisolated enum CSDbGroupInfo {
    static func detail(from data: Data) -> CSDbNewsDetail? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        guard let name = reader.fields["Name"], !name.isEmpty else { return nil }
        var lines: [String] = []
        if let country = reader.fields["BaseCountry"] { lines.append(country) }
        if !reader.types.isEmpty { lines.append(reader.types.joined(separator: ", ")) }
        if let year = reader.fields["FoundYear"] { lines.append(String(localized: "Formed \(year)")) }
        if let year = reader.fields["DissolveYear"] { lines.append(String(localized: "Dissolved \(year)")) }
        let short = reader.fields["Short"].map { " (\($0))" } ?? ""
        return CSDbNewsDetail(name: name + short, lines: lines)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var fields: [String: String] = [:]
        var types: [String] = []
        private var path: [String] = []
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            path.append(name)
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            defer {
                path.removeLast()
                text = ""
            }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, path.count >= 3, path[0] == "CSDbData", path[1] == "Group" else { return }
            if path.count == 3 {
                fields[elementName] = value
            } else if path[2] == "Grouptypes" {
                types.append(value)
            }
        }
    }
}

/// CSDb's feed formats, read into the app's types. Pure functions over the
/// feed's bytes, so they can be tested without the network.
enum CSDbFeeds {
    static func releases(from data: Data) -> [CSDbRelease] {
        items(in: data).compactMap { item in
            guard let guid = item["guid"], let id = entryID(guid),
                  let title = item["title"], let url = URL(string: "https://csdb.dk/release/?id=\(id)")
            else { return nil }
            let description = item["description"] ?? ""
            let groups = match(#"Released by:\s*(.*?)<br"#, in: description)
                .map { strip($0) }
                .map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                ?? []
            let kind = match(#"Type:\s*<a[^>]*>([^<]*)</a>"#, in: description) ?? ""
            return CSDbRelease(
                id: id, title: unescape(title), groups: groups.map(unescape), kind: unescape(kind),
                date: item["pubDate"].flatMap(date) ?? .distantPast, url: url,
                imageURL: match(#"src="([^"]+)""#, in: description).flatMap(URL.init(string:))
            )
        }
    }

    static func events(from data: Data) -> [CSDbEvent] {
        items(in: data).compactMap { item in
            guard let guid = item["guid"], let id = entryID(guid),
                  let title = item["title"], let url = URL(string: "https://csdb.dk/event/?id=\(id)")
            else { return nil }
            let description = item["description"] ?? ""
            let tagline = match(#"<i>\s*-?\s*(.*?)</i>"#, in: description).map { unescape(strip($0)) }
            return CSDbEvent(
                id: id, title: unescape(title),
                kind: unescape(match(#"Event type:\s*([^<]*)<"#, in: description) ?? ""),
                when: unescape(match(#"Held on:\s*([^<]*)<"#, in: description) ?? ""),
                tagline: (tagline?.isEmpty ?? true) ? nil : tagline,
                url: url,
                imageURL: match(#"src="([^"]+)""#, in: description).flatMap(URL.init(string:))
            )
        }
    }

    static func news(from data: Data) -> [CSDbNewsItem] {
        items(in: data).compactMap { item in
            guard let title = item["title"], !title.isEmpty else { return nil }
            let link = item["link"].flatMap { URL(string: $0.replacingOccurrences(of: "&rss", with: "")) }
            return CSDbNewsItem(id: item["guid"] ?? title + (item["pubDate"] ?? ""), text: unescape(title), url: link, date: item["pubDate"].flatMap(date))
        }
    }

    // ── Reading ──

    /// Each `<item>`'s child elements by name, CDATA included.
    private static func items(in data: Data) -> [[String: String]] {
        let reader = ItemReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.items
    }

    private final class ItemReader: NSObject, XMLParserDelegate {
        var items: [[String: String]] = []
        private var current: [String: String]?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "item" { current = [:] }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            text += String(decoding: data, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "item", let current {
                items.append(current)
                self.current = nil
            } else if current != nil {
                current?[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private static func entryID(_ guid: String) -> Int? {
        match(#"id=(\d+)"#, in: guid).flatMap(Int.init)
    }

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              found.numberOfRanges > 1, let range = Range(found.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func strip(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    /// CSDb escapes some titles twice ("&amp;amp;").
    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
    }

    private static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: text)
    }
}

#endif
