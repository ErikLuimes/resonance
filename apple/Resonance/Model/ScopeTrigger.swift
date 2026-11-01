/// Picks which stretch of a voice's samples the scope draws, so a held
/// note's waveform stands still from one display frame to the next instead
/// of sliding sideways.
nonisolated enum ScopeTrigger {
    /// Periods shown for a pitched voice; fewer for very low notes.
    static let cycles = 2.5
    static let minLength = 96
    static let maxLength = 1400
    /// Shown for noise and silence, which have no period to lock to.
    static let unpitchedLength = 512

    /// The newest stretch of `samples` that starts where the wave rises
    /// through zero, about `cycles` periods of `hz` long. Falls back to the
    /// newest stretch when there's no crossing (noise, silence, test bit).
    static func window(_ samples: [Float], hz: Double, sampleRate: Float, pitched: Bool) -> ArraySlice<Float> {
        guard pitched, hz > 0, sampleRate > 0 else { return samples.suffix(unpitchedLength) }
        let period = Double(sampleRate) / hz
        // Leave a period of room before the window to find a crossing in.
        let room = samples.count - Int(period.rounded(.up)) - 1
        let length = max(min(Int(period * cycles), maxLength, room), minLength)
        guard samples.count > length + 1 else { return samples.suffix(length) }

        let earliest = max(1, samples.count - length - Int(period.rounded(.up)))
        var start = samples.count - length
        while start >= earliest {
            if samples[start - 1] < 0, samples[start] >= 0 {
                return samples[start..<start + length]
            }
            start -= 1
        }
        return samples.suffix(length)
    }
}
