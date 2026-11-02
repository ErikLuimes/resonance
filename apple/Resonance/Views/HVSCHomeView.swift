import SwiftUI
import AppKit
import PhosphorCore

/// The HVSC Home: the collection's front door.
///
/// While the folder holds no tree it is the download surface — an empty
/// state, then the download's progress. Once the collection has arrived it
/// shows what the tree's own DOCUMENTS say: the release and its counts, the
/// three sections to browse, the latest update announcement, Phosphor's
/// published playlists, the disk images and the reference documents. Selecting the sidebar's Collection row shows this view.
struct HVSCHomeView: View {
    /// Shows a section in the sidebar: the Browse tiles' action.
    var openCategory: (HvscCategory) -> Void = { _ in }
    @Environment(PlayerStore.self) private var store

    var body: some View {
        Group {
            if store.hasCollection, let info = store.hvscInfo {
                CollectionHome(info: info, openCategory: openCategory)
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

/// The Home once the collection has arrived: the hero, the three sections
/// to browse, then what's new, the playlists and the archive's extras.
private struct CollectionHome: View {
    let info: HvscInfo
    let openCategory: (HvscCategory) -> Void
    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(\.colorScheme) private var colorScheme

    @State private var showAllPlaylists = false
    @State private var showAnnouncement = false
    /// The content's width, which picks the column counts below. The
    /// detail column's minimum is pinned elsewhere, so this only ever
    /// rearranges the content inside it.
    @State private var width: CGFloat = 900

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                browse
                if wide {
                    // Equal heights: the row is as tall as its tallest
                    // panel, and each panel stretches to it.
                    // Five twelfths to the counts, the rest to the covers.
                    HStack(alignment: .top, spacing: 20) {
                        whatsNewSection
                            .frame(width: info.update == nil ? 0 : (width - 20) * 5 / 12)
                            .frame(maxHeight: .infinity, alignment: .top)
                        playlistsSection
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    whatsNewSection
                    playlistsSection
                }
                extras
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showAllPlaylists) {
            PlaylistsSheet(playlists: info.playlists)
        }
        .sheet(isPresented: $showAnnouncement) {
            if let update = info.update {
                AnnouncementSheet(update: update)
            }
        }
    }

    private var wide: Bool { width >= 820 }

    // ── Hero ──

    private var hero: some View {
        // Two layouts for the same data. Wide: the stats sit right of the
        // title. Narrow: they drop below it. ViewThatFits picks the first
        // whose ideal width fits, so the title is never squeezed.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 36) {
                heroIdentity
                Spacer(minLength: 0)
                stats
            }
            VStack(alignment: .leading, spacing: 22) {
                heroIdentity
                stats
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.22), Palette.purple.opacity(0.14), Palette.teal.opacity(0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                HeroWaves()
                    .opacity(0.55)
            }
            .allowsHitTesting(false)
        }
        .clipShape(.rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(.separator)
        }
    }

    private var heroIdentity: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                Tile(size: 84, symbol: "waveform")
                    .shadow(color: Palette.purple.opacity(0.35), radius: 14, y: 8)
                VStack(alignment: .leading, spacing: 4) {
                    if let version = info.version {
                        HStack(spacing: 8) {
                            Text("Release \(version)")
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .kerning(0.6)
                                .foregroundStyle(.secondary)
                            Text("v\(version)")
                                .font(.caption.monospaced().weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.18), in: .capsule)
                                .foregroundStyle(.tint)
                        }
                    }
                    Text("High Voltage SID Collection")
                        .font(.system(size: 30, weight: .bold))
                        .kerning(-0.4)
                        // Shown whole or the layout below takes over: the
                        // title is never truncated.
                        .fixedSize()
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button {
                    Task { await library.surpriseMe() }
                } label: {
                    Label("Shuffle Collection", systemImage: "shuffle")
                }
                .buttonStyle(.borderedProminent)
                .help("Play random tunes from all of HVSC")
                if let top = topPlaylist {
                    Button {
                        store.playPublishedPlaylist(top)
                    } label: {
                        Label("Play \(shortName(top.name))", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .help("Play \(top.name)")
                }
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
    }

    private var stats: some View {
        HStack(spacing: 28) {
            stat(info.totalTunes.formatted(), "tunes")
            stat(info.composers.formatted(), "composers")
            stat(info.stilEntries.formatted(), "STIL notes")
            stat(songLengthCoverage, "song lengths")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        // Darker than the hero in dark mode, lighter in light mode.
        .background(colorScheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.55),
                    in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.separator)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .fixedSize()
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }

    /// "Released June 28, 2026 · every C64 SID tune, archived since 1996".
    private var subtitle: String {
        let tagline = "Every C64 SID tune, archived since 1996"
        guard let date = info.releaseDate else { return tagline }
        return "Released \(date) · \(tagline)"
    }

    private var songLengthCoverage: String {
        guard info.totalTunes > 0 else { return "—" }
        let percent = Double(info.songlengthEntries) / Double(info.totalTunes) * 100
        return percent >= 99.5 ? "100%" : "\(Int(percent.rounded()))%"
    }

    /// The hero's second button: HVSC's own Top 100 when Phosphor
    /// publishes it.
    private var topPlaylist: HvscPlaylist? {
        info.playlists.first { $0.name.localizedCaseInsensitiveContains("top 100") }
    }

    // ── Browse ──

    private var browse: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Browse", sub: "Tunes by where they come from")
            let layout = width >= 520
                ? AnyLayout(HStackLayout(spacing: 14))
                : AnyLayout(VStackLayout(spacing: 14))
            layout {
                browseTile(.musicians, info.musicianTunes, Palette.teal)
                browseTile(.demos, info.demoTunes, Palette.orange)
                browseTile(.games, info.gameTunes, Palette.purple)
            }
        }
    }

