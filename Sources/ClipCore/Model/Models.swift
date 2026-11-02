import Foundation

public enum ClipKind: String, Sendable, CaseIterable, Codable, Identifiable {
    case text, link, code, color, image, video, audio, file, other

    public var id: String { rawValue }

    /// The whole category, for tabs and filters, where English wants a plural.
    public var categoryName: String {
        switch (AppLanguage.current, self) {
        case (.english, .link), (.english, .color), (.english, .image), (.english, .video), (.english, .file): displayName + "s"
        default: displayName
        }
    }

    public var displayName: String {
        switch self {
        case .text: L("文本")
        case .link: L("链接")
        case .code: L("代码")
        case .color: L("颜色")
        case .image: L("图片")
        case .video: L("视频")
        case .audio: L("音频")
        case .file: L("文件")
        case .other: L("其他")
        }
    }

    public var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .color: "paintpalette"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .file: "doc"
        case .other: "shippingbox"
        }
    }

    public var isTextual: Bool {
        switch self {
        case .text, .link, .code, .color: true
        default: false
        }
    }
}

public struct ClipMetadata: Codable, Sendable, Hashable {
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var durationSeconds: Double?
    public var fileCount: Int?
    public var mediaTitle: String?
    public var artist: String?

    public init(
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        durationSeconds: Double? = nil,
        fileCount: Int? = nil,
        mediaTitle: String? = nil,
        artist: String? = nil
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
        self.fileCount = fileCount
        self.mediaTitle = mediaTitle
        self.artist = artist
    }
}

public struct Clip: Identifiable, Sendable, Hashable {
    public var id: Int64
    public var kind: ClipKind
    public var title: String?
    /// Truncated in list queries; `ClipService.detail(id:)` returns the full text.
    public var plainText: String?
    public var textLength: Int
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var contentHash: String
    public var byteSize: Int64
    public var createdAt: Date
    public var lastCopiedAt: Date
    public var lastUsedAt: Date?
    public var copyCount: Int
    public var useCount: Int
    public var isSensitive: Bool
    public var aiHidden: Bool
    public var ocrText: String?
    public var metadata: ClipMetadata
    public var thumbnailPath: String?
    public var enrichedAt: Date?
    public var deletedAt: Date?

    public var isTextTruncated: Bool { (plainText?.count ?? 0) < textLength }

    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let first = plainText?.split(whereSeparator: \.isNewline).first {
            return String(first.prefix(80))
        }
        return kind.displayName
    }
}

public struct Representation: Sendable, Hashable, Codable {
    public var itemIndex: Int
    public var position: Int
    public var uti: String
    public var inlineData: Data?
    public var blobHash: String?
    public var byteSize: Int64

    public init(itemIndex: Int, position: Int, uti: String, inlineData: Data?, blobHash: String?, byteSize: Int64) {
        self.itemIndex = itemIndex
        self.position = position
        self.uti = uti
        self.inlineData = inlineData
        self.blobHash = blobHash
        self.byteSize = byteSize
    }
}

public struct ClipFile: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var clipID: Int64
    public var position: Int
    public var originalPath: String
    public var bookmark: Data?
    public var snapshotPath: String?
    public var fileName: String
    public var uti: String?
    public var byteSize: Int64
    public var isDirectory: Bool
}

public struct ClipDetail: Sendable, Hashable {
    public var clip: Clip
    public var representations: [Representation]
    public var files: [ClipFile]
    public var pinboardIDs: [Int64]
    public var tags: [String]
}

public struct Pinboard: Identifiable, Sendable, Hashable {
    public var id: Int64
    public var name: String
    public var colorHex: String
    public var sortOrder: Int
    public var aiHidden: Bool
    public var createdAt: Date

    public static let palette = ["#FF8A1F", "#C026D3", "#22C55E", "#3B82F6", "#EF4444", "#EAB308", "#14B8A6", "#8B5CF6"]
}

public struct ClipQuery: Sendable, Hashable {
    public enum Collection: Sendable, Hashable {
        case history
        case pinboard(Int64)
        case trash
    }

    public var collection: Collection
    public var text: String
    public var kinds: Set<ClipKind>
    public var sourceBundleID: String?
    public var from: Date?
    public var to: Date?
    public var tag: String?
    public var limit: Int
    public var offset: Int

    public init(
        collection: Collection = .history,
        text: String = "",
        kinds: Set<ClipKind> = [],
        sourceBundleID: String? = nil,
        from: Date? = nil,
        to: Date? = nil,
        tag: String? = nil,
        limit: Int = 60,
        offset: Int = 0
    ) {
        self.collection = collection
        self.text = text
        self.kinds = kinds
        self.sourceBundleID = sourceBundleID
        self.from = from
        self.to = to
        self.tag = tag
        self.limit = limit
        self.offset = offset
    }
}

/// Which rows a read may see. `.agent` applies the AI visibility rules inside the SQL, so hidden content
/// never reaches agent code rather than being filtered afterwards.
public enum AccessScope: Sendable {
    case user
    case agent
}

public struct SourceApp: Sendable, Hashable, Identifiable {
    public var bundleID: String
    public var name: String
    public var count: Int
    public var id: String { bundleID }
}

public struct LibraryStats: Sendable, Hashable, Codable {
    public var total: Int
    public var byKind: [String: Int]
    public var bySource: [String: Int]
    public var last7Days: Int
    public var last30Days: Int
    public var totalBytes: Int64
}

public enum ClipChange: Sendable {
    case inserted(Int64)
    case updated(Int64)
    case removed
    case pinboardsChanged
}
