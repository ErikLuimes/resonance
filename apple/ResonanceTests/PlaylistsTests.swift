import Foundation
import Testing
import PhosphorCore
@testable import Resonance

@MainActor
struct PlaylistsStoreTests {
    let fake = FakeCore()
    let folder = FileManager.default.temporaryDirectory.appending(path: "ResonancePlaylists-\(UUID().uuidString)")

    private func makeStore() -> PlaylistsStore {
        let suite = "ResonanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let player = PlayerStore(defaults: defaults, phosphorHvscRoot: { nil }) { _ in fake }
        return PlaylistsStore(player: player, folder: folder, defaults: defaults)
    }

    @Test func makesUniquelyNamedM3UFiles() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore()
        let first = try #require(store.create())
        let second = try #require(store.create())
        #expect(first.name == "Untitled Playlist")
        #expect(second.name == "Untitled Playlist 2")
        #expect(try String(contentsOf: first.url, encoding: .utf8) == "#EXTM3U\n")
        #expect(store.create(named: "a/b:c")?.name == "a-b-c", "no path separators in a file name")
    }

    @Test func addsWithoutDuplicatesAndRemoves() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore()
        let playlist = try #require(store.create(named: "Mix"))
        await store.add(["/a.sid", "/b.sid"], to: .playlist(playlist.id))
        await store.add(["/b.sid", "/c.sid"], to: .playlist(playlist.id))
        #expect(store.read(playlist) == ["/a.sid", "/b.sid", "/c.sid"])

        store.remove(["/b.sid"], from: playlist)
        // Read back from the file, not the cache.
        let reread = makeStore()
        #expect(reread.read(try #require(reread.playlist(playlist.id))) == ["/a.sid", "/c.sid"])
    }

    @Test func renamesDuplicatesAndDeletes() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore()
        let mix = try #require(store.create(named: "Mix"))
        _ = store.create(named: "Taken")
        #expect(store.rename(mix, to: "taken") == nil, "names are unique, whatever the case")

        let renamed = try #require(store.rename(mix, to: "Late night"))
        #expect(store.playlists.map(\.name) == ["Late night", "Taken"])
        #expect(store.duplicate(renamed)?.name == "Late night copy")

        store.delete(renamed)
        #expect(store.playlist(renamed.id) == nil)
    }

    @Test func theLastPlaylistAddedToComesFirst() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore()
        let a = try #require(store.create(named: "A"))
        let b = try #require(store.create(named: "B"))
        await store.add(["/x.sid"], to: .playlist(b.id))
        #expect(store.recentlyUsed.map(\.name) == ["B", "A"])
        await store.add(["/x.sid"], to: .playlist(a.id))
        #expect(store.recentlyUsed.map(\.name) == ["A", "B"])
    }

    @Test func favouritesGoThroughTheCore() async {
        let store = makeStore()
        await store.add(["/a.sid"], to: .favourites)
        #expect(store.isFavourite("/a.sid"))
        await store.setFavourite("/a.sid", false)
        #expect(!store.isFavourite("/a.sid"))
    }
}

@MainActor
struct PlaybackSourceTests {
    let fake = FakeCore()

    @Test func namesWhatPlaysAfterWhateverStartedIt() {
        let suite = "ResonanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = PlayerStore(defaults: defaults, phosphorHvscRoot: { nil }) { _ in fake }

        store.playQueue([URL(filePath: "/a.sid")], startAt: URL(filePath: "/a.sid"), from: .search(query: "commando"))
        var snapshot = FakeCore.stoppedSnapshot
        snapshot.queueActive = true
        fake.set(snapshot: snapshot)
        store.refresh()
        #expect(store.source == .search(query: "commando"))
        #expect(store.source?.name == "Search “commando”")

        // The list ended and the playlist plays: My Playlist.
        snapshot.queueActive = false
        snapshot.currentIndex = 0
        fake.set(snapshot: snapshot)
        store.refresh()
        #expect(store.source == .myPlaylist)

        snapshot.surpriseActive = true
        fake.set(snapshot: snapshot)
        store.refresh()
        #expect(store.source == .surprise)
    }
}

@MainActor
struct PlaylistPlacingTests {
    let fake = FakeCore()
    let folder = FileManager.default.temporaryDirectory.appending(path: "ResonancePlaylists-\(UUID().uuidString)")

    @Test func movesAndInsertsBeforeATargetOrAtTheEnd() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "ResonanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let player = PlayerStore(defaults: defaults, phosphorHvscRoot: { nil }) { _ in fake }
        let store = PlaylistsStore(player: player, folder: folder, defaults: defaults)
        let mix = try #require(store.create(named: "Mix"))
        await store.add(["/a.sid", "/b.sid", "/c.sid", "/d.sid"], to: .playlist(mix.id))

        store.place(["/d.sid"], before: "/b.sid", in: mix)
        #expect(store.read(mix) == ["/a.sid", "/d.sid", "/b.sid", "/c.sid"])

        store.place(["/a.sid", "/b.sid"], before: nil, in: mix)
        #expect(store.read(mix) == ["/d.sid", "/c.sid", "/a.sid", "/b.sid"])

        store.place(["/new.sid", "/new.sid"], before: "/c.sid", in: mix)
        #expect(store.read(mix) == ["/d.sid", "/new.sid", "/c.sid", "/a.sid", "/b.sid"], "added once, where dropped")
    }
}
