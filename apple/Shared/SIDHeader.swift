import Foundation

/// What a SID file says about itself, from its PSID or RSID header
/// (HVSC's SID_file_format.txt). Shared with the Quick Look extension, which
/// can't load the core and only needs the first bytes.
nonisolated struct SIDHeader: Equatable, Sendable {
    /// Every field read here is within this many bytes of the start.
    static let length = 124

    enum Model: Equatable, Sendable {
        case mos6581, mos8580, both

        var name: String {
            switch self {
            case .mos6581: "MOS 6581"
            case .mos8580: "MOS 8580"
            case .both: "MOS 6581 and 8580"
            }
        }
    }

    enum Clock: Equatable, Sendable {
        case pal, ntsc, both

        var name: String {
            switch self {
            case .pal: "PAL"
            case .ntsc: "NTSC"
            case .both: "PAL and NTSC"
            }
        }
    }

    /// RSID tunes need the C64's real environment to play.
    let isRSID: Bool
    let title: String
    let author: String
    let released: String
    let songs: Int
    let model: Model?
    let clock: Clock?
    /// How many SID chips it plays on.
    let chips: Int

    /// Nil when `data` doesn't start with a PSID or RSID header.
    init?(_ data: Data) {
        let bytes = [UInt8](data.prefix(Self.length))
        guard bytes.count >= 118 else { return nil }
        let magic = String(decoding: bytes[0..<4], as: UTF8.self)
        guard magic == "PSID" || magic == "RSID" else { return nil }
        isRSID = magic == "RSID"

        func word(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        func text(_ at: Int) -> String {
            let field = bytes[at..<at + 32].prefix { $0 != 0 }
            return (String(bytes: field, encoding: .windowsCP1252) ?? "")
                .trimmingCharacters(in: .whitespaces)
        }
        let version = word(4)
        songs = word(14)
        title = text(22)
        author = text(54)
        released = text(86)

        // The rest came in with version 2.
        guard version >= 2, bytes.count >= Self.length else {
            model = nil
            clock = nil
            chips = 1
            return
        }
        let flags = word(118)
        clock = switch (flags >> 2) & 3 {
        case 1: .pal
        case 2: .ntsc
        case 3: .both
        default: nil
        }
        model = switch (flags >> 4) & 3 {
        case 1: .mos6581
        case 2: .mos8580
        case 3: .both
        default: nil
        }
        chips = 1 + (version >= 3 && bytes[122] != 0 ? 1 : 0) + (version >= 4 && bytes[123] != 0 ? 1 : 0)
    }

    /// "3 subtunes", "MOS 6581", "PAL", "2 SIDs", "RSID": what's worth saying,
    /// in that order.
    var facts: [String] {
        var facts = [songs == 1 ? "1 tune" : "\(songs) subtunes"]
        if let model { facts.append(model.name) }
        if let clock { facts.append(clock.name) }
        if chips > 1 { facts.append("\(chips) SIDs") }
        if isRSID { facts.append("RSID") }
        return facts
    }
}
