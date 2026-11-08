import Foundation
import PhosphorCore

/// What a section of Games or Demos is called, and what HVSC files there.
nonisolated struct SectionIdentity: Equatable, Sendable {
    /// The folder's name: "A-F", "UNKNOWN", "Commodore".
    let name: String
    let category: HvscCategory

    /// A letter range, which only says something next to the category.
    private var isRange: Bool {
        let ends = name.split(separator: "-")
        return ends.count == 2 && ends.allSatisfy { $0.count == 1 }
    }

    private var isUnknown: Bool { name.caseInsensitiveCompare("unknown") == .orderedSame }

    private var tunesAreFrom: String { category == .demos ? String(localized: "demos") : String(localized: "games") }

    /// "Games A-F", "Unknown Composers", "Commodore".
    var title: String {
        if isRange { return category == .demos ? String(localized: "Demos \(name)") : String(localized: "Games \(name)") }
        return isUnknown ? String(localized: "Unknown Composers") : name
    }

    /// What its tunes are, when the title doesn't say.
    var kind: String? {
        isRange ? nil : (category == .demos ? "demo" : "game")
    }

    /// What goes on its tile: it has no photo to show.
    var tile: String { isUnknown ? "?" : name }

    /// What's in it, from HVSC's own account of these folders (HVSC.txt):
    /// composers get a folder from three tunes up, and the rest of the music
    /// from games and demos is filed here.
    var description: String? {
        if isRange {
            let ends = name.split(separator: "-")
            let composers = String(localized: "by composers with fewer than three tunes in HVSC")
            return String(localized: "Music from \(tunesAreFrom), filed \(ends[0]) to \(ends[1]) by title, ")
                + (category == .demos ? "\(composers)." : String(localized: "\(composers), or none known."))
        }
        if isUnknown { return String(localized: "Music from \(tunesAreFrom) whose composers aren't known.") }
        if category == .demos, name == "Commodore" {
            return String(localized: "Mostly music from the C64's manuals and the test disks that came with its drives.")
        }
        return nil
    }
}

