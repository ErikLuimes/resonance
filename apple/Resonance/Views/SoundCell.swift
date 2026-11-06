import SwiftUI
import PhosphorCore

/// A tune list's Sound cell: the fingerprint's barcode, and on a short
/// hover a card with the tune's sphere, waveform mix and tags, to play it
/// or sort the list by how alike the others sound.
struct SoundCell: View {
    /// Passed in, not read from the environment (see `TuneTitleCell`).
    let fingerprints: FingerprintStore
    let path: String
    let title: String
    let subtitle: String
    let length: String?
    var onPlay: (() -> Void)?
    var onFindSimilar: (() -> Void)?

    @State private var showsCard = false
    @State private var hovering = false
    @State private var overCard = false
    @Environment(\.sectionIsCovered) private var isCovered

    var body: some View {
        Group {
            if let fp = fingerprints.fingerprint(path) {
                SoundBarcode(traits: fp.traits)
                    .contentShape(.rect)
                    .onHover { inside in
                        hovering = inside
                        updateCard()
                    }
                    .popover(isPresented: $showsCard, arrowEdge: .bottom) {
                        SoundHoverCard(fingerprint: fp, title: title, subtitle: subtitle, length: length,
                                       onPlay: onPlay.map { play in { showsCard = false; play() } },
                                       onFindSimilar: onFindSimilar.map { find in { showsCard = false; find() } })
                            .onHover { inside in
                                overCard = inside
                                updateCard()
                            }
                    }
            } else {
                // Not scanned yet: an empty track, so the column doesn't jump.
                RoundedRectangle(cornerRadius: 1)
                    .fill(.secondary.opacity(0.08))
                    .frame(width: SoundBarcode.size.width, height: 2)
                    .help(fingerprints.isScanning ? "Not fingerprinted yet" : "No fingerprint")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isCovered) { if isCovered { showsCard = false } }
    }

    /// Open after the pointer rests on the barcode a moment; close a moment
    /// after it has left both the barcode and the card.
    private func updateCard() {
        guard !isCovered else { return }
        let wanted = hovering || overCard
        Task {
            try? await Task.sleep(for: .milliseconds(wanted ? 550 : 250))
            if (hovering || overCard) == wanted, showsCard != wanted {
                showsCard = wanted
            }
        }
    }
}

/// The card itself: who and how long, the tune's sphere, its waveform mix
/// and tags, Play and Find Similar.
struct SoundHoverCard: View {
    let fingerprint: TuneFingerprint
    let title: String
    let subtitle: String
    let length: String?
    var onPlay: (() -> Void)?
    var onFindSimilar: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let length {
                    Text(length)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .center, spacing: 12) {
                MorphSphere(fingerprint: fingerprint, zoom: 1.2)
                    .frame(width: 104, height: 104)
                VStack(alignment: .leading, spacing: 8) {
                    Text(fingerprint.summary)
                        .fixedSize(horizontal: false, vertical: true)
                    SoundTagList(tags: fingerprint.tags)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Waveform Mix")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                WaveformMixBar(fingerprint: fingerprint)
            }
            if onPlay != nil || onFindSimilar != nil {
                HStack(spacing: 8) {
                    if let onPlay {
                        Button("Play", action: onPlay)
                            .buttonStyle(.borderedProminent)
                    }
                    if let onFindSimilar {
                        Button("Find Similar", action: onFindSimilar)
                            .help("Sort this list by how alike the tunes sound to this one")
                    }
                }
                .controlSize(.small)
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 340)
    }
}

/// A fingerprint's tags as small capsules, wrapping.
struct SoundTagList: View {
    let tags: [SoundTag]

    var body: some View {
        if !tags.isEmpty {
            FlowLayout(spacing: 5) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag.name)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.fill.secondary, in: .capsule)
                }
            }
        }
    }
}

/// Lays its subviews out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                // Centred in the row, so a link lines up with a button beside it.
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
