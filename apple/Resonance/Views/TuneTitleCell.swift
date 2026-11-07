import SwiftUI
import STILKit

/// A tune list's title cell: the title, a Cover chip when STIL says the
/// tune covers something, and under it STIL's teaser, the first sentence
/// of its notes. A composer's words are set in serif italics with their
/// name ("“There is an interesting story behind Commando.” — Rob Hubbard"),
/// the editors' notes plainly. Tunes without STIL keep one line.
struct TuneTitleCell: View {
    /// Passed in, not read from the environment: table rows built while a
    /// list scrolls didn't always get it, and reading it there crashed.
    let library: LibraryStore
    let path: String
    let title: String
    /// The header's author, which tells whose voice a quote is in.
    let author: String
    let isCurrent: Bool
    /// False when the library already knows the tune has no STIL entry.
    var mayHaveStil = true
    /// STIL's first line under the title. Rows with a line of their own there
    /// leave it out.
    var showsTeaser = true
    /// Always bold, for rows that set their title apart from a line under it.
    var isBold = false

    var body: some View {
        let entry = library.stil[path] ?? nil
        VStack(alignment: .leading, spacing: 2) {
            // The chip only beside a title it leaves whole.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    titleText.fixedSize()
                    if let entry, let covers = Self.covers(entry) {
                        CoverChip(arcade: covers.allSatisfy { $0.source?.hasPrefix("the arcade game") == true })
                    }
                }
                titleText
            }
            if showsTeaser, let entry, let teaser = Teaser(entry) {
                teaser.text
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(teaser.plain)
            }
        }
        .padding(.vertical, 2)
        .task(id: path) {
            if mayHaveStil {
                await library.loadStil(path: path, sidAuthor: author)
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .fontWeight(isCurrent || isBold ? .semibold : .regular)
            .lineLimit(1)
    }

    /// The covers STIL names, on the whole file or any of its songs.
    nonisolated static func covers(_ entry: STILEntry) -> [STILCover]? {
        let covers = entry.sections.flatMap(\.covers)
        return covers.isEmpty ? nil : covers
    }
}

/// The first thing STIL says about a tune, for a list's second line.
nonisolated struct Teaser: Equatable {
    /// The sentence, typeset.
    let sentence: String
    /// Who said it, for a quote; nil for the editors' notes.
    let by: String?
    let isQuote: Bool

    /// From the whole file's notes first, else the first song with any;
    /// memorials and empty comments are skipped.
    init?(_ entry: STILEntry) {
        let sections = entry.sections.filter { $0.subtune == nil } + entry.sections.filter { $0.subtune != nil }
        guard let comment = sections.lazy.flatMap(\.comments).first(where: { !$0.teaser.isEmpty && !$0.memoriam }),
              let block = comment.blocks.first
        else { return nil }
        sentence = comment.teaser
        isQuote = block.kind == .quote
        by = isQuote ? block.by : nil
    }

    /// "“There is an interesting story behind Commando.” — Rob Hubbard".
    var plain: String {
        guard isQuote else { return sentence }
        return "\u{201C}\(sentence)\u{201D}" + (by.map { " \u{2014} \($0)" } ?? "")
    }

    var text: Text {
        guard isQuote else { return Text(sentence) }
        return Text("\u{201C}\(sentence)\u{201D}").font(.system(.body, design: .serif).italic())
            + Text(by.map { " \u{2014} \($0)" } ?? "")
    }
}
