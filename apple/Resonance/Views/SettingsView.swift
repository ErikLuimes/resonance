import SwiftUI
import PhosphorCore

/// Settings: a sidebar of focused pages, in groups. The selected page is
/// remembered. The window is a fixed size and its title never changes, because
/// a split view whose constraints or toolbar change mid-layout has crashed the
/// main window: each page's name is in the pane, and long pages scroll.
struct SettingsView: View {
    @AppStorage(Pref.settingsTab) private var page = SettingsPage.updates
    @Environment(Updater.self) private var updater

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { page }, set: { if let next = $0 { page = next } })) {
                ForEach(SettingsPage.groups) { group in
                    Section(group.title) {
                        ForEach(group.pages) { item in
                            SettingsSidebarRow(
                                page: item,
                                isSelected: item == page,
                                failed: item == .updates && updater.lastFailure != nil
                            )
                            .tag(item)
                        }
                    }
                }
            }
            // The frame sets the width: the split view alone gives this column
            // 144 points, too narrow for "Storage and Reset".
            .frame(width: 200)
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                Text(page.title)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                Form { pageContent }
                    .formStyle(.grouped)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Settings")
        .frame(width: 796, height: 580)
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .updates:
            UpdateSettings()
        case .general:
            StartPageSettings()
            MenuBarSettings()
            KeyboardSettings()
        case .appearance:
            AppearanceSettings()
            ThemeSettings()
        case .engine:
            EngineSettings()
        case .playback:
            PlaybackSettings()
        case .collection:
            CollectionSettings()
        case .fingerprints:
            FingerprintPage()
        case .history:
            HistorySettings()
#if CSDB
        case .csdb:
            SceneSettings()
#endif
        case .integrations:
            IntegrationSettings()
        case .storage:
            StorageSettings()
        }
    }
}

/// A page of Settings. Its raw value is saved, under the key from when these
/// were tabs: the old tabs that are gone fall back to Updates.
nonisolated enum SettingsPage: String, CaseIterable, Identifiable {
    case updates, general, appearance
    case engine, playback
    case collection, fingerprints, history
#if CSDB
    case csdb
#endif
    case integrations, storage

    var id: Self { self }

    var title: String {
        switch self {
        case .updates: String(localized: "Updates")
        case .general: String(localized: "General")
        case .appearance: String(localized: "Appearance")
        case .engine: String(localized: "Engine")
        case .playback: String(localized: "Playback")
        case .collection: String(localized: "Collection")
        case .fingerprints: String(localized: "Fingerprints")
        case .history: String(localized: "History")
#if CSDB
        case .csdb: "CSDb"
#endif
        case .integrations: String(localized: "Integrations")
        case .storage: String(localized: "Storage and Reset")
        }
    }

    var symbol: String {
        switch self {
        case .updates: "arrow.triangle.2.circlepath"
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .engine: "waveform"
        case .playback: "play.circle"
        case .collection: "folder"
        case .fingerprints: "touchid"
        case .history: "clock.arrow.circlepath"
#if CSDB
        case .csdb: "antenna.radiowaves.left.and.right"
#endif
        case .integrations: "puzzlepiece.extension"
        case .storage: "internaldrive"
        }
    }

    struct Group: Identifiable {
        let title: String
        let pages: [SettingsPage]
        var id: String { title }
    }

    static var groups: [Group] {
        var library: [SettingsPage] = [.collection, .fingerprints, .history]
#if CSDB
        library.append(.csdb)
#endif
        return [
            Group(title: "Resonance", pages: [.updates, .general, .appearance]),
            Group(title: String(localized: "Sound"), pages: [.engine, .playback]),
            Group(title: String(localized: "Library"), pages: library),
            Group(title: String(localized: "Your Mac"), pages: [.integrations, .storage]),
        ]
    }
}

/// Light, dark or following the Mac, for this app only.
nonisolated enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark, auto

    var id: Self { self }

    var title: String {
        switch self {
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        case .auto: String(localized: "Auto")
        }
    }

    /// Nil follows the system, and keeps following it as it changes.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .light: .aqua
        case .dark: .darkAqua
        case .auto: nil
        }
    }

    static func saved(defaults: UserDefaults = .standard) -> AppAppearance {
        defaults.string(forKey: Pref.appAppearance).flatMap(AppAppearance.init(rawValue:)) ?? .auto
    }

    /// For every window, panel and dialog of the app at once. Views made to
    /// stay dark, such as Now Playing, set their own color scheme.
    @MainActor func apply() {
        NSApp.appearance = appearanceName.flatMap(NSAppearance.init(named:))
    }
}

