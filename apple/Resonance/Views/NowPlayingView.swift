import AppKit
import SwiftUI
import PhosphorCore

/// Now Playing: the main window's second mode, sliding up over the library
/// like Music's player. A big visualizer (Halo, Particles or Radial, picked
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
        .background { Color.black.ignoresSafeArea() }
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
        }
    }

    /// The system's segmented control, centred above everything.
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

    /// Which list is playing, and where in it.
    private var source: String {
        if store.surpriseActive { return "Now playing · Surprise Me" }
        if store.queueActive { return "Now playing · Queue" }
        if let index = store.currentIndex, store.nowPlaying != nil {
            return "Now playing · Playlist \(index + 1) / \(store.rows.count)"
        }
        return "Now playing"
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.1), in: .rect(cornerRadius: 6))
    }

    // MARK: Controls

    /// Add to Playlist for any tune not in it, a small "In Playlist"
    /// otherwise. Both are always laid out, one hidden, so switching
    /// between them never moves the text above.
    private func playlistStatus(_ track: TrackDetails) -> some View {
        let inPlaylist = store.rows.contains(where: { $0.id == track.path })
        return ZStack(alignment: .leading) {
            Button {
                store.add([URL(filePath: track.path)])
            } label: {
                Label("Add to Playlist", systemImage: "plus")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(.white.opacity(0.1), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help("Add this tune to your playlist")
            .opacity(inPlaylist ? 0 : 1)
            .allowsHitTesting(!inPlaylist)
            .accessibilityHidden(inPlaylist)

            Label("In Playlist", systemImage: "checkmark")
                .font(.callout)
                .foregroundStyle(Self.dim)
                .help("This tune is in your playlist")
                .opacity(inPlaylist ? 1 : 0)
                .accessibilityHidden(!inPlaylist)
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
        .disabled(!library.hasRoot)
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

            Text(clock(store.elapsed))
            progress
            Text(store.duration.map(clock) ?? "--:--")
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.7))
    }

    /// Read-only, like the player bar's: SID tunes can't be scrubbed.
    private var progress: some View {
        Capsule()
            .fill(.white.opacity(0.15))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: proxy.size.width * (store.progress ?? 0))
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue("\(Int((store.progress ?? 0) * 100)) percent")
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

    var id: Self { self }

    var title: String {
        switch self {
        case .halo: "Halo"
        case .particles: "Particles"
        case .radial: "Radial"
        }
    }
}

/// The three voices' waveform and note, redrawn every display frame. Fixed
/// sizes, so changing notes never move anything.
private struct VoiceChips: View {
    var isActive = true

    @Environment(PlayerStore.self) private var store

    var body: some View {
        TimelineView(.animation(paused: !store.isPlaying || !isActive)) { _ in
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
                .foregroundStyle(voice?.gate == true ? VisualizerFeed.voiceColors[i] : .white.opacity(0.35))
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
                guard let store, store.isShowingNowPlaying else { return false }
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
