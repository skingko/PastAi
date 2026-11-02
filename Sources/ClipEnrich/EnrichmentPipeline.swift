import AVFoundation
import ClipCore
import CoreGraphics
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers
import Vision

/// Resumes a continuation exactly once, with whichever result arrives first.
private final class FirstOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func settle(_ value: Bool) {
        lock.withLock {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}

/// Fills in what capture skipped to stay fast: thumbnails, media metadata and OCR.
/// Work runs one clip at a time at utility priority so a burst of copies cannot load the machine.
public actor EnrichmentPipeline {
    private let service: ClipService
    private var queue: [Int64] = []
    private var worker: Task<Void, Never>?

    static let thumbnailPixels = 520
    static let ocrByteLimit: Int64 = 30 * 1024 * 1024
    static let clipTimeLimit: Duration = .seconds(60)

    public init(service: ClipService) {
        self.service = service
    }

    /// New clips go to the front, so a copy gets its thumbnail straight away even during a long catch-up.
    public func enqueue(_ clipID: Int64) {
        guard !queue.contains(clipID) else { return }
        queue.insert(clipID, at: 0)
        startWorkerIfNeeded()
    }

    /// Catches up on clips captured while a previous run was interrupted, and on imports, page by page.
    public func backfill() async {
        var previous: [Int64] = []
        while let pending = try? await service.pendingEnrichment(limit: 500), !pending.isEmpty, pending != previous {
            queue.append(contentsOf: pending.filter { !queue.contains($0) })
            startWorkerIfNeeded()
            await drain()
            previous = pending
        }
    }

    /// Waits for the queue to empty. Used by tests.
    public func drain() async {
        await worker?.value
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task(priority: .utility) { [weak self] in
            while let next = await self?.dequeue() {
                await self?.processWithinLimit(next)
            }
            await self?.workerFinished()
        }
    }

    private func dequeue() -> Int64? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    private func workerFinished() {
        worker = nil
        if !queue.isEmpty { startWorkerIfNeeded() }
    }

    /// System thumbnailers can hang on a single file and never return. Waiting for them would leave every
    /// later clip without a thumbnail, so a clip that runs out of time is marked done without one.
    private func processWithinLimit(_ clipID: Int64) async {
        let finished = await Self.finishes(within: Self.clipTimeLimit) { [weak self] in await self?.process(clipID) }
        if !finished {
            try? await service.saveEnrichment(clipID: clipID, thumbnailPath: nil, ocrText: nil, metadata: nil)
        }
    }

    /// Unlike a task group, this returns even if `work` never does. It cannot stop such work, only stop waiting.
    static func finishes(within limit: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let outcome = FirstOutcome(continuation)
            let timer = Task {
                try? await Task.sleep(for: limit)
                if !Task.isCancelled { outcome.settle(false) }
            }
            Task {
                await work()
                timer.cancel()
                outcome.settle(true)
            }
        }
    }

    private func process(_ clipID: Int64) async {
        guard let detail = try? await service.detail(id: clipID) else { return }
        var metadata = ClipMetadata()
        var thumbnail: String?

        let file = detail.files.first.flatMap { service.resolveURL(for: $0) }
        let imageData = imagePayload(detail)
        let target = service.paths.thumbnails.appending(path: "\(clipID).jpg")

        switch detail.clip.kind {
        case .image:
            if let imageData, let info = ImageTools.writeThumbnail(from: .data(imageData), to: target, maxPixels: Self.thumbnailPixels) {
                metadata.pixelWidth = info.width
                metadata.pixelHeight = info.height
                thumbnail = target.lastPathComponent
            } else if let file, let info = ImageTools.writeThumbnail(from: .url(file), to: target, maxPixels: Self.thumbnailPixels) {
                metadata.pixelWidth = info.width
                metadata.pixelHeight = info.height
                thumbnail = target.lastPathComponent
            }
        case .video:
            if let file {
                let info = await MediaTools.inspect(file)
                metadata.durationSeconds = info.duration
                metadata.pixelWidth = info.width
                metadata.pixelHeight = info.height
                metadata.mediaTitle = info.title
                if let frame = await MediaTools.frame(of: file, at: 1), ImageTools.writeJPEG(frame, to: target, maxPixels: Self.thumbnailPixels) {
                    thumbnail = target.lastPathComponent
                }
            }
        case .audio:
            if let file {
                let info = await MediaTools.inspect(file)
                metadata.durationSeconds = info.duration
                metadata.mediaTitle = info.title
                metadata.artist = info.artist
                if let artwork = info.artwork, ImageTools.writeThumbnail(from: .data(artwork), to: target, maxPixels: Self.thumbnailPixels) != nil {
                    thumbnail = target.lastPathComponent
                }
            }
        case .file:
            if let file, await SystemThumbnail.write(for: file, to: target, maxPixels: Self.thumbnailPixels) {
                thumbnail = target.lastPathComponent
            }
        default:
            break
        }

        // Thumbnail first: a card should not wait on OCR, which takes far longer.
        try? await service.saveEnrichment(clipID: clipID, thumbnailPath: thumbnail, ocrText: nil, metadata: metadata)

        if detail.clip.kind == .image, detail.clip.byteSize <= Self.ocrByteLimit {
            let text: String?
            if let imageData {
                text = await TextRecognizer.recognize(.data(imageData))
            } else if let file {
                text = await TextRecognizer.recognize(.url(file))
            } else {
                text = nil
            }
            if let text, !text.isEmpty {
                try? await service.saveEnrichment(clipID: clipID, thumbnailPath: nil, ocrText: text, metadata: nil)
            }
        }
    }

