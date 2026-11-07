import Foundation
import Testing
@testable import Resonance

struct SIDHeaderTests {
    /// A header as HVSC's format describes it.
    private func file(magic: String = "PSID", version: UInt8 = 2, songs: UInt8 = 3,
                      title: String = "Commando", author: String = "Rob Hubbard", released: String = "1985 Elite",
                      flags: UInt8 = 0b0001_0100, second: UInt8 = 0, third: UInt8 = 0) -> Data {
        var bytes = [UInt8](repeating: 0, count: 124)
        bytes.replaceSubrange(0..<4, with: Array(magic.utf8))
        bytes[5] = version
        bytes[15] = songs
        func put(_ text: String, _ at: Int) {
            for (i, byte) in text.data(using: .windowsCP1252)!.prefix(32).enumerated() { bytes[at + i] = byte }
        }
        put(title, 22)
        put(author, 54)
        put(released, 86)
        bytes[119] = flags
        bytes[122] = second
        bytes[123] = third
        return Data(bytes)
    }

    @Test func readsTheTextFields() throws {
        let header = try #require(SIDHeader(file()))
        #expect(header.title == "Commando")
        #expect(header.author == "Rob Hubbard")
        #expect(header.released == "1985 Elite")
        #expect(header.songs == 3)
        #expect(!header.isRSID)
    }

    /// HVSC's headers are Windows-1252, and names use it: "Søren Lund".
    @Test func readsAccentsAsWindows1252() throws {
        #expect(try #require(SIDHeader(file(author: "Søren Lund"))).author == "Søren Lund")
    }

    @Test func aFieldCanFillAllItsBytes() throws {
        let long = String(repeating: "x", count: 32)
        #expect(try #require(SIDHeader(file(title: long))).title == long)
    }

    @Test func readsTheChipAndClock() throws {
        let header = try #require(SIDHeader(file(flags: 0b0001_0100)))
        #expect(header.model == .mos6581)
        #expect(header.clock == .pal)
        let other = try #require(SIDHeader(file(flags: 0b0010_1000)))
        #expect(other.model == .mos8580)
        #expect(other.clock == .ntsc)
        let unknown = try #require(SIDHeader(file(flags: 0)))
        #expect(unknown.model == nil)
        #expect(unknown.clock == nil)
    }

    /// Version 1 ends before the flags: whatever follows is the tune's data.
    @Test func versionOneHasNoFlags() throws {
        let header = try #require(SIDHeader(file(version: 1, flags: 0b0001_0100, second: 0x42)))
        #expect(header.model == nil)
        #expect(header.chips == 1)
        #expect(SIDHeader(file(version: 1).prefix(118)) != nil)
    }

    @Test func countsExtraChipsByVersion() throws {
        #expect(try #require(SIDHeader(file(version: 2, second: 0x42))).chips == 1)
        #expect(try #require(SIDHeader(file(version: 3, second: 0x42, third: 0x50))).chips == 2)
        #expect(try #require(SIDHeader(file(version: 4, second: 0x42, third: 0x50))).chips == 3)
    }

    @Test func factsSayWhatIsWorthSaying() throws {
        #expect(try #require(SIDHeader(file())).facts == ["3 subtunes", "MOS 6581", "PAL"])
        #expect(try #require(SIDHeader(file(magic: "RSID", version: 3, songs: 1, flags: 0, second: 0x42))).facts
            == ["1 tune", "2 SIDs", "RSID"])
    }

    @Test func anythingElseIsntAHeader() {
        #expect(SIDHeader(Data()) == nil)
        #expect(SIDHeader(file().prefix(100)) == nil)
        #expect(SIDHeader(file(magic: "MThd")) == nil)
    }
}
