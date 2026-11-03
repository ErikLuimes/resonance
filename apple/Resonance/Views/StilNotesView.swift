import AppKit
import SwiftUI
import PhosphorCore
import STILKit

/// What STIL says about the playing tune, under the composer card: a card
/// for the whole file, then one for the song that's playing. The composer's
/// own words are set as a quote with a byline, the STIL editors' notes as
/// plain text. Tunes the notes name lead to the library.
struct StilNotesView: View {
    let entry: STILEntry
    let track: TrackDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(Self.cards(entry, song: Int(track.currentSong), songs: Int(track.songs)).enumerated()), id: \.offset) { _, card in
                switch card {
                case .memorial(let memorial):
                    MemorialCard(memorial: memorial)
                case .section(let section, let heading):
                    StilSectionCard(section: section, heading: heading)
                case .noNotes(let song):
                    NoSongNotesCard(song: song)
                }
            }
        }
        .stilLinks(entry)
    }

    /// One card in the notes.
    nonisolated enum Card: Equatable {
        /// Someone STIL remembers, at the top.
        case memorial(STILMemorial)
        case section(STILSection, heading: Heading)
        /// STIL has notes on other songs, not on this one.
        case noNotes(song: Int)
    }

    nonisolated enum Heading: Equatable {
        /// About the whole file: in the composer's words when it opens with
        /// a quote.
        case file(quote: Bool)
        case song(Int)
    }

    /// The cards for `song` of `songs`: remembrances first, then the whole
    /// file's notes, then the song's own (or a word that it has none, when
    /// other songs do).
    nonisolated static func cards(_ full: STILEntry, song: Int, songs: Int) -> [Card] {
        let (memorials, entry) = full.splittingMemorials()
        var cards: [Card] = memorials.map(Card.memorial)
        var sections: [(STILSection, Heading?)] = entry.sections.filter { $0.subtune == nil }.map { ($0, nil) }
        let own = entry.sections.first { $0.subtune == song }
        if let own {
            sections.append((own, songs > 1 ? .song(song) : nil))
        }
        for (section, heading) in sections {
            let rest = section
            if case .song(let n) = heading, rest.isEmpty {
                cards.append(.noNotes(song: n))
            } else if !rest.isEmpty {
                let opensWithQuote = rest.covers.isEmpty && rest.comments.first?.blocks.first?.kind == .quote
                cards.append(.section(rest, heading: heading ?? .file(quote: opensWithQuote)))
            }
        }
        if own == nil, songs > 1, entry.sections.contains(where: { $0.subtune != nil }) {
            cards.append(.noNotes(song: song))
        }
        return cards
    }
}

private nonisolated extension STILSection {
    var isEmpty: Bool { names.isEmpty && authors.isEmpty && covers.isEmpty && comments.isEmpty }
}

/// Every comment of an entry, without cards: STIL's note on an author
/// folder, in the composer card.
struct StilCommentsView: View {
    let entry: STILEntry

    var body: some View {
        let (memorials, rest) = entry.splittingMemorials()
        VStack(alignment: .leading, spacing: 10) {
            ForEach(memorials, id: \.name) { MemorialCard(memorial: $0) }
            StilBlocksView(blocks: rest.sections.flatMap(\.comments).flatMap(\.blocks), spacing: 10)
        }
        .stilLinks(entry)
    }
}

private struct StilLinks: ViewModifier {
    let entry: STILEntry

    @Environment(LibraryStore.self) private var library

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard let path = StilLink.path(url) else { return .systemAction }
                library.reveal(hvscPath: path)
                return .handled
            })
            // Titles for the tunes the text links to.
            .task(id: entry.path) {
                for link in entry.links.sorted() {
                    await library.loadLinkedTune(link)
                }
            }
    }
}

private extension View {
    /// Tunes STIL text links to open in the library, by their titles; web
    /// addresses open in the browser.
    func stilLinks(_ entry: STILEntry) -> some View {
        modifier(StilLinks(entry: entry))
    }
}

// MARK: - Cards

