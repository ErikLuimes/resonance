import SwiftUI
import PhosphorCore

/// One HVSC category: authors (or alphabetical sections) on the left, the
/// selected one's tunes on the right; typing in the window's search field
/// switches to ranked results from this category or all of HVSC.
///
/// Nothing here touches the toolbar (search field, scopes, subtitle): a
/// toolbar that changes when the sidebar selection changes made SwiftUI
/// re-run the window layout until AppKit aborted the app.
struct HVSCBrowserView: View {
    let category: HvscCategory
    /// The window search field's text for this category.
    let search: String

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var player
    @State private var selectedAuthor: String?
    /// A composer without a folder whose credited tunes show instead of an
    /// author's (the inspector's link).
    @State private var creditedName: String?
    /// Scrolls the author list to an author the inspector's link revealed.
    @State private var authorScroll: AuthorScroll?
    @State private var scope = SearchScope.category
    @State private var results: HvscSearchResult?
    @State private var searchError: String?

    enum SearchScope: Hashable {
        case category, all
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Group {
            if query.isEmpty {
                // Not HSplitView: its panes' minimum widths become AppKit
                // constraints that fight the window's own split view
                // (sidebar / content / inspector) until AppKit aborts the
                // app. A fixed author column can't conflict.
                HStack(spacing: 0) {
                    AuthorList(category: category, selection: $selectedAuthor, scrollTarget: authorScroll)
                        .frame(width: 240)
                        // A column separator through the title bar, like the
                        // window's own: a Divider stopped at the title bar,
                        // and its glass faded the top of it.
                        .overlay(alignment: .trailing) {
                            Rectangle()
                                .fill(.separator)
                                .frame(width: 1)
                                .ignoresSafeArea()
                        }
                    authorTunes
                        .frame(minWidth: 0, maxWidth: .infinity)
                }
            } else {
                searchResults
            }
        }
        .task(id: SearchRequest(query: query, scope: scope)) { await runSearch() }
        .task(id: player.hvscTreeRevision) {
            for c in searchedCategories {
                await library.loadAuthors(c)
                await library.loadComposers(c)
            }
        }
        .onChange(of: library.reveal, initial: true) { applyReveal() }
        // Search all of HVSC, from another list's search.
        .onChange(of: library.searchesAllHvsc, initial: true) {
            guard library.searchesAllHvsc else { return }
            scope = .all
            library.searchesAllHvsc = false
        }
        .onChange(of: library.credits, initial: true) { applyCredits() }
        .onChange(of: query) { applyCredits() }
        .onChange(of: selectedAuthor) { _, author in
            if author != nil { creditedName = nil }
        }
    }

    /// Follow the composer card's link for a composer without a folder:
    /// once the window has cleared the search, list their tunes.
    private func applyCredits() {
        guard let request = library.credits, request.category == category, query.isEmpty else { return }
        selectedAuthor = nil
        creditedName = request.name
        library.credits = nil
    }

    /// Follow the inspector's author link: select the composer, and leave
    /// the tune for their tune table to select.
    private func applyReveal() {
        guard let reveal = library.reveal, reveal.category == category else { return }
        selectedAuthor = reveal.authorPath
        authorScroll = AuthorScroll(path: reveal.authorPath, request: reveal.id)
        if !reveal.tunePath.isEmpty { library.revealedTune = reveal.tunePath }
        library.reveal = nil
    }

    // MARK: Author tunes

    @ViewBuilder
    private var authorTunes: some View {
        if let name = creditedName {
            CreditedTunes(name: name)
                .id(name)
        } else if let path = selectedAuthor {
            AuthorTunes(authorPath: path, authorName: authorName(path), category: category) { other in
                selectedAuthor = other
                authorScroll = AuthorScroll(path: other, request: UUID())
            }
            .id(path)
        } else {
            ContentUnavailableView(
                "Choose \(category == .musicians ? "an Author" : "a Section")",
                systemImage: category.symbolName,
                description: Text("Double-click a tune to play it.")
            )
        }
    }

    private func authorName(_ path: String) -> String {
        library.authors[category]?.first { $0.path == path }?.displayName ?? URL(filePath: path).lastPathComponent
    }

    // MARK: Search

