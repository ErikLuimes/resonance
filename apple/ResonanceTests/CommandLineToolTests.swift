import Foundation
import Testing
@testable import Resonance

struct CommandLineToolTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "tool-\(UUID().uuidString)")

    private func tool(_ app: String = "Resonance") throws -> URL {
        let url = folder.appending(path: "\(app).app/Contents/Helpers/resonance")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        return url
    }

    private func bin(_ name: String = "bin") throws -> URL {
        let url = folder.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func assistantCommandUsesTheInstalledPath() {
        #expect(CommandLineTool.assistantCommand(installedAt: nil) == "claude mcp add resonance -- resonance mcp")
        #expect(CommandLineTool.assistantCommand(installedAt: URL(filePath: "/opt/homebrew/bin/resonance"))
                == "claude mcp add resonance -- /opt/homebrew/bin/resonance mcp")
        #expect(CommandLineTool.assistantCommand(installedAt: URL(filePath: "/Users/a b/.local/bin/resonance"))
                == "claude mcp add resonance -- \"/Users/a b/.local/bin/resonance\" mcp")
    }

    @Test func linksIntoTheFirstWritableFolder() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = try tool(), bin = try bin()
        let link = try CommandLineTool.install(tool: tool, in: [folder.appending(path: "missing"), bin])
        #expect(link == bin.appending(path: "resonance"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == tool.path)
        #expect(CommandLineTool.installed(tool: tool, in: [bin])?.path == link.path)
    }

    @Test func makesTheUsersOwnFolder() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let own = folder.appending(path: "home/.local/bin")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = try CommandLineTool.install(tool: try tool(), in: [folder.appending(path: "missing"), own])
        #expect(link == own.appending(path: "resonance"))
    }

    /// Another copy of the app, say an older one, or one since deleted.
    @Test func replacesItsOwnLink() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = try tool("Old"), new = try tool("New"), bin = try bin()
        try CommandLineTool.install(tool: old, in: [bin])
        let link = try CommandLineTool.install(tool: new, in: [bin])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == new.path)
    }

    @Test func leavesAnythingElseAlone() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let bin = try bin()
        let other = bin.appending(path: "resonance")
        FileManager.default.createFile(atPath: other.path, contents: Data("mine".utf8))
        #expect(throws: CommandLineTool.Failure.nameTaken([other.path])) {
            try CommandLineTool.install(tool: try tool(), in: [bin])
        }
        #expect(try String(contentsOf: other, encoding: .utf8) == "mine")
    }

    @Test func leavesSomeoneElsesLinkAlone() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let bin = try bin()
        try FileManager.default.createSymbolicLink(at: bin.appending(path: "resonance"), withDestinationURL: URL(filePath: "/usr/bin/true"))
        #expect(throws: CommandLineTool.Failure.self) { try CommandLineTool.install(tool: try tool(), in: [bin]) }
    }

    @Test func movesPastAFolderWhereTheNameIsTaken() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = try tool(), first = try bin("first"), second = try bin("second")
        let other = first.appending(path: "resonance")
        FileManager.default.createFile(atPath: other.path, contents: Data("mine".utf8))
        let link = try CommandLineTool.install(tool: tool, in: [first, second])
        #expect(link == second.appending(path: "resonance"))
        #expect(try String(contentsOf: other, encoding: .utf8) == "mine")
    }

    @Test func movesPastSomeoneElsesLink() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try bin("first"), second = try bin("second")
        let other = first.appending(path: "resonance")
        try FileManager.default.createSymbolicLink(at: other, withDestinationURL: URL(filePath: "/usr/bin/true"))
        let link = try CommandLineTool.install(tool: try tool(), in: [first, second])
        #expect(link == second.appending(path: "resonance"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: other.path) == "/usr/bin/true")
    }

    /// Moving on shouldn't leave a second link when it's already further along.
    @Test func replacesItsOwnLinkPastATakenFolder() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = try tool("Old"), new = try tool("New"), first = try bin("first"), second = try bin("second")
        try CommandLineTool.install(tool: old, in: [second])
        FileManager.default.createFile(atPath: first.appending(path: "resonance").path, contents: Data())
        let link = try CommandLineTool.install(tool: new, in: [first, second])
        #expect(link == second.appending(path: "resonance"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == new.path)
    }

    /// An old link further along could come first on the PATH.
    @Test func removesItsOwnLinkFromALaterFolder() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = try tool("Old"), new = try tool("New"), first = try bin("first"), second = try bin("second")
        let stale = try CommandLineTool.install(tool: old, in: [second])
        let link = try CommandLineTool.install(tool: new, in: [first, second])
        #expect(link == first.appending(path: "resonance"))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: stale.path)) == nil)
    }

    @Test func keepsSomeoneElsesLinkInALaterFolder() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try bin("first"), second = try bin("second")
        let other = second.appending(path: "resonance")
        try FileManager.default.createSymbolicLink(at: other, withDestinationURL: URL(filePath: "/usr/bin/true"))
        try CommandLineTool.install(tool: try tool(), in: [first, second])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: other.path) == "/usr/bin/true")
    }

    @Test func namesEveryTakenFolderWhenAllAre() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try bin("first"), second = try bin("second")
        let taken = [first, second].map { $0.appending(path: "resonance") }
        for path in taken { FileManager.default.createFile(atPath: path.path, contents: Data()) }
        #expect(throws: CommandLineTool.Failure.nameTaken(taken.map(\.path))) {
            try CommandLineTool.install(tool: try tool(), in: [first, second])
        }
        let message = CommandLineTool.message(for: CommandLineTool.Failure.nameTaken(taken.map(\.path)))
        #expect(taken.allSatisfy { message.contains($0.path) })
    }

    @Test func noWritableFolderSaysSo() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = try tool()
        #expect(throws: CommandLineTool.Failure.noFolder) {
            try CommandLineTool.install(tool: tool, in: [URL(filePath: "/nonexistent/bin"), URL(filePath: "/System/bin")])
        }
    }

    @Test func noticesAnotherProgramEarlierOnThePath() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = try tool(), first = try bin("first"), second = try bin("second")
        let other = first.appending(path: "resonance")
        FileManager.default.createFile(atPath: other.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        let link = try CommandLineTool.install(tool: tool, in: [first, second])
        #expect(CommandLineTool.shadowedBy(link, in: [first, second])?.path == other.path)
    }

    /// The shell's PATH may not follow the order of the folders here.
    @Test func noticesAnotherProgramInALaterFolder() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = try tool(), first = try bin("first"), second = try bin("second")
        let later = second.appending(path: "resonance")
        FileManager.default.createFile(atPath: later.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        let link = try CommandLineTool.install(tool: tool, in: [first, second])
        #expect(link == first.appending(path: "resonance"))
        #expect(CommandLineTool.shadowedBy(link, in: [first, second])?.path == later.path)
    }

    @Test func aFolderWithTheNameShadowsNothing() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try bin("first"), second = try bin("second")
        try FileManager.default.createDirectory(at: first.appending(path: "resonance"), withIntermediateDirectories: true)
        let link = second.appending(path: "resonance")
        #expect(CommandLineTool.shadowedBy(link, in: [first, second]) == nil)
    }

    @Test func anotherCopyOfTheToolIsNotAnotherProgram() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = try tool("Old"), first = try bin("first"), second = try bin("second")
        try FileManager.default.createSymbolicLink(at: first.appending(path: "resonance"), withDestinationURL: old)
        let link = second.appending(path: "resonance")
        #expect(CommandLineTool.shadowedBy(link, in: [first, second]) == nil)
    }

    @Test func pathCommandFitsTheShell() {
        let line = #"export PATH="$HOME/.local/bin:$PATH""#
        #expect(CommandLineTool.pathCommand(shell: "/bin/zsh")
                == #"grep -qsF '\#(line)' "${ZDOTDIR:-$HOME}/.zshrc" || echo '\#(line)' >> "${ZDOTDIR:-$HOME}/.zshrc""#)
        #expect(CommandLineTool.pathCommand(shell: "/bin/bash")
                == "grep -qsF '\(line)' ~/.bash_profile || echo '\(line)' >> ~/.bash_profile")
        #expect(CommandLineTool.pathCommand(shell: "/opt/homebrew/bin/fish") == "fish_add_path $HOME/.local/bin")
        #expect(CommandLineTool.pathCommand(shell: "/bin/ksh")
                == "grep -qsF '\(line)' ~/.profile || echo '\(line)' >> ~/.profile")
    }

    /// Running the copied line twice leaves one line in the file.
    @Test func pathCommandOnlyAddsTheLineOnce() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = try bin("home")
        let run = Process()
        run.executableURL = URL(filePath: "/bin/zsh")
        run.environment = ["HOME": home.path, "ZDOTDIR": home.path]
        run.arguments = ["-fc", CommandLineTool.pathCommand(shell: "/bin/zsh") + "; " + CommandLineTool.pathCommand(shell: "/bin/zsh")]
        try run.run()
        run.waitUntilExit()
        let text = try String(contentsOf: home.appending(path: ".zshrc"), encoding: .utf8)
        #expect(text == #"export PATH="$HOME/.local/bin:$PATH""# + "\n")
    }

    @Test func aMissingToolSaysSo() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: CommandLineTool.Failure.notInApp) {
            try CommandLineTool.install(tool: folder.appending(path: "nope"), in: [try bin()])
        }
    }

    @Test func notInstalledIsNil() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(CommandLineTool.installed(tool: try tool(), in: [try bin()]) == nil)
    }
}
