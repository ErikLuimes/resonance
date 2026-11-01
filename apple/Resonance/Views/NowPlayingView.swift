import AppKit
import SwiftUI
import PhosphorCore

/// Now Playing: the main window's second mode, sliding up over the library
/// like Music's player. The Halo, with the playing tune, its voices and the
/// transport over it (design/visualizers/reference/AppNowPlaying.dc.html,
/// Halo only). Full screen when the window is.
///
/// Toggled from the player bar (its button or the track title) and View ›
/// Now Playing (⇧⌘F); its close button (top-left) and Esc slide it away.
struct NowPlayingView: View {
    /// False while it's slid away: everything that animates pauses.
    var isShowing = true

    @Environment(PlayerStore.self) private var store
    @State private var escape = EscapeKey()

    var body: some View {
        ZStack {
            HaloView(isActive: isShowing)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                closeButton
                Spacer(minLength: 24)
                HStack(alignment: .bottom, spacing: 24) {
                    trackInfo
                    Spacer(minLength: 24)
                    VoiceChips(isActive: isShowing)
                }
                transport
                    .padding(.top, 28)
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 32)
            // From the window's edges, not the title bar's safe area, so
            // nothing moves when the title bar hides or returns.
            .ignoresSafeArea()
        }
        .background { Color.black.ignoresSafeArea() }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear { escape.start(store) }
        .onDisappear { escape.stop() }
    }

    private static let dim = Color.white.opacity(0.55)

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
                }
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

    private var transport: some View {
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

    private var closeButton: some View {
        Button { store.isShowingNowPlaying = false } label: {
            Image(systemName: "xmark")
                .font(.title3)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.1), in: .circle)
        }
        .buttonStyle(.plain)
        .help("Close Now Playing (Esc)")
        .accessibilityLabel("Close Now Playing")
    }

    private func clock(_ t: TimeInterval) -> String {
        Duration.seconds(t).formatted(.time(pattern: .minuteSecond))
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
/// keyboard focus of its own. Now Playing stays mounted while closed, so
/// the monitor only acts while it shows, and otherwise lets Esc through.
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
        .frame(width: 1100, height: 700)
}