    private func browseTile(_ category: HvscCategory, _ count: UInt32, _ color: Color) -> some View {
        let share = info.totalTunes > 0 ? Double(count) / Double(info.totalTunes) : 0
        return BrowseTile(
            title: category.displayName,
            symbol: category.symbolName,
            count: count,
            share: share,
            color: color
        ) {
            openCategory(category)
        }
    }

    // ── What's new ──

    @ViewBuilder
    private var whatsNewSection: some View {
        if let update = info.update {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(info.version.map { "What's New in v\($0)" } ?? "What's New") {
                    AccentLink("Announcement") { showAnnouncement = true }
                }
                WhatsNewPanel(update: update)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    // ── Playlists ──

    @ViewBuilder
    private var playlistsSection: some View {
        if !info.playlists.isEmpty {
            let top = Array(info.playlists.sorted { $0.tracks > $1.tracks }.prefix(4))
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Curated Playlists", sub: "\(info.playlists.count) playlists") {
                    AccentLink("See All") { showAllPlaylists = true }
                }
                // Four across, or two rows of two where a cover would get
                // too small to read.
                let columns = (wide ? (width - 20) * 7 / 12 : width) >= 440 ? 4 : 2
                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    ForEach(Array(stride(from: 0, to: top.count, by: columns)), id: \.self) { start in
                        GridRow(alignment: .top) {
                            ForEach(start..<min(start + columns, top.count), id: \.self) { index in
                                PlaylistCover(
                                    playlist: top[index],
                                    label: shortName(top[index].name),
                                    stripes: Raster.sets[index % Raster.sets.count]
                                )
                            }
                            // Keep the last row's covers the same size.
                            ForEach(0..<(columns - min(columns, top.count - start)), id: \.self) { _ in
                                Color.clear.gridCellUnsizedAxes(.vertical)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A playlist's cover label: its name without the words every one of
    /// them shares. "Epic C64 SID Collection" → "Epic".
    private func shortName(_ name: String) -> String {
        let filler: Set<String> = ["hvsc", "c64", "sid", "collection", "playlist", "favorite", "favourite"]
        let words = name.split(separator: " ").filter { !filler.contains($0.lowercased()) }
        return words.isEmpty ? name : words.prefix(2).joined(separator: " ")
    }

    // ── Disks, reference, about ──

    @ViewBuilder
    private var extras: some View {
        if width >= 820 {
            HStack(alignment: .top, spacing: 20) {
                if !info.disks.isEmpty {
                    disksPanel.frame(maxHeight: .infinity, alignment: .top)
                }
                referencePanel.frame(maxHeight: .infinity, alignment: .top)
                aboutPanel.frame(maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else if width >= 560 {
            VStack(spacing: 20) {
                HStack(alignment: .top, spacing: 20) {
                    if !info.disks.isEmpty {
                        disksPanel.frame(maxHeight: .infinity, alignment: .top)
                    }
                    referencePanel.frame(maxHeight: .infinity, alignment: .top)
                }
                .fixedSize(horizontal: false, vertical: true)
                aboutPanel
            }
        } else {
            VStack(spacing: 20) {
                if !info.disks.isEmpty { disksPanel }
                referencePanel
                aboutPanel
            }
        }
    }

    private var disksPanel: some View {
        Panel("C64 Disk Images", meta: "\(info.disks.count) \(info.disks.count == 1 ? "disk" : "disks")") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(info.disks.enumerated()), id: \.element.name) { index, disk in
                    HStack(spacing: 14) {
                        Floppy(color: [Color.accentColor, Palette.teal, Palette.orange, Palette.purple][index % 4])
                        VStack(alignment: .leading, spacing: 1) {
                            Text(disk.name)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            Text("\(disk.images) \(disk.images == 1 ? "image" : "images")")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(6)
                }
                Text("Bootable in any C64 emulator. Their tunes are also in the collection.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private var referencePanel: some View {
        let documents = URL(filePath: info.root).appending(path: "DOCUMENTS")
        return Panel("Reference", meta: "\(info.documents) files") {
            VStack(alignment: .leading, spacing: 2) {
                ReferenceRow(symbol: "text.document", name: "STIL", detail: "Tune information",
                             trailing: info.stilEntries.formatted(),
                             file: documents.appending(path: "STIL.txt"))
                ReferenceRow(symbol: "clock", name: "Songlengths", detail: "Playback durations",
                             trailing: info.songlengthEntries.formatted(), file: nil)
                ReferenceRow(symbol: "chevron.left.forwardslash.chevron.right", name: "SID File Format",
                             detail: "Header specification", trailing: "PSID · RSID",
                             file: documents.appending(path: "SID_file_format.txt"))
                ReferenceRow(symbol: "ladybug", name: "BUGlist", detail: "Known playback issues",
                             trailing: "TXT", file: documents.appending(path: "BUGlist.txt"))
                Button("Show in Finder") {
                    NSWorkspace.shared.open(documents)
                }
                .controlSize(.small)
                .padding(.top, 8)
            }
        }
    }

    private var aboutPanel: some View {
        Panel("About the Project", meta: "since May 1996") {
            VStack(alignment: .leading, spacing: 14) {
                Text(info.summary ?? "A complete archive of the C64 era's SID music, kept alive by a volunteer crew of SID archeologists.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach(aboutFacts, id: \.self) { fact in
                        Text(fact)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.fill.tertiary, in: .capsule)
                    }
                }
                Link("hvsc.c64.org", destination: URL(string: "https://hvsc.c64.org")!)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
                    .pointerStyle(.link)
            }
        }
    }

    private var aboutFacts: [String] {
        var facts = ["Started May 1996"]
        if let version = info.version { facts.append("\(version) releases") }
        facts.append("PSID & RSID")
        return facts
    }

    // ── Parts ──

    private func sectionHeader(_ title: String, sub: String? = nil) -> some View {
        sectionHeader(title, sub: sub) { EmptyView() }
    }

    private func sectionHeader<Trailing: View>(
        _ title: String,
        sub: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
            if let sub {
                Text(sub)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            trailing()
                .font(.caption.weight(.semibold))
        }
    }
}

// MARK: - Home parts

/// The flat card every Home panel sits on: a faint fill with a hairline.
private struct CardBackground: ViewModifier {
    var radius: CGFloat = 16
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .background(highlighted ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.fill.quaternary),
                        in: .rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(.separator)
            }
    }
}

/// A titled panel: the disks, reference and about cards.
private struct Panel<Content: View>: View {
    let title: String
    let meta: String?
    @ViewBuilder let content: Content

    init(_ title: String, meta: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.meta = meta
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                if let meta {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(CardBackground())
    }
}

/// One of the three sections, with its share of the collection; opens the
/// section in the sidebar.
private struct BrowseTile: View {
    let title: String
    let symbol: String
    let count: UInt32
    let share: Double
    let color: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(color)
                        .frame(width: 34, height: 34)
                        .background(color.opacity(0.18), in: .rect(cornerRadius: 10))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(title)
                    .font(.body.weight(.semibold))
                Text(count.formatted())
                    .font(.system(size: 26, weight: .bold))
                    .monospacedDigit()
                HStack(spacing: 8) {
                    Meter(fraction: share, color: color)
                    Text(share.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topTrailing) {
                // A soft glow in the corner, in the section's color.
                RadialGradient(colors: [color.opacity(0.2), .clear], center: .center, startRadius: 0, endRadius: 100)
                    .frame(width: 200, height: 200)
                    .offset(x: 60, y: -60)
            }
            .clipShape(.rect(cornerRadius: 16))
            .modifier(CardBackground(highlighted: hovering))
            .contentShape(.rect(cornerRadius: 16))
            .offset(y: hovering ? -2 : 0)
            .animation(.easeOut(duration: 0.2), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Browse \(title)")
    }
}

/// A slim bar showing a fraction.
private struct Meter: View {
    let fraction: Double
    let color: Color

    var body: some View {
        Capsule()
            .fill(.fill.tertiary)
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(color)
                        .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
                }
            }
    }
}

/// The latest update's counts: a stacked bar of their proportions, then
/// one row per count.
private struct WhatsNewPanel: View {
    let update: HvscUpdate

    var body: some View {
        let rows = self.rows
        let total = rows.reduce(0) { $0 + Double($1.count) }

        VStack(alignment: .leading, spacing: 0) {
            if total > 0 {
                GeometryReader { proxy in
                    let gaps = CGFloat(rows.count - 1) * 2
                    HStack(spacing: 2) {
                        ForEach(rows, id: \.label) { row in
                            Rectangle()
                                .fill(row.color)
                                .frame(width: max(2, (proxy.size.width - gaps) * Double(row.count) / total))
                        }
                    }
                }
                .frame(height: 8)
                .clipShape(.capsule)
                .padding(.top, 4)
                .padding(.bottom, 14)
            }
            ForEach(Array(rows.enumerated()), id: \.element.label) { index, row in
                if index > 0 { Divider() }
                HStack(spacing: 10) {
                    Circle()
                        .fill(row.color)
                        .frame(width: 8, height: 8)
                    Text(row.count.formatted())
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                    Text(row.label)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
            }
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(CardBackground())
    }

    private var rows: [(label: String, count: UInt32, color: Color)] {
        var rows: [(label: String, count: UInt32, color: Color)] = []
        if let count = update.newSids { rows.append(("new SIDs added", count, .green)) }
        if let count = update.fixedRips { rows.append(("fixed and better rips", count, Palette.teal)) }
        if let count = update.creditFixes { rows.append(("credit fixes", count, Palette.purple)) }
        if let count = update.moved { rows.append(("tunes re-filed", count, Palette.orange)) }
        return rows
    }

    /// "Update #85, released June 28, 2026, follows v84."
    private var footnote: String {
        var text = "Update #\(update.number)"
        if let date = update.date { text += ", released \(date)" }
        if let previous = update.previousVersion { text += ", follows v\(previous)" }
        return text + "."
    }
}

/// A published playlist as a square cover of C64 raster bars; the play
/// button shows on hover, and a click anywhere on the cover plays it.
private struct PlaylistCover: View {
    let playlist: HvscPlaylist
    let label: String
    let stripes: [Color]
    @Environment(PlayerStore.self) private var store

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                store.playPublishedPlaylist(playlist)
            } label: {
                Raster(stripes: stripes)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        Text(label)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .textCase(.uppercase)
                            .kerning(0.4)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
                            .lineLimit(2)
                            .padding(.leading, 10)
                            .padding(.trailing, 50)
                            .padding(.bottom, 9)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Color.accentColor, in: .circle)
                            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                            .padding(10)
                            .opacity(hovering ? 1 : 0)
                            .offset(y: hovering ? 0 : 6)
                    }
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.separator)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 8)
                    .contentShape(.rect(cornerRadius: 12))
                    .animation(.easeOut(duration: 0.2), value: hovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Play \(playlist.name)")

            Text(playlist.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .padding(.top, 2)
            Text("\(playlist.tracks.formatted()) tunes")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Horizontal C64 raster bars, repeating the stripe pattern down the cover.
private struct Raster: View {
    /// One color per 4 pt band.
    let stripes: [Color]

    var body: some View {
        Canvas { context, size in
            let band: CGFloat = 4
            var y: CGFloat = 0
            var index = 0
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: band)),
                             with: .color(stripes[index % stripes.count]))
                y += band
                index += 1
            }
        }
    }

    /// Patterns in the C64's own palette (Pepto's values).
    static let sets: [[Color]] = {
        func c64(_ hex: UInt32) -> Color {
            Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        }
        let blue = c64(0x352879), lightBlue = c64(0x6C5EB5), cyan = c64(0x70A4B2)
        let brown = c64(0x68372B), lightRed = c64(0x9A6759), yellow = c64(0xB8C76F)
        let green = c64(0x588D43), lightGreen = c64(0x9AE29B), black = c64(0x000000)
        let purple = c64(0x6F3D86)
        return [
            [blue, blue, lightBlue, lightBlue, cyan, cyan, lightBlue, lightBlue],
            [brown, lightRed, yellow, lightRed, brown, black],
            [green, lightGreen, green, black, black, black],
            [purple, purple, black, cyan, black],
        ]
    }()
}

/// A 5¼" floppy: a sleeve with a label strip, the hub and the read slot.
private struct Floppy: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(white: 0.16))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.white.opacity(0.14))
            }
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(height: 10)
                    .padding([.horizontal, .top], 4)
            }
            .overlay {
                Circle()
                    .fill(Color(white: 0.09))
                    .frame(width: 12, height: 12)
                    .overlay { Circle().strokeBorder(Color(white: 0.24), lineWidth: 3).padding(-3) }
                    .offset(y: 1)
            }
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(Color(white: 0.09))
                    .frame(width: 5, height: 7)
                    .padding(.bottom, 3)
            }
            .frame(width: 46, height: 46)
            .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
    }
}

