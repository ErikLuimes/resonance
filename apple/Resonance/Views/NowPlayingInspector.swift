import SwiftUI
import PhosphorCore

/// Visualizer and details of the playing tune: its title, the composer's
/// card, what STIL says about it, and its specs.
struct NowPlayingInspector: View {
    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library

    var body: some View {
        // The visualizer redraws every frame, so it stays above the
        // scrolling details rather than being laid out with them.
        VStack(spacing: 0) {
            VisualizerView()
                .frame(height: 204)
                .padding(12)
            details
        }
    }

    @ViewBuilder
    private var details: some View {
        if let track = store.nowPlaying {
            let composer = library.composer(of: track)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(track, showsAuthor: composer == nil)
                    if let composer {
                        ComposerCard(composer: composer, tunePath: track.path)
                    }
                    if let stil = store.stil {
                        InspectorSection("About This Tune") {
                            StilNotesView(stil: stil, songs: track.songs)
                        }
                    }
                    InspectorSection("Details") {
                        specs(of: track)
                    }
                }
                .padding([.horizontal, .bottom], 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Pinned like the playlist column: content must not decide the
            // inspector column's width.
            .frame(minWidth: 0, maxWidth: .infinity)
            // The composer card matches composers against the MUSICIANS list.
            .task(id: store.hvscRoot) { await library.loadAuthors(.musicians) }
        } else {
            ContentUnavailableView {
                Label("Not Playing", systemImage: "waveform")
            } description: {
                Text("Double-click a tune to play it. Its details and STIL commentary appear here.")
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Where it's playing from (with a way to keep it), the title, who
    /// released it when, then how long it runs and which of several songs
    /// is on. The author too, when no composer card names them.
    private func header(_ track: TrackDetails, showsAuthor: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                source
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                playlistStatus(track)
            }
            .padding(.bottom, 2)
            Text(track.title)
                .font(.title2.weight(.semibold))
            if showsAuthor {
                Text(track.author)
            }
            if let released = Self.released(track.released) {
                Text(released)
                    .foregroundStyle(.secondary)
            }
            let duration = store.duration.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) }
            if duration != nil || track.songs > 1 {
                // Each fact keeps to one line; there's room for both.
                HStack(spacing: 14) {
                    if let duration {
                        Label(duration, systemImage: "clock")
                            .fixedSize()
                            .help("Length")
                    }
                    if track.songs > 1 {
                        Label("Song \(track.currentSong) of \(track.songs)", systemImage: "list.number")
                            .fixedSize()
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 5)
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 4)
    }

    /// The header's released field in words: "1985 Gremlin Graphics" →
    /// "Released 1985 by Gremlin Graphics". It holds a year, then the
    /// publisher, group or party that put the tune out; either may be
    /// missing, and "<?>" means nothing is known.
    nonisolated static func released(_ field: String) -> String? {
        switch releasedParts(field) {
        case let (year?, by?): return "Released \(year) by \(by)"
        case let (year?, nil): return "Released \(year)"
        case let (nil, by?): return "Released by \(by)"
        case (nil, nil): return nil
        }
    }

    /// The released field's year and who put the tune out, either nil when
    /// unknown.
    nonisolated static func releasedParts(_ field: String) -> (year: String?, by: String?) {
        let parts = field.split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return (nil, nil) }
        // "1985", "198?", "1987-88"; "19??" and "????" say nothing.
        let isYear = first.allSatisfy { $0.isNumber || "?-/".contains($0) }
        let year = isYear && first.filter(\.isNumber).count >= 3 ? first : nil
        let by = (isYear ? parts.dropFirst().first : field.trimmingCharacters(in: .whitespaces))
            .flatMap { $0.isEmpty || $0 == "<?>" ? nil : $0 }
        return (year, by)
    }

    /// Which list Next and Previous walk.
    @ViewBuilder
    private var source: some View {
        if store.surpriseActive {
            Label("Surprise Me", systemImage: "dice.fill")
                .foregroundStyle(.tint)
                .help("Next plays another random tune from HVSC. Play anything else to stop.")
        } else if store.queueActive {
            Label("From HVSC", systemImage: "books.vertical")
        } else {
            Label("From Playlist", systemImage: "music.note.list")
        }
    }

