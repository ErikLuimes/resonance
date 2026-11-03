import Foundation

// Step 3 + 4: enrichment and assembly. Mirrors reference/stil_reference.py
// function for function; keep them in sync and re-run the fixture tests.

public enum STILEnricher {

    // MARK: Titles — "BGM1 [from the arcade game Commando] (1:16-1:32)"

    static let titleRx = Rx(
        #"^(?<title>.*?)"#
        + #"(?:\s*\[(?<src>[Ff]rom [^\]]*(?:\[[^\]]*\][^\]]*)*)\])?"#
        + #"(?:\s*\((?<t1>\d{1,2}:\d\d)(?:-(?<t2>\d{1,2}:\d\d))?\))?$"#)

    static func seconds(_ ts: String?) -> Int? {
        guard let ts else { return nil }
        let p = ts.split(separator: ":")
        guard p.count == 2, let m = Int(p[0]), let s = Int(p[1]) else { return nil }
        return m * 60 + s
    }

    public static func parseTitle(_ raw: String) -> STILCover {
        let s = raw.stripped
        let m = titleRx.matchPrefix(s)
        let title = m?.group("title")?.stripped ?? s
        let src = m?.group("src")
        return STILCover(
            title: (title == "<?>" || title.isEmpty) ? nil : title,
            unknown: title == "<?>",
            source: src.map { String($0.dropFirst(5)).stripped },
            at: seconds(m?.group("t1")),
            until: seconds(m?.group("t2")),
            artist: nil)
    }

    // MARK: Composer from path

    /// "/MUSICIANS/H/Hubbard_Rob/Commando.sid" → Rob Hubbard / RH. Uses the deepest folder.
    public static func composer(fromPath path: String) -> STILComposer? {
        let parts = path.components(separatedBy: "/")
        guard parts.count >= 5, parts[1] == "MUSICIANS" else { return nil }
        let folder = parts[parts.count - 2]
        let bits = folder.components(separatedBy: "_")
        if bits.count < 2 {
            return STILComposer(name: folder, initials: String(folder.prefix(1)).uppercased(), aliases: [folder])
        }
        let first = bits[bits.count - 1]
        let last = bits.dropLast().joined(separator: " ")
        let name = "\(first) \(last)"
        let initials = (String(first.prefix(1)) + last.split(separator: " ").map { String($0.prefix(1)) }.joined()).uppercased()
        let short = (String(first.prefix(1)) + String(last.prefix(1))).uppercased()
        return STILComposer(name: name, initials: initials,
                            aliases: Array(Set([initials, short, name, last, first])).sorted())
    }

    // MARK: Initials declared in folder entries

    static let initialsDeclRx = Rx(
        #"(?:(?<who>[A-Z][\w .'\-\x{00c0}-\x{024f}]{0,40}?)(?:'s)?(?:\s*\([^)]*\))?\s+(?:own\s+)?comments?"#
        + #"|comments?\s+(?:by|from)\s+(?<who2>[^.()]{1,40}?))"#
        + #"\s+(?:are\s+|is\s+)?(?:denoted|indicated|marked|signed)(?:\s+(?:by|with|as))?\s*\((?<ini>[^)]{1,8})\)"#)

    /// folder path → [initials: display name]. Build once per STIL file.
    public static func initialsIndex(_ entries: [String: STILRawEntry]) -> [String: [String: String]] {
        var index: [String: [String: String]] = [:]
        for (path, raw) in entries where path.hasSuffix("/") {
            let fallback = composer(fromPath: path + "x.sid")
            for sec in raw.sections {
                for f in sec.fields where f.key == "COMMENT" {
                    let text = f.lines.map { $0.stripped }.joined(separator: " ")
                    for m in initialsDeclRx.matches(text) {
                        var who = (m.group("who") ?? m.group("who2") ?? "").stripped
                        who = (who.components(separatedBy: ". ").last ?? who).stripped
                        while let c = who.last, c == "'" || c == "\u{2019}" { who.removeLast() }
                        let firstWord = who.split(separator: " ").first.map(String.init) ?? ""
                        if who.isEmpty || ["All", "The", "His", "Her", "Their", "Own"].contains(firstWord) {
                            who = fallback?.name ?? who
                        } else if let fb = fallback, !who.contains(" "),
                                  fb.name.split(separator: " ").map(String.init).contains(who) {
                            who = fb.name
                        }
                        index[path, default: [:]][(m.group("ini") ?? "").stripped] = who
                    }
                }
            }
        }
        return index
    }

    /// Initials that apply to a tune: every folder above it, inner folders win.
    public static func initials(for path: String, in index: [String: [String: String]]) -> [String: String] {
        var out: [String: String] = [:]
        for folder in index.keys.sorted(by: { $0.utf16Length < $1.utf16Length }) where path.hasPrefix(folder) {
            out.merge(index[folder]!) { _, new in new }
        }
        return out
    }

    // MARK: Bylines

    /// `sidAuthor` is the PSID header author field (e.g. "Jeroen Tel (WMC)").
    static func resolveByline(_ by: String?, composer: STILComposer?, sidAuthor: String?,
                              initials: [String: String]) -> (by: String?, role: STILBlock.Role?) {
        guard let by else { return (nil, nil) }
        if let declared = initials[by] {
            let aliases = Set((composer?.aliases ?? []).map { $0.lowercased() })
            return (declared, aliases.contains(declared.lowercased()) ? .composer : nil)
        }
        var candidates = Set<String>()
        if let c = composer { candidates.formUnion(c.aliases.map { $0.lowercased() }) }
        if let a0 = sidAuthor {
            let a = a0.stripped
            candidates.insert(a.lowercased())
            if let h = Rx(#"\(([^)]+)\)"#).search(a)?.group(1) { candidates.insert(h.lowercased()) }
            let plain = Rx(#"\s*\([^)]*\)"#).replace(a, with: "").stripped
            candidates.insert(plain.lowercased())
            let words = plain.split(whereSeparator: { $0 == " " || $0 == "&" || $0 == "," })
            candidates.insert(words.map { String($0.prefix(1)) }.joined().lowercased())
        }
        if candidates.contains(by.lowercased()) {
            let isInitials = by == by.uppercased() && by.contains(where: { $0.isLetter }) && by.count <= 4
            return ((composer != nil && isInitials) ? composer!.name : by, .composer)
        }
        // No match is NOT "someone else": STIL often signs with real-name
        // initials while the folder uses a handle. Never claim "not the composer".
        return (by, nil)
    }

    // MARK: Runs (links, URLs, emphasis, tech tokens) + typography

    static let linkPattern = #"/(?:MUSICIANS|DEMOS|GAMES)/\S+?\.sid"#
    static let urlPattern = #"\b(?:https?://|www\.)[^\s"')\]]+[^\s"')\].,;:!?]"#
    static let emPattern = #"(?<![\w*])\*(?=\S)([^*\n]{1,40}?)(?<=\S)\*(?![\w*])"#
    static let techPattern = #"\$[0-9A-Fa-f]{2,4}\b|\b(?:6581|8580)(?:/(?:6581|8580))?\b|\b(?:PAL|NTSC)(?:/(?:PAL|NTSC))?\b"#
    static let tokenRx = Rx("(?<link>\(linkPattern))|(?<url>\(urlPattern))|(?<em>\(emPattern))|(?<tech>\(techPattern))")
    static let subtuneRefRx = Rx(#"^,?\s*\(?(?:sub)?(?:tune|song)\s*#?(\d+)\)?"#, [.caseInsensitive])
    static let mask = "\u{E000}"   // private-use placeholder: not \w, not whitespace, not a quote

    static let typo: [(Rx, String)] = [
        (Rx(#"\.\.\.+"#), "\u{2026}"),
        (Rx(#"\s+--\s+|\s+-\s+"#), " \u{2014} "),
        (Rx("--"), "\u{2014}"),
        (Rx(#"(\w)'(\w)"#), "$1\u{2019}$2"),
        (Rx(#"(\s|^|[(\[])'"#), "$1\u{2018}"),
        (Rx("'"), "\u{2019}"),
        (Rx(#"(\s|^|[(\[\x{2014}])""#), "$1\u{201C}"),
        (Rx("\""), "\u{201D}"),
    ]

    /// Typographic clean-up for prose. Never applied to paths or URLs.
    public static func smartTypography(_ input: String) -> String {
        var s = input.replacingOccurrences(of: "etc..", with: "etc.")
        for (rx, template) in typo { s = rx.replace(s, with: template) }
        return s
    }

    public static func runs(_ text: String) -> [STILRun] {
        var tokens: [STILRun] = []
        var masked = ""
        var pos = 0
        for m in tokenRx.matches(text) {
            masked += text.utf16Slice(pos, m.range.location)
            let tok = m.text
            var run: STILRun
            if m.has("link") {
                run = STILRun(t: tok, link: tok)
                let tail = text.utf16Slice(m.range.location + m.range.length)
                if let t = subtuneRefRx.matchPrefix(tail), let n = Int(t.group(1) ?? "") { run.subtune = n }
            } else if m.has("url") {
                run = STILRun(t: tok, url: tok.hasPrefix("http") ? tok : "https://" + tok)
            } else if m.has("em") {
                run = STILRun(t: smartTypography(String(tok.dropFirst().dropLast())), em: true)
            } else {
                run = STILRun(t: tok, tech: true)
            }
            tokens.append(run)
            masked += mask
            pos = m.range.location + m.range.length
        }
        masked += text.utf16Slice(pos)
        let typeset = smartTypography(masked)

        var out: [STILRun] = []
        let chunks = typeset.components(separatedBy: mask)
        for (i, chunk) in chunks.enumerated() {
            if !chunk.isEmpty { out.append(STILRun(t: chunk)) }
            if i < tokens.count { out.append(tokens[i]) }
        }
        return out
    }

    // MARK: Note / quote blocks

    static let quoteEndRx = Rx(#""\s*(?:\((?:[Cc]omments? by |[Qq]uote by )?(?<by>[^()]{1,40})\))?\s*$"#)
    static let attrOnlyRx = Rx(#"^\((?:[Cc]omments? by |[Qq]uote by )?(?<by>[^()]{1,40})\)\s*$"#)
    static let inlineQuoteStartRx = Rx(#"(?:^|(?<=[.!?:]\s)|(?<=\s))""#)

    static func quoteCount(_ s: String) -> Int { s.reduce(0) { $1 == "\"" ? $0 + 1 : $0 } }

    /// "Note. "Quote…" (AB)" → ("Note.", "\"Quote…\" (AB)")
    static func splitInlineQuote(_ p: String) -> (String, String)? {
        guard let end = quoteEndRx.search(p), end.group("by") != nil else { return nil }
        for m in inlineQuoteStartRx.matches(p) {
            let k = m.range.location
            if k == 0 { return nil }
            let head = p.utf16Slice(0, k).rstripped
            let tail = p.utf16Slice(k)
            guard let last = head.last, ".!?:".contains(last) else { continue }
            let quoted = p.utf16Slice(k, end.range.location + 1)
            if quoteCount(quoted) % 2 == 0 { return (head, tail) }
        }
        // No sentence boundary before the quote: a reference or a tool name
        // in front of it ("Same as /…/Remoteness.sid "Used in the game…"
        // (Geir Tjelta)", "SW1.8 "Title is…" (NP)"). Split there too when
        // the byline is a name or initials and the quote is a phrase, not a
        // title.
        guard isByline(end.group("by")) else { return nil }
        for m in inlineQuoteStartRx.matches(p) {
            let k = m.range.location
            if k == 0 { return nil }
            let head = p.utf16Slice(0, k).rstripped
            let tail = p.utf16Slice(k)
            let quoted = p.utf16Slice(k, end.range.location + 1)
            let body = p.utf16Slice(k + 1, end.range.location)
            // A phrase, or anything after a short label like "SW1.7".
            if quoteCount(quoted) % 2 == 0, words(body) >= 4 || words(head) <= 3 { return (head, tail) }
        }
        return nil
    }

    /// A quote that opens after a short lead-in ("SW1.8 "This angry tune…",
    /// "Covers /…/Traz.sid "…") and closes, signed, in a later paragraph:
    /// (lead-in, quote start). The lead-in is a few words or ends in a tune
    /// path; the quote must close with a name or initials.
    static func splitOpeningQuote(_ p: String, rest: ArraySlice<String>) -> (String, String)? {
        guard let m = inlineQuoteStartRx.matches(p).first else { return nil }
        let k = m.range.location
        if k == 0 { return nil }
        let head = p.utf16Slice(0, k).rstripped
        let tail = p.utf16Slice(k)
        if words(head) > 3, !head.hasSuffix(".sid") { return nil }
        var count = quoteCount(tail)
        if count % 2 == 0 { return nil }   // closed here: not this case
        for q in rest {
            count += quoteCount(q)
            if count % 2 == 0 {
                return isByline(quoteEndRx.search(q)?.group("by")) ? (head, tail) : nil
            }
        }
        return nil
    }

    /// A lead-in that names the tool a tune was made with rather than
    /// saying something: a few words, no sentence end, no tune path
    /// ("SW1.8", "GMC1.6 + SW1.9-EMU", "SID Factory 2").
    static func isLabel(_ head: String) -> Bool {
        let n = words(head)
        guard n > 0, n <= 3, !head.contains("/"), let last = head.last else { return false }
        return !".!?:,".contains(last)
    }

    static func words(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }

    static let bylineParticles: Set<String> = ["van", "de", "der", "den", "von", "of", "the", "la", "le", "di", "da", "and", "&"]

    /// A byline that is a name or initials: every word capitalised (or a
    /// digit, or a name particle), so "(German children's song)" isn't one.
    static func isByline(_ by: String?) -> Bool {
        guard let by, !by.isEmpty else { return false }
        return by.split(whereSeparator: \.isWhitespace).allSatisfy { w in
            w.first.map { $0.isUppercase || $0.isNumber } == true || bylineParticles.contains(w.lowercased())
        }
    }

    struct RawBlock {
        var kind: STILBlock.Kind
        var by: String?
        var paragraphs: [String]
        var label: String? = nil
    }

    /// "Q: Is this a cover?" / "A: …" / "JT: …": an interview line.
    static let qaRx = Rx(#"^(?<who>[A-Z]{1,3}): (?<rest>.*)$"#, [.dotMatchesLineSeparators])

    static func isQuestion(_ p: String) -> Bool { qaRx.matchPrefix(p)?.group("who") == "Q" }

    /// Note blocks, quote blocks and interview questions. A "Q: " paragraph
    /// is a question block; the "A: " or "XY: " paragraph after it is the
    /// answer, a quote: up to its closing quote when it opens with one, else
    /// up to the next question or the comment's end. Initials other than
    /// "A" sign an answer that has no (byline).
    static func splitBlocks(_ paras: [String]) -> [RawBlock] {
        var work: [String] = []
        var labels: [Int: String] = [:]   // work index of a quote → its tool label
        for (n, p) in paras.enumerated() {
            // (not an interview line: its "A: " isn't a note)
            if !p.hasPrefix("\""), qaRx.matchPrefix(p) == nil,
               let pair = splitInlineQuote(p) ?? splitOpeningQuote(p, rest: paras[(n + 1)...]) {
                if isLabel(pair.0) {
                    // "SW1.8 "…": the quote's label, not a note.
                    labels[work.count] = pair.0
                    work.append(pair.1)
                } else {
                    work += [pair.0, pair.1]
                }
            } else {
                work.append(p)
            }
        }
        var blocks: [RawBlock] = []
        var answerBy: String?
        var i = 0
        while i < work.count {
            var p = work[i]
            if let qa = qaRx.matchPrefix(p) {
                let who = qa.group("who") ?? "", rest = (qa.group("rest") ?? "").stripped
                if who == "Q" {
                    blocks.append(RawBlock(kind: .question, by: nil, paragraphs: [rest]))
                    i += 1
                    continue
                }
                if blocks.last?.kind == .question {
                    let speaker: String? = who == "A" ? nil : who
                    if rest.hasPrefix("\"") {
                        work[i] = rest   // handled as a quote below
                        p = rest
                        answerBy = speaker
                    } else {
                        var body = [rest], j = i + 1
                        while j < work.count, !isQuestion(work[j]) {
                            body.append(work[j]); j += 1
                        }
                        blocks.append(RawBlock(kind: .quote, by: speaker, paragraphs: body))
                        i = j
                        continue
                    }
                }
            }
            if p.hasPrefix("\"") {
                var count = 0, j = i
                var closed: Int?
                while j < work.count {
                    count += quoteCount(work[j])
                    if count % 2 == 0, quoteEndRx.search(work[j]) != nil { closed = j; break }
                    j += 1
                }
                if let c = closed {
                    var body = Array(work[i...c])
                    let m = quoteEndRx.search(body[body.count - 1])!
                    var by = m.group("by")
                    body[body.count - 1] = body[body.count - 1].utf16Slice(0, m.range.location)
                    body[0] = String(body[0].dropFirst())
                    var next = c + 1
                    if by == nil, next < work.count, let a = attrOnlyRx.matchPrefix(work[next]) {
                        by = a.group("by"); next += 1
                    }
                    by = by ?? answerBy
                    answerBy = nil
                    blocks.append(RawBlock(kind: .quote, by: by?.stripped,
                                           paragraphs: body.map { $0.stripped }.filter { !$0.isEmpty },
                                           label: labels[i]))
                    i = next
                    continue
                }
            }
            answerBy = nil
            if let last = blocks.last, last.kind == .note {
                blocks[blocks.count - 1].paragraphs.append(p)
            } else {
                blocks.append(RawBlock(kind: .note, by: nil, paragraphs: [p]))
            }
            i += 1
        }
        return blocks
    }

    // MARK: Comments

    static let memoriamRx = Rx(#"\bpassed away\b|\bR\.I\.P\b"#, [.caseInsensitive])
    static let sentenceRx = Rx(#"^(.+?[.!?\x{2026}])(?:\s|$)"#)

    static func firstSentence(_ s: String, maxLength: Int = 140) -> String {
        var out = sentenceRx.matchPrefix(s)?.group(1) ?? s
        if out.unicodeScalars.count > maxLength {
            let cut = String(String.UnicodeScalarView(out.unicodeScalars.prefix(maxLength - 1)))
            out = (cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? cut) + "\u{2026}"
        }
        return out
    }

    public static func comment(_ lines: [String], composer: STILComposer?, sidAuthor: String?,
                               initials: [String: String]) -> STILComment {
        let paras = STILReflow.paragraphs(lines)
        let raw = splitBlocks(paras)
        var links = Set<String>()
        let blocks: [STILBlock] = raw.map { b in
            let byline = resolveByline(b.by, composer: composer, sidAuthor: sidAuthor, initials: initials)
            let ps = b.paragraphs.map(runs)
            for p in ps { for r in p { if let l = r.link { links.insert(l) } } }
            return STILBlock(kind: b.kind, by: byline.by, role: byline.role, paragraphs: ps, label: b.label)
        }
        let first = raw.first?.paragraphs.first ?? ""
        return STILComment(
            blocks: blocks,
            memoriam: memoriamRx.search(paras.joined(separator: " ")) != nil,
            teaser: first.isEmpty ? "" : smartTypography(firstSentence(first)),
            links: links.sorted())
    }

    // MARK: Entry

    /// - Parameters:
    ///   - sidAuthor: author field from the PSID header, if available.
    ///   - initials: `initials(for: raw.path, in: initialsIndex(allEntries))`.
    public static func entry(_ raw: STILRawEntry, sidAuthor: String? = nil,
                             initials: [String: String] = [:]) -> STILEntry {
        let comp = composer(fromPath: raw.path)
        var sections: [STILSection] = []
        for sec in raw.sections {
            var covers: [STILCover] = [], comments: [STILComment] = []
            var names: [String] = [], authors: [String] = []
            var lastCover: Int?
            for f in sec.fields {
                let oneLine = f.lines.map { $0.stripped }.joined(separator: " ")
                switch f.key {
                case "TITLE":
                    covers.append(parseTitle(oneLine))
                    lastCover = covers.count - 1
                case "ARTIST":
                    let artist: String? = oneLine == "<?>" ? nil : oneLine
                    if let i = lastCover, covers[i].artist == nil {
                        covers[i].artist = artist
                    } else {
                        covers.append(STILCover(title: nil, unknown: false, source: nil, at: nil, until: nil, artist: artist))
                    }
                case "COMMENT":
                    comments.append(comment(f.lines, composer: comp, sidAuthor: sidAuthor, initials: initials))
                case "NAME": names.append(oneLine)
                case "AUTHOR": authors.append(oneLine)
                default: break
                }
            }
            sections.append(STILSection(
                subtune: sec.subtune, names: names, authors: authors, covers: covers,
                isMedley: covers.filter { $0.at != nil }.count >= 2, comments: comments))
        }
        return STILEntry(path: raw.path, composer: comp, sections: sections)
    }

    /// A single timestamp "(0:53)" runs until the next timestamped part starts (or the song ends).
    public static func medleySegments(_ covers: [STILCover], songLength: Int?) -> [STILMedleySegment] {
        let timed = covers.filter { $0.at != nil }.sorted { $0.at! < $1.at! }
        return timed.enumerated().map { i, c in
            let end = c.until ?? (i + 1 < timed.count ? timed[i + 1].at : songLength)
            return STILMedleySegment(title: c.title ?? "Unknown", artist: c.artist, start: c.at!, end: end)
        }
    }
}
