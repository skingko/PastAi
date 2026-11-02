import Foundation
import Testing
@testable import ClipCore

/// Reads Swift source just well enough to find string literals, skipping comments and following
/// interpolations, so literals nested inside one are found too.
private struct SwiftLiterals {
    struct Literal {
        var text: String
        var isLocalized: Bool
    }

    private let source: [Unicode.Scalar]
    private(set) var found: [Literal] = []

    init(_ text: String) {
        source = Array(text.unicodeScalars)
        scan(from: 0, to: source.count)
    }

    private func matches(_ text: String, at index: Int) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard index + scalars.count <= source.count else { return false }
        return scalars.indices.allSatisfy { source[index + $0] == scalars[$0] }
    }

    private mutating func scan(from start: Int, to end: Int) {
        var index = start
        while index < end {
            if matches("//", at: index) {
                while index < end, source[index] != "\n" { index += 1 }
            } else if matches("/*", at: index) {
                while index < end, !matches("*/", at: index) { index += 1 }
                index += 2
            } else if source[index] == "#", matches("#\"", at: index) {
                index = endOfRawLiteral(from: index)
            } else if source[index] == "\"" {
                index = readLiteral(from: index)
            } else {
                index += 1
            }
        }
    }

    private func endOfRawLiteral(from start: Int) -> Int {
        var index = start + 2
        while index < source.count, !matches("\"#", at: index) { index += 1 }
        return index + 2
    }

    private mutating func readLiteral(from start: Int) -> Int {
        let multiline = matches("\"\"\"", at: start)
        let closer = multiline ? "\"\"\"" : "\""
        var index = start + closer.count
        var body = String.UnicodeScalarView()
        while index < source.count, !matches(closer, at: index) {
            if matches("\\(", at: index) {
                let open = index + 2
                index = endOfInterpolation(from: open)
                body.append(contentsOf: "%@".unicodeScalars)
                scan(from: open, to: index - 1)
            } else if source[index] == "\\", index + 1 < source.count {
                let escaped = source[index + 1]
                body.append(escaped == "n" ? "\n" : escaped)
                index += 2
            } else {
                body.append(source[index])
                index += 1
            }
        }
        let isCall = start >= 2 && source[start - 2] == "L" && source[start - 1] == "("
        let standsAlone = start < 3 || !(CharacterSet.alphanumerics.contains(source[start - 3]) || source[start - 3] == "_")
        found.append(Literal(text: String(body), isLocalized: isCall && standsAlone))
        return index + closer.count
    }

    private func endOfInterpolation(from start: Int) -> Int {
        var index = start
        var depth = 1
        while index < source.count, depth > 0 {
            if source[index] == "\"" {
                index += 1
                while index < source.count, source[index] != "\"" {
                    index += source[index] == "\\" ? 2 : 1
                }
            } else if source[index] == "(" {
                depth += 1
            } else if source[index] == ")" {
                depth -= 1
            }
            index += 1
        }
        return index
    }
}

@Suite struct LocalizationTests {
    /// Chinese here is data rather than interface text: detection patterns and language names.
    private static let notInterfaceText = [
        "ContentAnalysis.swift", "Localization.swift", "EnglishStrings.swift", "main.swift",
    ]
    private static let keywords: Set<String> = ["密码", "口令", "密钥", "私钥", "账号"]

    private func literals() throws -> [SwiftLiterals.Literal] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var found: [SwiftLiterals.Literal] = []
        for folder in ["Sources", "App"] {
            guard let walker = FileManager.default.enumerator(at: root.appending(path: folder), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker {
                let name = url.lastPathComponent
                guard url.pathExtension == "swift", !name.hasPrefix("._"), !Self.notInterfaceText.contains(name) else { continue }
                found += SwiftLiterals(try String(contentsOf: url, encoding: .utf8)).found
            }
        }
        return found
    }

    private func isChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    @Test func allInterfaceTextGoesThroughL() throws {
        let unwrapped = try literals().filter { !$0.isLocalized && isChinese($0.text) && !Self.keywords.contains($0.text) }
        #expect(unwrapped.map(\.text) == [])
    }

    @Test func everyStringHasAnEnglishTranslation() throws {
        let keys = Set(try literals().filter(\.isLocalized).map(\.text))
        #expect(keys.subtracting(L10n.english.keys).sorted() == [])
    }

    @Test func noTranslationOutlivesItsString() throws {
        let keys = Set(try literals().filter(\.isLocalized).map(\.text))
        #expect(Set(L10n.english.keys).subtracting(keys).sorted() == [])
    }

    @Test func translationsKeepEveryPlaceholderAndLoseTheChinese() {
        func slots(_ text: String) -> Int {
            text.components(separatedBy: "%@").count - 1 + (1...3).reduce(0) { $0 + text.components(separatedBy: "%\($1)$@").count - 1 }
        }
        for (key, english) in L10n.english {
            #expect(slots(key) == slots(english), "\(key)")
            #expect(!isChinese(english), "\(key)")
        }
    }

    @Test func interpolationBecomesTheLookupKey() {
        let count = 3
        #expect(L10n.resolve("删除 \(count) 项", language: .english) == "Delete 3 items")
        #expect(L10n.resolve("删除 \(count) 项", language: .chinese) == "删除 3 项")
    }

    @Test func pluralFollowsTheFirstValue() {
        #expect(L10n.resolve("删除 \(1) 项", language: .english) == "Delete 1 item")
        #expect(L10n.resolve("\(1) 个文件 · \("2 MB")", language: .english) == "1 file · 2 MB")
        #expect(L10n.resolve("\(4) 个文件 · \("2 MB")", language: .english) == "4 files · 2 MB")
    }

    @Test func translationsMayReorderValues() {
        let text = L10n.resolve("用 \("mini") 处理 \(40) 条（约 \(9)K tokens）", language: .english)
        #expect(text == "Process 40 clips with mini (about 9K tokens)")
    }

    @Test func aValueThatLooksLikeATemplateIsLeftAlone() {
        #expect(L10n.resolve("修改「\("100%@ {s}")」", language: .chinese) == "修改「100%@ {s}」")
        #expect(L10n.resolve("把 \("%2$@") 条放入「\("x")」", language: .english) == "Put %2$@ clips in “x”")
    }

    @Test func unknownTextFallsBackToTheSource() {
        #expect(L10n.resolve("不在表里的文字", language: .english) == "不在表里的文字")
    }
}
