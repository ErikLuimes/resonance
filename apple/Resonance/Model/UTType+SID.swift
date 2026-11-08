import CoreTransferable
import UniformTypeIdentifiers

nonisolated extension UTType {
    /// Commodore 64 SID tunes (.sid, .psid, .rsid, .mus); declared as an
    /// imported type in Resonance-Info.plist.
    static let sidTune = UTType(importedAs: "org.hvsc.sid", conformingTo: .audio)

    /// What Add Files offers: SID tunes, playlists and folders, by every
    /// type this Mac gives their extensions. Another player (Modizer, say)
    /// can claim .sid with its own type, and the sandbox's open panel goes
    /// by a file's type, so `sidTune` alone would gray them out.
    static var addable: [UTType] {
        let extensions = ["sid", "psid", "rsid", "mus", "m3u", "m3u8", "pls"]
        var types: [UTType] = [.sidTune, .m3uPlaylist, .folder]
        for tag in extensions {
            for type in UTType.types(tag: tag, tagClass: .filenameExtension, conformingTo: nil) where !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    /// A tune row being dragged within the app; declared as an exported
    /// type in Resonance-Info.plist.
    static let playlistRow = UTType(exportedAs: "app.useresonance.resonance.playlist-row")
}

/// Drag payload for a tune row within the app: reordering a playlist, or
/// dropped on one in the sidebar. A private type, so drags from other
/// apps (file URLs, text) never land on these handlers.
nonisolated struct PlaylistRowDrag: Codable, Transferable {
    /// The tunes' files: one row, or a whole selection dragged as one.
    let paths: [String]
    /// The id of your playlist they're dragged from, which ⌘ can move them
    /// out of; nil from any other list.
    var from: String? = nil

    init(path: String, from: String? = nil) {
        paths = [path]
        self.from = from
    }

    init(paths: [String], from: String? = nil) {
        self.paths = paths
        self.from = from
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .playlistRow)
    }
}

/// What a sidebar playlist takes: tunes from a list in the app, or files
/// from outside. One type, as a row holds one drop handler per payload.
nonisolated enum SidebarDrop: Transferable {
    case tunes(PlaylistRowDrag)
    case file(URL)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (drag: PlaylistRowDrag) in SidebarDrop.tunes(drag) })
        ProxyRepresentation(importing: { (url: URL) in SidebarDrop.file(url) })
    }
}