    private struct SearchRequest: Hashable {
        let query: String
        let scope: SearchScope
    }

    private func runSearch() async {
        guard !query.isEmpty else {
            results = nil
            searchError = nil
            return
        }
        // Debounce: a newer keystroke cancels this task before it searches.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        do {
            let found = try await library.search(query, scope: scope == .all ? nil : category)
            guard !Task.isCancelled else { return }
            results = found
            searchError = nil
        } catch is CancellationError {
        } catch {
            searchError = LibraryStore.message(for: error)
        }
    }

    private var searchResults: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Finder's scope bar: a small control with its label, a
                // setting rather than the page's main thing. (Not
                // .searchScopes: the toolbar must stay the same per section.)
                HStack(spacing: 6) {
                    Text("Search in")
                        .foregroundStyle(.secondary)
                    Picker("Search in", selection: $scope) {
                        Text(category.displayName).tag(SearchScope.category)
                        Text("All HVSC").tag(SearchScope.all)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    // Capsules, like Now Playing's large picker (only the
                    // large size has them by default).
                    .buttonBorderShape(.capsule)
                    .fixedSize()
                }
                .font(.callout)
                if let results, !isIndexing, searchError == nil, !results.items.isEmpty {
                    Text(resultsSummary(results))
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
            Divider()
            // Filling the rest keeps the scope bar at the top: an empty
            // state's own height let the whole stack float to the middle.
            resultsBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var resultsBody: some View {
        if let searchError {
            ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle", description: Text(searchError))
        } else if let results, !isIndexing {
            if results.items.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                LibraryTable(rows: results.items.map(LibraryRow.init), source: .search(query: query))
                    .safeAreaInset(edge: .top, spacing: 0) { matchingComposers }
            }
        } else {
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
        }
    }

    /// The composers (or sections) the search names, above its tunes:
    /// clicking one opens it, as does Return on the first.
    @ViewBuilder
    private var matchingComposers: some View {
        let found = searchedCategories.flatMap { c in library.composers(matching: query, in: c, limit: 500).map { (c, $0) } }
        if !found.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(category == .musicians || scope == .all ? "Composers" : category.groupNoun.capitalized)
                    if found.count > Self.composerRows {
                        Text(found.count.formatted())
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                // All of them, for browsing: a few rows tall, scrolling
                // through the rest.
                if found.count > Self.composerRows {
                    ScrollView {
                        composerRows(found)
                    }
                    .frame(height: 210)
                } else {
                    composerRows(found)
                }
                Text("Tunes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    /// How many composers show before their list scrolls.
    private static let composerRows = 5

    private func composerRows(_ found: [(HvscCategory, HvscAuthorItem)]) -> some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(found, id: \.1.path) { (c, author) in
                Button {
                    library.showComposer(author.path, in: c)
                } label: {
                    ComposerRowLabel(author: author, summary: library.composers[c]?[author.path], showsCategory: scope == .all ? c : nil)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var searchedCategories: [HvscCategory] {
        scope == .all ? HvscCategory.allCases : [category]
    }

    private var isIndexing: Bool {
        player.hvscIndexing.contains { searchedCategories.contains($0) }
    }

    private var indexingNames: String {
        player.hvscIndexing
            .filter { searchedCategories.contains($0) }
            .map(\.displayName)
            .formatted(.list(type: .and))
    }

    private func resultsSummary(_ r: HvscSearchResult) -> String {
        let total = r.totalMatches.formatted()
        let indexed = r.indexed.formatted()
        return r.totalMatches > UInt32(r.items.count)
            ? "Best \(r.items.count) of \(total) matches among \(indexed) tunes"
            : "\(total) matches among \(indexed) tunes"
    }
}

// MARK: - Author list

/// An author to scroll to, once per reveal (the same author can be revealed
/// again after the user scrolled away).
private struct AuthorScroll: Equatable {
    let path: String
    let request: UUID
}

/// Authors (or sections) grouped under their letter folder, each with its
/// real name and tune count. The window's search finds them by name
/// (`matchingComposers`).
private struct AuthorList: View {
    let category: HvscCategory
    @Binding var selection: String?
    let scrollTarget: AuthorScroll?

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var player

    var body: some View {
        Group {
            if !player.hasCollection {
                HvscDownloadView()
            } else if let error = library.errors[category] {
                ContentUnavailableView {
                    Label("Can't Read \(category.displayName)", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(error)
                } actions: {
                    SettingsLink { Text("Open Settings…") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let authors = library.authors[category] {
                let shown = groups(authors)
                let summaries = library.composers[category] ?? [:]
                ScrollViewReader { proxy in
                    List(selection: $selection) {
                        ForEach(shown, id: \.letter) { group in
                            Section(group.letter == "0" ? "0–9" : group.letter) {
                                ForEach(group.authors, id: \.path) { author in
                                    ComposerRowLabel(author: author, summary: summaries[author.path])
                                        .tag(author.path)
                                        .contextMenu {
                                            Button("Add All to My Playlist") { library.addAll(authorPath: author.path) }
                                        }
                                }
                            }
                        }
                    }
                    .onChange(of: scrollTarget, initial: true) { _, target in
                        guard let target else { return }
                        // After the list has its rows.
                        Task { proxy.scrollTo(target.path, anchor: .center) }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The tree revision, not the root: it also bumps when the first
        // sync fills the current folder in place.
        .task(id: player.hvscTreeRevision) {
            await library.loadAuthors(category)
            await library.loadComposers(category)
        }
    }

    private struct LetterGroup {
        let letter: String
        let authors: [HvscAuthorItem]
    }

    /// Consecutive authors sharing a letter folder.
    private func groups(_ authors: [HvscAuthorItem]) -> [LetterGroup] {
        var groups: [LetterGroup] = []
        for author in authors {
            if groups.last?.letter == author.letter {
                groups[groups.count - 1] = LetterGroup(letter: author.letter, authors: groups[groups.count - 1].authors + [author])
            } else {
                groups.append(LetterGroup(letter: author.letter, authors: [author]))
            }
        }
        return groups
    }
}

/// An author's row: the folder's name, the person their headers name
/// under it, and how many tunes there are.
private struct ComposerRowLabel: View {
    let author: HvscAuthorItem
    let summary: HvscComposer?
    /// Names the section, in results from all of HVSC.
    var showsCategory: HvscCategory? = nil

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(author.displayName)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let tunes = summary?.tunes {
                Text(tunes.formatted())
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String? {
        let parts = [summary?.realName, showsCategory?.displayName].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

// MARK: - Download

/// The collection download, for when the folder holds no tree yet: a
/// button, then progress and cancel, then the outcome. Shared by the
/// sidebar and the Settings window.
struct HvscDownloadView: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        VStack(spacing: 10) {
            if let sync = store.hvscSync {
                if sync.running {
                    if let fraction = sync.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Text(sync.current)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Button("Cancel") { store.cancelHvscSync() }
                        .buttonStyle(.borderless)
                } else if let error = sync.error {
                    Label {
                        Text(error)
                            .multilineTextAlignment(.center)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    Button("Try Again") { store.startHvscSync() }
                        .buttonStyle(.borderless)
                } else {
                    // A beat, until the app points at the folder that was
                    // just filled and the category rows appear.
                    Label(sync.current, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            } else if let error = store.hvscSyncError {
                Label {
                    Text(error)
                        .multilineTextAlignment(.center)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
            } else {
                Button {
                    store.startHvscSync()
                } label: {
                    Label("Download HVSC", systemImage: "arrow.down.circle")
                }
                Text("The whole collection as one archive, into the folder Phosphor uses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Author tunes

private struct AuthorTunes: View {
    let authorPath: String
    let authorName: String
    let category: HvscCategory
    /// Opens another composer (Sounds similar).
    let openComposer: (String) -> Void

    @Environment(LibraryStore.self) private var library

    var body: some View {
        Group {
            if let rows = library.tunes[authorPath] {
                LibraryTable(rows: rows, source: source, hidesAuthor: category == .musicians)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        ComposerCard(authorPath: authorPath, name: authorName, category: category,
                                     rows: rows, source: source, openComposer: openComposer)
                    }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await library.loadTunes(authorPath: authorPath) }
    }

    private var source: PlaybackSource { .folder(name: authorName, category: category) }
}

/// The composer (or section) over their tunes: who they are, how much and
/// when, play buttons, and the composers who sound most like them.
private struct ComposerCard: View {
    let authorPath: String
    let name: String
    let category: HvscCategory
    let rows: [LibraryRow]
    let source: PlaybackSource
    let openComposer: (String) -> Void

    @Environment(LibraryStore.self) private var library

    var body: some View {
        let summary = library.composers[category]?[authorPath]
        HStack(alignment: .top, spacing: 14) {
            // The inspector's composer card's monogram, larger.
            ZStack {
                Circle().fill(.background)
                Text(initials)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.tint)
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(facts(summary))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Button("Play", systemImage: "play.fill") { library.play(rows, from: source) }
                        .buttonStyle(.borderedProminent)
                    Button("Shuffle", systemImage: "shuffle") { library.play(rows.shuffled(), from: source) }
                    AddToButton(files: rows.map(\.id))
                }
                .controlSize(.small)
                .disabled(rows.isEmpty)
            }
            Spacer(minLength: 12)
            if category == .musicians, let similar = library.similarComposers[authorPath], !similar.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sounds similar")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(similar.prefix(3), id: \.path) { other in
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
                .font(.callout)
                .frame(width: 170)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A card like the inspector's composer card, set off from the
        // window's title bar and the tune list.
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        // The same material as the title bar above it and the sound bar
        // below, so the top of the pane reads as one surface.
        .background(.bar)
        .task(id: authorPath) {
            guard category == .musicians else { return }
            await library.loadSimilarComposers(authorPath)
        }
    }

    private var initials: String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    /// "Ari Yliaho, 124 tunes, 1988–2021".
    private func facts(_ summary: HvscComposer?) -> String {
        var parts: [String] = []
        if let real = summary?.realName { parts.append(real) }
        parts.append(rows.count == 1 ? "1 tune" : "\(rows.count.formatted()) tunes")
        if let first = summary?.firstYear, let last = summary?.lastYear {
            parts.append(first == last ? "\(first)" : "\(first)–\(last)")
        }
        return parts.joined(separator: ", ")
    }

    private func displayName(_ path: String) -> String {
        library.authors[.musicians]?.first { $0.path == path }?.displayName ?? URL(filePath: path).lastPathComponent
    }
}

// MARK: - Credited tunes

/// The tunes credited to a composer without a MUSICIANS folder, standing in
/// for one: every tune in HVSC whose header names them.
private struct CreditedTunes: View {
    let name: String

    @Environment(LibraryStore.self) private var library

    var body: some View {
        Group {
            if let rows = library.credited[name] {
                if rows.isEmpty {
                    ContentUnavailableView(
                        "No Tunes Found",
                        systemImage: "music.mic",
                        description: Text("No tune in HVSC credits \(name).")
                    )
                } else {
                    LibraryTable(rows: rows, source: .folder(name: name, category: .musicians))
                        .safeAreaInset(edge: .top, spacing: 0) { header(rows) }
                }
            } else {
                // The first lookup reads every tune's header.
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Finding tunes credited to \(name)…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await library.loadCredited(name: name) }
    }

    private func header(_ rows: [LibraryRow]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(rows.count == 1 ? "1 tune" : "\(rows.count) tunes")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Add All", systemImage: "text.badge.plus") { library.addToPlaylist(rows) }
                    .help("Add every tune here to My Playlist")
            }
            Text("\(name) has no folder in MUSICIANS. These are the tunes whose header credits them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Tune table

/// Library tunes: double-click (or Return) plays, the context menu adds to
/// the playlist or reveals the file. Sorting only changes the view. The
/// playing tune is marked like the playlist's current row.
///
/// Playing works like Music: one tune plays the whole list as shown,
/// starting there; several selected tunes play just those. Either way the
/// player walks that list, not the playlist.
struct LibraryTable: View {
    let rows: [LibraryRow]
    /// Where the rows come from, which "Playing from" names while they
    /// play.
    let source: PlaybackSource
    /// Removes rows from the list shown (one of your playlists).
    var onRemove: ((Set<LibraryRow.ID>) -> Void)? = nil
    var removeTitle = "Remove from Playlist"
    /// Every row is by one composer, who the header above names.
    var hidesAuthor = false
    /// When each row last played, for a Played column (the history).
    var played: [LibraryRow.ID: String]? = nil

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var player
    @Environment(FingerprintStore.self) private var fingerprints
    @State private var selection = Set<LibraryRow.ID>()
    @State private var sortOrder: [KeyPathComparator<LibraryRow>] = []
    /// The Sound chips that are on; a tune must have them all.
    @State private var soundFilter = Set<SoundTag>()
    /// Find Similar's tune, which the list is sorted by likeness to, and
    /// how alike each row sounds to it (0–1).
    @State private var similarTo: LibraryRow?
    @State private var likeness: [LibraryRow.ID: Double] = [:]
    /// Which columns show (the header's menu), kept per window and shared by
    /// every library list. Title, Author, Released and Length by default.
    @SceneStorage("LibraryColumns") private var columns = TableColumnCustomization<LibraryRow>()

    var body: some View {
        ScrollViewReader { proxy in
            table
                // The inspector's author link: select the tune once it's here.
                .onChange(of: rows, initial: true) { revealTune(proxy) }
                .onChange(of: library.revealedTune) { revealTune(proxy) }
        }
        .safeAreaInset(edge: .top, spacing: 0) { soundBar }
        .task(id: rows) { fingerprints.load(rows.map(\.id)) }
        .task(id: TaskKey(seed: similarTo?.id, rows: rows.count, revision: (fingerprints.status?.revision ?? 0) / 500)) {
            guard let seed = similarTo else { return }
            likeness = await fingerprints.similarity(to: seed.id, of: rows.map(\.id))
        }
        // A list sorted by a column isn't sorted by likeness any more.
        .onChange(of: sortOrder) { if !sortOrder.isEmpty { similarTo = nil } }
        .onChange(of: rows) { if let seed = similarTo, !rows.contains(seed) { similarTo = nil } }
    }

    private struct TaskKey: Equatable {
        let seed: LibraryRow.ID?
        let rows: Int
        let revision: UInt64
    }

    // MARK: Sound

    /// The Sound chips, and while Find Similar sorts the list, what it's
    /// sorted by. Only once any row here has a fingerprint.
    @ViewBuilder
    private var soundBar: some View {
        if rows.contains(where: { fingerprints.fingerprint($0.id) != nil }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Sound")
                        .foregroundStyle(.secondary)
                    ForEach(SoundTag.filters, id: \.self) { tag in
                        chip(tag)
                    }
                    Spacer(minLength: 8)
                    if !soundFilter.isEmpty {
                        Text("\(shownRows.count) of \(rows.count) tunes")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        AccentLink("Clear") { soundFilter = [] }
                    }
                }
                if let seed = similarTo {
                    HStack(spacing: 6) {
                        Text("Sorted by how alike they sound to \u{201C}\(seed.title)\u{201D}")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        AccentLink("Clear") { similarTo = nil }
                    }
                }
            }
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func chip(_ tag: SoundTag) -> some View {
        let on = soundFilter.contains(tag)
        let button = Button(tag.name) {
            if on { soundFilter.remove(tag) } else { soundFilter.insert(tag) }
        }
        .buttonBorderShape(.capsule)
        .accessibilityAddTraits(on ? .isSelected : [])
        if on {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func findSimilar(_ row: LibraryRow) {
        likeness = [:]
        sortOrder = []
        similarTo = row
        selection = [row.id]
    }

    private func revealTune(_ proxy: ScrollViewProxy) {
        guard let path = library.revealedTune, rows.contains(where: { $0.id == path }) else { return }
        selection = [path]
        library.revealedTune = nil
        Task { proxy.scrollTo(path, anchor: .center) }
    }

    /// Songs, Length, STIL and Played: apart from `table`'s columns, which
    /// a builder (and the type checker) can't take all at once.
    @TableColumnBuilder<LibraryRow, KeyPathComparator<LibraryRow>>
    private var trailingColumns: some TableColumnContent<LibraryRow, KeyPathComparator<LibraryRow>> {
            TableColumn("Songs", value: \.songs) { row in
                Text("\(row.songs)").monospacedDigit()
            }
            .width(48)
            .customizationID("songs")
            .defaultVisibility(.hidden)
            TableColumn("Length", value: \.length) { row in
                Text(row.lengthText).monospacedDigit()
            }
            .width(56)
            .customizationID("length")
            TableColumn("STIL", value: \.stilSort) { row in
                if row.item.hasStil {
                    Image(systemName: "text.quote")
                        .foregroundStyle(.secondary)
                        .help("Has STIL commentary")
                }
            }
            .width(36)
            .customizationID("stil")
            .defaultVisibility(.hidden)
            if let played {
                TableColumn("Played") { row in
                    Text(played[row.id] ?? "")
                        .foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 120)
                .customizationID("played")
            }
    }

    private var table: some View {
        Table(shownRows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("") { row in
                if isCurrent(row) {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel(player.isPlaying ? "Playing" : "Paused")
                }
            }
            .width(22)
            .customizationID("playing")
            TableColumn("Title", value: \.title) { row in
                TuneTitleCell(library: library, path: row.id, title: row.title, author: row.author,
                              isCurrent: isCurrent(row), mayHaveStil: row.item.hasStil)
            }
            .width(min: 160, ideal: 320)
            .customizationID("title")
            if !hidesAuthor {
                TableColumn("Author", value: \.author)
                    .customizationID("author")
            }
            TableColumn("Year", value: \.year)
                .width(44)
                .customizationID("year")
            TableColumn("Released", value: \.released)
                .customizationID("releasedFull")
                .defaultVisibility(.hidden)
            TableColumn("Sound") { row in
                SoundCell(fingerprints: fingerprints, path: row.id, title: row.title, subtitle: row.author,
                          length: row.item.durationSecs == nil ? nil : row.lengthText,
                          onPlay: { play([row.id]) }, onFindSimilar: { findSimilar(row) })
            }
            .width(72)
            .customizationID("sound")
            if similarTo != nil {
                TableColumn("Match") { row in
                    if row.id != similarTo?.id, let score = likeness[row.id] {
                        Text(score, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .width(52)
                .customizationID("match")
            }
            trailingColumns
        }
        .contextMenu(forSelectionType: LibraryRow.ID.self) { ids in
            if !ids.isEmpty {
                Button("Play") { play(ids) }
                AddToMenu(files: chosen(ids).map(\.id))
                if let onRemove {
                    Button(removeTitle) { onRemove(ids) }
                }
                if ids.count == 1, let row = chosen(ids).first, fingerprints.fingerprint(row.id) != nil {
                    Button("Find Similar") { findSimilar(row) }
                }
                Divider()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(chosen(ids).map(\.url))
                }
            }
        } primaryAction: { ids in
            play(ids)
        }
    }

    private func play(_ ids: Set<LibraryRow.ID>) {
        let picked = chosen(ids)
        if picked.count == 1 {
            library.play(shownRows, startAt: picked[0], from: source)
        } else {
            library.play(picked, from: source)
        }
    }

    /// The rows as shown: filtered by the Sound chips, then sorted by a
    /// column or by likeness to Find Similar's tune (it first, unscanned
    /// tunes last).
    private var shownRows: [LibraryRow] {
        let filtered = soundFilter.isEmpty ? rows : rows.filter { row in
            guard let fp = fingerprints.fingerprint(row.id) else { return false }
            return soundFilter.isSubset(of: fp.tags)
        }
        if let seed = similarTo {
            return filtered.sorted { a, b in
                if a.id == seed.id || b.id == seed.id { return a.id == seed.id }
                return (likeness[a.id] ?? -1) > (likeness[b.id] ?? -1)
            }
        }
        return sortOrder.isEmpty ? filtered : filtered.sorted(using: sortOrder)
    }

    /// Played from here or from the playlist, the core reports the same path.
    private func isCurrent(_ row: LibraryRow) -> Bool {
        row.id == player.nowPlaying?.path
    }

    /// Selected rows, in the order shown.
    private func chosen(_ ids: Set<LibraryRow.ID>) -> [LibraryRow] {
        shownRows.filter { ids.contains($0.id) }
    }
}

#Preview {
    HVSCBrowserView(category: .musicians, search: "")
        .environment(PlayerStore.preview)
        .environment(LibraryStore(player: .preview))
        .environment(FingerprintStore(player: .preview))
        .frame(width: 900, height: 500)
}
