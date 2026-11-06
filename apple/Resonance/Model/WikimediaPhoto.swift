#if CSDB // Debug builds only until CSDb's admins have had their say.

import AppKit

/// A composer's photo from Wikimedia Commons, with what its license asks for.
/// A proof of concept, behind a Settings toggle that's off by default.
struct WikimediaPhoto {
    let image: NSImage
    /// "C64Scener, CC BY-SA 4.0".
    let credit: String
    /// The file's page on Commons: its author, license and history.
    let page: URL
}

/// Reading Wikipedia's and Commons' answers; pure, so they can be tested
/// without the network.
nonisolated enum WikimediaPhotos {
    struct Candidate: Equatable {
        /// The Commons file name: "Rob_Hubbard.jpg".
        let file: String
        let thumbnail: URL
    }

    /// The article's photo, if it's about a game music composer and the
    /// photo is on Commons.
    ///
    /// A name alone isn't enough: "Jon Wells" on Wikipedia is a rugby player.
    /// Images outside Commons are often non-free, used on Wikipedia only.
    static func candidate(fromSummary data: Data) -> Candidate? {
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data),
              summary.type == "standard",
              isAboutGameMusic((summary.description ?? "") + " " + (summary.extract ?? "")),
              let original = summary.originalimage?.source,
              let thumbnail = summary.thumbnail?.source,
              let url = URL(string: original), url.path.contains("/wikipedia/commons/"),
              let thumbnailURL = URL(string: thumbnail)
        else { return nil }
        return Candidate(file: url.lastPathComponent, thumbnail: thumbnailURL)
    }

    static func isAboutGameMusic(_ text: String) -> Bool {
        text.range(of: #"\b(commodore|c64|video ?games?|computer games?|chiptune|game music|sid chip)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "Author, License" from a Commons file's metadata, only for a free
    /// license: Creative Commons or public domain.
    static func credit(fromMetadata data: Data) -> String? {
        guard let answer = try? JSONDecoder().decode(Metadata.self, from: data),
              let fields = answer.query.pages.values.first?.imageinfo?.first?.extmetadata,
              let license = fields["LicenseShortName"]?.value,
              license.hasPrefix("CC") || license.localizedCaseInsensitiveContains("public domain") || license.hasPrefix("PD")
        else { return nil }
        let artist = fields["Artist"]?.value
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let artist, !artist.isEmpty else { return license }
        return "\(artist), \(license)"
    }

    private struct Summary: Decodable {
        struct Image: Decodable { let source: String }
        let type: String?
        let description: String?
        let extract: String?
        let thumbnail: Image?
        let originalimage: Image?
    }

    private struct Metadata: Decodable {
        struct Query: Decodable { let pages: [String: Page] }
        struct Page: Decodable { let imageinfo: [Info]? }
        struct Info: Decodable { let extmetadata: [String: Field]? }
        struct Field: Decodable { let value: String }
        let query: Query
    }
}

extension CSDbStore {
    /// Looks for a photo of a composer under each name they go by, once per
    /// launch. Does nothing unless the Settings toggles for CSDb and photos
    /// are both on.
    func loadPhoto(names: [String]) async {
        guard isEnabled, UserDefaults.standard.bool(forKey: Pref.composerPhotos),
              let key = names.first, !checkedPhotos.contains(key) else { return }
        checkedPhotos.insert(key)
        for name in names {
            let title = name.replacingOccurrences(of: " ", with: "_")
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_-.,'()")))
            guard let title,
                  let summaryURL = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(title)"),
                  let (summary, _) = try? await session.data(from: summaryURL),
                  let candidate = WikimediaPhotos.candidate(fromSummary: summary)
            else { continue }

            var metadata = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
            metadata.queryItems = [
                .init(name: "action", value: "query"), .init(name: "format", value: "json"),
                .init(name: "prop", value: "imageinfo"), .init(name: "iiprop", value: "extmetadata"),
                .init(name: "iiextmetadatafilter", value: "Artist|LicenseShortName"),
                .init(name: "titles", value: "File:\(candidate.file)")
            ]
            guard let url = metadata.url, let (info, _) = try? await session.data(from: url),
                  let credit = WikimediaPhotos.credit(fromMetadata: info),
                  let (bytes, _) = try? await session.data(from: candidate.thumbnail),
                  let image = NSImage(data: bytes),
                  let page = URL(string: "https://commons.wikimedia.org/wiki/File:\(candidate.file)")
            else { continue }
            composerPhotos[key] = WikimediaPhoto(image: image, credit: credit, page: page)
            return
        }
    }
}

#endif
