import CryptoKit
import Foundation
import Network
import PhosphorCore
import Security
import SystemConfiguration

/// Resonance Remote's Mac half: a Bonjour-advertised TLS listener that takes
/// the command line tool's commands from paired iPhones and iPads. The
/// protocol is written down in the remote's own repository, design/PROTOCOL.md.
///
/// TLS uses pre-shared keys: each paired device has its own, and while
/// Settings, Remote is open, so do the QR code and the typed code. The keys
/// are fixed when the listener starts, so it starts again when they change.
@Observable
final class RemoteServer {
    nonisolated static let serviceType = "_resonance._tcp"
    nonisolated static let version = 1
    /// How long a QR code lasts while the page stays open.
    static let qrLifetime: Duration = .seconds(5 * 60)
    /// Failed handshakes while pairing before the typed code stops working.
    static let wrongCodeLimit = 5
    /// How long a connection has to say hello.
    static let helloTimeout: Duration = .seconds(10)
    /// How long a typed-code pairing waits for Allow on the Mac.
    static let approvalTimeout: Duration = .seconds(60)
    /// Connections that haven't said hello or paired yet, at most.
    static let maxStrangers = 8
    /// Connections per paired device, at most.
    static let maxPerDevice = 4

    struct Device: Codable, Identifiable, Equatable {
        let id: String
        var name: String
        /// "iPhone" or "iPad".
        var kind: String
        let pairedAt: Date
        var lastSeen: Date?
        /// Set when it joined through the Apple Account: the install that did.
        var install: String?
    }

    /// What Settings, Remote shows while it's open.
    struct Pairing: Equatable {
        let qrKey: Data
        /// Nil once too many wrong codes were tried.
        var code: String?
    }

    /// A device that typed the code, waiting for Allow. Both screens show
    /// the check number; a go-between would hold two connections, and two
    /// unrelated numbers.
    struct Approval: Equatable, Identifiable {
        let id = UUID()
        let name: String
        let kind: String
        /// Six digits, as "482 913".
        let check: String
    }

    enum Phase: Equatable {
        case off
        case starting
        case on
        case failed(String)
    }

    private(set) var phase = Phase.off
    private(set) var devices: [Device]
    private(set) var pairing: Pairing? {
        didSet {
#if DEBUG
            if Self.logsPairing, let pairing {
                FileHandle.standardError.write(Data("Remote pairing: \(Self.pairURL(macID: macID, key: pairing.qrKey)) code \(pairing.code ?? "none")\n".utf8))
            }
#endif
        }
    }
    /// Devices with a connection open now.
    private(set) var connected: Set<String> = []
    /// Something Settings, Remote should say, such as a key the Keychain
    /// wouldn't delete.
    private(set) var problem: String?
    /// Whether devices on this Mac's Apple Account join without pairing.
    private(set) var accountJoin: Bool
    /// False when this build can't keep the item in iCloud Keychain (no
    /// provisioning profile, so no data-protection keychain).
    private(set) var accountAvailable = true
    private(set) var approval: Approval? {
        didSet {
#if DEBUG
            // For testing a client without Settings open: prints the check
            // number, and answers it after two seconds if told how.
            guard Self.logsPairing, let approval else { return }
            FileHandle.standardError.write(Data("Remote approval: \(approval.name) check \(approval.check)\n".utf8))
            let answer = ProcessInfo.processInfo.environment["RESONANCE_REMOTE_APPROVE"]
            guard answer == "allow" || answer == "deny" else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                if answer == "allow" { self?.allow(approval) } else { self?.deny() }
            }
#endif
        }
    }

    let macID: String
    @ObservationIgnored private let commands: ControlCommands
    @ObservationIgnored private let player: PlayerStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var keys: [String: Data]
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [ObjectIdentifier: RemoteConnection] = [:]
    @ObservationIgnored private var pageViewers = 0
    @ObservationIgnored private var rotation: Task<Void, Never>?
    @ObservationIgnored private var failedHandshakes = 0
    /// Kept across restarts, so a device's last address keeps working.
    @ObservationIgnored private var port: NWEndpoint.Port?
    /// Waiting for the old listener to let go of the port.
    @ObservationIgnored private var restarting = false
    @ObservationIgnored private var waiting: Waiting?
    /// The account key, in iCloud Keychain while `accountJoin` is on.
    @ObservationIgnored private var accountKey: Data?
    /// The connection whose device is listening (Listen on iPhone).
    @ObservationIgnored private weak var streamConnection: RemoteConnection?

    /// A typed-code pairing: committed, then revealed, then waiting for Allow.
    private struct Waiting {
        let connection: RemoteConnection
        let pairID: Int
        let args: Args
        /// SHA-256 of the device's bytes, sent before it saw the Mac's.
        let commit: Data
        let macNonce: Data
        /// The `pair.reveal` request, answered on Allow.
        var revealID: Int?
        let timeout: Task<Void, Never>
    }

    init(commands: ControlCommands, player: PlayerStore, defaults: UserDefaults = .standard) {
        self.commands = commands
        self.player = player
        self.defaults = defaults
        if let id = defaults.string(forKey: Pref.remoteMacID) {
            macID = id
        } else {
            macID = Self.randomID(length: 8)
            defaults.set(macID, forKey: Pref.remoteMacID)
        }
        devices = (defaults.data(forKey: Pref.remoteDevices))
            .flatMap { try? JSONDecoder().decode([Device].self, from: $0) } ?? []
        keys = RemoteKeychain.load()
        accountJoin = defaults.object(forKey: Pref.remoteAccountJoin) as? Bool ?? true
        // A device whose key went missing can't connect, so it isn't listed;
        // a key whose device isn't listed mustn't keep working unseen.
        devices.removeAll { keys[$0.id] == nil }
        let listed = Set(devices.map(\.id))
        if keys.keys.contains(where: { !listed.contains($0) }) {
            keys = keys.filter { listed.contains($0.key) }
            if !RemoteKeychain.save(keys) {
                problem = String(localized: "Resonance couldn't remove keys of devices that are no longer listed from the Keychain.")
            }
        }
    }

    var isOn: Bool { defaults.bool(forKey: Pref.remoteEnabled) }

    /// At launch.
    func start() {
        observeStatus()
        if isOn {
            loadAccountKey()
            listen()
        }
#if DEBUG
        // For testing a client without Settings open: pairs as if the page
        // were, and prints the QR code's link and the code.
        if Self.logsPairing { pageOpened() }
#endif
    }

