import Foundation
import Testing
import PhosphorCore
@testable import Resonance

@MainActor
struct DataFolderTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ResonanceData-\(UUID().uuidString)")
    let defaults: UserDefaults
    let fake = FakeCore()

    init() {
        let suite = "ResonanceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func collection(_ name: String) throws -> String {
        let root = folder.appending(path: name)
        try FileManager.default.createDirectory(at: root.appending(path: "MUSICIANS"), withIntermediateDirectories: true)
        return root.path
    }

    private func makeStore(own: String?) -> PlayerStore {
        PlayerStore(defaults: defaults, defaultHvscRoot: own) { _ in fake }
    }

    // MARK: HVSC folder

    @Test func aChosenFolderStillWins() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        defaults.set("/Music/C64", forKey: Pref.hvscRoot)
        let store = makeStore(own: try collection("Resonance"))
        #expect(store.hvscRoot == "/Music/C64")
    }

    // MARK: Reset

    @Test func trashesOnlyTheCollectionDownloadedHere() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let own = try collection("Resonance")
        let store = makeStore(own: own)
        #expect(store.collectionIsDownloadedHere)

        var trashed: [URL] = []
        try await store.trashDownloadedCollection { trashed.append($0) }
        #expect(trashed == [URL(filePath: own)])
        #expect(fake.calls.contains("reloadHvsc"))
    }

    @Test func neverTrashesAnotherFolder() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore(own: folder.appending(path: "Resonance").path)
        store.hvscRoot = try collection("Phosphor")
        #expect(!store.collectionIsDownloadedHere)

        var trashed: [URL] = []
        try await store.trashDownloadedCollection { trashed.append($0) }
        #expect(trashed.isEmpty)
    }

    @Test func stopsADownloadBeforeTrashing() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let own = try collection("Resonance")
        let store = makeStore(own: own)
        fake.set(sync: HvscSyncStatus(root: own, running: true, error: nil, current: "",
                                      filesDone: 1, filesTotal: 10, bytesDone: 0, bytesTotal: 0))
        // The fake keeps "running", so this also covers the wait giving up.
        try await store.trashDownloadedCollection { _ in }
        #expect(fake.calls.contains("syncCancel"))
    }

    @Test func shutsDownOnce() {
        let store = makeStore(own: nil)
        store.shutdown()
        store.shutdown()
        #expect(fake.calls.filter { $0 == "shutdown" }.count == 1)
    }
}
