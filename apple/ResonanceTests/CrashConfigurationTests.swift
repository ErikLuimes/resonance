import KSCrashRecording
import Testing
@testable import Resonance

/// What KSCrash watches for: crashes and hangs, not how the last run ended.
@MainActor
struct CrashConfigurationTests {
    @Test func aQuitIsNotACrash() {
        let monitors = AppDelegate.crashConfiguration().monitors
        #expect(!monitors.contains(.termination))
        #expect(monitors.contains(.signal))
        #expect(monitors.contains(.machException))
        #expect(monitors.contains(.nsException))
        #expect(monitors.contains(.cppException))
        #expect(monitors.contains(.watchdog))
    }
}
