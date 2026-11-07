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
        #expect(throws: CommandLineTool.Failure.nameTaken(other.path)) {
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