    private func imagePayload(_ detail: ClipDetail) -> Data? {
        for uti in PasteboardTypes.images {
            if let representation = detail.representations.first(where: { $0.uti == uti }),
               let data = try? service.data(for: representation) {
                return data
            }
        }
        return nil
    }
}

public enum ImageSourceInput: Sendable {
    case data(Data)
    case url(URL)
}

public enum ImageTools {
    public struct PixelInfo: Sendable {
        public var width: Int
        public var height: Int
    }

    @discardableResult
    public static func writeThumbnail(from input: ImageSourceInput, to url: URL, maxPixels: Int) -> PixelInfo? {
        let source: CGImageSource?
        switch input {
        case .data(let data): source = CGImageSourceCreateWithData(data as CFData, nil)
        case .url(let file): source = CGImageSourceCreateWithURL(file as CFURL, nil)
        }
        guard let source, let image = thumbnail(of: source, maxPixels: maxPixels) else { return nil }
        guard writeJPEG(image, to: url, maxPixels: nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return PixelInfo(
            width: properties?[kCGImagePropertyPixelWidth] as? Int ?? image.width,
            height: properties?[kCGImagePropertyPixelHeight] as? Int ?? image.height
        )
    }

    /// Downscaled JPEG for handing an image to a vision model without uploading the full original.
    public static func jpegData(from input: ImageSourceInput, maxPixels: Int, quality: Double = 0.8) -> Data? {
        let source: CGImageSource?
        switch input {
        case .data(let data): source = CGImageSourceCreateWithData(data as CFData, nil)
        case .url(let file): source = CGImageSourceCreateWithURL(file as CFURL, nil)
        }
        guard let source, let image = thumbnail(of: source, maxPixels: maxPixels) else { return nil }
        return jpegData(image, quality: quality)
    }

    public static func jpegData(_ image: CGImage, quality: Double = 0.8) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    static func thumbnail(of source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func writeJPEG(_ image: CGImage, to url: URL, maxPixels: Int?) -> Bool {
        guard let data = jpegData(image) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

public enum MediaTools {
    public struct Info: Sendable {
        public var duration: Double?
        public var width: Int?
        public var height: Int?
        public var title: String?
        public var artist: String?
        public var artwork: Data?
    }

    public static func inspect(_ url: URL) async -> Info {
        let asset = AVURLAsset(url: url)
        var info = Info()
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            info.duration = duration.seconds
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            info.width = Int(size.width)
            info.height = Int(size.height)
        }
        if let items = try? await asset.load(.commonMetadata) {
            info.title = await string(in: items, key: .commonKeyTitle)
            info.artist = await string(in: items, key: .commonKeyArtist)
            if let artwork = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first {
                info.artwork = try? await artwork.load(.dataValue)
            }
        }
        return info
    }

    private static func string(in items: [AVMetadataItem], key: AVMetadataKey) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, withKey: key, keySpace: .common).first else { return nil }
        return try? await item.load(.stringValue)
    }

    public static func frame(of url: URL, at seconds: Double) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}

enum SystemThumbnail {
    static func write(for url: URL, to target: URL, maxPixels: Int) async -> Bool {
        let size = CGSize(width: maxPixels / 2, height: maxPixels / 2)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)
        // Its own generator, because one that hangs on a file also blocks every later request it receives.
        guard let representation = try? await QLThumbnailGenerator().generateBestRepresentation(for: request) else { return false }
        return ImageTools.writeJPEG(representation.cgImage, to: target, maxPixels: nil)
    }
}

public enum TextRecognizer {
    public static func recognize(_ input: ImageSourceInput) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].map(Locale.Language.init(identifier:))
        request.usesLanguageCorrection = true
        let observations: [RecognizedTextObservation]?
        switch input {
        case .data(let data): observations = try? await request.perform(on: data)
        case .url(let url): observations = try? await request.perform(on: url)
        }
        return observations?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
