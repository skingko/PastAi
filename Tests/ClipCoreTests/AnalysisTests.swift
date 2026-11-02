import AppKit
import Foundation
import Testing
@testable import ClipCore

@Suite struct SearchTextTests {
    @Test func segmentSplitsCJKAndKeepsLatinWordsWhole() {
        #expect(SearchText.segment("远程部署nginx配置") == "远 程 部 署 nginx 配 置")
        #expect(SearchText.segment("hello world") == "hello world")
    }

    @Test func matchExpressionBuildsPhrases() {
        #expect(SearchText.matchExpression(for: "部署") == "\"部 署\"")
        #expect(SearchText.matchExpression(for: "nginx 配置") == "\"nginx\"* \"配 置\"")
        #expect(SearchText.matchExpression(for: "ngin") == "\"ngin\"*")
    }

    @Test func punctuationOnlyQueryHasNoMatchExpression() {
        #expect(SearchText.matchExpression(for: "://") == nil)
        #expect(SearchText.matchExpression(for: "   ") == nil)
    }

    @Test func quotesCannotBreakOutOfThePhrase() {
        #expect(SearchText.matchExpression(for: "a\"b") == "\"a\"\"b\"*")
    }
}

@Suite struct ClassifierTests {
    @Test(arguments: [
        ("#FF8A1F", ClipKind.color),
        ("rgb(10, 20, 30)", .color),
        ("https://pasteapp.io/help", .link),
        ("mailto:a@b.com", .link),
        ("今天的会议纪要写完了", .text),
        ("ssh -p 2222 deploy@10.0.0.8 'cd /srv/app'", .code),
        ("curl -fsSL https://example.com/install.sh | sh", .code),
        ("Hello; this is a sentence.\nAnd another one.", .text),
        ("import Foundation\n\nfunc main() {\n    print(1)\n}\n", .code),
        ("server {\n    listen 80;\n    location / {\n        proxy_pass http://app;\n    }\n}", .code),
    ])
    func classify(input: String, expected: ClipKind) {
        #expect(TextClassifier.classify(input) == expected)
    }

    @Test func urlInsideASentenceIsNotALink() {
        #expect(TextClassifier.classify("see https://a.com for details") == .text)
    }
}

@Suite struct SensitiveDetectorTests {
    @Test(arguments: [
        "-----BEGIN OPENSSH PRIVATE KEY-----\nabc",
        "sk-abcdefghijklmnopqrstuvwxyz123456",
        "ghp_abcdefghijklmnopqrstuvwxyz1234567890",
        "AKIAIOSFODNN7EXAMPLE",
        "password: hunter2hunter",
        "密码：abc12345",
        "4111 1111 1111 1111",
        "11010519491231002X",
    ])
    func detects(_ text: String) {
        #expect(SensitiveDetector.isSensitive(text))
    }

    @Test(arguments: ["今天天气不错", "order number 1234567890123456", "the skate park is open", "110105194912310021"])
    func ignores(_ text: String) {
        #expect(!SensitiveDetector.isSensitive(text))
    }
}

@Suite struct ClipBuilderTests {
    let source = SourceInfo(bundleID: "com.test", name: "Test")

    func entry(_ uti: String, _ text: String = "x") -> PasteboardEntry { PasteboardEntry(uti: uti, data: Data(text.utf8)) }

    @Test func imageWinsWhenDeclaredBeforeText() throws {
        let snapshot = PasteboardSnapshot(items: [[entry("public.png", "png"), entry("public.utf8-plain-text", "caption")]])
        #expect(try #require(ClipBuilder.build(snapshot, source: source)).kind == .image)
    }

    @Test func textWinsOverRenderedImageFromOfficeApps() throws {
        let snapshot = PasteboardSnapshot(items: [[entry("public.utf8-plain-text", "A1\tB1"), entry("public.html"), entry("public.png")]])
        #expect(try #require(ClipBuilder.build(snapshot, source: source)).kind == .text)
    }

    @Test func browserImageWithUrlTextIsAnImage() throws {
        let snapshot = PasteboardSnapshot(items: [[entry("public.utf8-plain-text", "https://a.com/x.png"), entry("public.png")]])
        #expect(try #require(ClipBuilder.build(snapshot, source: source)).kind == .image)
    }

    @Test func tiffDroppedWhenPngIsPresent() throws {
        let snapshot = PasteboardSnapshot(items: [[entry("public.png"), entry("public.tiff")]])
        let draft = try #require(ClipBuilder.build(snapshot, source: source))
        #expect(draft.entries.map(\.entry.uti) == ["public.png"])
    }

    @Test func privateTypesAreKeptForRoundTrip() throws {
        let snapshot = PasteboardSnapshot(items: [[entry("com.figma.private"), entry("public.utf8-plain-text", "frame")]])
        let draft = try #require(ClipBuilder.build(snapshot, source: source))
        #expect(draft.kind == .text)
        #expect(draft.entries.map(\.entry.uti).contains("com.figma.private"))
    }

    @Test func unknownBinaryBecomesOther() throws {
        let snapshot = PasteboardSnapshot(items: [[entry("com.acme.scene")]])
        #expect(try #require(ClipBuilder.build(snapshot, source: source)).kind == .other)
    }

    @Test func filesAreClassifiedByType() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appending(path: "clip.mp4")
        let song = directory.appending(path: "song.mp3")
        let note = directory.appending(path: "notes.txt")
        for url in [movie, song, note] { try Data("x".utf8).write(to: url) }

        func kind(_ urls: URL...) throws -> ClipKind {
            let items = urls.map { [PasteboardEntry(uti: "public.file-url", data: Data($0.absoluteString.utf8))] }
            return try #require(ClipBuilder.build(PasteboardSnapshot(items: items), source: source)).kind
        }
        #expect(try kind(movie) == .video)
        #expect(try kind(song) == .audio)
        #expect(try kind(note) == .file)
        #expect(try kind(movie, song) == .file)
    }
}
