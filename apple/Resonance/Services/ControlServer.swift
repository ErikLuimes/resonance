import Darwin
import Foundation
import PhosphorCore
import Security

/// The socket the `resonance` command line tool talks to: one JSON object per
/// line each way (ControlCommands.swift has what they say). It lives in the
/// app group's container, where the sandboxed `resonance-mcp` can reach it,
/// is only readable by its owner, and turns away anyone else.
nonisolated final class ControlServer: @unchecked Sendable {
    /// More than any request needs: a whole playlist's paths fit well within.
    private static let maxLine = 8 << 20

    static var defaultPath: String {
#if DEBUG
        // So a Debug copy can run beside the installed app without taking its
        // socket.
        if let path = ProcessInfo.processInfo.environment["RESONANCE_SOCKET"] { return path }
#endif
        // The group's container, not its Library: a socket's whole path has
        // to fit in 104 bytes. Without a team there's no group, and then the
        // sandbox's home, the app's own container.
        let folder = appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)?.path }
        return ((folder ?? NSHomeDirectory()) as NSString).appendingPathComponent("control.sock")
    }

    /// "<team>.resonance", as the app was signed: Config/Resonance.entitlements
    /// has it as `$(TeamIdentifierPrefix)resonance`, which a build signed
    /// without a team turns into a plain "resonance".
    static var appGroup: String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String]
        else { return nil }
        return groups.first { $0.hasSuffix(".resonance") }
    }

    private let path: String
    private let handle: @Sendable (Data) async -> Data
    private var listener: Int32 = -1
    /// Numbers connections in the log (ControlAudit). Only the accept loop
    /// touches it.
    private var connections = 0

    init(path: String = ControlServer.defaultPath, handle: @escaping @Sendable (Data) async -> Data) {
        self.path = path
        self.handle = handle
    }

    enum StartError: Error {
        case pathTooLong
        case system(String)
    }

    func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw StartError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: Array(path.utf8) + [0])
        }

        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw StartError.system("socket") }
        // Left behind by an app that didn't get to quit.
        unlink(path)
        // Owner only from the moment it exists, not from the chmod below.
        let mask = umask(0o177)
        defer { umask(mask) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(socket, 8) == 0 else {
            close(socket)
            throw StartError.system(String(cString: strerror(errno)))
        }
        listener = socket

        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let connection = accept(socket, nil, nil)
                guard connection >= 0 else {
                    if errno == EINTR { continue }
                    return
                }
                serve(connection)
            }
        }
    }

    func stop() {
        guard listener >= 0 else { return }
        close(listener)
        listener = -1
        unlink(path)
    }

    private func serve(_ connection: Int32) {
        var peer = uid_t(), group = gid_t()
        guard getpeereid(connection, &peer, &group) == 0, peer == getuid() else {
            ControlAudit.refused(uid: peer)
            close(connection)
            return
        }
        var on: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        connections += 1
        let number = connections
        ControlAudit.connected(number, socket: connection)

        // One blocking thread per client, answering in the order it asks.
        let handle = handle
        Thread.detachNewThread {
            defer { close(connection); ControlAudit.closed(number) }
            var pending = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(connection, &chunk, chunk.count)
                guard count > 0 else { return }
                // Only the new bytes can hold a newline: what came before was
                // looked through already.
                var from = pending.endIndex
                pending.append(contentsOf: chunk[0..<count])
                // Walk the buffer once and drop what was read at the end, so a
                // flood of short lines doesn't copy the rest for each one.
                var start = pending.startIndex
                while let newline = pending[from...].firstIndex(of: 10) {
                    let line = Data(pending[start..<newline])
                    start = newline + 1
                    from = start
                    guard !line.isEmpty else { continue }
                    ControlAudit.request(number, line: line)
                    let reply = Self.wait { await handle(line) }
                    guard Self.write(reply + [10], to: connection) else { return }
                }
                if start != pending.startIndex { pending = Data(pending[start...]) }
                guard pending.count <= Self.maxLine else { return }
            }
        }
    }

    /// Off the thread pool, so blocking here is fine.
    private static func wait(_ work: @escaping @Sendable () async -> Data) -> Data {
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        Task {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value
    }

    private final class Box: @unchecked Sendable {
        var value = Data()
    }

    private static func write(_ data: Data, to connection: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.write(connection, buffer.baseAddress! + sent, buffer.count - sent)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }
}

/// What's playing, as one line in a file, so a shell prompt can show it without
/// asking the app (which would slow every prompt). No file while nothing plays.
final class PromptStatus {
    static var defaultURL: URL {
        AppPaths.supportDirectory.appending(path: "now-playing.txt")
    }

    private let store: PlayerStore
    private let url: URL
    private var written: String?

    init(store: PlayerStore, url: URL = PromptStatus.defaultURL) {
        self.store = store
        self.url = url
    }

    func start() {
        observe()
    }

    func stop() {
        try? FileManager.default.removeItem(at: url)
        written = nil
    }

    private func observe() {
        withObservationTracking {
            _ = (store.state, store.nowPlaying)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        let line = Self.line(track: store.nowPlaying, playing: store.isPlaying)
        guard line != written else { return }
        written = line
        if let line {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// "Commando · Rob Hubbard"; nil unless something's playing.
    nonisolated static func line(track: TrackDetails?, playing: Bool) -> String? {
        guard playing, let track else { return nil }
        let title = track.title.isEmpty
            ? URL(filePath: track.path).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
            : track.title
        return plain(track.author.isEmpty ? title : "\(title) · \(track.author)")
    }

    /// Without control characters: a prompt prints this as it is, and a tune
    /// file's header can hold escape codes that would steer the terminal.
    nonisolated static func plain(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0.properties.generalCategory != .control && !CharacterSet.newlines.contains($0)
        }))
    }
}
