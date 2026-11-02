import AppKit
import UniformTypeIdentifiers

public struct SourceInfo: Sendable, Hashable {
    public var bundleID: String?
    public var name: String?

    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }
}

public struct DraftFile: Sendable, Hashable {
    public var path: String
    public var fileName: String
    public var uti: String?
    public var byteSize: Int64
    public var isDirectory: Bool
    public var bookmark: Data?
}

public struct CaptureDraft: Sendable, Hashable {
    public var kind: ClipKind
    public var plainText: String?
    public var contentHash: String
    public var entries: [(itemIndex: Int, position: Int, entry: PasteboardEntry)]
    public var files: [DraftFile]
    public var source: SourceInfo
    public var isSensitive: Bool
    public var metadata: ClipMetadata

    public static func == (lhs: CaptureDraft, rhs: CaptureDraft) -> Bool { lhs.contentHash == rhs.contentHash }
    public func hash(into hasher: inout Hasher) { hasher.combine(contentHash) }

    public var byteSize: Int64 {
        entries.reduce(Int64(0)) { $0 + Int64($1.entry.data.count) } + files.reduce(Int64(0)) { $0 + $1.byteSize }
    }
}

/// Turns a raw snapshot into what gets stored. Pure apart from `stat`-ing copied files, so it is easy to test.
public enum ClipBuilder {
    /// Files on a pasteboard are references; everything else is captured by value up to this limit.
    static let maxRepresentationBytes = 256 * 1024 * 1024

    public static func build(_ snapshot: PasteboardSnapshot, source: SourceInfo) -> CaptureDraft? {
        guard !snapshot.items.isEmpty else { return nil }
        if let draft = fileDraft(snapshot, source: source) { return draft }

        let text = extractText(snapshot)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let entries = storableEntries(snapshot)

        if let image = primaryImage(snapshot), prefersImage(snapshot, text: trimmed, imageUTI: image.uti) {
            return CaptureDraft(
                kind: .image,
                plainText: trimmed.isEmpty ? nil : text,
                contentHash: Hashing.sha256("image:" + Hashing.sha256(image.data)),
                entries: entries,
                files: [],
                source: source,
                isSensitive: false,
                metadata: ClipMetadata()
            )
        }

        if !trimmed.isEmpty, let text {
            return CaptureDraft(
                kind: TextClassifier.classify(text),
                plainText: text,
                contentHash: textHash(text),
                entries: entries,
                files: [],
                source: source,
                isSensitive: SensitiveDetector.isSensitive(text),
                metadata: ClipMetadata()
            )
        }

        if let image = primaryImage(snapshot) {
            return CaptureDraft(
                kind: .image,
                plainText: nil,
                contentHash: Hashing.sha256("image:" + Hashing.sha256(image.data)),
                entries: entries,
                files: [],
                source: source,
                isSensitive: false,
                metadata: ClipMetadata()
            )
        }

        guard !entries.isEmpty else { return nil }
        var hasher = Data()
        for stored in entries {
            hasher.append(Data(stored.entry.uti.utf8))
            hasher.append(stored.entry.data)
        }
        return CaptureDraft(
            kind: .other,
            plainText: nil,
            contentHash: Hashing.sha256("other:" + Hashing.sha256(hasher)),
            entries: entries,
            files: [],
            source: source,
            isSensitive: false,
            metadata: ClipMetadata()
        )
    }

    public static func textHash(_ text: String) -> String { Hashing.sha256("text:" + text) }

    /// Declared order is fidelity order. Office apps offer a rendered PNG behind the text and browsers
    /// offer the image URL as text behind the image, so whichever comes first decides.
    private static func prefersImage(_ snapshot: PasteboardSnapshot, text: String, imageUTI: String) -> Bool {
        if text.isEmpty { return true }
        if TextClassifier.isLink(text) { return true }
        guard let first = snapshot.items.first else { return false }
        let imageIndex = first.firstIndex { PasteboardTypes.images.contains($0.uti) }
        let textIndex = first.firstIndex { [PasteboardTypes.plainText, PasteboardTypes.rtf, PasteboardTypes.html].contains($0.uti) }
        guard let imageIndex else { return false }
        guard let textIndex else { return true }
        return imageIndex < textIndex
    }

