import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings, Remote: turns Resonance Remote's listener on, pairs a device by
/// QR code or typed code, and lists the paired ones. The approved mockup is
/// design/settings-mockup.html in the remote's repository.
struct RemoteSettings: View {
    @Environment(RemoteServer.self) private var remote
    @State private var isOn = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { isOn }, set: { isOn = $0; remote.setOn($0) })) {
                Text("Control Resonance from iPhone and iPad")
                Text("This Mac shows up in Resonance Remote on devices on the same network.")
            }
        } footer: {
            if let problem = remote.problem {
                Text(problem)
                    .foregroundStyle(.red)
            } else if case .failed(let message) = remote.phase {
                Text("Resonance couldn't start listening: \(message)")
                    .foregroundStyle(.red)
            } else if !isOn {
                Text("Commands stay on your network and are encrypted. The first time you turn this on, macOS asks to let Resonance find devices on your local network.")
            }
        }
        .onAppear {
            isOn = remote.isOn
            remote.pageOpened()
        }
        .onDisappear { remote.pageClosed() }

        if isOn {
            if remote.accountAvailable {
                Section("Apple Account") {
                    Toggle(isOn: Binding(get: { remote.accountJoin }, set: { remote.setAccountJoin($0) })) {
                        Text("Connect devices on your Apple Account without pairing")
                        Text("iPhones and iPads signed in to the same Apple Account, with iCloud Keychain on, connect without a code. A new device can take a few minutes to get it.")
                    }
                }
            }
            Section("Pair a Device") {
                if let approval = remote.approval {
                    RemoteApprovalRow(approval: approval)
                } else {
                    RemotePairingRow()
                }
            }
            Section {
                if remote.devices.isEmpty {
                    Text("No devices yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(remote.devices) { device in
                        RemoteDeviceRow(device: device, isConnected: remote.connected.contains(device.id),
                                        joinedThroughAccount: device.install != nil && remote.accountJoin) {
                            remote.remove(device)
                        }
                    }
                }
            } header: {
                Text("Paired Devices")
            } footer: {
                Text("Removing a device signs it out at once. It needs a new code or a scan to come back, even on your Apple Account. Commands stay on your network and are encrypted.")
            }
        }
    }
}

private struct RemotePairingRow: View {
    @Environment(RemoteServer.self) private var remote

    var body: some View {
        HStack(spacing: 20) {
            if let url = remote.pairingURL, let image = QRCodeImage.make(url.absoluteString) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 132, height: 132)
                    .padding(8)
                    // Dark on white in both appearances: not every scanner
                    // reads a light-on-dark code.
                    .background(.white, in: .rect(cornerRadius: 10))
                    .accessibilityLabel("Pairing QR code")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Scan this with the camera on your iPhone or iPad.")
                    .fontWeight(.medium)
                Text("It opens Resonance Remote and pairs it with this Mac. The code works once, and only while this page is open.")
                    .foregroundStyle(.secondary)
                if let code = remote.pairing?.code {
                    Text("Or enter this code in Resonance Remote:")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    HStack(spacing: 6) {
                        ForEach(Array(code.enumerated()), id: \.offset) { _, digit in
                            Text(verbatim: String(digit))
                                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                                .frame(width: 32, height: 40)
                                .background(.quaternary, in: .rect(cornerRadius: 7))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Pairing code \(code.map(String.init).joined(separator: " "))")
                } else {
                    Text("Too many wrong codes. Open this page again for a new one.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }
}

/// After a typed code: the device waits until the person compares the
/// numbers on both screens and allows it.
private struct RemoteApprovalRow: View {
    @Environment(RemoteServer.self) private var remote
    let approval: RemoteServer.Approval

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            Image(systemName: approval.kind == "iPad" ? "ipad.landscape" : "iphone")
                .font(.title)
                .foregroundStyle(.secondary)
                .frame(width: 30)
                .frame(maxHeight: .infinity, alignment: .center)
            VStack(alignment: .leading, spacing: 6) {
                // Verbatim inside: the name comes from the device.
                Text("\(Text(verbatim: approval.name)) wants to pair with this Mac.")
                    .fontWeight(.medium)
                Text("Allow it only if Resonance Remote shows the same number.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(Array(approval.check.enumerated()), id: \.offset) { _, digit in
                        if digit == " " {
                            Spacer().frame(width: 6)
                        } else {
                            Text(verbatim: String(digit))
                                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                                .frame(width: 32, height: 40)
                                .background(.quaternary, in: .rect(cornerRadius: 7))
                        }
                    }
                }
                .padding(.top, 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Check number \(approval.check.filter(\.isNumber).map(String.init).joined(separator: " "))")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button("Don't Allow") { remote.deny() }
                // No default button: Return mustn't let a device in.
                Button("Allow") { remote.allow(approval) }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct RemoteDeviceRow: View {
    let device: RemoteServer.Device
    let isConnected: Bool
    let joinedThroughAccount: Bool
    let remove: () -> Void

    var body: some View {
        LabeledContent {
            Button("Remove", action: remove)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: device.kind == "iPad" ? "ipad.landscape" : "iphone")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: device.name)
                    HStack(spacing: 0) {
                        if isConnected {
                            HStack(spacing: 5) {
                                Circle().fill(.green).frame(width: 7, height: 7)
                                Text("Connected")
                            }
                        } else if let seen = device.lastSeen {
                            Text("Last connected \(seen.formatted(.relative(presentation: .named)))")
                        } else {
                            Text("Not connected yet")
                        }
                        if joinedThroughAccount {
                            Text(" · Joined through your Apple Account")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The pairing link as a QR code, made the way Core Image makes them.
nonisolated enum QRCodeImage {
    static func make(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
