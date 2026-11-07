import Foundation
import Testing
@testable import Resonance

struct FileAccessTests {
    private let name = "FileAccessTests.\(UUID().uuidString)"
    private let folder = URL.temporaryDirectory.appending(path: "FileAccessTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func access(container: String = "/nowhere/container") -> (FileAccess, UserDefaults) {
        let defaults = UserDefaults(suiteName: name)!
        return (FileAccess(defaults: defaults, container: container), defaults)
    }

    private func make(_ path: String) throws -> URL {
        let url = folder.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("PSID".utf8).write(to: url)
        return url
    }

    private func cleanUp(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func keepsAFileAndRemembersIt() throws {
        let (files, defaults) = access()
        defer { cleanUp(defaults) }
        let tune = try make("Commando.sid")
        files.keep([tune])
        #expect(files.paths == [tune.standardizedFileURL.path])
        // A later launch's.
        let again = FileAccess(defaults: defaults, container: "/nowhere/container")
        again.restore()
        #expect(again.paths == [tune.standardizedFileURL.path])
    }

    @Test func aFolderCoversWhatsInIt() throws {
        let (files, defaults) = access()
        defer { cleanUp(defaults) }
        let tune = try make("Hubbard/Commando.sid")
        files.keep([tune])
        files.keep([folder])
        #expect(files.paths == [folder.standardizedFileURL.path])
        #expect(files.isCovered(tune.path))
        files.keep([tune])
        #expect(files.paths.count == 1)
    }

    @Test func theContainerNeedsNothing() throws {
        let (files, defaults) = access(container: folder.path)
        defer { cleanUp(defaults) }
        files.keep([try make("Commando.sid")])
        #expect(files.paths.isEmpty)
    }

    @Test func forgetsWhatsGone() throws {
        let (files, defaults) = access()
        defer { cleanUp(defaults) }
        let tune = try make("Commando.sid")
        files.keep([tune])
        try FileManager.default.removeItem(at: tune)
        files.restore()
        #expect(files.paths.isEmpty)
    }

    @Test func showsTheContainerByName() {
        let container = "/Users/x/Library/Containers/app.useresonance.resonance/Data"
        let support = container + "/Library/Application Support/Resonance"
        #expect(RealHome.displayPath(support + "/HVSC", container: container, support: support) == "Resonance's folder/HVSC")
        #expect(RealHome.displayPath(container + "/tmp", container: container, support: support) == "Resonance's container/tmp")
        #expect(RealHome.displayPath(RealHome.url.path + "/HVSC", container: container, support: support) == "~/HVSC")
        #expect(RealHome.displayPath("/Volumes/C64/HVSC", container: container, support: support) == "/Volumes/C64/HVSC")
    }

    @Test func realHomeIsTheUsersNotTheContainer() {
        #expect(!RealHome.url.path.contains("/Library/Containers/"))
        #expect(FileManager.default.fileExists(atPath: RealHome.url.appending(path: "Library").path))
    }
}
