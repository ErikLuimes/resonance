import CoreSpotlight
import Foundation
import PhosphorCore
import Testing
@testable import Resonance

private func tune(_ path: String = "/hvsc/MUSICIANS/H/Hubbard_Rob/Commando.sid", title: String = "Commando",
                  author: String = "Hubbard, Rob", released: String = "1985 Elite",
                  category: HvscCategory = .musicians) -> HvscTuneItem {
    HvscTuneItem(path: path, title: title, author: author, released: released, songs: 1, startSong: 1,
                 durationSecs: nil, hasStil: false, isRsid: nil, category: category)
}

struct SpotlightTunesTests {
    @Test func aMusiciansTuneNamesItsComposerAsSpoken() {
        let attributes = SpotlightTunes.attributes(tune())
        #expect(attributes.title == "Commando")
        #expect(attributes.artist == "Rob Hubbard")
        #expect(attributes.contentDescription == "Rob Hubbard · 1985 Elite")
        #expect(attributes.keywords?.contains("Rob Hubbard") == true)
    }

    /// GAMES and DEMOS file by letter: "0-9" isn't anyone.
    @Test func aGamesFolderIsntAComposer() {
        let attributes = SpotlightTunes.attributes(tune(author: "0-9", category: .games))
        #expect(attributes.artist == nil)
        #expect(attributes.contentDescription == "1985 Elite")
    }

    @Test func aSingleNameStaysAsItIs() {
        #expect(SpotlightTunes.composer(of: tune(author: "Laxity")) == "Laxity")
    }

    @Test func theItemIsFoundByItsPath() {
        let item = SpotlightTunes.item(tune())
        #expect(item.uniqueIdentifier == "/hvsc/MUSICIANS/H/Hubbard_Rob/Commando.sid")
        #expect(item.domainIdentifier == SpotlightTunes.domain)
    }

    @Test func aClickGivesTheTune() {
        let click = NSUserActivity(activityType: CSSearchableItemActionType)
        click.userInfo = [CSSearchableItemActivityIdentifier: "/hvsc/a.sid"]
        #expect(SpotlightTunes.path(from: click) == "/hvsc/a.sid")
        let other = NSUserActivity(activityType: "other")
        other.userInfo = [CSSearchableItemActivityIdentifier: "/hvsc/a.sid"]
        #expect(SpotlightTunes.path(from: other) == nil)
    }
}

@MainActor
@Suite(.serialized)
final class SpotlightIndexTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "spotlight-\(UUID().uuidString)")
    private let defaults: UserDefaults
    private let suite = "spotlight-tests-\(UUID().uuidString)"
    private let fake = FakeCore()
    private let log = Log()

    /// What reached Spotlight.
    private nonisolated final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _deletes = 0
        private var _added: [[String]] = []
        var deletes: Int { lock.withLock { _deletes } }
        var added: [[String]] { lock.withLock { _added } }
        var failing = false

        func delete() { lock.withLock { _deletes += 1 } }
        func add(_ ids: [String]) { lock.withLock { _added.append(ids) } }
    }

    init() {
        defaults = UserDefaults(suiteName: suite)!
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func index(root: String?) -> SpotlightIndex {
        let store = PlayerStore(defaults: defaults, defaultHvscRoot: root) { [fake] _ in fake }
        let log = log
        return SpotlightIndex(store: store, defaults: defaults, backend: .init(
            deleteAll: { log.delete() },
            add: { items in
                if log.failing { throw CocoaError(.fileWriteUnknown) }
                log.add(items.map(\.uniqueIdentifier))
            }))
    }

    private func collection() throws -> String {
        try FileManager.default.createDirectory(at: folder.appending(path: "MUSICIANS"), withIntermediateDirectories: true)
        return folder.path
    }

    private func tunes(_ count: Int) -> [HvscTuneItem] {
        (0..<count).map { tune("/hvsc/\($0).sid") }
    }

    @Test func indexesEveryTuneInBatches() async throws {
        fake.set(allTunes: tunes(SpotlightTunes.batch + 1))
        await index(root: try collection()).refresh()
        #expect(log.deletes == 1)
        #expect(log.added.map(\.count) == [SpotlightTunes.batch, 1])
    }

    @Test func anUnchangedCollectionIsLeftAlone() async throws {
        fake.set(allTunes: tunes(3))
        let index = index(root: try collection())
        await index.refresh()
        await index.refresh()
        #expect(log.added.count == 1)
        #expect(log.deletes == 1)
    }

    /// A new HVSC release has another number of tunes.
    @Test func aChangedCollectionIsDoneAgain() async throws {
        fake.set(allTunes: tunes(3))
        let index = index(root: try collection())
        await index.refresh()
        fake.set(allTunes: tunes(4))
        await index.refresh()
        #expect(log.added.map(\.count) == [3, 4])
    }

    @Test func aFailureIsTriedAgainNextTime() async throws {
        fake.set(allTunes: tunes(3))
        let index = index(root: try collection())
        log.failing = true
        await index.refresh()
        log.failing = false
        await index.refresh()
        #expect(log.added.map(\.count) == [3])
    }

    @Test func aRemovedCollectionLeavesSpotlight() async throws {
        fake.set(allTunes: tunes(3))
        let root = try collection()
        await index(root: root).refresh()
        try FileManager.default.removeItem(at: folder)
        await index(root: root).refresh()
        #expect(log.deletes == 2)
        #expect(defaults.string(forKey: Pref.spotlightIndexed) == nil)
    }

    @Test func waitsForADownloadToFinish() async throws {
        fake.set(allTunes: tunes(3))
        let root = try collection()
        fake.set(sync: HvscSyncStatus(root: root, running: true, error: nil, current: "",
                                      filesDone: 0, filesTotal: 0, bytesDone: 0, bytesTotal: 0))
        let index = index(root: root)
        await index.refresh()
        #expect(log.added.isEmpty)
    }
}