    private static func primaryImage(_ snapshot: PasteboardSnapshot) -> PasteboardEntry? {
        guard let item = snapshot.items.first(where: { $0.contains { PasteboardTypes.images.contains($0.uti) } }) else { return nil }
        for uti in PasteboardTypes.images {
            if let entry = item.first(where: { $0.uti == uti }) { return entry }
        }
        return nil
    }

    private static func extractText(_ snapshot: PasteboardSnapshot) -> String? {
        let entries = snapshot.items.flatMap(\.self)
        let plain = snapshot.items.compactMap { item in
            item.first { $0.uti == PasteboardTypes.plainText }.flatMap { String(data: $0.data, encoding: .utf8) }
        }
        if !plain.isEmpty { return plain.joined(separator: "\n") }
        if let rtf = entries.first(where: { $0.uti == PasteboardTypes.rtf }),
           let attributed = NSAttributedString(rtf: rtf.data, documentAttributes: nil) {
            return attributed.string
        }
        if let html = entries.first(where: { $0.uti == PasteboardTypes.html }), let source = String(data: html.data, encoding: .utf8) {
            return source
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
        return nil
    }

    private static func storableEntries(_ snapshot: PasteboardSnapshot) -> [(itemIndex: Int, position: Int, entry: PasteboardEntry)] {
        var stored: [(itemIndex: Int, position: Int, entry: PasteboardEntry)] = []
        var total = 0
        for (itemIndex, item) in snapshot.items.enumerated() {
            let hasCompressedImage = item.contains { ["public.png", "public.jpeg", "public.heic"].contains($0.uti) }
            for (position, entry) in item.enumerated() {
                // TIFF is often ten times the size of the PNG next to it and adds no information.
                if hasCompressedImage, entry.uti == PasteboardTypes.tiff { continue }
                guard total + entry.data.count <= maxRepresentationBytes else { continue }
                total += entry.data.count
                stored.append((itemIndex, position, entry))
            }
        }
        return stored
    }

    private static func fileDraft(_ snapshot: PasteboardSnapshot, source: SourceInfo) -> CaptureDraft? {
        let urls = snapshot.items.compactMap { item -> URL? in
            guard let entry = item.first(where: { $0.uti == PasteboardTypes.fileURL }),
                  let string = String(data: entry.data, encoding: .utf8),
                  let url = URL(string: string), url.isFileURL else { return nil }
            return url.standardizedFileURL
        }
        guard !urls.isEmpty else { return nil }

        var identity = ""
        let files = urls.map { url -> DraftFile in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey, .contentTypeKey])
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            identity += "\(url.path)|\(values?.fileSize ?? 0)|\(modified)\n"
            return DraftFile(
                path: url.path,
                fileName: url.lastPathComponent,
                uti: values?.contentType?.identifier ?? UTType(filenameExtension: url.pathExtension)?.identifier,
                byteSize: Int64(values?.fileSize ?? 0),
                isDirectory: values?.isDirectory ?? false,
                bookmark: try? url.bookmarkData()
            )
        }

        return CaptureDraft(
            kind: kind(forFiles: files),
            plainText: files.map(\.fileName).joined(separator: "\n"),
            contentHash: Hashing.sha256("files:" + identity),
            entries: [],
            files: files,
            source: source,
            isSensitive: false,
            metadata: ClipMetadata(fileCount: files.count)
        )
    }

    private static func kind(forFiles files: [DraftFile]) -> ClipKind {
        let kinds = Set(files.map { file -> ClipKind in
            guard !file.isDirectory, let uti = file.uti, let type = UTType(uti) else { return .file }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            return .file
        })
        return kinds.count == 1 ? kinds.first! : .file
    }
}
