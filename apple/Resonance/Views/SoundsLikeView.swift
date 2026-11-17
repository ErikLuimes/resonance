import SwiftUI
import PhosphorCore

/// The Sounds Like page: the tunes across the collection that sound most like
/// one, closest first. It follows what's playing until Find Similar picks a
/// tune, and each Find Similar from here is a hop along a trail, which leads
/// back the way it came.
struct SoundsLikeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var store
    @Environment(FingerprintStore.self) private var fingerprints
    @Environment(PlaylistsStore.self) private var playlists

    @State private var closeness = SmartSettings.Closeness.close
    @State private var filter = ""
    /// The matches for `loadedFor`; nil while they load.
    @State private var matches: [SimilarTune]?
    @State private var loadedFor: LoadKey?
    @State private var savedFor: LoadKey?

    private struct LoadKey: Equatable {
        let path: String
        let closeness: SmartSettings.Closeness
    }

    /// The playing tune, when it's in the collection.
    private var playingSeed: SmartSettings.Seed? {
        guard let track = store.nowPlaying, library.category(of: track.path) != nil else { return nil }
        return .init(path: track.path, title: track.displayTitle, author: track.author)
    }

    /// The tune shown: the trail's last, else what's playing.
    private var seed: SmartSettings.Seed? { library.likeTrail.last ?? playingSeed }

    private var isFollowing: Bool { library.likeTrail.isEmpty }

    var body: some View {
        Group {
            if !store.hasCollection {
                noCollection
            } else if let seed {
                VStack(spacing: 0) {
                    header(seed)
                    if library.likeTrail.count > 1 { trail }
                    Divider()
                    list(seed)
                }
                .task(id: LoadKey(path: seed.path, closeness: closeness)) { await load(seed) }
            } else {
                start
            }
        }
        .onAppear { library.isShowingSoundsLike = true }
        .onDisappear { library.isShowingSoundsLike = false }
        .onChange(of: playingSeed, initial: true) { library.likeFollowed = playingSeed }
    }

    private func load(_ seed: SmartSettings.Seed) async {
        let key = LoadKey(path: seed.path, closeness: closeness)
        if loadedFor?.path != key.path { matches = nil }
        fingerprints.load([seed.path])
        let found = (try? await store.core.similarTunes(path: seed.path, subtune: nil, limit: closeness.rawValue)) ?? []
        guard !Task.isCancelled else { return }
        matches = found
        loadedFor = key
    }

    private var rows: [LibraryRow] { (matches ?? []).map { LibraryRow(item: $0.item) }.numbered() }

    private var shownRows: [LibraryRow] {
        let words = filter.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return rows }
        return rows.filter { $0.title.localizedStandardContains(words) || $0.author.localizedStandardContains(words) }
    }

    // MARK: Header

    private func header(_ seed: SmartSettings.Seed) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Group {
                if let print = fingerprints.fingerprint(seed.path) {
                    MorphSphere(fingerprint: print, zoom: 1.2, isActive: !store.isShowingNowPlaying)
                } else {
                    Circle().fill(.fill.quaternary)
                }
            }
            .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 3) {
                eyebrow
                Text(seed.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                if !seed.author.isEmpty {
                    Text(seed.author)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let summary = fingerprints.fingerprint(seed.path)?.summary {
                    Text(summary)
                        .lineLimit(2)
                        .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                Button("Play All") { library.play(rows, from: .soundsLike(title: seed.title, seed: seed.path)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(rows.isEmpty)
                Button("Drift From Here") {
                    Task { _ = await fingerprints.startDrift(from: nil, path: seed.path, with: library) }
                }
                .help("An endless radio: each tune sounds like the one before")
                Button(savedFor == loadedFor && savedFor != nil ? "Saved" : "Save as Playlist") { save(seed) }
                    .disabled(rows.isEmpty || (savedFor == loadedFor && savedFor != nil))
                    .help("Keeps these tunes as one of your playlists. It stays as it is now.")
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var eyebrow: some View {
        HStack(spacing: 6) {
            if isFollowing {
                Circle().fill(.tint).frame(width: 6, height: 6)
                Text("Following what's playing")
                    .foregroundStyle(.secondary)
            } else {
                Text("Sounds like")
                    .foregroundStyle(.secondary)
                if playingSeed != nil {
                    AccentLink(String(localized: "Follow What's Playing")) { library.likeTrail = [] }
                }
            }
        }
        .font(.caption)
    }

    private func save(_ seed: SmartSettings.Seed) {
        let files = rows.map(\.id)
        let key = loadedFor
        Task {
            await playlists.addToNew(files, named: String(localized: "Sounds like \(seed.title)"))
            savedFor = key
        }
    }

    // MARK: Trail

    /// The way here: each earlier tune a link back to it.
    private var trail: some View {
        HStack(spacing: 6) {
            let steps = library.likeTrail
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index == steps.count - 1 {
                    Text(step.title)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                } else {
                    AccentLink(step.title) { library.likeTrail = Array(steps.prefix(index + 1)) }
                        .lineLimit(1)
                        .help("Back to what sounds like \u{201C}\(step.title)\u{201D}")
                    Text("›").foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    // MARK: List

    @ViewBuilder
    private func list(_ seed: SmartSettings.Seed) -> some View {
        if let matches, loadedFor?.path == seed.path {
            if matches.isEmpty {
                if fingerprints.fingerprint(seed.path) == nil {
                    ContentUnavailableView("Not Scanned Yet", systemImage: "waveform",
                                           description: Text("Resonance hasn't learned how this tune sounds yet. Try another one, or come back when the scan has reached it."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Nothing Else Fingerprinted Yet", systemImage: "waveform",
                                           description: Text("Sounds Like fills in as the scan goes on."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                LibraryTable(rows: shownRows, source: .soundsLike(title: seed.title), actions: AnyView(listActions), numbered: true,
                             matches: TuneMatches(seed: seed.path, scores: Dictionary(matches.map { ($0.item.path, Double(max(0, $0.score))) },
                                                                                   uniquingKeysWith: max)))
                    .overlay {
                        if shownRows.isEmpty { ContentUnavailableView.search(text: filter) }
                    }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// After Sound, in the row above the list: how far down the closest it
    /// goes, as in Smart Playlists, and the filter.
    private var listActions: some View {
        Group {
            Picker("Closeness", selection: $closeness) {
                ForEach(SmartSettings.Closeness.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("How far down the closest tunes the list goes")
            ListFilterField(text: $filter)
        }
    }

    // MARK: Nothing to show yet

    private var start: some View {
        ContentUnavailableView {
            Label("What Should It Sound Like?", systemImage: "waveform.badge.magnifyingglass")
        } description: {
            Text("Play a tune and this follows it, or choose Find Similar on any tune.")
        } actions: {
            let recent = Array((library.recent ?? []).prefix(4))
            if !recent.isEmpty {
                VStack(spacing: 6) {
                    Text("Recently played")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        ForEach(recent, id: \.row.id) { play in
                            AccentLink(play.row.title) {
                                library.findSimilar(.init(path: play.row.id, title: play.row.title, author: play.row.author))
                            }
                            .lineLimit(1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await library.loadRecent() }
    }

    private var noCollection: some View {
        ContentUnavailableView {
            Label("Sounds Like Searches the Collection", systemImage: "archivebox")
        } description: {
            Text("Download it first, then play a tune or choose Find Similar on one.")
        } actions: {
            Button("Download the Collection") { store.startHvscSync() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
