import AppKit
import AVFoundation
import ClipCore
import Foundation
import Testing
@testable import ClipEnrich

private func makeService() throws -> ClipService {
    let root = FileManager.default.temporaryDirectory.appending(path: "pastai-enrich-\(UUID().uuidString)", directoryHint: .isDirectory)
    return try ClipService(paths: AppPaths(root: root))
}

/// Draws text onto a white canvas so OCR has something real to read.
private func renderPNG(_ text: String, size: NSSize = NSSize(width: 900, height: 220)) throws -> Data {
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    (text as NSString).draw(
        at: NSPoint(x: 40, y: 70),
        withAttributes: [.font: NSFont.systemFont(ofSize: 64, weight: .medium), .foregroundColor: NSColor.black]
    )
    image.unlockFocus()
    let tiff = try #require(image.tiffRepresentation)
    return try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
}

@Suite(.serialized) struct EnrichmentTests {
    @Test func imageGetsThumbnailDimensionsAndSearchableOCR() async throws {
        let service = try makeService()
        let snapshot = PasteboardSnapshot(items: [[PasteboardEntry(uti: PasteboardTypes.png, data: try renderPNG("远程部署 Nginx"))]])
        let draft = try #require(ClipBuilder.build(snapshot, source: SourceInfo(bundleID: nil, name: nil)))
        let id = try await service.ingest(draft).clipID

        let pipeline = EnrichmentPipeline(service: service)
        await pipeline.enqueue(id)
        await pipeline.drain()

        let clip = try #require(try await service.detail(id: id)).clip
        #expect(clip.enrichedAt != nil)
        #expect((clip.metadata.pixelWidth ?? 0) >= 900)
        let thumbnail = try #require(clip.thumbnailPath)
        #expect(FileManager.default.fileExists(atPath: service.paths.thumbnails.appending(path: thumbnail).path))
        #expect(clip.ocrText?.contains("部署") == true)
        #expect(try await service.list(ClipQuery(text: "部署")).map(\.id) == [id])
    }

    @Test func fileClipGetsSystemThumbnail() async throws {
        let service = try makeService()
        let file = service.paths.root.appending(path: "notes.txt")
        try "hello quick look".write(to: file, atomically: true, encoding: .utf8)
        let snapshot = PasteboardSnapshot(items: [[PasteboardEntry(uti: PasteboardTypes.fileURL, data: Data(file.absoluteString.utf8))]])
        let draft = try #require(ClipBuilder.build(snapshot, source: SourceInfo(bundleID: nil, name: nil)))
        let id = try await service.ingest(draft).clipID

        let pipeline = EnrichmentPipeline(service: service)
        await pipeline.enqueue(id)
        await pipeline.drain()

        let clip = try #require(try await service.detail(id: id)).clip
        #expect(clip.enrichedAt != nil)
        #expect(clip.thumbnailPath != nil)
    }

    @Test func videoGetsDurationAndFrame() async throws {
        let service = try makeService()
        let url = service.paths.root.appending(path: "movie.mp4")
        try await writeTestMovie(to: url)
        let snapshot = PasteboardSnapshot(items: [[PasteboardEntry(uti: PasteboardTypes.fileURL, data: Data(url.absoluteString.utf8))]])
        let draft = try #require(ClipBuilder.build(snapshot, source: SourceInfo(bundleID: nil, name: nil)))
        #expect(draft.kind == .video)
        let id = try await service.ingest(draft).clipID

        let pipeline = EnrichmentPipeline(service: service)
        await pipeline.enqueue(id)
        await pipeline.drain()

        let clip = try #require(try await service.detail(id: id)).clip
        #expect(abs((clip.metadata.durationSeconds ?? 0) - 3) < 0.1)
        #expect(clip.metadata.pixelWidth == 320)
        #expect(clip.thumbnailPath != nil)
    }

    @Test func backfillPicksUpClipsLeftUnprocessed() async throws {
        let service = try makeService()
        let snapshot = PasteboardSnapshot(items: [[PasteboardEntry(uti: PasteboardTypes.plainText, data: Data("text".utf8))]])
        let draft = try #require(ClipBuilder.build(snapshot, source: SourceInfo(bundleID: nil, name: nil)))
        let id = try await service.ingest(draft).clipID

        let pipeline = EnrichmentPipeline(service: service)
        await pipeline.backfill()
        await pipeline.drain()
        #expect(try await service.detail(id: id)?.clip.enrichedAt != nil)
    }

    private func writeTestMovie(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer)
        let frame = try #require(buffer)
        for second in 0...2 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(frame, withPresentationTime: CMTime(seconds: Double(second), preferredTimescale: 600))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 3, preferredTimescale: 600))
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
