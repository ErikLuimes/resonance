import Foundation
import PhosphorCore

/// One playlist row. `index` is the row's position in the core's playlist —
/// what commands take — while `id` (the file path) survives reordering.
nonisolated struct TrackRow: Identifiable, Hashable, Sendable {
    let index: Int
    let item: PlaylistItem

    var id: String { item.path }
    var url: URL { URL(filePath: item.path) }

    // Sortable columns (Table sorts on these key paths).
    var title: String { item.title }
    var author: String { item.author }
    var released: String { item.released }
    var songs: Int { Int(item.songs) }
    var chips: Int { Int(item.numSids) }
    /// Unknown lengths sort last.
    var length: Int { item.durationSecs.map(Int.init) ?? .max }

    var lengthText: String {
        item.durationSecs.map {
            (item.durationIsEstimate ? "~" : "") + Duration.seconds($0).formatted(.time(pattern: .minuteSecond))
        } ?? "—"
    }

    var songsText: String {
        item.songs > 1 ? "\(item.selectedSong)/\(item.songs)" : "1"
    }

    var format: String { item.isRsid ? "RSID" : "PSID" }
}
