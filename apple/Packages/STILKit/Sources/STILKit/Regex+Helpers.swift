import Foundation

/// Thin wrapper over NSRegularExpression with named groups and UTF-16 safe slicing.
/// (NSRegularExpression is used instead of Swift Regex so behavior matches ICU
/// across macOS versions; patterns are ICU syntax: named groups are (?<name>…).)
struct Rx: @unchecked Sendable {
    let re: NSRegularExpression

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        // Patterns are compile-time constants; a failure here is a programming error.
        self.re = try! NSRegularExpression(pattern: pattern, options: options)
    }

    struct Match {
        let result: NSTextCheckingResult
        let string: NSString

        var range: NSRange { result.range }
        var text: String { string.substring(with: result.range) }

        func group(_ name: String) -> String? {
            let r = result.range(withName: name)
            return r.location == NSNotFound ? nil : string.substring(with: r)
        }
        func group(_ index: Int) -> String? {
            guard index <= result.numberOfRanges - 1 else { return nil }
            let r = result.range(at: index)
            return r.location == NSNotFound ? nil : string.substring(with: r)
        }
        func has(_ name: String) -> Bool { result.range(withName: name).location != NSNotFound }
    }

    /// Anchored at the start, like Python's re.match.
    func matchPrefix(_ s: String) -> Match? {
        let ns = s as NSString
        guard let r = re.firstMatch(in: s, options: [.anchored], range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return Match(result: r, string: ns)
    }

    /// Like Python's re.search.
    func search(_ s: String) -> Match? {
        let ns = s as NSString
        guard let r = re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return Match(result: r, string: ns)
    }

    func matches(_ s: String) -> [Match] {
        let ns = s as NSString
        return re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
            .map { Match(result: $0, string: ns) }
    }

    /// Like Python's re.sub with a template ("$1" syntax).
    func replace(_ s: String, with template: String) -> String {
        let ns = s as NSString
        return re.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: ns.length),
                                           withTemplate: template)
    }
}

extension String {
    /// Python str.strip() for spaces/tabs.
    var stripped: String { trimmingCharacters(in: .whitespaces) }

    /// Python str.rstrip().
    var rstripped: String {
        var s = Substring(self)
        while let last = s.last, last.isWhitespace { s = s.dropLast() }
        return String(s)
    }

    /// Length the way the reference implementation counts it (Unicode scalars,
    /// i.e. Python len()), used for the wrap-width test.
    var scalarCount: Int { unicodeScalars.count }

    /// NSString-based substring by UTF-16 offsets.
    func utf16Slice(_ from: Int, _ to: Int? = nil) -> String {
        let ns = self as NSString
        let end = to ?? ns.length
        return ns.substring(with: NSRange(location: from, length: max(0, end - from)))
    }

    var utf16Length: Int { (self as NSString).length }
}
