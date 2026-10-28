import Foundation
import PhosphorCore

/// Keeps App Nap and timer coalescing away while music plays. The player
/// thread paces C64 frames with sleep-then-spin waits; coalesced timers in a
/// hidden or minimised window would make it stutter and fall behind.
final class PlaybackActivity {
    private let store: PlayerStore
    private var token: NSObjectProtocol?

    init(store: PlayerStore) {
        self.store = store
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = store.state
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        update(playing: store.state == .playing)
    }

    private func update(playing: Bool) {
        if playing, token == nil {
            token = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Playing SID music"
            )
        } else if !playing, let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
    }
}
