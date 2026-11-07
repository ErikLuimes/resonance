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
        var detail: Bool?
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
        /// When it was last played, in seconds since 1970, in Recently Played.
        var playedAt: UInt64?

        init(_ item: HvscTuneItem, score: Double? = nil, playedAt: UInt64? = nil) {
            path = item.path
            title = item.title
            author = item.author
            released = item.released
            songs = Int(item.songs)
            secs = item.durationSecs.map(Int.init)
            self.score = score
            self.playedAt = playedAt
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
        /// The list it's playing from.
        let source: String?
    }

    struct PlaylistInfo: Encodable {
        let name: String
        let count: Int
        let isFavourites: Bool
    }

    struct Described: Encodable {
        let title: String
        let note: String?
        /// What it took from the sentence, in words.
        let understood: String?
        /// "19 tunes, 61 minutes".
        let facts: String?
        let tunes: [Tune]
    }

    struct Scope: Encodable {
        let voices: [[Float]]
    }

    /// A tune as a tracker would show it, short-named as it can run to thousands of rows.
    struct TrackerAnswer: Encodable {
        struct Instrument: Encodable {
            let name: String
            let ad: UInt8
            let sr: UInt8
        }

        struct Row: Encodable {
            let f: UInt32
            /// Each voice: "C-4 02 ARP", "--- 00 VIB", or empty for nothing at all.
            let v: [String]
            let c: UInt16
            let r: UInt8
            let ro: UInt8
            let m: UInt8

            init(_ row: TrackerRow) {
                f = row.frame
                v = row.voices.map { cell in
                    let effect = switch cell.effect {
                    case .arpeggio: "ARP"
                    case .slide: "SLD"
                    case .vibrato: "VIB"
                    case .none: "..."
                    }
                    if cell.note == nil, !cell.off, cell.effect == .none { return "" }
                    let note = cell.note ?? (cell.off ? "---" : "...")
                    return "\(note) \(String(format: "%02X", cell.instrument)) \(effect)"
                }
                c = row.cutoff
                r = row.resonance
                ro = row.filterRouting
                m = row.filterMode
            }
        }

        let path: String
        let song: Int
        let frameRate: Double
        let framesPerRow: Float
        let hasGrid: Bool
        let chips: UInt32
        let instruments: [Instrument]
        let rows: [Row]
    }

    /// What's being heard, for the tracker's playhead.
    struct TrackerPosition: Encodable {
        let path: String?
        let song: Int
        let heard: Double?
        let levels: [Float]
        let notes: [String?]
    }

    struct Sound: Encodable {
        let summary: String
        let tags: [String]
    }

    /// A tune's fingerprint for drawing: the nine traits, and with `detail` its
    /// waveform mix and how loud each voice is across the tune.
    struct Print: Encodable {
        struct Mix: Encodable {
            let triangle: Float
            let saw: Float
            let pulse: Float
            let noise: Float
        }

        let path: String
        let traits: [Float]
        let mix: Mix?
        let activity: [[UInt8]]?

        /// A composer's sound: the average of their tunes.
        init(path: String, traits: [Float]) {
            self.path = path
            self.traits = traits
            mix = nil
            activity = nil
        }

        init(path: String, print: TuneFingerprint, detail: Bool) {
            self.path = path
            traits = print.traits
            mix = detail ? Mix(triangle: print.mix.triangle, saw: print.mix.saw, pulse: print.mix.pulse, noise: print.mix.noise) : nil
            let levels = Array(print.activity)
            let bins = max(Int(print.bins), 1)
            activity = detail ? stride(from: 0, to: levels.count, by: bins).map {
                Array(levels[$0..<min($0 + bins, levels.count)])
            } : nil
        }
    }

    /// The collection's front door, as the HVSC Home shows it.
    struct HvscOverview: Encodable {
        struct Update: Encodable {
            let number: UInt32
            let newSids: UInt32?
            let fixedRips: UInt32?
            let creditFixes: UInt32?
            let moved: UInt32?
            let text: String
        }

        struct Playlist: Encodable {
            let name: String
            let file: String
            let tracks: UInt32
        }

        struct Disk: Encodable {
            let name: String
            let images: UInt32
        }

        let version: String?
        let releaseDate: String?
        let totalTunes: UInt32
        let musicianTunes: UInt32
        let gameTunes: UInt32
        let demoTunes: UInt32
        let composers: UInt32
        let songlengthEntries: UInt32
        let documents: UInt32
        let update: Update?
        let disks: [Disk]
        let playlists: [Playlist]

        init(_ info: HvscInfo) {
            version = info.version
            releaseDate = info.releaseDate
            totalTunes = info.totalTunes
            musicianTunes = info.musicianTunes
            gameTunes = info.gameTunes
            demoTunes = info.demoTunes
            composers = info.composers
            songlengthEntries = info.songlengthEntries
            documents = info.documents
            update = info.update.map {
                Update(number: $0.number, newSids: $0.newSids, fixedRips: $0.fixedRips, creditFixes: $0.creditFixes,
                       moved: $0.moved, text: $0.text)
            }
            disks = info.disks.map { Disk(name: $0.name, images: $0.images) }
            playlists = info.playlists.map { Playlist(name: $0.name, file: $0.file, tracks: $0.tracks) }
        }
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
                let source: PlaybackSource = if let title = args.name {
                    .smart(title: title)
                } else {
                    args.text.map { .search(query: $0) } ?? .files
                }
                try play(paths, start: args.start, from: source)
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

        case "tracker.position":
            let voices = player.visualizer.latest()?.chips.first?.voices ?? []
            return answer(TrackerPosition(
                path: player.nowPlaying?.path, song: Int(player.nowPlaying?.currentSong ?? 0),
                heard: player.core.vizHeardSecs(), levels: voices.map(\.envLevel), notes: voices.map(\.note)
            ))
        case "tracker.song":
            guard let track = player.nowPlaying else { throw Failure("Nothing is playing.") }
            // Its known length, else the longest a tune with none usually gets.
            let secs = min((player.duration ?? 300) + 2, 900)
            let song = try await player.core.trackerSong(path: track.path, subtune: UInt16(clamping: track.currentSong), secs: secs, chip: 0)
            return answer(TrackerAnswer(
                path: track.path, song: Int(track.currentSong), frameRate: song.frameRate, framesPerRow: song.framesPerRow,
                hasGrid: song.hasGrid, chips: song.chips,
                instruments: song.instruments.map { .init(name: $0.name, ad: $0.attackDecay, sr: $0.sustainRelease) },
                rows: song.rows.map(TrackerAnswer.Row.init)
            ))

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
        case "drift":
            let started = await fingerprints.startDrift(from: args.path == nil ? try playing() : nil, path: args.path, with: library)
            guard started else { throw Failure("Resonance hasn't fingerprinted this tune yet.") }
            return done()
        case "sound":
            let path = try args.path ?? playing().path
            guard let print = await player.core.fingerprints(paths: [path]).first ?? nil else {
                throw Failure("Resonance hasn't fingerprinted this tune yet.")
            }
            return answer(Sound(summary: print.summary, tags: print.tags.map(\.name)))
        case "prints":
            // Only tunes with a fingerprint are in the answer.
            let paths = args.paths ?? []
            let found = await player.core.fingerprints(paths: paths)
            let detail = args.detail ?? false
            return answer(zip(paths, found).compactMap { path, print in
                print.map { Print(path: path, print: $0, detail: detail) }
            })
        case "prints.composers":
            return answer(await composerPrints(args.paths ?? []))
        case "guess.pool":
            return answer(try await guessPool())
        case "describe":
            guard let text = args.text, !text.isEmpty else { throw Failure("Say what you'd like to hear.") }
            return answer(try await describe(text, play: args.play ?? true))
        case "describe.playing":
            return answer(try await describePlaying())
        case "recent":
            let recent = try await player.core.recentlyPlayed()
            return answer(recent.prefix(args.limit ?? 100).map { Tune($0.item, playedAt: $0.playedAt) })

        // MARK: HVSC
        case "hvsc.info":
            return answer(HvscOverview(try await collectionInfo()))
        case "hvsc.authors":
            let category = try hvscCategory(args.name)
            await library.loadAuthors(category)
            await library.loadComposers(category)
            let composers = library.composers[category] ?? [:]
            return answer((library.authors[category] ?? []).map { Tune(author: $0, composer: composers[$0.path]) })
        case "hvsc.tunes":
            guard let path = args.path else { throw Failure("Which composer?") }
            await library.loadTunes(authorPath: path)
            return answer((library.tunes[path] ?? []).map { Tune($0.item) })
        case "hvsc.playlist":
            let playlist = try await curated(args.name)
            await library.loadPlaylist(playlist)
            let rows = library.playlistTunes[playlist.file] ?? nil
            return answer((rows ?? []).map { Tune($0.item) })
        case "hvsc.playlist.play":
            player.playPublishedPlaylist(try await curated(args.name))
            return done()
        case "hvsc.shuffle":
            guard library.hasRoot else { throw Failure("There's no collection on this Mac yet.") }
            await library.shuffleCollection()
            return done()

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
            favourite: track.map { playlists.isFavourite($0.path) } ?? false,
            source: player.source?.name
        )
    }

    private func collectionInfo() async throws -> HvscInfo {
        await player.loadHvscInfo()
        guard let info = player.hvscInfo else { throw Failure("There's no collection on this Mac yet.") }
        return info
    }

    private func hvscCategory(_ name: String?) throws -> HvscCategory {
        switch name?.lowercased() {
        case "musicians": .musicians
        case "demos": .demos
        case "games": .games
        default: throw Failure("Musicians, Demos or Games?")
        }
    }

    private func curated(_ file: String?) async throws -> HvscPlaylist {
        let info = try await collectionInfo()
        guard let found = info.playlists.first(where: { $0.file == file }) else {
            throw Failure("There's no such playlist.")
        }
        return found
    }

    /// The average of each composer's fingerprinted tunes, leaving out any with none.
    private func composerPrints(_ paths: [String]) async -> [Print] {
        var found: [Print] = []
        for path in paths.prefix(80) {
            guard let tunes = try? await player.core.hvscTunes(authorPath: path) else { continue }
            let prints = await player.core.fingerprints(paths: tunes.map(\.path)).compactMap(\.self)
            guard let length = prints.first?.traits.count else { continue }
            let total = prints.reduce(into: [Float](repeating: 0, count: length)) { sum, print in
                for index in sum.indices where print.traits.indices.contains(index) { sum[index] += print.traits[index] }
            }
            found.append(Print(path: path, traits: total.map { $0 / Float(prints.count) }))
        }
        return found
    }

    private func play(_ paths: [String], start: String?, from source: PlaybackSource) throws {
        let urls = paths.map { URL(filePath: $0) }
        guard let first = start.map({ URL(filePath: $0) }) ?? urls.first else { return }
        guard FileManager.default.fileExists(atPath: first.path) else { throw Failure("There's no tune at \(first.path).") }
        player.playQueue(urls, startAt: first, from: source)
    }

    /// What `resonance guess` chooses from: tunes people know, from HVSC's own
    /// Top 100, so a day's tune can be got.
    private func guessPool() async throws -> [Tune] {
        // The window asks for these as it opens; there may be no window yet.
        if player.hvscInfo == nil { await player.syncPublishedPlaylists() }
        let lists = player.hvscInfo?.playlists ?? []
        guard let list = lists.first(where: { $0.name.localizedCaseInsensitiveContains("top 100") }) ?? lists.first else {
            throw Failure("Resonance doesn't have HVSC's playlists yet.")
        }
        let files = player.publishedPlaylistTunes(list).map(\.path)
        return await player.core.tunesFromFiles(paths: files).map { Tune($0) }
    }

    private func describe(_ text: String, play shouldPlay: Bool) async throws -> Described {
        // HVSC's Top 100 is a list already; the window goes to it rather than working one out.
        if text.lowercased().contains("top 100"), let list = try? await collectionInfo().playlists.first(where: {
            $0.name.localizedCaseInsensitiveContains("top 100")
        }) {
            await library.loadPlaylist(list)
            let rows = library.playlistTunes[list.file] ?? nil
            if shouldPlay { player.playPublishedPlaylist(list) }
            return Described(title: list.name, note: nil, understood: nil,
                             facts: "\(list.tracks) tunes",
                             tunes: (rows ?? []).map { Tune($0.item) })
        }
        await library.describe(text, isFinal: true)
        return try await smartList(play: shouldPlay)
    }

    /// The closest to what's playing, as Similar to a Tune has it.
    private func describePlaying() async throws -> Described {
        guard let track = player.nowPlaying, player.hvscRoot.map(track.path.hasPrefix) == true else {
            throw Failure("Nothing from the collection is playing. Say “like” and a tune's name.")
        }
        library.describeTune(.init(path: track.path, title: track.title, author: track.author))
        return try await smartList(play: false)
    }

    /// The list for the sentence just read, or what the window would have said instead.
    private func smartList(play shouldPlay: Bool) async throws -> Described {
        let settings = library.smartSettings
        guard settings.isReady else { throw Failure("Resonance couldn't make a list from that.") }
        let made = try await player.core.smartPlaylist(recipe: settings.recipe)
        if made.needsMoreHistory {
            let heard = made.heard == 1 ? "1 tune" : "\(made.heard) tunes"
            throw Failure("New to Me compares what you've played with everything else. You've played \(heard) so far, so it would mostly be guessing. Try Never Heard.")
        }
        if made.seedNotScanned {
            throw Failure("Resonance hasn't learned how this tune sounds yet. Try another one, or come back when the scan has reached it.")
        }
        let items = made.tunes.map(\.item)
        guard !items.isEmpty else {
            if let instead = settings.understood?.likeInstead(of: settings.sentence) {
                throw Failure("No tune by that name fits, but some that sound like it may. Try “\(instead)”.")
            }
            throw Failure("No tunes fit that. Try asking for a little less.")
        }
        if shouldPlay {
            library.play(items.map(LibraryRow.init), from: .smart(title: settings.title))
        }
        let understood = settings.understood?.description(seedTitles: settings.describedSeeds.map {
            settings.understood?.composers.isEmpty == true ? "\($0.title) by \($0.author)" : $0.title
        })
        return Described(title: settings.title, note: settings.note, understood: understood,
                         facts: SmartFacts.tunes(items.count, secs: made.totalSecs), tunes: items.map { Tune($0) })
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
    /// A composer as a row: the name as its title, the real name as its author, the
    /// years as its release, and how many tunes as its songs.
    init(author: HvscAuthorItem, composer: HvscComposer?) {
        path = author.path
        title = author.displayName
        self.author = composer?.realName ?? ""
        released = switch (composer?.firstYear, composer?.lastYear) {
        case let (first?, last?) where first != last: "\(first)–\(last)"
        case let (first?, _): "\(first)"
        default: ""
        }
        songs = Int(composer?.tunes ?? 0)
        secs = nil
        score = nil
    }

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
