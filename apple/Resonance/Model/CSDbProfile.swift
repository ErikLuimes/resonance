#if CSDB // Off unless Config/Signing.local.xcconfig turns it on, until CSDb's admins have had their say.

import Foundation

/// A scener on CSDb, as the composer cards show them: where they're from,
/// what they do, and CSDb's trivia.
nonisolated struct CSDbProfile: Codable, Equatable, Sendable {
    /// The handle's CSDb id, which CSDb's scener page takes.
    let id: Int
    let name: String
    let aka: String?
    let country: String?
    let roles: [String]
    let trivia: String?
    /// Every name they've gone by, the one in use first.
    var handles: [CSDbHandle] = []
    var groups: [String] = []
    var formerGroups: [String] = []
    /// "August 1985", when they're in one group and CSDb knows.
    var groupFormed: String?
    /// The newest music release crediting this handle.
    var latestMusic: CSDbCredit?
    /// Their best compo places, best first.
    var results: [CSDbResult] = []

    var url: URL { URL(string: "https://csdb.dk/scener/?id=\(id)")! }

    /// CSDb's trivia with its `[url=…]text[/url]` links made real and its
    /// other markup dropped, cut to `limit` characters.
    func triviaText(limit: Int = 320) -> AttributedString? {
        // CSDb's own cross-reference tags (<scener id="1">) mean nothing
        // here, and ||| marks text its author struck out (a hacked site):
        // the lines holding them are left out.
        guard let trivia = self.trivia.map({ text in
            Self.unescape(text).split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.range(of: #"<(scener|group|release|event|bbs|sid)\b"#, options: .regularExpression) == nil }
                .filter { !$0.contains("|||") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }), !trivia.isEmpty else { return nil }
        let markup = try? NSRegularExpression(pattern: #"\[url=([^\]]+)\](.*?)\[/url\]"#, options: [.dotMatchesLineSeparators])
        var result = AttributedString()
        var cursor = trivia.startIndex
        for found in markup?.matches(in: trivia, range: NSRange(trivia.startIndex..., in: trivia)) ?? [] {
            guard let whole = Range(found.range, in: trivia),
                  let target = Range(found.range(at: 1), in: trivia),
                  let label = Range(found.range(at: 2), in: trivia) else { continue }
            result += AttributedString(Self.plain(trivia[cursor..<whole.lowerBound]))
            var link = AttributedString(Self.plain(trivia[label]))
            let address = Self.unescape(String(trivia[target]))
            if let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()) {
                link.link = url
            }
            result += link
            cursor = whole.upperBound
        }
        result += AttributedString(Self.plain(trivia[cursor...]))
        Self.linkBareAddresses(in: &result)
        if result.characters.count > limit {
            let end = result.index(result.startIndex, offsetByCharacters: limit)
            result = AttributedString(result[..<end]) + AttributedString("…")
        }
        return result
    }

    /// Trivia often just writes out an address.
    private static func linkBareAddresses(in text: inout AttributedString) {
        let string = String(text.characters)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        for found in detector.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
            guard let url = found.url, ["http", "https"].contains(url.scheme?.lowercased()),
                  let range = Range(found.range, in: string) else { continue }
            let start = text.index(text.startIndex, offsetByCharacters: string.distance(from: string.startIndex, to: range.lowerBound))
            let end = text.index(text.startIndex, offsetByCharacters: string.distance(from: string.startIndex, to: range.upperBound))
            if text[start..<end].link == nil { text[start..<end].link = url }
        }
    }

    private static func plain(_ text: Substring) -> String {
        unescape(String(text).replacingOccurrences(of: #"\[/?[a-z]+(=[^\]]*)?\]"#, with: "",
                                                   options: [.regularExpression, .caseInsensitive]))
    }

    fileprivate static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}

/// One of a scener's names on CSDb.
nonisolated struct CSDbHandle: Codable, Equatable, Sendable {
    let name: String
    let inUse: Bool
}

/// A release crediting a scener.
nonisolated struct CSDbCredit: Codable, Equatable, Sendable {
    let id: Int
    let name: String
    let kind: String
    var year: Int?
    var month: Int?
    var day: Int?
    var imageURL: URL?

    var url: URL { URL(string: "https://csdb.dk/release/?id=\(id)")! }

    /// For picking the newest; missing parts count as earliest.
    fileprivate var order: Int { (year ?? 0) * 10000 + (month ?? 0) * 100 + (day ?? 0) }

    /// Days since release, when CSDb has the full date.
    var daysOld: Int? {
        guard let year, let month, let day else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day
    }

    /// "Nov 5, 2026", "Nov 2026" or "2026": as much as CSDb knows.
    var dateText: String? {
        guard let year else { return nil }
        guard let month, (1...12).contains(month) else { return String(year) }
        let name = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][month - 1]
        return day.map { "\(name) \($0), \(year)" } ?? "\(name) \(year)"
    }
}

