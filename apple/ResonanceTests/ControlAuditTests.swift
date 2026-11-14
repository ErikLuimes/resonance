import Darwin
import Foundation
import Testing
@testable import Resonance

struct ControlAuditTests {
    private func request(_ json: String) throws -> ControlAudit.Request {
        try #require(ControlAudit.Request(Data(json.utf8)))
    }

    @Test func connectionLineSaysWhoAndWhoStartedThem() {
        let peer = ControlAudit.Peer(pid: 4512, path: "/Users/someone/.local/bin/resonance",
                                     signingID: "app.useresonance.resonance-cli", team: "ABCDE12345",
                                     parentPID: 4100, parentName: "zsh")
        #expect(ControlAudit.connectionLine(3, peer)
            == "#3 from resonance (pid 4512, app.useresonance.resonance-cli, team ABCDE12345), started by zsh (pid 4100)")
    }

    @Test func connectionLineWithoutSigningOrParent() {
        let unsigned = ControlAudit.Peer(pid: 9, path: "/tmp/nc")
        #expect(ControlAudit.connectionLine(1, unsigned) == "#1 from nc (pid 9, unsigned)")
        let adHoc = ControlAudit.Peer(pid: 9, path: nil, signingID: "nc-5555", parentPID: 1, parentName: nil)
        #expect(ControlAudit.connectionLine(2, adHoc) == "#2 from ? (pid 9, nc-5555, no team), started by ? (pid 1)")
    }

    @Test func requestLineShowsTheShapeNotTheValues() throws {
        let add = try request(#"{"id":4,"cmd":"playlist.add","args":{"name":"Secret Mix","paths":["/a.sid","/b.sid"]}}"#)
        #expect(add.changesThings)
        #expect(ControlAudit.requestLine(3, add) == "#3 playlist.add (name, paths: 2)")
        #expect(!ControlAudit.requestLine(3, add).contains("Secret"))
        #expect(add.arguments.contains("Secret Mix"))
    }

    @Test func readOnlyCommandsAreQuiet() throws {
        let search = try request(#"{"cmd":"search","args":{"text":"commando"}}"#)
        #expect(!search.changesThings)
        #expect(ControlAudit.requestLine(1, search) == "#1 search (text)")
        let status = try request(#"{"cmd":"status"}"#)
        #expect(ControlAudit.requestLine(1, status) == "#1 status")
    }

    @Test func unknownCommandsAndArgumentsStayPrivate() throws {
        let odd = try request(#"{"cmd":"/Users/someone/secret","args":{"/also/secret":1}}"#)
        #expect(odd.changesThings)
        #expect(ControlAudit.requestLine(5, odd) == "#5 unknown command (other)")
        #expect(odd.arguments.hasPrefix("/Users/someone/secret"))
        #expect(ControlAudit.Request(Data("not json".utf8)) == nil)
    }

    @Test func everyCommandIsSortedOnce() {
        #expect(ControlAudit.readOnly.isDisjoint(with: ControlAudit.changing))
    }

    @Test func findsThePeerOfALocalSocket() throws {
        var pair: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        let peer = try #require(ControlAudit.peer(of: pair[0]))
        #expect(peer.pid == getpid())
        #expect(peer.parentPID != nil)
    }
}