/// A section of STIL on a rounded fill: what it covers, who wrote it, and
/// its comments.
private struct StilSectionCard: View {
    let section: STILSection
    let heading: StilNotesView.Heading

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !section.names.isEmpty || !section.authors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(section.names, id: \.self) { Text("Also known as \($0)") }
                    ForEach(section.authors, id: \.self) { Text("Written by \($0)") }
                }
                .foregroundStyle(.secondary)
            }
            if !section.covers.isEmpty {
                CoversView(covers: section.covers, isMedley: section.isMedley)
            }
            ForEach(Array(section.comments.enumerated()), id: \.offset) { _, comment in
                StilBlocksView(blocks: comment.blocks, spacing: 12)
            }
        }
        .stilCard()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            switch heading {
            case .file(let quote):
                StilOverline(quote ? "In Their Words" : "About This Tune")
            case .song(let song):
                Text("Song \(song)")
                    .font(.headline)
            }
            Spacer()
            Text(verbatim: "STIL")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .help("From the SID Tune Information List")
        }
    }
}

/// Someone remembered, set like an epitaph: centred and unframed, a thin
/// candle flame, the name in the quotes' serif, and when it happened.
struct MemorialCard: View {
    let memorial: STILMemorial

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "flame")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
                .accessibilityHidden(true)
            Text(memorial.name)
                .font(.system(size: 17, design: .serif))
                .foregroundStyle(.primary)
            Text(Self.passed(memorial.details))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("In memory of \(memorial.name). \(Self.passed(memorial.details))")
    }

    /// "On May 6th, 2011." → "Passed away on May 6th, 2011".
    nonisolated static func passed(_ details: String?) -> String {
        guard var details, !details.isEmpty else { return "Passed away" }
        if details.hasSuffix(".") { details.removeLast() }
        return "Passed away " + details.prefix(1).lowercased() + details.dropFirst()
    }
}

/// The playing song has no notes of its own, though others do.
private struct NoSongNotesCard: View {
    let song: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Song \(song)")
                .font(.headline)
            Text("No notes for this song yet.")
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }
}

/// A small heading inside a card: "IN THEIR WORDS".
private struct StilOverline: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

private extension View {
    /// The notes' cards: the inspector's rounded fill.
    func stilCard() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: .rect(cornerRadius: 10))
    }
}

// MARK: - Blocks

/// A comment's blocks in order, with each interview question and the
/// answer after it set together as a transcript.
private struct StilBlocksView: View {
    let blocks: [STILBlock]
    let spacing: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(Self.items(blocks).enumerated()), id: \.offset) { _, item in
                switch item {
                case .block(let block):
                    StilBlockView(block: block)
                case .interview(let exchanges):
                    StilTranscript(exchanges: exchanges)
                }
            }
        }
    }

    enum Item {
        case block(STILBlock)
        case interview([StilTranscript.Exchange])
    }

    /// Questions take the quote after them as their answer; questions in a
    /// row of exchanges make one transcript.
    nonisolated static func items(_ blocks: [STILBlock]) -> [Item] {
        var items: [Item] = []
        var i = 0
        while i < blocks.count {
            let block = blocks[i]
            guard block.kind == .question else {
                items.append(.block(block))
                i += 1
                continue
            }
            let answer = i + 1 < blocks.count && blocks[i + 1].kind == .quote ? blocks[i + 1] : nil
            let exchange = StilTranscript.Exchange(question: block, answer: answer)
            if case .interview(let exchanges) = items.last {
                items[items.count - 1] = .interview(exchanges + [exchange])
            } else {
                items.append(.interview([exchange]))
            }
            i += answer == nil ? 1 : 2
        }
        return items
    }
}

/// An interview in STIL: who speaks sits in a narrow left column, the
/// question muted beside "STIL" (its editors ask), the answer in the
/// speaker's serif voice beside their initials. Same size and line height
/// as the quotes.
private struct StilTranscript: View {
    struct Exchange {
        let question: STILBlock
        let answer: STILBlock?
    }

    let exchanges: [Exchange]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(exchanges.enumerated()), id: \.offset) { index, exchange in
                if index > 0 { Divider() }
                Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text(verbatim: "STIL")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 28, alignment: .trailing)
                            .padding(.top, 2)
                            .accessibilityLabel("Question")
                        paragraphs(exchange.question.paragraphs, style: .question)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let answer = exchange.answer {
                        GridRow {
                            Monogram(name: answer.by ?? "A")
                                .help(answer.by.map { answer.role == .composer ? "\($0), composer" : $0 } ?? "Answer")
                            AnswerView(answer: answer)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private func paragraphs(_ paragraphs: [[STILRun]], style: StilText.Style) -> some View {
        VStack(alignment: .leading, spacing: style.paragraphSpacing) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, runs in
                StilText(runs: runs, style: style)
            }
        }
        .textSelection(.enabled)
    }
}

/// An interview answer in curly quotes, folded like a quote when it's long.
private struct AnswerView: View {
    let answer: STILBlock

    @State private var expanded = false

