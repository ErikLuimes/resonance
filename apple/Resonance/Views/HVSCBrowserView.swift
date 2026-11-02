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
                    Divider()
                    authorTunes
                        .frame(minWidth: 0, maxWidth: .infinity)
                }
            } else {
                searchResults
            }
        }
        .task(id: SearchRequest(query: query, scope: scope)) { await runSearch() }
        .onChange(of: library.reveal, initial: true) { applyReveal() }
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
        library.revealedTune = reveal.tunePath
        library.reveal = nil
    }

    // MARK: Author tunes

    @ViewBuilder
    private var authorTunes: some View {
        if let name = creditedName {
            CreditedTunes(name: name)
                .id(name)
        } else if let path = selectedAuthor {
            AuthorTunes(authorPath: path, authorName: authorName(path))
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
                Picker("Search in", selection: $scope) {
                    Text(category.displayName).tag(SearchScope.category)
                    Text("All HVSC").tag(SearchScope.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
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
                LibraryTable(rows: results.items.map(LibraryRow.init))
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

/// Authors (or sections) grouped under their letter folder, with a filter.
private struct AuthorList: View {
    let category: HvscCategory
    @Binding var selection: String?
    let scrollTarget: AuthorScroll?

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var player
    @State private var filter = ""

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
            } else if let authors = library.authors[category] {
                let shown = groups(authors)
                ScrollViewReader { proxy in
                    List(selection: $selection) {
                        ForEach(shown, id: \.letter) { group in
                            Section(group.letter == "0" ? "0–9" : group.letter) {
                                ForEach(group.authors, id: \.path) { author in
                                    Text(author.displayName)
                                        .lineLimit(1)
                                        .tag(author.path)
                                        .contextMenu {
                                            Button("Add All to Playlist") { library.addAll(authorPath: author.path) }
                                        }
                                }
                            }
                        }
                    }
                    .onChange(of: scrollTarget, initial: true) { _, target in
                        guard let target else { return }
                        // The filter could hide the author.
                        filter = ""
                        // After the list has its rows back.
                        Task { proxy.scrollTo(target.path, anchor: .center) }
                    }
                }
                // Before the inset, so it centres in the list below the
                // filter field rather than covering it.
                .overlay {
                    if shown.isEmpty {
                        ContentUnavailableView.search(text: needle)
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    TextField("Filter \(category.groupNoun)", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .padding(8)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The tree revision, not the root: it also bumps when the first
        // sync fills the current folder in place.
        .task(id: player.hvscTreeRevision) { await library.loadAuthors(category) }
    }

    private struct LetterGroup {
        let letter: String
        let authors: [HvscAuthorItem]
    }

    private var needle: String { filter.trimmingCharacters(in: .whitespaces) }

    /// Consecutive authors sharing a letter folder, after filtering.
    private func groups(_ authors: [HvscAuthorItem]) -> [LetterGroup] {
        let shown = needle.isEmpty
            ? authors
            : authors.filter { $0.displayName.localizedStandardContains(needle) || $0.name.localizedStandardContains(needle) }
        var groups: [LetterGroup] = []
        for author in shown {
            if groups.last?.letter == author.letter {
                groups[groups.count - 1] = LetterGroup(letter: author.letter, authors: groups[groups.count - 1].authors + [author])
            } else {
                groups.append(LetterGroup(letter: author.letter, authors: [author]))
            }
        }
        return groups
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

    @Environment(LibraryStore.self) private var library

    var body: some View {
        Group {
            if let rows = library.tunes[authorPath] {
                LibraryTable(rows: rows)
                    .safeAreaInset(edge: .top, spacing: 0) { header(count: rows.count) }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await library.loadTunes(authorPath: authorPath) }
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(authorName)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text(count == 1 ? "1 tune" : "\(count) tunes")
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Add All", systemImage: "text.badge.plus") { library.addAll(authorPath: authorPath) }
                .help("Add every tune here to the playlist")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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
                    LibraryTable(rows: rows)
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
                    .help("Add every tune here to the playlist")
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
    /// The published playlist the rows are, which the inspector names
    /// while they play.
    var playlist: HvscPlaylist? = nil

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var player
    @State private var selection = Set<LibraryRow.ID>()
    @State private var sortOrder: [KeyPathComparator<LibraryRow>] = []

    var body: some View {
        ScrollViewReader { proxy in
            table
                // The inspector's author link: select the tune once it's here.
                .onChange(of: rows, initial: true) { revealTune(proxy) }
                .onChange(of: library.revealedTune) { revealTune(proxy) }
        }
    }

    private func revealTune(_ proxy: ScrollViewProxy) {
        guard let path = library.revealedTune, rows.contains(where: { $0.id == path }) else { return }
        selection = [path]
        library.revealedTune = nil
        Task { proxy.scrollTo(path, anchor: .center) }
    }

    private var table: some View {
        Table(sortedRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { row in
                if isCurrent(row) {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel(player.isPlaying ? "Playing" : "Paused")
                }
            }
            .width(22)
            TableColumn("Title", value: \.title) { row in
                Text(row.title)
                    .fontWeight(isCurrent(row) ? .semibold : .regular)
            }
            TableColumn("Author", value: \.author)
            TableColumn("Released", value: \.released)
            TableColumn("Songs", value: \.songs) { row in
                Text("\(row.songs)").monospacedDigit()
            }
            .width(48)
            TableColumn("Length", value: \.length) { row in
                Text(row.lengthText).monospacedDigit()
            }
            .width(56)
            TableColumn("STIL", value: \.stilSort) { row in
                if row.item.hasStil {
                    Image(systemName: "text.quote")
                        .foregroundStyle(.secondary)
                        .help("Has STIL commentary")
                }
            }
            .width(36)
        }
        .contextMenu(forSelectionType: LibraryRow.ID.self) { ids in
            if !ids.isEmpty {
                Button("Play") { play(ids) }
                Button("Add to Playlist") { library.addToPlaylist(chosen(ids)) }
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
            library.play(sortedRows, startAt: picked[0], from: playlist)
        } else {
            library.play(picked)
        }
    }

    private var sortedRows: [LibraryRow] {
        sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder)
    }

    /// Played from here or from the playlist, the core reports the same path.
    private func isCurrent(_ row: LibraryRow) -> Bool {
        row.id == player.nowPlaying?.path
    }

    /// Selected rows, in the order shown.
    private func chosen(_ ids: Set<LibraryRow.ID>) -> [LibraryRow] {
        sortedRows.filter { ids.contains($0.id) }
    }
}

#Preview {
    HVSCBrowserView(category: .musicians, search: "")
        .environment(PlayerStore.preview)
        .environment(LibraryStore(player: .preview))
        .frame(width: 900, height: 500)
}
