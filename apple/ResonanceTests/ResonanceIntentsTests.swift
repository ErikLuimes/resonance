import Foundation
import Testing
@testable import Resonance

struct ResonanceIntentsTests {
    private let lists = [UserPlaylist(id: "id-1", url: URL(filePath: "/p/Late night.m3u")),
                         UserPlaylist(id: "id-2", url: URL(filePath: "/p/Galway.m3u"))]

    @Test func favoritesComeBeforeYourPlaylists() {
        #expect(PlaylistEntity.all(in: lists).map(\.name) == ["Favorites", "Late night", "Galway"])
    }

    @Test func findsByPartOfTheNameIgnoringCase() {
        #expect(PlaylistEntity.all(in: lists, matching: "NIGHT").map(\.name) == ["Late night"])
        #expect(PlaylistEntity.all(in: lists, matching: "fav").map(\.name) == ["Favorites"])
        #expect(PlaylistEntity.all(in: lists, matching: "").count == 3)
    }

    @Test func favoritesUseTheStoresEmptyID() {
        #expect(PlaylistEntity.favorites.storeID == PlaylistsStore.favoritesID)
        #expect(PlaylistEntity.favorites.source == .favorites)
    }

    /// Its id, not its file name: a shortcut holds it, and a rename moves
    /// the file.
    @Test func aPlaylistGoesByItsID() {
        let entity = PlaylistEntity(lists[0])
        #expect(entity.id == "id-1")
        #expect(entity.storeID == "id-1")
        #expect(entity.source == .playlist(id: "id-1", name: "Late night"))
    }

    /// Siri only accepts a phrase that holds the app's name, and only ten
    /// shortcuts.
    @Test func thereAreNoMoreThanTenShortcuts() {
        #expect((1...10).contains(ResonanceShortcuts.appShortcuts.count))
    }
}