    var body: some View {
        let folds = answer.paragraphs.reduce(0) { $0 + $1.reduce(0) { $0 + $1.t.count } } > StilBlockView.foldLength
        let folded = folds && !expanded
        let quoted = Self.quoted(answer.paragraphs)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: StilText.Style.quote.paragraphSpacing) {
                ForEach(Array((folded ? Array(quoted.prefix(1)) : quoted).enumerated()), id: \.offset) { _, runs in
                    StilText(runs: runs, style: .quote)
                        .lineLimit(folded ? StilBlockView.foldedLines : nil)
                }
            }
            .textSelection(.enabled)
            if folds {
                AccentLink(expanded ? "Show Less" : "Read More") { expanded.toggle() }
            }
        }
    }

    /// The answer's paragraphs between “ and ”.
    nonisolated static func quoted(_ paragraphs: [[STILRun]]) -> [[STILRun]] {
        guard !paragraphs.isEmpty else { return paragraphs }
        var out = paragraphs
        out[0].insert(STILRun(t: "\u{201C}"), at: 0)
        out[out.count - 1].append(STILRun(t: "\u{201D}"))
        return out
    }
}

/// One stretch of a comment: the STIL editors' note in plain text, or a
/// quote in serif with who said it. Long ones start folded.
private struct StilBlockView: View {
    let block: STILBlock

    @State private var expanded = false

    /// Blocks longer than this fold to their first paragraph, at most
    /// `foldedLines` lines of it.
    static let foldLength = 280
    static let foldedLines = 5

    var body: some View {
        let folds = block.paragraphs.reduce(0) { $0 + $1.reduce(0) { $0 + $1.t.count } } > Self.foldLength
        let folded = folds && !expanded
        let paragraphs = folded ? Array(block.paragraphs.prefix(1)) : block.paragraphs
        switch block.kind {
        case .note:
            VStack(alignment: .leading, spacing: 8) {
                if !folded, let relation = RelationLink(paragraphs.first) {
                    RelationCard(relation: relation)
                    text(Array(paragraphs.dropFirst()), style: .note, folded: false)
                } else {
                    text(paragraphs, style: .note, folded: folded)
                }
                if folds { foldLink }
            }
        case .question:
            // Only reaches here without the transcript around it.
            text(paragraphs, style: .question, folded: false)
        case .quote:
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 6) {
                    Text(verbatim: "\u{201C}")
                        .font(.system(size: 22, design: .serif))
                        .foregroundStyle(.tint)
                        .frame(height: 15, alignment: .top)
                        .accessibilityHidden(true)
                    text(paragraphs, style: .quote, folded: folded)
                }
                HStack(alignment: .center) {
                    if let by = block.by {
                        Byline(name: by, isComposer: block.role == .composer)
                    }
                    Spacer()
                    if folds { foldLink }
                }
                // The tracker the lead-in names ("SW1.8 "…" (NP)").
                if let label = block.label {
                    Text("Made with \(label)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func text(_ paragraphs: [[STILRun]], style: StilText.Style, folded: Bool) -> some View {
        VStack(alignment: .leading, spacing: style.paragraphSpacing) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, runs in
                StilText(runs: runs, style: style)
                    .lineLimit(folded ? Self.foldedLines : nil)
            }
        }
        .textSelection(.enabled)
    }

    private var foldLink: some View {
        AccentLink(expanded ? "Show Less" : "Read More") { expanded.toggle() }
    }
}

/// Who a quote is from: their initials, name, and "Composer" when it's the
/// tune's own composer.
private struct Byline: View {
    let name: String
    let isComposer: Bool

    var body: some View {
        HStack(spacing: 8) {
            Monogram(name: name)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.callout.weight(.semibold))
                if isComposer {
                    Text("Composer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "Rob Hubbard" → "RH"; initials STIL couldn't resolve stay as they are.
    nonisolated static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count == 1, words[0].count <= 4, words[0] == words[0].uppercased() {
            return String(words[0])
        }
        let picked = words.count > 1 ? [words[0], words[words.count - 1]] : words
        return String(picked.compactMap(\.first)).uppercased()
    }
}

/// Someone's initials in a small tinted circle.
private struct Monogram: View {
    let name: String

    var body: some View {
        Text(Byline.initials(name))
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.tint)
            .frame(width: 28, height: 28)
            .background(.tint.opacity(0.16), in: .circle)
    }
}

// MARK: - Text

/// A paragraph of STIL: tunes it names as links to the library (by their
/// title), web addresses as links, chip models and addresses in monospace.
private struct StilText: View {
    let runs: [STILRun]
    let style: Style

