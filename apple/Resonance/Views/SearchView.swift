import AppKit
import PhosphorCore
import SwiftUI

/// What search puts first: an exact composer name, the best composer match,
/// then the best tune. It's a guess at what was meant, so the page always
/// shows it beside the tunes.
nonisolated enum SearchTopResult: Equatable {
    case composer(HvscAuthorItem)
    case tune(LibraryRow)

    /// `composers` and `tunes` are best match first.
    static func pick(query: String, composers: [HvscAuthorItem], tunes: [LibraryRow]) -> SearchTopResult? {
        let typed = Set(LibraryStore.nameWords(query))
        let exact = composers.first {
            Set(LibraryStore.nameWords($0.displayName)) == typed || Set(LibraryStore.nameWords($0.name)) == typed
        }
        if let composer = exact ?? composers.first { return .composer(composer) }
        return tunes.first.map(SearchTopResult.tune)
    }
}

/// Search's own place in the window, the same from every section: all of
/// HVSC, with filters to narrow it, because a word can be a composer, a tune
/// or a game. Sections stay as they were underneath, and a composer opened
/// here keeps this page alive behind it, so Back finds it as it was.
struct SearchView: View {
    /// What's in the window's search field, trimmed.
    let query: String
    /// Goes up with each press of Return in the field.
    let submissions: Int

    private enum Filter: Hashable, CaseIterable {
        case all, tunes, composers, games, demos

        var title: String {
            switch self {
            case .all: "All"
            case .tunes: "Tunes"
            case .composers: "Composers"
            case .games: "Games"
            case .demos: "Demos"
            }
        }

        /// The part of HVSC whose tunes it shows on their own.
        var category: HvscCategory? {
            switch self {
            case .games: .games
            case .demos: .demos
            default: nil
            }
        }
    }

    private struct SearchRequest: Hashable {
        let query: String
        let category: HvscCategory?
    }

    /// What can be in your lists without being in HVSC.
#if CSDB
    private var downloads: Set<Int> { csdb.downloadedIDs }
    private var downloadedFiles: [String] { csdb.downloadedFiles() }
#else
    private var downloads: Set<Int> { [] }
    private var downloadedFiles: [String] { [] }
#endif

    private struct LocalFiles: Hashable {
        let playlist: [String]
        let downloads: Set<Int>
    }

    private struct ComposerRequest: Hashable {
        let query: String
        let authors: Int
        let summaries: Int
    }

    /// A row in the overview's Playlists: yours or a curated one.
    private struct PlaylistMatch: Identifiable {
        let id: SidebarItem
        let name: String
        let kind: String
    }

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var player
    @Environment(PlaylistsStore.self) private var playlists
#if CSDB
    @Environment(CSDbStore.self) private var csdb
#endif

    @State private var filter = Filter.all
    /// All of HVSC. The last results stay until new ones are in, so nothing
    /// flashes while typing.
    @State private var results: HvscSearchResult?
    @State private var tunes: [LibraryRow] = []
    /// Games or Demos searched on their own, so the cap on results doesn't
    /// leave them short; nil while that's under way.
    @State private var categoryTunes: [LibraryRow]?
    @State private var searchError: String?
    @State private var composers: [HvscAuthorItem] = []
    /// My Playlist's and Downloads' tunes from outside HVSC, which HVSC's
    /// search can't find.
    @State private var localTunes: [LibraryRow] = []
    /// The composer open over the results.
    @State private var opened: HvscAuthorItem?
    @State private var width: CGFloat = 700

