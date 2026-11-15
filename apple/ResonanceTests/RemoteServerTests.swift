import CryptoKit
import Foundation
import Testing
@testable import Resonance

struct RemoteServerTests {
    private let root = "/Users/someone/HVSC"

    @Test func pathsInsideTheCollectionAreAllowed() {
        #expect(RemoteServer.pathsAllowed(["\(root)/MUSICIANS/H/Hubbard_Rob/Commando.sid"], root: root, myPlaylist: []))
        #expect(RemoteServer.pathsAllowed(["\(root)/MUSICIANS/H/Hubbard_Rob"], root: root + "/", myPlaylist: []))
        #expect(RemoteServer.pathsAllowed([], root: nil, myPlaylist: []))
    }

    @Test func pathsOutsideTheCollectionAreRefused() {
        #expect(!RemoteServer.pathsAllowed(["/etc/passwd"], root: root, myPlaylist: []))
        #expect(!RemoteServer.pathsAllowed(["\(root)/../secret.sid"], root: root, myPlaylist: []))
        // A sibling folder whose name starts the same.
        #expect(!RemoteServer.pathsAllowed(["\(root)-private/tune.sid"], root: root, myPlaylist: []))
        #expect(!RemoteServer.pathsAllowed(["MUSICIANS/tune.sid"], root: root, myPlaylist: []))
        #expect(!RemoteServer.pathsAllowed(["/tmp/tune.sid"], root: nil, myPlaylist: []))
    }

    @Test func tunesInMyPlaylistAreAllowed() {
        #expect(RemoteServer.pathsAllowed(["/Users/someone/Desktop/new.sid"], root: root, myPlaylist: ["/Users/someone/Desktop/new.sid"]))
    }

    /// A tune of the person's own in Favorites or a playlist plays; a file
    /// next to it that no list has doesn't.
    @Test func listedTunesOutsideTheCollectionAreAllowedOthersAreNot() {
        let listed: Set<String> = ["/Users/someone/Music/Jarre_En_Sync.sid"]
        #expect(RemoteServer.pathsAllowed(["/Users/someone/Music/Jarre_En_Sync.sid"], root: root, myPlaylist: listed))
        #expect(!RemoteServer.pathsAllowed(["/Users/someone/Music/Other.sid"], root: root, myPlaylist: listed))
    }

    /// The phone derives the same key from the same digits, and only for this Mac.
    @Test func theCodeKeyDependsOnTheCodeAndTheMac() {
        let key = RemoteServer.codeKey(code: "4819", macID: "28W7VQ6C")
        #expect(key.count == 32)
        #expect(key == RemoteServer.codeKey(code: "4819", macID: "28W7VQ6C"))
        #expect(key != RemoteServer.codeKey(code: "4818", macID: "28W7VQ6C"))
        #expect(key != RemoteServer.codeKey(code: "4819", macID: "28W7VQ6D"))
    }

    @Test func aProofNeedsTheKeyAndTheSession() {
        let key = RemoteServer.randomKey()
        let exporter = Data((0..<32).map { UInt8($0) })
        let proof = Data(HMAC<SHA256>.authenticationCode(for: exporter, using: SymmetricKey(data: key))).base64EncodedString()
        #expect(RemoteServer.proves(proof, key: key, exporter: exporter))
        #expect(!RemoteServer.proves(proof, key: RemoteServer.randomKey(), exporter: exporter))
        #expect(!RemoteServer.proves(proof, key: key, exporter: Data(exporter.reversed())))
        #expect(!RemoteServer.proves(proof, key: key, exporter: nil))
        #expect(!RemoteServer.proves("not base64", key: key, exporter: exporter))
    }

    /// The phone computes the same number; PROTOCOL.md has the recipe. The
    /// expected value is from Python's hmac, as a second implementation.
    @Test func theCheckNumberNeedsTheSessionAndBothSidesBytes() {
        let exporter = Data((0..<32).map { UInt8($0) })
        let device = Data(repeating: 1, count: 32), mac = Data(repeating: 2, count: 32)
        #expect(RemoteServer.checkNumber(exporter: exporter, device: device, mac: mac) == "838 349")
        #expect(RemoteServer.checkNumber(exporter: Data(exporter.reversed()), device: device, mac: mac) != "838 349")
        #expect(RemoteServer.checkNumber(exporter: exporter, device: mac, mac: device) != "838 349")
    }

