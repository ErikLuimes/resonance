import SwiftUI
import PhosphorCore

/// Settings, one tab per area. The selected tab is remembered.
struct SettingsView: View {
    @AppStorage(Pref.settingsTab) private var tab = SettingsTab.playback

    var body: some View {
        TabView(selection: $tab) {
            Tab("Playback", systemImage: "play.circle", value: .playback) {
                SettingsPane { PlaybackSettings() }
            }
            Tab("Appearance", systemImage: "paintpalette", value: .appearance) {
                SettingsPane {
                    MenuBarSettings()
                    ThemeSettings()
                }
            }
            Tab("Collection", systemImage: "folder", value: .collection) {
                SettingsPane {
                    CollectionSettings()
                    SceneSettings()
                }
            }
            Tab("History", systemImage: "clock.arrow.circlepath", value: .history) {
                SettingsPane { HistorySettings() }
            }
            Tab("Advanced", systemImage: "gearshape.2", value: .advanced) {
                SettingsPane { AdvancedSettings() }
            }
        }
    }
}

enum SettingsTab: String {
    case playback, appearance, collection, history, advanced
}

/// A tab's grouped form, as tall as its content: the window resizes to
/// each tab.
private struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PlaybackSettings: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Section {
            ForEach(Engine.pickerOrder, id: \.self) { engine in
                EngineRow(engine: engine, isOn: store.engine == engine) { store.engine = engine }
            }
        } header: {
            Text("Engine")
        } footer: {
            Text("Changing the engine restarts the current tune.")
        }

        Section {
            Toggle("Skip RSID tunes", isOn: $store.options.skipRsid)
            LabeledContent("Default song length") {
                HStack {
                    TextField("Seconds", value: $store.options.defaultSongLengthSecs, format: .number)
                        .labelsHidden()
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Text("seconds")
                }
            }
        } header: {
            Text("Playback")
        } footer: {
            Text("Resonance works out the length of tunes missing from the Songlengths database by itself, in the background. The default length is used until then, and for tunes it can't work out. 0 means play until silence.")
        }

        Section {
            Toggle("Play 2SID tunes in mirrored stereo", isOn: $store.options.forceStereo2sid)
            Picker("Widen mono tunes", selection: $store.options.pseudoStereo) {
                Text("Off").tag(PseudoStereo?.none)
                ForEach(PseudoStereo.allCases, id: \.self) { strength in
                    Text(strength.displayName).tag(Optional(strength))
                }
            }
        } header: {
            Text("Stereo")
        } footer: {
            if store.engine.rendersDirectly {
                Text("Widen mono tunes has no effect on \(store.engine.displayName).")
            }
        }
    }
}

/// One engine to pick, as a radio row: the dot, the name (with a
/// Recommended badge on the default) and a line on what sets it apart.
/// The whole row selects.
private struct EngineRow: View {
    let engine: Engine
    let isOn: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isOn ? "inset.filled.circle" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                    .font(.body)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(engine.displayName)
                        if engine == Engine.recommended {
                            Text("Recommended")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.accentColor, in: .capsule)
                                .foregroundStyle(.white)
                        }
                    }
                    Text(engine.caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .accessibilityLabel("\(engine.displayName), \(engine.caption)")
    }
}

/// The HVSC folder and its release, and downloading it (again).
private struct CollectionSettings: View {
    @Environment(PlayerStore.self) private var store
    @State private var choosingFolder = false
    @State private var confirmingDownload = false

