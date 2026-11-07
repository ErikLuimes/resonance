import Foundation
import NaturalLanguage
import PhosphorCore

/// What a sentence asked for. Facts are read by plain code; composers and
/// moods by NLTagger with a gazetteer. The same sentence always gives the
/// same answer, on any Mac, with nothing leaving it.
nonisolated struct SmartUnderstanding: Hashable, Sendable {
    enum Shape: Hashable, Sendable { case steady, rising, falling, alternating }

    struct Composer: Hashable, Sendable {
        var folder: String
        var name: String
    }

    var energy = SmartEnergy.any
    var shape = Shape.steady
    /// Who it's by: more than one for "Tel, Hubbard and Follin".
    var composers: [Composer] = []
    var fromYear: UInt16?
    var toYear: UInt16?
    var section = SmartSection.any
    var onlyUnheard = false
    var unlikeHeard = false
    /// Tunes still to look up by name: more than one for "Sanxion and Delta".
    var tuneNames: [String] = []
    /// Words the title must have: "with love in the title".
    var titleWords: String?
    /// Those words were a tune's name, not words to look for: "play Commando".
    var titleIsATune = false
    var sounds: [SmartSound] = []
    var chip = SmartChip.any
    /// How many SID chips a tune uses: 2 and 2 for "dual SID", 2 and nil for
    /// "stereo", 1 and 1 for "single SID".
    var minChips: UInt8?
    var maxChips: UInt8?
    var maxTunes: UInt32?
    var minMinutes: UInt32?
    var totalMinutes: UInt32?
    /// "Until 9 PM": when it should stop, which `totalMinutes` was worked out
    /// from when the sentence was read.
    var until: Date?
    /// "Random", "shuffle", "surprise me": nothing to narrow, but understood.
    var justShuffle = false
    /// Reading it found this composer only by a close spelling.
    var composerWasGuessed = false
    /// Things asked for that the data can't tell, said so rather than faked.
    var cantTell: [String] = []
    var asksForLocalFiles = false

    var composerFolder: String? { composers.first?.folder }
    var composerName: String? { composers.first?.name }
    var tuneName: String? { tuneNames.first }

    var isEmpty: Bool {
        self == SmartUnderstanding()
    }

    /// More than a name: a mood, a length, "never heard" and so on. A search
    /// for a tune or composer alone stays a search.
    var asksForAList: Bool {
        energy != .any || shape != .steady || onlyUnheard || unlikeHeard || totalMinutes != nil || minMinutes != nil
            || fromYear != nil || toYear != nil || section != .any || justShuffle
            || !sounds.isEmpty || chip != .any || minChips != nil || maxChips != nil || maxTunes != nil || composers.count > 1 || tuneNames.count > 1
    }

    /// What to try when a tune by that name doesn't fit the rest of `sentence`:
    /// no Commando is dual SID, but "like Commando dual SID" finds what is.
    func likeInstead(of sentence: String) -> String? {
        guard titleIsATune else { return nil }
        var rest = sentence.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        rest.replace(/^(?:please\s+)?(?:play|put\s+on|give\s+me|i\s+want|find|search\s+for)\s+(?:me\s+)?/.ignoresCase(), with: "")
        rest.replace(/\s+please$/.ignoresCase(), with: "")
        return "like \(rest)"
    }

    private static func list(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    /// In words, so a wrong guess shows: "Starts calm, ends intense", "By Rob
    /// Hubbard", "From 1985 to 1986".
    func parts(seedTitles: [String] = []) -> [String] {
        var parts: [String] = []
        let tunes = seedTitles.isEmpty ? tuneNames : seedTitles
        if !tunes.isEmpty { parts.append("sounds like \(Self.list(tunes))") }
        if let titleWords { parts.append("with “\(titleWords)” in the title") }
        if unlikeHeard { parts.append("different to what you've heard before") }
        switch shape {
        case .rising: parts.append("starts calm, ends intense")
        case .falling: parts.append("starts intense, ends calm")
        case .alternating: parts.append("taking turns between calm and intense")
        case .steady:
            let relative = !tunes.isEmpty
            if energy == .calm { parts.append(relative ? "calmer" : "calm") }
            if energy == .medium { parts.append("mid-tempo") }
            if energy == .intense { parts.append(relative ? "more intense" : "intense") }
        }
        if !composers.isEmpty { parts.append("by \(Self.list(composers.map(\.name)))") }
        if !sounds.isEmpty { parts.append("with plenty of \(Self.list(sounds.map(Self.soundName)))") }
        switch (minChips, maxChips) {
        case (1, 1): parts.append("single SID")
        case (2, 2): parts.append("dual SID")
        case (3, 3): parts.append("triple SID")
        case (2, nil): parts.append("stereo, two SIDs or more")
        default: break
        }
        if chip == .mos6581 { parts.append("for the 6581") }
        if chip == .mos8580 { parts.append("for the 8580") }
        switch section {
        case .games: parts.append("from games")
        case .demos: parts.append("from demos")
        case .notGames: parts.append("no games")
        case .notDemos: parts.append("no demos")
        case .any: break
        }
        switch (fromYear, toYear) {
        case let (from?, to?) where from == to: parts.append("from \(String(from))")
        case let (from?, to?): parts.append("from \(String(from)) to \(String(to))")
        case let (from?, nil): parts.append("from \(String(from)) on")
        case let (nil, to?): parts.append("up to \(String(to))")
        default: break
        }
        if onlyUnheard, !unlikeHeard { parts.append("never heard") }
        if let minMinutes { parts.append("each over \(minMinutes) \(minMinutes == 1 ? "minute" : "minutes")") }
        if let maxTunes { parts.append("at most \(maxTunes) tunes") }
        if let until { parts.append("until \(until.formatted(date: .omitted, time: .shortened))") }
        if parts.isEmpty || parts == until.map({ ["until \($0.formatted(date: .omitted, time: .shortened))"] }) {
            parts.insert("anything, shuffled", at: 0)
        }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    /// What couldn't be done, said beside the parts.
    var aside: String? {
        var text: [String] = []
        if !cantTell.isEmpty { text.append("Can't tell \(Self.list(cantTell.map { "“\($0)”" })) from how tunes sound yet.") }
        if asksForLocalFiles { text.append("Your own files aren't included yet.") }
        return text.isEmpty ? nil : text.joined(separator: " ")
    }

    /// All of it in a sentence.
    func description(seedTitles: [String] = []) -> String {
        let shown = parts(seedTitles: seedTitles).enumerated().map { index, part in
            index == 0 || part.hasPrefix("HVSC") ? part : part.prefix(1).lowercased() + part.dropFirst()
        }
        let sentence = shown.joined(separator: ", ") + "."
        return aside.map { "\(sentence) \($0)" } ?? sentence
    }

    private static func soundName(_ sound: SmartSound) -> String {
        switch sound {
        case .arpeggios: "arpeggios"
        case .filter: "filter"
        case .drums: "drums"
        case .bass: "bass"
        case .pulseWidth: "pulse width"
        case .samples: "samples"
        case .ringMod: "ring mod"
        case .sync: "sync"
        }
    }
}

nonisolated final class SmartSentenceParser: @unchecked Sendable {
    private static let moods: [String: [String]] = [
        "calm": ["chill", "chilled", "chillout", "slow", "slowly", "mellow", "calm", "calming", "relax", "relaxed",
                 "relaxing", "quiet", "sleep", "asleep", "sleepy", "ambient", "soft", "peaceful", "gentle", "soothing",
                 "dreamy", "lazy", "easy", "atmospheric", "background", "slower"],
        "intense": ["intense", "intensity", "fast", "faster", "hard", "harder", "energetic", "energy", "party",
                    "workout", "working out", "banging", "bang", "aggressive", "wild", "upbeat", "pumping",
                    "frantic", "crazy", "loud", "high-energy", "fast-paced", "bangers", "banger", "driving", "action", "racing"],
        "rising": ["build up", "builds up", "building up", "build", "builds", "rising", "rises", "ramp up", "ramps up",
                   "getting faster", "getting more", "increasing"],
        "falling": ["wind down", "winds down", "winding down", "cool down", "calm down", "fading", "slowing down"],
    ]
    private static let notNames: Set<String> = ["music", "tune", "tunes", "song", "songs", "game", "games", "demo", "demos"]
    /// Three-letter surnames that are mostly just words.
    private static let shortWords: Set<String> = ["the", "day", "may", "boy", "man", "war", "sun", "sky", "ice", "fox", "bay",
                                                  "low", "law", "key", "row", "new", "old", "one", "two", "all", "sid", "big"]
    /// Words that say nothing about which tune: a title needs more than these.
    private static let plainWords: Set<String> = [
        "a", "an", "the", "i", "me", "my", "we", "you", "your", "it", "is", "are", "be", "am", "do", "to", "of", "in", "on", "at",
        "for", "from", "by", "with", "and", "or", "but", "not", "no", "this", "that", "these", "those", "some", "any", "all",
        "more", "most", "much", "very", "just", "only", "please", "play", "plays", "playing", "playlist", "list", "make", "give",
        "want", "wanna", "need", "like", "love", "good", "great", "best", "nice", "cool", "something", "anything", "stuff", "things",
        "music", "tune", "tunes", "song", "songs", "track", "tracks", "sid", "sids", "c64", "commodore", "hear", "listen", "start",
        "starts", "end", "ends", "then", "get", "gets", "let", "lets", "new", "old", "one", "two", "up", "down", "out", "time",
        "what", "when", "how", "who", "can", "could", "would", "should", "will", "have", "has", "had", "ones",
        "top", "hvsc", "local", "file", "files", "mix", "collection", "classic", "classics", "short", "long", "max", "chiptune",
        "chiptunes", "them", "style", "styles", "vibe", "vibes", "gimme", "find", "about", "include", "my", "other",
        "generate", "suggest", "similar", "heavy", "strong", "title", "loading", "crack", "piece", "pieces", "composer", "bit", "few", "whatever", "today", "fill", "first",
        "games", "game", "demos", "demo", "soundtrack", "soundtracks", "theme", "themes", "only", "any", "playlists", "sid's",
    ]
    /// Asked for often, but nothing measured says it. Better to say so.
    private static let cantTellWords = ["dark", "moody", "melancholic", "melancholy", "sad", "happy", "playful", "nostalgic",
                                        "alternative", "experimental", "complex", "best", "good"]
    private static let sayIt: Set<String> = ["dark", "moody", "melancholic", "melancholy", "sad", "happy", "playful", "nostalgic",
                                             "alternative", "experimental"]

    private let gazetteer: NLGazetteer?
    private let english: NLEmbedding?
    /// Single-word titles too, for lists: "Sanxion, Delta".
    private let everyTitle: Set<String>
    /// Multi-word titles by their words: "monty on the run".
    private let titles: Set<String>
    private let longestTitle: Int
    /// A composer's full name or unmistakable surname to their folder.
    private let composers: [String: SmartComposer]
    /// One-word names, which also mean ordinary things: only after "by".
    private let handles: [String: SmartComposer]

    init(composers list: [SmartComposer], titles titleList: [String] = []) {
        var full: [String: SmartComposer] = [:]
        var handles: [String: SmartComposer] = [:]
        var surnames: [String: [SmartComposer]] = [:]
        let english = NLEmbedding.wordEmbedding(for: .english)
        self.english = english
        let moodWords = Set(Self.moods.values.flatMap { $0 })
        // Fewest tunes first, so a shared name ends up with who has the most.
        for original in list.sorted(by: { $0.tunes < $1.tunes }) {
            // "Hubbard, Rob" is Rob Hubbard.
            var composer = original
            let parts = composer.name.components(separatedBy: ", ")
            if parts.count == 2 { composer.name = "\(parts[1]) \(parts[0])" }
            for name in [original.name] + original.aliases {
                let words = Self.words(name)
                guard let first = words.first, let last = words.last else { continue }
                if words.count == 1 {
                    // A nickname that's no English word is safe anywhere;
                    // "Eye" and "Jeff" need "by".
                    let plain = english?.contains(first) == true || moodWords.contains(first) || Self.notNames.contains(first)
                        || Self.plainWords.contains(first)
                    if !plain, first.count >= 3 { full[first] = composer }
                    handles[first] = composer
                    continue
                }
                let joined = words.joined(separator: " ")
                full[joined] = composer
                // "Jeroen Tel", "Tel Jeroen" and "Tel, Jeroen" are one person.
                if words.count == 2 {
                    full[[last, first].joined(separator: " ")] = composer
                    surnames[name.contains(",") ? first : last, default: []].append(composer)
                }
            }
        }
        for (surname, owners) in surnames where surname.count >= 3 {
            // Each is in order of tunes, so the last has the most.
            guard let owner = owners.last, full[surname] == nil else { continue }
            // "Long" alone is rarely James Long; "Hubbard" alone is Rob Hubbard.
            if english?.contains(surname) == true, owner.tunes < 30 { continue }
            if !moodWords.contains(surname), !Self.notNames.contains(surname), !Self.plainWords.contains(surname),
               !Self.shortWords.contains(surname) {
                full[surname] = owner
            }
        }
        let allKeys = titleList.map { Self.words($0) }
        everyTitle = Set(allKeys.map { $0.joined(separator: " ") })
        let titleKeys = allKeys.filter { $0.count >= 2 }
        titles = Set(titleKeys.map { $0.joined(separator: " ") })
        longestTitle = titleKeys.map(\.count).max() ?? 0
        composers = full
        self.handles = handles
        var dictionary = Self.moods
        dictionary["composer"] = Array(full.keys)
        gazetteer = try? NLGazetteer(dictionary: dictionary, language: .english)
    }

    /// A name or title as words to compare: folded, and ordinals as digits, as
    /// the core compares titles.
    private static func words(_ text: String) -> [String] {
        folded(text).split { !$0.isLetter && !$0.isNumber }.map { word in
            switch word {
            case "first": "1st"
            case "second": "2nd"
            case "third": "3rd"
            case "fourth": "4th"
            default: String(word)
            }
        }
    }

    /// Lower case, without accents, as the names are kept: "Hülsbeck" is
    /// filed as "Huelsbeck".
    private static func folded(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "ü", with: "ue")
            .replacingOccurrences(of: "ö", with: "oe")
            .replacingOccurrences(of: "ä", with: "ae")
            .folding(options: .diacriticInsensitive, locale: .init(identifier: "en"))
    }

    /// Nil when there's nothing in it to go on.
    func parse(_ sentence: String) -> SmartUnderstanding? {
        var text = Self.folded(sentence)
        // "Commodore 64" isn't 64 of anything, and "Hubbard's" is Hubbard.
        text.replace(/\b(?:commodore\s*64|c\s?64)\b/, with: " ")
        text.replace(/['’]s\b/, with: "")
        var result = SmartUnderstanding()
        readUntil(&text, into: &result)
        readTitle(&text, into: &result)
        let energyIsSettled = readNegatives(&text, into: &result)
        readSounds(&text, into: &result)
        readLengths(&text, into: &result)
        readCounts(&text, into: &result)
        readYears(&text, into: &result)
        readFlags(&text, into: &result)
        readCantTell(text, into: &result)
        readPlayTitle(&text, into: &result)
        readTune(&text, into: &result)
        readTitleList(&text, into: &result)
        readTags(&text, into: &result, energyIsSettled: energyIsSettled)
        readKnownTitle(text, into: &result)
        readLeftoverHandles(text, into: &result)
        readCloseComposer(text, into: &result)
        return result.isEmpty ? nil : result
    }

    // MARK: Facts

    /// "Until 9pm", "till midnight", "until tomorrow morning". NSDataDetector
    /// knows these, and gives "until" as a range: its date plus its duration
    /// is the end.
    private func readUntil(_ text: inout String, into result: inout SmartUnderstanding) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return }
        let now = Date()
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let date = match.date,
                  text[range].hasPrefix("until") || text[range].hasPrefix("till") || text[range].hasPrefix("til ")
            else { continue }
            var end = date.addingTimeInterval(match.duration)
            // Already past today, so tomorrow's.
            if end <= now { end = end.addingTimeInterval(86_400) }
            result.until = end
            result.totalMinutes = UInt32(max(1, (end.timeIntervalSince(now) / 60).rounded()))
            text.replaceSubrange(range, with: " ")
            return
        }
    }

    /// What it shouldn't be, before anything reads those words as what it
    /// should: "no demos", "not too intense", and what's between two moods.
    /// Returns whether that settled the energy.
    private func readNegatives(_ text: inout String, into result: inout SmartUnderstanding) -> Bool {
        var settled = false
        if text.firstMatch(of: /\b(?:not|no|without|exclude|excluding)\s+(?:any\s+)?demos?\b/) != nil { result.section = .notDemos }
        if text.firstMatch(of: /\b(?:no|without|exclude|excluding)\s+(?:any\s+)?games?\b/) != nil { result.section = .notGames }
        text.replace(/\b(?:not|no|without|exclude|excluding)\s+(?:any\s+)?(?:demos?|games?)\b/, with: " ")
        text.replace(/\bnot\s+just\s+(?:demos?|games?)\b/, with: " ")
        text.replace(/\bno\s+(?:pure\s+)?action(?:\s+stuff)?\b/, with: " ")
        let notToo = /\bnot\s+(?:too|so|that|very)\s+(?:fast|intense|hard|loud|heavy|energetic|slow|calm|quiet)\b/
        if text.firstMatch(of: notToo) != nil {
            result.energy = .medium
            settled = true
            text.replace(notToo, with: " ")
        }
        let middle = /\b(?:mid-?\s?tempo|medium|moderate|between\s+slow\s+and\s+fast|between\s+fast\s+and\s+slow)\b/
        if text.firstMatch(of: middle) != nil {
            result.energy = .medium
            settled = true
            text.replace(middle, with: " ")
        }
        let turns = /\b(?:alternate|alternates|alternating)(?:\s+between)?(?:\s+slow\s+and\s+fast|\s+fast\s+and\s+slow|\s+calm\s+and\s+intense)?\b/
        if text.firstMatch(of: turns) != nil {
            result.shape = .alternating
            settled = true
            text.replace(turns, with: " ")
        }
        return settled
    }

    /// "About 20 tracks", "10 songs max", "short playlist".
    private func readCounts(_ text: inout String, into result: inout SmartUnderstanding) {
        let pattern = /\b(\d{1,4})\s+(?:tracks?|songs?|tunes?|sids?)\b(?:\s+max)?/
        if let match = text.firstMatch(of: pattern), let count = UInt32(match.1) {
            result.maxTunes = count
            text.replace(pattern, with: " ")
        }
        if result.totalMinutes == nil, result.maxTunes == nil {
            if text.firstMatch(of: /\bshort\s+(?:playlist|list|mix)\b/) != nil { result.totalMinutes = 30 }
            if text.firstMatch(of: /\blong\s+(?:background\s+)?(?:playlist|list|mix)\b/) != nil { result.totalMinutes = 180 }
        }
    }

    /// Sounds and chips the fingerprints measure.
    private func readSounds(_ text: inout String, into result: inout SmartUnderstanding) {
        let kinds: [(pattern: Regex<Substring>, sound: SmartSound)] = [
            (/\barp(?:eggio|eggios|s)?(?:-heavy)?\b/, .arpeggios),
            (/\bfilter(?:ed|s|ing)?(?:\s+(?:sweeps?|usage|character))?\b/, .filter),
            (/\bdrum(?:s|\s+patterns?)?\b/, .drums),
            (/\bbass(?:lines?)?\b/, .bass),
            (/\b(?:pulse[- ]width(?:\s+modulation)?|pwm)\b/, .pulseWidth),
            (/\b(?:digi|samples?|sampled)\b/, .samples),
            (/\bring[- ]?mod(?:ulation)?\b/, .ringMod),
            (/\bsync\b/, .sync),
        ]
        for kind in kinds where text.firstMatch(of: kind.pattern) != nil {
            result.sounds.append(kind.sound)
            text.replace(kind.pattern, with: " ")
        }
        // Speech is played as samples, which is all a tune's sound says: drums
        // are too. So it finds those, and says it can't tell which.
        let speech = /\b(?:speech|spoken|talking|vocals?)\b/
        if let word = text.firstMatch(of: speech) {
            if !result.sounds.contains(.samples) { result.sounds.append(.samples) }
            result.cantTell.append(String(word.output))
            text.replace(speech, with: " ")
        }
        let chipCounts: [(pattern: Regex<Substring>, min: UInt8, max: UInt8?)] = [
            (/\b(?:dual|double|two|2)[- ]?sids?\b|\b2sids?\b/, 2, 2),
            (/\b(?:triple|three|3)[- ]?sids?\b|\b3sids?\b/, 3, 3),
            (/\b(?:single|mono|one|1)[- ]?sids?\b|\b1sids?\b/, 1, 1),
            (/\b(?:stereo|multi[- ]?sids?)\b/, 2, nil),
        ]
        for count in chipCounts where text.firstMatch(of: count.pattern) != nil {
            result.minChips = count.min
            result.maxChips = count.max
            text.replace(count.pattern, with: " ")
            break
        }
        if text.firstMatch(of: /\b6581\b/) != nil {
            result.chip = .mos6581
            text.replace(/\b6581\b/, with: " ")
        }
        if text.firstMatch(of: /\b8580\b/) != nil {
            result.chip = .mos8580
            text.replace(/\b8580\b/, with: " ")
        }
    }

    /// Asked for, but nothing measured says it: said in the line, not faked.
    private func readCantTell(_ text: String, into result: inout SmartUnderstanding) {
        let words = Set(text.split { !$0.isLetter }.map(String.init))
        result.cantTell += Self.cantTellWords.filter { Self.sayIt.contains($0) && words.contains($0) }
    }

    private func readLengths(_ text: inout String, into result: inout SmartUnderstanding) {
        for (phrase, minutes) in [("whole day", 1440), ("all day", 1440), ("an hour and a half", 90), ("hour and a half", 90), ("half an hour", 30), ("half hour", 30)] as [(String, UInt32)]
        where text.contains(phrase) {
            result.totalMinutes = minutes
            text = text.replacingOccurrences(of: phrase, with: " ")
        }
        let pattern = /(longer than|more than|at least|over|above)?\s*(\d+|an?|one|two|three|four|five|six)\s*[- ]?(hours?|hrs?|minutes?|mins?)\b/
        for match in text.matches(of: pattern) {
            let amount: UInt32 = switch match.2 {
            case "a", "an", "one": 1
            case "two": 2
            case "three": 3
            case "four": 4
            case "five": 5
            case "six": 6
            default: UInt32(match.2) ?? 0
            }
            guard amount > 0 else { continue }
            let isHours = match.3.hasPrefix("h")
            // "over two hours" is how long it plays; no tune is that long.
            if match.1 != nil, !isHours {
                result.minMinutes = amount
            } else {
                result.totalMinutes = isHours ? amount * 60 : amount
            }
        }
        text.replace(pattern, with: " ")
    }

    private func readYears(_ text: inout String, into result: inout SmartUnderstanding) {
        // "Mid-80s" narrows a decade.
        if let match = text.firstMatch(of: /\b(early|mid|late)[- ]?(?:19)?([89]0)s?\b/), let decade = UInt16(match.2) {
            let start = 1900 + decade
            switch match.1 {
            case "early": (result.fromYear, result.toYear) = (start, start + 3)
            case "mid": (result.fromYear, result.toYear) = (start + 4, start + 6)
            default: (result.fromYear, result.toYear) = (start + 7, start + 9)
            }
            text.replace(match.0, with: " ")
        }
        let decades: [(names: [String], from: UInt16)] = [
            (["eighties", "1980s", "80s", "80's"], 1980), (["nineties", "1990s", "90s", "90's"], 1990),
            (["2000s", "noughties"], 2000), (["2010s"], 2010), (["2020s"], 2020),
        ]
        for decade in decades {
            for name in decade.names where text.contains(name) {
                result.fromYear = decade.from
                result.toYear = decade.from + 9
                text = text.replacingOccurrences(of: name, with: " ")
            }
        }
        if let match = text.firstMatch(of: /\b(after|since)\s+((?:19|20)\d\d)\b/), let year = UInt16(match.2) {
            result.fromYear = match.1 == "after" ? year + 1 : year
            text.replace(match.0, with: " ")
        }
        if let match = text.firstMatch(of: /\b(before|until)\s+((?:19|20)\d\d)\b/), let year = UInt16(match.2) {
            result.toYear = match.1 == "before" ? year - 1 : year
            text.replace(match.0, with: " ")
        }
        let years = text.matches(of: /\b(?:19|20)\d\d\b/).compactMap { UInt16($0.0) }
        if let low = years.min(), let high = years.max() {
            result.fromYear = low
            result.toYear = high
            text.replace(/\b(?:19|20)\d\d\b/, with: " ")
        }
    }

    /// "with love in the title", "love as the title", "titled love", "called
    /// love". Ahead of the rest, as a title can be any word: "fast" here isn't
    /// a mood. A quoted name keeps its case-free words whatever they are.
    private func readTitle(_ text: inout String, into result: inout SmartUnderstanding) {
        let ends = /(.+?)\s+(?:in|as)\s+(?:the\s+|its\s+)?(?:title|name)\b/
        let starts = /\b(?:titled|called|named|title contains|name contains)\s+[\"“']?([^\"”',]+)[\"”']?/
        var words: String?
        if let match = text.firstMatch(of: ends) {
            // Only what follows "with" or "has", when it's there; what comes
            // before that still counts: "calm tunes with night in the title".
            let whole = String(match.1)
            if let lead = whole.firstMatch(of: /.*\b(?:with|has|have|having|contain|contains|containing)\s+/) {
                words = String(whole[lead.range.upperBound...])
                let before = whole[..<lead.range.upperBound]
                text.replaceSubrange(match.range, with: before.replacing(/\s*\b(?:with|has|have|having|contain|contains|containing)\s+$/, with: " "))
            } else {
                words = whole
                text.replaceSubrange(match.range, with: " ")
            }
        } else if let match = text.firstMatch(of: starts) {
            words = String(match.1)
            text.replace(match.0, with: " ")
        }
        let cleaned = words?.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if let cleaned, !cleaned.isEmpty { result.titleWords = cleaned }
    }

    private func readFlags(_ text: inout String, into result: inout SmartUnderstanding) {
        func take(_ phrases: [String]) -> Bool {
            var found = false
            for phrase in phrases where text.contains(phrase) {
                found = true
                text = text.replacingOccurrences(of: phrase, with: " ")
            }
            return found
        }
        if take(["new to me", "opposite", "different from", "something different", "wouldn't normally", "not my usual"]) {
            result.unlikeHeard = true
            result.onlyUnheard = true
        }
        if take(["unheard", "never heard", "never played", "not heard", "haven't heard", "havent heard", "not played", "haven't played", "i've never"]) {
            result.onlyUnheard = true
        }
        if take(["random", "shuffle", "surprise me"]) { result.justShuffle = true }
        if text.contains("local") {
            result.asksForLocalFiles = true
            text.replace(/\b(?:my\s+)?local\s+\S+/, with: " ")
        }
        let spaced = " \(text) "
        if spaced.firstMatch(of: /\b(?:games?|soundtracks?)\b/) != nil { result.section = .games }
        if spaced.firstMatch(of: /\b(?:demos?|demoscene|scene)\b/) != nil { result.section = .demos }
        _ = take(["game music", "game tunes", "games", " game ", "demo music", "demo tunes", "demoscene", "demos", " demo "])
    }

    /// "Play Airwolf": a request, and the rest is exactly a real title, however
    /// ordinary. It means that tune and its versions, not what sounds like it.
    private func readPlayTitle(_ text: inout String, into result: inout SmartUnderstanding) {
        guard result.titleWords == nil else { return }
        let lead = /^\s*(?:please\s+)?(?:play|put\s+on|give\s+me|i\s+want|find|search\s+for)\s+(?:me\s+)?(.+?)[\s.!?]*(?:\s+please)?[\s.!?]*$/
        guard let match = text.firstMatch(of: lead) else { return }
        let name = String(match.1)
        let said = Self.words(name)
        var words = said
        // What led to a fact already taken out: "play Commando with dual SID".
        while let last = words.last, Self.leadsToAFact.contains(last), !everyTitle.contains(words.joined(separator: " ")) {
            words.removeLast()
        }
        let moodWords = Set(Self.moods.values.flatMap { $0 })
        guard !words.isEmpty, everyTitle.contains(words.joined(separator: " ")), composers[words.joined(separator: " ")] == nil,
              // "Slow music" is a mood; "Crazy Comets" is a title.
              words.contains(where: { !Self.plainWords.contains($0) && !moodWords.contains($0) }) else { return }
        result.titleWords = words.count == said.count
            ? name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            : words.joined(separator: " ")
        result.titleIsATune = true
        text = ""
    }

    private static let leadsToAFact: Set<String> = ["with", "on", "in", "as", "using", "for", "at", "over", "only", "just"]

    /// What follows "like", "similar to" and so on, up to where the sentence
    /// moves on, split where it names several: "like Sanxion and Delta". A name
    /// that's a composer means them: "like Galway".
    private func readTune(_ text: inout String, into result: inout SmartUnderstanding) {
        let lead = /\b(?:sounds?\s+like|similar\s+to(?:\s+this\s+one\s*:?)?|like|based\s+on|close\s+to|closest\s+to|same\s+vibe\s+as|matches\s+for|in\s+the\s+style\s+of|style\s+of|fingerprint\s+of)\s+(.+)$/
        guard let match = text.firstMatch(of: lead) else { return }
        var name = String(match.1)
        if let end = name.firstMatch(of: /,?\s*(?:\b(?:but|for|that|with|by|only|ones|each|longer|from|until)\b|\.$)/) {
            name = String(name[..<end.range.lowerBound])
        }
        let rest = text[..<match.range.lowerBound] + " " + String(match.1).dropFirst(name.count)
        var tunes: [String] = []
        for part in name.split(whereSeparator: { ",/".contains($0) }).flatMap({ $0.components(separatedBy: " and ") }).flatMap({ $0.components(separatedBy: " or ") }) {
            // "The Last Ninja 3 theme" is the tune.
            let item = part.replacing(/\s+(?:theme|music|soundtrack|vibes?|tunes?|songs?|style|stuff|drum\s+patterns?)\s*$/, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let words = Self.words(item)
            guard !words.isEmpty else { continue }
            if let composer = composers[words.joined(separator: " ")] {
                Self.add(composer, to: &result)
            } else if !words.allSatisfy(Self.plainWords.contains),
                      tags(in: item).allSatisfy({ !Self.moods.keys.contains($0.tag) }) {
                tunes.append(item)
            }
        }
        // "Songs like chill ones" names a mood, and "like them" nothing.
        guard !tunes.isEmpty || !result.composers.isEmpty else { return }
        result.tuneNames = tunes
        text = String(rest)
    }

    private static func add(_ composer: SmartComposer, to result: inout SmartUnderstanding) {
        guard !result.composers.contains(where: { $0.folder == composer.folder }) else { return }
        result.composers.append(.init(folder: composer.folder, name: composer.name))
    }

    /// Several real titles in a row: "Delta, Knucklebusters, Crazy Comets", or
    /// "Cybernoid and Cybernoid II". Two or more, as one word alone could be
    /// anything.
    private func readTitleList(_ text: inout String, into result: inout SmartUnderstanding) {
        guard result.tuneNames.isEmpty, result.titleWords == nil else { return }
        let moodWords = Set(Self.moods.values.flatMap { $0 })
        var found: [String] = []
        for chunk in text.split(whereSeparator: { ",/:".contains($0) }).flatMap({ $0.components(separatedBy: " and ") })
            .flatMap({ $0.components(separatedBy: " or ") }).flatMap({ $0.components(separatedBy: " plus ") }) {
            let words = Self.words(chunk)
            search: for length in stride(from: words.count, through: 1, by: -1) {
                for start in 0...(words.count - length) {
                    let candidate = Array(words[start..<(start + length)])
                    let key = candidate.joined(separator: " ")
                    // "Slow music" is a mood; "Crazy Comets" is a title.
                    guard everyTitle.contains(key), composers[key] == nil,
                          candidate.contains(where: { !Self.plainWords.contains($0) && !moodWords.contains($0) }) else { continue }
                    // One word only if the rest say nothing: "stuff from
                    // Delta", not "title screens".
                    if length == 1, moodWords.contains(key) || Self.sayIt.contains(key)
                        || !words.allSatisfy({ $0 == key || Self.plainWords.contains($0) }) { continue }
                    found.append(key)
                    break search
                }
            }
        }
        guard found.count >= 2 else { return }
        result.tuneNames = found
        // Their words aren't moods as well: "Crazy Comets".
        text = Self.words(text).joined(separator: " ")
        for key in found { text = text.replacingOccurrences(of: key, with: " ") }
    }

    // MARK: Composers and moods

    private func tags(in text: String) -> [(tag: String, term: String)] {
        guard let gazetteer else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass, .lemma])
        tagger.setGazetteers([gazetteer], for: .nameTypeOrLexicalClass)
        tagger.string = text
        tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
        var found: [(tag: String, term: String)] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameTypeOrLexicalClass,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            // "Relaxes" and "harder" are their mood words too.
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            if let tag, Self.moods.keys.contains(tag.rawValue) || tag.rawValue == "composer" {
                found.append((tag.rawValue, String(text[range])))
            } else if let lemma, let mood = Self.moods.first(where: { $0.value.contains(lemma) })?.key {
                found.append((mood, String(text[range])))
            } else if let tag {
                found.append((tag.rawValue, String(text[range])))
            }
            return true
        }
        return found
    }

    private func readTags(_ text: inout String, into result: inout SmartUnderstanding, energyIsSettled: Bool) {
        var moods: [String] = []
        // A comma would split "Tel, Jeroen".
        text = text.replacingOccurrences(of: ",", with: " ")
        text.replace(/\s+/, with: " ")
        for found in tags(in: text) {
            switch found.tag {
            case "calm", "intense":
                moods.append(found.tag)
            case "rising":
                if !energyIsSettled { result.shape = .rising }
            case "falling":
                if !energyIsSettled { result.shape = .falling }
            case "composer":
                if let composer = composers[found.term] {
                    Self.add(composer, to: &result)
                    // Not a title's words as well.
                    text = text.replacingOccurrences(of: found.term, with: " ")
                }
            default:
                break
            }
        }
        if result.composers.isEmpty, let match = text.firstMatch(of: /\bby\s+([\p{L}\d-]+)/),
           let composer = handles[String(match.1)] {
            Self.add(composer, to: &result)
        }
        if !result.composers.isEmpty { text.replace(/\bby\s+/, with: " ") }
        if energyIsSettled { return }
        // The order of the moods is the shape: calm then intense rises.
        if let first = moods.first, let last = moods.last, first != last {
            result.shape = first == "calm" ? .rising : .falling
        } else if result.shape == .steady, let first = moods.first {
            result.energy = first == "calm" ? .calm : .intense
        }
    }

    /// A real title inside the sentence, longest first: "the last ninja", or
    /// "monty on the run by hubbard". It needs two words that say something,
    /// or to be the whole sentence, as tunes are called all sorts of things.
    private func readKnownTitle(_ text: String, into result: inout SmartUnderstanding) {
        guard result.tuneNames.isEmpty, result.titleWords == nil, !titles.isEmpty else { return }
        let words = Self.words(text)
        guard words.count >= 2 else { return }
        let moodWords = Set(Self.moods.values.flatMap { $0 })
        for length in stride(from: min(words.count, longestTitle), through: 2, by: -1) {
            for start in 0...(words.count - length) {
                let candidate = Array(words[start..<(start + length)])
                let key = candidate.joined(separator: " ")
                guard titles.contains(key), !candidate.contains(where: moodWords.contains) else { continue }
                let telling = candidate.filter { !Self.plainWords.contains($0) }.count
                // The whole sentence is the title: that tune and its versions.
                // Finding what sounds like it takes "like".
                if length == words.count, telling >= 1, result.composers.isEmpty {
                    result.titleWords = key
                    result.titleIsATune = true
                    return
                }
                if telling >= 2 {
                    result.tuneNames = [key]
                    return
                }
            }
        }
    }

    /// A handle that's also a word: "chill Hermit", "Laxity from the 90s". Those
    /// need "by" elsewhere, as Rock and Moon compose too, but once all the rest
    /// is understood, nothing else is left for such a word to mean.
    private func readLeftoverHandles(_ text: String, into result: inout SmartUnderstanding) {
        guard result.tuneNames.isEmpty, result.titleWords == nil, !result.isEmpty else { return }
        let moodWords = Set(Self.moods.values.flatMap { $0 })
        let left = Self.words(text).filter { !Self.plainWords.contains($0) && !Self.notNames.contains($0) && !moodWords.contains($0) }
        let found = left.compactMap { word -> SmartComposer? in
            guard !Self.sayIt.contains(word), !Self.notHandles.contains(word),
                  let composer = handles[word], composer.tunes >= 30 else { return nil }
            return composer
        }
        guard !left.isEmpty, found.count == left.count else { return }
        for composer in found { Self.add(composer, to: &result) }
    }

    /// Styles of music people ask for, which happen to be composers' handles.
    private static let notHandles: Set<String> = ["rock", "metal", "rap", "beat", "beats", "funk", "pop", "jazz", "trance", "techno", "house"]

    /// A slip of the keyboard in a name: "hubard", "rob hubard", "jeroen tell".
    private func readCloseComposer(_ text: String, into result: inout SmartUnderstanding) {
        guard result.composers.isEmpty, result.tuneNames.isEmpty, result.titleWords == nil, result.energy == .any,
              result.shape == .steady, result.sounds.isEmpty else { return }
        let words = Self.words(text).filter { !Self.plainWords.contains($0) && !Self.notNames.contains($0) }
        // A sentence of more than a name is about something else: "crazy" and
        // "later" are close to somebody, but real words.
        guard words.count <= 2 else { return }
        var candidates = zip(words, words.dropFirst()).map { "\($0) \($1)" }
        candidates += words.filter { $0.count >= 5 && english?.contains($0) != true }
        for candidate in candidates {
            let allowed = candidate.count >= 8 ? 2 : 1
            let close = composers.keys
                .filter { abs($0.count - candidate.count) <= allowed && $0 != candidate }
                .map { (key: $0, distance: Self.editDistance(candidate, $0, limit: allowed)) }
                .filter { $0.distance <= allowed }
                .sorted { ($0.distance, $0.key) < ($1.distance, $1.key) }
            if let best = close.first, let composer = composers[best.key] {
                Self.add(composer, to: &result)
                result.composerWasGuessed = true
                return
            }
        }
    }

    static func isPlain(_ word: String) -> Bool { plainWords.contains(word) }

    private static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 0..<a.count {
            var previous = row[0]
            row[0] = i + 1
            for j in 0..<b.count {
                let current = row[j + 1]
                row[j + 1] = a[i] == b[j] ? previous : 1 + min(previous, row[j], row[j + 1])
                previous = current
            }
            if row.min() ?? 0 > limit { return limit + 1 }
        }
        return row[b.count]
    }
}