/// A page in the sidebar, saying so when the last update failed: that's easy to
/// miss otherwise, as an automatic update has no dialog of its own. Told it's
/// selected, because `backgroundProminence` isn't set on these rows.
private struct SettingsSidebarRow: View {
    let page: SettingsPage
    let isSelected: Bool
    let failed: Bool

    var body: some View {
        HStack {
            Label(page.title, systemImage: page.symbol)
            Spacer(minLength: 4)
            if failed {
                Text("Failed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isSelected ? Color.white : Color.red)
            }
        }
    }
}

private struct PlaybackSettings: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        @Bindable var store = store
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
            Text("Tunes")
        } footer: {
            Text("Resonance works out the length of tunes missing from the Songlengths database by itself, in the background. The default length is used until then, and for tunes it can't work out. 0 means play until silence.")
        }

        Section {
            Toggle("Play 2SID tunes in mirrored stereo", isOn: $store.options.forceStereo2sid)
        } header: {
            Text("Stereo")
        }
    }
}

/// The engines, to pick one.
private struct EngineSettings: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        Section {
            ForEach(Engine.pickerOrder, id: \.self) { engine in
                EngineRow(engine: engine, isOn: store.engine == engine) { store.engine = engine }
            }
        } footer: {
            Text("Changing the engine restarts the current tune.")
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
                Text(store.hvscRoot.map { RealHome.displayPath($0) } ?? String(localized: "Not set"))
                    .foregroundStyle(store.hvscRoot == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button("Choose…") { choosingFolder = true }
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
                FileAccess.shared.keep([url])
                store.hvscRoot = url.path
            }
        }
        .confirmationDialog("Download HVSC again?", isPresented: $confirmingDownload) {
            Button("Download") { store.startHvscSync() }
        } message: {
            Text("Downloads the whole collection archive and restores any missing or damaged files. The tunes already there are kept, and so are your fingerprints.")
        }
        .task { await store.loadHvscInfo() }
    }
}

/// The scan, once there's a collection to scan.
private struct FingerprintPage: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        if store.hasCollection {
            FingerprintSettings()
        } else {
            Section {
                Text("Fingerprints come from your collection. Choose or download it under Collection first.")
                    .foregroundStyle(.secondary)
            }
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
                    AccentLink(String(localized: "Try Again")) { Task { await store.checkHvscUpdate() } }
                } else if store.hvscUpdateAvailable, let latest = store.latestHvsc {
                    if store.hvscSync?.running != true {
                        Button("Update to HVSC \(latest)") { store.startHvscSync() }
                    }
                } else if store.latestHvsc != nil {
                    Text("Up to date")
                        .foregroundStyle(.secondary)
                    AccentLink(String(localized: "Check Again")) { Task { await store.checkHvscUpdate() } }
                } else {
                    AccentLink(String(localized: "Check for Update")) { Task { await store.checkHvscUpdate() } }
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
                        AccentLink(String(localized: "Retry")) { Task { await fingerprints.retryFailed() } }
                    }
                }
                if let error = status.error {
                    Text(error)
                        .foregroundStyle(.red)
                }
            } else {
                LabeledContent("Fingerprinted", value: String(localized: "Starting…"))
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
        } footer: {
            Text("Resonance plays every tune silently in the background to learn how it sounds, for the Fingerprint column and Sounds Like. It picks up where it left off, and takes a few hours for all of HVSC. The published set (about 42 MB) has the fingerprints of all of HVSC already; Resonance downloads it the first time, and the scan fills in the rest.")
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
        if fingerprints.status?.finished == true { return String(localized: "Finished") }
        if fingerprints.paused { return String(localized: "Paused") }
        return fingerprints.status?.running == true ? String(localized: "In the background") : String(localized: "Starting…")
    }

    /// Start before anything has been scanned, Resume after, Pause while
    /// it runs. Pausing holds its place, also across launches.
    private var scanButton: String {
        guard fingerprints.paused else { return String(localized: "Pause") }
        return (fingerprints.status?.done ?? 0) == 0 ? String(localized: "Start") : String(localized: "Resume")
    }

    /// "About 1 hour, 20 minutes left".
    private static func timeLeft(_ remaining: Duration) -> String {
        guard remaining >= .seconds(60) else { return String(localized: "Less than a minute left") }
        let units: Set<Duration.UnitsFormatStyle.Unit> = remaining >= .seconds(3600) ? [.hours, .minutes] : [.minutes]
        return String(localized: "About \(remaining.formatted(.units(allowed: units, width: .wide))) left")
    }
}

