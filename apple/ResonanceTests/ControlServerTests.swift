import Darwin
import Foundation
import PhosphorCore
import Testing
@testable import Resonance

@MainActor
@Suite(.serialized)
final class ControlCommandsTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "control-\(UUID().uuidString)")
    private let suite = "control-tests-\(UUID().uuidString)"
    private let fake = FakeCore()
    private let player: PlayerStore
    private let playlists: PlaylistsStore
    private let commands: ControlCommands

    init() {
        let defaults = UserDefaults(suiteName: suite)!
        let fake = fake
        player = PlayerStore(defaults: defaults, defaultHvscRoot: nil) { _ in fake }
        playlists = PlaylistsStore(player: player, folder: folder, defaults: defaults)
        commands = ControlCommands(player: player, library: LibraryStore(player: player),
                                   fingerprints: FingerprintStore(player: player, defaults: defaults), playlists: playlists)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func ask(_ cmd: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        let line = try JSONSerialization.data(withJSONObject: ["id": 7, "cmd": cmd, "args": args])
        let reply = await commands.handle(line)
        return try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    @Test func answersWithTheRequestsID() async throws {
        let reply = try await ask("status")
        #expect(reply["id"] as? Int == 7)
        #expect(reply["ok"] as? Bool == true)
        #expect((reply["result"] as? [String: Any])?["state"] as? String == "stopped")
    }

    @Test func printsAnswerOnlyForTunesWithAFingerprint() throws {
        let print = fingerprint()
        let plain = ControlCommands.Print(path: "/a.sid", print: print, detail: false)
        #expect(plain.traits == print.traits)
        #expect(plain.mix == nil)
        #expect(plain.activity == nil)
    }

    @Test func printsInDetailSplitTheVoices() throws {
        let print = fingerprint(mix: [0.1, 0.2, 0.3, 0.4])
        let detail = ControlCommands.Print(path: "/a.sid", print: print, detail: true)
        #expect(detail.mix?.noise == 0.4)
        #expect(detail.activity?.count == 3)
        #expect(detail.activity?.allSatisfy { $0.count == 128 } == true)
    }

    @Test func printsLeaveOutWhatIsntScanned() async throws {
        fake.set(fingerprints: ["/HVSC/a.sid": fingerprint()])
        let reply = try await ask("prints", ["paths": ["/HVSC/a.sid", "/HVSC/b.sid"]])
        let found = try #require(reply["result"] as? [[String: Any]])
        #expect(found.map { $0["path"] as? String } == ["/HVSC/a.sid"])
        #expect((found[0]["traits"] as? [Double])?.count == 9)
    }

    @Test func hvscAsksWhichSection() async throws {
        let reply = try await ask("hvsc.authors", ["name": "Tapes"])
        #expect(reply["ok"] as? Bool == false)
        #expect((reply["error"] as? String)?.contains("Musicians") == true)
    }

    @Test func hvscSaysWhenThereIsNoCollection() async throws {
        let reply = try await ask("hvsc.info")
        #expect(reply["ok"] as? Bool == false)
    }

    @Test func aCuratedPlaylistIsFoundByNameOrFile() {
        let top = HvscPlaylist(name: "HVSC Favorite Top 100", file: "HVSC_Favorite_Top_100.m3u", description: nil, tracks: 100)
        let other = HvscPlaylist(name: "Encore64", file: "Encore64.m3u", description: nil, tracks: 64)
        #expect(ControlCommands.curated("HVSC Favorite Top 100", in: [other, top]) == top)
        #expect(ControlCommands.curated(" hvsc favorite top 100 ", in: [other, top]) == top)
        #expect(ControlCommands.curated("HVSC_Favorite_Top_100.m3u", in: [other, top]) == top)
        #expect(ControlCommands.curated("Top 100", in: [other, top]) == nil)
        #expect(ControlCommands.curated(nil, in: [other, top]) == nil)
    }

    @Test func aComposersPrintIsTheAverageOfTheirTunes() {
        let print = ControlCommands.Print(path: "/MUSICIANS/H/Hubbard_Rob", traits: [0.5, 0.25])
        #expect(print.traits == [0.5, 0.25])
        #expect(print.mix == nil)
    }

    @Test func describingWhatsPlayingNeedsATuneFromTheCollection() async throws {
        let reply = try await ask("describe.playing")
        #expect(reply["ok"] as? Bool == false)
        #expect((reply["error"] as? String)?.contains("like") == true)
    }

    @Test func anUnknownCommandSaysSo() async throws {
        let reply = try await ask("dance")
        #expect(reply["ok"] as? Bool == false)
        #expect((reply["error"] as? String)?.contains("dance") == true)
    }

    @Test func nonsenseGetsAnAnswerToo() async throws {
        let reply = await commands.handle(Data("not json".utf8))
        let parsed = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect(parsed["ok"] as? Bool == false)
    }

    @Test func transportGoesToTheCore() async throws {
        _ = try await ask("next")
        _ = try await ask("prev")
        _ = try await ask("stop")
        #expect(fake.calls.contains("next"))
        #expect(fake.calls.contains("previous"))
        #expect(fake.calls.contains("stop"))
    }

    @Test func playlistsAreFoundIgnoringCase() async throws {
        #expect(try await ask("playlist.new", ["name": "Late Night", "paths": ["/a.sid", "/b.sid"]])["ok"] as? Bool == true)
        let list = try #require(playlists.playlists.first)
        #expect(playlists.read(list) == ["/a.sid", "/b.sid"])
        #expect(try await ask("playlist.add", ["name": "late night", "paths": ["/c.sid"]])["ok"] as? Bool == true)
        #expect(playlists.read(list) == ["/a.sid", "/b.sid", "/c.sid"])
    }

    @Test func aMissingPlaylistSaysWhich() async throws {
        let reply = try await ask("playlist.show", ["name": "Nope"])
        #expect(reply["error"] as? String == "You have no playlist called Nope.")
    }

    @Test func tunesCanBeRemovedAndMoved() async throws {
        _ = try await ask("playlist.new", ["name": "L", "paths": ["/a.sid", "/b.sid", "/c.sid"]])
        let list = try #require(playlists.playlists.first)
        _ = try await ask("playlist.mv", ["name": "L", "paths": ["/c.sid"], "before": "/a.sid"])
        #expect(playlists.read(list) == ["/c.sid", "/a.sid", "/b.sid"])
        _ = try await ask("playlist.rm", ["name": "L", "paths": ["/a.sid"]])
        #expect(playlists.read(list) == ["/c.sid", "/b.sid"])
    }

    @Test func aPlaylistCanBeRenamedAndDeleted() async throws {
        _ = try await ask("playlist.new", ["name": "Old"])
        #expect(try await ask("playlist.rename", ["name": "Old", "to": "New"])["ok"] as? Bool == true)
        #expect(playlists.playlists.map(\.name) == ["New"])
        #expect(try await ask("playlist.delete", ["name": "New"])["ok"] as? Bool == true)
        #expect(playlists.playlists.isEmpty)
    }

    @Test func favoritesStayFavorites() async throws {
        #expect(try await ask("playlist.delete", ["name": "favorites"])["ok"] as? Bool == false)
        #expect(try await ask("playlist.mv", ["name": "Favorites", "paths": ["/a.sid"]])["ok"] as? Bool == false)
    }

    @Test func playingAMissingFileSaysSo() async throws {
        let reply = try await ask("play", ["paths": ["/nowhere/a.sid"]])
        #expect((reply["error"] as? String)?.contains("/nowhere/a.sid") == true)
    }

    @Test func favoritingNeedsSomethingPlaying() async throws {
        #expect(try await ask("fav")["error"] as? String == "Nothing is playing.")
    }
}

struct ControlSearchTests {
    private let item = HvscTuneItem(path: "/hvsc/MUSICIANS/H/Hubbard_Rob/Commando.sid", title: "Commando", author: "Hubbard, Rob",
                                    released: "1985", songs: 1, startSong: 1, durationSecs: nil, hasStil: false,
                                    isRsid: nil, category: .musicians)

    @Test func everyWordHasToBeThereSomewhere() {
        #expect(ControlCommands.holds(["hubbard", "commando"], item))
        #expect(ControlCommands.holds(["COMMANDO", "rob"], item))
        #expect(!ControlCommands.holds(["galway", "commando"], item))
    }

    @Test func accentsDontMatter() {
        #expect(ControlCommands.holds(["hübbard"], item))
    }
}

@Suite(.serialized)
struct ControlServerSocketTests {
    private func path() -> String {
        // Short: a socket's path has to fit in about 100 bytes. In the
        // container, which is all the sandbox lets the tests write.
        (NSHomeDirectory() as NSString).appendingPathComponent("rc-\(UUID().uuidString.prefix(8)).sock")
    }

    private func connect(_ path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(result == 0)
        return socket
    }

    private func readLine(_ socket: Int32) -> String {
        var line = [UInt8]()
        var byte: UInt8 = 0
        while read(socket, &byte, 1) == 1, byte != 10 { line.append(byte) }
        return String(decoding: line, as: UTF8.self)
    }

    @Test func answersEachLineInOrder() throws {
        let path = path()
        let server = ControlServer(path: path) { line in Data("echo \(String(decoding: line, as: UTF8.self))".utf8) }
        try server.start()
        defer { server.stop() }
        let socket = try connect(path)
        defer { close(socket) }
        _ = "one\ntwo\n".withCString { write(socket, $0, 8) }
        #expect(readLine(socket) == "echo one")
        #expect(readLine(socket) == "echo two")
    }

    @Test func onlyItsOwnerCanReachIt() throws {
        let path = path()
        let server = ControlServer(path: path) { _ in Data() }
        try server.start()
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func replacesASocketLeftBehind() throws {
        let path = path()
        let first = ControlServer(path: path) { _ in Data() }
        try first.start()
        let second = ControlServer(path: path) { _ in Data("second".utf8) }
        try second.start()
        defer {
            second.stop()
            first.stop()
        }
        let socket = try connect(path)
        defer { close(socket) }
        _ = "x\n".withCString { write(socket, $0, 2) }
        #expect(readLine(socket) == "second")
    }

    @Test func stoppingRemovesIt() throws {
        let path = path()
        let server = ControlServer(path: path) { _ in Data() }
        try server.start()
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func thePathFitsASocket() {
        #expect(ControlServer.defaultPath.utf8.count < 104)
    }

    @Test func aPathTooLongIsRefused() {
        let long = "/tmp/" + String(repeating: "x", count: 200)
        #expect(throws: ControlServer.StartError.self) { try ControlServer(path: long) { _ in Data() }.start() }
    }
}

struct SoundDriftTests {
    private func tune(_ name: String, by author: String = "A") -> HvscTuneItem {
        HvscTuneItem(path: "/\(name).sid", title: name, author: author, released: "", songs: 1, startSong: 1,
                     durationSecs: nil, hasStil: false, isRsid: nil, category: .musicians)
    }

    private func step(_ matches: [HvscTuneItem], visited: Set<String> = [], recent: [String] = []) -> HvscTuneItem? {
        var rng = SystemRandomNumberGenerator()
        return SoundDrift.step(from: matches, visited: visited, recentComposers: recent, using: &rng)
    }

    @Test func neverRepeatsATune() {
        for _ in 0..<50 {
            #expect(step([tune("a"), tune("b")], visited: ["/a.sid"])?.title == "b")
        }
    }

    @Test func movesOnFromComposersItJustHeard() {
        for _ in 0..<50 {
            #expect(step([tune("a", by: "Rob"), tune("b", by: "Martin")], recent: ["Rob"])?.title == "b")
        }
    }

    /// Better one of theirs than the drift ending.
    @Test func staysWithAComposerWhenTheresNoOneElse() {
        #expect(step([tune("a", by: "Rob")], recent: ["Rob"])?.title == "a")
    }

    @Test func staysAmongTheClosest() {
        let matches = (0..<20).map { tune("t\($0)", by: "C\($0)") }
        for _ in 0..<200 {
            let chosen = step(matches)
            #expect(matches.prefix(SoundDrift.spread).contains { $0.path == chosen?.path })
        }
    }

    @Test func varies() {
        let matches = (0..<20).map { tune("t\($0)", by: "C\($0)") }
        #expect(Set((0..<100).compactMap { _ in step(matches)?.path }).count > 1)
    }

    @Test func endsWhenThereIsNowhereToGo() {
        #expect(step([]) == nil)
        #expect(step([tune("a")], visited: ["/a.sid"]) == nil)
    }

    @Test func itsNameSaysWhereItStarted() {
        #expect(PlaybackSource.drift(title: "Commando").name == "Drifting from Commando")
        #expect(PlaybackSource.drift(title: "Commando").kind == "Sound Drift")
    }
}
