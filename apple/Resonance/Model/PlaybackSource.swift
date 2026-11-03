import Foundation
import PhosphorCore

/// Where what's playing comes from, named the same everywhere: "Playing
/// from Rob Hubbard". Whatever starts playback says which source it is;
/// the core only knows a temporary list (or the playlist).
nonisolated enum PlaybackSource: Equatable, Sendable {
    /// The playlist Resonance keeps between launches.
    case myPlaylist
    case favourites
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
    case surprise
    case shuffleCollection
    /// Files dropped or opened, outside any list.
    case files

    /// "Rob Hubbard", "Search “commando”".
    var name: String {
        switch self {
        case .myPlaylist: "My Playlist"
        case .favourites: "Favourites"
        case .playlist(_, let name): name
        case .curated(let playlist): playlist.name
        case .folder(let name, _): name
        case .search(let query): "Search “\(query)”"
        case .recentlyPlayed: "Recently Played"
        case .soundsLike(let title): "Sounds like \(title)"
        case .surprise: "Surprise Me"
        case .shuffleCollection: "Shuffle Collection"
        case .files: "Files"
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
        case .myPlaylist, .playlist: "Your playlist"
        case .favourites: "Your favourites"
        case .curated: "Curated playlist"
        case .folder(_, let category): category == .musicians ? "Composer" : category.displayName
        case .search: "Search"
        case .recentlyPlayed: "History"
        case .soundsLike: "Sounds like"
        case .surprise: "Random tunes from HVSC"
        case .shuffleCollection: "All of HVSC, shuffled"
        case .files: "Added files"
        }
    }

    var symbol: String {
        switch self {
        case .myPlaylist, .playlist: "music.note.list"
        case .favourites: "heart"
        case .curated: "list.star"
        case .folder(_, let category): category.symbolName
        case .search: "magnifyingglass"
        case .recentlyPlayed: "clock"
        case .soundsLike: "waveform"
        case .surprise: "dice"
        case .shuffleCollection: "shuffle"
        case .files: "doc"
        }
    }

    /// The sidebar section it is, when it has one; the others show the
    /// playing tune in the library instead.
    @MainActor var section: SidebarItem? {
        switch self {
        case .myPlaylist: .playlist
        case .favourites: .favourites
        case .playlist(let id, _): .userPlaylist(id)
        case .curated(let playlist): .curated(playlist.file)
        case .recentlyPlayed: .recent
        default: nil
        }
    }
}
