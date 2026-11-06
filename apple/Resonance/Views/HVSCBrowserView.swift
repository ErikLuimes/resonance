import SwiftUI
import PhosphorCore

/// One HVSC category: authors (or alphabetical sections) on the left, the
/// selected one's tunes on the right. Only for browsing: search has its own
/// place (`SearchView`), so this never changes shape.
///
/// Nothing here touches the toolbar (search field, subtitle): a toolbar that
/// changes when the sidebar selection changes made SwiftUI re-run the window
/// layout until AppKit aborted the app.
struct HVSCBrowserView: View {
    let category: HvscCategory

    @Environment(LibraryStore.self) private var library
    @State private var selectedAuthor: String?
    /// A composer without a folder whose credited tunes show instead of an
    /// author's (the inspector's link).
    @State private var creditedName: String?
    /// Scrolls the author list to an author the inspector's link revealed.
    @State private var authorScroll: AuthorScroll?

    var body: some View {
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
        .onChange(of: library.reveal, initial: true) { applyReveal() }
        .onChange(of: library.credits, initial: true) { applyCredits() }
        .onChange(of: selectedAuthor) { _, author in
            if author != nil { creditedName = nil }
        }
    }

    /// Follow the composer card's link for a composer without a folder:
    /// list their tunes.
    private func applyCredits() {
        guard let request = library.credits, request.category == category else { return }
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
}

// MARK: - Author list

/// An author to scroll to, once per reveal (the same author can be revealed
/// again after the user scrolled away).
private struct AuthorScroll: Equatable {
    let path: String
    let request: UUID
}

/// Authors (or sections) grouped under their letter folder, each with its
/// real name and tune count.
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
struct ComposerRowLabel: View {
    let author: HvscAuthorItem
    let summary: HvscComposer?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(author.displayName)
                    .lineLimit(1)
                if let realName = summary?.realName {
                    Text(realName)
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
                Text("The whole collection as one archive, into Resonance's folder.")
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

struct AuthorTunes: View {
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
                        Group {
                            if category == .musicians {
                                ComposerHeader(authorPath: authorPath, name: authorName, rows: rows,
                                               source: source, openComposer: openComposer)
                            } else {
                                SectionHeader(name: authorName, category: category, rows: rows, source: source)
                            }
                        }
                        // The same material as the title bar above it and the
                        // sound bar below, so the top of the pane reads as one
                        // surface.
                        .background(.bar)
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
    /// The Delete key removes the selection too.
    var removesOnDeleteKey = false
    /// A menu item's title and page for a row, where it has one.
    var webLink: ((LibraryRow.ID) -> (title: String, url: URL)?)? = nil
    /// Every row is by one composer, who the header above names.
    var hidesAuthor = false
    /// Puts dragged tunes (moved within the list, or from another) before
    /// the row at an index of the rows shown, or at the end: one of your
    /// playlists. Only while the list is in its own order.
    var onPlace: (([String], Int) -> Void)? = nil
    /// When each row last played, for a Played column (the history).
    var played: [LibraryRow.ID: String]? = nil
    /// What the list does, after Sound in the row above it: filter, Play.
    var actions: AnyView? = nil

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var player
    @Environment(FingerprintStore.self) private var fingerprints
    @State private var selection = Set<LibraryRow.ID>()
    @State private var sortOrder: [KeyPathComparator<LibraryRow>] = []
    /// The sounds that are on; a tune must have them all.
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

    /// The Sound menu and what the list does, and while Find Similar sorts the
    /// list, what it's sorted by. Sound only once any row has a fingerprint.
    @ViewBuilder
    private var soundBar: some View {
        let hasFingerprints = rows.contains(where: { fingerprints.fingerprint($0.id) != nil })
        if hasFingerprints || actions != nil {
            ListBar(sound: $soundFilter, showsSound: hasFingerprints, shown: shownRows.count, total: rows.count) {
                actions
            } extra: {
                if let seed = similarTo {
                    HStack(spacing: 6) {
                        Text("Sorted by how alike they sound to \u{201C}\(seed.title)\u{201D}")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        AccentLink("Clear") { similarTo = nil }
                    }
                }
            }
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

    /// Songs, Length, STIL, SIDs and Played: apart from `table`'s columns, which
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
            TableColumn("SIDs") { row in
                Text(fingerprints.fingerprint(row.id).map { "\($0.chips)" } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(36)
            .customizationID("sids")
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
        Table(of: LibraryRow.self, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("") { row in
                RowPlayCell(isCurrent: isCurrent(row), isPlaying: player.isPlaying, isSelected: selection.contains(row.id),
                            feed: player.visualizer, play: { play([row.id]) }, playPause: { player.playPause() })
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
                TableColumn("Author", value: \.author) { row in
                    AuthorCell(author: row.author)
                }
                .customizationID("author")
            }
            TableColumn("Year", value: \.year)
                .width(44)
                .customizationID("year")
            TableColumn("Released", value: \.released)
                .customizationID("releasedFull")
                .defaultVisibility(.hidden)
            TableColumn("Fingerprint") { row in
                SoundCell(fingerprints: fingerprints, path: row.id, title: row.title, subtitle: row.author,
                          length: row.item.durationSecs == nil ? nil : row.lengthText,
                          onPlay: { play([row.id]) }, onFindSimilar: { findSimilar(row) })
            }
            .width(84)
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
        } rows: {
            // Every row drags, onto a playlist in the sidebar. Reordering
            // only in the list's own order: sorted or filtered, a drop
            // position doesn't map to a place in the playlist.
            if let onPlace, isInOwnOrder {
                ForEach(shownRows) { row in
                    TableRow(row)
                        .draggable(TuneDrag.payload(path: row.id, title: row.title, author: row.author, from: ownPlaylist))
                }
                .dropDestination(for: PlaylistRowDrag.self) { offset, drags in
                    onPlace(drags.flatMap(\.paths), offset)
                }
            } else {
                ForEach(shownRows) { row in
                    TableRow(row)
                        .draggable(TuneDrag.payload(path: row.id, title: row.title, author: row.author, from: ownPlaylist))
                }
            }
        }
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: LibraryRow.ID.self) { ids in
            if !ids.isEmpty {
                Button("Play") { play(ids) }
                AddToMenu(files: chosen(ids).map(\.id))
                if ids.count == 1, let row = chosen(ids).first {
                    ShareMenu(path: row.id)
                }
                if let onRemove {
                    Button(removeTitle) { onRemove(ids) }
                }
                if ids.count == 1, let row = chosen(ids).first, fingerprints.fingerprint(row.id) != nil {
                    Button("Find Similar") { findSimilar(row) }
                    Button("Make a Playlist Like This") {
                        library.describeTune(.init(path: row.id, title: row.title, author: row.author))
                        library.shownSection = .smartPlaylist
                    }
                }
                Divider()
                if ids.count == 1, let id = ids.first, let link = webLink?(id) {
                    Button(link.title) { NSWorkspace.shared.open(link.url) }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(chosen(ids).map(\.url))
                }
            }
        } primaryAction: { ids in
            play(ids)
        }
        .onDeleteCommand(perform: removesOnDeleteKey && onRemove != nil && !selection.isEmpty ? { onRemove?(selection) } : nil)
    }

    private func play(_ ids: Set<LibraryRow.ID>) {
        let picked = chosen(ids)
        if picked.count == 1 {
            library.play(shownRows, startAt: picked[0], from: source)
        } else {
            library.play(picked, from: source)
        }
    }

    /// The rows as shown: filtered by Sound, then sorted by a
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

    /// No sort, Sound filter or Find Similar: the rows as the list has them.
    private var isInOwnOrder: Bool {
        sortOrder.isEmpty && soundFilter.isEmpty && similarTo == nil
    }

    /// Played from here or from the playlist, the core reports the same path.
    private func isCurrent(_ row: LibraryRow) -> Bool {
        row.id == player.nowPlaying?.path
    }

    /// Your playlist the rows are in, which tunes can be moved out of.
    private var ownPlaylist: String? {
        if case .playlist(let id, _) = source { id } else { nil }
    }

    /// Selected rows, in the order shown.
    private func chosen(_ ids: Set<LibraryRow.ID>) -> [LibraryRow] {
        shownRows.filter { ids.contains($0.id) }
    }
}

#Preview {
    HVSCBrowserView(category: .musicians)
#if CSDB
        .environment(CSDbStore())
#endif
        .environment(PlayerStore.preview)
        .environment(LibraryStore(player: .preview))
        .environment(FingerprintStore(player: .preview))
        .frame(width: 900, height: 500)
}
