import SwiftUI

// The large header over a list of tunes: a composer's, or a section of Games
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

/// Always the same height, so nothing that arrives late can move the tunes
/// below: a picture with the name and play controls under it; then the bio;
/// then a carousel of whatever else there is to say. A card only exists when
/// there's something to put on it, so more to tell simply makes more pages.
///
/// In a narrower pane the bio becomes the carousel's first card, and in the
/// narrowest the carousel moves underneath.
struct LargeHeader<Card: Hashable, Picture: View, Bio: View, CardContent: View>: View {
    private let title: String
    private let detail: String
    private let rows: [LibraryRow]
    private let source: PlaybackSource
    private let hasBio: Bool
    private let expectsCards: Bool
    private let cards: [Card]
    private let picture: Picture
    private let bio: Bio
    private let card: (Card) -> CardContent

    @State private var width: CGFloat = 900
    @State private var page: Int?

    /// How wide the header's inside must be for the bio to have a column, and
    /// for a card to fit beside the picture.
    private static var roomForBio: CGFloat { 620 }
    private static var roomForColumns: CGFloat { 390 }
    private static var identityWidth: CGFloat { 180 }
    private static var pictureHeight: CGFloat { 156 }
    /// The picture, name, detail and controls.
    private static var columnHeight: CGFloat { 232 }
    private static var columnSpacing: CGFloat { 16 }
    private static var dotsHeight: CGFloat { 16 }

    /// - Parameters:
    ///   - title: The name under the picture.
    ///   - detail: The line under that: how many tunes, from when.
    ///   - rows: The tunes the controls play.
    ///   - hasBio: Whether there's anything to say in the bio.
    ///   - expectsCards: Cards are on their way, so the bio keeps to its column.
    ///   - picture: Fills the frame it's given.
    init(title: String, detail: String, rows: [LibraryRow], source: PlaybackSource,
         hasBio: Bool = true, expectsCards: Bool = false, cards: [Card],
         @ViewBuilder picture: () -> Picture, @ViewBuilder bio: () -> Bio,
         @ViewBuilder card: @escaping (Card) -> CardContent) {
        self.title = title
        self.detail = detail
        self.rows = rows
        self.source = source
        self.hasBio = hasBio
        self.expectsCards = expectsCards
        self.cards = cards
        self.picture = picture()
        self.bio = bio()
        self.card = card
    }

    /// A place in the carousel: the bio, when it has no column, or a card.
    private enum Slot: Hashable {
        case bio
        case card(Card)
    }

    private var bioHasColumn: Bool { hasBio && width >= Self.roomForBio }

    private var slots: [Slot] {
        (hasBio && !bioHasColumn ? [.bio] : []) + cards.map(Slot.card)
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
        .padding(12)
        // A card like the inspector's composer card, set off from the
        // window's title bar and the tune list.
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: Layouts

    private var columns: some View {
        let slots = slots
        // The bio takes half of what's beside the picture, up to what it reads
        // well at; the cards get the rest, and more of them show as it grows.
        let room = width - Self.identityWidth - Self.columnSpacing
        let bioWidth = min(300, (room - Self.columnSpacing) / 2)
        let carouselWidth = bioHasColumn ? room - bioWidth - Self.columnSpacing : room
        return HStack(alignment: .top, spacing: Self.columnSpacing) {
            VStack(alignment: .leading, spacing: 0) {
                picture
                    .frame(width: Self.identityWidth, height: Self.pictureHeight)
                titleAndDetail(detailLines: 1)
                    .padding(.top, 8)
                HeaderPlayControls(rows: rows, source: source)
                    .padding(.top, 6)
            }
            .frame(width: Self.identityWidth, alignment: .leading)
            if bioHasColumn, slots.isEmpty, !expectsCards {
                bioColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Self.columnHeight)
            } else {
                if bioHasColumn {
                    bioColumn
                        .frame(width: bioWidth, alignment: .leading)
                        .frame(height: Self.columnHeight)
                }
                carousel(slots, perPage: HeaderCards.perPage(width: carouselWidth, cards: slots.count))
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .frame(height: Self.columnHeight)
            }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                picture
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 6) {
                    titleAndDetail(detailLines: 2)
                    HeaderPlayControls(rows: rows, source: source)
                }
            }
            carousel(slots, perPage: 1)
                .frame(minWidth: 0, maxWidth: .infinity)
                .frame(height: 150)
        }
    }

    /// The detail shrinks to one line under the picture, where a second would
    /// make the header taller; beside the small picture it has room to wrap.
    private func titleAndDetail(detailLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(detailLines)
                .minimumScaleFactor(0.8)
        }
    }

    /// It scrolls rather than grows, for when there's a lot to say.
    private var bioColumn: some View {
        ScrollView(.vertical) {
            bio
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
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
            HeaderCard("About") {
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

/// Play, Shuffle and Add to, for all the tunes under a header. Titles only, to
/// fit under the picture.
private struct HeaderPlayControls: View {
    let rows: [LibraryRow]
    let source: PlaybackSource

    @Environment(LibraryStore.self) private var library

    var body: some View {
        FlowLayout(spacing: 6) {
            Button("Play", systemImage: "play.fill") { library.play(rows, from: source) }
                .buttonStyle(.borderedProminent)
            Button("Shuffle", systemImage: "shuffle") { library.play(rows.shuffled(), from: source) }
            AddToButton(files: rows.map(\.id))
        }
        .labelStyle(.titleOnly)
        .controlSize(.small)
        .disabled(rows.isEmpty)
    }
}

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
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A well in the header's own card, set apart without another outline.
        .background(.background.opacity(0.6), in: .rect(cornerRadius: 10))
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