#if DEBUG
    private static let logsPairing = ProcessInfo.processInfo.environment["RESONANCE_REMOTE_PAIRING"] != nil
#endif

    func setOn(_ on: Bool) {
        defaults.set(on, forKey: Pref.remoteEnabled)
        if on {
            loadAccountKey()
            listen()
        } else {
            stopListening()
            for connection in connections.values { connection.close() }
        }
    }

    // MARK: Pairing

    /// Settings, Remote appeared: the QR code and the typed code exist until
    /// it goes.
    func pageOpened() {
        pageViewers += 1
        guard pageViewers == 1 else { return }
        newPairing()
        rotation = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.qrLifetime)
                // Also after the typed code was dropped: scanning still works.
                guard !Task.isCancelled, let self, let pairing = self.pairing else { continue }
                self.pairing = Pairing(qrKey: Self.randomKey(), code: pairing.code)
                self.relisten()
            }
        }
    }

    func pageClosed() {
        pageViewers = max(pageViewers - 1, 0)
        guard pageViewers == 0 else { return }
        if waiting != nil { deny() }
        rotation?.cancel()
        rotation = nil
        pairing = nil
        relisten()
    }

    /// What the QR code holds.
    var pairingURL: URL? {
        pairing.map { Self.pairURL(macID: macID, key: $0.qrKey) }
    }

    private func newPairing() {
        failedHandshakes = 0
        pairing = Pairing(qrKey: Self.randomKey(), code: Self.randomCode())
        relisten()
    }

    // MARK: Apple Account

    /// The switch in Settings: off deletes the item on every device; on
    /// makes a new key. Devices that joined keep their own keys.
    func setAccountJoin(_ on: Bool) {
        defaults.set(on, forKey: Pref.remoteAccountJoin)
        accountJoin = on
        if on {
            loadAccountKey()
        } else {
            if !RemoteAccountKey.delete(macID: macID) {
                problem = String(localized: "Resonance couldn't delete this Mac's key from iCloud Keychain, so devices on your Apple Account can still join.")
            }
            accountKey = nil
        }
        relisten()
    }

    /// Reads the account key from iCloud Keychain, or puts a new one there.
    private func loadAccountKey() {
        guard accountJoin else { return }
        defer {
#if DEBUG
            if Self.logsPairing {
                FileHandle.standardError.write(Data("Remote account key: \(accountKey?.base64EncodedString() ?? "unavailable")\n".utf8))
            }
#endif
        }
        switch RemoteAccountKey.load(macID: macID) {
        case .found(let key):
            accountKey = key
        case .missing:
            let key = Self.randomKey()
            let name = welcome().name
            if RemoteAccountKey.save(key, macID: macID, name: name) {
                accountKey = key
            } else {
                accountAvailable = false
            }
        case .unavailable:
            accountAvailable = false
        }
    }

    private var removedInstalls: Set<String> {
        Set(defaults.stringArray(forKey: Pref.remoteRemovedInstalls) ?? [])
    }

    func remove(_ device: Device) {
        var remaining = keys
        remaining[device.id] = nil
        // If the key stays in the Keychain, so does the device in the list.
        guard RemoteKeychain.save(remaining) else {
            problem = String(localized: "Resonance couldn't delete \(device.name)'s key from the Keychain, so it can still connect.")
            return
        }
        problem = nil
        keys = remaining
        if let install = device.install {
            defaults.set(Array(removedInstalls.union([install])).sorted(), forKey: Pref.remoteRemovedInstalls)
        }
        devices.removeAll { $0.id == device.id }
        saveDevices()
        for connection in connections.values where connection.device == device.id {
            connection.close()
        }
        relisten()
    }

    // MARK: Listening

    private func listen() {
        guard !restarting else { return }  // The restart under way reads the keys then.
        guard let old = listener else {
            startListening()
            return
        }
        // Start again once the old listener has let go of the port.
        restarting = true
        listener = nil
        old.newConnectionHandler = nil
        old.stateUpdateHandler = { [weak self] state in
            guard case .cancelled = state else { return }
            MainActor.assumeIsolated {
                guard let self, self.restarting else { return }
                self.restarting = false
                self.startListening()
            }
        }
        old.cancel()
    }

    private func startListening() {
        phase = .starting
        let parameters = Self.parameters(keys: tlsKeys())
        parameters.includePeerToPeer = true
        let listener: NWListener
        let wanted = port
        do {
            listener = try wanted.map { try NWListener(using: parameters, on: $0) } ?? NWListener(using: parameters)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        listener.service = service()
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, listener === self.listener else { return }
                switch state {
                case .ready:
                    self.port = listener.port
                    self.phase = .on
                case .failed(let error) where wanted != nil:
#if DEBUG
                    FileHandle.standardError.write(Data("Remote port \(wanted!) unavailable: \(error)\n".utf8))
#endif
                    // The port was taken meanwhile: any other will do.
                    self.port = nil
                    self.listen()
                case .failed(let error):
                    self.phase = .failed(error.localizedDescription)
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    /// After the keys change. Open connections stay open.
    private func relisten() {
        if listener != nil || restarting { listen() }
    }

    private func stopListening() {
        restarting = false
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        phase = .off
    }

    private func tlsKeys() -> [(identity: String, key: Data)] {
        var all = keys.map { (identity: "d:\($0.key)", key: $0.value) }
        if let pairing {
            all.append((identity: "q", key: pairing.qrKey))
            if let code = pairing.code {
                all.append((identity: "c", key: Self.codeKey(code: code, macID: macID)))
            }
        }
        if let accountKey {
            all.append((identity: "a", key: accountKey))
        }
        return all
    }

    nonisolated static func parameters(keys: [(identity: String, key: Data)]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for (identity, key) in keys {
            sec_protocol_options_add_pre_shared_key(options, key.dispatchData, Data(identity.utf8).dispatchData)
        }
        // ECDHE as well as the key, so a recording can't be tested offline.
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0xCCAC)!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        return NWParameters(tls: tls)
    }

    /// Nothing about what's playing: anyone in range can read the record.
    private func service() -> NWListener.Service {
        let txt = NWTXTRecord(["v": String(Self.version), "id": macID])
        return NWListener.Service(name: nil, type: Self.serviceType, domain: nil, txtRecord: txt)
    }

    // MARK: Connections

    private func accept(_ nw: NWConnection) {
        // Strangers hold a connection for up to ten seconds; cap them, so
        // nobody on the network can use up the app's files.
        guard connections.values.count(where: { $0.device == nil }) < Self.maxStrangers else {
            nw.cancel()
            return
        }
        let connection = RemoteConnection(nw)
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.onLine = { [weak self, weak connection] line in
            guard let self, let connection else { return }
            connection.enqueue { await self.received(line, from: connection) }
        }
        connection.onClose = { [weak self, weak connection] failure in
            guard let self else { return }
            self.connections[key] = nil
            Log.remote.info("connection closed\(failure.map { ": \(Log.kind($0))" } ?? "", privacy: .public)")
            self.updateConnected()
            if let waiting = self.waiting, waiting.connection === connection { self.endWaiting() }
            if let connection, self.streamConnection === connection { self.streamDeviceLeft() }
            if let failure, Self.isWrongKey(failure) { self.handshakeFailed() }
        }
        connection.start()
        Task { [weak self, weak connection] in
            try? await Task.sleep(for: Self.helloTimeout)
            guard let self, let connection, connection.device == nil,
                  self.waiting?.connection !== connection else { return }
            connection.close()
        }
    }

    /// A wrong key, most likely a mistyped code, or a wrong proof in `pair`.
    private func handshakeFailed() {
        guard var pairing, pairing.code != nil else { return }
        failedHandshakes += 1
        guard failedHandshakes >= Self.wrongCodeLimit else { return }
        pairing.code = nil
        self.pairing = pairing
        relisten()
    }

    private func updateConnected() {
        let now = Set(connections.values.compactMap(\.device))
        if now != connected { connected = now }
    }

    private struct Head: Decodable {
        var id: Int?
        var cmd: String
        var args: Args?
    }

    /// The parts of a request's arguments the remote looks at itself.
    private struct Args: Decodable {
        var device: String?
        var proof: String?
        var name: String?
        var kind: String?
        var path: String?
        var paths: [String]?
        var start: String?
        var commit: String?
        var nonce: String?
        var install: String?
        /// `visuals`: start or stop.
        var on: Bool?
        /// `visuals`: with the voices' waveforms.
        var scope: Bool?
    }

    private struct Welcome: Encodable {
        let mac: String
        let name: String
        let version: Int
        var device: String?
        var key: String?
    }

    private struct Empty: Encodable {}

    private struct Nonce: Encodable {
        let nonce: String
    }

    /// Where the stream comes from and how it's sealed (PROTOCOL.md, "Listening").
    private struct Stream: Encodable {
        let port: UInt16
        let key: String
        let rate = 48_000
        let frame = 480
    }

    private func received(_ line: Data, from connection: RemoteConnection) async {
        guard let head = try? JSONDecoder().decode(Head.self, from: line) else {
            connection.send(Self.failure(id: 0, "That request couldn't be read."))
            return
        }
        let id = head.id ?? 0
        let args = head.args ?? Args()
        guard let device = connection.device else {
            switch head.cmd {
            case "hello": hello(id: id, args, on: connection)
            case "pair": pair(id: id, args, on: connection)
            case "pair.reveal": reveal(id: id, args, on: connection)
            case "join": join(id: id, args, on: connection)
            default: connection.send(Self.failure(id: id, "Pair with this Mac first."), thenClose: true)
            }
            return
        }
        switch head.cmd {
        case "hello", "pair", "pair.reveal", "join":
            connection.send(Self.failure(id: id, "This device is already connected."))
        case "subscribe":
            connection.subscribed = true
            connection.send(Self.success(id: id, Empty()))
            connection.send(Self.event(commands.status()))
        case "visuals":
            connection.wantsVisuals = args.on ?? true
            connection.wantsScope = connection.wantsVisuals && args.scope == true
            connection.send(Self.success(id: id, Empty()))
            sendVisualsIfWanted()
        case "listen.start":
            startStream(id: id, device: device, on: connection)
        case "listen.stop":
            if streamConnection === connection { endStream() }
            connection.send(Self.success(id: id, Empty()))
        case let cmd where Self.allowed.contains(cmd):
            let paths = [args.path, args.start].compactMap(\.self) + (args.paths ?? [])
            guard Self.pathsAllowed(paths, root: player.hvscRoot, myPlaylist: Set(player.rows.map(\.item.path))) else {
                connection.send(Self.failure(id: id, "Resonance Remote can only reach tunes in this Mac's collection."))
                return
            }
            touch(device)
            connection.send(await commands.handle(line))
        default:
            connection.send(Self.failure(id: id, "Resonance Remote can't do that."))
        }
    }

    private func hello(id: Int, _ args: Args, on connection: RemoteConnection) {
        guard let device = args.device, let key = keys[device],
              Self.proves(args.proof, key: key, exporter: connection.exporter) else {
            connection.send(Self.failure(id: id, "This Mac doesn't know this device. Pair it again."), thenClose: true)
            return
        }
        guard connections.values.count(where: { $0.device == device }) < Self.maxPerDevice else {
            connection.send(Self.failure(id: id, "This device has too many connections open to this Mac."), thenClose: true)
            return
        }
        connection.device = device
        if let index = devices.firstIndex(where: { $0.id == device }) {
            if args.name != nil { devices[index].name = Self.name(args.name, kind: args.kind) }
            if let kind = args.kind { devices[index].kind = Self.kind(kind) }
            devices[index].lastSeen = .now
            saveDevices()
        }
        updateConnected()
        Log.remote.info("device connected")
        connection.send(Self.success(id: id, welcome()))
    }

    private func pair(id: Int, _ args: Args, on connection: RemoteConnection) {
        if let qrKey = pairing?.qrKey, Self.proves(args.proof, key: qrKey, exporter: connection.exporter) {
            // The QR code's key never crossed the network: no check needed.
            paired(id: id, args, on: connection)
            return
        }
        guard let code = pairing?.code, let exporter = connection.exporter,
              Self.proves(args.proof, key: Self.codeKey(code: code, macID: macID), exporter: exporter) else {
            handshakeFailed()
            connection.send(Self.failure(id: id, "That code has expired. Use the one on the Mac now."), thenClose: true)
            return
        }
        guard waiting == nil else {
            connection.send(Self.failure(id: id, "Another device is pairing with this Mac. Try again in a moment."), thenClose: true)
            return
        }
        guard let commit = args.commit.flatMap({ Data(base64Encoded: $0) }), commit.count == 32 else {
            connection.send(Self.failure(id: id, "Update Resonance Remote to pair with this Mac."), thenClose: true)
            return
        }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.approvalTimeout)
            if !Task.isCancelled { self?.deny() }
        }
        let macNonce = Self.randomKey()
        waiting = Waiting(connection: connection, pairID: id, args: args, commit: commit, macNonce: macNonce, timeout: timeout)
        connection.send(Self.success(id: id, Nonce(nonce: macNonce.base64EncodedString())))
    }

    /// A device on this Mac's Apple Account, holding the account key from
    /// iCloud Keychain. The key never crossed the network, so, as for a
    /// scan, there's nothing to check on the Mac.
    private func join(id: Int, _ args: Args, on connection: RemoteConnection) {
        guard let accountKey, Self.proves(args.proof, key: accountKey, exporter: connection.exporter) else {
            connection.send(Self.failure(id: id, "This Mac doesn't let devices on your Apple Account join. Pair it with a code or a scan."), thenClose: true)
            return
        }
        guard let install = Self.install(args.install), !removedInstalls.contains(install) else {
            connection.send(Self.failure(id: id, "This device was removed on this Mac. Pair it with a code or a scan."), thenClose: true)
            return
        }
        paired(id: id, args, install: install, on: connection)
    }

    /// The device shows its bytes, committed to before it saw the Mac's; only
    /// now does either side know the check number.
    private func reveal(id: Int, _ args: Args, on connection: RemoteConnection) {
        guard var waiting, waiting.connection === connection, waiting.revealID == nil,
              let exporter = connection.exporter,
              let nonce = args.nonce.flatMap({ Data(base64Encoded: $0) }), nonce.count == 32,
              Data(SHA256.hash(data: nonce)) == waiting.commit else {
            connection.send(Self.failure(id: id, "The Mac didn't allow this device."), thenClose: true)
            if self.waiting?.connection === connection { endWaiting() }
            return
        }
        waiting.revealID = id
        self.waiting = waiting
        approval = Approval(name: Self.name(waiting.args.name, kind: waiting.args.kind), kind: Self.kind(waiting.args.kind),
                            check: Self.checkNumber(exporter: exporter, device: nonce, mac: waiting.macNonce))
    }

    /// The person saw the same number on both screens. Only answers the
    /// request that was shown, in case another took its place.
    func allow(_ shown: Approval) {
        guard let waiting, let revealID = waiting.revealID, approval?.id == shown.id else { return }
        waiting.timeout.cancel()
        self.waiting = nil
        approval = nil
        paired(id: revealID, waiting.args, on: waiting.connection)
    }

    /// Don't Allow, no answer in time, or the page closed.
    func deny() {
        guard let waiting else { return }
        waiting.connection.send(Self.failure(id: waiting.revealID ?? waiting.pairID, "The Mac didn't allow this device."), thenClose: true)
        endWaiting()
    }

    /// The code is used up either way: a go-between may know it now.
    private func endWaiting() {
        waiting?.timeout.cancel()
        waiting = nil
        approval = nil
        if pageViewers > 0 { newPairing() }
    }

    private func paired(id: Int, _ args: Args, install: String? = nil, on connection: RemoteConnection) {
        let device = Device(
            id: Self.randomID(length: 10),
            name: Self.name(args.name, kind: args.kind),
            kind: Self.kind(args.kind),
            pairedAt: .now,
            lastSeen: .now,
            install: install
        )
        let key = Self.randomKey()
        var all = keys
        all[device.id] = key
        guard RemoteKeychain.save(all) else {
            connection.send(Self.failure(id: id, "The Mac couldn't save this device's key."), thenClose: true)
            if pageViewers > 0 { newPairing() }
            return
        }
        keys = all
        devices.append(device)
        saveDevices()
        connection.device = device.id
        updateConnected()
        var welcome = welcome()
        welcome.device = device.id
        welcome.key = key.base64EncodedString()
        connection.send(Self.success(id: id, welcome))
        // Used up: the page shows new ones, and the listener learns the device.
        if pageViewers > 0 { newPairing() } else { relisten() }
    }

    private func welcome() -> Welcome {
        Welcome(mac: macID, name: SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac", version: Self.version)
    }

    /// Last seen, at most once a minute, so commands don't keep writing.
    private func touch(_ id: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }),
              devices[index].lastSeen.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true else { return }
        devices[index].lastSeen = .now
        saveDevices()
    }

    private func saveDevices() {
        defaults.set(try? JSONEncoder().encode(devices), forKey: Pref.remoteDevices)
    }

    // MARK: Events

    // MARK: Listening

    /// The device plays the Mac's audio; the speakers go quiet. A device
    /// that was listening before stops getting audio and is told.
    private func startStream(id: Int, device: String, on connection: RemoteConnection) {
        guard player.canSeek else {
            connection.send(Self.failure(id: id, "Listening needs the reSIDfp or SIDLite direct engine, in Resonance's Settings on the Mac."))
            return
        }
        let name = devices.first { $0.id == device }?.name ?? device
        let key = Self.randomKey()
        do {
            let port = try player.startListening(.init(device: device, name: name), key: key)
            if let previous = streamConnection, previous !== connection {
                previous.send(Self.listenEnded)
            }
            streamConnection = connection
            Log.remote.info("listening on a device, port \(port)")
            touch(device)
            connection.send(Self.success(id: id, Stream(port: port, key: key.base64EncodedString())))
        } catch {
            Log.remote.error("listening didn't start: \(Log.kind(error))")
            connection.send(Self.failure(id: id, "The Mac couldn't start sending its audio: \(error.localizedDescription)"))
        }
    }

    private func endStream() {
        if streamConnection != nil { Log.remote.info("listening ended") }
        streamConnection = nil
        player.stopListening()
    }

    /// The listening device's connection dropped: pause, as macOS does when
    /// headphones are unplugged, rather than keep playing out loud.
    /// Paused first: the player takes commands sent before the switch
    /// ahead of it, so the speakers never get a moment of the tune.
    private func streamDeviceLeft() {
        Log.remote.info("the listening device's connection closed; pausing")
        if player.isPlaying { player.playPause() }
        endStream()
    }

    // MARK: Visuals

    /// Collects the visualizer frames every `visualsTick` and sends them to
    /// the devices that asked, until none does.
    private var visualsTask: Task<Void, Never>?

    /// 25 batches a second, two frames each at 50 Hz: well inside what a
    /// listening device buffers (about 150 ms), so frames land before they
    /// are heard; on the Mac's speakers, a frame shows within 40 ms.
    private static let visualsTick: Duration = .milliseconds(40)

    private func sendVisualsIfWanted() {
        guard visualsTask == nil, connections.values.contains(where: \.wantsVisuals) else { return }
        // Frames from before anyone asked aren't wanted.
        _ = player.takeRemoteVisuals()
        visualsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.visualsTick)
                guard let self else { return }
                let wanting = self.connections.values.filter { $0.wantsVisuals && $0.device != nil }
                guard !wanting.isEmpty else {
                    self.visualsTask = nil
                    return
                }
                let scope = wanting.contains(where: \.wantsScope)
                let frames = self.player.takeRemoteVisuals(scope: scope)
                guard !frames.isEmpty else { continue }
                let plain = Self.visuals(frames, scope: false)
                let withScope = scope ? Self.visuals(frames, scope: true) : plain
                for connection in wanting { connection.send(connection.wantsScope ? withScope : plain) }
            }
        }
    }

    private struct VisualFrame: Encodable {
        /// Frames since the subtune started.
        let i: UInt64
        let pal: Bool
        /// Per chip 35 bytes (RemoteVizFrame), base64.
        let chips: String
        /// The stream sample it starts at, while the device listens.
        let sample: UInt64?
        /// Chip 1's voices across the frame, base64 (RemoteVizFrame), when asked.
        let scope: String?
    }

    private static func visuals(_ frames: [RemoteVizFrame], scope: Bool) -> Data {
        let encoded = frames.map {
            VisualFrame(i: $0.index, pal: $0.isPal, chips: Data($0.chips).base64EncodedString(), sample: $0.streamSample,
                        scope: scope && !$0.scope.isEmpty ? Data($0.scope).base64EncodedString() : nil)
        }
        return (try? JSONEncoder().encode(Event(event: "visuals", result: encoded))) ?? Data()
    }

    private static var listenEnded: Data {
        Data(#"{"event":"listen.ended"}"#.utf8)
    }

    private func observeStatus() {
        let status = withObservationTracking {
            commands.status()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatus() }
        }
        // Another engine was chosen on the Mac, one that can't stream.
        if let connection = streamConnection, !status.canSeek {
            connection.send(Self.listenEnded)
            endStream()
        }
        let event = Self.event(status)
        for connection in connections.values where connection.subscribed {
            connection.send(event)
        }
    }

    // MARK: Rules

    /// What a paired device may ask: playing and finding, not reshaping
    /// playlists or opening files.
    nonisolated static let allowed: Set<String> = [
        "status", "play", "pause", "toggle", "stop", "next", "prev", "seek", "surprise", "fav", "scope",
        "search", "like", "drift", "sound", "tune.info", "share.link", "share.open", "describe", "describe.playing", "recent",
        "hvsc.info", "hvsc.authors", "hvsc.tunes", "hvsc.playlist", "hvsc.playlist.play", "hvsc.shuffle",
        "playlist.list", "playlist.show", "playlist.play", "playlist.add", "myplaylist.show", "myplaylist.play",
    ]

    /// Paths inside the collection, or already in My Playlist. No control
    /// characters: a NUL ends the path where `open` reads it, not where the
    /// check does. Symbolic links are followed before comparing.
    nonisolated static func pathsAllowed(_ paths: [String], root: String?, myPlaylist: Set<String>) -> Bool {
        let folder = root.map(resolved).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        return paths.allSatisfy { path in
            if myPlaylist.contains(path) { return true }
            guard let folder, path.hasPrefix("/"),
                  path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
            return resolved(path).hasPrefix(folder)
        }
    }

    /// Links resolved in the deepest part of the path that exists:
    /// `resolvingSymlinksInPath` leaves a path alone when its last part
    /// doesn't exist, which would let a link lead out of the collection.
    private nonisolated static func resolved(_ path: String) -> String {
        var existing = URL(fileURLWithPath: (path as NSString).standardizingPath)
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var result = existing.resolvingSymlinksInPath()
        for part in rest { result.append(path: part) }
        return result.path
    }

    nonisolated static func codeKey(code: String, macID: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
            salt: Data(macID.utf8),
            info: Data("resonance-remote code v1".utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    nonisolated static func proves(_ proof: String?, key: Data, exporter: Data?) -> Bool {
        guard let exporter, let proof, let mac = Data(base64Encoded: proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: exporter, using: SymmetricKey(data: key))
    }

    /// Six digits both ends take from the TLS session and both sides' random
    /// bytes, as "482 913".
    nonisolated static func checkNumber(exporter: Data, device: Data, mac macNonce: Data) -> String {
        let message = Data("resonance-remote check v2".utf8) + device + macNonce
        let mac = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: exporter)))
        let value = mac.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let digits = String(format: "%06u", value)
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }

    /// Whether a handshake failed on the key itself, rather than an unknown
    /// identity (a removed device) or something that never spoke TLS.
    nonisolated static func isWrongKey(_ error: NWError) -> Bool {
        if case .tls(let status) = error { return wrongKeyStatuses.contains(status) }
        return false
    }

    /// Measured on the listener: a wrong key for a known identity fails with
    /// -9846 (bad record MAC). An unknown identity gives -9864, and a
    /// connection that never speaks TLS gives -9816; neither counts.
    nonisolated static let wrongKeyStatuses: Set<OSStatus> = [-9846]

    nonisolated static func pairURL(macID: String, key: Data) -> URL {
        let base64url = key.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "resonance-remote://pair?mac=\(macID)&key=\(base64url)")!
    }

    /// As the device calls itself, without control characters or line
    /// breaks: it's shown in the Allow prompt.
    nonisolated static func name(_ name: String?, kind: String?) -> String {
        let scalars = (name ?? "").unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        }
        let name = String(String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces).prefix(64))
        return name.isEmpty ? Self.kind(kind) : name
    }

    /// A device's install ID: 1 to 64 letters, digits or dashes.
    nonisolated static func install(_ id: String?) -> String? {
        guard let id, (1...64).contains(id.count),
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }) else { return nil }
        return id
    }

    private nonisolated static func kind(_ kind: String?) -> String {
        kind == "iPad" ? "iPad" : "iPhone"
    }

    /// Letters and digits that can't be mistaken for each other.
    private nonisolated static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    nonisolated static func randomID(length: Int) -> String {
        String((0..<length).map { _ in alphabet.randomElement()! })
    }

    nonisolated static func randomKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    nonisolated static func randomCode() -> String {
        String(format: "%04d", Int.random(in: 0..<10_000))
    }

    // MARK: Lines

    private struct Envelope<T: Encodable>: Encodable {
        let id: Int
        let ok: Bool
        let result: T?
        let error: String?
    }

    private struct Event<T: Encodable>: Encodable {
        let event: String
        let result: T
    }

    private static func success<T: Encodable>(id: Int, _ value: T) -> Data {
        (try? JSONEncoder().encode(Envelope(id: id, ok: true, result: value, error: nil))) ?? Data()
    }

    private static func failure(id: Int, _ message: String) -> Data {
        (try? JSONEncoder().encode(Envelope<Empty>(id: id, ok: false, result: nil, error: message))) ?? Data()
    }

    private static func event(_ status: ControlCommands.Status) -> Data {
        (try? JSONEncoder().encode(Event(event: "status", result: status))) ?? Data()
    }
}

