import Testing
@testable import Resonance

/// When losing the output pauses the music: headphones unplugged or gone,
/// not a different output chosen while they're still there.
@MainActor
struct OutputUnplugTests {
    private let jack = PlayerStore.Output(kind: "headphones", name: "External Headphones")
    private let speakers = PlayerStore.Output(kind: "speakers", name: "MacBook Pro Speakers")
    private let airPods = PlayerStore.Output(kind: "airpodsPro", name: "AirPods Pro")
    private let display = PlayerStore.Output(kind: "display", name: "Studio Display")

    private func ends(_ old: PlayerStore.Output, _ new: PlayerStore.Output?, same: Bool = false, there: Bool) -> Bool {
        OutputLatencyMonitor.endsPersonalListening(from: old, to: new, sameDevice: same, oldStillThere: there)
    }

    @Test func unpluggingTheJackPauses() {
        #expect(ends(jack, speakers, same: true, there: true))
    }

    @Test func pluggingInHeadphonesDoesNot() {
        #expect(!ends(speakers, jack, same: true, there: true))
    }

    @Test func bluetoothHeadphonesGoingAwayPause() {
        #expect(ends(airPods, speakers, there: false))
        #expect(ends(airPods, display, there: false))
        #expect(ends(airPods, nil, there: false))
    }

    @Test func choosingTheSpeakersWhileTheHeadphonesAreThereDoesNot() {
        #expect(!ends(airPods, speakers, there: true))
    }

    @Test func movingFromOneHeadphoneToAnotherDoesNot() {
        #expect(!ends(airPods, jack, there: false))
        #expect(!ends(jack, airPods, there: true))
    }

    @Test func losingSpeakersOrADisplayDoesNot() {
        #expect(!ends(display, speakers, there: false))
        #expect(!ends(speakers, display, there: true))
    }
}
