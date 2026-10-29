import SwiftUI
import PhosphorCore

/// One HVSC category: authors (or alphabetical sections) on the left, the
/// selected one's tunes on the right; typing in the search field switches to
/// ranked results from this category or all of HVSC.
struct HVSCBrowserView: View {
    let category: HvscCategory

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var player
    @State private var selectedAuthor: String?
    @State private var search = ""
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
                HSplitView {
                    AuthorList(category: category, selection: $selectedAuthor)
                        .frame(minWidth: 160, idealWidth: 230, maxWidth: 340)
                    authorTunes
                        .frame(minWidth: 200, maxWidth: .infinity)
                }
            } else {
                searchResults
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search \(category.displayName)")
        .searchScopes($scope) {
            Text(category.displayName).tag(SearchScope.category)
            Text("All HVSC").tag(SearchScope.all)
        }
        .task(id: SearchRequest(query: query, scope: scope)) { await runSearch() }
        .navigationSubtitle(subtitle)
    }

    // MARK: Author tunes

    @ViewBuilder
    private var authorTunes: some View {
        if let path = selectedAuthor {
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

    @ViewBuilder
    private var searchResults: some View {
        if let searchError {
            ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle", description: Text(searchError))
        } else if let results, !isIndexing {
            if results.items.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                LibraryTable(rows: results.items.map(LibraryRow.init))
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Text(resultsSummary(results))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.bar)
                    }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var subtitle: String {
        if !query.isEmpty, let results {
            return "\(results.totalMatches.formatted()) matches"
        }
        guard let authors = library.authors[category] else { return category.displayName }
        return "\(authors.count.formatted()) \(category.groupNoun)"
    }
}

// MARK: - Author list

/// Authors (or sections) grouped under their letter folder, with a filter.
private struct AuthorList: View {
    let category: HvscCategory
    @Binding var selection: String?

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var player
    @State private var filter = ""

    var body: some View {
        Group {
            if let error = library.errors[category] {
                ContentUnavailableView {
                    Label("Can't Read \(category.displayName)", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(error)
                } actions: {
                    SettingsLink { Text("Open Settings…") }
                }
            } else if let authors = library.authors[category] {
                List(selection: $selection) {
                    ForEach(groups(authors), id: \.letter) { group in
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
        .task(id: player.hvscRoot) { await library.loadAuthors(category) }
    }

    private struct LetterGroup {
        let letter: String
        let authors: [HvscAuthorItem]
    }

    /// Consecutive authors sharing a letter folder, after filtering.
    private func groups(_ authors: [HvscAuthorItem]) -> [LetterGroup] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
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

// MARK: - Tune table

/// Library tunes: double-click (or Return) plays, the context menu adds to
/// the playlist or reveals the file. Sorting only changes the view.
private struct LibraryTable: View {
    let rows: [LibraryRow]

    @Environment(LibraryStore.self) private var library
    @State private var selection = Set<LibraryRow.ID>()
    @State private var sortOrder: [KeyPathComparator<LibraryRow>] = []

    var body: some View {
        Table(sortedRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title)
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
                Button("Play") { library.play(chosen(ids)) }
                Button("Add to Playlist") { library.addToPlaylist(chosen(ids)) }
                Divider()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(chosen(ids).map(\.url))
                }
            }
        } primaryAction: { ids in
            library.play(chosen(ids))
        }
    }

    private var sortedRows: [LibraryRow] {
        sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder)
    }

    /// Selected rows, in the order shown.
    private func chosen(_ ids: Set<LibraryRow.ID>) -> [LibraryRow] {
        sortedRows.filter { ids.contains($0.id) }
    }
}

#Preview {
    HVSCBrowserView(category: .musicians)
        .environment(PlayerStore.preview)
        .environment(LibraryStore(player: .preview))
        .frame(width: 900, height: 500)
}
