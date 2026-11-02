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

/// Someone STIL remembers, from its "Sadly, NAME passed away on …"
/// sentence (63 of them in v85, 53 in musicians' folder notes).
nonisolated struct STILMemorial: Equatable, Sendable {
    /// "Ben Daglish", "Andrzej Sielicki (ASL)".
    let name: String
    /// The rest of the sentence: "On October 1st, 2018, at the age of 52,
    /// due to complications from lung cancer." Nil when it says no more.
    let details: String?

    /// "Sadly, NAME (has) passed away…" up to the sentence's end: a period,
    /// "!" or "?" before a capital (or the end), so initials in the name
    /// ("Scott T. Etherton") don't end it.
    static let sentenceRx = try! NSRegularExpression(
        pattern: #"Sadly, (?<name>\p{Lu}[^,]{1,59}?) (?:has )?passed away\b(?<rest>.*?[.!?])(?=\s+[A-Z\x{201C}"(]|\s*$)"#)

    /// The memorial in `text` and the range of its sentence, if there's one.
    static func find(in text: String) -> (STILMemorial, NSRange)? {
        let ns = text as NSString
        guard let m = sentenceRx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let name = ns.substring(with: m.range(withName: "name")).trimmingCharacters(in: .whitespaces)
        var rest = ns.substring(with: m.range(withName: "rest"))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        if rest == "." || rest.isEmpty {
            rest = ""
        } else {
            rest = rest.prefix(1).uppercased() + rest.dropFirst()
        }
        return (STILMemorial(name: name, details: rest.isEmpty ? nil : rest), m.range)
    }
}

nonisolated extension STILComment {
    /// The memorial a note in this comment holds, and the comment without
    /// its sentence (nil when nothing else is left). Other comments STIL
    /// flags `memoriam` ("Since Anthony passed away, we can't verify it")
    /// aren't memorials and stay as they are.
    func splittingMemorial() -> (memorial: STILMemorial?, rest: STILComment?) {
        for (b, block) in blocks.enumerated() where block.kind == .note {
            for (p, runs) in block.paragraphs.enumerated() {
                let text = runs.map(\.t).joined()
                guard let (memorial, range) = STILMemorial.find(in: text) else { continue }
                var comment = self
                comment.memoriam = false
                let left = Self.cutting(runs, range)
                if left.allSatisfy({ $0.t.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    comment.blocks[b].paragraphs.remove(at: p)
                } else {
                    comment.blocks[b].paragraphs[p] = left
                }
                comment.blocks = comment.blocks.filter { !$0.paragraphs.isEmpty }
                return (memorial, comment.blocks.isEmpty ? nil : comment)
            }
        }
        return (nil, self)
    }

    /// `runs` without the UTF-16 `range` of their joined text (and the
    /// spaces after it), each run keeping its own style.
    private static func cutting(_ runs: [STILRun], _ range: NSRange) -> [STILRun] {
        let joined = runs.map(\.t).joined() as NSString
        var end = range.location + range.length
        while end < joined.length, joined.character(at: end) == 0x20 { end += 1 }
        var out: [STILRun] = []
        var offset = 0
        for run in runs {
            let t = run.t as NSString
            let start = offset, stop = offset + t.length
            offset = stop
            var kept = ""
            if start < range.location { kept += t.substring(to: min(t.length, range.location - start)) }
            if stop > end { kept += t.substring(from: max(0, end - start)) }
            if !kept.isEmpty {
                var piece = run
                piece.t = kept
                out.append(piece)
            }
        }
        if var last = out.popLast() {
            last.t = last.t.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            if !last.t.isEmpty { out.append(last) }
        }
        return out
    }
}

nonisolated extension STILEntry {
    /// The entry's memorials, and the entry without their sentences.
    func splittingMemorials() -> (memorials: [STILMemorial], rest: STILEntry) {
        var memorials: [STILMemorial] = []
        var rest = self
        for s in rest.sections.indices {
            rest.sections[s].comments = rest.sections[s].comments.compactMap { comment in
                let (memorial, left) = comment.splittingMemorial()
                if let memorial, !memorials.contains(memorial) { memorials.append(memorial) }
                return left
            }
        }
        return (memorials, rest)
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
