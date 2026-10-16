import Foundation

/// Removes credentials from strings before they reach any log (spec §7).
public enum Redactor {
    private static let patterns: [String] = [
        #"(?i)bearer\s+[A-Za-z0-9\-\._~\+/]+=*"#,
        #"ya29\.[A-Za-z0-9\-_]+"#,  // Google access tokens
        #"1//[A-Za-z0-9\-_]{20,}"#,  // Google refresh tokens
        #"sk-[A-Za-z0-9\-_]{16,}"#,  // OpenAI / Anthropic style keys
        #"gh[pousr]_[A-Za-z0-9]{20,}"#,  // GitHub tokens
        #"xox[abpr]-[A-Za-z0-9\-]{10,}"#,  // Slack tokens
        #"AKIA[0-9A-Z]{16}"#,  // AWS access key id
        #"(?i)(access_token|refresh_token|id_token|client_secret|password|api_key|apikey|token)(["']?\s*[:=]\s*["']?)[^\s"'&,}]+"#,
    ]

    private static let regexes: [NSRegularExpression] = patterns.compactMap {
        try? NSRegularExpression(pattern: $0)
    }

    public static func redact(_ input: String) -> String {
        var output = input
        for (index, regex) in regexes.enumerated() {
            let range = NSRange(output.startIndex..., in: output)
            let template = index == regexes.count - 1 ? "$1$2[REDACTED]" : "[REDACTED]"
            output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: template)
        }
        return output
    }

    /// Shortens a string for compact display (never used to hide content from the decision UI).
    public static func truncate(_ input: String, limit: Int) -> String {
        guard input.count > limit, limit > 1 else { return input }
        return String(input.prefix(limit - 1)) + "…"
    }
}
