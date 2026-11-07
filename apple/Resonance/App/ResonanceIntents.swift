import AppIntents
import Foundation
import PhosphorCore

/// Resonance's actions for Siri, Shortcuts and Spotlight. They run inside the
/// app, which macOS launches first if it has to; the stores come from
/// `AppDependencyManager` (AppDelegate adds them).
///
/// Fixed actions and your own playlists only: Siri can't be relied on to catch
/// a tune's or composer's name out of about 60,000.

/// Why an action couldn't do what it was asked, in Siri's and Shortcuts' words.
nonisolated enum TuneActionError: Error, CustomLocalizedStringResourceConvertible {
    case noCollection
    case nothingPlaying
    case notFingerprinted
    case emptyPlaylist(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noCollection: "Resonance doesn't have the HVSC collection yet."
        case .nothingPlaying: "Nothing is playing in Resonance."
        case .notFingerprinted: "Resonance hasn't fingerprinted this tune yet."
        case .emptyPlaylist(let name): "\(name) has no tunes in it."
        }
    }
}

struct SurpriseMeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Surprise Me"
    static let description = IntentDescription("Plays random tunes from all of HVSC until something else plays.")

    @Dependency private var library: LibraryStore

    @MainActor
    func perform() async throws -> some IntentResult {
        guard library.hasRoot else { throw TuneActionError.noCollection }
        await library.surpriseMe()
        return .result()
    }
}

struct PlaySomethingLikeThisIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Something Like This"
    static let description = IntentDescription("Plays the tunes that sound most like the one playing.")

    @Dependency private var player: PlayerStore
    @Dependency private var library: LibraryStore
    @Dependency private var fingerprints: FingerprintStore

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let track = player.nowPlaying else { throw TuneActionError.nothingPlaying }
        guard await fingerprints.playSimilar(to: track, with: library) else { throw TuneActionError.notFingerprinted }
        return .result()
    }
}

struct FavouriteThisTuneIntent: AppIntent {
    static let title: LocalizedStringResource = "Favourite This Tune"
    static let description = IntentDescription("Adds the tune playing to your Favourites.")

    @Dependency private var player: PlayerStore
    @Dependency private var playlists: PlaylistsStore

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let track = player.nowPlaying else { throw TuneActionError.nothingPlaying }
        await playlists.setFavourite(track.path, true)
        return .result(dialog: "Added \(track.displayTitle) to Favourites.")
    }
}

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Plays Favourites or one of your playlists.")
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$playlist)") }

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @Dependency private var library: LibraryStore
    @Dependency private var playlists: PlaylistsStore

    @MainActor
    func perform() async throws -> some IntentResult {
        let id = playlist.storeID
        await playlists.loadRows(id)
        guard let rows = playlists.rows[id], !rows.isEmpty else {
            throw TuneActionError.emptyPlaylist(playlist.name)
        }
        library.play(rows, from: playlist.source)
        return .result()
    }
}

struct PlayPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Pauses Resonance, or carries on playing.")

    @Dependency private var player: PlayerStore

    @MainActor
    func perform() async throws -> some IntentResult {
        player.playPause()
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let description = IntentDescription("Skips to the next tune.")

    @Dependency private var player: PlayerStore

    @MainActor
    func perform() async throws -> some IntentResult {
        player.next()
        return .result()
    }
}

// MARK: - Playlists

/// Favourites or one of your playlists, as Shortcuts and Siri name it.
nonisolated struct PlaylistEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist")
    static let defaultQuery = PlaylistEntityQuery()
    /// Favourites' id here: in the store it's empty, which an entity's can't
    /// usefully be. Playlists' ids are file names ending .m3u, so never this.
    static let favouritesID = "favourites"

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static let favourites = PlaylistEntity(id: favouritesID, name: "Favourites")

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(_ playlist: UserPlaylist) {
        self.init(id: playlist.id, name: playlist.name)
    }

    /// Its key in `PlaylistsStore`.
    var storeID: String { id == Self.favouritesID ? PlaylistsStore.favouritesID : id }

    var source: PlaybackSource {
        id == Self.favouritesID ? .favourites : .playlist(id: id, name: name)
    }

    /// Favourites, then your playlists; those whose name holds `text` when
    /// there is one.
    static func all(in playlists: [UserPlaylist], matching text: String? = nil) -> [PlaylistEntity] {
        let everything = [favourites] + playlists.map(PlaylistEntity.init)
        guard let text, !text.isEmpty else { return everything }
        return everything.filter { $0.name.localizedStandardContains(text) }
    }
}

struct PlaylistEntityQuery: EntityStringQuery {
    @Dependency private var playlists: PlaylistsStore

    @MainActor
    func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        PlaylistEntity.all(in: playlists.playlists).filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [PlaylistEntity] {
        PlaylistEntity.all(in: playlists.playlists, matching: string)
    }

    @MainActor
    func suggestedEntities() async throws -> [PlaylistEntity] {
        PlaylistEntity.all(in: playlists.playlists)
    }
}

// MARK: - Siri

/// What Siri and Spotlight offer without any setup. Every phrase has to hold
/// the app's name.
struct ResonanceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SurpriseMeIntent(),
                    phrases: ["Surprise me in \(.applicationName)", "Play something random in \(.applicationName)"],
                    shortTitle: "Surprise Me", systemImageName: "dice")
        AppShortcut(intent: PlaySomethingLikeThisIntent(),
                    phrases: ["Play something like this in \(.applicationName)", "More like this in \(.applicationName)"],
                    shortTitle: "Play Something Like This", systemImageName: "waveform")
        AppShortcut(intent: FavouriteThisTuneIntent(),
                    phrases: ["Favourite this tune in \(.applicationName)", "Add this to my favourites in \(.applicationName)"],
                    shortTitle: "Favourite This Tune", systemImageName: "heart")
        AppShortcut(intent: PlayPlaylistIntent(),
                    phrases: ["Play \(\.$playlist) in \(.applicationName)"],
                    shortTitle: "Play Playlist", systemImageName: "music.note.list")
    }
}
