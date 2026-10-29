import MediaPlayer
import PhosphorCore

/// Publishes the current tune to Control Center / the Now Playing widget
/// and routes media keys back to the store.
///
/// macOS can't infer any of this from our audio (the engine drives Core
/// Audio directly), so `playbackState` is set explicitly. Elapsed time is
/// only pushed on track and state changes; the system extrapolates it from
/// the playback rate in between.
final class NowPlayingController {
    private let store: PlayerStore
    private var lastKey: Key?

    private struct Key: Equatable {
        let trackRevision: UInt64
        let state: PlaybackState
        let duration: TimeInterval?
    }

    init(store: PlayerStore) {
        self.store = store
        registerRemoteCommands()
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = (store.trackRevision, store.state, store.duration)
        } onChange: { [weak self] in
            // onChange runs before the new values are set; read them next turn.
            Task { @MainActor in
                self?.publish()
                self?.observe()
            }
        }
        publish()
    }

    private func publish() {
        let key = Key(trackRevision: store.trackRevision, state: store.state, duration: store.duration)
        guard key != lastKey else { return }
        lastKey = key

        let center = MPNowPlayingInfoCenter.default()
        guard let track = store.nowPlaying, store.state != .stopped else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.author,
            MPMediaItemPropertyAlbumTitle: track.released,
            MPMediaItemPropertyAlbumTrackNumber: Int(track.currentSong),
            MPMediaItemPropertyAlbumTrackCount: Int(track.songs),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: store.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: store.state == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let duration = store.duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        center.nowPlayingInfo = info
        center.playbackState = store.state == .playing ? .playing : .paused
    }

    private func registerRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        // Handlers can arrive off the main thread, so they're @Sendable
        // (not main-actor-isolated) and hop to the main actor themselves.
        let store = store
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerStore) -> Void) {
            command.isEnabled = true
            command.addTarget { @Sendable _ in
                Task { @MainActor in action(store) }
                return .success
            }
        }
        on(commands.togglePlayPauseCommand) { $0.playPause() }
        on(commands.playCommand) { if !$0.isPlaying { $0.playPause() } }
        on(commands.pauseCommand) { if $0.isPlaying { $0.playPause() } }
        on(commands.stopCommand) { $0.stop() }
        on(commands.nextTrackCommand) { $0.next() }
        on(commands.previousTrackCommand) { $0.previous() }
        // SID tunes are generated live; there's nothing to seek in.
        commands.changePlaybackPositionCommand.isEnabled = false
        commands.seekForwardCommand.isEnabled = false
        commands.seekBackwardCommand.isEnabled = false
    }
}
