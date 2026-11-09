import Foundation

/// Removes personal data from a KSCrash report before it leaves the Mac.
/// The original report remains untouched in KSCrash's local report store.
nonisolated enum CrashReportSanitizer {
    // Square brackets remain visible in Markdown. Angle brackets would be
    // interpreted as HTML-like tags when pasted into a GitHub issue.
    private static let redacted = "[redacted]"
    private static let redactedPath = "[redacted-path]"

    /// Keys whose values aren't needed to diagnose a crash, or whose values can
    /// identify the person or their Mac. Normalizing also catches snake_case.
    private static let sensitiveKeys: Set<String> = [
        "advertisingid",
        "commandline",
        "consolelog",
        "crashreporterkey",
        "deviceapphash",
        "email",
        "environment",
        "hostname",
        "installationid",
        "lastdeallocatedobject",
        "notableaddresses",
        "parentprocessid",
        "processid",
        "processstartmonotonicns",
        "processstartwallclockns",
        "runid",
        "serialnumber",
        "sessionid",
        "user",
        "userid",
        "userinfo",
        "username",
        "vendorid",
    ]

    static func sanitize(_ report: [String: Any]) -> [String: Any] {
        sanitizeDictionary(report, parentKey: nil)
    }

    static func jsonString(from report: [String: Any]) -> String? {
        let sanitized = sanitize(report)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(
                withJSONObject: sanitized,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func sanitizeDictionary(_ dictionary: [String: Any], parentKey: String?) -> [String: Any] {
        dictionary.reduce(into: [:]) { result, entry in
            let (key, value) = entry
            let normalizedKey = normalized(key)
            let isReportID = normalizedKey == "id" && parentKey.map(normalized) == "report"
            if sensitiveKeys.contains(normalizedKey) || isReportID {
                result[key] = redacted
            } else {
                result[key] = sanitizeValue(value, key: key)
            }
        }
    }

    private static func sanitizeValue(_ value: Any, key: String?) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            sanitizeDictionary(dictionary, parentKey: key)
        case let array as [Any]:
            array.map { sanitizeValue($0, key: key) }
        case let string as String:
            sanitizeString(string)
        default:
            value
        }
    }

    private static func sanitizeString(_ string: String) -> String {
        var result = string

        // A user's source, library and media filenames can all occur below a
        // home folder. Redact the whole path instead of only the account name.
        result = replacing(
            #"(?i)(?:file://(?:localhost)?)?/(?:Users|home)/[^\n\r\"']+"#,
            in: result,
            with: redactedPath
        )
        // External volume names and their paths often describe a music library.
        result = replacing(
            #"(?i)/Volumes/[^\n\r\"']+"#,
            in: result,
            with: redactedPath
        )
        result = replacing(
            #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            in: result,
            with: redacted
        )
        result = replacing(
            #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,
            in: result,
            with: redacted
        )
        return result
    }

    private static func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
        value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    private static func normalized(_ key: String) -> String {
        String(key.lowercased().filter(\.isLetter))
    }
}
