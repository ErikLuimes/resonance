import AVFoundation
import OSLog

/// Switch, tube, hatch, disk drive and keyboard sounds for the About desk.
final class MonitorSounds {
    static let shared = MonitorSounds()
    private static let log = Logger(subsystem: "app.useresonance.resonance", category: "MonitorSounds")

    private let switchOn = MonitorSounds.player(named: "CRTPowerOn")
    private let switchOff = MonitorSounds.player(named: "CRTPowerOff")
    private let hatchClose = MonitorSounds.player(named: "CRTHatchClose")
    private let driveLoad = MonitorSounds.player(named: "Drive1541Load")
    private let hum = MonitorSounds.player(named: "CRTHum")
    // Let one key's clack finish while the next starts.
    private let keyDown = (0..<4).compactMap { _ in MonitorSounds.player(named: "C64KeyDown") }
    private let keyUp = (0..<4).compactMap { _ in MonitorSounds.player(named: "C64KeyUp") }
    private let spaceDown = (0..<2).compactMap { _ in MonitorSounds.player(named: "C64SpaceDown") }
    private let spaceUp = (0..<2).compactMap { _ in MonitorSounds.player(named: "C64SpaceUp") }

    private init() {
        hum?.numberOfLoops = -1
    }

    func update(power: MonitorModel.Power) {
        switch power {
        case .on:
            play(switchOn, volume: 0.85)
            play(hum, volume: 0.12)
            hum?.setVolume(0.78, fadeDuration: 0.35)
        case .dying:
            switchOn?.stop()
            stopKeys()
            play(switchOff, volume: 0.85)
            hum?.setVolume(0, fadeDuration: 0.18)
        case .off:
            stop()
        }
    }

    func playKey(pressed: Bool, spacebar: Bool) {
        let keyPlayers = pressed ? keyDown : keyUp
        let spacePlayers = pressed ? spaceDown : spaceUp
        let players = spacebar && !spacePlayers.isEmpty ? spacePlayers : keyPlayers
        let player = players.first { !$0.isPlaying } ?? players.first
        play(player, volume: (pressed ? 0.50 : 0.27) * Float.random(in: 0.85...1))
    }

    func playHatchClose() {
        play(hatchClose, volume: 0.72)
    }

    func playDriveLoad() {
        play(driveLoad, volume: 0.68)
    }

    func stopDrive() {
        driveLoad?.stop()
    }

    func stop() {
        switchOn?.stop()
        switchOff?.stop()
        hatchClose?.stop()
        stopDrive()
        hum?.stop()
        stopKeys()
    }

    private func stopKeys() {
        for player in keyDown + keyUp + spaceDown + spaceUp { player.stop() }
    }

    private func play(_ player: AVAudioPlayer?, volume: Float) {
        guard let player else { return }
        player.currentTime = 0
        player.volume = volume
        if !player.play() {
            Self.log.error("Could not play \(player.url?.lastPathComponent ?? "CRT audio", privacy: .public)")
        }
    }

    private static func player(named name: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            log.error("Missing bundled CRT clip \(name, privacy: .public)")
            return nil
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            return player
        } catch {
            log.error("Could not load \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
