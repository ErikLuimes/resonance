import CoreAudio
import Foundation

/// Reports how long the default output device takes to play what it's
/// given: a few milliseconds for built-in speakers, 100–250 ms for Bluetooth
/// headphones. It reports once at start and again whenever the default
/// output changes.
///
/// The visualizer feed needs it to line up with the sound, and the core
/// can't see it: the engine plays through cpal. Kept for the app's lifetime.
final class OutputLatencyMonitor {
    private let onChange: (Duration) -> Void
    /// What the output is, whenever it changes: for Resonance Remote.
    private let onOutput: (PlayerStore.Output?) -> Void
    /// Headphones were unplugged, or Bluetooth ones went away.
    private let onUnplugged: () -> Void
    /// The device whose data source (speakers or the headphone jack) is
    /// watched, so plugging in headphones reports too.
    private var watched: AudioObjectID?
    /// The output at the last report, to tell what changed.
    private var last: (device: AudioObjectID, output: PlayerStore.Output)?

    init(onChange: @escaping (Duration) -> Void,
         onOutput: @escaping (PlayerStore.Output?) -> Void = { _ in },
         onUnplugged: @escaping () -> Void = {}) {
        self.onChange = onChange
        self.onOutput = onOutput
        self.onUnplugged = onUnplugged
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.report() }
        }
        report()
    }

    private func report() {
        onChange(Self.defaultOutputLatency() ?? .zero)
        let device = Self.uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        if let device, device != watched {
            watched = device
            var address = Self.address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput)
            AudioObjectAddPropertyListenerBlock(device, &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }
        let output = device.map(Self.output(of:))
        if let last, Self.endsPersonalListening(
            from: last.output, to: output,
            sameDevice: device == last.device, oldStillThere: Self.isPresent(last.device)
        ) {
            onUnplugged()
        }
        last = device.flatMap { device in output.map { (device, $0) } }
        onOutput(output)
    }

    /// Whether going from `old` to `new` ends listening on headphones, so
    /// the music would go on out loud: the jack was unplugged (the
    /// built-in device switched itself to its speakers; macOS gives no other
    /// way there), or the Bluetooth headphones went away. Choosing another
    /// output while they're still there doesn't count, as on iPhone.
    static func endsPersonalListening(from old: PlayerStore.Output, to new: PlayerStore.Output?,
                                      sameDevice: Bool, oldStillThere: Bool) -> Bool {
        guard old.isPersonal, new?.isPersonal != true else { return false }
        return sameDevice || !oldStillThere
    }

    /// Whether `device` is still connected and working.
    private static func isPresent(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return false }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr,
              devices.contains(device)
        else { return false }
        return uint32(device, kAudioDevicePropertyDeviceIsAlive).map { $0 != 0 } ?? false
    }

    /// What `device` is, by its transport and, for Bluetooth, its name: the
    /// name is what tells AirPods, AirPods Pro and AirPods Max apart.
    static func output(of device: AudioDeviceID) -> PlayerStore.Output {
        let name = string(device, kAudioObjectPropertyName) ?? ""
        let lower = name.lowercased()
        let kind: String
        switch uint32(device, kAudioDevicePropertyTransportType) {
        case kAudioDeviceTransportTypeBuiltIn:
            // 'hdpn' is the headphone jack; 'ispk' the internal speakers.
            kind = uint32(device, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput) == 0x6864_706E
                ? "headphones" : "speakers"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            kind = lower.contains("airpods max") ? "airpodsMax"
                : lower.contains("airpods pro") ? "airpodsPro"
                : lower.contains("airpods") ? "airpods"
                : lower.contains("beats") ? "beats"
                : "bluetooth"
        case kAudioDeviceTransportTypeAirPlay: kind = "airplay"
        case kAudioDeviceTransportTypeUSB: kind = "usb"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: kind = "display"
        default: kind = "other"
        }
        return PlayerStore.Output(kind: kind, name: name)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector, kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    /// The device's latency, safety offset, I/O buffer and stream latency.
    static func defaultOutputLatency() -> Duration? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let output = kAudioObjectPropertyScopeOutput
        guard let device = uint32(system, kAudioHardwarePropertyDefaultOutputDevice),
              let rate = float64(device, kAudioDevicePropertyNominalSampleRate), rate > 0
        else { return nil }
        let frames = [
            uint32(device, kAudioDevicePropertyLatency, scope: output),
            uint32(device, kAudioDevicePropertySafetyOffset, scope: output),
            uint32(device, kAudioDevicePropertyBufferFrameSize, scope: output),
            firstOutputStream(of: device).flatMap { uint32($0, kAudioStreamPropertyLatency) },
        ]
        .compactMap { $0 }
        .reduce(0) { $0 + Double($1) }
        return .seconds(frames / rate)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func float64(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Float64? {
        var address = address(selector, kAudioObjectPropertyScopeGlobal)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func firstOutputStream(of device: AudioDeviceID) -> AudioStreamID? {
        var address = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioStreamID>.size)
        else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr else { return nil }
        return streams.first
    }
}