    /// Keep what's playing — a surprise, or any tune played from the
    /// library. Once it's kept, a label says so (a disabled button would
    /// show no tooltip); nothing at all when it's playing from the playlist.
    @ViewBuilder
    private func playlistStatus(_ track: TrackDetails) -> some View {
        if !store.rows.contains(where: { $0.id == track.path }) {
            Button("Add to Playlist", systemImage: "plus") {
                store.add([URL(filePath: track.path)])
            }
            .controlSize(.small)
            .help("Add this tune to your playlist")
        } else if store.queueActive || store.surpriseActive {
            Label("In Playlist", systemImage: "checkmark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("This tune is already in your playlist")
        }
    }

    /// The tune's format, SID model, clock and chip count side by side,
    /// then its file.
    private func specs(of track: TrackDetails) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                spec("Format", track.isRsid ? "RSID" : "PSID")
                Divider()
                spec("SID", track.chipModel.short)
                    .help(track.chipModel.full)
                Divider()
                spec("Clock", track.isPal ? "PAL" : "NTSC")
                Divider()
                spec("Chips", "\(track.numSids)")
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: track.path)])
            }
            .controlSize(.small)
            .help("Show \(URL(filePath: track.path).lastPathComponent) in Finder")
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func spec(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

nonisolated extension TrackDetails {
    /// The SID chip the tune's header asks for: short for labels, in full
    /// for help text.
    var chipModel: (short: String, full: String) {
        switch sidModel {
        case 1: ("6581", "MOS 6581")
        case 2: ("8580", "MOS 8580")
        case 3: ("Either", "Plays on the 6581 or the 8580")
        default: ("—", "Not specified in the file")
        }
    }
}

/// A titled group of details on a rounded fill, like a grouped form's
/// section.
private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: .rect(cornerRadius: 10))
        }
    }
}

/// The inspector's links, all alike: text in the accent colour (`.link`
/// would be system blue).
private struct AccentLink: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .pointerStyle(.link)
    }
}

/// What STIL says about the playing subtune: the file's comment, then each
/// block, a cover as "Cover of … by …". Tunes the text names in MUSICIANS
/// lead to that tune in the browser.
struct StilNotesView: View {
    let stil: TuneStil
    /// How many songs the tune has: a block's "Song N" only says something
    /// when there are several.
    let songs: UInt16

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let comment = stil.comment {
                StilParagraph(comment)
            }
            ForEach(Array(stil.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .font(.callout)
        .padding(10)
    }

    private func blockView(_ block: StilBlock) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if block.subtune > 0, songs > 1 {
                Text("Song \(block.subtune)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let title = block.title {
                let covers = Self.covers(title: title, by: block.artist ?? block.author)
                ForEach(Array(covers.enumerated()), id: \.offset) { index, cover in
                    Text("\(Text("Cover of").foregroundStyle(.secondary)) \(cover.title)")
                        .padding(.top, index > 0 ? 4 : 0)
                    if let by = cover.by {
                        Text("by \(by)").foregroundStyle(.secondary)
                    }
                }
                if block.artist != nil, let author = block.author {
                    Text("written by \(author)").foregroundStyle(.secondary)
                }
            } else if let author = block.author {
                Text("\(Text("Original by").foregroundStyle(.secondary)) \(author)")
            }
            if let name = block.name {
                Text("Also known as \(name)").foregroundStyle(.secondary)
            }
            if let comment = block.comment {
                StilParagraph(comment)
                    .padding(.top, block.title == nil && block.name == nil ? 0 : 6)
            }
        }
    }

    /// A piece a block covers, and who performed (or wrote) it.
    nonisolated struct Cover: Equatable {
        /// One title, or several on lines of their own.
        let title: String
        let by: String?
    }

    /// The pieces a block's TITLE names, each with its ARTIST (or AUTHOR).
    /// A block covering several pieces repeats those fields, which arrive
    /// joined by newlines: one performer of all the titles is named once,
    /// under them all, and as many performers as titles pair up line by
    /// line. Anything else stays as STIL has it.
    nonisolated static func covers(title: String, by: String?) -> [Cover] {
        let titles = lines(title)
        let performers = by.map(lines) ?? []
        if Set(performers).count == 1 {
            return [Cover(title: title, by: performers[0])]
        }
        if titles.count > 1, performers.count == titles.count {
            return zip(titles, performers).map { Cover(title: $0, by: $1) }
        }
        return [Cover(title: title, by: by)]
    }

    private nonisolated static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// STIL text with the tunes it names shortened to their file names.
/// One tune in the library (nearly always) is accent-coloured in place,
/// and the whole paragraph is its button. Several get an AccentLink each
/// below the text: SwiftUI colours text links its own blue, whatever the
/// tint.
private struct StilParagraph: View {
    let text: String

    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        let references = Self.tuneReferences(in: text)
        let targets = references.filter(\.inLibrary)
        if targets.count == 1 {
            Button {
                reveal(path: targets[0].path)
            } label: {
                Self.render(text, references, highlighted: true)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Show \(targets[0].name) in the library")
            // A click goes to the tune, not into the text.
            .textSelection(.disabled)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Self.render(text, references, highlighted: false)
                ForEach(targets, id: \.path) { target in
                    AccentLink(target.name) { reveal(path: target.path) }
                }
            }
        }
    }