/// A DOCUMENTS entry: opens the file when the collection has it.
private struct ReferenceRow: View {
    let symbol: String
    let name: String
    let detail: String
    let trailing: String
    let file: URL?

    @State private var hovering = false

    var body: some View {
        let url = file.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let row = HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.fill.tertiary, in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Text(trailing)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(hovering && url != nil ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 9))
        .contentShape(.rect(cornerRadius: 9))

        if let url {
            Button { NSWorkspace.shared.open(url) } label: { row }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Open \(url.lastPathComponent)")
        } else {
            row
        }
    }
}

/// The hero's backdrop: three slow waves in the voice colors. Its own
/// view, so its redraws never touch the hero's buttons.
private struct HeroWaves: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let waves: [(y: Double, frequency: Double, color: Color)] = [
                    (0.62, 1, Palette.teal), (0.5, 1.6, Palette.orange), (0.38, 2.3, Palette.purple),
                ]
                for (index, wave) in waves.enumerated() {
                    var path = Path()
                    var x = 0.0
                    while x <= size.width {
                        let envelope = sin(x / size.width * .pi)
                        let speed = 0.6 + Double(index) * 0.2
                        let y = size.height * wave.y
                            + sin(x / 90 * wave.frequency + phase * speed) * 18 * envelope
                            + sin(x / 30 + phase * 2 + Double(index)) * 4 * envelope
                        if x == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                        x += 3
                    }
                    context.stroke(path, with: .color(wave.color.opacity(0.45)), lineWidth: 1.5)
                }
            }
        }
    }
}

/// The latest update announcement, in full.
private struct AnnouncementSheet: View {
    let update: HvscUpdate
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Update #\(update.number)\(update.date.map { " · \($0)" } ?? "")")
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
        .frame(width: 900, height: 900)
}
