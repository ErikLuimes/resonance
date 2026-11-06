import SwiftUI
import PhosphorCore

/// A recipe in the app's terms. `SmartRecipe` is what the core takes.
nonisolated struct SmartSettings: Hashable, Sendable {
    enum Start: String, CaseIterable, Identifiable {
        case like, neverHeard, chillToIntense, newToMe
        var id: Self { self }

        var title: String {
            switch self {
            case .like: "Like This Tune"
            case .neverHeard: "Never Heard"
            case .chillToIntense: "Chill to Intense"
            case .newToMe: "New to Me"
            }
        }

        /// The other recipes shuffle, so asking again gives something new.
        var isRandom: Bool { self != .like }
    }

    /// How far down the closest tunes a list goes. By rank, not by score: the
    /// same score means 23 tunes for one seed and 458 for another.
    enum Closeness: UInt32, CaseIterable, Identifiable {
        case veryClose = 50, close = 200, loose = 1000
        var id: Self { self }

        var title: String {
            switch self {
            case .veryClose: "Very Close"
            case .close: "Close"
            case .loose: "Loose"
            }
        }
    }

    /// The tune `like` starts from.
    struct Seed: Hashable, Sendable {
        var path: String
        var title: String
        var author: String
    }

    var start = Start.like
    var seed: Seed?
    var closeness = Closeness.close
    var otherVersions = true
    var minMinutes: UInt32 = 2
    var onlyUnheard = false
    /// How long it plays; nil for every tune that fits.
    var totalMinutes: UInt32?
    /// Different at each launch, and with Generate Again.
    var generation = UInt64.random(in: 0...UInt64.max)

    /// Starting a recipe sets what it means; the rest stays for going back.
    mutating func begin(_ start: Start) {
        self.start = start
        switch start {
        case .like:
            minMinutes = 2
            onlyUnheard = false
            totalMinutes = nil
        case .neverHeard:
            minMinutes = 0
            onlyUnheard = true
            totalMinutes = nil
        case .chillToIntense:
            minMinutes = 0
            onlyUnheard = false
            totalMinutes = 60
        case .newToMe:
            minMinutes = 0
            onlyUnheard = true
            totalMinutes = 60
        }
    }

    var recipe: SmartRecipe {
        let kind: SmartKind = switch start {
        case .like: .like
        case .neverHeard: .shuffle
        case .chillToIntense: .rising
        case .newToMe: .different
        }
        return SmartRecipe(
            kind: kind,
            seed: seed?.path,
            seedSubtune: nil,
            top: closeness.rawValue,
            otherVersions: otherVersions,
            minSecs: minMinutes * 60,
            onlyUnheard: onlyUnheard,
            totalSecs: totalMinutes.map { $0 * 60 },
            shuffle: generation
        )
    }

    /// What the list is called, and what a saved copy is named.
    var title: String {
        if start == .like, let seed { return "Like \(seed.title)" }
        return start.title
    }
}

/// How long a list plays: "19 tunes, 61 minutes", "155 tunes, 8 h 58 min".
nonisolated enum SmartFacts {
    static func tunes(_ count: Int, secs: UInt64) -> String {
        let tunes = count == 1 ? "1 tune" : "\(count.formatted()) tunes"
        let minutes = Int((Double(secs) / 60).rounded())
        if minutes < 90 { return "\(tunes), \(minutes) \(minutes == 1 ? "minute" : "minutes")" }
        if minutes >= 100 * 60 { return "\(tunes), about \((minutes / 60).formatted()) hours" }
        return "\(tunes), \(minutes / 60) h \(minutes % 60) min"
    }

    /// The header's line under the title.
    static func summary(_ playlist: SmartPlaylist, settings: SmartSettings) -> String {
        let total = tunes(playlist.tunes.count, secs: playlist.totalSecs)
        switch settings.start {
        case .like:
            let versions = playlist.tunes.count(where: \.isVersion)
            guard versions > 0 else { return "\(total), by sound" }
            let sound = playlist.tunes.count - versions
            return "\(total): \(sound.formatted()) by sound, \(versions) other \(versions == 1 ? "version" : "versions") by name"
        case .neverHeard:
            return "\(total), shuffled"
        case .chillToIntense:
            return total
        case .newToMe:
            return "\(total), from \(playlist.pool.formatted()) tunes unlike the \(playlist.heard.formatted()) you've played"
        }
    }
}

/// Smart Playlist: pick a start, change the recipe, and the list follows.
/// Save as Playlist keeps a copy, which is then an ordinary playlist.
struct SmartPlaylistView: View {
    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(PlaylistsStore.self) private var playlists

