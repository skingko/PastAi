import AppKit
import Foundation
import Testing
@testable import ClipCore

/// Runs against a private named pasteboard so tests never touch the real clipboard.
@MainActor
@Suite(.serialized) struct CaptureTests {
    struct Harness {
        let service: ClipService
        let settings: AppSettings
        let pasteboard: NSPasteboard
        let capture: CaptureService
    }

    func makeHarness() throws -> Harness {
        let service = try makeService()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "pastai.test.\(UUID().uuidString)")!)
        let pasteboard = NSPasteboard(name: .init("pastai.test.\(UUID().uuidString)"))
        let capture = CaptureService(service: service, settings: settings, pasteboard: pasteboard)
        return Harness(service: service, settings: settings, pasteboard: pasteboard, capture: capture)
    }

    func put(_ pasteboard: NSPasteboard, _ entries: [(String, Data)]) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        for (type, data) in entries { item.setData(data, forType: .init(type)) }
        pasteboard.writeObjects([item])
    }

    @Test func capturesTextWithAllRepresentations() async throws {
        let harness = try makeHarness()
        put(harness.pasteboard, [
            (PasteboardTypes.plainText, Data("hello".utf8)),
            (PasteboardTypes.html, Data("<b>hello</b>".utf8)),
            ("com.acme.private", Data([9, 9])),
        ])
        harness.capture.poll()
        await harness.capture.drain()

        let clips = try await harness.service.list(ClipQuery())
        #expect(clips.count == 1)
        let detail = try #require(try await harness.service.detail(id: clips[0].id))
        #expect(detail.clip.plainText == "hello")
        #expect(Set(detail.representations.map(\.uti)) == [PasteboardTypes.plainText, PasteboardTypes.html, "com.acme.private"])
    }

    @Test(arguments: ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"])
    func skipsMarkedSecrets(marker: String) async throws {
        let harness = try makeHarness()
        put(harness.pasteboard, [(PasteboardTypes.plainText, Data("hunter2".utf8)), (marker, Data())])
        harness.capture.poll()
        await harness.capture.drain()
        #expect(try await harness.service.list(ClipQuery()).isEmpty)
    }

    @Test func recordsNothingWhilePaused() async throws {
        let harness = try makeHarness()
        harness.settings.togglePause()
        put(harness.pasteboard, [(PasteboardTypes.plainText, Data("paused".utf8))])
        harness.capture.poll()
        await harness.capture.drain()
        #expect(try await harness.service.list(ClipQuery()).isEmpty)
    }

    @Test func ignoredAppsAreSkippedByBundleID() throws {
        let harness = try makeHarness()
        #expect(!harness.capture.shouldCapture(types: [PasteboardTypes.plainText], frontmostBundleID: "com.1password.1password"))
        #expect(harness.capture.shouldCapture(types: [PasteboardTypes.plainText], frontmostBundleID: "com.apple.Safari"))
    }

    @Test func pasteRoundTripPreservesEveryRepresentationAndIsNotRecaptured() async throws {
        let harness = try makeHarness()
        let large = Data(repeating: 7, count: 100_000)
        put(harness.pasteboard, [
            (PasteboardTypes.plainText, Data("doc".utf8)),
            ("com.acme.private", large),
        ])
        harness.capture.poll()
        await harness.capture.drain()
        let id = try #require(try await harness.service.list(ClipQuery()).first).id
        let detail = try #require(try await harness.service.detail(id: id))

        harness.pasteboard.clearContents()
        let writer = PasteWriter(service: harness.service, pasteboard: harness.pasteboard)
        try writer.write([detail], mode: .original)

        #expect(harness.pasteboard.data(forType: .init("com.acme.private")) == large)
        #expect(harness.pasteboard.string(forType: .string) == "doc")

        harness.capture.poll()
        await harness.capture.drain()
        let after = try await harness.service.list(ClipQuery())
        #expect(after.count == 1)
        #expect(after[0].copyCount == 1)
    }

    @Test func plainTextPasteDropsFormatting() async throws {
        let harness = try makeHarness()
        put(harness.pasteboard, [
            (PasteboardTypes.plainText, Data("doc".utf8)),
            (PasteboardTypes.html, Data("<b>doc</b>".utf8)),
        ])
        harness.capture.poll()
        await harness.capture.drain()
        let id = try #require(try await harness.service.list(ClipQuery()).first).id
        let detail = try #require(try await harness.service.detail(id: id))

        let writer = PasteWriter(service: harness.service, pasteboard: harness.pasteboard)
        try writer.write([detail], mode: .plainText)
        #expect(harness.pasteboard.string(forType: .string) == "doc")
        #expect(harness.pasteboard.data(forType: .html) == nil)
    }

    @Test func fileClipSurvivesTheOriginalBeingDeleted() async throws {
        let harness = try makeHarness()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "report.pdf")
        try Data("pdf bytes".utf8).write(to: file)

        put(harness.pasteboard, [(PasteboardTypes.fileURL, Data(file.absoluteString.utf8))])
        harness.capture.poll()
        await harness.capture.drain()

        let id = try #require(try await harness.service.list(ClipQuery()).first).id
        let detail = try #require(try await harness.service.detail(id: id))
        #expect(detail.clip.kind == .file)
        let snapshot = try #require(detail.files.first?.snapshotPath)
        #expect(snapshot.hasSuffix("report.pdf"))

        try FileManager.default.removeItem(at: directory)
        let resolved = try #require(harness.service.resolveURL(for: detail.files[0]))
        #expect(try Data(contentsOf: resolved) == Data("pdf bytes".utf8))
    }

    @Test func filesOverTheLimitStayByReference() async throws {
        let harness = try makeHarness()
        harness.settings.snapshotLimitMB = 0
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        try Data("movie".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        put(harness.pasteboard, [(PasteboardTypes.fileURL, Data(file.absoluteString.utf8))])
        harness.capture.poll()
        await harness.capture.drain()

        let id = try #require(try await harness.service.list(ClipQuery()).first).id
        let detail = try #require(try await harness.service.detail(id: id))
        #expect(detail.clip.kind == .video)
        #expect(detail.files.first?.snapshotPath == nil)
    }
}
