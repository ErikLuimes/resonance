import CoreTransferable
import UniformTypeIdentifiers

nonisolated extension UTType {
    /// Commodore 64 SID tunes (.sid, .psid, .rsid, .mus); declared as an
    /// imported type in Resonance-Info.plist.
    static let sidTune = UTType(importedAs: "org.hvsc.sid", conformingTo: .audio)

    /// A playlist row being dragged within the app; declared as an exported
    /// type in Resonance-Info.plist.
    static let playlistRow = UTType(exportedAs: "nl.luimes.resonance.playlist-row")
}

/// Drag payload for reordering playlist rows. A private type, so drags
/// from other apps (file URLs, text) never land on the reorder handler.
nonisolated struct PlaylistRowDrag: Codable, Transferable {
    let path: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .playlistRow)
    }
}
