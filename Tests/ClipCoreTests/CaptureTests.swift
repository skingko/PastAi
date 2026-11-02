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

    private func capturedFile(_ harness: Harness, _ file: URL) async throws -> ClipDetail {
        put(harness.pasteboard, [(PasteboardTypes.fileURL, Data(file.absoluteString.utf8))])
        harness.capture.poll()
        await harness.capture.drain()
        let id = try #require(try await harness.service.list(ClipQuery()).first).id
        return try #require(try await harness.service.detail(id: id))
    }

    private func temporaryFolder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func copiedFilesAreRecordedByPathAlone() async throws {
        let harness = try makeHarness()
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "report.pdf")
        try Data("pdf bytes".utf8).write(to: file)

        let detail = try await capturedFile(harness, file)
        #expect(detail.clip.kind == .file)
        #expect(detail.files.first?.snapshotPath == nil)
        #expect(!FileManager.default.fileExists(atPath: harness.service.paths.files.appending(path: String(detail.clip.id)).path))
        #expect(harness.service.resolveURL(for: detail.files[0])?.path == detail.files[0].originalPath)
    }

    @Test func finderReferenceURLsBecomeRealPaths() async throws {
        let harness = try makeHarness()
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "report.pdf")
        try Data("pdf bytes".utf8).write(to: file)
        let reference = try #require((file as NSURL).perform(#selector(NSURL.fileReferenceURL))?.takeUnretainedValue() as? NSURL)
        #expect(reference.absoluteString?.hasPrefix("file:///.file/id=") == true)

        put(harness.pasteboard, [(PasteboardTypes.fileURL, Data((reference.absoluteString ?? "").utf8))])
        harness.capture.poll()
        await harness.capture.drain()

        let id = try #require(try await harness.service.list(ClipQuery()).first).id
        let stored = try #require(try await harness.service.detail(id: id)?.files.first)
        #expect(stored.fileName == "report.pdf")
        #expect(URL(fileURLWithPath: stored.originalPath).resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
    }

    @Test func foldersAreRecordedByPathAlone() async throws {
        let harness = try makeHarness()
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("inside".utf8).write(to: directory.appending(path: "inside.txt"))

        let detail = try await capturedFile(harness, directory)
        #expect(detail.clip.kind == .file)
        #expect(detail.files.first?.isDirectory == true)
        #expect(detail.files.first?.snapshotPath == nil)
    }

    @Test func pastingAFileThatIsGoneReportsItAndLeavesThePasteboardAlone() async throws {
        let harness = try makeHarness()
        let directory = try temporaryFolder()
        let file = directory.appending(path: "report.pdf")
        try Data("pdf bytes".utf8).write(to: file)
        let detail = try await capturedFile(harness, file)
        try FileManager.default.removeItem(at: directory)

        put(harness.pasteboard, [(PasteboardTypes.plainText, Data("before".utf8))])
        let writer = PasteWriter(service: harness.service, pasteboard: harness.pasteboard)
        #expect(throws: MissingFilesError(names: ["report.pdf"])) {
            try writer.write([detail], mode: .original)
        }
        #expect(harness.pasteboard.string(forType: .string) == "before")

        try writer.write([detail], mode: .plainText)
        #expect(harness.pasteboard.string(forType: .string) == detail.files[0].originalPath)
    }

    @Test func oneMissingFileBlocksAMultiPasteRatherThanDroppingIt() async throws {
        let harness = try makeHarness()
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = directory.appending(path: "kept.pdf")
        let gone = directory.appending(path: "gone.pdf")
        try Data("a".utf8).write(to: kept)
        try Data("b".utf8).write(to: gone)
        let first = try await capturedFile(harness, kept)
        let second = try await capturedFile(harness, gone)
        try FileManager.default.removeItem(at: gone)

        let writer = PasteWriter(service: harness.service, pasteboard: harness.pasteboard)
        #expect(throws: MissingFilesError(names: ["gone.pdf"])) {
            try writer.write([first, second], mode: .original)
        }
    }

    @Test func aFileInTheTrashCountsAsGone() async throws {
        let harness = try makeHarness()
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "report.pdf")
        try Data("pdf bytes".utf8).write(to: file)
        let detail = try await capturedFile(harness, file)

        let trash = directory.appending(path: ".Trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: trash.appending(path: "report.pdf"))

        #expect(harness.service.resolveURL(for: detail.files[0]) == nil)
    }

    @Test func aMovedFileIsFollowed() async throws {
        let harness = try makeHarness()
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "report.pdf")
        let moved = directory.appending(path: "renamed.pdf")
        try Data("pdf bytes".utf8).write(to: file)
        let detail = try await capturedFile(harness, file)
        try FileManager.default.moveItem(at: file, to: moved)

        #expect(try Data(contentsOf: #require(harness.service.resolveURL(for: detail.files[0]))) == Data("pdf bytes".utf8))
    }

    @Test func screenshotsKeepTheirOwnCopy() async throws {
        let harness = try makeHarness()
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/PastAiTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "shot.png")
        try Data("pixels".utf8).write(to: file)
        let marker = Data([1])
        #expect(marker.withUnsafeBytes { setxattr(file.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, $0.count, 0, 0) } == 0)

        let detail = try await capturedFile(harness, file)
        try #require(detail.files.first?.snapshotPath != nil)
        try FileManager.default.removeItem(at: file)
        #expect(try Data(contentsOf: #require(harness.service.resolveURL(for: detail.files[0]))) == Data("pixels".utf8))
    }

    @Test func picturesInTemporaryFoldersKeepTheirOwnCopy() async throws {
        let harness = try makeHarness()
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "capture.png")
        try Data("pixels".utf8).write(to: file)

        let detail = try await capturedFile(harness, file)
        #expect(detail.clip.kind == .image)
        #expect(detail.files.first?.snapshotPath != nil)
    }

    @Test func oldFileCopiesAreReleasedOnlyWhileTheOriginalExists() async throws {
        let harness = try makeHarness()
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = directory.appending(path: "kept.pdf")
        let gone = directory.appending(path: "gone.pdf")
        try Data("a".utf8).write(to: kept)
        try Data("b".utf8).write(to: gone)
        var details = [try await capturedFile(harness, kept), try await capturedFile(harness, gone)]
        for detail in details {
            let relative = "\(detail.clip.id)/0-\(detail.files[0].fileName)"
            let copy = harness.service.paths.files.appending(path: relative)
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: detail.files[0].originalPath, toPath: copy.path)
            try await harness.service.setSnapshot(fileID: detail.files[0].id, relativePath: relative)
        }
        try FileManager.default.removeItem(at: gone)

        #expect(try await harness.service.releaseFileSnapshots() == 1)

        details = [
            try #require(try await harness.service.detail(id: details[0].clip.id)),
            try #require(try await harness.service.detail(id: details[1].clip.id)),
        ]
        #expect(details[0].files[0].snapshotPath == nil)
        #expect(!FileManager.default.fileExists(atPath: harness.service.paths.files.appending(path: String(details[0].clip.id)).path))
        #expect(try Data(contentsOf: #require(harness.service.resolveURL(for: details[1].files[0]))) == Data("b".utf8))
    }
}
