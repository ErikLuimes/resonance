import Foundation
import Testing
@testable import Resonance

struct ResonanceIntentsTests {
    private let lists = [UserPlaylist(url: URL(filePath: "/p/Late night.m3u")),
                         UserPlaylist(url: URL(filePath: "/p/Galway.m3u"))]

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

    @Test func aPlaylistIsItsFile() {
        let entity = PlaylistEntity(lists[0])
        #expect(entity.storeID == "Late night.m3u")
        #expect(entity.source == .playlist(id: "Late night.m3u", name: "Late night"))
    }

    /// Siri only accepts a phrase that holds the app's name, and only ten
    /// shortcuts.
    @Test func thereAreNoMoreThanTenShortcuts() {
        #expect((1...10).contains(ResonanceShortcuts.appShortcuts.count))
    }
}
