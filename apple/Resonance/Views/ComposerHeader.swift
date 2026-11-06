import AppKit
import PhosphorCore
import STILKit
import SwiftUI

// What's above a composer's tunes: their picture, name and play controls, what
// HVSC and CSDb say about them, and a carousel of everything else.

// MARK: - Facts

nonisolated enum ComposerFacts {
    /// "176 tunes from 1986 to 2020", or "28 demo tunes": as much as is known.
    static func tunes(_ count: Int, kind: String? = nil, firstYear: Int?, lastYear: Int?) -> String {
        let noun = kind.map { "\($0) tune" } ?? "tune"
        let tunes = count == 1 ? "1 \(noun)" : "\(count.formatted()) \(noun)s"
        guard let firstYear, let lastYear else { return tunes }
        return firstYear == lastYear ? "\(tunes) from \(firstYear)" : "\(tunes) from \(firstYear) to \(lastYear)"
    }

    /// "Maniacs of Noise (MON), formed 1987". CSDb only says when a group
    /// formed for someone in just the one.
    static func groups(_ groups: [String], formed: String?) -> String? {
        guard !groups.isEmpty else { return nil }
        let names = groups.joined(separator: ", ")
        guard groups.count == 1, let formed else { return names }
        return "\(names), formed \(formed)"
    }

    /// A real name, unless it only repeats what they're shown as.
    static func realName(_ realName: String?, shownAs name: String) -> String? {
        guard let realName else { return nil }
        return Set(LibraryStore.nameWords(realName)) == Set(LibraryStore.nameWords(name)) ? nil : realName
    }
}

/// The carousel's cards for a composer.
nonisolated enum ComposerInfoCard: Hashable {
    case similar
    case note
    case newest
    case results
    case trivia
}

// MARK: - The header

/// A composer's header: their picture, what HVSC and CSDb know about them, and
/// cards for the rest. Nothing CSDb says, or says late, can move the tunes below.
///
/// Cards HVSC and the fingerprints can fill come first and CSDb's after them,
/// so what arrives late only adds pages to the right of where you are.
///
/// CSDb's trivia is only a card if switched on in Settings, and says it's
/// unverified: its users write it unreviewed, accusations about named people
/// included, and it mustn't read as ours.
struct ComposerHeader: View {
    /// Their MUSICIANS folder.
    let authorPath: String
    /// HVSC's name for them, which CSDb is looked up by: "Galway, Martin".
    let name: String
    let rows: [LibraryRow]
    let source: PlaybackSource
    /// Opens another composer (Sounds similar).
    let openComposer: (String) -> Void

    @Environment(LibraryStore.self) private var library
    @Environment(CSDbStore.self) private var csdb
    @Environment(\.openURL) private var openURL
    @AppStorage(Pref.csdbEnabled) private var csdbEnabled = true
    @AppStorage(Pref.csdbTrivia) private var showsTrivia = false
    @AppStorage(Pref.composerPhotos) private var showsPhotos = false

    /// With CSDb switched off there may be nothing to say beyond the name.
    private var hasBio: Bool { csdbEnabled || realName != nil }

    /// "Galway, Martin" stays in the sorted list; here it's "Martin Galway".
    private var shownName: String { LibraryStore.spokenName(name) }

    private var summary: HvscComposer? { library.composers[.musicians]?[authorPath] }

    private var realName: String? { ComposerFacts.realName(summary?.realName, shownAs: shownName) }

    private var tuneCount: String {
        ComposerFacts.tunes(rows.count, firstYear: summary?.firstYear.map(Int.init), lastYear: summary?.lastYear.map(Int.init))
    }

    /// What CSDb might know them by: the HVSC name, then a real name.
    private var lookupNames: [String] { [name] + [summary?.realName].compactMap { $0 } }

    private var profile: CSDbProfile? {
        if csdbEnabled, case .found(let profile) = csdb.lookup(for: [name]) { profile } else { nil }
    }

    private var isLookingUp: Bool { csdbEnabled && csdb.lookup(for: [name]) == .loading }

    private var note: STILEntry? { library.stil[authorPath] ?? nil }

    private var similar: [SimilarComposer] { library.similarComposers[authorPath] ?? [] }

    private var photo: WikimediaPhoto? {
        csdbEnabled && showsPhotos ? csdb.composerPhotos[shownName] : nil
    }

    private var cards: [ComposerInfoCard] {
        var cards: [ComposerInfoCard] = []
        if !similar.isEmpty { cards.append(.similar) }
        if note != nil { cards.append(.note) }
        if profile?.latestMusic != nil { cards.append(.newest) }
        if !(profile?.results ?? []).isEmpty { cards.append(.results) }
        if showsTrivia, profile?.triviaText() != nil { cards.append(.trivia) }
        return cards
    }