/// The play history, and clearing it.
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
        return count == 1 ? String(localized: "1 tune") : String(localized: "\(count.formatted()) tunes")
    }
}

/// Where Resonance keeps its files, and starting over.
private struct StorageSettings: View {
    @Environment(PlayerStore.self) private var store
    @State private var size: Int64?

    var body: some View {
        Section {
            LabeledContent("Resonance's folder") {
                HStack {
                    Text(size.map { $0.formatted(.byteCount(style: .file)) } ?? String(localized: "Measuring…"))
                        .foregroundStyle(.secondary)
                    AccentLink(String(localized: "Show in Finder")) { NSWorkspace.shared.open(AppPaths.supportDirectory) }
                }
            }
        } header: {
            Text("Data Folder")
        } footer: {
            Text("Resonance keeps its favorites, play history, playlists, fingerprints and, unless you choose another folder, HVSC in its own folder.")
        }
        .task {
            let url = AppPaths.supportDirectory
            size = await Task.detached(priority: .utility) { DiskUsage.bytes(at: url) }.value
        }

        ResetSettings()
    }
}

/// Puts a command on the clipboard and says so for a moment.
private struct CopyCommandButton: View {
    var title = String(localized: "Copy Command")
    let command: String
    @State private var copied = false

    var body: some View {
        Button(copied ? String(localized: "Copied") : title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied = true
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// The two-sheet copy icon, with its name as the tooltip. It turns into a
/// checkmark for a moment after a click, in a fixed frame so the row doesn't
/// move.
private struct CopyIconButton: View {
    let label: String
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.default, value: copied)
        .help(label)
        .accessibilityLabel(copied ? String(localized: "Copied") : label)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// What reaches Resonance from outside its window: first what needs setting
/// up, then what already works, with a link where macOS owns the switch.
private struct IntegrationSettings: View {
    /// Resonance's page in the Raycast Store. Until it's there, Settings has
    /// no row for it.
    private static let raycastExtension: URL? = nil

    @State private var installed = CommandLineTool.installed()
    @State private var shadowedBy: URL?
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent {
                Button(installed == nil ? "Install" : "Install Again") {
                    do {
                        let link = try CommandLineTool.install()
                        installed = link
                        shadowedBy = CommandLineTool.shadowedBy(link)
                        error = nil
                    } catch {
                        self.error = CommandLineTool.message(for: error)
                    }
                }
            } label: {
                Text("Command Line Tool")
                if let installed {
                    Text("Installed at \(installed.path)")
                } else {
                    Text("The terminal app, and commands for scripts")
                }
            }
            .onAppear { shadowedBy = installed.flatMap { CommandLineTool.shadowedBy($0) } }
            if let error {
                Text(error)
                    .foregroundStyle(.red)
            }
            if let shadowedBy {
                Text("Your terminal may run \(shadowedBy.path) instead, a different program with the same name. Use the full path to be sure.")
                    .foregroundStyle(.secondary)
            }
            if let folder = installed?.deletingLastPathComponent(), !CommandLineTool.isOnDefaultPath(folder) {
                LabeledContent {
                    CopyCommandButton(title: String(localized: "Copy Line"), command: CommandLineTool.pathCommand())
                } label: {
                    Text("Add \(folder.path) to your PATH")
                    Text("Copies the line for your shell. Run it in a terminal, then open a new window. Running it again changes nothing.")
                }
            }
            LabeledContent {
                CopyCommandButton(command: CommandLineTool.assistantCommand(installedAt: installed))
            } label: {
                Text("Claude and other assistants")
                Text("Copies the command that connects Claude Code")
            }
            if let raycast = Self.raycastExtension {
                LabeledContent {
                    Button("Get Extension") { NSWorkspace.shared.open(raycast) }
                } label: {
                    Text("Raycast")
                    Text("Eleven commands, without opening a window")
                }
            }
        } header: {
            Text("Set Up")
        } footer: {
            Text("Run **resonance** in a terminal for the terminal app, or **resonance --help** for its commands. Assistants need the tool. They can search, play and make playlists, but can't delete one.")
        }

        Section {
            LabeledContent {
                AccentLink(String(localized: "Open Shortcuts")) {
                    NSWorkspace.shared.open(URL(filePath: "/System/Applications/Shortcuts.app"))
                }
            } label: {
                Text("Siri and Shortcuts")
                Text("“Surprise me in Resonance”")
            }
            LabeledContent {
                AccentLink(String(localized: "System Settings")) { Self.openSystemSettings("com.apple.Spotlight-Settings.extension") }
            } label: {
                Text("Spotlight")
                Text("Finds tunes by title and composer")
            }
            LabeledContent {
                EmptyView()
            } label: {
                Text("Quick Look")
                Text("Press Space on a SID file in Finder")
            }
            LabeledContent {
                AccentLink(String(localized: "System Settings")) {
                    Self.openSystemSettings("com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")
                }
            } label: {
                Text("Notifications")
                Text("When a download or a long scan ends")
            }
            LabeledContent {
                EmptyView()
            } label: {
                Text("Dock icon")
                Text("Control-click for the tune and its controls")
            }
        } header: {
            Text("Already On")
        } footer: {
            Text("macOS owns these switches, so Resonance links to them.")
        }
    }

    private static func openSystemSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Starting over: the collection Download put in Resonance's folder, or
/// everything Resonance keeps. Both go to the Trash.
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
            Text("Both move files to the Trash, so you can put them back.")
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
            Text("Moves Resonance's folder to the Trash: your favorites, play history, playlists, fingerprints and its HVSC collection. Its settings are forgotten. Resonance then restarts, fresh.")
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
                self.error = String(localized: "Couldn't move it to the Trash: \(error.localizedDescription)")
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

/// The visualizers' color theme: a preset or your own colors, and whether
/// its badge shows.
#if CSDB
private struct SceneSettings: View {
    @AppStorage(Pref.csdbEnabled) private var enabled = false
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

#endif

private struct StartPageSettings: View {
    @AppStorage(Pref.startPage) private var startPage = StartPage.myPlaylist
#if CSDB
    @AppStorage(Pref.csdbEnabled) private var csdbEnabled = false
#endif

    var body: some View {
        Section {
            Picker("Start page", selection: $startPage) {
                ForEach(StartPage.allCases) { page in
                    Text(page.title).tag(page)
                }
            }
        } footer: {
#if CSDB
            Text(startPage == .scenePulse && !csdbEnabled
                 ? "CSDb is switched off, so Resonance opens on the HVSC Home instead."
                 : "What Resonance shows when it opens.")
                .foregroundStyle(.secondary)
#else
            Text(String(localized: "What Resonance shows when it opens."))
                .foregroundStyle(.secondary)
#endif
        }
    }
}

private struct KeyboardSettings: View {
    @AppStorage(Pref.keyScheme) private var scheme = KeyScheme.normal

    var body: some View {
        Section {
            Picker("Keys", selection: $scheme) {
                ForEach(KeyScheme.allCases) { Text($0.displayName).tag($0) }
            }
        } footer: {
            Text("Vim and Emacs add their keys for moving through lists and playing tunes, except while you're typing. The menus' shortcuts keep working. Press ? in the main window to see them all.")
        }
    }
}

private struct MenuBarSettings: View {
    @AppStorage(Pref.menuBarPlayer) private var showsMenuBarPlayer = true

    var body: some View {
        Section {
            Toggle("Show the player in the menu bar", isOn: $showsMenuBarPlayer)
        } footer: {
            Text("What's playing, the controls, Favorite, Shuffle, Surprise Me and what plays next, from the menu bar, with the window closed too.")
        }
    }
}

/// The mode, chosen from pictures of it, as in System Settings.
private struct AppearanceSettings: View {
    @AppStorage(Pref.appAppearance) private var appearance = AppAppearance.auto

    var body: some View {
        Section {
            LabeledContent("Appearance") {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(AppAppearance.allCases) { mode in
                        AppearanceChoice(mode: mode, isSelected: appearance == mode) {
                            appearance = mode
                        }
                    }
                }
            }
        }
        .onChange(of: appearance) { _, mode in mode.apply() }
    }
}

private struct AppearanceChoice: View {
    let mode: AppAppearance
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 5) {
                AppearanceThumbnail(mode: mode)
                    .padding(2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
                    }
                Text(mode.title)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A small Resonance window with the icon's three bars, on a light or dark
/// backdrop. Auto is half of each. Its colors are fixed, whatever the app's
/// mode is, because it pictures the modes.
private struct AppearanceThumbnail: View {
    let mode: AppAppearance

    var body: some View {
        ZStack {
            scene(dark: mode == .dark)
            if mode == .auto {
                scene(dark: true)
                    .mask {
                        HStack(spacing: 0) {
                            Color.clear
                            Color.black
                        }
                    }
            }
        }
        .frame(width: 68, height: 44)
        .clipShape(.rect(cornerRadius: 7))
    }

    private func scene(dark: Bool) -> some View {
        ZStack {
            LinearGradient(
                colors: dark
                    ? [Color(red: 0.12, green: 0.14, blue: 0.32), Color(red: 0.24, green: 0.12, blue: 0.38)]
                    : [Color(red: 0.72, green: 0.84, blue: 0.96), Color(red: 0.88, green: 0.82, blue: 0.96)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 2) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { color in
                        Circle().fill(color).frame(width: 3, height: 3)
                    }
                }
                HStack(alignment: .bottom, spacing: 3) {
                    bar(.cyan, height: 12)
                    bar(.purple, height: 17)
                    bar(.orange, height: 9)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(4)
            .frame(width: 46, height: 32)
            .background(dark ? Color(white: 0.13) : .white, in: .rect(cornerRadius: 4))
        }
    }

    private func bar(_ color: Color, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: 6, height: height)
    }
}

private struct ThemeSettings: View {
    @Environment(\.voiceTheme) private var theme
    @AppStorage(Pref.theme) private var themeID = VoiceTheme.resonance.id
    @AppStorage(Pref.customTheme) private var customData = Data()
    @AppStorage(Pref.themeBadge) private var showsBadge = true

    var body: some View {
        Section {
            Picker("Colors", selection: $themeID) {
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
            Text("Colors the three voices in every visualizer. Buttons and links keep the system accent color.")
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
        .environment(Updater())
}

/// The update channel, Sparkle's two settings, and a way to check now.
private struct UpdateSettings: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        Section {
            if let failure = updater.lastFailure {
                failureRow(failure)
            }
            LabeledContent("Update channel") {
                Picker("Update channel", selection: $updater.channel) {
                    ForEach(UpdateChannel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .buttonBorderShape(.capsule)
                .fixedSize()
            }
            Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
            Toggle("Download and install automatically", isOn: $updater.installsAutomatically)
                .disabled(!updater.checksAutomatically)
            LabeledContent("Last checked") {
                HStack {
                    Text(lastChecked)
                        .foregroundStyle(.secondary)
                    AccentLink(String(localized: "Check Now")) { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if updater.isAvailable {
                    Text(updater.channel.summary)
                }
                Text(updater.isAvailable
                     ? "Resonance checks for a new version once a day. Updates are verified with Resonance's signing key before they're installed, and nothing about your Mac is sent. Automatic updates install when you quit."
                     : "This build of Resonance doesn't update itself. Releases from the website do.")
            }
        }
        .disabled(!updater.isAvailable)
    }

    /// Tinted like a destructive button, so it reads as something gone wrong,
    /// with primary text: red text on the tint is about 3:1, primary over 11:1.
    /// A box inside the row, because a grouped form on macOS ignores
    /// `listRowBackground`.
    private func failureRow(_ failure: UpdateFailure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last update failed")
                    .fontWeight(.medium)
                Spacer()
                CopyIconButton(label: String(localized: "Copy Details"), text: failure.details)
            }
            Text(failure.message)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.primary)
        .padding(10)
        .background(Color.red.opacity(0.15), in: .rect(cornerRadius: 8))
    }

    private var lastChecked: String {
        guard let date = updater.lastCheck else { return String(localized: "Never") }
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
