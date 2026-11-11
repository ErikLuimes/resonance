import MetalKit
import SwiftUI
import PhosphorCore

/// Notes: the tune as sheet music lying flat and running into the distance,
/// a staff per voice. The notes still to come are dark beads, each with a
/// stem as long as it lasts; a ball per voice hops from note to note,
/// landing on each exactly as it starts and lighting it in the voice's
/// color, and the played notes slide away toward you and out of focus.
///
/// It needs the notes ahead of time, so it uses the tracker's rebuild of
/// the tune (core/src/tracker.rs: the whole tune run once, away from the
/// player), and places it by the feed's heard time, as the Tracker tab
/// does. Until that's ready, the staves are empty. `NotesRenderer` draws it.
///
/// Shows the first chip, like the Halo.
struct NotesView: View {
    /// False pauses it, e.g. while Now Playing is slid away.
    var isActive = true

    @Environment(PlayerStore.self) private var store
    @Environment(\.voiceTheme) private var theme
    @State private var track: NoteTrack?

    private struct Tune: Hashable {
        let path: String
        let song: Int
    }

    private var tune: Tune? {
        store.nowPlaying.map { Tune(path: $0.path, song: Int($0.currentSong)) }
    }

    var body: some View {
        NotesMetalView(feed: store.visualizer, theme: theme, track: track, isActive: isActive)
            .task(id: tune) { await load() }
            .accessibilityElement()
            .accessibilityLabel("Notes visualizer")
    }

    private func load() async {
        track = nil
        guard let tune else { return }
        // Its known length, else the longest a tune with none usually gets.
        let secs = min((store.duration ?? 300) + 2, 900)
        let song = try? await store.core.trackerSong(path: tune.path, subtune: UInt16(clamping: tune.song), secs: secs, chip: 0)
        guard !Task.isCancelled, let song else { return }
        track = NoteTrack(song)
    }
}

nonisolated extension NoteTrack {
    /// The notes of a tracker rebuild: each starts on its row and lasts
    /// until its voice's next note or note-off.
    init(_ song: TrackerSong) {
        var voices = [[Note]](repeating: [], count: 3)
        var open = [Int?](repeating: nil, count: 3)
        func seconds(_ frame: UInt32) -> Double { Double(frame) / max(song.frameRate, 1) }
        for row in song.rows {
            let time = seconds(row.frame)
            for (voice, cell) in row.voices.prefix(3).enumerated() {
                let midi = cell.note.flatMap(Self.midi)
                if midi != nil || cell.off, let index = open[voice] {
                    voices[voice][index].end = time
                    open[voice] = nil
                }
                if let midi {
                    open[voice] = voices[voice].count
                    voices[voice].append(Note(start: time, end: time, midi: midi))
                }
            }
        }
        // Whatever still sounds at the end lasts one more row.
        let end = seconds(song.rows.last?.frame ?? 0) + Double(song.framesPerRow) / max(song.frameRate, 1)
        for voice in 0..<3 {
            if let index = open[voice] { voices[voice][index].end = end }
        }
        self.init(voices: voices)
    }

    /// A tracker note name ("C-4", "F#3") as a MIDI note.
    static func midi(_ name: String) -> Float? {
        let names = ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"]
        guard let step = names.firstIndex(of: String(name.prefix(2))), let octave = Int(name.dropFirst(2)) else { return nil }
        return Float((octave + 1) * 12 + step)
    }
}

private struct NotesMetalView: NSViewRepresentable {
    let feed: VisualizerFeed
    let theme: VoiceTheme
    let track: NoteTrack?
    let isActive: Bool

    func makeCoordinator() -> NotesDisplay {
        NotesDisplay()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = PassThroughMetalView(frame: .zero, device: context.coordinator.renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.preferredFramesPerSecond = VisualizerFeed.framesPerSecond
        view.delegate = context.coordinator
        update(view, context.coordinator)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        update(view, context.coordinator)
    }

    private func update(_ view: MTKView, _ display: NotesDisplay) {
        display.feed = feed
        display.renderer.voiceColors = theme.voices.map { SIMD3(Float($0.red), Float($0.green), Float($0.blue)) }
        if display.renderer.track != track { display.renderer.track = track }
        view.isPaused = !isActive
    }
}

/// An MTKView that never takes the mouse: as an AppKit view it would
/// otherwise catch the clicks meant for Now Playing's buttons drawn over it.
final class PassThroughMetalView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Draws the notes once per display frame, at the time being heard.
private final class NotesDisplay: NSObject, MTKViewDelegate {
    let renderer = NotesRenderer()
    var feed: VisualizerFeed?
    private var playhead = SmoothPlayhead()

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let commands = renderer.commandQueue?.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        let time = playhead.update(heard: feed?.heardSecs, now: now)
        let scale = Float(view.window?.backingScaleFactor ?? 2)
        renderer.encode(into: drawable.texture, commands: commands, time: time, clock: now, scale: scale)
        commands.present(drawable)
        commands.commit()
    }
}

#Preview {
    NotesView()
        .environment(PlayerStore.preview)
        .frame(width: 640, height: 400)
        .background(.black)
}
