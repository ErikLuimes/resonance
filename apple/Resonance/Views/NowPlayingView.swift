import AppKit
import SwiftUI
import PhosphorCore

/// Now Playing: the main window's second mode, sliding up over the library
/// like Music's player. A big visualizer (Halo, Particles, Radial or Sound Map, picked
/// at the top and remembered), with the playing tune, its voices and the
/// transport over it (design/visualizers/reference/AppNowPlaying.dc.html).
/// Full screen when the window is.
///
/// Toggled from the player bar (its button or the track title) and View ›
/// Now Playing (⇧⌘F); its close button (top-left) and Esc slide it away.
struct NowPlayingView: View {
    /// False while it's slid away: everything that animates pauses.
    var isShowing = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme
    @Environment(LibraryStore.self) private var library
    @State private var escape = EscapeKey()
    @AppStorage(Pref.nowPlayingVisualizer) private var visual = NowPlayingVisual.particles
    /// Surprise Me, the picker and the playlist status fade out after a
    /// while without the mouse moving, leaving the visualizer and the tune;
    /// full screen, the pointer hides too.
    @State private var showsExtras = true
    @State private var isHoveringExtras = false
    /// Not observed: restarting it on every mouse move redraws nothing.
    @State private var idle = IdleTimer()

    var body: some View {
        ZStack {
            visualizer
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    closeButton
                    surpriseMe
                        .extra(showsExtras, hovering: $isHoveringExtras)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay {
                    picker
                        .extra(showsExtras, hovering: $isHoveringExtras)
                }
                Spacer(minLength: 24)
                HStack(alignment: .bottom, spacing: 24) {
                    trackInfo
                    Spacer(minLength: 24)
                    VoiceChips(isActive: isShowing)
                }
                Transport()
                    .padding(.top, 28)
            }
            .padding(.horizontal, 44)
            // The window keeps the hidden title bar's strip (about 52 pt) as
            // a drag area that swallows clicks, so the top row sits below it.
            .padding(.top, 60)
            .padding(.bottom, 32)
            // From the window's edges, not the title bar's safe area, so
            // nothing moves when the title bar hides or returns.
            .ignoresSafeArea()
        }
        .background { theme.background.color.ignoresSafeArea() }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        // The whole view tracks the mouse, the visualizer's area included.
        .contentShape(.rect)
        .onContinuousHover { phase in
            if case .active = phase { wake() }
        }
        .onChange(of: isHoveringExtras) { wake() }
        .onAppear {
            escape.start(store)
            wake()
        }
        .onDisappear {
            escape.stop()
            idle.task?.cancel()
        }
    }

    private static let dim = Color.white.opacity(0.55)

    /// Seconds without the mouse moving before the extras fade out.
    private static let idleDelay = 3.0

    /// Shows the extras and restarts the idle countdown. They stay while the
    /// mouse rests on one of them.
    private func wake() {
        if !showsExtras {
            withAnimation(.easeOut(duration: 0.2)) { showsExtras = true }
        }
        idle.task?.cancel()
        idle.task = Task {
            try? await Task.sleep(for: .seconds(Self.idleDelay))
            guard !Task.isCancelled, !isHoveringExtras else { return }
            withAnimation(.easeInOut(duration: 0.6)) { showsExtras = false }
            // Full screen, the pointer goes too, until the mouse moves.
            if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }

    // MARK: Visualizer

    /// Only the one shown exists, so the others cost nothing.
    @ViewBuilder
    private var visualizer: some View {
        switch visual {
        case .halo: HaloView(isActive: isShowing)
        case .particles: ParticlesView(isActive: isShowing)
        case .radial: RadialView(isActive: isShowing)
        case .soundMap: SoundMapView(isActive: isShowing)
        }
    }

    /// The system's segmented control, centered above everything.
    private var picker: some View {
        Picker("Visualizer", selection: $visual) {
            ForEach(NowPlayingVisual.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
        .fixedSize()
    }

    // MARK: Tune

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(source)
                .font(.caption.weight(.semibold))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(Self.dim)
            if let track = store.nowPlaying {
                Text(track.title)
                    .font(.system(size: 56, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(track.author)
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                let released = NowPlayingInspector.releasedParts(track.released)
                let line = [released.year, released.by].compactMap(\.self).joined(separator: " · ")
                if !line.isEmpty {
                    Text(line)
                        .foregroundStyle(Self.dim)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    tag(track.sidType)
                    if track.sidModel != 0 {
                        tag(track.chipModel.short)
                            .help(track.chipModel.full)
                    }
                    tag(track.isPal ? "PAL" : "NTSC")
                    playlistStatus(track)
                        .extra(showsExtras, hovering: $isHoveringExtras)
                        .padding(.leading, 8)
                }
                // The button's height whether it shows or not, so nothing
                // moves when it comes or goes.
                .frame(height: 28)
                .padding(.top, 8)
            } else {
                Text("Not Playing")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    /// Which list is playing, and where in My Playlist.
    private var source: String {
        guard let source = store.source else { return String(localized: "Now playing") }
        if source == .myPlaylist, let index = store.currentIndex {
            return String(localized: "Playing from My Playlist · \(index + 1) / \(store.rows.count)")
        }
        return String(localized: "Playing from \(source.name)")
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.1), in: .rect(cornerRadius: 6))
    }

    // MARK: Controls

    /// Keep what's playing: a heart for Favorites, and Add to… for a
    /// playlist.
    private func playlistStatus(_ track: TrackDetails) -> some View {
        HStack(spacing: 10) {
            FavoriteButton(path: track.path)
                .font(.title3)
            AddToButton(files: [track.path])
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(.white.opacity(0.1), in: .capsule)
            ShareButton(path: track.path, subtune: Int(track.currentSong))
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(.white.opacity(0.1), in: .capsule)
        }
    }

    /// Like the library's toolbar button: the dice wiggle on every pick.
    private var surpriseMe: some View {
        Button {
            Task { await library.surpriseMe() }
        } label: {
            Label("Surprise Me", systemImage: "dice")
                .symbolEffect(.wiggle, value: library.surprises)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .help("Play random tunes from all of HVSC")
        .disabled(!store.hasCollection)
    }

    /// Always there, but while idle only its cross shows: the circle behind
    /// it fades with the extras.
    private var closeButton: some View {
        Button { store.isShowingNowPlaying = false } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(.white.opacity(showsExtras ? 0.16 : 0), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("Close Now Playing (Esc)")
        .accessibilityLabel("Close Now Playing")
    }

}

/// Previous, play/pause, next and the progress. Its own view: the elapsed
/// time changes many times a second, and only this part should redraw for
/// it, not the buttons at the top (a redraw mid-click could drop the click).
private struct Transport: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        HStack(spacing: 20) {
            HStack(spacing: 18) {
                Button("Previous", systemImage: "backward.fill") { store.previous() }
                Button { store.playPause() } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .foregroundStyle(.black)
                        .frame(width: 52, height: 52)
                        .background(.white, in: .circle)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(store.isPlaying ? "Pause" : "Play")
                Button("Next", systemImage: "forward.fill") { store.next() }
            }
            .font(.title2)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .disabled(store.rows.isEmpty && !store.queueActive)

            Text(clock(preview ?? store.seekPosition ?? store.elapsed))
                .opacity(store.seeking && preview == nil ? 0.55 : 1)
            progress
            Text(store.duration.map { (store.durationIsEstimate ? "~" : "") + clock($0) } ?? "--:--")
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.7))
    }

    /// The time under the pointer while scrubbing.
    @State private var preview: TimeInterval?

    /// Scrubs like the player bar's, in white.
    private var progress: some View {
        ScrubBar(
            elapsed: store.elapsed,
            duration: store.duration,
            canSeek: store.canSeek,
            isPlaying: store.isPlaying,
            engine: store.engine,
            hasSubtunes: store.hasSubtunes,
            seeking: store.seeking,
            seekPosition: store.seekPosition,
            onDark: true,
            preview: $preview,
            seek: { store.seek(to: $0) }
        )
        .frame(height: 14)
    }

    private func clock(_ t: TimeInterval) -> String {
        Duration.seconds(t).formatted(.time(pattern: .minuteSecond))
    }
}

/// Holds Now Playing's idle countdown.
private final class IdleTimer {
    var task: Task<Void, Never>?
}

private extension View {
    /// One of Now Playing's extras: faded out and unclickable while idle.
    func extra(_ isShown: Bool, hovering: Binding<Bool>) -> some View {
        opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .onHover { hovering.wrappedValue = $0 }
    }
}

nonisolated enum NowPlayingVisual: String, CaseIterable, Identifiable {
    case halo
    case particles
    case radial
    case soundMap

    var id: Self { self }

    var title: String {
        switch self {
        case .halo: String(localized: "Halo")
        case .particles: String(localized: "Particles")
        case .radial: String(localized: "Radial")
        case .soundMap: String(localized: "Sound Map")
        }
    }
}

/// The three voices' waveform and note, redrawn every display frame. Fixed
/// sizes, so changing notes never move anything.
private struct VoiceChips: View {
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme

    var body: some View {
        TimelineView(.animation(minimumInterval: VisualizerFeed.frameInterval, paused: !store.isPlaying || !isActive)) { _ in
            let voices = store.visualizer.latest()?.chips.first?.voices ?? []
            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    chip(i, voice: i < voices.count ? voices[i] : nil)
                }
            }
        }
    }

    private func chip(_ i: Int, voice: VizVoice?) -> some View {
        let sounding = voice.map { $0.gate || $0.envLevel > 0 } ?? false
        let waveform = voice?.waveformName ?? ""
        return HStack {
            Text("V\(i + 1) \(waveform.isEmpty ? "—" : waveform)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 8)
            Text((sounding ? voice?.note : nil) ?? "—")
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundStyle(voice?.gate == true ? theme.voice(i) : .white.opacity(0.35))
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(width: 148, height: 40)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// Esc closes Now Playing. A local monitor, because the overlay has no
/// keyboard focus of its own. It only acts while Now Playing shows, and
/// otherwise lets Esc through: during the slide-out the view (and its
/// monitor) is still around.
final class EscapeKey {
    private var monitor: Any?

    func start(_ store: PlayerStore) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak store] event in
            guard event.keyCode == 53 else { return event }
            let closed = MainActor.assumeIsolated {
                // The keyboard help over it goes first (see AppKeys).
                guard let store, store.isShowingNowPlaying, !store.isShowingKeyHelp else { return false }
                store.isShowingNowPlaying = false
                return true
            }
            return closed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

#Preview {
    NowPlayingView()
        .environment(PlayerStore.preview)
        .environment(LibraryStore(player: PlayerStore.preview))
        .frame(width: 1100, height: 700)
}
