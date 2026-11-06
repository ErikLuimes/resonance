import SwiftUI
import PhosphorCore

/// What the Smart Playlist is making: a sentence, what was understood from it,
/// and how long it plays. `SmartRecipe` is what the core takes.
nonisolated struct SmartSettings: Hashable, Sendable {
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

    /// The tune a list sounds like.
    struct Seed: Hashable, Sendable {
        var path: String
        var title: String
        var author: String
    }

    var closeness = Closeness.close
    var otherVersions = true
    /// How long it plays; nil for every tune that fits.
    var totalMinutes: UInt32? = 60
    /// Different at each launch, and with Refresh.
    var generation = UInt64.random(in: 0...UInt64.max)
    var sentence = ""
    var understood: SmartUnderstanding?
    /// The tunes the sentence names, once looked up.
    var describedSeeds: [Seed] = []
    /// What was done about a sentence that wasn't fully understood.
    var note: String?
    /// Refresh on a list with a set order: the same tunes, shuffled.
    var isReordered = false

    /// Whether there's enough to make a list from.
    var isReady: Bool {
        understood != nil && (understood?.tuneNames.isEmpty == true || !describedSeeds.isEmpty)
    }

    /// Whether it's a list of the closest to a tune.
    var isClosestFirst: Bool { understood?.tuneNames.isEmpty == false }

    /// A new pick, or a new order where the tunes can't change.
    mutating func refresh() {
        generation &+= 1
        if !canRefresh { isReordered = true }
    }

    /// Whether asking again can give something new. Closest-first lists come
    /// out the same, and so do one composer's in order of a mood.
    var canRefresh: Bool {
        guard isReady, !isClosestFirst, let understood else { return false }
        return understood.titleWords == nil && (understood.composers.isEmpty || understood.energy == .any)
    }

    /// How long it plays, as Plays For says it.
    var lengthTitle: String { Self.lengthTitle(totalMinutes) }

    static func lengthTitle(_ minutes: UInt32?) -> String {
        switch minutes {
        case nil: "All"
        case 1440?: "Whole Day"
        case 30?: "30 Min"
        case 60?: "1 Hour"
        case 120?: "2 Hours"
        case let minutes?:
            minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) Min"
        }
    }

    var recipe: SmartRecipe {
        var recipe = SmartRecipe(
            kind: .shuffle, seeds: [], top: closeness.rawValue, otherVersions: otherVersions,
            minSecs: 0, onlyUnheard: false, totalSecs: totalMinutes.map { $0 * 60 }, titleWords: nil, composers: [],
            sounds: [], chip: .any, minChips: nil, maxChips: nil, maxTunes: nil, fromYear: nil, toYear: nil,
            section: .any, energy: .any, shuffle: generation
        )
        guard let understood else { return recipe }
        recipe.titleWords = understood.titleWords
        recipe.composers = understood.composers.map(\.folder)
        recipe.sounds = understood.sounds
        recipe.chip = understood.chip
        recipe.minChips = understood.minChips
        recipe.maxChips = understood.maxChips
        recipe.maxTunes = understood.maxTunes
        recipe.fromYear = understood.fromYear
        recipe.toYear = understood.toYear
        recipe.section = understood.section
        recipe.energy = understood.energy
        recipe.onlyUnheard = understood.onlyUnheard
        recipe.minSecs = (understood.minMinutes ?? 0) * 60
        if !understood.tuneNames.isEmpty {
            recipe.kind = .like
            recipe.seeds = describedSeeds.map(\.path)
        } else if understood.unlikeHeard {
            recipe.kind = .different
        } else {
            switch understood.shape {
            case .rising: recipe.kind = .rising
            case .falling: recipe.kind = .falling
            case .alternating: recipe.kind = .alternating
            case .steady: recipe.kind = .shuffle
            }
        }
        return recipe
    }

    /// What a saved copy is named, and what "Playing from" says.
    var title: String { sentence.isEmpty ? "Smart Playlist" : String(sentence.prefix(60)) }
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
}

/// Smart Playlist: one field, and what it understood under it, in the height of
/// a playlist's header, so the tunes have the page. The suggestions are
/// sentences like any other. Save keeps a copy, then an ordinary playlist.
struct SmartPlaylistView: View {
    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(PlaylistsStore.self) private var playlists

    @State private var result: SmartPlaylist?
    @State private var failed = false
    @State private var savedKey: SmartSettings?
    @State private var choosingSeed = false
    @State private var typed = ""
    /// Narrows the list made, without changing what it's made from.
    @State private var filter = ""

