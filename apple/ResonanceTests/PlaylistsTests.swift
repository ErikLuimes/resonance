import Foundation
import Testing
import Synchronization
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
        let player = PlayerStore(defaults: defaults, phosphorHvscRoot: { nil }, defaultHvscRoot: nil) { _ in fake }
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

    @Test func aPlaylistFileBecomesANamedPlaylistAndSaysWhatsMissing() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore()
        fake.set(resolved: ResolvedFiles(paths: ["/a.sid", "/b.sid"], found: 2, listed: 3), for: "/lists/Top 100.m3u")

        await store.importAsNew([URL(filePath: "/lists/Top 100.m3u")])

        let made = try #require(store.playlists.first)
        #expect(made.name == "Top 100")
        #expect(store.read(made) == ["/a.sid", "/b.sid"])
        #expect(store.revealing == made.id)
        #expect(store.renaming == nil, "it has its name already")
        #expect(store.importNotice == "Top 100: 2 of 3 tunes found.")
        #expect(fake.calls.isEmpty, "nothing goes to My Playlist or starts playing")
    }

    @Test func aPlaylistWithNothingPlayableMakesNoPlaylist() async {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore()
        fake.set(resolved: ResolvedFiles(paths: [], found: 0, listed: 3), for: "/lists/Gone.m3u")

        await store.importAsNew([URL(filePath: "/lists/Gone.m3u")])

        #expect(store.playlists.isEmpty)
        #expect(store.revealing == nil)
        #expect(store.importNotice?.hasPrefix("No playable SID files found in Gone.") == true)
    }

    @Test func importingTheSameFileTwiceMakesASecondPlaylist() async {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore()
        fake.set(resolved: ResolvedFiles(paths: ["/a.sid"], found: 1, listed: 1), for: "/lists/Mix.m3u")

        await store.importAsNew([URL(filePath: "/lists/Mix.m3u")])
        await store.importAsNew([URL(filePath: "/lists/Mix.m3u")])

        #expect(store.playlists.map(\.name) == ["Mix", "Mix 2"])
    }

    @Test func looseTunesMakeOnePlaylistToName() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore()

        await store.importAsNew([URL(filePath: "/x/a.sid"), URL(filePath: "/x/b.sid")])

        let made = try #require(store.playlists.first)
        #expect(store.playlists.count == 1)
        #expect(made.name == "Untitled Playlist")
        #expect(store.read(made) == ["/x/a.sid", "/x/b.sid"])
        #expect(store.renaming == made.id)
    }

    @Test func filesDroppedOnAPlaylistAreAddedToIt() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore()
        let mix = try #require(store.create(named: "Mix"))
        await store.add(["/a.sid"], to: .playlist(mix.id))
        fake.set(resolved: ResolvedFiles(paths: ["/a.sid", "/b.sid"], found: 2, listed: 2), for: "/lists/More.m3u")

        await store.addFiles([URL(filePath: "/lists/More.m3u")], to: .playlist(mix.id))

        #expect(store.read(mix) == ["/a.sid", "/b.sid"])
        #expect(store.playlists.count == 1, "no new playlist")
        #expect(store.importNotice == nil)
    }

    @Test func exportsCollectionTunesAsRelativePaths() {
        let files = ["/HVSC/MUSICIANS/A/Ann/One.sid", "/Music/Mine.sid", "/HVSC2/Other.sid"]
        #expect(PlaylistsStore.exportedM3U(files, hvscRoot: "/HVSC")
            == "#EXTM3U\nMUSICIANS/A/Ann/One.sid\n/Music/Mine.sid\n/HVSC2/Other.sid\n")
        #expect(PlaylistsStore.exportedM3U(files, hvscRoot: "/HVSC/").contains("\nMUSICIANS/A/Ann/One.sid\n"))
        #expect(PlaylistsStore.exportedM3U(files, hvscRoot: nil).contains("/HVSC/MUSICIANS/A/Ann/One.sid"))
    }

    @Test func exportWritesTheFileAndLeavesThePlaylistAlone() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore()
        let mix = try #require(store.create(named: "Mix"))
        await store.add(["/a.sid"], to: .playlist(mix.id))
        let out = FileManager.default.temporaryDirectory.appending(path: "Export-\(UUID().uuidString).m3u")
        defer { try? FileManager.default.removeItem(at: out) }

        #expect(store.export(.playlist(mix.id), to: out))
        #expect(try String(contentsOf: out, encoding: .utf8) == "#EXTM3U\n/a.sid\n")
        #expect(store.read(mix) == ["/a.sid"])
    }

    @Test func exportsFavouritesNewestFirst() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore()
        await store.add(["/old.sid"], to: .favourites)
        await store.add(["/new.sid"], to: .favourites)
        let out = FileManager.default.temporaryDirectory.appending(path: "Export-\(UUID().uuidString).m3u")
        defer { try? FileManager.default.removeItem(at: out) }

        #expect(store.export(.favourites, to: out))
        #expect(try String(contentsOf: out, encoding: .utf8) == "#EXTM3U\n/new.sid\n/old.sid\n")
    }

    @Test func exportsMyPlaylistWithItsChosenSubtunes() {
        #expect(PlaylistsStore.exportedM3U(["/HVSC/a.sid", "/b.sid"], songs: ["/HVSC/a.sid": 8], hvscRoot: "/HVSC")
            == "#EXTM3U\n#PHOSPHOR:song=8\na.sid\n/b.sid\n")
    }

    @Test func myPlaylistsExportContentsNoteOnlyChosenSubtunes() {
        let store = makeStore()
        func item(_ path: String, song: UInt16) -> PlaylistItem {
            PlaylistItem(path: path, title: "T", author: "A", released: "1987", songs: 9, selectedSong: song,
                         durationSecs: 60, isRsid: false, isPal: true, numSids: 1, md5: nil)
        }
        var snapshot = FakeCore.stoppedSnapshot
        snapshot.playlistRevision = 1
        fake.set(snapshot: snapshot, items: [item("/a.sid", song: 1), item("/b.sid", song: 3)])
        store.player.refresh()

        let contents = store.exportContents(of: .myPlaylist)
        #expect(contents.files == ["/a.sid", "/b.sid"])
        #expect(contents.songs == ["/b.sid": 3])
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

    /// A heart reading isFavourite redraws when the tune is hearted.
    @Test func heartingNotifiesWhoeverAsked() async {
        let store = makeStore()
        let changed = Mutex(false)
        withObservationTracking {
            _ = store.isFavourite("/a.sid")
        } onChange: {
            changed.withLock { $0 = true }
        }
        await store.setFavourite("/a.sid", true)
        #expect(changed.withLock { $0 })
    }
}

@MainActor
struct PlaybackSourceTests {
    let fake = FakeCore()

    @Test func namesWhatPlaysAfterWhateverStartedIt() {
        let suite = "ResonanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = PlayerStore(defaults: defaults, phosphorHvscRoot: { nil }, defaultHvscRoot: nil) { _ in fake }

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
        let player = PlayerStore(defaults: defaults, phosphorHvscRoot: { nil }, defaultHvscRoot: nil) { _ in fake }
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