    var body: some View {
        Section {
            LabeledContent("Collection folder") {
                Text(store.hvscRoot.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not set")
                    .foregroundStyle(store.hvscRoot == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Button("Choose…") { choosingFolder = true }
                Button("Use Phosphor's") { store.usePhosphorHvscRoot() }
            }
            if store.hasCollection, let info = store.hvscInfo, let version = info.version {
                LabeledContent("Version") {
                    Text(info.releaseDate.map { "HVSC \(version), released \($0)" } ?? "HVSC \(version)")
                }
            }
            if store.hasCollection {
                UpdateRow()
            }
            if let sync = store.hvscSync, sync.running {
                ProgressView(value: sync.fraction) {
                    Text(sync.current)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Cancel Download") { store.cancelHvscSync() }
            } else if store.hasCollection {
                // An available update is the Updates row's button instead.
                if !store.hvscUpdateAvailable {
                    Button("Download Again…") { confirmingDownload = true }
                }
            } else {
                Button("Download Collection…") { store.startHvscSync() }
            }
            if let error = store.hvscSyncError ?? store.hvscSync?.error {
                Text(error)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("HVSC")
        } footer: {
            if store.hasCollection {
                Text("The folder that holds MUSICIANS, GAMES and DEMOS. Updating adds the new and changed tunes; tunes a release moves or removes stay where they were. Downloading again restores missing or damaged files.")
            } else {
                Text("The folder that holds MUSICIANS, GAMES and DEMOS. With nothing in it yet, download the collection into it — by default Resonance's own folder.")
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                store.hvscRoot = url.path
            }
        }
        .confirmationDialog("Download HVSC again?", isPresented: $confirmingDownload) {
            Button("Download") { store.startHvscSync() }
        } message: {
            Text("Downloads the whole collection archive and restores any missing or damaged files. The tunes already there are kept, and so are your fingerprints.")
        }
        .task { await store.loadHvscInfo() }

        if store.hasCollection {
            FingerprintSettings()
        }
    }
}

/// Whether a newer HVSC release is out, and getting it.
private struct UpdateRow: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        LabeledContent("Updates") {
            HStack {
                if store.isCheckingHvscUpdate {
                    Text("Checking…")
                        .foregroundStyle(.secondary)
                } else if let error = store.hvscUpdateError {
                    Text("Couldn't check: \(error)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(error)
                    AccentLink("Try Again") { Task { await store.checkHvscUpdate() } }
                } else if store.hvscUpdateAvailable, let latest = store.latestHvsc {
                    if store.hvscSync?.running != true {
                        Button("Update to HVSC \(latest)") { store.startHvscSync() }
                    }
                } else if store.latestHvsc != nil {
                    Text("Up to date")
                        .foregroundStyle(.secondary)
                    AccentLink("Check Again") { Task { await store.checkHvscUpdate() } }
                } else {
                    AccentLink("Check for Update") { Task { await store.checkHvscUpdate() } }
                }
            }
        }
    }
}

/// The background scan that fingerprints the collection: how far it has
/// got and how long it has left, pausing it, and scanning again.
private struct FingerprintSettings: View {
    @Environment(FingerprintStore.self) private var fingerprints
    @State private var confirmingRebuild = false
    @State private var databaseBytes: Int64?

    var body: some View {
        Section {
            if let status = fingerprints.status, status.total > 0 {
                LabeledContent("Fingerprinted") {
                    Text("\(status.done.formatted()) of \(status.total.formatted()) tunes")
                        .monospacedDigit()
                }
                if !status.finished {
                    ProgressView(value: Double(status.done), total: Double(status.total)) {
                        EmptyView()
                    } currentValueLabel: {
                        if fingerprints.paused {
                            Text("Paused")
                        } else if let remaining = fingerprints.remaining {
                            Text(Self.timeLeft(remaining))
                        }
                    }
                }
                if status.failed > 0 {
                    LabeledContent("Couldn't scan \(status.failed.formatted()) tunes") {
                        AccentLink("Retry") { Task { await fingerprints.retryFailed() } }
                    }
                }
                if let error = status.error {
                    Text(error)
                        .foregroundStyle(.red)
                }
            } else {
                LabeledContent("Fingerprinted", value: "Starting…")
            }
            // Its own row: the scan runs for hours, so starting and pausing
            // it shouldn't hide among the database controls.
            LabeledContent("Scanning") {
                HStack {
                    Text(scanState)
                        .foregroundStyle(.secondary)
                    if fingerprints.status?.finished != true {
                        Button(scanButton) { fingerprints.paused.toggle() }
                    }
                }
            }
            LabeledContent("Database") {
                HStack {
                    if let databaseBytes {
                        Text(databaseBytes.formatted(.byteCount(style: .file)))
                            .foregroundStyle(.secondary)
                    }
                    Button("Rebuild All…") { confirmingRebuild = true }
                }
            }
            LabeledContent("Published set") {
                HStack {
                    switch fingerprints.setDownload {
                    case .downloading:
                        ProgressView()
                            .controlSize(.small)
                        Text("Downloading…")
                            .foregroundStyle(.secondary)
                    case .added(let count):
                        Text(count == 0 ? "Nothing new" : "\(count.formatted()) added")
                            .foregroundStyle(.secondary)
                    default:
                        Button("Download") { Task { await fingerprints.downloadSet() } }
                    }
                }
            }
            if case .failed(let message) = fingerprints.setDownload {
                Text(message)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Sound Fingerprints")
        } footer: {
            Text("Resonance plays every tune silently in the background to learn how it sounds, for the Sound column and Sounds Like. It picks up where it left off, and takes a few hours for all of HVSC. The published set (about 42 MB) has the fingerprints of all of HVSC already; Resonance downloads it the first time, and the scan fills in the rest.")
        }
        .confirmationDialog("Rebuild all fingerprints?", isPresented: $confirmingRebuild) {
            Button("Rebuild") { Task { await fingerprints.rebuild() } }
        } message: {
            Text("Forgets every fingerprint and scans HVSC again from the start. That takes a few hours, and Sounds Like is incomplete until it's done.")
        }
        .task(id: fingerprints.status?.revision) {
            let url = AppPaths.fingerprintDatabase
            databaseBytes = await Task.detached(priority: .utility) {
                ["", "-wal"].reduce(Int64(0)) { sum, suffix in
                    sum + DiskUsage.bytes(at: URL(filePath: url.path + suffix))
                }
            }.value
        }
    }

    /// What the scan is doing, next to its button.
    private var scanState: String {
        if fingerprints.status?.finished == true { return "Finished" }
        if fingerprints.paused { return "Paused" }
        return fingerprints.status?.running == true ? "In the background" : "Starting…"
    }

    /// Start before anything has been scanned, Resume after, Pause while
    /// it runs. Pausing holds its place, also across launches.
    private var scanButton: String {
        guard fingerprints.paused else { return "Pause" }
        return (fingerprints.status?.done ?? 0) == 0 ? "Start" : "Resume"
    }

    /// "About 1 hour, 20 minutes left".
    private static func timeLeft(_ remaining: Duration) -> String {
        guard remaining >= .seconds(60) else { return "Less than a minute left" }
        let units: Set<Duration.UnitsFormatStyle.Unit> = remaining >= .seconds(3600) ? [.hours, .minutes] : [.minutes]
        return "About \(remaining.formatted(.units(allowed: units, width: .wide))) left"
    }
}

/// The play history Resonance shares with Phosphor, and clearing it.
private struct HistorySettings: View {
    @Environment(LibraryStore.self) private var library
    @State private var confirmingClear = false
    @State private var confirmingReset = false

    var body: some View {
        Section {
            LabeledContent("Recently played") {
                HStack {
                    Text(Self.tunes(library.recent?.count))
                        .foregroundStyle(.secondary)
                    Button("Clear…") { confirmingClear = true }
                }
            }
        } footer: {
            Text("The last 100 different tunes you played.")
        }

        Section {
            LabeledContent("Heard") {
                HStack {
                    Text(Self.tunes(library.heardCount))
                        .foregroundStyle(.secondary)
                    Button("Reset…") { confirmingReset = true }
                }
            }
        } footer: {
            Text("Every tune you've ever played, for the SIDs heard count in Recently Played.")
        }
        .confirmationDialog("Clear recently played?", isPresented: $confirmingClear) {
            Button("Clear") { Task { await library.clearRecent() } }
        } message: {
            Text("Removes every tune from Recently Played.")
        }
        .confirmationDialog("Reset heard tunes?", isPresented: $confirmingReset) {
            Button("Reset") { Task { await library.resetHeard() } }
        } message: {
            Text("Forgets every tune you've heard, so the SIDs heard count starts from zero.")
        }
        .task { await library.loadRecent() }
    }

    private static func tunes(_ count: Int?) -> String {
        guard let count else { return "…" }
        return count == 1 ? "1 tune" : "\(count.formatted()) tunes"
    }
}

/// Importing from Phosphor, and where each app keeps its files.
private struct AdvancedSettings: View {
    @Environment(PlayerStore.self) private var store
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(LibraryStore.self) private var library
    @State private var sizes: [URL: Int64] = [:]
    @State private var importing = false
    /// What the last import added.
    @State private var imported: String?

    private static let folders = [
        ("Resonance", AppPaths.supportDirectory),
        ("Phosphor", AppPaths.phosphorDirectory),
    ]

    var body: some View {
        UpdateSettings()

        Section {
            LabeledContent {
                Button("Import") {
                    importing = true
                    Task {
                        imported = await store.importFromPhosphor()
                        await playlists.loadFavourites()
                        await library.loadRecent()
                        importing = false
                    }
                }
                .disabled(importing)
            } label: {
                Text("Import from Phosphor")
                if let imported {
                    Text(imported)
                }
            }
        } footer: {
            Text("Takes Phosphor's playback settings, adds its favourites and play history to Resonance's, and uses its HVSC collection if Resonance has none. Nothing in Phosphor changes.")
        }

        Section {
            ForEach(Self.folders, id: \.1) { name, url in
                LabeledContent(name) {
                    HStack {
                        Text(sizes[url].map { $0.formatted(.byteCount(style: .file)) } ?? "Measuring…")
                            .foregroundStyle(.secondary)
                        AccentLink("Show in Finder") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        } header: {
            Text("Data Folders")
        } footer: {
            Text("Resonance keeps its favourites, play history, playlists, fingerprints and, unless you choose another folder, HVSC in its own folder. It reads Phosphor's only when you import from it.")
        }
        .task {
            for (_, url) in Self.folders {
                sizes[url] = await Task.detached(priority: .utility) { DiskUsage.bytes(at: url) }.value
            }
        }

        ResetSettings()
    }
}

/// Starting over: the collection Download put in Resonance's folder, or
/// everything Resonance keeps. Both go to the Trash, never Phosphor's.
private struct ResetSettings: View {
    @Environment(PlayerStore.self) private var store
    @State private var collectionBytes: Int64?
    @State private var confirmingCollection = false
    @State private var confirmingReset = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Section {
            if store.collectionIsDownloadedHere {
                LabeledContent {
                    Button("Move to Trash…") { confirmingCollection = true }
                        .disabled(working)
                } label: {
                    Text("Downloaded collection")
                    Text("HVSC in Resonance's folder · \(collectionSize)")
                }
            }
            LabeledContent {
                Button("Reset Resonance…") { confirmingReset = true }
                    .disabled(working)
            } label: {
                Text("Everything")
                Text("Start Resonance fresh")
            }
            if let error {
                Text(error)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Reset")
        } footer: {
            Text("Both move files to the Trash, so you can put them back. Phosphor's folder is never touched.")
        }
        .task(id: store.collectionIsDownloadedHere) {
            guard store.collectionIsDownloadedHere, let root = store.hvscRoot else { return }
            let url = URL(filePath: root)
            collectionBytes = await Task.detached(priority: .utility) { DiskUsage.bytes(at: url) }.value
        }
        .confirmationDialog("Move the downloaded collection to the Trash?", isPresented: $confirmingCollection) {
            Button("Move to Trash", role: .destructive) {
                run { try await store.trashDownloadedCollection() }
            }
        } message: {
            Text("Moves HVSC in Resonance's folder (\(collectionSize)) to the Trash, stopping a download into it first. You can download it again from the Home.")
        }
        .confirmationDialog("Reset Resonance?", isPresented: $confirmingReset) {
            Button("Reset Resonance", role: .destructive) {
                run {
                    try await store.resetEverything()
                    Self.relaunch()
                }
            }
        } message: {
            Text("Moves Resonance's folder to the Trash: your favourites, play history, playlists, fingerprints and its HVSC collection. Its settings are forgotten. Resonance then restarts, fresh.")
        }
    }

    /// Quit, and open again once this process has gone: a shell outside
    /// the app waits for it to exit, so the two never run at once.
    private static func relaunch() {
        let wait = Process()
        wait.executableURL = URL(filePath: "/bin/sh")
        wait.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
            "relaunch", "\(ProcessInfo.processInfo.processIdentifier)", Bundle.main.bundlePath,
        ]
        try? wait.run()
        NSApp.terminate(nil)
    }

    private var collectionSize: String {
        collectionBytes.map { $0.formatted(.byteCount(style: .file)) } ?? "measuring…"
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            do {
                try await action()
            } catch {
                self.error = "Couldn't move it to the Trash: \(error.localizedDescription)"
            }
            working = false
        }
    }
}

/// Bytes a file or folder takes on disk.
nonisolated enum DiskUsage {
    static func bytes(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        let size = { (url: URL) -> Int64 in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return size(url)
        }
        var total = size(url)
        for case let file as URL in files {
            total += size(file)
        }
        return total
    }
}

/// The visualizers' colour theme: a preset or your own colours, and whether
/// its badge shows.
private struct SceneSettings: View {
    @AppStorage(Pref.csdbEnabled) private var enabled = true
    @AppStorage(Pref.csdbTrivia) private var showsTrivia = false
    @AppStorage(Pref.composerPhotos) private var showsPhotos = false

    var body: some View {
        Section {
            Toggle("Show the C64 scene from CSDb", isOn: $enabled)
        } footer: {
            Text("Scene Pulse and composers' CSDb details. Resonance only contacts csdb.dk while this is on.")
        }
        Section {
            Toggle("Show CSDb trivia about composers", isOn: $showsTrivia)
                .disabled(!enabled)
        } footer: {
            Text("Trivia is written by CSDb's users and shown as they wrote it. It's unverified, may be wrong or out of date, and can include claims about real people. It doesn't come from Resonance or HVSC.")
        }
        Section {
            Toggle("Show composer photos from Wikimedia Commons", isOn: $showsPhotos)
                .disabled(!enabled)
        } footer: {
            Text("Experimental. Composer profiles look for a freely licensed photo through Wikipedia, and credit its author. Few composers have one, and a match by name can be the wrong person. Resonance only contacts Wikipedia and Wikimedia Commons while this is on.")
        }
    }
}

private struct MenuBarSettings: View {
    @AppStorage(Pref.menuBarPlayer) private var showsMenuBarPlayer = true

    var body: some View {
        Section {
            Toggle("Show the player in the menu bar", isOn: $showsMenuBarPlayer)
        } footer: {
            Text("What's playing, the controls, Favourite, Shuffle, Surprise Me and what plays next, from the menu bar, with the window closed too.")
        }
    }
}

private struct ThemeSettings: View {
    @Environment(\.voiceTheme) private var theme
    @AppStorage(Pref.theme) private var themeID = VoiceTheme.resonance.id
    @AppStorage(Pref.customTheme) private var customData = Data()
    @AppStorage(Pref.themeBadge) private var showsBadge = true

    var body: some View {
        Section {
            Picker("Theme", selection: $themeID) {
                ForEach(VoiceTheme.presets + [VoiceTheme.custom(from: customData)]) { theme in
                    row(theme).tag(theme.id)
                }
            }
            .pickerStyle(.radioGroup)

            if themeID == VoiceTheme.customID {
                ColorPicker("Voice 1", selection: customColor(\.voices[0]), supportsOpacity: false)
                ColorPicker("Voice 2", selection: customColor(\.voices[1]), supportsOpacity: false)
                ColorPicker("Voice 3", selection: customColor(\.voices[2]), supportsOpacity: false)
                ColorPicker("Background", selection: customColor(\.background), supportsOpacity: false)
            }

            Toggle("Show theme badge", isOn: $showsBadge)
            if showsBadge {
                LabeledContent("Badge") {
                    ThemeBadgeView()
                        .frame(width: 220, height: 20)
                        .padding(6)
                        .background(theme.background.color, in: .rect(cornerRadius: 6))
                }
            }
        } header: {
            Text("Theme")
        } footer: {
            Text("Colours the three voices in every visualizer. Buttons and links keep the system accent colour.")
        }
    }

    private func row(_ theme: VoiceTheme) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(theme.voice(i)).frame(width: 10, height: 10)
                }
            }
            Text(theme.name)
            Text(theme.summary)
                .foregroundStyle(.secondary)
        }
    }

    private func customColor(_ keyPath: WritableKeyPath<VoiceTheme, RGB>) -> Binding<Color> {
        Binding {
            VoiceTheme.custom(from: customData)[keyPath: keyPath].color
        } set: { color in
            var custom = VoiceTheme.custom(from: customData)
            custom[keyPath: keyPath] = RGB(color)
            customData = custom.encoded
        }
    }
}

#Preview {
    SettingsView()
        .environment(PlayerStore.preview)
        .environment(LibraryStore(player: .preview))
        .environment(FingerprintStore(player: .preview))
}

/// Sparkle's two settings, and a way to check now.
private struct UpdateSettings: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        Section {
            Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
            Toggle("Download and install automatically", isOn: $updater.installsAutomatically)
                .disabled(!updater.checksAutomatically)
            LabeledContent("Last checked") {
                HStack {
                    Text(lastChecked)
                        .foregroundStyle(.secondary)
                    AccentLink("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text(updater.isAvailable
                 ? "Resonance checks for a new version once a day. Updates are verified with Resonance's signing key before they're installed, and nothing about your Mac is sent. Automatic updates install when you quit."
                 : "This build of Resonance doesn't update itself. Releases from the website do.")
        }
        .disabled(!updater.isAvailable)
    }

    private var lastChecked: String {
        guard let date = updater.lastCheck else { return "Never" }
        return Self.dateFormatter.string(from: date)
    }

    /// "Today at 14:02", "Yesterday at 09:15", "3 Nov 2026 at 21:40".
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}