/// One phone or iPad's connection: TLS, then one JSON object per line.
final class RemoteConnection {
    private static let maxLine = 1 << 20
    private static let exporterLabel = "EXPORTER-resonance-remote"

    /// Once it has said hello or paired.
    var device: String?
    var subscribed = false
    /// Sent visualizer frames (`visuals`), while its Now Playing shows.
    var wantsVisuals = false
    /// With the voices' waveforms, while its Scope page shows.
    var wantsScope = false
    /// 32 bytes both ends derive from this TLS session, for proofs.
    private(set) var exporter: Data?
    var onLine: ((Data) -> Void)?
    /// The error, when it closed before TLS was up.
    var onClose: ((_ failure: NWError?) -> Void)?

    private let nw: NWConnection
    private var buffer = Data()
    private var wasReady = false
    private var closed = false
    private var tail: Task<Void, Never>?

    init(_ nw: NWConnection) {
        self.nw = nw
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.changed(state) }
        }
        nw.start(queue: .main)
    }

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            wasReady = true
            exporter = Self.exporter(of: nw)
            receive()
        case .waiting(let error), .failed(let error):
#if DEBUG
            if !wasReady { FileHandle.standardError.write(Data("Remote handshake failed: \(error)\n".utf8)) }
#endif
            nw.cancel()
            finish(error)
        case .cancelled:
            finish()
        default:
            break
        }
    }

    private static func exporter(of nw: NWConnection) -> Data? {
        guard let tls = nw.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        let secret = exporterLabel.withCString {
            sec_protocol_metadata_create_secret(tls.securityProtocolMetadata, exporterLabel.utf8.count, $0, 32)
        }
        return secret.map { Data($0 as DispatchData) }
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data { self.buffer.append(data) }
                // Walk the buffer once and drop what was read at the end, so a
                // flood of short lines doesn't copy the rest for each one.
                var start = self.buffer.startIndex
                while let newline = self.buffer[start...].firstIndex(of: 10) {
                    let line = Data(self.buffer[start..<newline])
                    start = newline + 1
                    if !line.isEmpty { self.onLine?(line) }
                }
                if start != self.buffer.startIndex { self.buffer = Data(self.buffer[start...]) }
                if self.buffer.count > Self.maxLine || isComplete || error != nil {
                    self.close()
                } else {
                    self.receive()
                }
            }
        }
    }

    /// Runs requests one after another, so answers keep their order.
    func enqueue(_ work: @escaping () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await work()
        }
    }

    func send(_ line: Data, thenClose: Bool = false) {
        guard !closed else { return }
        nw.send(content: line + [10], completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                if error != nil || thenClose { self?.close() }
            }
        })
    }

    func close() {
        guard !closed else { return }
        nw.cancel()
        finish()
    }

    private func finish(_ error: NWError? = nil) {
        guard !closed else { return }
        closed = true
        tail?.cancel()
        onClose?(wasReady ? nil : error)
    }
}

