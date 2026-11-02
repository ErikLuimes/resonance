import Foundation

// MARK: - Raw structure (step 1: parse)

public struct STILRawField: Equatable, Sendable {
    public var key: String          // NAME | AUTHOR | TITLE | ARTIST | COMMENT | BUG
    public var lines: [String]      // text only: key / 9-space indent removed
}

public struct STILRawSection: Equatable, Sendable {
    public var subtune: Int?        // nil = whole file
    public var fields: [STILRawField] = []
}

public struct STILRawEntry: Equatable, Sendable {
    public var path: String         // "/MUSICIANS/H/Hubbard_Rob/Commando.sid" or a folder ending in "/"
    public var sections: [STILRawSection] = []
}

public enum STILParser {
    static let indent = 9
    static let fieldRx = Rx(#"^ {0,4}(NAME|AUTHOR|TITLE|ARTIST|COMMENT|BUG): ?(.*)$"#)
    static let subtuneRx = Rx(#"^\(#(\d+)\)\s*$"#)

    /// HVSC ships STIL.txt as ISO-8859-1 with CRLF. Try UTF-8 first (some
    /// redistributed copies are UTF-8), fall back to Latin-1, which never fails.
    public static func decode(_ data: Data) -> String {
        let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Parse the whole file. Keys are HVSC paths. Order of insertion is not
    /// needed by callers, so a plain dictionary is fine.
    public static func parse(_ text: String) -> [String: STILRawEntry] {
        var entries: [String: STILRawEntry] = [:]
        var curPath: String?
        var cur = STILRawEntry(path: "")
        var hasField = false   // whether the current section has an open field

        func flush() {
            if let p = curPath {
                // Drop the empty file-level section when an entry starts with (#1).
                cur.sections = cur.sections.filter { !$0.fields.isEmpty || $0.subtune != nil }
                entries[p] = cur
            }
        }

        let pad = String(repeating: " ", count: indent)
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).rstripped
            if line.isEmpty { hasField = false; continue }
            if line.hasPrefix("#") {                       // header and "### /DEMOS/ ###" dividers
                flush(); curPath = nil; hasField = false; continue
            }
            if line.hasPrefix("/") {                       // new entry
                flush()
                curPath = line.stripped
                cur = STILRawEntry(path: line.stripped, sections: [STILRawSection(subtune: nil)])
                hasField = false
                continue
            }
            guard curPath != nil else { continue }
            if let m = subtuneRx.matchPrefix(line), let n = Int(m.group(1) ?? "") {
                cur.sections.append(STILRawSection(subtune: n))
                hasField = false
                continue
            }
            if let m = fieldRx.matchPrefix(line) {
                cur.sections[cur.sections.count - 1].fields.append(
                    STILRawField(key: m.group(1) ?? "", lines: [m.group(2) ?? ""]))
                hasField = true
                continue
            }
            guard hasField else { continue }
            let s = cur.sections.count - 1
            let f = cur.sections[s].fields.count - 1
            if line.hasPrefix(pad) {
                cur.sections[s].fields[f].lines.append(String(line.dropFirst(indent)))
            } else {
                cur.sections[s].fields[f].lines.append(line.stripped)   // malformed: keep the text
            }
        }
        flush()
        return entries
    }
}

// MARK: - Step 2: reflow

public enum STILReflow {
    public static let wrapWidth = 79       // STIL is hand-wrapped to 79–80 columns
    public static let slack = 3            // tolerate sloppy hand-wrapping
    static let sentenceEnd: Set<Character> = [".", "!", "?", "\"", ")"]   // deliberately not ":"
    static let numberedRx = Rx(#"^\(?\d{1,2}[.)]\s"#)                   // "1) " "2. " "(3) " — not "1990. "
    static let bulletRx = Rx(#"^[-*\x{2022}]\s"#)
    static let speakerRx = Rx(#"^[A-Z]{1,3}:\s"#)                       // "Q: " "A: " "JT: "

    /// Join hard-wrapped lines into paragraphs.
    public static func paragraphs(_ input: [String]) -> [String] {
        let lines = input.map { $0.stripped }
        var paras: [String] = []
        var cur = ""
        for (i, line) in lines.enumerated() {
            if line.isEmpty {
                if !cur.isEmpty { paras.append(cur); cur = "" }
                continue
            }
            if cur.isEmpty {
                cur = line
            } else if cur.hasSuffix("-"), !cur.hasSuffix(" -"), line.first?.isLowercase == true {
                cur += line                                   // word hyphenated across the break
            } else {
                cur += " " + line
            }

            guard i + 1 < lines.count, !lines[i + 1].isEmpty else { continue }
            let next = lines[i + 1]
            let nextWord = next.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let endsSentence = line.last.map { sentenceEnd.contains($0) } ?? false
            let wouldHaveFit = STILParser.indent + line.scalarCount + 1 + nextWord.scalarCount <= wrapWidth - slack
            let structural = numberedRx.matchPrefix(next) != nil
                || speakerRx.matchPrefix(next) != nil
                || (bulletRx.matchPrefix(next) != nil && endsSentence)
            if (wouldHaveFit && endsSentence) || structural {
                paras.append(cur); cur = ""
            }
        }
        if !cur.isEmpty { paras.append(cur) }
        return paras
    }
}