    @Environment(LibraryStore.self) private var library

    enum Style {
        case note
        case quote
        /// An interviewer's question: the note face, in italics and muted.
        case question

        /// Quotes differ from notes in face only, not size.
        var size: CGFloat { NSFont.systemFontSize }

        var design: Font.Design {
            switch self {
            case .note, .question: .default
            case .quote: .serif
            }
        }

        var paragraphSpacing: CGFloat { 6 }
    }

    var body: some View {
        Text(attributed)
            .font(.system(size: style.size, design: style.design))
            .italic(style == .question)
            .foregroundStyle(style == .question ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            // New York runs taller than SF; one line height keeps quotes and
            // notes alike.
            .lineHeight(.exact(points: (style.size * 1.3).rounded()))
            .tint(Color.accentColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var text = AttributedString()
        for run in runs {
            var piece: AttributedString
            if let path = run.link {
                let title = library.linkedTunes[path]??.title ?? LinkedTune.fallbackTitle(path)
                piece = AttributedString(title)
                piece.link = StilLink.url(path)
                piece.font = .system(size: style.size, weight: .semibold, design: style.design)
            } else if let url = run.url {
                piece = AttributedString(run.t)
                piece.link = URL(string: url)
            } else if run.tech == true {
                piece = AttributedString(run.t)
                piece.font = .system(size: (style.size * 0.85).rounded(), design: .monospaced)
                piece.foregroundColor = .secondary
            } else if run.em == true {
                piece = AttributedString(run.t)
                piece.font = .system(size: style.size, design: style.design).italic()
            } else {
                piece = AttributedString(run.t)
            }
            text += piece
        }
        return text
    }
}

/// Links to tunes inside STIL text, which the notes' `openURL` action
/// turns into library reveals.
nonisolated enum StilLink {
    static let scheme = "resonance-stil"

    static func url(_ hvscPath: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.path = hvscPath
        return components.url
    }

    static func path(_ url: URL) -> String? {
        url.scheme == scheme ? url.path : nil
    }
}

/// A note that is only a relation and a tune — "Remix of /MUSICIANS/…" —
/// shows the tune as a card of its own.
nonisolated struct RelationLink: Equatable {
    /// "Remix of".
    let relation: String
    let hvscPath: String

    private static let relations = ["remix of", "same as", "covers", "inspired by", "see also", "edit of", "based on"]

    init?(_ runs: [STILRun]?) {
        guard let runs, runs.count >= 2, let path = runs[1].link else { return nil }
        let lead = runs[0].t.trimmingCharacters(in: .whitespaces)
        guard runs[0].link == nil, Self.relations.contains(lead.lowercased()) else { return nil }
        // Anything after the link beyond punctuation stays a sentence.
        let tail = runs.dropFirst(2).map(\.t).joined()
        guard tail.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) else { return nil }
        relation = lead
        hvscPath = path
    }
}

/// The tune a note relates this one to, with who wrote it; a click shows
/// it in the library.
private struct RelationCard: View {
    let relation: RelationLink

    @Environment(LibraryStore.self) private var library

    var body: some View {
        let tune = library.linkedTunes[relation.hvscPath] ?? nil
        let title = tune?.title ?? LinkedTune.fallbackTitle(relation.hvscPath)
        VStack(alignment: .leading, spacing: 6) {
            StilOverline(LocalizedStringKey(relation.relation))
            Button {
                library.reveal(hvscPath: relation.hvscPath)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .fontWeight(.semibold)
                            .foregroundStyle(.tint)
                        if let author = tune?.author, !author.isEmpty, author != "<?>" {
                            Text(author)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The card opens the tune.
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.tertiary, in: .rect(cornerRadius: 8))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Show \(title) in the library")
        }
    }
}

// MARK: - Covers

/// What a section covers: a chip, then each piece and who wrote it, or
/// for a medley the parts on a timeline.
private struct CoversView: View {
    let covers: [STILCover]
    let isMedley: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                CoverChip(arcade: covers.allSatisfy { $0.source?.hasPrefix("the arcade game") == true })
                if isMedley {
                    Text(Self.medleyLine(covers))
                        .foregroundStyle(.secondary)
                } else if covers.count == 1 {
                    Self.line(covers[0])
                }
            }
            if isMedley {
                MedleyTimeline(covers: covers)
                ForEach(Array(covers.filter { $0.at == nil }.enumerated()), id: \.offset) { _, cover in
                    Self.line(cover)
                }
            } else if covers.count > 1 {
                ForEach(Array(covers.enumerated()), id: \.offset) { _, cover in
                    Self.line(cover)
                }
            }
        }
    }

