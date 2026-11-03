import Foundation

// Render-ready model. Field names and JSON shape match the reference
// implementation's output exactly (see fixtures/*.expected.json), so the
// golden tests can decode the expected files straight into these types.

public struct STILEntry: Codable, Equatable, Sendable {
    public var path: String
    public var composer: STILComposer?
    public var sections: [STILSection]
}

public struct STILComposer: Codable, Equatable, Sendable {
    public var name: String
    public var initials: String
    public var aliases: [String]
}

public struct STILSection: Codable, Equatable, Sendable {
    /// nil = applies to the whole file; otherwise the 1-based subtune number from "(#n)".
    public var subtune: Int?
    public var names: [String]
    public var authors: [String]
    public var covers: [STILCover]
    /// Two or more covers carry timestamps: render as a medley timeline.
    public var isMedley: Bool
    public var comments: [STILComment]
}

public struct STILCover: Codable, Equatable, Sendable {
    /// nil when the title is "<?>" (then `unknown` is true) or when ARTIST came without TITLE.
    public var title: String?
    public var unknown: Bool
    /// Text after "[from …]", e.g. "the arcade game Commando".
    public var source: String?
    /// Seconds into the subtune where this part starts / ends ("(0:53)" or "(1:16-1:32)").
    public var at: Int?
    public var until: Int?
    /// nil when ARTIST is missing or "<?>".
    public var artist: String?
}

public struct STILComment: Codable, Equatable, Sendable {
    public var blocks: [STILBlock]
    public var memoriam: Bool
    /// First sentence of the comment, typeset; for the tune-list second line.
    public var teaser: String
    /// Every HVSC path linked from this comment (sorted, unique).
    public var links: [String]
}

public struct STILBlock: Codable, Equatable, Sendable {
    /// `question`: an interviewer's "Q: " line; the quote after it is the answer.
    public enum Kind: String, Codable, Sendable { case note, quote, question }
    public enum Role: String, Codable, Sendable { case composer }

    public var kind: Kind
    /// Display name of the person quoted ("Rob Hubbard", "Freaky DNA", or raw initials if unresolved).
    public var by: String?
    /// .composer only when confirmed. nil means "unknown", never "someone else".
    public var role: Role?
    public var paragraphs: [[STILRun]]
    /// The tool a quote's tune was made with, when its lead-in names one
    /// ("SW1.8 "…" (NP)": "SW1.8"). Absent from the JSON when nil.
    public var label: String? = nil
}

/// One styled stretch of text inside a paragraph.
public struct STILRun: Codable, Equatable, Sendable {
    public var t: String
    /// HVSC path of another tune, e.g. "/MUSICIANS/T/Tel_Jeroen/Get_Ready.sid".
    public var link: String?
    /// Subtune referenced right after the link (", Tune #2").
    public var subtune: Int?
    public var url: String?
    public var em: Bool?
    /// Chip model, PAL/NTSC or $hex address: render in monospace.
    public var tech: Bool?

    public init(t: String, link: String? = nil, subtune: Int? = nil, url: String? = nil,
                em: Bool? = nil, tech: Bool? = nil) {
        self.t = t; self.link = link; self.subtune = subtune; self.url = url; self.em = em; self.tech = tech
    }
}

/// A timeline segment for a medley subtune.
public struct STILMedleySegment: Equatable, Sendable {
    public var title: String
    public var artist: String?
    public var start: Int
    public var end: Int?
}
