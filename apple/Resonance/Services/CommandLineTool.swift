import Foundation

/// Puts the `resonance` tool on the PATH: a link to the copy inside the app, so
/// updating the app updates the tool, in the first folder here that's writable
/// without asking for a password.
nonisolated enum CommandLineTool {
    enum Failure: Error, Equatable {
        /// Something else already has the name there.
        case nameTaken(String)
        case notInApp
        case noFolder
    }

    static var bundled: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/resonance")
    }

    static var folders: [URL] {
        [URL(filePath: "/opt/homebrew/bin"), URL(filePath: "/usr/local/bin"),
         FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin")]
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

    @discardableResult
    static func install(tool: URL = bundled, in folders: [URL] = folders) throws -> URL {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: tool.path) else { throw Failure.notInApp }
        // The last folder is the user's own, so it may not exist yet.
        if let own = folders.last { try? manager.createDirectory(at: own, withIntermediateDirectories: true) }
        guard let folder = folders.first(where: { manager.isWritableFile(atPath: $0.path) }) else {
            throw Failure.noFolder
        }
        let link = folder.appending(path: "resonance")
        if let target = try? manager.destinationOfSymbolicLink(atPath: link.path) {
            // Ours from another copy of the app, or one that's gone: replace it.
            guard target.hasSuffix("/Contents/Helpers/resonance") else { throw Failure.nameTaken(link.path) }
            try manager.removeItem(at: link)
        } else if manager.fileExists(atPath: link.path) {
            throw Failure.nameTaken(link.path)
        }
        try manager.createSymbolicLink(at: link, withDestinationURL: tool)
        return link
    }

    private static func isLink(_ link: URL, to tool: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == tool.path
    }

    static func message(for error: any Error) -> String {
        switch error as? Failure {
        case .nameTaken(let path): "Something else is already at \(path)."
        case .notInApp: "This copy of Resonance doesn't include the tool."
        case .noFolder: "No folder for it could be written to."
        case nil: error.localizedDescription
        }
    }
}