    /// "*BGM1* from the arcade game Commando, by Tamayo Kawamoto".
    static func line(_ cover: STILCover) -> Text {
        var text: Text
        if let title = cover.title {
            text = Text(title).italic()
        } else if cover.unknown {
            text = Text("Title unknown").foregroundStyle(.secondary)
        } else {
            text = Text(verbatim: "")
        }
        let named = cover.title != nil || cover.unknown
        if let source = cover.source {
            text = Text("\(text)\(named ? " from " : "From ")\(source)")
        }
        if let artist = cover.artist {
            text = Text("\(text)\(named || cover.source != nil ? ", by " : "A tune by ")\(artist)")
        }
        if let at = cover.at {
            let range = cover.until.map { "\(Self.time(at))–\(Self.time($0))" } ?? Self.time(at)
            text = Text("\(text) \(Text(range).monospacedDigit().foregroundStyle(.secondary))")
        }
        return text
    }

    /// "A medley from the arcade game Commando, music by Tamayo Kawamoto".
    nonisolated static func medleyLine(_ covers: [STILCover]) -> String {
        let timed = covers.filter { $0.at != nil }
        let sources = Set(timed.map(\.source))
        let artists = Set(timed.map(\.artist))
        var line = "A medley"
        if sources.count == 1, let source = sources.first ?? nil {
            line += " from \(source)"
        } else {
            line += " of \(timed.count) parts"
        }
        if artists.count == 1, let artist = artists.first ?? nil {
            line += ", music by \(artist)"
        }
        return line
    }

    nonisolated static func time(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

/// "Cover", or "Arcade Cover" when it's from an arcade game.
struct CoverChip: View {
    let arcade: Bool

    var body: some View {
        Text(arcade ? "Arcade Cover" : "Cover")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.16), in: .capsule)
            .fixedSize()
    }
}

/// A medley's parts along the song, the one playing highlighted. The bar
/// needs the song's length; without it there's only the list.
private struct MedleyTimeline: View {
    let covers: [STILCover]

    @Environment(PlayerStore.self) private var store

    var body: some View {
        let length = store.duration.map { Int($0.rounded()) }.flatMap { $0 > 0 ? $0 : nil }
        let segments = STILEnricher.medleySegments(covers, songLength: length)
        let elapsed = Int(store.elapsed)
        let active = segments.lastIndex { elapsed >= $0.start && elapsed < ($0.end ?? .max) }
        VStack(alignment: .leading, spacing: 8) {
            if let length {
                VStack(spacing: 3) {
                    bar(segments, length: length, active: active)
                    HStack {
                        Text(verbatim: CoversView.time(0))
                        Spacer()
                        Text(verbatim: CoversView.time(length))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
                .accessibilityHidden(true)
            }
            VStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    row(segment, isActive: index == active)
                }
            }
        }
    }

    private func bar(_ segments: [STILMedleySegment], length: Int, active: Int?) -> some View {
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 5), with: .style(.fill.secondary))
            let scale = size.width / CGFloat(length)
            for (index, segment) in segments.enumerated() {
                let end = min(segment.end ?? length, length)
                guard end > segment.start else { continue }
                let rect = CGRect(x: CGFloat(segment.start) * scale, y: 4, width: max(CGFloat(end - segment.start) * scale - 1, 1), height: size.height - 8)
                let color = index == active ? Color.stilCoverActive : Color.stilCover
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
            }
            let x = min(CGFloat(store.elapsed) * scale, size.width - 2)
            context.fill(Path(CGRect(x: x, y: 0, width: 2, height: size.height)), with: .style(.primary))
        }
        .frame(height: 22)
    }

    private func row(_ segment: STILMedleySegment, isActive: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.stilCover)
                .frame(width: 8, height: 8)
            Text(segment.title)
                .fontWeight(isActive ? .semibold : .regular)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(segment.end.map { "\(CoversView.time(segment.start))–\(CoversView.time($0))" } ?? "from \(CoversView.time(segment.start))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
        .background(isActive ? Color.stilCover.opacity(0.16) : .clear, in: .rect(cornerRadius: 6))
    }
}

extension Color {
    /// A medley's parts: quiet grey, a stronger grey for the one that's
    /// playing.
    static let stilCover = Color(nsColor: .tertiaryLabelColor)
    static let stilCoverActive = Color(nsColor: .secondaryLabelColor)
}
