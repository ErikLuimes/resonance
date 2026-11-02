import Foundation
import STILKit

nonisolated extension STILEntry {
    /// The entry an excerpt of STIL.txt is about, ready to show. The core
    /// hands over the entry after those of the folders it's in, which
    /// declare whose initials sign its comments. `sidAuthor` is the tune
    /// header's author, which tells whose voice a quote is in.
    static func parsing(_ excerpt: String, sidAuthor: String?) -> STILEntry? {
        let entries = STILParser.parse(excerpt)
        guard let path = excerpt.split(separator: "\n").last(where: { $0.hasPrefix("/") })
            .map({ $0.trimmingCharacters(in: .whitespaces) }),
            let raw = entries[path]
        else { return nil }
        let initials = STILEnricher.initials(for: path, in: STILEnricher.initialsIndex(entries))
        return STILEnricher.entry(raw, sidAuthor: sidAuthor, initials: initials)
    }

    /// Every tune the entry's comments link to.
    var links: Set<String> {
        Set(sections.flatMap { $0.comments.flatMap(\.links) })
    }
}

/// A tune STIL links to, as its SID header names it.
nonisolated struct LinkedTune: Equatable, Sendable {
    let title: String
    let author: String

    /// The title and author in a PSID or RSID header: two 32-byte Latin-1
    /// fields at 0x16 and 0x36. Nil when the file can't be read.
    @concurrent static func read(_ file: URL) async -> LinkedTune? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 0x56), header.count == 0x56,
              ["PSID", "RSID"].contains(String(decoding: header.prefix(4), as: UTF8.self))
        else { return nil }
        func field(_ offset: Int) -> String {
            let bytes = header[offset..<offset + 32].prefix { $0 != 0 }
            return (String(data: Data(bytes), encoding: .isoLatin1) ?? "").trimmingCharacters(in: .whitespaces)
        }
        return LinkedTune(title: field(0x16), author: field(0x36))
    }

    /// What to call a linked tune before (or without) its header: its file
    /// name, "Get_Ready.sid" → "Get Ready".
    static func fallbackTitle(_ hvscPath: String) -> String {
        URL(filePath: hvscPath).deletingPathExtension().lastPathComponent.replacing("_", with: " ")
    }
}
