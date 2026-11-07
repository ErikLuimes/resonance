import AppKit
import Foundation
import PhosphorCore

/// What the `resonance` command line tool can ask of the app. A request is
/// `{"id": 1, "cmd": "search", "args": {"text": "commando"}}`; its answer is
/// `{"id": 1, "ok": true, "result": …}` or `{"id": 1, "ok": false, "error": "…"}`.
/// Everything goes through the same stores as the window, so the two agree.
final class ControlCommands {
    struct Request: Decodable {
        var id: Int = 0
        var cmd: String
        var args: Args = Args()

        private enum CodingKeys: String, CodingKey { case id, cmd, args }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
            cmd = try container.decode(String.self, forKey: .cmd)
            args = try container.decodeIfPresent(Args.self, forKey: .args) ?? Args()
        }
    }

    struct Args: Decodable {
        var text: String?
        var limit: Int?
        var path: String?
        var paths: [String]?
        var start: String?
        var name: String?
        var to: String?
        var before: String?
        var on: Bool?
        var play: Bool?
        var count: Int?
    }

    struct Failure: Error {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }

    struct Tune: Encodable, Equatable {
        let path: String
        let title: String
        let author: String
        let released: String
        let songs: Int
        let secs: Int?
        /// How alike, 0–1, in Sounds Like.
        var score: Double?

        init(_ item: HvscTuneItem, score: Double? = nil) {
            path = item.path
            title = item.title
            author = item.author
            released = item.released
            songs = Int(item.songs)
            secs = item.durationSecs.map(Int.init)
            self.score = score
        }
    }

    struct Status: Encodable {
        struct Now: Encodable {
            let path: String
            let title: String
            let author: String
            let released: String
            let song: Int
            let songs: Int
        }

        /// "playing", "paused" or "stopped".
        let state: String
        let now: Now?
        let elapsed: Double
        let duration: Double?
        let hasCollection: Bool
        let favourite: Bool
    }

    struct PlaylistInfo: Encodable {
        let name: String
        let count: Int
        let isFavourites: Bool
    }

    struct Described: Encodable {
        let title: String
        let note: String?
        let tunes: [Tune]
    }

    struct Scope: Encodable {
        let voices: [[Float]]
    }

    struct Done: Encodable {}

    private struct Envelope<T: Encodable>: Encodable {
        let id: Int
        let ok: Bool
        let result: T?
        let error: String?
    }

    private let player: PlayerStore
    private let library: LibraryStore
    private let fingerprints: FingerprintStore
    private let playlists: PlaylistsStore

    init(player: PlayerStore, library: LibraryStore, fingerprints: FingerprintStore, playlists: PlaylistsStore) {
        self.player = player
        self.library = library
        self.fingerprints = fingerprints
        self.playlists = playlists
    }

    /// Answer one line from the socket.
    func handle(_ line: Data) async -> Data {
        let decoder = JSONDecoder()
        guard let request = try? decoder.decode(Request.self, from: line) else {
            return Self.reply(id: 0, Result<Done, Failure>.failure(Failure("That request couldn't be read.")))
        }
        do {
            return try await run(request)
        } catch let failure as Failure {
            return Self.reply(id: request.id, Result<Done, Failure>.failure(failure))
        } catch {
            return Self.reply(id: request.id, Result<Done, Failure>.failure(Failure(LibraryStore.message(for: error))))
        }
    }

    private static func reply<T: Encodable>(id: Int, _ result: Result<T, Failure>) -> Data {
        let envelope = switch result {
        case .success(let value): Envelope<T>(id: id, ok: true, result: value, error: nil)
        case .failure(let failure): Envelope<T>(id: id, ok: false, result: nil, error: failure.message)
        }
        return (try? JSONEncoder().encode(envelope)) ?? Data(#"{"id":0,"ok":false,"error":"Couldn't answer."}"#.utf8)
    }

    private func run(_ request: Request) async throws -> Data {
        let args = request.args
        func answer<T: Encodable>(_ value: T) -> Data { Self.reply(id: request.id, Result<T, Failure>.success(value)) }
        func done() -> Data { answer(Done()) }

        switch request.cmd {
        // MARK: Playback
        case "status":
            return answer(status())
        case "play":
            if let paths = args.paths, !paths.isEmpty {
                try play(paths, start: args.start, from: args.text.map { .search(query: $0) } ?? .files)
            } else if !player.isPlaying {
                player.playPause()
            }
            return done()
        case "pause":
            if player.isPlaying { player.playPause() }
            return done()
        case "toggle":
            player.playPause()
            return done()
        case "stop":
            player.stop()
            return done()
        case "next":
            player.next()
            return done()
        case "prev":
            player.previous()
            return done()
        case "surprise":
            guard library.hasRoot else { throw Failure("Resonance doesn't have the HVSC collection yet.") }
            await library.surpriseMe()
            return done()
        case "fav":
            let track = try playing()
            await playlists.setFavourite(track.path, args.on ?? true)
            return answer(Tune(path: track.path, title: track.displayTitle, author: track.author, released: track.released))
        case "show":
            guard let path = args.path else { throw Failure("Which tune?") }
            library.reveal(tunePath: path)
            player.isShowingNowPlaying = false
            NSApp.activate()
            MiniPlayer.openMainWindow?()
            return done()
        case "scope":
            let scope = player.visualizer.scope(chip: 0, count: min(max(args.count ?? 256, 16), 2048))
            return answer(Scope(voices: scope.voices))

        // MARK: Finding
        case "search":
            let text = args.text ?? ""
            guard !text.isEmpty else { return answer([Tune]()) }
            return answer(try await search(text).prefix(args.limit ?? 50).map { Tune($0) })
        case "like":
            let seed = try args.path ?? playing().path
            let found = try await player.core.similarTunes(path: seed, subtune: nil, limit: UInt32(clamping: args.limit ?? 20))
            guard !found.isEmpty else { throw Failure("Resonance hasn't fingerprinted this tune yet.") }
            if args.play == true {
                library.play(found.map { LibraryRow(item: $0.item) },
                             from: .soundsLike(title: player.nowPlaying?.displayTitle ?? "this tune"))
            }
            return answer(found.map { Tune($0.item, score: Double(max(0, $0.score))) })
        case "describe":
            guard let text = args.text, !text.isEmpty else { throw Failure("Say what you'd like to hear.") }
            return answer(try await describe(text, play: args.play ?? true))
        case "recent":
            let recent = try await player.core.recentlyPlayed()
            return answer(recent.prefix(args.limit ?? 100).map { Tune($0.item) })

        // MARK: Playlists
        case "playlist.list":
            if playlists.favourites == nil { await playlists.loadFavourites() }
            var lists = [PlaylistInfo(name: "Favourites", count: playlists.favourites?.count ?? 0, isFavourites: true)]
            lists += playlists.playlists.map { PlaylistInfo(name: $0.name, count: playlists.read($0).count, isFavourites: false) }
            return answer(lists)
        case "playlist.show":
            return answer(try await tunes(of: try target(args.name)))
        case "playlist.play":
            let list = try target(args.name)
            let shown = try await tunes(of: list)
            guard !shown.isEmpty else { throw Failure("\(list.name) has no tunes in it.") }
            try play(shown.map(\.path), start: args.start, from: list.source)
            return done()
        case "playlist.new":
            guard let name = args.name, !name.isEmpty else { throw Failure("What should it be called?") }
            guard let made = playlists.create(named: name) else { throw Failure("Couldn't make \(name).") }
            if let paths = args.paths { await playlists.add(paths, to: .playlist(made.id)) }
            return answer(PlaylistInfo(name: made.name, count: args.paths?.count ?? 0, isFavourites: false))
        case "playlist.add":
            let list = try target(args.name)
            await playlists.add(args.paths ?? [], to: list.addTarget)
            return done()
        case "playlist.rm":
            let list = try target(args.name)
            let paths = args.paths ?? []
            if let own = list.playlist {
                playlists.remove(Set(paths), from: own)
            } else {
                for path in paths { await playlists.setFavourite(path, false) }
            }
            return done()
        case "playlist.mv":
            let list = try target(args.name)
            guard let own = list.playlist else { throw Failure("Favourites keeps its own order.") }
            playlists.place(args.paths ?? [], before: args.before, in: own)
            return done()
        case "playlist.rename":
            let list = try target(args.name)
            guard let own = list.playlist else { throw Failure("Favourites keeps its name.") }
            guard let to = args.to, playlists.rename(own, to: to) != nil else {
                throw Failure("That name is empty or taken.")
            }
            return done()
        case "playlist.delete":
            let list = try target(args.name)
            guard let own = list.playlist else { throw Failure("Favourites can't be deleted.") }
            playlists.delete(own)
            return done()
        default:
            throw Failure("Resonance doesn't know “\(request.cmd)”. It may be older than this tool.")
        }
    }

    // MARK: Helpers

    /// The collection's search looks at one field at a time, so "hubbard
    /// commando" finds nothing. Then: the longest word, narrowed by the others.
    private func search(_ text: String) async throws -> [HvscTuneItem] {
        let found = try await player.core.hvscSearch(query: text, scope: nil).items
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard found.isEmpty, words.count > 1, let longest = words.max(by: { $0.count < $1.count }) else { return found }
        return try await player.core.hvscSearch(query: longest, scope: nil).items.filter { Self.holds(words, $0) }
    }

    /// Whether every word is in the tune's title, composer or path, which also
    /// names its composer when the header doesn't.
    nonisolated static func holds(_ words: [String], _ item: HvscTuneItem) -> Bool {
        let haystack = "\(item.title) \(item.author) \(item.path)"
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private func playing() throws -> TrackDetails {
        guard let track = player.nowPlaying else { throw Failure("Nothing is playing.") }
        return track
    }

    private func status() -> Status {
        let track = player.nowPlaying
        let state = switch player.state {
        case .playing: "playing"
        case .paused: "paused"
        case .stopped: "stopped"
        }
        return Status(
            state: state,
            now: track.map {
                Status.Now(path: $0.path, title: $0.displayTitle, author: $0.author, released: $0.released,
                           song: Int($0.currentSong), songs: Int($0.songs))
            },
            elapsed: player.elapsed,
            duration: player.duration,
            hasCollection: player.hasCollection,
            favourite: track.map { playlists.isFavourite($0.path) } ?? false
        )
    }

    private func play(_ paths: [String], start: String?, from source: PlaybackSource) throws {
        let urls = paths.map { URL(filePath: $0) }
        guard let first = start.map({ URL(filePath: $0) }) ?? urls.first else { return }
        guard FileManager.default.fileExists(atPath: first.path) else { throw Failure("There's no tune at \(first.path).") }
        player.playQueue(urls, startAt: first, from: source)
    }

    private func describe(_ text: String, play shouldPlay: Bool) async throws -> Described {
        await library.describe(text, isFinal: true)
        let settings = library.smartSettings
        guard settings.isReady else { throw Failure("Resonance couldn't make a list from that.") }
        let made = try await player.core.smartPlaylist(recipe: settings.recipe)
        let items = made.tunes.map(\.item)
        guard !items.isEmpty else { throw Failure("No tunes fit that.") }
        if shouldPlay {
            library.play(items.map(LibraryRow.init), from: .smart(title: settings.title))
        }
        return Described(title: settings.title, note: settings.note, tunes: items.map { Tune($0) })
    }

    /// Favourites or one of your playlists, by name.
    struct Target {
        let name: String
        /// Nil for Favourites.
        let playlist: UserPlaylist?

        var source: PlaybackSource {
            playlist.map { .playlist(id: $0.id, name: $0.name) } ?? .favourites
        }

        var addTarget: AddTarget {
            playlist.map { .playlist($0.id) } ?? .favourites
        }
    }

    private func target(_ name: String?) throws -> Target {
        guard let name, !name.isEmpty else { throw Failure("Which playlist?") }
        if ["favourites", "favorites"].contains(name.lowercased()) {
            return Target(name: "Favourites", playlist: nil)
        }
        let matches = playlists.playlists.filter { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        guard let found = matches.first else { throw Failure("You have no playlist called \(name).") }
        return Target(name: found.name, playlist: found)
    }

    private func tunes(of list: Target) async throws -> [Tune] {
        let id = list.playlist?.id ?? PlaylistsStore.favouritesID
        await playlists.loadRows(id)
        return (playlists.rows[id] ?? []).map { Tune($0.item) }
    }
}

private extension ControlCommands.Tune {
    /// The tune playing, which has no length to hand here.
    init(path: String, title: String, author: String, released: String) {
        self.path = path
        self.title = title
        self.author = author
        self.released = released
        songs = 1
        secs = nil
        score = nil
    }
}