    @State private var result: SmartPlaylist?
    @State private var failed = false
    @State private var savedKey: SmartSettings?
    @State private var choosingSeed = false

    /// Kept in the library, so a list is still there after looking elsewhere.
    private var settings: SmartSettings {
        get { library.smartSettings }
        nonmutating set { library.smartSettings = newValue }
    }

    private var rows: [LibraryRow] { result?.tunes.map { LibraryRow(item: $0.item) } ?? [] }

    var body: some View {
        Group {
            if store.hasCollection {
                VStack(spacing: 0) {
                    controls
                    Divider()
                    content
                }
            } else {
                noCollection
            }
        }
        .task(id: settings) { await generate() }
        .task {
            // Start from what's playing, the likeliest thing to want more of.
            if settings.seed == nil, let track = store.nowPlaying, store.hvscRoot.map(track.path.hasPrefix) == true {
                settings.seed = .init(path: track.path, title: track.title, author: track.author)
            }
        }
    }

    private func generate() async {
        guard store.hasCollection else { return }
        if settings.start == .like && settings.seed == nil {
            result = nil
            return
        }
        result = nil
        failed = false
        // Settings change in bursts while a menu is used.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let made = try? await store.core.smartPlaylist(recipe: settings.recipe)
        guard !Task.isCancelled else { return }
        result = made
        failed = made == nil
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Four across, or a menu where they wouldn't fit.
            ViewThatFits(in: .horizontal) {
                startPicker
                    .pickerStyle(.segmented)
                    .buttonBorderShape(.capsule)
                    .fixedSize()
                startPicker
                    .pickerStyle(.menu)
                    .fixedSize()
            }
            SmartSentenceField { parsed in apply(parsed) }
            recipeRow
            header
            if settings.start == .chillToIntense, let tunes = result?.tunes, !tunes.isEmpty {
                IntensityCurve(tunes: tunes)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var startPicker: some View {
        Picker("Start", selection: Binding(get: { settings.start }, set: { settings.begin($0) })) {
            ForEach(SmartSettings.Start.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
    }

    private func apply(_ parsed: SmartSentence) {
        var next = settings
        next.begin(parsed.start)
        if let minutes = parsed.minMinutes { next.minMinutes = minutes }
        if let minutes = parsed.totalMinutes { next.totalMinutes = minutes }
        if parsed.onlyUnheard { next.onlyUnheard = true }
        if let seed = parsed.seed { next.seed = seed }
        settings = next
    }

    private func binding<Value>(_ key: WritableKeyPath<SmartSettings, Value>) -> Binding<Value> {
        Binding(get: { library.smartSettings[keyPath: key] }, set: { library.smartSettings[keyPath: key] = $0 })
    }

    private var recipeRow: some View {
        SmartFlow(spacing: 8) {
            if settings.start == .like {
                Button { choosingSeed = true } label: {
                    Text(settings.seed.map { "Sounds like \($0.title) by \($0.author)" } ?? "Choose a Tune")
                        .lineLimit(1)
                }
                .popover(isPresented: $choosingSeed, arrowEdge: .bottom) {
                    SmartSeedPicker { seed in
                        settings.seed = seed
                        choosingSeed = false
                    }
                }
                Picker("How close", selection: binding(\.closeness)) {
                    ForEach(SmartSettings.Closeness.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("How far down the list of the closest tunes to go: the top 50, 200 or 1,000")
                Toggle("Other Versions", isOn: binding(\.otherVersions))
                    .toggleStyle(.button)
                    .help("Also add tunes with the same name. Versions of a piece often sound quite different.")
            }
            if settings.start != .chillToIntense {
                Picker("Length", selection: binding(\.minMinutes)) {
                    Text("Any Length").tag(UInt32(0))
                    ForEach([1, 2, 3, 5] as [UInt32], id: \.self) { Text("Over \($0) min").tag($0) }
                }
                .fixedSize()
            }
            if settings.start == .like || settings.start == .chillToIntense {
                Picker("Heard", selection: binding(\.onlyUnheard)) {
                    Text("Heard or Not").tag(false)
                    Text("Never Heard").tag(true)
                }
                .fixedSize()
            }
            Picker("Plays for", selection: binding(\.totalMinutes)) {
                if settings.start != .chillToIntense { Text("All of Them").tag(UInt32?.none) }
                ForEach([30, 60, 120] as [UInt32], id: \.self) { minutes in
                    Text(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) \(minutes == 60 ? "hour" : "hours")")
                        .tag(UInt32?.some(minutes))
                }
            }
            .fixedSize()
        }
        .controlSize(.small)
        .labelsHidden()
    }

    private var header: some View {
        // As in PlaylistHeader: the buttons drop below rather than squeeze.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 12) {
                titles.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                actions
            }
            VStack(alignment: .leading, spacing: 8) {
                titles
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    actions
                }
            }
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(settings.title)
                .font(.title2.weight(.bold))
                .lineLimit(1)
            Text(result.map { SmartFacts.summary($0, settings: settings) } ?? " ")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if settings.start.isRandom {
            Button("Generate Again") { settings.generation &+= 1 }
                .disabled(result == nil)
        }
        Button(savedKey == settings ? "Saved" : "Save as Playlist") {
            let files = rows.map(\.id)
            let name = settings.title
            let saved = settings
            Task {
                await playlists.addToNew(files, named: name)
                savedKey = saved
            }
        }
        .disabled(rows.isEmpty || savedKey == settings)
        .help("Keeps these tunes as one of your playlists. It stays as it is now.")
        Button {
            library.play(rows, from: .smart(title: settings.title))
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(rows.isEmpty)
        .fixedSize()
    }

    // MARK: The list

    @ViewBuilder
    private var content: some View {
        if settings.start == .like && settings.seed == nil {
            ContentUnavailableView {
                Label("Choose a Tune", systemImage: "waveform")
            } description: {
                Text("Pick a tune, and this finds the ones that sound like it.")
            } actions: {
                Button("Choose a Tune") { choosingSeed = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if failed {
            ContentUnavailableView("Couldn't Make the List", systemImage: "exclamationmark.triangle",
                                   description: Text("The collection couldn't be read. Try again."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result {
            if result.needsMoreHistory {
                ContentUnavailableView {
                    Label("New to Me Needs More to Go On", systemImage: "sparkles")
                } description: {
                    Text("It compares what you've played with everything else. You've played \(result.heard == 1 ? "1 tune" : "\(result.heard) tunes") so far, so it would mostly be guessing.")
                } actions: {
                    Button("Try Never Heard") { settings.begin(.neverHeard) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if result.seedNotScanned {
                ContentUnavailableView("Not Scanned Yet", systemImage: "waveform",
                                       description: Text("Resonance hasn't learned how this tune sounds yet. Try another one, or come back when the scan has reached it."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView("No Tunes Fit", systemImage: "music.note.list",
                                       description: Text("Try a shorter length or fewer conditions."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LibraryTable(rows: rows, source: .smart(title: settings.title))
            }
        } else {
            ProgressView("Choosing tunes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var noCollection: some View {
        ContentUnavailableView {
            Label("Smart Playlists Are Made from the Collection", systemImage: "archivebox")
        } description: {
            Text("Download it first, then pick a tune or describe what you'd like to hear.")
        } actions: {
            Button("Download the Collection") { store.startHvscSync() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Finds a tune by name. "Second Reality" finds "2nd Reality".
private struct SmartSeedPicker: View {
    let choose: (SmartSettings.Seed) -> Void
    @Environment(PlayerStore.self) private var store
    @State private var name = ""
    @State private var found: [HvscTuneItem]?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Tune name", text: $name)
                .textFieldStyle(.roundedBorder)
            if let found {
                if found.isEmpty {
                    Text("No tune is called \(name).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(found, id: \.path) { tune in row(tune) }
                        }
                    }
                    .frame(maxHeight: 240)
                }
            }
        }
        .padding(12)
        .frame(width: 340)
        .task(id: name) {
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                found = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let tunes = await store.core.smartFindTunes(name: name, limit: 40)
            guard !Task.isCancelled else { return }
            found = tunes
        }
    }

    private func row(_ tune: HvscTuneItem) -> some View {
        Button {
            choose(.init(path: tune.path, title: tune.title, author: tune.author))
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(tune.title).fontWeight(.semibold).lineLimit(1)
                Text(tune.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Each tune of a Chill to Intense list, how intense against the collection.
private struct IntensityCurve: View {
    let tunes: [SmartTune]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Canvas { context, size in
                let gap: CGFloat = 2
                let width = (size.width - gap * CGFloat(tunes.count - 1)) / CGFloat(tunes.count)
                for (index, tune) in tunes.enumerated() {
                    let height = max(3, size.height * CGFloat(tune.intensity ?? 0))
                    let rect = CGRect(x: CGFloat(index) * (width + gap), y: size.height - height,
                                      width: width, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.accentColor))
                }
            }
            .frame(height: 44)
            Text("How intense each tune is, start to end, against the whole collection")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Intensity stays low, then rises towards the end")
    }
}

/// Lines of controls that wrap in a narrow pane.
private struct SmartFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
