#if CSDB // Debug builds only until CSDb's admins have had their say.

import SwiftUI
import AppKit

// The C64 scene from CSDb: Scene Pulse, a page of its own.

// MARK: - The page

/// Scene Pulse: what's going on in the scene under a large featured header,
/// then the news, fresh music, CSDb's top rated and what's coming.
struct SceneView: View {
    @Environment(CSDbStore.self) private var csdb
    @State private var width: CGFloat = 900

    private var features: [SceneFeature] {
        SceneFeature.pick(music: csdb.music, events: csdb.events, top: csdb.topMusic, today: .now)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SceneFeatureHeader(features: features, fallbackBackdrop: csdb.music.first?.imageURL)
                ScenePanels(wide: width >= 760)
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 20)
                    .frame(maxWidth: 1200)
                    .frame(maxWidth: .infinity)
            }
        }
        .onGeometryChange(for: CGFloat.self) { min($0.size.width, 1200) - 48 } action: { width = $0 }
    }
}

/// The news, then the cards: side by side when there's room.
private struct ScenePanels: View {
    let wide: Bool

    @Environment(CSDbStore.self) private var csdb
    @State private var showsAllNews = false
    @State private var showsAllMusic = false
    @State private var showsAllTop = false
    @State private var showsAllEvents = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            news
            if csdb.music.isEmpty && csdb.events.isEmpty {
                SceneStatus()
            } else if wide {
                HStack(alignment: .top, spacing: 14) {
                    releases
                    if !csdb.topMusic.isEmpty { topRated }
                    events
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                releases
                if !csdb.topMusic.isEmpty { topRated }
                events
            }
            Text("Data from CSDb, the Commodore 64 Scene Database. Updated hourly.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var releases: some View {
        ScenePanel("Fresh Releases", sub: "C64 Music") {
            VStack(spacing: 0) {
                ForEach(showsAllMusic ? csdb.music : Array(csdb.music.prefix(5))) { ReleaseRow(release: $0) }
                moreLink(csdb.music.count > 5, isOn: $showsAllMusic)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var topRated: some View {
        TopRatedPanel(releases: Array(csdb.topMusic.prefix(showsAllTop ? 25 : 5))) {
            moreLink(csdb.topMusic.count > 5, isOn: $showsAllTop)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var events: some View {
        ScenePanel("Coming Up", sub: "CSDb events") {
            VStack(spacing: 0) {
                ForEach(showsAllEvents ? csdb.events : Array(csdb.events.prefix(5))) { EventRow(event: $0) }
                moreLink(csdb.events.count > 5, isOn: $showsAllEvents)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func moreLink(_ hasMore: Bool, isOn: Binding<Bool>) -> some View {
        if hasMore {
            AccentLink(isOn.wrappedValue ? "Show Fewer" : "Show All") { isOn.wrappedValue.toggle() }
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.top, 8)
        }
    }

    /// The latest few, or all of them, in two columns when there's room.
    @ViewBuilder
    private var news: some View {
        if !csdb.news.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Scene News", sub: "Comings and goings in the scene") {
                    if csdb.news.count > (wide ? 6 : 3) {
                        AccentLink(showsAllNews ? "Show Fewer" : "Show All") { showsAllNews.toggle() }
                    }
                }
                let items = showsAllNews ? csdb.news : Array(csdb.news.prefix(wide ? 6 : 3))
                let half = wide ? (items.count + 1) / 2 : items.count
                HStack(alignment: .top, spacing: 24) {
                    newsColumn(items.prefix(half))
                    if wide {
                        NewsDivider()
                        newsColumn(items.dropFirst(half))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(18)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .modifier(CardBackground())
            }
        }
    }

    private func newsColumn(_ items: ArraySlice<CSDbNewsItem>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(items) { item in
                NewsLink(item: item, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text)
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let date = item.date {
                            Text(date, format: .dateTime.day().month(.wide))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Between the news columns: a hairline fading out at both ends.
private struct NewsDivider: View {
    var body: some View {
        LinearGradient(colors: [.clear, Color(nsColor: .separatorColor), Color(nsColor: .separatorColor), .clear],
                       startPoint: .top, endPoint: .bottom)
            .frame(width: 1)
            .accessibilityHidden(true)
    }
}

// MARK: - The featured header

/// The top of Scene Pulse, the width of the pane: one thing at large, on its
/// own picture blurred and darkened, fading into the page. It moves on by
/// itself, but never under the pointer, nor with Reduce Motion on.
struct SceneFeatureHeader: View {
    let features: [SceneFeature]
    /// While there's nothing to feature yet.
    let fallbackBackdrop: URL?

    @Environment(CSDbStore.self) private var csdb
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.sectionIsCovered) private var isCovered
    @State private var shown = 0
    @State private var isHovered = false
    @State private var width: CGFloat = 900

    private static var height: CGFloat { 270 }

    private var index: Int { min(shown, max(features.count - 1, 0)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                if features.isEmpty {
                    SceneBackdrop(url: fallbackBackdrop, seed: "Scene Pulse")
                }
                ForEach(Array(features.enumerated()), id: \.element.id) { position, feature in
                    SceneFeatureSlide(feature: feature, showsCover: width >= 560)
                        .opacity(position == index ? 1 : 0)
                        .allowsHitTesting(position == index)
                        .accessibilityHidden(position != index)
                }
            }
            topBar
            pager
        }
        .frame(height: Self.height)
        .frame(minWidth: 0, maxWidth: .infinity)
        .clipped()
        // Clipping only clips what's drawn: without this the backdrop's picture,
        // much larger than the header, keeps it hovered from far below.
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// The page's name and links, as a page's title.
    private var topBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Scene Pulse")
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
            AccentLink("Open CSDb") { openURL(URL(string: "https://csdb.dk")!) }
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            AccentLink("Refresh") { Task { await csdb.refresh(force: true) } }
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .disabled(csdb.state == .loading)
            if csdb.state == .loading {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 8)
            CSDbLiveStatus()
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .frame(minWidth: 0, maxWidth: .infinity)
        .tint(Color(red: 0.61, green: 0.77, blue: 1))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var pager: some View {
        if !features.isEmpty {
            SceneFeaturePager(count: features.count, label: features[index].typeName(today: .now), shown: $shown,
                              isPaused: isHovered || activeState != .key || isCovered, moves: !reduceMotion)
                .padding(.trailing, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .environment(\.colorScheme, .dark)
        }
    }
}

/// What's featured, and a line per item: the current one long, filling up
/// until the next. In a view of its own, so only this redraws as it fills.
private struct SceneFeaturePager: View {
    let count: Int
    let label: String
    @Binding var shown: Int
    let isPaused: Bool
    let moves: Bool

    @State private var clock = SceneFeatureClock()

    private var index: Int { min(shown, max(count - 1, 0)) }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            if count > 1 {
                HStack(spacing: 2) {
                    ForEach(0..<count, id: \.self) { position in
                        Button {
                            show(position)
                        } label: {
                            line(position)
                                .padding(.horizontal, 2)
                                .padding(.vertical, 6)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Featured \(position + 1) of \(count)")
                    }
                }
            }
        }
        // Restarted as the pause changes: a task keeps the values it began with.
        .task(id: "\(count) \(moves) \(isPaused)") {
            guard count > 1, moves, !isPaused else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(SceneFeatureClock.tick))
                guard !Task.isCancelled else { return }
                if clock.advance(by: SceneFeatureClock.tick, isPaused: false) {
                    show((index + 1) % count)
                }
            }
        }
    }

    private func line(_ position: Int) -> some View {
        let isCurrent = position == index
        return Capsule()
            .fill(.white.opacity(0.3))
            .overlay(alignment: .leading) {
                if isCurrent {
                    Capsule()
                        .fill(.white)
                        .frame(width: moves ? max(28 * clock.progress, 5) : 28)
                }
            }
            .clipShape(.capsule)
            .frame(width: isCurrent ? 28 : 7, height: 5)
    }

    private func show(_ position: Int) {
        clock.reset()
        guard moves else {
            shown = position
            return
        }
        withAnimation(.easeInOut(duration: 0.45)) { shown = position }
    }
}

/// A picture as a backdrop, or a colour from the name until it loads or if
/// there's none.
private struct SceneBackdrop: View {
    let url: URL?
    let seed: String

    var body: some View {
        SceneBackdropLook(seed: seed) {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    }
                }
            }
        }
    }
}

/// How a backdrop looks: blurred, darkened and fading into the page. The
/// picture hangs on a colour that sets the size, as a picture filling its
/// frame would otherwise make the frame as big as the picture.
struct SceneBackdropLook<Picture: View>: View {
    let seed: String
    @ViewBuilder let picture: Picture

    @Environment(\.colorScheme) private var colorScheme

    /// Text stays light on the backdrop, so a lit page only takes the very end.
    private var fadeStart: CGFloat { colorScheme == .dark ? 0.35 : 0.9 }

    var body: some View {
        let hue = Double(seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        Color(hue: hue, saturation: 0.45, brightness: 0.45)
            .overlay { picture }
            .blur(radius: 34)
            .saturation(1.35)
            .scaleEffect(1.25)
            .overlay(Color.black.opacity(0.42))
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: fadeStart),
                                       .init(color: Color(nsColor: .windowBackgroundColor), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// One featured thing, its text light on its backdrop in either appearance.
private struct SceneFeatureSlide: View {
    let feature: SceneFeature
    let showsCover: Bool

    @Environment(CSDbStore.self) private var csdb
    @Environment(LibraryStore.self) private var library
    @Environment(\.openURL) private var openURL

    private var picture: URL? {
        switch feature {
        case .release(let release): release.imageURL
        case .event(let event): event.imageURL
        case .top(let release): csdb.releaseFiles[release.id]?.cover
        }
    }

    private var title: String {
        switch feature {
        case .release(let release): release.displayTitle
        case .event(let event): event.title
        case .top(let release): release.displayTitle
        }
    }

    /// Its type is beside the paging lines; this says what's particular.
    private var eyebrow: String {
        switch feature {
        case .release(let release):
            return release.date.formatted(.dateTime.day().month(.abbreviated).year()).uppercased()
        case .event(let event):
            return event.kind.uppercased()
        case .top(let release):
            let rating = release.rating.formatted(.number.precision(.fractionLength(2)))
            return "\(rating) from \(release.votes.formatted()) votes".uppercased()
        }
    }

    private var line: String {
        switch feature {
        case .release(let release):
            return ([release.byline] + [release.sidFormat].compactMap { $0 }).joined(separator: " · ")
        case .event(let event):
            return ([event.tagline.map { "“\($0)”" }, event.when].compactMap { $0 }).joined(separator: " · ")
        case .top(let release):
            let who = csdb.releaseFiles[release.id]?.composerHandle
            return ([who, release.byline, release.sidFormat].compactMap { $0 }).joined(separator: " · ")
        }
    }

    private var player: CSDbPlayer? {
        switch feature {
        case .release(let release):
            CSDbPlayer(id: release.id, title: release.displayTitle, author: release.byline, url: release.url,
                       csdb: csdb, library: library, openURL: openURL)
        case .top(let release):
            CSDbPlayer(id: release.id, title: release.displayTitle, author: release.byline, url: release.url,
                       csdb: csdb, library: library, openURL: openURL)
        case .event:
            nil
        }
    }

    private var pageURL: URL {
        switch feature {
        case .release(let release): release.url
        case .event(let event): event.url
        case .top(let release): release.url
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SceneBackdrop(url: picture, seed: title)
            HStack(alignment: .bottom, spacing: 20) {
                if showsCover, let picture {
                    SceneFeatureCover(url: picture)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(eyebrow)
                        .font(.caption.weight(.semibold))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                    Text(title)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(player?.message ?? line)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    actions
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
            .padding(.trailing, 60)
            .environment(\.colorScheme, .dark)
        }
        .onAppear(perform: loadDetails)
    }

    /// The chart's best has no picture until CSDb's asked.
    private func loadDetails() {
        if case .top(let release) = feature {
            Task { await csdb.loadChartDetails([release]) }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if let player, player.state != .unavailable {
                let isPlaying = player.isCurrent && library.player.isPlaying
                Button(action: player.activateRow) {
                    if player.state == .loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(player.state == .loading)
            }
            AccentLink("Open on CSDb") { openURL(pageURL) }
                .font(.callout.weight(.semibold))
                .tint(Color(red: 0.61, green: 0.77, blue: 1))
        }
    }
}

/// The picture itself, sharp: a C64's pixels aren't to be smoothed.
private struct SceneFeatureCover: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .interpolation(.none)
                    .scaledToFill()
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: 170, height: 120)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.18))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Parts

/// "Live from CSDb · updated 19:28" with a pulsing green dot, in the headers
/// of Scene Pulse and the Scene page. It keeps the feeds current while it
/// shows, so "live" holds: it checks every few minutes, and the store only
/// goes to CSDb once its hour is up. When the last answer is too old, it
/// says so, with a still grey dot.
struct CSDbLiveStatus: View {
    @Environment(CSDbStore.self) private var csdb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sectionIsCovered) private var isCovered

    /// Two feed lifetimes: one missed check is no reason to stop saying live.
    private var isLive: Bool {
        guard !csdb.isFailed, let updated = csdb.updated else { return false }
        return Date().timeIntervalSince(updated) < 2 * 3600
    }

    var body: some View {
        HStack(spacing: 6) {
            dot
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .task(id: isCovered) {
            while !Task.isCancelled, !isCovered {
                await csdb.refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private var text: String {
        if isLive, let updated = csdb.updated {
            return "Live from CSDb · " + SceneFormat.updated(updated)
        }
        if let updated = csdb.updated {
            return "CSDb offline · " + SceneFormat.updated(updated)
        }
        return "Connecting to CSDb"
    }

    /// In a fixed frame, so the pulse never moves the text beside it.
    private var dot: some View {
        let color: Color = isLive ? .green : .secondary
        return ZStack {
            if isLive && !reduceMotion {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .phaseAnimator([false, true]) { view, spreading in
                        view
                            .scaleEffect(spreading ? 2.2 : 1)
                            .opacity(spreading ? 0 : 0.5)
                    } animation: { spreading in
                        spreading ? .easeOut(duration: 1.6) : nil
                    }
            } else if isLive {
                Circle()
                    .fill(color.opacity(0.3))
                    .frame(width: 15, height: 15)
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

/// A news item: opens the scener or group on CSDb, and after a moment's
/// hover says when it happened and who they are.
private struct NewsLink<Label: View>: View {
    let item: CSDbNewsItem
    /// Where the popover points from: away from the mouse's path.
    let arrowEdge: Edge
    @ViewBuilder let label: Label

    @Environment(CSDbStore.self) private var csdb
    @Environment(\.openURL) private var openURL
    @State private var hovering = false
    @State private var showsDetail = false
    @Environment(\.sectionIsCovered) private var isCovered

    var body: some View {
        Button {
            showsDetail = false
            if let url = item.url { openURL(url) }
        } label: {
            label
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .task(id: hovering && !isCovered) {
            guard hovering, !isCovered else {
                showsDetail = false
                return
            }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            showsDetail = true
            await csdb.loadNewsDetail(item)
        }
        .background {
            HoverPopover(isPresented: showsDetail && !isCovered, edge: arrowEdge) {
                NewsDetail(item: item)
                    .environment(csdb)
            }
        }
    }
}

/// A popover that only the hover opens and closes. SwiftUI's `.popover` is
/// transient: the next click anywhere closes it and is used up doing so, so
/// the row under the mouse never got its click.
private struct HoverPopover<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let edge: Edge
    @ViewBuilder let content: () -> Content

    final class Coordinator {
        var popover: NSPopover?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        guard isPresented, view.window != nil else {
            coordinator.popover?.close()
            coordinator.popover = nil
            return
        }
        if let hosting = coordinator.popover?.contentViewController as? NSHostingController<Content> {
            hosting.rootView = content()
            return
        }
        let hosting = NSHostingController(rootView: content())
        hosting.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = hosting
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: rectEdge)
        coordinator.popover = popover
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.popover?.close()
        coordinator.popover = nil
    }

    private var rectEdge: NSRectEdge {
        switch edge {
        case .top: .maxY
        case .bottom: .minY
        case .leading: .minX
        case .trailing: .maxX
        }
    }
}

private struct NewsDetail: View {
    let item: CSDbNewsItem
    @Environment(CSDbStore.self) private var csdb

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let date = item.date {
                Text(date, format: .dateTime.day().month(.wide).year())
                    .foregroundStyle(.secondary)
            }
            if let url = item.url, let detail = csdb.newsDetails[url] {
                Divider()
                Text(detail.name)
                    .fontWeight(.semibold)
                ForEach(detail.lines, id: \.self) { line in
                    Text(line)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Click to open on CSDb")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .font(.callout)
        .padding(12)
        .frame(width: 260, alignment: .leading)
    }
}

/// A click on a release: plays it, downloading its SID first if need be.
/// Once CSDb turns out to have nothing to play, opens its page instead.
struct CSDbPlayer {
    let id: Int
    let title: String
    let author: String
    let url: URL
    let csdb: CSDbStore
    let library: LibraryStore
    let openURL: OpenURLAction

    var state: CSDbPlayState? { csdb.playStates[id] }

    /// Where it would play from, once known: nothing to download either way.
    var tag: String? {
        if csdb.hvscTune(ofRelease: id, library: library) != nil { return "In HVSC" }
        return csdb.downloadedIDs.contains(id) ? "Downloaded" : nil
    }

    /// What the row says instead of its byline, while it has something to say.
    var message: String? {
        switch state {
        case .loading: "Downloading…"
        case .unavailable: "No SID on CSDb. Click to open its page"
        case .failed(let reason): "Couldn't download: \(reason)"
        case nil: nil
        }
    }

    func activate() {
        if state == .unavailable {
            openURL(url)
        } else {
            Task { await csdb.play(release: id, title: title, author: author, on: library) }
        }
    }

    /// Whether this release is what's loaded in the player, playing or paused:
    /// its download, or the collection's copy.
    var isCurrent: Bool {
        guard let path = library.player.nowPlaying?.path else { return false }
        return path == CSDbStore.sidFolder.appending(path: "\(id).sid").path
            || path == csdb.hvscTune(ofRelease: id, library: library)?.path
    }

    /// A click on the row: pauses or resumes it if it's the one in the player.
    func activateRow() {
        if isCurrent {
            library.player.playPause()
        } else {
            activate()
        }
    }
}

/// What a release row shows over its cover or instead of its place: a spinner
/// while it downloads; on the release that's playing, its voices, or pause
/// under the pointer; on another, play under the pointer. Nil when there's
/// nothing to add.
struct CSDbPlaySlot: View {
    let player: CSDbPlayer
    let isHovered: Bool
    /// Over a picture: white, on a dimmed cover.
    var overCover = false

    /// Whether anything shows here, in place of a place number.
    static func isEmpty(_ player: CSDbPlayer, isHovered: Bool) -> Bool {
        player.state != .loading && !player.isCurrent && !(isHovered && player.state != .unavailable)
    }

    private var store: PlayerStore { player.library.player }

    private var style: AnyShapeStyle {
        overCover ? AnyShapeStyle(.white) : AnyShapeStyle(.tint)
    }

    var body: some View {
        if !Self.isEmpty(player, isHovered: isHovered) {
            ZStack {
                if overCover {
                    Color.black.opacity(0.5)
                }
                if player.state == .loading {
                    ProgressView()
                        .controlSize(.mini)
                } else if player.isCurrent && !isHovered {
                    VoiceBars(feed: store.visualizer, isActive: store.isPlaying)
                        .foregroundStyle(style)
                        .accessibilityLabel(store.isPlaying ? "Playing" : "Paused")
                } else {
                    Image(systemName: player.isCurrent && store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(style)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

extension View {
    /// A release row's background: the playing row's accent wash, as in a song
    /// table, or a hint of a click to come.
    func csdbRowBackground(isCurrent: Bool, isHovered: Bool) -> some View {
        background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 8).fill(.tint.opacity(0.16))
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8).fill(.fill.tertiary)
            }
        }
    }
}

/// A music release: cover, title, group, format and date. A click plays it.
private struct ReleaseRow: View {
    let release: CSDbRelease
    /// Room for the date in a column of its own.
    var showsDate = false
    @Environment(CSDbStore.self) private var csdb
    @Environment(LibraryStore.self) private var library
    @Environment(\.openURL) private var openURL
    @State private var hovering = false

    private var player: CSDbPlayer {
        CSDbPlayer(id: release.id, title: release.displayTitle, author: release.byline, url: release.url,
                   csdb: csdb, library: library, openURL: openURL)
    }

    private var byline: String {
        var parts = [release.byline]
        if !showsDate { parts.append(release.date.formatted(.dateTime.day().month(.abbreviated))) }
        if let tag = player.tag { parts.append(tag) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: player.activateRow) {
            HStack(spacing: 10) {
                SceneCover(url: release.imageURL, seed: release.title, size: 34, radius: 7)
                    .overlay {
                        CSDbPlaySlot(player: player, isHovered: hovering, overCover: true)
                            .clipShape(.rect(cornerRadius: 7))
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(release.displayTitle)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(player.message ?? byline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let format = release.sidFormat {
                    Text(format)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.purple.opacity(0.25), in: .rect(cornerRadius: 5))
                }
                if showsDate {
                    Text(release.date, format: .dateTime.day().month(.abbreviated))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .contentShape(.rect)
            .csdbRowBackground(isCurrent: player.isCurrent, isHovered: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open on CSDb") { openURL(release.url) }
        }
    }
}

/// A card with its title above it, like the sections of the HVSC Home.
private struct ScenePanel<Content: View>: View {
    let title: String
    let sub: String
    @ViewBuilder let content: Content

    init(_ title: String, sub: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.sub = sub
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title, sub: sub)
            content
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .modifier(CardBackground())
        }
    }
}

/// CSDb's chart. With the top tied at one rating, as it mostly is, votes are
/// what tell the releases apart, so they get the bar.
struct TopRatedPanel<Footer: View>: View {
    let releases: [CSDbTopRelease]
    @ViewBuilder let footer: Footer
    @Environment(CSDbStore.self) private var csdb

    var body: some View {
        let common = CSDbTopList.commonRating(releases)
        let mostVotes = releases.map(\.votes).max() ?? 0
        ScenePanel("Top Rated", sub: common.map { "all rated \($0.formatted(.number.precision(.fractionLength(2))))" } ?? "rating, votes") {
            VStack(spacing: 0) {
                ForEach(releases) { release in
                    TopRow(release: release, mostVotes: mostVotes, showsRating: common == nil)
                }
                footer
            }
        }
        .task(id: releases.map(\.id)) { await csdb.loadChartDetails(releases) }
    }
}

/// A release on CSDb's chart. A click plays it.
struct TopRow: View {
    let release: CSDbTopRelease
    let mostVotes: Int
    let showsRating: Bool
    @Environment(CSDbStore.self) private var csdb
    @Environment(LibraryStore.self) private var library
    @Environment(\.openURL) private var openURL
    @State private var hovering = false

    private var player: CSDbPlayer {
        CSDbPlayer(id: release.id, title: release.displayTitle, author: release.byline, url: release.url,
                   csdb: csdb, library: library, openURL: openURL)
    }

    private var details: CSDbReleaseFiles? { csdb.releaseFiles[release.id] }

    /// "Mibri · 3rd, Mixed Music at Revision 2025"; its groups until CSDb says.
    private var line: String {
        ([details?.composerHandle ?? release.byline] + [details?.story].compactMap { $0 }).joined(separator: " · ")
    }

    private var votes: String {
        let count = release.votes == 1 ? "1 vote" : "\(release.votes.formatted()) votes"
        return showsRating ? "\(release.rating.formatted(.number.precision(.fractionLength(2)))), \(count)" : count
    }

    var body: some View {
        Button(action: player.activateRow) {
            HStack(spacing: 10) {
                SceneCover(url: details?.cover, seed: release.title, size: 34, radius: 7)
                    .overlay {
                        CSDbPlaySlot(player: player, isHovered: hovering, overCover: true)
                            .clipShape(.rect(cornerRadius: 7))
                    }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(release.displayTitle)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        if let format = release.sidFormat {
                            Text(format)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.purple.opacity(0.25), in: .rect(cornerRadius: 5))
                        }
                        Spacer(minLength: 6)
                        Text(votes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Text(player.message ?? line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    VoteBar(share: mostVotes > 0 ? Double(release.votes) / Double(mostVotes) : 0)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .contentShape(.rect)
            .csdbRowBackground(isCurrent: player.isCurrent, isHovered: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open on CSDb") { openURL(release.url) }
        }
    }
}

/// A release's votes against the most on the chart.
private struct VoteBar: View {
    let share: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.tertiary)
                Capsule().fill(.tint).frame(width: max(proxy.size.width * share, 4))
            }
        }
        .frame(height: 4)
        .padding(.top, 2)
        .accessibilityHidden(true)
    }
}

private struct EventRow: View {
    let event: CSDbEvent
    @Environment(\.openURL) private var openURL
    @State private var hovering = false

    var body: some View {
        Button {
            openURL(event.url)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text([event.when, event.kind].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .contentShape(.rect)
            .background(hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open on CSDb")
    }
}

/// CSDb's screenshot when it loads, a gradient from the title until then.
struct SceneCover: View {
    let url: URL?
    let seed: String
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            gradient
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().interpolation(.none).scaledToFill()
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: radius))
        .accessibilityHidden(true)
    }

    private var gradient: some View {
        let hue = Double(seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.6, brightness: 0.8),
                     Color(hue: (hue + 0.2).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.55)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

/// While the feeds load for the first time, or when they can't.
private struct SceneStatus: View {
    @Environment(CSDbStore.self) private var csdb

    var body: some View {
        HStack(spacing: 10) {
            switch csdb.state {
            case .failed(let message):
                Text("CSDb isn't reachable: \(message)")
                    .foregroundStyle(.secondary)
                AccentLink("Try Again") { Task { await csdb.refresh(force: true) } }
            default:
                ProgressView().controlSize(.small)
                Text("Loading the scene…")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout)
        .padding(18)
        .modifier(CardBackground())
    }
}

enum SceneFormat {
    static func updated(_ date: Date) -> String {
        "updated " + date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Downloads

/// The SIDs played from CSDb, newest first. They stay on disk so Play doesn't
/// download them again; removing one here deletes its file.
struct CSDbDownloadsView: View {
    /// The list's own filter.
    @State private var filter = ""

    @Environment(CSDbStore.self) private var csdb
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(LibraryStore.self) private var library
    @State private var rows: [LibraryRow]?
    /// Tunes waiting on the question of whether to take them out of the
    /// lists they're in.
    @State private var removing: Set<String> = []
    @State private var usedIn: [String] = []

    private var query: String { filter.trimmingCharacters(in: .whitespaces) }

    private var shown: [LibraryRow] {
        guard let rows else { return [] }
        guard !query.isEmpty else { return rows }
        return rows.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.author.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        // Reads the files' headers again whenever one comes or goes.
        .task(id: csdb.downloadedIDs) {
            rows = await playlists.tunes(from: csdb.downloadedFiles())
        }
        .confirmationDialog(dialogTitle, isPresented: Binding(
            get: { !removing.isEmpty },
            set: { if !$0 { removing = [] } }
        ), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { confirmRemoval() }
            Button("Cancel", role: .cancel) { removing = [] }
        } message: {
            Text("It's also in \(usedIn.formatted()), and will be taken out of there too.")
        }
    }

    private var dialogTitle: String {
        removing.count == 1 ? "Remove This Download?" : "Remove \(removing.count) Downloads?"
    }

    @ViewBuilder
    private var content: some View {
        if let rows {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("No Downloads Yet", systemImage: "arrow.down.circle")
                } description: {
                    Text("Press Play on a release in Scene Pulse. Tunes that aren't in your HVSC collection are kept here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LibraryTable(rows: shown, source: .csdbDownloads, onRemove: remove,
                             removeTitle: "Remove Download", removesOnDeleteKey: true,
                             webLink: { path in CSDbStore.releaseURL(ofDownload: path).map { ("Open on CSDb", $0) } })
                    .overlay {
                        if !query.isEmpty && shown.isEmpty {
                            ContentUnavailableView.search(text: query)
                        }
                    }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 76, height: 76)
                .background(
                    LinearGradient(
                        colors: [Color(red: 63 / 255, green: 208 / 255, blue: 232 / 255),
                                 Color(red: 0.25, green: 0.45, blue: 0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: .rect(cornerRadius: 17)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(PlaybackSource.csdbDownloads.name)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if !(rows ?? []).isEmpty {
                ListFilterField(text: $filter)
            }
            Button {
                library.play(rows ?? [], from: .csdbDownloads)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled((rows ?? []).isEmpty)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var subtitle: String {
        guard let count = rows?.count else { return "…" }
        return (count == 1 ? "1 tune" : "\(count.formatted()) tunes") + " from CSDb"
    }

    /// Straight away, unless a playlist would lose the tune too.
    private func remove(_ ids: Set<LibraryRow.ID>) {
        let lists = playlists.lists(holding: ids)
        if lists.isEmpty {
            csdb.removeDownloads(ids)
        } else {
            usedIn = lists
            removing = ids
        }
    }

    private func confirmRemoval() {
        let ids = removing
        removing = []
        Task {
            await playlists.takeOut(ids)
            csdb.removeDownloads(ids)
        }
    }
}

#endif
