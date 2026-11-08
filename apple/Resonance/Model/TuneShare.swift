import Foundation
import PhosphorCore

/// A link to an HVSC tune, as shared from Resonance. Two spellings:
///
/// - the web link people paste, `<share server>/t/<code>?s=2&v=85`, whose
///   page shows a preview card and hands over to the app; the code is the
///   tune's 12-character share code (`shortCode`), `s` is left out for the
///   tune's start song;
/// - the app's own, `resonance://tune/<md5>?s=2&v=85&p=/MUSICIANS/…&t=…&a=…`,
///   which that page's Open in Resonance button opens.
///
/// The MD5 (Songlengths.md5's key) names the tune in every HVSC release;
/// the path finds it in an older one where the file differs.
nonisolated struct SharedTuneLink: Equatable, Hashable, Sendable, Identifiable {
    /// The tune's MD5, or its share code (from a web link); the core looks
    /// up either.
    var key: String
    /// 1-based; nil for the tune's start song.
    var subtune: Int?
    /// The sender's HVSC release.
    var hvsc: Int?
    /// "/MUSICIANS/H/Hubbard_Rob/Commando.sid"; only in the app's link.
    var hvscPath: String?
    /// Title and author, for while the tune is missing; only in the app's link.
    var title: String?
    var author: String?

    var id: Self { self }

    static let scheme = "resonance"

    /// The share server's address (Info.plist's ResonanceShareBaseURL, from
    /// the SHARE_BASE_URL build setting); nil turns sharing off.
    static let shareBase: URL? = base(Bundle.main.object(forInfoDictionaryKey: "ResonanceShareBaseURL") as? String)

    static func base(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let url = URL(string: raw.hasSuffix("/") ? String(raw.dropLast()) : raw),
              url.scheme == "https" || url.scheme == "http", url.host() != nil
        else { return nil }
        return url
    }

    init(key: String, subtune: Int? = nil, hvsc: Int? = nil, hvscPath: String? = nil, title: String? = nil, author: String? = nil) {
        // MD5s in any case; share codes are case-sensitive.
        self.key = Self.isMD5(key) ? key.lowercased() : key
        self.subtune = subtune
        self.hvsc = hvsc
        self.hvscPath = hvscPath
        self.title = title
        self.author = author
    }

    /// A link Resonance opens: the app's own, or a web link to `shareBase`.
    init?(url: URL, shareBase: URL? = SharedTuneLink.shareBase) {
        let raw: String?
        if url.scheme == Self.scheme, url.host() == "tune" {
            raw = url.pathComponents.dropFirst().first
        } else if let shareBase, url.scheme == shareBase.scheme, url.host() == shareBase.host(), url.port == shareBase.port {
            let prefix = shareBase.pathComponents.filter { $0 != "/" } + ["t"]
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count == prefix.count + 1, Array(parts.prefix(prefix.count)) == prefix else { return nil }
            raw = parts.last
        } else {
            return nil
        }
        guard let key = raw, Self.isMD5(key) || Self.isShortCode(key) else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        self.init(
            key: key,
            subtune: value("s").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil },
            hvsc: value("v").flatMap(Int.init),
            hvscPath: value("p").flatMap { $0.hasPrefix("/") && !$0.contains("..") ? $0 : nil },
            title: value("t"),
            author: value("a")
        )
    }

    /// A universal link: an https link macOS gave to the app. Every build's
    /// come from this address, though Debug shares through a local server.
    static let universalLinkBase = URL(string: "https://useresonance.app")!

    init?(activity: NSUserActivity) {
        guard activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL else { return nil }
        self.init(url: url, shareBase: Self.universalLinkBase)
    }

    /// The web link to paste: `<base>/t/<code>?s=2&v=85`.
    func webURL(base: URL) -> URL {
        let code = Self.shortCode(md5: key) ?? key
        var components = URLComponents(url: base.appending(path: "t").appending(path: code), resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = []
        if let subtune { query.append(URLQueryItem(name: "s", value: String(subtune))) }
        if let hvsc { query.append(URLQueryItem(name: "v", value: String(hvsc))) }
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

    static func isMD5(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy(\.isHexDigit)
    }

    static func isShortCode(_ value: String) -> Bool {
        value.count == 12 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// A tune's share code: the first 72 bits of its MD5 in base64url, 12
    /// characters; nil for anything but an MD5. The share server and the
    /// core make the same (`short_code` in share-server/src/tune.rs and
    /// core/src/share.rs).
    static func shortCode(md5: String) -> String? {
        guard isMD5(md5) else { return nil }
        let hex = Array(md5.utf8)
        let bytes = (0..<9).map { i in UInt8(String(decoding: hex[i * 2..<i * 2 + 2], as: UTF8.self), radix: 16)! }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    /// "Commando — Rob Hubbard", or nil when the link doesn't say.
    var name: String? {
        switch (title, author) {
        case let (title?, author?): "\(title) — \(author)"
        case let (title?, nil): title
        default: nil
        }
    }
}

/// What opening a shared link offers, from what this collection has and
/// what the HVSC mirror holds.
nonisolated enum SharedTuneOutcome: Equatable, Sendable {
    /// The collection has it (`sameFile`: the very file the sender played).
    /// `offerUpdate` is the newer release the sender has, offered but not
    /// needed.
    case play(path: String, sameFile: Bool, offerUpdate: Int?)
    /// Missing here; this newer release on the mirror should have it.
    case update(to: Int)
    /// Missing here, and the sender's release is newer than any this app
    /// has seen on the mirror.
    case checkForUpdate(senderHvsc: Int)
    /// No collection yet.
    case download
    /// Missing, and no newer release to get it from.
    case notFound

    static func decide(match: SharedTuneMatch, hasCollection: Bool, senderHvsc: Int?, latestHvsc: Int?) -> Self {
        guard hasCollection else { return .download }
        let installed = match.installedHvsc.map(Int.init)
        if let path = match.path {
            var offer: Int?
            if let sender = senderHvsc, let installed, sender > installed {
                offer = max(sender, latestHvsc ?? 0)
            }
            return .play(path: path, sameFile: match.sameFile, offerUpdate: offer)
        }
        if let sender = senderHvsc, sender > max(latestHvsc ?? 0, installed ?? 0) {
            return .checkForUpdate(senderHvsc: sender)
        }
        if let latest = latestHvsc, let installed, latest > installed {
            return .update(to: latest)
        }
        return .notFound
    }
}

/// A tune ready to share: its web link and what to call it.
nonisolated struct PreparedShare: Equatable, Sendable {
    let url: URL
    let title: String
    let author: String

    /// "Commando by Rob Hubbard", for a message or mail subject.
    var subject: String {
        author.isEmpty || author == "<?>" ? title : String(localized: "\(title) by \(author)")
    }
}