    /// How many characters `text` shows, its tunes shortened.
    static func length(of text: String) -> Int {
        tuneReferences(in: text).reduce(text.count) { $0 - $1.path.count + $1.name.count }
    }

    /// A tune path in STIL text: "/MUSICIANS/H/Hubbard_Rob/Lightforce.sid".
    private struct TuneReference {
        let range: Range<String.Index>
        let path: String

        var name: String { URL(filePath: path).lastPathComponent }
        /// The browser only shows composers' folders, not GAMES or DEMOS.
        var inLibrary: Bool { path.hasPrefix("/MUSICIANS/") }
    }

    private static func tuneReferences(in text: String) -> [TuneReference] {
        text.matches(of: #/\/(?:MUSICIANS|GAMES|DEMOS)\/[^\s"(),;]+?\.sid/#).map {
            TuneReference(range: $0.range, path: String($0.output))
        }
    }

    private static func render(_ text: String, _ references: [TuneReference], highlighted: Bool) -> Text {
        var result = Text(verbatim: "")
        var start = text.startIndex
        for reference in references {
            let before = Text(verbatim: String(text[start..<reference.range.lowerBound]))
            result = Text("\(result)\(before)\(name(of: reference, highlighted: highlighted))")
            start = reference.range.upperBound
        }
        return Text("\(result)\(Text(verbatim: String(text[start...])))")
    }

    private static func name(of reference: TuneReference, highlighted: Bool) -> Text {
        guard highlighted, reference.inLibrary else { return Text(verbatim: reference.name) }
        return Text(verbatim: reference.name).foregroundStyle(.tint)
    }

    private func reveal(path: String) {
        guard let root = store.hvscRoot else { return }
        let tune = URL(filePath: root).appending(path: path.trimmingPrefix("/"))
        library.reveal = LibraryReveal(
            authorPath: tune.deletingLastPathComponent().path,
            tunePath: tune.path
        )
    }
}

/// Who wrote what's playing: their name, a way to all their tunes, and
/// STIL's note on them when it has one, the tunes it names leading to the
/// browser. Tinted so it stands apart from the plain sections around it;
/// the monogram is where a photo would go.
private struct ComposerCard: View {
    let composer: Composer
    let tunePath: String

    @Environment(LibraryStore.self) private var library
    @State private var expanded = false

    /// Notes longer than this start folded to `foldedLines`. Half are a
    /// single line; a few run to a dozen.
    private static let foldLength = 240
    private static let foldedLines = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                monogram
                VStack(alignment: .leading, spacing: 1) {
                    Text(composer.name)
                        .font(.headline)
                    if let subtitle = composer.subtitle {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                    }
                    if let path = composer.authorPath {
                        AccentLink("Show All Tunes") {
                            library.reveal = LibraryReveal(authorPath: path, tunePath: tunePath)
                        }
                        .help("Show all tunes by \(composer.name)")
                    } else if library.hasRoot {
                        // No folder: the tunes whose header credits them.
                        AccentLink("Show All Tunes") {
                            library.credits = LibraryCredits(
                                name: composer.name,
                                category: library.category(of: tunePath) ?? .musicians
                            )
                        }
                        .help("Show all tunes credited to \(composer.name)")
                    }
                }
            }
            if let path = composer.authorPath, let note = library.authorNotes[path], !note.isEmpty {
                let folds = StilParagraph.length(of: note) > Self.foldLength
                StilParagraph(note)
                    .foregroundStyle(.secondary)
                    .lineLimit(folds && !expanded ? Self.foldedLines : nil)
                    .textSelection(.enabled)
                if folds {
                    AccentLink(expanded ? "Less" : "More") { expanded.toggle() }
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.tint.opacity(0.12), in: .rect(cornerRadius: 10))
        .task(id: composer.authorPath) {
            expanded = false
            if let path = composer.authorPath {
                await library.loadAuthorNote(authorPath: path)
            }
        }
    }

    private var monogram: some View {
        ZStack {
            Circle().fill(.background)
            if composer.initials.isEmpty {
                Image(systemName: "person.fill")
            } else {
                Text(composer.initials)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(.tint)
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}

#Preview {
    NowPlayingInspector()
        .environment(PlayerStore.preview)
        .environment(LibraryStore(player: .preview))
        .frame(width: 300, height: 700)
}