/// What can be said about a section from its tunes alone. There's no one to
/// look up: the composers here have a tune or two each, or aren't known.
nonisolated struct SectionFacts: Equatable, Sendable {
    nonisolated struct YearCount: Equatable, Sendable {
        let year: Int
        let tunes: Int
    }

    nonisolated struct Releaser: Equatable, Sendable {
        let name: String
        let tunes: Int
    }

    /// Tunes per year from the first to the last, quiet years included.
    let years: [YearCount]
    /// How many tunes have no exact year ("198?").
    let undated: Int
    /// The tunes' lengths added up, where they're known.
    let playingSeconds: Int
    /// How many tunes have a note in HVSC's STIL.
    let notedTunes: Int
    let longest: [LibraryRow]
    let oldest: [LibraryRow]
    /// Never the ones `oldest` has: a small section would list them twice.
    let newest: [LibraryRow]
    /// Who released the most, from two tunes up: one each says nothing.
    let releasers: [Releaser]

    init(rows: [LibraryRow], listLength: Int = 5) {
        let dated = rows.compactMap { row -> (year: Int, row: LibraryRow)? in
            // A typo in a SID's header must not make a chart of centuries.
            guard let year = Int(row.year), (1970...2100).contains(year) else { return nil }
            return (year, row)
        }
        let perYear = Dictionary(grouping: dated, by: \.year).mapValues(\.count)
        if let first = perYear.keys.min(), let last = perYear.keys.max() {
            years = (first...last).map { YearCount(year: $0, tunes: perYear[$0] ?? 0) }
        } else {
            years = []
        }
        undated = rows.count - dated.count
        playingSeconds = rows.reduce(0) { $0 + Int($1.item.durationSecs ?? 0) }
        notedTunes = rows.count { $0.item.hasStil }

        longest = Array(rows.filter { $0.item.durationSecs != nil }
            .sorted { ($1.length, $0.title) < ($0.length, $1.title) }
            .prefix(listLength))

        let oldestFirst = dated.sorted { ($0.year, $0.row.title) < ($1.year, $1.row.title) }
        let oldest = oldestFirst.prefix(listLength).map(\.row)
        self.oldest = oldest
        let listed = Set(oldest.map(\.id))
        newest = Array(dated.sorted { ($1.year, $0.row.title) < ($0.year, $1.row.title) }
            .map(\.row)
            .filter { !listed.contains($0.id) }
            .prefix(listLength))

        let perReleaser = Dictionary(grouping: rows.compactMap(\.releaser), by: { $0 }).mapValues(\.count)
        releasers = Array(perReleaser
            .filter { $0.value >= 2 }
            .map { Releaser(name: $0.key, tunes: $0.value) }
            .sorted { ($1.tunes, $0.name) < ($0.tunes, $1.name) }
            .prefix(listLength))
    }

    /// The busiest year; the earliest of them on a tie.
    var busiest: YearCount? {
        years.reduce(nil) { best, year in
            year.tunes > (best?.tunes ?? 0) ? year : best
        }
    }

    /// "About 10 hours".
    var playingTime: String? {
        guard playingSeconds > 0 else { return nil }
        let minutes = (Double(playingSeconds) / 60).rounded()
        if minutes < 1 { return String(localized: "Under a minute") }
        if minutes == 1 { return String(localized: "About a minute") }
        if minutes < 60 { return String(localized: "About \(Int(minutes)) minutes") }
        let hours = (Double(playingSeconds) / 3600).rounded()
        return hours == 1 ? String(localized: "About an hour") : String(localized: "About \(Int(hours).formatted()) hours")
    }

    /// "On 247 tunes".
    var notes: String? {
        guard notedTunes > 0 else { return nil }
        return notedTunes == 1 ? String(localized: "On 1 tune") : String(localized: "On \(notedTunes.formatted()) tunes")
    }

    /// "62 tunes".
    var withoutExactYear: String? {
        guard undated > 0 else { return nil }
        return undated == 1 ? String(localized: "1 tune") : String(localized: "\(undated.formatted()) tunes")
    }

    /// "Most in 1984: 90 tunes".
    var busiestText: String? {
        busiest.map { String(localized: "Most in \(String($0.year)): \(Self.tunes($0.tunes))") }
    }

    static func tunes(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "no tunes")
        case 1: String(localized: "1 tune")
        default: String(localized: "\(count.formatted()) tunes")
        }
    }
}

// MARK: - Sound

/// How common a sound is in a section, and across the collection.
nonisolated struct SoundShare: Equatable, Sendable {
    let tag: SoundTag
    /// The share of the section's fingerprinted tunes that have it, 0–1.
    let share: Double
    /// The same across the collection, when it's known.
    let overall: Double?
}

nonisolated extension SectionFacts {
    /// The sounds most common among `tags`, one list per fingerprinted tune.
    static func soundShares(tags: [[SoundTag]], overall: [SoundTag: Double], limit: Int = 5) -> [SoundShare] {
        guard !tags.isEmpty else { return [] }
        let shares = SoundTag.all.map { tag in
            SoundShare(tag: tag, share: Double(tags.count { $0.contains(tag) }) / Double(tags.count), overall: overall[tag])
        }
        return Array(shares.enumerated()
            .filter { $0.element.share > 0 }
            .sorted { ($1.element.share, $0.offset) < ($0.element.share, $1.offset) }
            .prefix(limit)
            .map(\.element))
    }
}

// MARK: - Releases

nonisolated extension LibraryRow {
    /// Who released it, from "1987 Ocean" or "198? Firebird <?>"; nil when
    /// HVSC doesn't know.
    var releaser: String? {
        let parts = released.split(separator: " ", maxSplits: 1)
        guard let first = parts.first else { return nil }
        let rest = first.first?.isNumber == true ? parts.dropFirst().first.map(String.init) ?? "" : released
        let name = rest.replacingOccurrences(of: "<?>", with: "").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