/// The paired devices' keys: one Keychain item for all of them.
nonisolated enum RemoteKeychain {
    private static let service = "Resonance Remote"
    private static let account = "devices"

    static func load() -> [String: Data] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let encoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return encoded.compactMapValues { Data(base64Encoded: $0) }
    }

    /// Whether the Keychain now holds exactly these keys.
    @discardableResult
    static func save(_ keys: [String: Data]) -> Bool {
        let match: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        guard !keys.isEmpty else {
            let status = SecItemDelete(match as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        guard let data = try? JSONEncoder().encode(keys.mapValues { $0.base64EncodedString() }) else { return false }
        let status = SecItemUpdate(match as CFDictionary, [kSecValueData: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var add = match
        add[kSecValueData] = data
        add[kSecAttrLabel] = "Resonance Remote devices"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// The account key in iCloud Keychain, shared with Resonance Remote through
/// the keychain group both apps list (PROTOCOL.md, "Joining through the Apple
/// Account").
nonisolated enum RemoteAccountKey {
    static let group = "R4D8QN85WK.app.useresonance.shared"
    private static let service = "Resonance Remote account"

    enum Loaded {
        case found(Data)
        case missing
        /// This build has no access to the group (no provisioning profile).
        case unavailable
    }

    private static func match(_ macID: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: macID,
            kSecAttrAccessGroup: group,
            kSecAttrSynchronizable: true,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    static func load(macID: String) -> Loaded {
        var query = match(macID)
        query[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let key = result as? Data, key.count == 32 else { return .missing }
            return .found(key)
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable
        }
    }

    static func save(_ key: Data, macID: String, name: String) -> Bool {
        var add = match(macID)
        add[kSecValueData] = key
        add[kSecAttrLabel] = "Resonance Remote: \(name)"
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(match(macID) as CFDictionary, [kSecValueData: key] as CFDictionary)
        }
        return status == errSecSuccess
    }

    /// Deletes it here and, through iCloud Keychain, everywhere.
    static func delete(macID: String) -> Bool {
        let status = SecItemDelete(match(macID) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement
    }
}

nonisolated private extension Data {
    var dispatchData: __DispatchData {
        withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }
}
