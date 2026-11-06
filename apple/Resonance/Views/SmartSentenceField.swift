import FoundationModels
import PhosphorCore
import SwiftUI

/// What a sentence asked for, in the terms the Smart Playlist controls use.
/// It only ever fills in those controls, so a wrong guess shows up in plain
/// sight and can be changed.
nonisolated struct SmartSentence: Equatable, Sendable {
    var start = SmartSettings.Start.like
    var seed: SmartSettings.Seed?
    var minMinutes: UInt32?
    var totalMinutes: UInt32?
    var onlyUnheard = false
}

/// Reads a sentence by its words, on any Mac. What it finds is exact, so it
/// goes first; nil when it finds nothing to go on.
nonisolated enum SmartSentenceParser {
    static func parse(_ text: String) -> (sentence: SmartSentence, tuneName: String?)? {
        let lower = text.lowercased()
        var sentence = SmartSentence()
        var found = false

        let (minimum, total) = lengths(in: lower)
        sentence.minMinutes = minimum
        sentence.totalMinutes = total
        found = minimum != nil || total != nil

        if contains(lower, ["unheard", "never heard", "never played", "not heard", "haven't heard"]) {
            sentence.onlyUnheard = true
            found = true
        }

        // In order: "new to me" may also say "like", and chill may also say "new".
        if contains(lower, ["new to me", "opposite", "something different", "different from"]) {
            sentence.start = .newToMe
            sentence.onlyUnheard = true
            return (sentence, nil)
        }
        if contains(lower, ["chill", "slow", "calm", "relax", "intens", "build up", "builds up", "getting faster"]) {
            sentence.start = .chillToIntense
            return (sentence, nil)
        }
        if let name = tuneName(in: text) {
            sentence.start = .like
            return (sentence, name)
        }
        if sentence.onlyUnheard || contains(lower, ["random", "shuffle"]) {
            sentence.start = .neverHeard
            sentence.onlyUnheard = true
            return (sentence, nil)
        }
        return found ? (sentence, nil) : nil
    }

    private static func contains(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
    }

    /// "longer than 2 minutes" is each tune's length; "1 hour", "45 minutes"
    /// is the whole playlist's.
    private static func lengths(in text: String) -> (minimum: UInt32?, total: UInt32?) {
        var minimum: UInt32?
        var total: UInt32?
        let pattern = /(longer than|more than|at least|over|above)?\s*(\d+|an?|one|two|three)\s*[- ]?(hours?|hrs?|minutes?|mins?)\b/
        for match in text.matches(of: pattern) {
            let amount: UInt32 = switch match.2 {
            case "a", "an", "one": 1
            case "two": 2
            case "three": 3
            default: UInt32(match.2) ?? 0
            }
            guard amount > 0 else { continue }
            let minutes = match.3.hasPrefix("h") ? amount * 60 : amount
            if match.1 != nil, !match.3.hasPrefix("h") {
                minimum = minutes
            } else {
                total = minutes
            }
        }
        return (minimum, total)
    }

    /// What follows "like" or "similar to", up to where the sentence moves on.
    private static func tuneName(in text: String) -> String? {
        guard let match = text.firstMatch(of: /(?i)\b(sounds? like|similar to|like)\s+(.+)$/) else { return nil }
        var name = String(match.2)
        if let end = name.firstMatch(of: /(?i)\s*(,|\band\b|\bbut\b|\bfor\b|\blonger\b|\bover\b|\bthat\b|\bat least\b|\bwith\b|\d+\s*(hour|min))/) {
            name = String(name[..<end.range.lowerBound])
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return name.isEmpty ? nil : name
    }
}

/// The on-device model's reading of a sentence.
@Generable
private struct ParsedSentence {
    @Guide(description: "like: sounds like one named tune. neverHeard: random tunes never played before. chillToIntense: slow or chill music that gets more intense. newToMe: something different from or opposite to what the listener usually plays.", .anyOf(["like", "neverHeard", "chillToIntense", "newToMe"]))
    var start: String

    @Guide(description: "The name of the tune it should sound like, exactly as written, or an empty string when none is named.")
    var tuneName: String

    @Guide(description: "The shortest length of each tune in minutes, or 0 when none is mentioned.")
    var minimumMinutes: Int

    @Guide(description: "How long the whole playlist should play in minutes, or 0 when not mentioned.")
    var totalMinutes: Int

    @Guide(description: "True only when the listener asks for tunes they have never heard.")
    var onlyUnheard: Bool
}

/// The sentence box above a Smart Playlist's recipe. It runs on the Mac: the
/// parser first, then the on-device model where the Mac has one.
struct SmartSentenceField: View {
    let apply: (SmartSentence) -> Void

    @Environment(PlayerStore.self) private var store
    @State private var text = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Describe a playlist: slow chill music for an hour, getting more intense", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                    .disabled(working)
                if working {
                    ProgressView().controlSize(.small)
                }
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func submit() {
        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return }
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                guard let parsed = try await read(sentence) else {
                    problem = "Try naming a tune or a length, or words like chill, never heard or new to me."
                    return
                }
                var result = parsed.sentence
                if let name = parsed.tuneName {
                    let found = await store.core.smartFindTunes(name: name, limit: 40)
                    if let tune = found.first {
                        result.seed = .init(path: tune.path, title: tune.title, author: tune.author)
                        if found.count > 1 {
                            problem = "Using \(tune.title) by \(tune.author). Other tunes have a similar name: choose below."
                        }
                    } else {
                        problem = "No tune is called \(name). Choose one below."
                    }
                }
                apply(result)
            } catch {
                problem = "Try naming a tune or a length, or words like chill, never heard or new to me."
            }
        }
    }

    private func read(_ sentence: String) async throws -> (sentence: SmartSentence, tuneName: String?)? {
        if let parsed = SmartSentenceParser.parse(sentence) { return parsed }
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        return try await SmartSentenceReader.read(sentence)
    }
}

enum SmartSentenceReader {
    /// A sentence as settings, and the name of a tune still to look up. The
    /// model invents lengths nobody asked for, so numbers only count when
    /// the sentence has any.
    static func read(_ sentence: String) async throws -> (sentence: SmartSentence, tuneName: String?) {
        let session = LanguageModelSession(instructions: """
            You turn a request for a playlist of Commodore 64 SID music into settings. \
            Only fill in what the request says. Never invent a tune name.
            """)
        let parsed = try await session.respond(to: sentence, generating: ParsedSentence.self).content
        let hasNumbers = sentence.contains { $0.isNumber }
        return map(parsed.start, tuneName: parsed.tuneName, minimum: hasNumbers ? parsed.minimumMinutes : 0,
                   total: hasNumbers ? parsed.totalMinutes : 0, onlyUnheard: parsed.onlyUnheard)
    }

    /// Kept apart from the model, which a test can't rely on being here.
    static func map(_ start: String, tuneName: String, minimum: Int, total: Int, onlyUnheard: Bool)
        -> (sentence: SmartSentence, tuneName: String?)
    {
        var sentence = SmartSentence()
        sentence.start = SmartSettings.Start(rawValue: start) ?? .like
        if minimum > 0 { sentence.minMinutes = UInt32(clamping: minimum) }
        if total > 0 { sentence.totalMinutes = UInt32(clamping: total) }
        sentence.onlyUnheard = onlyUnheard
        let name = tuneName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (sentence, name.isEmpty ? nil : name)
    }
}
