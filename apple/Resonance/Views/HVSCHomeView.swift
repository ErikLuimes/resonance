import SwiftUI
import AppKit
import PhosphorCore

/// The HVSC Home: the collection's front door.
///
/// While the folder holds no tree it is the download surface — an empty
/// state, then the download's progress. Once the collection has arrived it
/// shows what the tree's own DOCUMENTS say: the release, the latest update
/// announcement, the counts, the disk images and Phosphor's published
/// playlists. Selecting the sidebar's Collection row shows this view.
struct HVSCHomeView: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        Group {
            if store.hasCollection, let info = store.hvscInfo {
                CollectionHome(info: info)
            } else if store.hasCollection {
                ProgressView("Reading the collection…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let sync = store.hvscSync {
                if sync.running {
                    DownloadProgress(sync: sync)
                } else if let error = sync.error {
                    DownloadError(error: error)
                } else {
                    // Finished, but the app hasn't pointed at the folder yet.
                    ProgressView("Collection downloaded")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                DownloadOffer()
            }
        }
    }
}

// MARK: - The download surface

/// The empty state: one offer, one footnote (the location lives in Settings,
/// deliberately not here).
private struct DownloadOffer: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            Tile(size: 110, symbol: "waveform")

            Text("No collection on this Mac yet")
                .font(.title2.weight(.semibold))

            Text("The High Voltage SID Collection — every well-kept C64 SID in one complete, documented archive. Download it to browse by composer, search, and play.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if let error = store.hvscSyncError {
                VStack(spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.primary)
                        .symbolRenderingMode(.multicolor)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { store.startHvscSync() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Button {
                    store.startHvscSync()
                } label: {
                    Label("Download the Collection", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Text("Installs into the collection folder — change it in Settings…")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A download that ended in an error before a collection appeared.
private struct DownloadError: View {
    let error: String
    @Environment(PlayerStore.self) private var store

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .symbolRenderingMode(.multicolor)
            Text("The Download Stopped")
                .font(.title2.weight(.semibold))
            Text(error)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Try Again") { store.startHvscSync() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The download's progress: a ring over the tile, a bar with its numbers,
/// and the worker's own line (which names the file being extracted).
private struct DownloadProgress: View {
    let sync: HvscSyncStatus
    @Environment(PlayerStore.self) private var store

    var body: some View {
        let extracting = sync.filesTotal > 0
        let fraction = sync.fraction

        VStack(spacing: 18) {
            ZStack {
                Tile(size: 96, symbol: "archivebox")
                if let fraction {
                    Circle()
                        .stroke(.quaternary, lineWidth: 5)
                        .frame(width: 132, height: 132)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 132, height: 132)
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.title.bold())
                        .monospacedDigit()
                } else {
                    ProgressView()
                }
            }
            .animation(.linear(duration: 0.25), value: fraction ?? 0)

            Text(extracting ? "Extracting the Collection" : "Downloading the Collection")
                .font(.title2.weight(.semibold))

            if let fraction, !label.isEmpty {
                HStack(spacing: 12) {
                    ProgressView(value: fraction)
                    Text(label)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .frame(width: 340)
            } else {
                ProgressView()
            }

            Text(sync.current)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Button("Cancel") { store.cancelHvscSync() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The bar's caption: files while the archive extracts, bytes while it
    /// streams; empty before the server announces a total.
    private var label: String {
        if sync.filesTotal > 0 {
            return "\(sync.filesDone.formatted()) of \(sync.filesTotal.formatted()) files"
        }
        if sync.bytesTotal > 0 {
            let mb = Double(1024 * 1024)
            let done = (Double(sync.bytesDone) / mb).formatted(.number.precision(.fractionLength(1)))
            let total = (Double(sync.bytesTotal) / mb).formatted(.number.precision(.fractionLength(1)))
            return "\(done) MB of \(total) MB"
        }
        return ""
    }
}

// MARK: - The parsed collection

/// The Home once the collection has arrived: the hero, then the cards.
private struct CollectionHome: View {
    let info: HvscInfo
    @Environment(PlayerStore.self) private var store

    @State private var showAllPlaylists = false
    @State private var showAnnouncement = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero
                // Two columns instead of a grid: a grid row is as tall as
                // its tallest cell, so a card below a short one would float
                // down. Stacked columns only ever leave 14 pt of spacing.
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 14) {
                        if let update = info.update {
                            whatsNew(update)
                        }
                        aboutCard
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 14) {
                        if !info.playlists.isEmpty {
                            playlistsCard
                        }
                        if !info.disks.isEmpty {
                            disksCard
                        }
                        documentsCard
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(22)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showAllPlaylists) {
            PlaylistsSheet(playlists: info.playlists)
        }
        .sheet(isPresented: $showAnnouncement) {
            if let update = info.update {
                VStack(spacing: 0) {
                    HStack {
                        Text("Update #\(update.number)\(update.date.map { " · \($0)" } ?? "")")
                            .font(.headline)
                        Spacer()
                        Button {
                            showAnnouncement = false
                        } label: {
                            Image(systemName: "xmark")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.cancelAction)
                        .help("Close")
                    }
                    .padding(14)
                    Divider()
                    ScrollView {
                        Text(update.text)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                }
                .frame(minWidth: 560, minHeight: 420)
            }
        }
    }

    // ── Hero ──

    private var hero: some View {
        // Two layouts for the same data. Wide: the stats sit right of the
        // title, separated by a divider. Narrow: the stats drop below the
        // title row. ViewThatFits picks the first whose ideal width fits,
        // so the title is never squeezed between the tile and the numbers.
        VStack(spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    Tile(size: 54, symbol: "waveform")
                    titleBlock
                    Spacer(minLength: 16)
                    stats(separated: true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 16) {
                        Tile(size: 54, symbol: "waveform")
                        titleBlock
                        Spacer(minLength: 0)
                    }
                    stats(separated: false)
                }
            }
            HStack(spacing: 8) {
                chip(Palette.teal, "Musicians", info.musicianTunes)
                chip(Palette.orange, "Demos", info.demoTunes)
                chip(Palette.purple, "Games", info.gameTunes)
                Spacer()
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text("High Voltage SID Collection")
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    // The title is measured at full width, so it is either
                    // shown in complete form or the layout below it takes
                    // over — it is never truncated or shrunk.
                    .fixedSize()
                if let version = info.version {
                    Text("v\(version)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.18), in: .capsule)
                        .foregroundStyle(.tint)
                }
            }
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stats(separated: Bool) -> some View {
        HStack(spacing: 22) {
            stat(info.totalTunes.formatted(), "tunes")
            stat(info.composers.formatted(), "composers")
            stat(info.stilEntries.formatted(), "STIL notes")
            stat(songLengthCoverage, "song lengths")
        }
        .padding(.leading, separated ? 22 : 0)
        .overlay(alignment: .leading) {
            if separated {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let version = info.version { parts.append("Release \(version)") }
        if let date = info.releaseDate { parts.append(date) }
        return parts.joined(separator: " · ")
    }

    private var songLengthCoverage: String {
        guard info.totalTunes > 0 else { return "—" }
        let percent = Double(info.songlengthEntries) / Double(info.totalTunes) * 100
        return percent >= 99.5 ? "100%" : "\(Int(percent.rounded()))%"
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.body.weight(.semibold))
                .monospacedDigit()
                // Never compress: the spacer between the title and the stats
                // absorbs narrow windows instead of wrapping the numbers.
                .fixedSize()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }

    private func chip(_ color: Color, _ name: String, _ count: UInt32) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(name)
            Text(count.formatted())
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.4), in: .capsule)
    }

    // ── Cards ──

    private func whatsNew(_ update: HvscUpdate) -> some View {
        let title = info.version.map { "What's new in v\($0)" } ?? "What's new"
        let meta = "update #\(update.number)"
            + (update.previousVersion.map { " · from v\($0)" } ?? "")
        return card(title, "arrow.down.circle", Palette.teal, meta: meta) {
            VStack(spacing: 2) {
                if let count = update.newSids {
                    countRow("checkmark", .green, count, "new SIDs added")
                }
                if let count = update.fixedRips {
                    countRow("checkmark", .green, count, "fixed and better rips")
                }
                if let count = update.creditFixes {
                    countRow("checkmark", .green, count, "credit fixes")
                }
                if let count = update.moved {
                    countRow("arrow.left.arrow.right", Palette.teal, count, "tunes re-filed")
                }
            }
            Button {
                showAnnouncement = true
            } label: {
                Text("Read the full announcement →")
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .font(.callout)
            .padding(.top, 10)
        }
    }

    private var playlistsCard: some View {
        let top = Array(info.playlists.sorted { $0.tracks > $1.tracks }.prefix(4))
        return card("Curated playlists", "list.bullet", Palette.purple,
                    meta: "\(info.playlists.count) total") {
            VStack(spacing: 0) {
                ForEach(top, id: \.name) { playlist in
                    HStack(spacing: 8) {
                        Text(playlist.name)
                            .lineLimit(1)
                        Text("\(playlist.tracks.formatted()) tunes")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button {
                            store.playPublishedPlaylist(playlist)
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                                .frame(width: 22, height: 22)
                                .background(.tint.opacity(0.14), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .help("Play \(playlist.name)")
                    }
                    .font(.callout)
                    .padding(.vertical, 5)
                }
            }
            Button {
                showAllPlaylists = true
            } label: {
                Text("See all \(info.playlists.count) playlists →")
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .font(.callout)
            .padding(.top, 10)
        }
    }

    private var aboutCard: some View {
        card("About the project", "person.2", Palette.orange) {
            VStack(alignment: .leading, spacing: 10) {
                Text(info.summary ?? "A complete archive of the C64 era's SID music, kept alive by a volunteer crew of SID archeologists.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                Link(destination: URL(string: "https://hvsc.c64.org")!) {
                    Label("hvsc.c64.org", systemImage: "globe")
                }
                .font(.callout)
            }
        }
    }

    private var disksCard: some View {
        card("C64 disks in the archive", "opticaldisc", Palette.teal) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(info.disks, id: \.name) { disk in
                    HStack(spacing: 8) {
                        Text(disk.name)
                            .lineLimit(1)
                        Spacer()
                        Text("\(disk.images) images")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .font(.callout)
                    .padding(.vertical, 5)
                }
                Text("Bootable disk images for your C64 emulator — their tunes are also in the collection.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
            }
        }
    }

    private var documentsCard: some View {
        card("Reference documents", "doc.text", Palette.purple,
             meta: "\(info.documents) files") {
            VStack(spacing: 2) {
                docRow("STIL — tune information", "\(info.stilEntries.formatted()) entries")
                docRow("Songlengths database", "\(info.songlengthEntries.formatted()) entries")
                docRow("SID file format", "PSID · RSID")
            }
            Button {
                let root = URL(filePath: info.root)
                NSWorkspace.shared.open(root.appending(path: "DOCUMENTS"))
            } label: {
                Text("Show in Finder →")
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .font(.callout)
            .padding(.top, 10)
        }
    }

    // ── Card parts ──

    @ViewBuilder
    private func card<Content: View>(
        _ title: String,
        _ systemImage: String,
        _ tint: Color,
        meta: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer()
                if let meta {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func countRow(_ symbol: String, _ tint: Color, _ count: UInt32, _ label: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(count.formatted())
                .fontWeight(.semibold)
                .monospacedDigit()
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.vertical, 4)
    }

    private func docRow(_ name: String, _ meta: String?) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .lineLimit(1)
            Spacer()
            if let meta {
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .padding(.vertical, 5)
    }
}

// MARK: - Shared pieces

/// Phosphor's published playlists: every one, with its play button.
private struct PlaylistsSheet: View {
    let playlists: [HvscPlaylist]
    @Environment(PlayerStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Published Playlists")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            .padding(14)
            Divider()
            List(playlists, id: \.name) { playlist in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name)
                        if let description = playlist.description {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Text("\(playlist.tracks.formatted()) tunes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button {
                        store.playPublishedPlaylist(playlist)
                    } label: {
                        Image(systemName: "play.circle")
                            .font(.title3)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.borderless)
                    .help("Play \(playlist.name)")
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}

/// The collection's icon: the voice palette's purple and teal on a tile.
private struct Tile: View {
    var size: CGFloat
    var symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [Palette.purple, Palette.teal],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                ),
                in: .rect(cornerRadius: size * 0.26)
            )
    }
}

/// The voice palette the visualizers use; the collection's tile and the
/// card accents borrow from it.
private enum Palette {
    static let teal = Color(red: 63 / 255, green: 208 / 255, blue: 232 / 255)
    static let purple = Color(red: 155 / 255, green: 107 / 255, blue: 1.0)
    static let orange = Color(red: 1.0, green: 154 / 255, blue: 60 / 255)
}

#Preview {
    HVSCHomeView()
        .environment(PlayerStore.preview)
        .environment(LibraryStore(player: .preview))
        .frame(width: 760, height: 520)
}
