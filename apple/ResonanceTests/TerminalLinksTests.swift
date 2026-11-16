import Foundation
import PhosphorCore
import Testing
@testable import Resonance

/// A shared link handed to the terminal app while headless: it waits in
/// `status`, and `link.answer` plays it, adds it or lets it go.
@MainActor
@Suite(.serialized)
final class TerminalLinksTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "links-\(UUID().uuidString)")
    private let suite = "links-tests-\(UUID().uuidString)"
    private let fake = FakeCore()
    private let player: PlayerStore
    private let links = TerminalLinks(gone: .milliseconds(60))
    private let commands: ControlCommands
    private let link = SharedTuneLink(key: "6d019ecba831a9f853675aac29a61c10", subtune: nil, title: "Commando", author: "Rob Hubbard")
    private let tune = "/hvsc/MUSICIANS/H/Hubbard_Rob/Commando.sid"

    init() {
        // A folder that passes for a collection.
        try? FileManager.default.createDirectory(at: folder.appending(path: "MUSICIANS"), withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: suite)!
        let fake = fake
        player = PlayerStore(defaults: defaults, defaultHvscRoot: folder.path) { _ in fake }
        let playlists = PlaylistsStore(player: player, folder: folder, defaults: defaults)
        commands = ControlCommands(player: player, library: LibraryStore(player: player),
                                   fingerprints: FingerprintStore(player: player, defaults: defaults), playlists: playlists,
                                   links: links)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func ask(_ cmd: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        let line = try JSONSerialization.data(withJSONObject: ["id": 1, "cmd": cmd, "args": args])
        let reply = await commands.handle(line)
        return try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    /// What `status` says is waiting, as the terminal app asks.
    private func waitingLink() async throws -> [String: Any]? {
        let reply = try await ask("status", ["links": true])
        return (reply["result"] as? [String: Any])?["link"] as? [String: Any]
    }

    /// Offer the link with the terminal app watching, and wait until it's held.
    private func offer(found: Bool = true, unanswered: @escaping (SharedTuneLink) -> Void = { _ in }) async throws -> Task<Void, Never> {
        fake.set(sharedMatch: SharedTuneMatch(path: found ? tune : nil, sameFile: found, installedHvsc: 85))
        _ = try await waitingLink()
        let offering = Task { await links.offer(link, player: player, unanswered: unanswered) }
        while links.waiting == nil { await Task.yield() }
        return offering
    }

    @Test func onlyTheTerminalAppsStatusMakesItWatched() async throws {
        _ = try await ask("status")
        #expect(!links.isWatched)
        _ = try await ask("status", ["links": true])
        #expect(links.isWatched)
        #expect(!links.hasGone)
        try await Task.sleep(for: .milliseconds(120))
        #expect(!links.isWatched)
        #expect(links.hasGone)
    }

    @Test func aTerminalAppNeverSeenHasNotGone() {
        #expect(!links.hasGone)
    }

    @Test func theTerminalAppClosingLeavesAnAppWithItsWindowRunning() async throws {
        // Only a headless app quits with it; the test host isn't one.
        let reply = try await ask("terminal.closed")
        #expect(reply["ok"] as? Bool == true)
    }

    @Test func aLinkWaitsInTheTerminalAppsStatusOnly() async throws {
        let offering = try await offer()
        let waiting = try #require(try await waitingLink())
        #expect(waiting["title"] as? String == "Commando")
        #expect(waiting["author"] as? String == "Rob Hubbard")
        #expect(waiting["problem"] == nil)
        // Resonance Remote and `resonance now` get the same status without it.
        let plain = try await ask("status")
        #expect((plain["result"] as? [String: Any])?["link"] == nil)
        offering.cancel()
    }

    @Test func playAnswersByPlayingTheTune() async throws {
        let offering = try await offer()
        let id = try #require(links.waiting?.offer.id)
        let reply = try await ask("link.answer", ["link": id, "choice": "play"])
        #expect(reply["ok"] as? Bool == true)
        #expect(fake.calls.contains("queue [\"\(tune)\"] from \(tune)"))
        #expect(try await waitingLink() == nil)
        await offering.value
    }

    @Test func addAnswersByAddingToMyPlaylist() async throws {
        let offering = try await offer()
        let id = try #require(links.waiting?.offer.id)
        _ = try await ask("link.answer", ["link": id, "choice": "add"])
        #expect(fake.calls.contains("add [\"\(tune)\"] false"))
        #expect(!fake.calls.contains { $0.hasPrefix("queue") })
        await offering.value
    }

    @Test func declineLetsItGoAndASecondAnswerFails() async throws {
        let offering = try await offer()
        let id = try #require(links.waiting?.offer.id)
        let reply = try await ask("link.answer", ["link": id, "choice": "decline"])
        #expect(reply["ok"] as? Bool == true)
        #expect(!fake.calls.contains { $0.hasPrefix("queue") || $0.hasPrefix("add") })
        let again = try await ask("link.answer", ["link": id, "choice": "play"])
        #expect(again["ok"] as? Bool == false)
        await offering.value
    }

    @Test func aTuneThisCollectionLacksSaysWhy() async throws {
        let offering = try await offer(found: false)
        let waiting = try #require(try await waitingLink())
        #expect((waiting["problem"] as? String)?.contains("doesn't have this tune") == true)
        let id = try #require(links.waiting?.offer.id)
        let reply = try await ask("link.answer", ["link": id, "choice": "play"])
        #expect(reply["ok"] as? Bool == false)
        await offering.value
    }

    @Test func aTerminalAppThatClosedHandsTheLinkBack() async throws {
        var handedBack: SharedTuneLink?
        let offering = try await offer { handedBack = $0 }
        // No more `status` from the terminal app: it has gone.
        await offering.value
        #expect(handedBack == link)
        #expect(links.waiting == nil)
    }
}
