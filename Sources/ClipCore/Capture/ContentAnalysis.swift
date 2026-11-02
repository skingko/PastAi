import Foundation

public enum TextClassifier {
    private static let hexColor = try! NSRegularExpression(pattern: "^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")
    private static let functionalColor = try! NSRegularExpression(pattern: "^(?:rgb|hsl)a?\\([^)]{3,40}\\)$", options: .caseInsensitive)
    private static let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let linkSchemes: Set<String> = ["http", "https", "ftp", "ssh", "file", "mailto"]

    private static let codeKeywords = try! NSRegularExpression(
        pattern: "^\\s*(?:import |from \\S+ import|func |def |class |struct |enum |interface |const |let |var |return |if \\(|for \\(|while \\(|#include|package |public |private |function |server \\{|location |SELECT |INSERT |UPDATE |DELETE |CREATE TABLE)",
        options: [.anchorsMatchLines]
    )

    private static let shellCommand = try! NSRegularExpression(
        pattern: "^(?:sudo |\\$ )?(?:ssh|scp|rsync|curl|wget|git|docker|kubectl|npm|pnpm|yarn|brew|pip3?|python3?|node|cargo|swift|make|cd|ls|cat|grep|sed|awk|chmod|chown|mkdir|rm|mv|cp|tar|systemctl|nginx) [^\\n]+$"
    )

    public static func classify(_ text: String) -> ClipKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .text }
        if isColor(trimmed) { return .color }
        if isLink(trimmed) { return .link }
        if isShellCommand(trimmed) || isCode(text) { return .code }
        return .text
    }

    static func isShellCommand(_ text: String) -> Bool {
        guard text.count <= 2_000 else { return false }
        return shellCommand.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isColor(_ text: String) -> Bool {
        guard text.count <= 48 else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return hexColor.firstMatch(in: text, range: range) != nil || functionalColor.firstMatch(in: text, range: range) != nil
    }

    static func isLink(_ text: String) -> Bool {
        guard text.count <= 4096, !text.contains(where: \.isWhitespace) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = linkDetector.firstMatch(in: text, range: range), match.range == range, let url = match.url else { return false }
        return url.scheme.map { linkSchemes.contains($0.lowercased()) } ?? false
    }

    /// Scores structural signals. Needs several lines so prose containing one semicolon stays text.
    static func isCode(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        guard lines.count >= 2 else { return false }
        let sample = lines.prefix(200)
        var score = 0
        for line in sample {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if ["{", "}", ";", "};", "});", "=>", ":"].contains(where: trimmed.hasSuffix) { score += 2 }
            if line.hasPrefix("    ") || line.hasPrefix("\t") { score += 1 }
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("#!") { score += 2 }
        }
        let sampleText = sample.joined(separator: "\n")
        let keywordHits = codeKeywords.numberOfMatches(in: sampleText, range: NSRange(sampleText.startIndex..., in: sampleText))
        score += keywordHits * 2
        return Double(score) >= Double(sample.count) * 1.2
    }
}

/// Marks content that looks like a credential. The clip stays in local history but is hidden from AI.
public enum SensitiveDetector {
    private static let patterns: [NSRegularExpression] = [
        "-----BEGIN [A-Z ]*PRIVATE KEY-----",
        "\\bsk-[A-Za-z0-9_-]{20,}",
        "\\bgh[pousr]_[A-Za-z0-9]{30,}",
        "\\bgithub_pat_[A-Za-z0-9_]{30,}",
        "\\bAKIA[0-9A-Z]{16}\\b",
        "\\bxox[abprs]-[A-Za-z0-9-]{10,}",
        "\\bAIza[0-9A-Za-z_-]{35}\\b",
        "\\beyJ[A-Za-z0-9_-]{10,}\\.eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}",
        "(?i)\\b(?:password|passwd|pwd|secret|api[_-]?key|access[_-]?token|密码|口令)\\s*[:=：]\\s*\\S{4,}",
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let cardCandidate = try! NSRegularExpression(pattern: "\\b(?:\\d[ -]?){13,19}\\b")
    private static let chineseID = try! NSRegularExpression(pattern: "\\b\\d{17}[\\dXx]\\b")

    public static func isSensitive(_ text: String) -> Bool {
        let sample = String(text.prefix(20_000))
        let range = NSRange(sample.startIndex..., in: sample)
        if patterns.contains(where: { $0.firstMatch(in: sample, range: range) != nil }) { return true }
        if matches(cardCandidate, in: sample, range: range, where: passesLuhn) { return true }
        return matches(chineseID, in: sample, range: range, where: isValidChineseID)
    }

    private static func matches(_ regex: NSRegularExpression, in text: String, range: NSRange, where isValid: (String) -> Bool) -> Bool {
        regex.matches(in: text, range: range).contains { match in
            Range(match.range, in: text).map { isValid(String(text[$0])) } ?? false
        }
    }

    static func passesLuhn(_ candidate: String) -> Bool {
        let digits = candidate.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset.isMultiple(of: 2) {
                sum += digit
            } else {
                sum += digit * 2 > 9 ? digit * 2 - 9 : digit * 2
            }
        }
        return sum.isMultiple(of: 10)
    }

    static func isValidChineseID(_ candidate: String) -> Bool {
        let characters = Array(candidate.uppercased())
        guard characters.count == 18 else { return false }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let checks = Array("10X98765432")
        var sum = 0
        for index in 0..<17 {
            guard let digit = characters[index].wholeNumberValue else { return false }
            sum += digit * weights[index]
        }
        return checks[sum % 11] == characters[17]
    }
}
