import Foundation

/// Puts the `resonance` tool on the PATH: a link to the copy inside the app, so
/// updating the app updates the tool, in the first folder here that's writable
/// without asking for a password and doesn't have something else by that name.
nonisolated enum CommandLineTool {
    enum Failure: Error, Equatable {
        /// Something else already has the name in every folder that could be
        /// written to. These are all of them.
        case nameTaken([String])
        case notInApp
        case noFolder
    }

    static var bundled: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/resonance")
    }

    static var folders: [URL] {
        [URL(filePath: "/opt/homebrew/bin"), URL(filePath: "/usr/local/bin"),
         RealHome.url.appending(path: ".local/bin")]
    }

    /// Where it's installed, if somewhere: a link to `tool`.
    static func installed(tool: URL = bundled, in folders: [URL] = folders) -> URL? {
        folders.map { $0.appending(path: "resonance") }.first { isLink($0, to: tool) }
    }

    /// Whether a shell finds what's in `folder` without being told.
    static func isOnDefaultPath(_ folder: URL) -> Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains(Substring(folder.path))
            || ["/opt/homebrew/bin", "/usr/local/bin"].contains(folder.path)
    }

    /// The user's login shell, which a terminal opens by default.
    static var loginShell: String {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return "/bin/zsh" }
        return String(cString: shell)
    }

    /// The line that adds ~/.local/bin, the only folder here a shell doesn't
    /// already look in, to the PATH. Running it twice changes nothing.
    static func pathCommand(shell: String = loginShell) -> String {
        let file: String
        switch URL(filePath: shell).lastPathComponent {
        case "fish": return "fish_add_path $HOME/.local/bin"
        case "zsh": file = "\"${ZDOTDIR:-$HOME}/.zshrc\""
        case "bash": file = "~/.bash_profile"
        default: file = "~/.profile"
        }
        let line = #"export PATH="$HOME/.local/bin:$PATH""#
        return "grep -qsF '\(line)' \(file) || echo '\(line)' >> \(file)"
    }

    /// Another program by the same name in one of the other folders, which a
    /// terminal may run instead of the tool. "May", because only the user's
    /// shell knows the order of its PATH.
    static func shadowedBy(_ link: URL, in folders: [URL] = folders) -> URL? {
        let manager = FileManager.default
        return folders.filter { $0.path != link.deletingLastPathComponent().path }
            .map { $0.appending(path: "resonance") }
            .first { candidate in
                var isFolder: ObjCBool = false
                guard manager.fileExists(atPath: candidate.path, isDirectory: &isFolder), !isFolder.boolValue,
                      manager.isExecutableFile(atPath: candidate.path) else { return false }
                let target = try? manager.destinationOfSymbolicLink(atPath: candidate.path)
                return !(target.map(isOurs) ?? false)
            }
    }

    /// The command that connects Claude Code. With the full path when it's
    /// installed, because an assistant may not have the folder on its PATH.
    static func assistantCommand(installedAt link: URL?) -> String {
        let tool = link?.path ?? "resonance"
        return "claude mcp add resonance -- \(tool.contains(" ") ? "\"\(tool)\"" : tool) mcp"
    }

    @discardableResult
    static func install(tool: URL = bundled, in folders: [URL] = folders) throws -> URL {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: tool.path) else { throw Failure.notInApp }
        // The last folder is the user's own, so it may not exist yet.
        if let own = folders.last { try? manager.createDirectory(at: own, withIntermediateDirectories: true) }
        var taken: [String] = []
        var failure: (any Error)?
        for folder in folders where manager.isWritableFile(atPath: folder.path) {
            let link = folder.appending(path: "resonance")
            // Ours from another copy of the app, or one that's gone: replace it.
            let previous = try? manager.destinationOfSymbolicLink(atPath: link.path)
            guard previous.map(isOurs) ?? !manager.fileExists(atPath: link.path) else {
                taken.append(link.path)
                continue
            }
            do {
                if previous != nil { try manager.removeItem(at: link) }
                do {
                    try manager.createSymbolicLink(at: link, withDestinationURL: tool)
                } catch {
                    if let previous { try? manager.createSymbolicLink(atPath: link.path, withDestinationPath: previous) }
                    throw error
                }
                removeOurLinks(in: folders, except: folder)
                return link
            } catch {
                failure = failure ?? error
            }
        }
        if !taken.isEmpty { throw Failure.nameTaken(taken) }
        throw failure ?? Failure.noFolder
    }

    /// One left in another folder could come first on the PATH and run an old copy.
    private static func removeOurLinks(in folders: [URL], except kept: URL) {
        let manager = FileManager.default
        for folder in folders where folder.path != kept.path {
            let link = folder.appending(path: "resonance")
            if let target = try? manager.destinationOfSymbolicLink(atPath: link.path), isOurs(target) {
                try? manager.removeItem(at: link)
            }
        }
    }

    private static func isOurs(_ target: String) -> Bool {
        target.hasSuffix("/Contents/Helpers/resonance")
    }

    private static func isLink(_ link: URL, to tool: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == tool.path
    }

    static func message(for error: any Error) -> String {
        switch error as? Failure {
        case .nameTaken(let paths): String(localized: "Something else is already at \(paths.formatted(.list(type: .and))).")
        case .notInApp: String(localized: "This copy of Resonance doesn't include the tool.")
        case .noFolder: String(localized: "No folder for it could be written to.")
        case nil: error.localizedDescription
        }
    }
}