    /// Kept in the library, so a list is still there after looking elsewhere.
    private var settings: SmartSettings {
        get { library.smartSettings }
        nonmutating set { library.smartSettings = newValue }
    }

    private var rows: [LibraryRow] { result?.tunes.map { LibraryRow(item: $0.item) } ?? [] }

    private var shownRows: [LibraryRow] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return rows }
        return rows.filter { $0.title.localizedStandardContains(query) || $0.author.localizedStandardContains(query) }
    }

    var body: some View {
        Group {
            if store.hasCollection {
                VStack(spacing: 0) {
                    header
                    Divider()
                    content
                }
            } else {
                noCollection
            }
        }
        .task(id: settings) { await generate() }
        // The sentence can also arrive from search or a tune's menu.
        .task(id: settings.sentence) { typed = settings.sentence }
        // As it's typed. Waits for a pause, as the first letters mean little.
        .task(id: typed) {
            guard typed != settings.sentence else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            if typed.trimmingCharacters(in: .whitespaces).isEmpty {
                library.clearSmartSentence()
            } else {
                await library.describe(typed, isFinal: false)
            }
        }
        // Ready before the first word, as it reads every header.
        .task { _ = await library.loadSmartParser() }
    }

    private func generate() async {
        guard store.hasCollection else { return }
        failed = false
        guard settings.isReady else {
            result = nil
            return
        }
        // Settings change in bursts. The list stays until the new one's here.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        var made = try? await store.core.smartPlaylist(recipe: settings.recipe)
        guard !Task.isCancelled else { return }
        if settings.isReordered { made?.tunes.shuffle() }
        result = made
        failed = made == nil
    }

    // MARK: Header

    /// As tall as a playlist's header, unless a narrow pane needs a second line.
    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                SmartMagicField(placeholder: "Say what you'd like to hear", text: $typed) {
                    Task { await library.describe(typed, isFinal: true) }
                } trailing: {
                    if settings.understood != nil { menus }
                    // Always last, where a Mac's search fields keep it.
                    if !typed.isEmpty { clearButton }
                }
                refreshButton
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            if settings.understood == nil {
                suggestions
            } else {
                understanding
                    // Lined up with the field.
                    .frame(maxWidth: 680)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
        // From the top, so what's under the field never moves it.
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .top)
    }

    private var clearButton: some View {
        Button {
            typed = ""
            filter = ""
            library.clearSmartSentence()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear")
        .accessibilityLabel("Clear")
    }

    private var suggestions: some View {
        SmartFlow(spacing: 8) {
            suggestion("New to Me", sentence: "new to me")
            suggestion("Never Heard", sentence: "never heard")
            Button("Similar to a Tune") { similarToATune() }
                .popover(isPresented: $choosingSeed, arrowEdge: .bottom) {
                    SmartSeedPicker { seed in
                        choosingSeed = false
                        library.describeTune(seed)
                    }
                }
            suggestion("Slow to Intense", sentence: "slow to intense")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }

    private func suggestion(_ title: String, sentence: String) -> some View {
        Button(title) {
            typed = sentence
            Task { await library.describe(sentence, isFinal: true) }
        }
    }

    /// What's playing, if it's in the collection; else pick one.
    private func similarToATune() {
        if let track = store.nowPlaying, store.hvscRoot.map(track.path.hasPrefix) == true {
            library.describeTune(.init(path: track.path, title: track.title, author: track.author))
        } else {
            choosingSeed = true
        }
    }

    private var understanding: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            detection.fixedSize(horizontal: false, vertical: true)
            tuneCount
            Spacer(minLength: 0)
        }
    }

    /// What it understood, in words.
    @ViewBuilder
    private var detection: some View {
        if let understood = settings.understood {
            let text = settings.note ?? understood.description(seedTitles: settings.describedSeeds.map {
                // The composer's said once, if they're a filter too.
                understood.composers.isEmpty ? "\($0.title) by \($0.author)" : $0.title
            })
            SmartRevealText(text: text)
                .id(text)
        }
    }

    @ViewBuilder
    private var menus: some View {
        if settings.isClosestFirst { closenessMenu }
        playsForMenu
    }

    @ViewBuilder
    private var tuneCount: some View {
        if let result, !rows.isEmpty {
            Text(SmartFacts.tunes(result.tunes.count, secs: result.totalSecs))
                .font(.callout)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func binding<Value>(_ key: WritableKeyPath<SmartSettings, Value>) -> Binding<Value> {
        Binding(get: { library.smartSettings[keyPath: key] }, set: { library.smartSettings[keyPath: key] = $0 })
    }

    private var closenessMenu: some View {
        Menu("Match") {
            Picker("How close", selection: binding(\.closeness)) {
                ForEach(SmartSettings.Closeness.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Toggle("Other Versions", isOn: binding(\.otherVersions))
        }
        .menuStyle(.button)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .fixedSize()
        .help("How far down the closest tunes to go, and whether to add tunes with the same name")
    }

    private var playsForMenu: some View {
        Menu(settings.lengthTitle) {
            Picker("Plays for", selection: binding(\.totalMinutes)) {
                ForEach([UInt32?.some(30), 60, 120, 1440, nil], id: \.self) { minutes in
                    Text(SmartSettings.lengthTitle(minutes)).tag(minutes)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .menuStyle(.button)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .fixedSize()
        .help("How long it plays")
    }

    /// Round and as tall as the field, and always there, so the field doesn't
    /// move. Off only with nothing typed: a new pick where one can be made,
    /// otherwise the same tunes in a new order.
    private var refreshButton: some View {
        let isEnabled = !typed.trimmingCharacters(in: .whitespaces).isEmpty
        return Button {
            Task {
                if typed != settings.sentence { await library.describe(typed, isFinal: true) }
                settings.refresh()
            }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 15, weight: .medium))
                .symbolEffect(.rotate, value: settings.generation)
                .frame(width: SmartMagicField<EmptyView>.height, height: SmartMagicField<EmptyView>.height)
                .background(.fill.quaternary, in: .circle)
                .overlay { Circle().strokeBorder(.separator) }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .disabled(!isEnabled)
        .help("Make a new pick, or a new order, with the same words")
        .accessibilityLabel("Refresh")
    }

    /// In the row with Sound, as on every list.
    private var listActions: some View {
        Group {
            Button(savedKey == settings ? "Saved" : "Save") {
                let files = rows.map(\.id)
                let name = settings.title
                let saved = settings
                Task {
                    await playlists.addToNew(files, named: name)
                    savedKey = saved
                }
            }
            .disabled(savedKey == settings)
            .help("Keeps these tunes as one of your playlists. It stays as it is now.")
            .fixedSize()
            ListFilterField(text: $filter)
            ListPlayButton { library.play(rows, from: .smart(title: settings.title)) }
        }
    }

    // MARK: The list

    @ViewBuilder
    private var content: some View {
        if !settings.isReady {
            Color.clear
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
                    Button("Try Never Heard") {
                        typed = "never heard"
                        Task { await library.describe("never heard", isFinal: true) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if result.seedNotScanned {
                ContentUnavailableView("Not Scanned Yet", systemImage: "waveform",
                                       description: Text("Resonance hasn't learned how this tune sounds yet. Try another one, or come back when the scan has reached it."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView("No Tunes Fit", systemImage: "music.note.list",
                                       description: Text("Try asking for a little less."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LibraryTable(rows: shownRows, source: .smart(title: settings.title), actions: AnyView(listActions))
                    .overlay {
                        if shownRows.isEmpty { ContentUnavailableView.search(text: filter) }
                    }
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
            Text("Download it first, then say what you'd like to hear.")
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
                .onSubmit {
                    if let first = found?.first {
                        choose(.init(path: first.path, title: first.title, author: first.author))
                    }
                }
            if let found {
                if found.isEmpty {
                    Text("No tune's name starts with \(name).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(found, id: \.path) { tune in row(tune) }
                        }
                    }
                    // A popover gives a scroll view only the height it's told.
                    .frame(height: min(CGFloat(found.count) * 44, 320))
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

/// At the top of search, when what's typed reads as asking for a list, not a
/// name to find: "slow chill for an hour". A plain "Commando" gets nothing.
struct SmartSearchOffer: View {
    let query: String
    @Environment(LibraryStore.self) private var library
    @State private var understood: SmartUnderstanding?

    var body: some View {
        Group {
            if let understood {
                HStack(spacing: 10) {
                    Text(understood.description())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    AccentLink("Make a Playlist") {
                        Task {
                            await library.describe(query, isFinal: true)
                            library.shownSection = .smartPlaylist
                        }
                    }
                    .font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let parser = await library.loadSmartParser()
            guard !Task.isCancelled else { return }
            let parsed = parser.parse(query)
            understood = parsed.flatMap { $0.asksForAList ? $0 : nil }
        }
    }
}
