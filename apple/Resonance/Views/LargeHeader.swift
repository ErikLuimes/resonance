import SwiftUI

// The header over a list of tunes: a composer's, or a section of Games
// or Demos.

// MARK: - The carousel's pages

nonisolated enum HeaderCards {
    /// How many cards share a carousel this wide: each gets room to read, and
    /// a few cards share the width rather than leave a gap beside them.
    static func perPage(width: CGFloat, cards: Int) -> Int {
        min(max(Int(width / 230), 1), 3, max(cards, 1))
    }

    /// The cards shown together on each page.
    static func pages<Card>(_ cards: [Card], perPage: Int) -> [[Card]] {
        let size = max(perPage, 1)
        return stride(from: 0, to: cards.count, by: size).map { Array(cards[$0..<min($0 + size, cards.count)]) }
    }
}

// MARK: - The header

/// A compact header, like a playlist's: a picture with the name beside it and
/// something short under that, then cards to page through. Always the same height
/// where there's room, so nothing that arrives late can move the tunes below. A
/// card only exists when there's something to put on it. What you can do with the
/// tunes is in the row below, with every other list's (`ListBar`).
///
/// In the narrowest pane the cards move underneath.
struct LargeHeader<Card: Hashable, Picture: View, Below: View, Bio: View, CardContent: View>: View {
    private let title: String
    private let detail: String
    private let extra: String?
    private let hasBio: Bool
    private let cards: [Card]
    private let picture: Picture
    private let below: Below
    private let bio: Bio
    private let card: (Card) -> CardContent

    @State private var width: CGFloat = 900
    @State private var page: Int?

    /// How wide the header's inside must be for the cards to fit beside the rest.
    private static var roomForColumns: CGFloat { 520 }
    private static var pictureSize: CGFloat { 76 }
    private static var columnHeight: CGFloat { 150 }
    private static var columnSpacing: CGFloat { 18 }
    private static var dotsHeight: CGFloat { 16 }

    /// - Parameters:
    ///   - title: The name beside the picture.
    ///   - detail: The line under that: how many tunes, from when.
    ///   - extra: A line under that, for a fact in words.
    ///   - hasBio: Whether there's anything to say on the About card.
    ///   - picture: Fills the frame it's given.
    ///   - below: Under the picture and name, for what fits in a glance.
    init(title: String, detail: String, extra: String? = nil, hasBio: Bool = true, cards: [Card],
         @ViewBuilder picture: () -> Picture, @ViewBuilder below: () -> Below, @ViewBuilder bio: () -> Bio,
         @ViewBuilder card: @escaping (Card) -> CardContent) {
        self.title = title
        self.detail = detail
        self.extra = extra
        self.hasBio = hasBio
        self.cards = cards
        self.picture = picture()
        self.below = below()
        self.bio = bio()
        self.card = card
    }

    /// A place in the carousel: the bio or a card.
    private enum Slot: Hashable {
        case bio
        case card(Card)
    }

    /// The first card leads, and the bio follows it.
    private var slots: [Slot] {
        var slots = cards.map(Slot.card)
        if hasBio { slots.insert(.bio, at: min(1, slots.count)) }
        return slots
    }

    var body: some View {
        Group {
            if width >= Self.roomForColumns {
                columns
            } else {
                stacked
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Layouts

    private var columns: some View {
        let slots = slots
        let carouselWidth = max(260, width * 0.46)
        return HStack(alignment: .top, spacing: Self.columnSpacing) {
            identity
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                .frame(height: Self.columnHeight, alignment: .top)
                .clipped()
            carousel(slots, perPage: HeaderCards.perPage(width: carouselWidth, cards: slots.count))
                .frame(width: carouselWidth, height: Self.columnHeight)
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 10) {
            identity
            carousel(slots, perPage: 1)
                .frame(minWidth: 0, maxWidth: .infinity)
                .frame(height: 124)
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                picture
                    .frame(width: Self.pictureSize, height: Self.pictureSize)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let extra {
                        Text(extra)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            below
        }
    }

    // MARK: The carousel

    /// Paged like the inspector's visualizers: swipe, or use the dots. It only
    /// moves when you move it.
    private func carousel(_ slots: [Slot], perPage: Int) -> some View {
        let pages = HeaderCards.pages(slots, perPage: perPage)
        return VStack(spacing: 4) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(pages.indices, id: \.self) { index in
                        HStack(spacing: 10) {
                            ForEach(pages[index], id: \.self) { slot($0) }
                            // A last page that isn't full keeps its cards' width.
                            if pages[index].count < perPage {
                                Color.clear
                            }
                        }
                        .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $page)
            dots(count: pages.count)
        }
    }

    /// Always laid out, so one page keeps the same card height as many.
    private func dots(count: Int) -> some View {
        HStack(spacing: 0) {
            if count > 1 {
                ForEach(0..<count, id: \.self) { index in
                    Button {
                        withAnimation { page = index }
                    } label: {
                        Circle()
                            .fill(.primary.opacity(index == min(page ?? 0, count - 1) ? 0.8 : 0.25))
                            .frame(width: 7, height: 7)
                            .padding(4)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Card \(index + 1) of \(count)")
                }
            }
        }
        .frame(height: Self.dotsHeight)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func slot(_ slot: Slot) -> some View {
        switch slot {
        case .bio:
            HeaderCard(String(localized: "About")) {
                ScrollView(.vertical) {
                    bio
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .card(let content):
            card(content)
        }
    }
}

// MARK: - Parts

/// A card in the carousel: a small-caps title, and what's in it.
struct HeaderCard<Content: View>: View {
    let title: String
    var badge: String?
    @ViewBuilder let content: Content

    init(_ title: String, badge: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.badge = badge
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.18), in: .rect(cornerRadius: 5))
                }
            }
            // The system's soft fade at a scroll view's edge cut into the first
            // line, right under the title.
            content
                .scrollEdgeEffectHidden()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 10))
    }
}

/// A row of a bio's facts, for a `Grid`: nothing when there's no value.
@ViewBuilder
func headerFact(_ label: String, _ value: String?) -> some View {
    if let value {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Sound

/// What a set of tunes sounds like, card-sized: a bar a sound, with a tick where
/// it stands across all of HVSC. A composer's and a section's are the same card.
struct SoundSharesCard: View {
    let shares: [SoundShare]
    let scanned: Int
    let tunes: Int

    var body: some View {
        HeaderCard(String(localized: "Sound")) {
            if shares.isEmpty {
                Text("Resonance hasn't scanned these tunes yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 5) {
                        // Only when most of them aren't what it's about.
                        if scanned * 10 < tunes * 9 {
                            Text("Of the \(SectionFacts.tunes(scanned)) with a fingerprint.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(shares, id: \.tag) { SoundShareRow(share: $0) }
                    }
                }
                .font(.callout)
                .help(shares.contains { $0.overall != nil } ? "Share of tunes. The tick marks all of HVSC." : "Share of tunes.")
            }
        }
    }
}