    var body: some View {
        Group {
            if query.isEmpty {
                ContentUnavailableView {
                    Label("Search HVSC", systemImage: "magnifyingglass")
                } description: {
                    Text("Type in the search field at the top of the window to find tunes, composers, games and demos.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack {
                    VStack(spacing: 0) {
                        SmartSearchOffer(query: query)
                        resultsPage
                    }
                        .opacity(opened == nil ? 1 : 0)
                        .allowsHitTesting(opened == nil)
                        .accessibilityHidden(opened != nil)
                    if let opened {
                        composerPage(opened)
                    }
                }
            }
        }
        .task(id: SearchRequest(query: query, category: nil)) { await searchAll() }
        .task(id: SearchRequest(query: query, category: filter.category)) { await searchCategory() }
        .task(id: player.hvscTreeRevision) {
            await library.loadAuthors(.musicians)
            await library.loadComposers(.musicians)
        }
        .task(id: ComposerRequest(query: query, authors: library.authors[.musicians]?.count ?? 0,
                                  summaries: library.composers[.musicians]?.count ?? 0)) {
            composers = library.composers(matching: query, in: .musicians, limit: 500)
        }
        .task(id: LocalFiles(playlist: player.rows.map(\.id), downloads: downloads)) {
            let files = player.rows.map(\.id) + downloadedFiles
            let found = await playlists.tunes(from: Array(Set(files)))
            localTunes = found.filter { library.category(of: $0.id) == nil }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        // A new search starts over from its results.
        .onChange(of: query) {
            opened = nil
            if query.isEmpty { filter = .all }
        }
        .onChange(of: filter) { categoryTunes = nil }
        .onChange(of: submissions) { openTopResult() }
    }

    // MARK: Searching

    private func searchAll() async {
        guard !query.isEmpty, player.hasCollection else {
            results = nil
            tunes = []
            searchError = nil
            return
        }
        // Debounce: a newer keystroke cancels this task before it searches.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        do {
            let found = try await library.search(query, scope: nil)
            guard !Task.isCancelled else { return }
            results = found
            tunes = found.items.map(LibraryRow.init)
            searchError = nil
        } catch is CancellationError {
        } catch {
            searchError = LibraryStore.message(for: error)
        }
    }

    private func searchCategory() async {
        guard let category = filter.category, !query.isEmpty, player.hasCollection else { return }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        do {
            let found = try await library.search(query, scope: category)
            guard !Task.isCancelled else { return }
            categoryTunes = found.items.map(LibraryRow.init)
            searchError = nil
        } catch is CancellationError {
        } catch {
            searchError = LibraryStore.message(for: error)
        }
    }

    /// Return: opens the composer, or for a tune the full list it heads,
    /// rather than starting music out of the blue.
    private func openTopResult() {
        switch topResult {
        case .composer(let composer): opened = composer
        case .tune: filter = .tunes
        case nil: break
        }
    }

    private var topResult: SearchTopResult? {
        SearchTopResult.pick(query: query, composers: composers, tunes: allTunes)
    }

    private var localMatches: [LibraryRow] {
        localTunes.filter {
            $0.title.localizedStandardContains(query)
                || $0.author.localizedStandardContains(query)
                || $0.released.localizedStandardContains(query)
        }
    }

    /// HVSC's matches, then your own tunes.
    private var allTunes: [LibraryRow] { tunes + localMatches }

    private var matchingPlaylists: [PlaylistMatch] {
        let yours = playlists.playlists
            .filter { $0.name.localizedStandardContains(query) }
            .map { PlaylistMatch(id: .userPlaylist($0.id), name: $0.name, kind: "Your playlist") }
        let curated = (player.hvscInfo?.playlists ?? [])
            .filter { $0.name.localizedStandardContains(query) }
            .map { PlaylistMatch(id: .curated($0.file), name: $0.name, kind: "Curated playlist") }
        return yours + curated
    }

    private var isIndexing: Bool { !player.hvscIndexing.isEmpty }

    /// The first results aren't in yet, or the index they need is being built.
    private var isWaiting: Bool { player.hasCollection && (results == nil || isIndexing) }

    // MARK: The results

    private var resultsPage: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            // Filling the rest keeps the filters at the top: an empty
            // state's own height let the whole stack float to the middle.
            resultsBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            // Capsules, like Now Playing's large picker (only the large
            // size has them by default).
            .buttonBorderShape(.capsule)
            .fixedSize()
            if !isWaiting, searchError == nil, let summary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minWidth: 0, maxWidth: .infinity)
        .background(.bar)
    }

    private var summary: String? {
        switch filter {
        case .all:
            // The Tunes section says it.
            return nil
        case .tunes:
            guard let results, !results.items.isEmpty else { return nil }
            let total = results.totalMatches.formatted()
            let indexed = results.indexed.formatted()
            return results.totalMatches > UInt32(results.items.count)
                ? "Best \(results.items.count) of \(total) matches among \(indexed) tunes"
                : "\(total) matches among \(indexed) tunes"
        case .composers:
            return composers.isEmpty ? nil : Self.count(composers.count, "composer")
        case .games, .demos:
            return categoryTunes.flatMap { $0.isEmpty ? nil : Self.count($0.count, "tune") }
        }
    }

    private static func count(_ count: Int, _ noun: String) -> String {
        "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var resultsBody: some View {
        if let searchError {
            ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle", description: Text(searchError))
        } else if isWaiting {
            VStack(spacing: 10) {
                ProgressView()
                Text(isIndexing ? "Indexing \(indexingNames)…" : "Searching…")
                    .foregroundStyle(.secondary)
                if isIndexing {
                    Text("The first search builds an index of the collection; later ones are instant.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            switch filter {
            case .all:
                overview
            case .tunes:
                tuneTable(allTunes)
            case .composers:
                composerList
            case .games, .demos:
                if let categoryTunes {
                    tuneTable(categoryTunes)
                        .id(filter)
                } else {
                    ProgressView()
                }
            }
        }
    }

    private var indexingNames: String {
        player.hvscIndexing.map(\.displayName).formatted(.list(type: .and))
    }

    @ViewBuilder
    private func tuneTable(_ rows: [LibraryRow]) -> some View {
        if rows.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            LibraryTable(rows: rows, source: .search(query: query))
        }
    }

    @ViewBuilder
    private var composerList: some View {
        if composers.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(composers, id: \.path) { composer in
                        composerButton(composer)
                    }
                }
                .padding(12)
            }
        }
    }

    private func composerButton(_ composer: HvscAuthorItem) -> some View {
        Button {
            opened = composer
        } label: {
            ComposerRowLabel(author: composer, summary: library.composers[.musicians]?[composer.path])
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: The overview

    private static let shownTunes = 6
    private static let shownInSection = 4
    private static let shownComposers = 6

    @ViewBuilder
    private var overview: some View {
        let top = topResult
        let first = Array(allTunes.prefix(Self.shownTunes))
        let shown = Set(first.map(\.id))
        let others = composers.filter { top != .composer($0) }
        let games = tunes.filter { $0.item.category == .games && !shown.contains($0.id) }
        let demos = tunes.filter { $0.item.category == .demos && !shown.contains($0.id) }
        let local = localMatches.filter { !shown.contains($0.id) }
        let lists = matchingPlaylists

        if top == nil && lists.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let top {
                        topRow(top, first)
                    }
                    if !others.isEmpty {
                        SearchSection("Composers", seeAll: others.count > Self.shownComposers ? { filter = .composers } : nil) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 8) {
                                ForEach(others.prefix(Self.shownComposers), id: \.path) { composer in
                                    composerButton(composer)
                                        .modifier(CardBackground(radius: 10))
                                }
                            }
                        }
                    }
                    tuneSection("Games", games, from: tunes.filter { $0.item.category == .games }, showing: .games)
                    tuneSection("Demos", demos, from: tunes.filter { $0.item.category == .demos }, showing: .demos)
                    if !lists.isEmpty {
                        SearchSection("Playlists") {
                            VStack(spacing: 0) {
                                ForEach(lists) { playlistRow($0) }
                            }
                        }
                    }
                    if !local.isEmpty {
                        SearchSection("In Your Lists", sub: "My Playlist and Downloads") {
                            VStack(spacing: 0) {
                                ForEach(local.prefix(Self.shownInSection)) { row in
                                    SearchTuneRow(row: row) { play(row, in: local) }
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 1100, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onGeometryChange(for: CGFloat.self) { min($0.size.width, 1100) - 40 } action: { width = $0 }
        }
    }

    /// The top result and the first tunes side by side, or stacked when
    /// there's no room.
    @ViewBuilder
    private func topRow(_ top: SearchTopResult, _ first: [LibraryRow]) -> some View {
        let tunesSection = SearchSection(
            "Tunes",
            sub: Self.count(Int(results?.totalMatches ?? 0) + localMatches.count, "tune"),
            seeAll: allTunes.count > first.count ? { filter = .tunes } : nil
        ) {
            VStack(spacing: 0) {
                ForEach(first) { row in
                    SearchTuneRow(row: row) { play(row, in: allTunes) }
                }
            }
        }
        if width >= 620 {
            HStack(alignment: .top, spacing: 24) {
                topCard(top)
                    .frame(width: min(300, width * 0.38))
                if !first.isEmpty {
                    tunesSection
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        } else {
            topCard(top)
            if !first.isEmpty {
                tunesSection
            }
        }
    }

    private func topCard(_ top: SearchTopResult) -> some View {
        SearchSection("Top Result") {
            switch top {
            case .composer(let composer):
                let name = LibraryStore.spokenName(composer.displayName)
                TopResultButton(title: name, subtitle: composerFacts(composer)) {
                    opened = composer
                } art: {
                    // No lookups for a search: a photo only if it's here already.
                    ComposerPortrait(name: name, looksUpPhoto: false)
                        .frame(width: 72, height: 72)
                }
            case .tune(let row):
                TopResultButton(title: row.title, subtitle: "Tune by \(row.author), \(row.lengthText)") {
                    play(row, in: allTunes)
                } art: {
                    PlaylistArtwork(name: row.title, size: 72)
                }
            }
        }
    }

    private func composerFacts(_ composer: HvscAuthorItem) -> String {
        guard let tunes = library.composers[.musicians]?[composer.path]?.tunes else { return "Composer" }
        return "Composer, " + Self.count(Int(tunes), "tune")
    }

    @ViewBuilder
    private func tuneSection(_ title: String, _ rows: [LibraryRow], from all: [LibraryRow], showing target: Filter) -> some View {
        if !rows.isEmpty {
            SearchSection(title, seeAll: { filter = target }) {
                VStack(spacing: 0) {
                    ForEach(rows.prefix(Self.shownInSection)) { row in
                        SearchTuneRow(row: row) { play(row, in: all) }
                    }
                }
            }
        }
    }

    private func playlistRow(_ match: PlaylistMatch) -> some View {
        Button {
            library.shownSection = match.id
        } label: {
            HStack(spacing: 10) {
                PlaylistArtwork(name: match.name, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(match.name)
                        .lineLimit(1)
                    Text(match.kind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func play(_ row: LibraryRow, in rows: [LibraryRow]) {
        library.play(rows, startAt: row, from: .search(query: query))
    }

    // MARK: A composer

    private func composerPage(_ composer: HvscAuthorItem) -> some View {
        AuthorTunes(authorPath: composer.path, authorName: composer.displayName, category: .musicians) { other in
            opened = library.authors[.musicians]?.first { $0.path == other }
        }
        .id(composer.path)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                AccentLink("Back to Results") { opened = nil }
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minWidth: 0, maxWidth: .infinity)
            .background(.bar)
        }
    }
}

// MARK: - Parts

/// A titled part of the overview, like the Home's.
private struct SearchSection<Content: View>: View {
    let title: String
    var sub: String?
    var seeAll: (() -> Void)?
    @ViewBuilder let content: Content

    init(_ title: String, sub: String? = nil, seeAll: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.sub = sub
        self.seeAll = seeAll
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)
                if let sub {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let seeAll {
                    AccentLink("See All", action: seeAll)
                        .font(.caption.weight(.semibold))
                }
            }
            content
        }
    }
}

/// The top result: click to open a composer or play a tune.
private struct TopResultButton<Art: View>: View {
    let title: String
    let subtitle: String
    let action: () -> Void
    @ViewBuilder let art: Art

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                art
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .modifier(CardBackground(radius: 14, highlighted: hovering))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A tune in the overview, behaving as in any tune list: double-click plays,
/// and the context menu has the rest. Play shows on hover, for one click.
private struct SearchTuneRow: View {
    let row: LibraryRow
    let play: () -> Void

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var player
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            TuneTitleCell(library: library, path: row.id, title: row.title, author: row.author,
                          isCurrent: row.id == player.nowPlaying?.path, mayHaveStil: row.item.hasStil)
                .frame(maxWidth: .infinity, alignment: .leading)
            AccentLink("Play", action: play)
                .font(.caption.weight(.semibold))
                .opacity(hovering ? 1 : 0)
            Text(row.author)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 170, alignment: .trailing)
            Text(row.lengthText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(.rect)
        .background(hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: play)
        .contextMenu {
            Button("Play", action: play)
            AddToMenu(files: [row.id])
            ShareMenu(path: row.id)
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([row.url])
            }
        }
    }
}
