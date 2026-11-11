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
    private let fingerprints: FingerprintStore
    private var lastKey: Key?
    /// Rendered once per tune, not again for every pause or seek.
    private var artwork: (key: ArtworkKey, image: MPMediaItemArtwork?)?

    private struct Key: Equatable {
        let trackRevision: UInt64
        let state: PlaybackState
        let duration: TimeInterval?
        let canSeek: Bool
        /// A seek moves the elapsed time, and lands later: publish both.
        let seeking: Bool
        /// Its arrival swaps the composer's colors for the sphere.
        let scanned: Bool
    }

    private struct ArtworkKey: Equatable {
        let path: String
        let scanned: Bool
    }

    init(store: PlayerStore, fingerprints: FingerprintStore) {
        self.store = store
        self.fingerprints = fingerprints
        registerRemoteCommands()
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = (store.trackRevision, store.state, store.duration, store.canSeek, store.seeking)
            _ = store.nowPlaying.flatMap { fingerprints.fingerprint($0.path) }
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
        let fingerprint = store.nowPlaying.flatMap { fingerprints.fingerprint($0.path) }
        // Also what the Dock menu goes by. Tunes not scanned yet stay on the
        // store's list, and arrive through the observation above.
        if let path = store.nowPlaying?.path, fingerprint == nil { fingerprints.load([path]) }

        let key = Key(
            trackRevision: store.trackRevision, state: store.state, duration: store.duration,
            canSeek: store.canSeek, seeking: store.seeking, scanned: fingerprint != nil
        )
        guard key != lastKey else { return }
        lastKey = key

        let commands = MPRemoteCommandCenter.shared()
        commands.changePlaybackPositionCommand.isEnabled = store.canSeek
        commands.skipForwardCommand.isEnabled = store.canSeek
        commands.skipBackwardCommand.isEnabled = store.canSeek

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
            MPNowPlayingInfoPropertyElapsedPlaybackTime: store.elapsedNow,
            MPNowPlayingInfoPropertyPlaybackRate: store.state == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let duration = store.duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork = artwork(for: track, fingerprint: fingerprint) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        center.nowPlayingInfo = info
        center.playbackState = store.state == .playing ? .playing : .paused
    }

    private func artwork(for track: TrackDetails, fingerprint: TuneFingerprint?) -> MPMediaItemArtwork? {
        let key = ArtworkKey(path: track.path, scanned: fingerprint != nil)
        if let artwork, artwork.key == key { return artwork.image }
        let image = NowPlayingArtwork.image(fingerprint: fingerprint, composer: track.author).map(NowPlayingArtwork.artwork)
        artwork = (key, image)
        return image
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
        // Seeking, on the engines that can (`publish` enables these).
        commands.changePlaybackPositionCommand.addTarget { @Sendable event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in store.seek(to: position) }
            return .success
        }
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.preferredIntervals = [15]
        on(commands.skipForwardCommand) { $0.skip(by: 15) }
        on(commands.skipBackwardCommand) { $0.skip(by: -15) }
        // Hold-to-seek is for real-time scanning, which the engines can't do.
        commands.seekForwardCommand.isEnabled = false
        commands.seekBackwardCommand.isEnabled = false
    }
}
