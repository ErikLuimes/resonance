import Foundation
import PhosphorCore

/// Where what's playing comes from, named the same everywhere: "Playing
/// from Rob Hubbard". Whatever starts playback says which source it is;
/// the core only knows a temporary list (or the playlist).
nonisolated enum PlaybackSource: Equatable, Sendable {
    /// The playlist Resonance keeps between launches.
    case myPlaylist
    case favorites
    /// One of your playlists, by its file name.
    case playlist(id: String, name: String)
    /// One of Phosphor's published playlists.
    case curated(HvscPlaylist)
    /// A composer's tunes, or a game's or demo's folder.
    case folder(name: String, category: HvscCategory)
    case search(query: String)
    case recentlyPlayed
    /// A tune's Sounds Like list, by the tune's title.
    case soundsLike(title: String)
    /// Sound Drift, by the tune it set off from.
    case drift(title: String)
    /// A Smart Playlist not saved, by its title.
    case smart(title: String)
    case surprise
    case shuffleCollection
    /// Files dropped or opened, outside any list.
    case files
    /// A tune someone shared a link to.
    case shared
#if CSDB
    /// A release played from CSDb.
    case scene
    /// The list of tunes downloaded from CSDb.
    case csdbDownloads
#endif

    /// "Rob Hubbard", "Search “commando”".
    var name: String {
        switch self {
        case .myPlaylist: String(localized: "My Playlist")
        case .favorites: String(localized: "Favorites")
        case .playlist(_, let name): name
        case .curated(let playlist): playlist.name
        case .folder(let name, _): name
        case .search(let query): String(localized: "Search “\(query)”")
        case .recentlyPlayed: String(localized: "Recently Played")
        case .soundsLike(let title): String(localized: "Sounds like \(title)")
        case .drift(let title): String(localized: "Drifting from \(title)")
        case .smart(let title): title
        case .surprise: String(localized: "Surprise Me")
        case .shuffleCollection: String(localized: "Shuffle Collection")
        case .files: String(localized: "Files")
        case .shared: String(localized: "Shared Link")
#if CSDB
        case .scene: String(localized: "Scene Pulse")
        case .csdbDownloads: String(localized: "Downloads")
#endif
        }
    }

    /// The name after its kind ("Sounds like: Commando"), where the kind
    /// already says what `name` would repeat.
    var shortName: String {
        if case .soundsLike(let title) = self { return title }
        return name
    }

    /// What kind of list it is, for the inspector: "Composer".
    var kind: String {
        switch self {
        case .myPlaylist, .playlist: String(localized: "Your playlist")
        case .favorites: String(localized: "Your favorites")
        case .curated: String(localized: "Curated playlist")
        case .folder(_, let category): category == .musicians ? String(localized: "Composer") : category.displayName
        case .search: String(localized: "Search")
        case .recentlyPlayed: String(localized: "History")
        case .soundsLike: String(localized: "Sounds like")
        case .drift: String(localized: "Sound Drift")
        case .smart: String(localized: "Smart Playlist")
        case .surprise: String(localized: "Random tunes from HVSC")
        case .shuffleCollection: String(localized: "All of HVSC, shuffled")
        case .files: String(localized: "Added files")
        case .shared: String(localized: "Opened from")
#if CSDB
        case .scene, .csdbDownloads: String(localized: "From CSDb")
#endif
        }
    }

    var symbol: String {
        switch self {
        case .myPlaylist, .playlist: "music.note.list"
        case .favorites: "heart"
        case .curated: "list.star"
        case .folder(_, let category): category.symbolName
        case .search: "magnifyingglass"
        case .recentlyPlayed: "clock"
        case .soundsLike: "waveform"
        case .drift: "wind"
        case .smart: "wand.and.stars"
        case .surprise: "dice"
        case .shuffleCollection: "shuffle"
        case .files: "doc"
        case .shared: "link"
#if CSDB
        case .scene: "antenna.radiowaves.left.and.right"
        case .csdbDownloads: "arrow.down.circle"
#endif
        }
    }

    /// The sidebar section it is, when it has one; the others show the
    /// playing tune in the library instead.
    @MainActor var section: SidebarItem? {
        switch self {
        case .myPlaylist: .playlist
        case .favorites: .favorites
        case .playlist(let id, _): .userPlaylist(id)
        case .curated(let playlist): .curated(playlist.file)
        case .smart: .smartPlaylist
        case .recentlyPlayed: .recent
#if CSDB
        case .scene: .scene
        case .csdbDownloads: .csdbDownloads
#endif
        default: nil
        }
    }
}
