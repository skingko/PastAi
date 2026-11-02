import Foundation

/// Block-level Markdown for assistant replies. SwiftUI's `Text` only handles inline syntax, and replies
/// are re-parsed on every streamed chunk, so this stays a simple line scanner.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case quote(String)
    case code(language: String?, text: String)

    public static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String]?
        var language: String?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if codeLines != nil {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: language, text: (codeLines ?? []).joined(separator: "\n")))
                    codeLines = nil
                    language = nil
                } else {
                    codeLines?.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let name = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                language = name.isEmpty ? nil : name
                codeLines = []
            } else if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
            } else if let item = bullet(trimmed) {
                flushParagraph()
                if case .bullets(let items)? = blocks.last {
                    blocks[blocks.count - 1] = .bullets(items + [item])
                } else {
                    blocks.append(.bullets([item]))
                }
            } else if let item = numbered(trimmed) {
                flushParagraph()
                if case .numbered(let items)? = blocks.last {
                    blocks[blocks.count - 1] = .numbered(items + [item])
                } else {
                    blocks.append(.numbered([item]))
                }
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                let text = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if case .quote(let existing)? = blocks.last {
                    blocks[blocks.count - 1] = .quote(existing + "\n" + text)
                } else {
                    blocks.append(.quote(text))
                }
            } else {
                paragraph.append(trimmed)
            }
        }
        flushParagraph()
        // A fence still open means the reply is mid-stream; show what has arrived so far.
        if let codeLines {
            blocks.append(.code(language: language, text: codeLines.joined(separator: "\n")))
        }
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...4).contains(level), line.dropFirst(level).first == " " else { return nil }
        return .heading(level: level, text: line.dropFirst(level + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func bullet(_ line: String) -> String? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") else { return nil }
        return String(line.dropFirst(2))
    }

    private static func numbered(_ line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        return String(rest.dropFirst(2))
    }
}
