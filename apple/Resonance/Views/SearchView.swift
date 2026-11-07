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
            header
            Divider()
            // Filling the rest keeps the filters at the top: an empty
            // state's own height let the whole stack float to the middle.
            resultsBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filterPicker: some View {
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
    }

    /// Like a playlist's header: what's being looked at, how much of it, and
    /// which part to see.
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 76, height: 76)
                .background(
                    LinearGradient(
                        colors: [Color(red: 63 / 255, green: 208 / 255, blue: 232 / 255),
                                 Color(red: 155 / 255, green: 107 / 255, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: .rect(cornerRadius: 17)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text("\u{201C}\(query)\u{201D}")
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isWaiting ? "Searching…" : searchError == nil ? summary : "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            filterPicker
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private var summary: String {
        switch filter {
        case .all:
            var parts: [String] = []
            let tuneCount = Int(results?.totalMatches ?? 0) + localMatches.count
            if tuneCount > 0 { parts.append(Self.count(tuneCount, "tune")) }
            if !composers.isEmpty { parts.append(Self.count(composers.count, "composer")) }
            return parts.isEmpty ? "No matches" : parts.formatted(.list(type: .and))
        case .tunes:
            guard let results, !results.items.isEmpty else { return "No matches" }
            let total = results.totalMatches.formatted()
            let indexed = results.indexed.formatted()
            return results.totalMatches > UInt32(results.items.count)
                ? "Best \(results.items.count) of \(total) matches among \(indexed) tunes"
                : "\(total) matches among \(indexed) tunes"
        case .composers:
            return composers.isEmpty ? "No matches" : Self.count(composers.count, "composer")
        case .games, .demos:
            guard let categoryTunes else { return "Searching…" }
            return categoryTunes.isEmpty ? "No matches" : Self.count(categoryTunes.count, "tune")
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
                                }
                            }
                        }
                    }
                    gamesAndDemos(games, demos)
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
            // The same height, so the top result's card lines up with the tunes'.
            .fixedSize(horizontal: false, vertical: true)
        } else {
            topCard(top)
            if !first.isEmpty {
                tunesSection
            }
        }
    }

    private func topCard(_ top: SearchTopResult) -> some View {
        SearchSection("Top Result", isCard: false) {
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

    /// Side by side, the same height, when they both have tunes and there's room.
    @ViewBuilder
    private func gamesAndDemos(_ games: [LibraryRow], _ demos: [LibraryRow]) -> some View {
        let gamesSection = tuneSection("Games", games, from: tunes.filter { $0.item.category == .games }, showing: .games)
        let demosSection = tuneSection("Demos", demos, from: tunes.filter { $0.item.category == .demos }, showing: .demos)
        if width >= 620, !games.isEmpty, !demos.isEmpty {
            HStack(alignment: .top, spacing: 24) {
                gamesSection
                    .frame(minWidth: 0, maxWidth: .infinity)
                demosSection
                    .frame(minWidth: 0, maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            gamesSection
            demosSection
        }
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
            .padding(.horizontal, 6)
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

/// A titled part of the overview: a card with its title above it, like the
/// Home's and Scene Pulse's.
private struct SearchSection<Content: View>: View {
    let title: String
    var sub: String?
    var seeAll: (() -> Void)?
    /// False for content that's a card already.
    var isCard = true
    @ViewBuilder let content: Content

    init(_ title: String, sub: String? = nil, seeAll: (() -> Void)? = nil, isCard: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.sub = sub
        self.seeAll = seeAll
        self.isCard = isCard
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title, sub: sub) {
                if let seeAll {
                    AccentLink("See All", action: seeAll)
                }
            }
            if isCard {
                content
                    .padding(6)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .modifier(CardBackground(radius: 12))
            } else {
                content
                    .frame(maxHeight: .infinity, alignment: .top)
            }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(.rect)
            .modifier(CardBackground(radius: 12, highlighted: hovering))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A tune in the overview, played where it is, like Scene Pulse's music: a click
/// plays it, or pauses or resumes it if it's the one in the player. Over its
/// tile, play under the pointer and the voices while it plays. The context menu
/// has the rest.
private struct SearchTuneRow: View {
    let row: LibraryRow
    let play: () -> Void

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var player
    @State private var hovering = false

    private var isCurrent: Bool { row.id == player.nowPlaying?.path }

    var body: some View {
        Button {
            if isCurrent { player.playPause() } else { play() }
        } label: {
            HStack(spacing: 10) {
                PlaylistArtwork(name: row.title, size: 34)
                    .overlay { playSlot.clipShape(.rect(cornerRadius: 34 * 0.22)) }
                VStack(alignment: .leading, spacing: 1) {
                    TuneTitleCell(library: library, path: row.id, title: row.title, author: row.author,
                                  isCurrent: isCurrent, mayHaveStil: row.item.hasStil,
                                  showsTeaser: false, isBold: true)
                    Text(SearchByline.text(author: row.author, category: row.item.category, length: row.lengthText))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(.rect)
            .csdbRowBackground(isCurrent: isCurrent, isHovered: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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

    /// Dims the tile only while it has something to show.
    @ViewBuilder
    private var playSlot: some View {
        if hovering || isCurrent {
            ZStack {
                Color.black.opacity(0.5)
                if isCurrent && !hovering {
                    VoiceBars(feed: player.visualizer, isActive: player.isPlaying)
                        .foregroundStyle(.white)
                        .accessibilityLabel(player.isPlaying ? "Playing" : "Paused")
                } else {
                    Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

/// The line under a tune in the overview. Search knows a tune's folder, not its
/// credit: a composer's name in MUSICIANS, but in Games and Demos mostly a letter
/// range, which says nothing about who made it.
enum SearchByline {
    static func text(author: String, category: HvscCategory, length: String) -> String {
        guard let name = name(author: author, category: category) else { return length }
        return "\(name) · \(length)"
    }

    private static func name(author: String, category: HvscCategory) -> String? {
        if author == "<?>" || author.uppercased() == "UNKNOWN" { return "Unknown" }
        if category != .musicians, author.wholeMatch(of: /[A-Za-z0-9]+-[A-Za-z0-9]+/) != nil { return nil }
        return LibraryStore.spokenName(author)
    }
}

extension View {
    /// A tune row's background: the playing row's accent wash, as in a song
    /// table, or a hint of a click to come.
    func csdbRowBackground(isCurrent: Bool, isHovered: Bool) -> some View {
        background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 8).fill(.tint.opacity(0.16))
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8).fill(.fill.tertiary)
            }
        }
    }
}
