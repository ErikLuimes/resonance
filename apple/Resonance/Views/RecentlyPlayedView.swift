import SwiftUI
import PhosphorCore

/// The play history: the last 100 different tunes played, newest first,
/// and how much of HVSC has been heard so far.
struct RecentlyPlayedView: View {
    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library
    /// The list's own filter.
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        // Each play is recorded before the core reports the new track.
        .task(id: store.trackRevision) { await library.loadRecent() }
    }

    @ViewBuilder
    private var content: some View {
        if let recent = library.recent {
            if recent.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Played Yet", systemImage: "clock")
                } description: {
                    Text("Tunes you play show up here, newest first.")
                }
                // The whole pane, so the header stays on top and the play bar at
                // the bottom.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let rows = filtered(recent.map(\.row))
                LibraryTable(
                    rows: rows,
                    source: .recentlyPlayed,
                    played: Dictionary(recent.map { ($0.row.id, $0.playedText) }, uniquingKeysWith: { first, _ in first }),
                    actions: AnyView(listActions)
                )
                .overlay {
                    if !query.isEmpty && rows.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "clock")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 76, height: 76)
                .background(
                    LinearGradient(
                        colors: [Color(red: 63 / 255, green: 208 / 255, blue: 232 / 255),
                                 Color(red: 155 / 255, green: 107 / 255, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: .rect(cornerRadius: 17)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text("Recently Played")
                    .font(.title2.weight(.bold))
                Text("The last 100 different tunes you played.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let heard = heardText {
                    Text(heard)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// What the list does, in the row with Sound.
    private var listActions: some View {
        Group {
            ListFilterField(text: $filter)
            ListPlayButton { library.play(rows, from: .recentlyPlayed) }
        }
    }

    /// "You've heard 2,431 of 61,157 HVSC tunes (4%)."
    private var heardText: String? {
        guard let heard = library.heardCount, heard > 0 else { return nil }
        guard let total = store.hvscInfo?.totalTunes, total > 0 else {
            return String(localized: "You've heard \(heard.formatted()) different tunes.")
        }
        let share = Double(heard) / Double(total)
        let percent = share.formatted(.percent.precision(.fractionLength(share < 0.01 ? 1 : 0)))
        return String(localized: "You've heard \(heard.formatted()) of \(total.formatted()) HVSC tunes (\(percent)).")
    }

    private var rows: [LibraryRow] { library.recent?.map(\.row) ?? [] }

    private var query: String { filter.trimmingCharacters(in: .whitespaces) }

    private func filtered(_ rows: [LibraryRow]) -> [LibraryRow] {
        guard !query.isEmpty else { return rows }
        return rows.filter {
            $0.title.localizedStandardContains(query)
                || $0.author.localizedStandardContains(query)
                || $0.released.localizedStandardContains(query)
        }
    }
}

#Preview {
    RecentlyPlayedView()
        .environment(PlayerStore.preview)
        .environment(LibraryStore(player: .preview))
        .environment(FingerprintStore(player: .preview))
        .frame(width: 900, height: 500)
}
