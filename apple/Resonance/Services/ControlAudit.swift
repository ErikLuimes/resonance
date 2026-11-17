import Darwin
import Foundation
import OSLog
import Security

/// Who used the control socket and what they asked, in the unified log
/// (category `control`; design/logging/README.md). This is for finding out
/// afterward what happened, not access control: ControlServer's owner and uid
/// checks are that.
nonisolated enum ControlAudit {
    /// The process on the other end of a connection.
    struct Peer: Equatable {
        var pid: Int32
        /// The executable, in full: private, since it can be in a home folder.
        var path: String?
        var signingID: String?
        var team: String?
        var parentPID: Int32?
        var parentName: String?

        /// The executable's file name: public.
        var name: String? { path.map { URL(filePath: $0).lastPathComponent } }
    }

    // MARK: Logging

    static func connected(_ number: Int, socket: Int32) {
        guard let peer = peer(of: socket) else {
            Log.control.notice("#\(number, privacy: .public) from an unknown process")
            return
        }
        Log.control.notice("\(connectionLine(number, peer), privacy: .public) at \(peer.path ?? "?", privacy: .private)")
    }

    static func refused(uid: uid_t) {
        Log.control.error("Refused a connection from uid \(uid, privacy: .public)")
    }

    static func closed(_ number: Int) {
        Log.control.debug("#\(number, privacy: .public) closed")
    }

    static func request(_ number: Int, line: Data) {
        guard let request = Request(line) else {
            Log.control.notice("#\(number, privacy: .public) unreadable request, \(line.count, privacy: .public) bytes")
            return
        }
        let level: OSLogType = request.changesThings ? .default : .debug
        Log.control.log(level: level, "\(requestLine(number, request), privacy: .public) \(request.arguments, privacy: .private)")
    }

    // MARK: Formatting

    /// "#3 from resonance (pid 4512, app.useresonance.resonance-cli, team ABCDE12345), started by zsh (pid 4100)"
    static func connectionLine(_ number: Int, _ peer: Peer) -> String {
        let signing = switch (peer.signingID, peer.team) {
        case (nil, _): "unsigned"
        case (let id?, nil): "\(id), no team"
        case (let id?, let team?): "\(id), team \(team)"
        }
        var line = "#\(number) from \(peer.name ?? "?") (pid \(peer.pid), \(signing))"
        if let parent = peer.parentPID {
            line += ", started by \(peer.parentName ?? "?") (pid \(parent))"
        }
        return line
    }

    /// "#3 playlist.add (name, paths: 2)": the command and its arguments' shape,
    /// never their values.
    static func requestLine(_ number: Int, _ request: Request) -> String {
        let shape = request.shape.isEmpty ? "" : " (\(request.shape.joined(separator: ", ")))"
        return "#\(number) \(request.command ?? "unknown command")\(shape)"
    }

    /// One line from the socket, as far as the log cares.
    struct Request: Equatable {
        /// The command's name if it's one ControlCommands knows. Anything else
        /// a client sends could be anything, so it isn't logged in public.
        let command: String?
        /// The arguments it has, by name, with how many for a list.
        let shape: [String]
        /// The arguments themselves, as sent: private.
        let arguments: String
        let changesThings: Bool

        init?(_ line: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let name = object["cmd"] as? String else { return nil }
            let known = ControlAudit.readOnly.contains(name) || ControlAudit.changing.contains(name)
            command = known ? name : nil
            changesThings = !ControlAudit.readOnly.contains(name)
            let args = object["args"] as? [String: Any] ?? [:]
            shape = args.keys.sorted().map { key in
                guard ControlAudit.argumentNames.contains(key) else { return "other" }
                if let list = args[key] as? [Any] { return "\(key): \(list.count)" }
                return key
            }
            let text = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            arguments = known ? String(text.prefix(2000)) : "\(name) \(text.prefix(2000))"
        }
    }

    /// Commands that only read: logged at debug. Everything else, unknown ones
    /// included, at default.
    static let readOnly: Set<String> = [
        "status", "scope", "tracker.position", "tracker.song", "search", "like", "drift", "sound",
        "prints", "prints.composers", "guess.pool", "describe", "describe.playing", "recent",
        "hvsc.info", "hvsc.authors", "hvsc.tunes", "hvsc.playlist",
        "playlist.list", "playlist.show", "myplaylist.show", "playing.show",
    ]

    /// Commands that play, change a list, or bring the window up.
    static let changing: Set<String> = [
        "play", "pause", "seek", "toggle", "stop", "next", "prev", "surprise", "fav", "show",
        "hvsc.playlist.play", "hvsc.shuffle", "myplaylist.play", "playing.play", "recent.play",
        "playlist.play", "playlist.new", "playlist.add", "playlist.rm", "playlist.mv",
        "playlist.rename", "playlist.delete", "link.answer", "quit",
        "terminal.closed",
    ]

    /// ControlCommands.Args's fields.
    static let argumentNames: Set<String> = [
        "text", "limit", "path", "paths", "start", "name", "to", "before", "on", "play", "count",
        "detail", "chip", "seconds", "links", "link", "choice",
    ]

    // MARK: The peer

    static func peer(of socket: Int32) -> Peer? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else { return nil }
        // audit_token_to_pid, without linking libbsm.
        let pid = Int32(bitPattern: token.val.5)
        var peer = Peer(pid: pid, path: path(of: pid))
        signing(of: token, into: &peer)
        var info = proc_bsdinfo()
        let size2 = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size2) == size2 {
            let parent = Int32(bitPattern: info.pbi_ppid)
            peer.parentPID = parent
            peer.parentName = path(of: parent).map { URL(filePath: $0).lastPathComponent } ?? name(of: parent)
        }
        return peer
    }

    /// From the audit token rather than the pid, so a pid that's been reused
    /// can't stand in for the one that connected.
    private static func signing(of token: audit_token_t, into peer: inout Peer) {
        var token = token
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return }
        peer.signingID = info[kSecCodeInfoIdentifier as String] as? String
        peer.team = info[kSecCodeInfoTeamIdentifier as String] as? String
        if peer.path == nil, let url = info[kSecCodeInfoMainExecutable as String] as? URL {
            peer.path = url.path
        }
    }

    private static func path(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return string(buffer)
    }

    private static func name(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return string(buffer)
    }

    private static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
