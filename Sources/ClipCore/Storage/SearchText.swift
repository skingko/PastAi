import Foundation

/// FTS5's unicode61 tokenizer treats a run of Chinese as one token and trigram cannot match two-character
/// words, so CJK text is split into single characters before indexing and queried as a phrase.
public enum SearchText {
    public static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FFFF:
            return true
        default:
            return false
        }
    }

    public static func segment(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        output.reserveCapacity(text.unicodeScalars.count)
        var previousWasCJK = false
        for scalar in text.unicodeScalars {
            let cjk = isCJK(scalar)
            if (cjk || previousWasCJK), let last = output.last, last != " " {
                output.append(" ")
            }
            output.append(scalar)
            previousWasCJK = cjk
        }
        return String(output)
    }

    /// Builds an FTS5 MATCH expression, or nil when the query has nothing the tokenizer could index,
    /// such as `://`. Callers fall back to a substring scan for those.
    public static func matchExpression(for query: String) -> String? {
        var phrases: [String] = []
        for term in query.split(whereSeparator: \.isWhitespace) {
            let scalars = String(term).unicodeScalars
            guard scalars.contains(where: { isCJK($0) || CharacterSet.alphanumerics.contains($0) }) else { continue }
            let tokens = segment(String(term)).split(separator: " ").joined(separator: " ")
            let phrase = "\"" + tokens.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let endsInCJK = scalars.last.map(isCJK) ?? false
            phrases.append(endsInCJK ? phrase : phrase + "*")
        }
        return phrases.isEmpty ? nil : phrases.joined(separator: " ")
    }

    public static func likePattern(for query: String) -> String {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }
}