    var body: some View {
        LargeHeader(title: shownName, detail: tuneCount, rows: rows, source: source,
                    hasBio: hasBio, expectsCards: isLookingUp, cards: cards) {
            ComposerPortrait(name: shownName, realName: summary?.realName)
        } bio: {
            bio
        } card: { card in
            self.card(card)
        }
        .task(id: authorPath) { await library.loadSimilarComposers(authorPath) }
        .task(id: authorPath) { await library.loadStil(path: authorPath) }
        .task(id: "\(csdbEnabled) \(lookupNames)") { await csdb.loadProfile(for: lookupNames) }
        // Whose tune their newest credit is, and whether it's in HVSC, before
        // anyone presses Play.
        .task(id: profile?.latestMusic?.id) {
            if let id = profile?.latestMusic?.id { try? await csdb.files(ofRelease: id) }
        }
    }

    // MARK: The bio

    private var bio: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLookingUp {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Looking up on CSDb…")
                        .foregroundStyle(.secondary)
                }
            }
            if realName != nil || profile != nil {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    headerFact("Real name", realName)
                    headerFact("Country", profile?.country)
                    headerFact("Also known as", profile?.aka)
                    headerFact(profile?.groups.count == 1 ? "Group" : "Groups",
                               profile.flatMap { ComposerFacts.groups($0.groups, formed: $0.groupFormed) })
                    headerFact("Formerly", profile.flatMap(former))
                }
            }
            if let profile {
                // The name in use, then the others they've gone by, then what
                // they do. One name needs no chip: it's under the picture.
                let handles = profile.handles.count > 1 ? profile.handles : []
                if !handles.isEmpty || !profile.roles.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(handles, id: \.name) { handle in
                            SceneChip(text: handle.name, highlighted: handle.inUse)
                        }
                        ForEach(profile.roles, id: \.self) { SceneChip(text: $0) }
                    }
                }
                AccentLink("Open Scener on CSDb") { openURL(profile.url) }
                    .font(.caption.weight(.semibold))
            } else if csdbEnabled, !isLookingUp, csdb.lookup(for: [name]) != nil {
                Text("CSDb doesn't list one scener by this name.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = csdbSearch {
                    AccentLink("Search CSDb") { openURL(url) }
                        .font(.caption.weight(.semibold))
                }
            }
            if let photo {
                AccentLink("Photo: \(photo.credit)") { openURL(photo.page) }
                    .font(.caption)
                    .lineLimit(2)
                    .help("Open the photo's page on Wikimedia Commons")
            }
        }
        .font(.callout)
    }

    private func former(_ profile: CSDbProfile) -> String? {
        guard !profile.formerGroups.isEmpty else { return nil }
        let shown = profile.formerGroups.prefix(3).joined(separator: ", ")
        let more = profile.formerGroups.count - 3
        return more > 0 ? "\(shown) and \(more) more" : shown
    }

    private var csdbSearch: URL? {
        var search = URLComponents(string: "https://csdb.dk/search/")
        search?.queryItems = [.init(name: "seinsel", value: "all"), .init(name: "search", value: shownName)]
        return search?.url
    }

    // MARK: The cards

    @ViewBuilder
    private func card(_ card: ComposerInfoCard) -> some View {
        switch card {
        case .similar:
            HeaderCard("Sounds Similar") {
                ScrollView(.vertical) {
                    SimilarComposers(authorPath: authorPath, openComposer: openComposer)
                }
                .font(.callout)
            }
        case .note:
            HeaderCard("HVSC Note") {
                ScrollView(.vertical) {
                    if let note {
                        StilCommentsView(entry: note)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(authorPath)
                    }
                }
                .font(.callout)
            }
        case .newest:
            if let profile, let release = profile.latestMusic {
                newestCard(release, by: profile)
            }
        case .results:
            HeaderCard("Compo Results") {
                ScrollView(.vertical) {
                    resultsContent
                }
                .font(.callout)
            }
        case .trivia:
            HeaderCard("Unverified Trivia") {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Written by CSDb's users")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        if let trivia = profile?.triviaText(limit: 800) {
                            Text(trivia)
                                .foregroundStyle(.secondary)
                                .tint(.accentColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        }
    }

    /// "Just released" only while it is: an old credit is just their newest.
    private func newestCard(_ release: CSDbCredit, by profile: CSDbProfile) -> some View {
        let age = release.daysOld
        return HeaderCard(age.map { $0 <= 30 } == true ? "Just Released" : "Newest Music Credit",
                         badge: age == 0 ? "New today" : (age ?? .max) <= 30 ? "New" : nil) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        SceneCover(url: release.imageURL, seed: release.name, size: 48, radius: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(release.name)
                                .fontWeight(.semibold)
                                .lineLimit(2)
                            Text(creditLine(release))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    newestActions(release, by: profile)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
        }
    }

    /// "By Inge H. Pedersen, released 17 Sep 2011". Whose tune it is, when
    /// CSDb says: a credit can be for the original of someone else's remix.
    private func creditLine(_ release: CSDbCredit) -> String {
        let author = csdb.releaseFiles[release.id]?.hvscAuthor
        switch (author, release.dateText) {
        case (let author?, let date?): return "By \(author), released \(date)"
        case (let author?, nil): return "By \(author)"
        case (nil, let date?): return "Released \(date)"
        case (nil, nil): return release.kind
        }
    }

    /// Play, as long as there's reason to think it can.
    private func newestActions(_ release: CSDbCredit, by profile: CSDbProfile) -> some View {
        let player = CSDbPlayer(id: release.id, title: release.name, author: profile.name, url: release.url,
                                csdb: csdb, library: library, openURL: openURL)
        return FlowLayout(spacing: 10) {
            if player.state == .unavailable {
                Text("No SID on CSDb")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(action: player.activate) {
                    if player.state == .loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Play")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(player.state == .loading)
            }
            if csdb.hvscTune(ofRelease: release.id, library: library) != nil,
               let path = csdb.releaseFiles[release.id]?.hvscPath {
                AccentLink("Show in HVSC") { library.reveal(hvscPath: path) }
                    .font(.caption.weight(.semibold))
            }
            AccentLink("Open on CSDb") { openURL(release.url) }
                .font(.caption.weight(.semibold))
        }
    }

    private var resultsContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Crediting, not by: CSDb credits a remix's original composer too.
            Text("Crediting \(shownName)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            ForEach(Array((profile?.results ?? []).enumerated()), id: \.offset) { _, result in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(result.placeText)
                        .fontWeight(.semibold)
                        .frame(width: 30, alignment: .leading)
                    Text(resultText(result))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Tune Name, C64 Music at X-2024".
    private func resultText(_ result: CSDbResult) -> String {
        var text = "\(result.title), \(result.compo)"
        if let event = result.event {
            text += " at \(event)"
        } else if let year = result.year {
            text += " (\(year))"
        }
        return text
    }
}

// MARK: - Parts

/// The composers who sound most like one, with how much.
struct SimilarComposers: View {
    let authorPath: String
    let openComposer: (String) -> Void

    @Environment(LibraryStore.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(library.similarComposers[authorPath] ?? [], id: \.path) { other in
                HStack {
                    AccentLink(displayName(other.path)) { openComposer(other.path) }
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Double(max(other.score, 0)), format: .percent.precision(.fractionLength(0)))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func displayName(_ path: String) -> String {
        let listed = library.authors[.musicians]?.first { $0.path == path }?.displayName
        return LibraryStore.spokenName(listed ?? URL(filePath: path).lastPathComponent)
    }
}

/// A composer's picture, the same wherever they appear: their photo when
/// there is one, else a colour field from their name. It fills the frame it's
/// given.
struct ComposerPortrait: View {
    /// As it's spoken: "Martin Galway". Photos are found and kept by it.
    let name: String
    /// Another name a photo could be found under.
    var realName: String?
    /// Off where it may only show a photo already here: a search shouldn't
    /// go looking for one per result.
    var looksUpPhoto = true
    var cornerRadius: CGFloat = 12

    @AppStorage(Pref.csdbEnabled) private var csdbEnabled = true
    @AppStorage(Pref.composerPhotos) private var showsPhotos = false
    @Environment(CSDbStore.self) private var csdb

    private var photo: WikimediaPhoto? {
        csdbEnabled && showsPhotos ? csdb.composerPhotos[name] : nil
    }

    var body: some View {
        let seed = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
        let hue = Double(seed) / 360
        let first = Color(hue: hue, saturation: 0.75, brightness: 0.9)
        let second = Color(hue: (hue + 0.42).truncatingRemainder(dividingBy: 1), saturation: 0.72, brightness: 1)
        ZStack {
            Color(red: 0.11, green: 0.16, blue: 0.25)
            GeometryReader { proxy in
                let size = proxy.size
                let reach = max(size.width, size.height)
                ZStack {
                    RadialGradient(colors: [first, .clear], center: UnitPoint(x: 0.3, y: 0.25),
                                   startRadius: 0, endRadius: reach * 0.55)
                    RadialGradient(colors: [second, .clear], center: UnitPoint(x: 0.75, y: 0.72),
                                   startRadius: 0, endRadius: reach * 0.6)
                }
                if let photo {
                    // Faces sit high in portraits.
                    Image(nsImage: photo.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .clipped()
                }
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
        .help(photo.map { "Photo: \($0.credit)" } ?? "")
        .accessibilityHidden(true)
        .task(id: "\(csdbEnabled) \(showsPhotos) \(name)") {
            guard looksUpPhoto else { return }
            await csdb.loadPhoto(names: [name] + [realName].compactMap { $0 })
        }
    }
}

struct SceneChip: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .background(.fill.tertiary, in: .capsule)
            .overlay {
                if highlighted {
                    Capsule().strokeBorder(.tint)
                }
            }
    }
}
