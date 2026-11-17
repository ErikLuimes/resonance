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
    /// The device whose data source (speakers or the headphone jack) is
    /// watched, so plugging in headphones reports too.
    private var watched: AudioObjectID?

    init(onChange: @escaping (Duration) -> Void, onOutput: @escaping (PlayerStore.Output?) -> Void = { _ in }) {
        self.onChange = onChange
        self.onOutput = onOutput
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
        onOutput(device.map(Self.output(of:)))
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
