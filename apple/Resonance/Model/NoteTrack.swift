import Foundation
import simd

/// A tune's notes, voice by voice, for the Notes visualizer: when each one
/// starts and ends and where it sits on its voice's staff. Known for the
/// whole tune ahead of time (it's made from the tracker's rebuild of the
/// tune, see `NotesView`), so the visualizer can show what's coming and
/// work out where each voice's ball is at any moment with no state: a seek
/// or a restart needs nothing reset.
nonisolated struct NoteTrack: Equatable {
    struct Note: Equatable {
        /// Seconds into the subtune.
        var start: Double
        var end: Double
        var midi: Float
    }

    /// Three voices' notes, each in order of `start`.
    private(set) var voices: [[Note]]
    /// The pitch each voice's staff runs from and to, in semitones.
    private(set) var ranges: [ClosedRange<Float>]

    init(voices: [[Note]]) {
        let three = (0..<3).map { $0 < voices.count ? voices[$0].sorted { $0.start < $1.start } : [] }
        self.voices = three
        ranges = three.map(Self.range)
    }

    /// The staff's range: the voice's lowest to highest note, leaving out
    /// a stray one or two (2% at each end), and at least an octave so a voice
    /// on two notes doesn't leap from edge to edge.
    private static func range(of notes: [Note]) -> ClosedRange<Float> {
        guard !notes.isEmpty else { return 48...60 }
        let pitches = notes.map(\.midi).sorted()
        let cut = pitches.count / 50
        var low = pitches[cut], high = pitches[pitches.count - 1 - cut]
        if high - low < 12 {
            let middle = (low + high) / 2
            low = middle - 6
            high = middle + 6
        }
        return low...high
    }

    /// Where `midi` sits across `voice`'s staff: 0 on its lowest line, 1 on
    /// its highest. Strays beyond the range stay just outside it.
    func place(_ midi: Float, voice: Int) -> Float {
        let range = ranges[voice]
        let u = (midi - range.lowerBound) / (range.upperBound - range.lowerBound)
        return min(1.12, max(-0.12, u))
    }

    /// The index of the last note of `voice` that has started by `time`.
    func current(voice: Int, at time: Double) -> Int? {
        let notes = voices[voice]
        var low = 0, high = notes.count
        while low < high {
            let middle = (low + high) / 2
            if notes[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? low - 1 : nil
    }

    /// The notes of `voice` that are at least partly within `window`.
    func notes(voice: Int, in window: ClosedRange<Double>) -> ArraySlice<Note> {
        let notes = voices[voice]
        var first = current(voice: voice, at: window.lowerBound) ?? 0
        // An earlier note can still be sounding; one that has ended isn't in it.
        while first > 0, notes[first - 1].end > window.lowerBound { first -= 1 }
        if first < notes.count, notes[first].end < window.lowerBound { first += 1 }
        var last = first
        while last < notes.count, notes[last].start <= window.upperBound { last += 1 }
        return notes[first..<last]
    }

    // MARK: The ball

    /// The longest a hop takes, in seconds: with more time than this
    /// between two notes, the ball waits on the first one.
    static let longestHop = 0.9
    /// A hop's height is a real throw's: gravity × time² / 8, in staff
    /// widths, so quick runs skip low and slow notes arc high.
    static let gravity: Float = 18
    static let highestHop: Float = 0.9
    static let lowestHop: Float = 0.08

    struct Ball: Equatable {
        /// Across the staff, as `place` gives it.
        var place: Float
        /// Above the staff, in staff widths; 0 on a note.
        var height: Float
        /// Seconds since it last landed on a note; nil before the first.
        var sinceLanding: Double?
    }

    /// Where `voice`'s ball is at `time`: on the note that last started, or
    /// in the air on its way to land on the next one exactly as it starts.
    /// Nil for a voice with no notes.
    func ball(voice: Int, at time: Double) -> Ball? {
        let notes = voices[voice]
        guard !notes.isEmpty else { return nil }
        let index = current(voice: voice, at: time)
        let from = index.map { notes[$0] }
        let next = index.map { $0 + 1 } ?? 0
        let here = place((from ?? notes[0]).midi, voice: voice)
        let landed = from.map { time - $0.start }
        guard next < notes.count else { return Ball(place: here, height: 0, sinceLanding: landed) }

        let to = notes[next]
        // Before the first note it drops in from above the note itself.
        let gap = from.map { to.start - $0.start } ?? Self.longestHop
        let hop = min(gap, Self.longestHop)
        let u = Float(1 - (to.start - time) / hop)
        guard u > 0 else { return Ball(place: here, height: 0, sinceLanding: landed) }
        let peak = min(Self.highestHop, max(Self.lowestHop, Self.gravity * Float(hop * hop) / 8))
        let there = place(to.midi, voice: voice)
        if from == nil {
            // The second half of a throw: falling onto the first note.
            let fall = 0.5 + u / 2
            return Ball(place: there, height: Self.highestHop * 4 * fall * (1 - fall), sinceLanding: nil)
        }
        return Ball(place: here + (there - here) * u, height: peak * 4 * u * (1 - u), sinceLanding: landed)
    }
}

/// The time the visualizers draw at, running smoothly between the feed's
/// reports. The feed says how far in the frame being heard ends, which
/// moves in steps of a video frame (20 ms on PAL); drawn as it comes, a
/// scrolling view would judder. This runs with the display's clock while
/// the reports keep moving and stays within the frame being heard, so it's
/// never ahead of or more than a frame behind the sound.
nonisolated struct SmoothPlayhead {
    private(set) var time: Double = 0
    private var lastHeard: Double?
    private var lastMoved: Double = -.infinity
    private var lastNow: Double?

    /// The longest video frame: NTSC's is shorter.
    static let frame = 0.02

    /// Advance to `now` (any steady clock, in seconds) with the feed's
    /// latest report.
    mutating func update(heard: Double?, now: Double) -> Double {
        let dt = min(max(lastNow.map { now - $0 } ?? 0, 0), 0.1)
        lastNow = now
        guard let heard else { return time }
        if heard != lastHeard {
            lastHeard = heard
            lastMoved = now
        }
        // A seek, a new tune or the first report.
        if abs(heard - time) > 0.25 {
            time = heard - Self.frame / 2
            return time
        }
        // Paused: the reports stop, and so does this.
        if now - lastMoved < 3 * Self.frame { time += dt }
        time = min(heard, max(heard - Self.frame, time))
        return time
    }
}