/// Reading what's typed in Describe, and from search.
@MainActor
extension LibraryStore {
    /// Whether a search reads like a request for a list, not a name to find.
    func smartParserIfReady() -> SmartSentenceParser? { smartParser }

    func loadSmartParser() async -> SmartSentenceParser {
        if let smartParser { return smartParser }
        let core = player.core
        async let composers = core.smartComposers()
        async let titles = core.smartTitles()
        let (names, known) = await (composers, titles)
        let parser = await Task.detached { SmartSentenceParser(composers: names, titles: known) }.value
        smartParser = parser
        return parser
    }

    /// Put a sentence into the Smart Playlist. While it's being typed, words
    /// that mean nothing yet leave the list alone. Once it's final, there's
    /// always a list, and the note says what was done.
    func describe(_ sentence: String, isFinal: Bool) async {
        let sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return }
        let core = player.core
        // HVSC's Top 100 is a list already: it isn't for working out.
        if isFinal, sentence.lowercased().contains("top 100"), let list = player.hvscInfo?.playlists.first(where: {
            $0.name.localizedCaseInsensitiveContains("top 100")
        }) {
            shownSection = .curated(list.file)
            return
        }
        let parser = await loadSmartParser()
        var understood = parser.parse(sentence)
        var seeds: [SmartSettings.Seed] = []
        var note: String?
        var missing: [String] = []
        for name in understood?.tuneNames ?? [] {
            let found = await core.smartFindTunes(name: name, limit: 40)
            let folders = (understood?.composers ?? []).map { "/\($0.folder)/" }
            if let tune = found.first(where: { tune in folders.contains { tune.path.contains($0) } }) ?? found.first {
                seeds.append(.init(path: tune.path, title: tune.title, author: tune.author))
            } else {
                missing.append(name)
            }
        }
        if understood != nil, !missing.isEmpty {
            guard isFinal else { return }
            if seeds.isEmpty {
                understood?.tuneNames = []
                if understood?.composers.isEmpty == true { understood?.justShuffle = true }
                note = "No tune is called \(missing.joined(separator: " or ")), so here's a random mix."
            } else {
                note = "No tune is called \(missing.joined(separator: " or "))."
            }
        }
        // "Commando by Rob Hubbard" says which Commando; "fast Rob Hubbard
        // tracks like Commando" says whose tracks.
        if !seeds.isEmpty, sentence.lowercased().range(of: #"\bby\b"#, options: .regularExpression) != nil,
           understood?.composers.count == 1 {
            understood?.composers = []
        }
        if understood == nil {
            guard isFinal else { return }
            let guess = await bestGuess(sentence)
            understood = guess.0
            seeds = guess.1.map { [$0] } ?? []
            note = guess.2
        }
        // More has been typed since: this is about words that have moved on.
        guard !Task.isCancelled else { return }
        var next = smartSettings
        if next.sentence != sentence { next.isReordered = false }
        next.sentence = sentence
        next.understood = understood
        next.describedSeeds = seeds
        next.note = note
        if understood?.composerWasGuessed == true, let name = understood?.composerName {
            next.note = "Did you mean \(name)? Showing their tunes."
        }
        if let total = understood?.totalMinutes {
            next.totalMinutes = total
        } else if !(understood?.tuneNames.isEmpty ?? true) || !(understood?.composers.isEmpty ?? true)
                    || understood?.titleWords != nil || understood?.maxTunes != nil
                    || sentence.lowercased().range(of: #"\ball\b"#, options: .regularExpression) != nil {
            next.totalMinutes = nil
        } else {
            next.totalMinutes = 60
        }
        if next != smartSettings { smartSettings = next }
    }