/// A place in a compo.
nonisolated struct CSDbResult: Codable, Equatable, Sendable {
    let place: Int
    let compo: String
    let title: String
    let event: String?
    let year: Int?

    /// "1st", "2nd", "3rd".
    var placeText: String {
        switch place {
        case 1: "1st"
        case 2: "2nd"
        case 3: "3rd"
        default: "\(place)th"
        }
    }
}

/// How a composer's CSDb lookup stands.
enum CSDbLookup: Equatable {
    case loading
    case found(CSDbProfile)
    /// CSDb has no single scener of that name.
    case none
}

/// Reading CSDb's scener search and webservice; pure, so they can be tested
/// without the network.
nonisolated enum CSDbScener {
    /// The sceners CSDb's search lists, as (handle id, shown name).
    static func searchMatches(in html: String) -> [(id: Int, name: String)] {
        guard let heading = html.range(of: #"<b>\d+ sceners?</b>"#, options: .regularExpression) else { return [] }
        let tail = html[heading.upperBound...]
        let block = tail.range(of: "</ol>").map { String(tail[..<$0.lowerBound]) } ?? String(tail)
        guard let link = try? NSRegularExpression(pattern: #"<a href="/scener/\?id=(\d+)">([^<]*)</a>"#) else { return [] }
        return link.matches(in: block, range: NSRange(block.startIndex..., in: block)).compactMap { found in
            guard let id = Range(found.range(at: 1), in: block).flatMap({ Int(block[$0]) }),
                  let name = Range(found.range(at: 2), in: block).map({ CSDbProfile.unescape(String(block[$0])) })
            else { return nil }
            return (id, name)
        }
    }

    /// The one handle id a search names, if exactly one scener goes by
    /// `names`: CSDb shows "Handle/Group", so the group is ignored.
    static func uniqueID(for names: [String], in matches: [(id: Int, name: String)]) -> Int? {
        let wanted = Set(names.flatMap(variants).map(normalize).filter { !$0.isEmpty })
        let ids = Set(matches.filter { match in
            let handle = match.name.split(separator: "/", maxSplits: 1).first.map(String.init) ?? match.name
            return wanted.contains(normalize(handle))
        }.map(\.id))
        return ids.count == 1 ? ids.first : nil
    }

    /// The ways CSDb might write a name: HVSC's "Hubbard, Rob" is "Rob
    /// Hubbard" there, and "Hülsbeck" is "Huelsbeck". Best guess first.
    static func variants(_ name: String) -> [String] {
        var flipped = name
        let parts = name.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { flipped = parts[1] + " " + parts[0] }
        var seen = Set<String>()
        return [flipped, transliterated(flipped), name, transliterated(name)].filter { seen.insert($0).inserted }
    }

    /// How CSDb spells German names without umlauts: "Hülsbeck" as
    /// "Huelsbeck".
    static func transliterated(_ name: String) -> String {
        [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("Ä", "Ae"), ("Ö", "Oe"), ("Ü", "Ue"), ("ß", "ss")]
            .reduce(name) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    /// Lowercase letters and digits only, accents folded: "Jeroen Tel" and
    /// "jeroen  tel" are the same name.
    static func normalize(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US"))
            .filter { $0.isLetter || $0.isNumber }
    }

    /// A handle from the webservice (`type=scener`, depth 2).
    static func profile(from data: Data) -> CSDbProfile? {
        let reader = HandleReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        guard let id = reader.id, let name = reader.name, !name.isEmpty else { return nil }

        // The handle asked for sits in its own list with only its id.
        var seen = Set<String>()
        let handles = ([CSDbHandle(name: name, inUse: reader.inUse)] + reader.otherHandles)
            .sorted { $0.inUse && !$1.inUse }
            .filter { seen.insert($0.name.lowercased()).inserted }
        // A release is written out once, wherever it first comes up, and
        // only by id after that.
        let latest = reader.credited.union(reader.released)
            .compactMap { reader.releases[$0] }
            // Not "C64 Music Collection": those credit everyone they rip.
            .filter { $0.kind == "C64 Music" }
            .max { ($0.order, $0.id) < ($1.order, $1.id) }
        // Their own music only: other people's demos credit them too, for
        // a tune they used.
        let results = reader.credited.union(reader.released)
            .compactMap { id -> (CSDbResult, Int)? in
                guard let release = reader.releases[id], release.kind == "C64 Music",
                      let achievement = reader.achievements[id], achievement.place <= 3 else { return nil }
                let event = achievement.event.flatMap { reader.events[$0] }
                return (CSDbResult(place: achievement.place, compo: achievement.compo, title: release.name,
                                   event: event.map(CSDbProfile.unescape), year: release.year), release.order)
            }
            .sorted { ($0.0.place, -$0.1) < ($1.0.place, -$1.1) }
            .map(\.0)
        return CSDbProfile(id: id, name: name, aka: reader.aka, country: reader.country,
                           roles: reader.roles, trivia: reader.trivia, handles: handles,
                           groups: reader.groups, formerGroups: reader.formerGroups,
                           groupFormed: reader.formed.count == 1 ? reader.formed[0] : nil,
                           latestMusic: latest, results: Array(results.prefix(5)))
    }

    private final class HandleReader: NSObject, XMLParserDelegate {
        var id: Int?
        var name: String?
        var aka: String?
        var country: String?
        var trivia: String?
        var inUse = false
        var roles: [String] = []
        var otherHandles: [CSDbHandle] = []
        var groups: [String] = []
        var formerGroups: [String] = []
        var releases: [Int: CSDbCredit] = [:]
        /// Music credits, by release id.
        var credited = Set<Int>()
        var released = Set<Int>()
        /// When each current group formed, for those CSDb knows.
        var formed: [String] = []
        var achievements: [Int: (place: Int, compo: String, event: Int?)] = [:]
        var events: [Int: String] = [:]

        private struct Frame {
            var id: Int?
            var name: String?
            var kind: String?
            var year: Int?
            var month: Int?
            var day: Int?
            var image: URL?
            var event: Int?
            var compo: String?
            var place: Int?
        }

        private var path: [String] = []
        private var text = ""
        private var frames: [Frame] = []
        private var otherName: String?
        private var otherInUse = false
        private var groupName: String?
        private var groupEnded = false
        private var groupShort: String?
        private var groupFoundYear: Int?
        private var groupFoundMonth: Int?
        private var currentEvent: Int?
        private var creditType: String?
        private var creditRelease: Int?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            path.append(name)
            text = ""
            if name == "Release" { frames.append(Frame()) }
            switch relative {
            case "Scener/Handles/Handle": otherName = nil; otherInUse = false
            case "MemberOf":
                groupName = nil
                groupEnded = false
                groupShort = nil
                groupFoundYear = nil
                groupFoundMonth = nil
            case "Credits/Credit": creditType = nil; creditRelease = nil
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            defer {
                path.removeLast()
                text = ""
            }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            readRelease(elementName, value)
            guard path.count >= 3, path[0] == "CSDbData", path[1] == "Handle" else { return }
            switch relative {
            case "ID": id = Int(value)
            case "Handle": if !value.isEmpty { name = value }
            case "AKA": if !value.isEmpty { aka = value }
            case "CurrentlyUsedHandle": inUse = value == "true"
            case "Scener/Country": if !value.isEmpty { country = value }
            case "Scener/Trivia": if !value.isEmpty { trivia = value }
            case "FreelanceFunctions/Function": if !value.isEmpty { roles.append(value) }
            case "Scener/Handles/Handle/Handle": otherName = value
            case "Scener/Handles/Handle/CurrentlyUsedHandle": otherInUse = value == "true"
            case "Scener/Handles/Handle":
                if let otherName, !otherName.isEmpty { otherHandles.append(CSDbHandle(name: otherName, inUse: otherInUse)) }
            case "MemberOf/Group/Name": groupName = value
            case "MemberOf/Status": if value != "active" { groupEnded = true }
            case "MemberOf/LeaveYear": groupEnded = true
            case "MemberOf/Group/Short": groupShort = value
            case "MemberOf/Group/FoundYear": groupFoundYear = Int(value)
            case "MemberOf/Group/FoundMonth": groupFoundMonth = Int(value)
            case "MemberOf":
                if let groupName, !groupName.isEmpty {
                    if groupEnded {
                        if !formerGroups.contains(groupName) { formerGroups.append(groupName) }
                    } else {
                        let label = groupShort.map { $0.isEmpty ? groupName : "\(groupName) (\($0))" } ?? groupName
                        if !groups.contains(label) {
                            groups.append(label)
                            if let founded { formed.append(founded) }
                        }
                    }
                }
            case "Credits/Credit/CreditType": creditType = value
            case "Credits/Credit":
                if creditType == "Music", let creditRelease { credited.insert(creditRelease) }
            default: break
            }
        }

        /// "August 1985", or "1985" without a month.
        private var founded: String? {
            guard let groupFoundYear else { return nil }
            guard let groupFoundMonth, (1...12).contains(groupFoundMonth) else { return String(groupFoundYear) }
            let months = ["January", "February", "March", "April", "May", "June", "July",
                          "August", "September", "October", "November", "December"]
            return "\(months[groupFoundMonth - 1]) \(groupFoundYear)"
        }

        /// A release's own fields, wherever in the document it comes up.
        private func readRelease(_ element: String, _ value: String) {
            // An event is written out once too, and only by id after that.
            if path.count >= 2, path[path.count - 2] == "Event" {
                if element == "ID", let id = Int(value) {
                    currentEvent = id
                    if !frames.isEmpty { frames[frames.count - 1].event = id }
                } else if element == "Name", let currentEvent {
                    events[currentEvent] = value
                }
                return
            }
            if path.count >= 3, path[path.count - 2] == "Achievement", path[path.count - 3] == "Release", !frames.isEmpty {
                if element == "Compo" { frames[frames.count - 1].compo = value }
                if element == "Place" { frames[frames.count - 1].place = Int(value) }
                return
            }
            if element == "Release" {
                guard let frame = frames.popLast(), let id = frame.id else { return }
                if let place = frame.place, let compo = frame.compo, achievements[id] == nil {
                    achievements[id] = (place, compo, frame.event)
                }
                if let name = frame.name, let kind = frame.kind, releases[id] == nil {
                    releases[id] = CSDbCredit(id: id, name: CSDbProfile.unescape(name), kind: kind, year: frame.year,
                                              month: frame.month, day: frame.day, imageURL: frame.image)
                }
                switch relative {
                case "Credits/Credit/Release": creditRelease = id
                case "Released/Release": released.insert(id)
                default: break
                }
            } else if path.count >= 2, path[path.count - 2] == "Release", !frames.isEmpty {
                let last = frames.count - 1
                switch element {
                case "ID": frames[last].id = Int(value)
                case "Name": frames[last].name = value
                case "Type": frames[last].kind = value
                case "ReleaseYear": frames[last].year = Int(value)
                case "ReleaseMonth": frames[last].month = Int(value)
                case "ReleaseDay": frames[last].day = Int(value)
                case "ScreenShot": frames[last].image = URL(string: value)
                default: break
                }
            }
        }

        /// Where the parser is, below the handle asked for.
        private var relative: String {
            guard path.count >= 3, path[0] == "CSDbData", path[1] == "Handle" else { return "" }
            return path.dropFirst(2).joined(separator: "/")
        }
    }
}

extension CSDbStore {
    /// How long a lookup is kept: a found scener for two weeks, a miss for
    /// three days, since CSDb's sceners come and go.
    private static let foundLifetime: TimeInterval = 14 * 86400
    private static let missLifetime: TimeInterval = 3 * 86400

    /// The lookup for a composer, as it stands.
    func lookup(for names: [String]) -> CSDbLookup? {
        names.first.flatMap { profiles[CSDbScener.normalize($0)] }
    }

    /// Finds a composer on CSDb: their cached lookup when it's fresh, else
    /// a search and one webservice call (depth 2, for groups and releases). `names` are what they go by
    /// (first the HVSC name, then a real name).
    func loadProfile(for names: [String]) async {
        let names = names.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard isEnabled, let first = names.first else { return }
        let key = CSDbScener.normalize(first)
        guard !key.isEmpty, profiles[key] == nil else { return }

        var saved = Self.readSaved()
        if let entry = saved[key] {
            let age = Date().timeIntervalSince(entry.fetched)
            if age < (entry.profile == nil ? Self.missLifetime : Self.foundLifetime) {
                profiles[key] = entry.profile.map(CSDbLookup.found) ?? CSDbLookup.none
                return
            }
        }
        profiles[key] = .loading
        do {
            let profile = try await fetchProfile(names)
            profiles[key] = profile.map(CSDbLookup.found) ?? CSDbLookup.none
            saved[key] = SavedProfile(fetched: Date(), profile: profile)
            Self.write(saved)
        } catch {
            // Offline: show nothing now, and ask again next time.
            profiles[key] = nil
            if let old = saved[key]?.profile { profiles[key] = .found(old) }
        }
    }

    private func fetchProfile(_ names: [String]) async throws -> CSDbProfile? {
        // As written, then without umlauts, which is how CSDb spells them.
        var id: Int?
        for term in CSDbScener.variants(names[0]).prefix(2) {
            var search = URLComponents(string: "https://csdb.dk/search/")!
            search.queryItems = [.init(name: "seinsel", value: "all"), .init(name: "search", value: term)]
            let (page, _) = try await session.data(from: search.url!)
            let html = String(data: page, encoding: .utf8) ?? String(data: page, encoding: .isoLatin1) ?? ""
            id = CSDbScener.uniqueID(for: names, in: CSDbScener.searchMatches(in: html))
            if id != nil { break }
        }
        guard let id else { return nil }
        let (xml, response) = try await session.data(from: URL(string: "https://csdb.dk/webservice/?type=scener&id=\(id)&depth=2")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        // Up to a couple of MB for a prolific scener: off the main thread.
        return await Task.detached { CSDbScener.profile(from: xml) }.value
    }

    // ── On disk ──

    struct SavedProfile: Codable {
        let fetched: Date
        let profile: CSDbProfile?
    }

    private static var savedFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CSDb", isDirectory: true)
            .appendingPathComponent("profiles-3.json")
    }

    private static func readSaved() -> [String: SavedProfile] {
        (try? Data(contentsOf: savedFile)).flatMap { try? JSONDecoder().decode([String: SavedProfile].self, from: $0) } ?? [:]
    }

    private static func write(_ saved: [String: SavedProfile]) {
        try? FileManager.default.createDirectory(at: savedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: savedFile, options: .atomic) }
    }
}

#endif
