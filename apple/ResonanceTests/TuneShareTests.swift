import Foundation
import Testing
import PhosphorCore
@testable import Resonance

struct SharedTuneLinkTests {
    let md5 = "6d019ecba831a9f853675aac29a61c10"
    let base = URL(string: "https://share.example")!

    @Test func readsTheAppsOwnLink() throws {
        let url = URL(string: "resonance://tune/6D019ECBA831A9F853675AAC29A61C10?s=2&v=85&p=/MUSICIANS/H/Hubbard_Rob/Commando%20%26%20Co.sid&t=Commando&a=Rob%20Hubbard")!
        let link = try #require(SharedTuneLink(url: url, shareBase: nil))
        #expect(link.key == md5)
        #expect(link.subtune == 2)
        #expect(link.hvsc == 85)
        #expect(link.hvscPath == "/MUSICIANS/H/Hubbard_Rob/Commando & Co.sid")
        #expect(link.name == "Commando — Rob Hubbard")
    }

    @Test func readsTheWebLinkOnlyFromTheShareServer() {
        let web = URL(string: "https://share.example/t/\(md5)?s=3")!
        #expect(SharedTuneLink(url: web, shareBase: base) == SharedTuneLink(key: md5, subtune: 3))
        #expect(SharedTuneLink(url: web, shareBase: URL(string: "https://elsewhere.example")!) == nil)
        #expect(SharedTuneLink(url: URL(string: "https://share.example/x/\(md5)")!, shareBase: base) == nil)
        // A server under a path.
        let nested = URL(string: "https://example.org/resonance")!
        #expect(SharedTuneLink(url: URL(string: "https://example.org/resonance/t/\(md5)")!, shareBase: nested)?.key == md5)
    }

    @Test func rejectsWhatIsntATuneLink() {
        #expect(SharedTuneLink(url: URL(string: "resonance://tune/nothex")!, shareBase: nil) == nil)
        #expect(SharedTuneLink(url: URL(string: "resonance://other/\(md5)")!, shareBase: nil) == nil)
        #expect(SharedTuneLink(url: URL(filePath: "/HVSC/Commando.sid"), shareBase: base) == nil)
        // A path that climbs out of the collection is dropped, the rest kept.
        let climbing = SharedTuneLink(url: URL(string: "resonance://tune/\(md5)?p=/MUSICIANS/../../etc&s=0")!, shareBase: nil)
        #expect(climbing?.hvscPath == nil)
        #expect(climbing?.subtune == nil)
    }

    @Test func makesWebLinksWithTheShareCode() {
        let link = SharedTuneLink(key: md5, subtune: 2, hvsc: 85)
        let url = link.webURL(base: base)
        #expect(url.absoluteString == "https://share.example/t/bQGey6gxqfhT?s=2&v=85")
        // Read back, the code is the key the core looks up.
        #expect(SharedTuneLink(url: url, shareBase: base) == SharedTuneLink(key: "bQGey6gxqfhT", subtune: 2, hvsc: 85))
        #expect(SharedTuneLink(key: md5).webURL(base: base).absoluteString == "https://share.example/t/bQGey6gxqfhT")
    }

    @Test func shareCodesMatchTheServersAndTheCores() {
        // The same examples as share-server/src/tune.rs and core/src/share.rs.
        #expect(SharedTuneLink.shortCode(md5: md5) == "bQGey6gxqfhT")
        #expect(SharedTuneLink.shortCode(md5: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF") == "____________")
        #expect(SharedTuneLink.shortCode(md5: "bQGey6gxqfhT") == nil)
    }

    @Test func readsShareCodesCaseSensitively() throws {
        let link = try #require(SharedTuneLink(url: URL(string: "https://share.example/t/bQGey6gxqfhT")!, shareBase: base))
        #expect(link.key == "bQGey6gxqfhT")
        #expect(SharedTuneLink(url: URL(string: "https://share.example/t/bQGey6gxqf")!, shareBase: base) == nil, "too short")
        #expect(SharedTuneLink(url: URL(string: "https://share.example/t/bQGey6gxqf.T")!, shareBase: base) == nil)
    }

    @Test func theShareServerSettingNeedsAWebAddress() {
        #expect(SharedTuneLink.base("") == nil)
        #expect(SharedTuneLink.base(nil) == nil)
        #expect(SharedTuneLink.base("ftp://x.example") == nil)
        #expect(SharedTuneLink.base("https://share.example/")?.absoluteString == "https://share.example")
    }
}

struct SharedTuneOutcomeTests {
    private func match(_ path: String?, sameFile: Bool = true, installed: UInt32? = 85) -> SharedTuneMatch {
        SharedTuneMatch(path: path, sameFile: sameFile, installedHvsc: installed)
    }

    private func decide(_ match: SharedTuneMatch, collection: Bool = true, sender: Int?, latest: Int?) -> SharedTuneOutcome {
        SharedTuneOutcome.decide(match: match, hasCollection: collection, senderHvsc: sender, latestHvsc: latest)
    }

    @Test func sameReleasePlays() {
        #expect(decide(match("/HVSC/a.sid"), sender: 85, latest: 85) == .play(path: "/HVSC/a.sid", sameFile: true, offerUpdate: nil))
    }