    /// The closest to one tune, from a tune's menu or a picker.
    func describeTune(_ seed: SmartSettings.Seed) {
        var next = smartSettings
        next.sentence = "like \(seed.title)"
        next.isReordered = false
        next.understood = SmartUnderstanding(tuneNames: [seed.title])
        next.describedSeeds = [seed]
        next.note = nil
        next.totalMinutes = nil
        smartSettings = next
    }

    /// Back to the empty field and its suggestions.
    func clearSmartSentence() {
        var next = smartSettings
        next.sentence = ""
        next.isReordered = false
        next.understood = nil
        next.describedSeeds = []
        next.note = nil
        next.totalMinutes = 60
        smartSettings = next
    }

    /// Nothing in the sentence was recognised: its whole name as a tune, a word
    /// of it in titles, else a random mix. Whichever it is, it's said.
    private func bestGuess(_ sentence: String) async -> (SmartUnderstanding, SmartSettings.Seed?, String?) {
        let core = player.core
        let allWords = sentence.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let telling = allWords.filter { !SmartSentenceParser.isPlain($0) && !$0.allSatisfy(\.isNumber) }
        // "Play SIDs" and "Gimme some good C64 music" ask for anything.
        if telling.isEmpty { return (SmartUnderstanding(justShuffle: true), nil, nil) }
        if let tune = await core.smartFindTunes(name: sentence, limit: 1).first,
           tune.title.caseInsensitiveCompare(sentence) == .orderedSame {
            return (SmartUnderstanding(titleWords: sentence), nil, nil)
        }
        // A word in titles is a fair guess for a word or two, not a sentence.
        if allWords.count <= 2 {
            for word in telling.filter({ $0.count >= 4 }).sorted(by: { $0.count > $1.count }) where await core.smartFindTunes(name: word, limit: 5).count >= 3 {
                return (SmartUnderstanding(titleWords: word), nil, "Not sure about that, so here are tunes with “\(word)” in the title.")
            }
        }
        return (SmartUnderstanding(justShuffle: true), nil, "Not sure about that, so here's a random mix.")
    }
}
