import PhosphorCore
import SwiftUI

// The large header over a section of Games or Demos.

/// The carousel's cards for a section.
nonisolated enum SectionCard: Hashable {
    case sound
    case longest
    case oldest
    case newest
    case releasers
}

/// A section's header, like a composer's. HVSC files composers with a tune or
/// two here, or none known, so there's no one to tell about: what it says is
/// what the tunes have in common, starting with when they were made.
struct SectionHeader: View {
    private let rows: [LibraryRow]
    private let source: PlaybackSource
    private let identity: SectionIdentity
    private let facts: SectionFacts

    @Environment(LibraryStore.self) private var library
    @Environment(FingerprintStore.self) private var fingerprints

    init(name: String, category: HvscCategory, rows: [LibraryRow], source: PlaybackSource) {
        self.rows = rows
        self.source = source
        identity = SectionIdentity(name: name, category: category)
        facts = SectionFacts(rows: rows)
    }

    private var tuneCount: String {
        ComposerFacts.tunes(rows.count, kind: identity.kind, firstYear: facts.years.first?.year,
                            lastYear: facts.years.last?.year)
    }

    var body: some View {
        // The list below asks for its rows' fingerprints; they arrive here too.
        let tags = rows.compactMap { fingerprints.fingerprint($0.id)?.tags }
        let shares = SectionFacts.soundShares(tags: tags, overall: fingerprints.tagShares, limit: 4)
        LargeHeader(title: identity.title, detail: tuneCount,
                    hasBio: !facts.years.isEmpty || facts.playingTime != nil,
                    cards: cards(hasSound: !shares.isEmpty)) {
            tile
        } below: {
            if let description = identity.description {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } bio: {
            bio
        } card: { card in
            self.card(card, shares: shares, scanned: tags.count)
        }
        .task(id: identity.title) { await fingerprints.loadTagShares() }
    }

    private func cards(hasSound: Bool) -> [SectionCard] {
        var cards: [SectionCard] = hasSound ? [.sound] : []
        if !facts.longest.isEmpty { cards.append(.longest) }
        if !facts.oldest.isEmpty { cards.append(.oldest) }
        if !facts.newest.isEmpty { cards.append(.newest) }
        if !facts.releasers.isEmpty { cards.append(.releasers) }
        return cards
    }

    /// The picture a composer's photo would be, with the section's label on it.
    private var tile: some View {
        ComposerPortrait(name: identity.title, looksUpPhoto: false, cornerRadius: 17)
            .overlay(alignment: .bottomLeading) {
                Text(identity.tile)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(8)
            }
    }

    private var bio: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !facts.years.isEmpty {
                YearChart(years: facts.years, summary: facts.busiestText ?? "")
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                headerFact("Playing time", facts.playingTime)
                headerFact("HVSC notes", facts.notes)
                headerFact("No exact year", facts.withoutExactYear)
            }
        }
        .font(.callout)
    }

    // MARK: Cards

    @ViewBuilder
    private func card(_ card: SectionCard, shares: [SoundShare], scanned: Int) -> some View {
        switch card {
        case .sound:
            SoundSharesCard(shares: shares, scanned: scanned, tunes: rows.count)
        case .longest:
            tuneList("Longest Tunes", facts.longest) { $0.lengthText }
        case .oldest:
            tuneList("Oldest Tunes", facts.oldest, detail: yearAndReleaser)
        case .newest:
            tuneList("Newest Tunes", facts.newest, detail: yearAndReleaser)
        case .releasers:
            HeaderCard("Released Most By") {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(facts.releasers, id: \.name) { releaser in
                            HStack(spacing: 8) {
                                Text(releaser.name)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text(releaser.tunes, format: .number)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    /// "1982, Comm*Data".
    private func yearAndReleaser(_ row: LibraryRow) -> String {
        [row.year, row.releaser].compactMap { $0 }.joined(separator: ", ")
    }

    /// Tunes to click: each plays from there on, as in the list below.
    private func tuneList(_ title: String, _ tunes: [LibraryRow], detail: @escaping (LibraryRow) -> String) -> some View {
        HeaderCard(title) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tunes) { row in
                        HStack(spacing: 8) {
                            AccentLink(row.title) { library.play(rows, startAt: row, from: source) }
                                .lineLimit(1)
                                .layoutPriority(1)
                                .help("Play \(row.title)")
                            Spacer(minLength: 6)
                            Text(detail(row))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .font(.callout)
        }
    }

}

/// A sound's share of a section as a bar, with a tick where it stands across
/// all of HVSC.
struct SoundShareRow: View {
    let share: SoundShare

    var body: some View {
        HStack(spacing: 6) {
            Text(share.tag.name)
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.fill.tertiary)
                    Capsule()
                        .fill(.tint)
                        .frame(width: max(proxy.size.width * share.share, 3))
                    if let overall = share.overall {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.primary)
                            .frame(width: 2, height: 10)
                            .offset(x: min(proxy.size.width * overall, proxy.size.width - 2))
                    }
                }
            }
            .frame(height: 6)
            Text(share.share, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let here = share.share.formatted(.percent.precision(.fractionLength(0)))
        guard let overall = share.overall else { return "\(share.tag.name): \(here) of tunes" }
        return "\(share.tag.name): \(here) of tunes, against \(overall.formatted(.percent.precision(.fractionLength(0)))) across HVSC"
    }
}

/// Tunes per year: a bar a year from first to last. The line above says the
/// busiest year, or whichever one the pointer is on.
struct YearChart: View {
    let years: [SectionFacts.YearCount]
    /// What the line above says when the pointer isn't on a bar.
    let summary: String

    @State private var hovered: SectionFacts.YearCount?

    private static var barsHeight: CGFloat { 72 }

    /// A section of a few years shouldn't get bars like billboards.
    private var widest: CGFloat { max(64, CGFloat(years.count) * 24) }

    private var most: Int { years.map(\.tunes).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hovered.map { "\($0.year): \(SectionFacts.tunes($0.tunes))" } ?? summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(years, id: \.year) { bar($0) }
                }
                .frame(height: Self.barsHeight)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(.separator)
                        .frame(height: 1)
                }
                HStack {
                    if let first = years.first {
                        Text(verbatim: "\(first.year)")
                    }
                    Spacer(minLength: 4)
                    if let last = years.last, years.count > 1 {
                        Text(verbatim: "\(last.year)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: widest, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// The whole column is the bar's to hover, however short the bar is.
    private func bar(_ year: SectionFacts.YearCount) -> some View {
        UnevenRoundedRectangle(cornerRadii: .init(topLeading: 1.5, topTrailing: 1.5))
            .fill(hovered == year ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
            .frame(height: height(of: year))
            .padding(.horizontal, 0.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .contentShape(.rect)
            .onHover { inside in
                if inside {
                    hovered = year
                } else if hovered == year {
                    hovered = nil
                }
            }
    }

    /// A year with a single tune still shows.
    private func height(of year: SectionFacts.YearCount) -> CGFloat {
        guard year.tunes > 0, most > 0 else { return 0 }
        return max(2, Self.barsHeight * CGFloat(year.tunes) / CGFloat(most))
    }

    private var accessibilityText: String {
        guard let first = years.first, let last = years.last else { return summary }
        return "Tunes per year from \(first.year) to \(last.year). \(summary)"
    }
}