    /// A NUL ends the path where `open` reads it, so it mustn't pass.
    @Test func controlCharactersInAPathAreRefused() {
        #expect(!RemoteServer.pathsAllowed(["/etc/hosts\u{0}/../..\(root)/a.sid"], root: root, myPlaylist: []))
        #expect(!RemoteServer.pathsAllowed(["\(root)/a\nb.sid"], root: root, myPlaylist: []))
    }

    @Test func aLinkOutOfTheCollectionIsRefused() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "remote-links-\(UUID().uuidString)")
        let collection = folder.appending(path: "HVSC")
        try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(at: collection.appending(path: "out"), withDestinationURL: folder)
        #expect(!RemoteServer.pathsAllowed([collection.appending(path: "out/secret.sid").path], root: collection.path, myPlaylist: []))
        #expect(RemoteServer.pathsAllowed([collection.appending(path: "in.sid").path], root: collection.path, myPlaylist: []))
    }

    /// The name is shown in the Allow prompt.
    @Test func aDeviceNameLosesControlCharacters() {
        #expect(RemoteServer.name("Erik's\niPhone\u{202E}", kind: "iPhone") == "Erik'siPhone")
        #expect(RemoteServer.name("\u{0}\u{7}", kind: "iPad") == "iPad")
        #expect(RemoteServer.name(String(repeating: "a", count: 100), kind: nil).count == 64)
    }

    /// The Mac remembers removed installs by this ID, and shows nothing of it.
    @Test func anInstallIDIsShortAndPlain() {
        #expect(RemoteServer.install("3F2A9C1E-7B4D-4E0A-9F1C-2D8E6B5A4C3B") == "3F2A9C1E-7B4D-4E0A-9F1C-2D8E6B5A4C3B")
        #expect(RemoteServer.install(nil) == nil)
        #expect(RemoteServer.install("") == nil)
        #expect(RemoteServer.install(String(repeating: "a", count: 65)) == nil)
        #expect(RemoteServer.install("a\nb") == nil)
        #expect(RemoteServer.install("ä") == nil)
    }

    /// A build without the keychain group (no provisioning profile) says so,
    /// rather than claiming there's no key and making one it can't keep.
    @Test func aBuildWithoutTheGroupCantKeepTheAccountKey() {
        if case .found = RemoteAccountKey.load(macID: "TESTMAC0") { Issue.record("a test build read the shared group") }
    }

    /// `prefix` traps on a negative count.
    @Test func listLengthsFromOutsideStayInRange() {
        #expect(ControlCommands.limit(-1, or: 50) == 0)
        #expect(ControlCommands.limit(nil, or: 50) == 50)
        #expect(ControlCommands.limit(1_000_000, or: 50) == 500)
    }

    /// Measured on the listener: only a wrong key counts toward the lockout.
    @Test func onlyAWrongKeyCountsAsAWrongCode() {
        #expect(RemoteServer.isWrongKey(.tls(-9846)))
        #expect(!RemoteServer.isWrongKey(.tls(-9864)))  // Unknown identity: a removed device.
        #expect(!RemoteServer.isWrongKey(.tls(-9816)))  // Never spoke TLS.
        #expect(!RemoteServer.isWrongKey(.posix(.ECONNRESET)))
    }

    @Test func thePairingLinkCarriesTheMacAndTheKey() throws {
        let key = Data(repeating: 0xFB, count: 32)
        let url = RemoteServer.pairURL(macID: "28W7VQ6C", key: key)
        #expect(url.scheme == "resonance-remote")
        #expect(url.host() == "pair")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "mac" }?.value == "28W7VQ6C")
        let encoded = try #require(items.first { $0.name == "key" }?.value)
        #expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="))
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        #expect(Data(base64Encoded: base64) == key)
    }

    @Test func secretsAreRandomAndTheRightSize() {
        #expect(RemoteServer.randomKey().count == 32)
        #expect(RemoteServer.randomKey() != RemoteServer.randomKey())
        #expect(RemoteServer.randomCode().count == 4)
        let code = RemoteServer.randomCode()
        #expect(code.allSatisfy { $0.isNumber })
        #expect(RemoteServer.randomID(length: 10).count == 10)
    }

    /// Deleting playlists or opening files stays on the Mac.
    @Test func theNetworkCantReshapePlaylists() {
        for cmd in ["playlist.delete", "playlist.rename", "playlist.rm", "playlist.mv", "playlist.new", "show", "prints"] {
            #expect(!RemoteServer.allowed.contains(cmd))
        }
        #expect(RemoteServer.allowed.contains("play"))
    }
}