    @Test func olderReleaseWithTheTunePlaysAndOffersTheUpdate() {
        #expect(decide(match("/HVSC/a.sid", installed: 83), sender: 85, latest: 86) == .play(path: "/HVSC/a.sid", sameFile: true, offerUpdate: 86))
        #expect(decide(match("/HVSC/a.sid", sameFile: false, installed: 83), sender: 85, latest: nil) == .play(path: "/HVSC/a.sid", sameFile: false, offerUpdate: 85))
    }

    @Test func olderReleaseWithoutTheTuneOffersTheUpdate() {
        #expect(decide(match(nil, installed: 83), sender: 85, latest: 85) == .update(to: 85))
        // Sent without a release: the update may still have it.
        #expect(decide(match(nil, installed: 83), sender: nil, latest: 85) == .update(to: 85))
    }

    @Test func aReleaseNewerThanAnyKnownAsksToCheck() {
        #expect(decide(match(nil, installed: 85), sender: 86, latest: nil) == .checkForUpdate(senderHvsc: 86))
        #expect(decide(match(nil, installed: 85), sender: 86, latest: 85) == .checkForUpdate(senderHvsc: 86))
    }

    @Test func noCollectionOffersTheDownload() {
        #expect(decide(match(nil, installed: nil), collection: false, sender: 85, latest: 85) == .download)
    }

    @Test func missingFromTheNewestReleaseIsNotFound() {
        #expect(decide(match(nil, installed: 85), sender: 85, latest: 85) == .notFound)
        #expect(decide(match(nil, installed: 85), sender: nil, latest: nil) == .notFound)
    }
}

@MainActor
struct PlayerStoreSharingTests {
    let defaults: UserDefaults
    let fake = FakeCore()

    init() {
        let suite = "ResonanceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeStore(root: String?) -> PlayerStore {
        PlayerStore(defaults: defaults, phosphorHvscRoot: { root }, defaultHvscRoot: root) { _ in fake }
    }

    @Test func opensOnlyTuneLinks() {
        let store = makeStore(root: nil)
        #expect(!store.openShared(URL(string: "https://example.com/")!))
        #expect(store.sharedTune == nil)
        #expect(store.openShared(URL(string: "resonance://tune/6d019ecba831a9f853675aac29a61c10?s=2")!))
        #expect(store.sharedTune?.subtune == 2)
    }

    @Test func resolvesThroughTheCore() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "MUSICIANS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root.path)
        fake.set(sharedMatch: SharedTuneMatch(path: nil, sameFile: false, installedHvsc: 85))
        await store.checkHvscUpdate() // the fake mirror has 86
        let link = SharedTuneLink(key: "6d019ecba831a9f853675aac29a61c10", hvsc: 86, hvscPath: "/MUSICIANS/x.sid")
        let (outcome, _) = await store.resolve(link)
        #expect(outcome == .update(to: 86))
        #expect(fake.calls.contains("findSharedTune 6d019ecba831a9f853675aac29a61c10 /MUSICIANS/x.sid"))
    }

    @Test func playsASharedTuneOnItsOwn() {
        let store = makeStore(root: nil)
        store.playShared(path: "/HVSC/MUSICIANS/H/Hubbard_Rob/Commando.sid", subtune: nil)
        #expect(fake.calls.last == "queue [\"/HVSC/MUSICIANS/H/Hubbard_Rob/Commando.sid\"] from /HVSC/MUSICIANS/H/Hubbard_Rob/Commando.sid")
        #expect(store.queueSource == .shared)
    }

    @Test func preparesTheWebLinkWithTheInstalledRelease() async throws {
        let base = try #require(SharedTuneLink.shareBase, "the test host is a Debug build, which shares to localhost")
        let store = makeStore(root: nil)
        let share = try #require(await store.prepareShare(path: "/HVSC/Commando.sid", subtune: 3))
        #expect(share.url == SharedTuneLink(key: "6d019ecba831a9f853675aac29a61c10", subtune: 3).webURL(base: base))
        #expect(share.title == "Commando")
        #expect(share.url.absoluteString.hasSuffix("/t/bQGey6gxqfhT?s=3"))
        #expect(await store.prepareShare(path: "/Music/notes.txt") == nil, "the core says HVSC doesn't list it")
    }

    @Test func leavesOutTheStartSong() async throws {
        let base = try #require(SharedTuneLink.shareBase)
        fake.set(filesTunes: [HvscTuneItem(
            path: "/HVSC/Commando.sid", title: "Commando", author: "Rob Hubbard", released: "1985 Elite",
            songs: 19, startSong: 1, durationSecs: 236, hasStil: true, isRsid: false, category: .musicians
        )])
        let store = makeStore(root: nil)
        let start = try #require(await store.prepareShare(path: "/HVSC/Commando.sid", subtune: 1))
        #expect(start.url == base.appending(path: "t/bQGey6gxqfhT"))
        #expect(start.subject == "Commando by Rob Hubbard")
        let other = try #require(await store.prepareShare(path: "/HVSC/Commando.sid", subtune: 2))
        #expect(other.url.absoluteString.hasSuffix("/t/bQGey6gxqfhT?s=2"))
    }
}
