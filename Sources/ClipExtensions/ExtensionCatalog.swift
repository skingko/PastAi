import CryptoKit
import Foundation

public struct CatalogFile: Codable, Sendable, Hashable {
    public var path: String
    public var sha256: String
}

public struct CatalogEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var folder: String
    public var version: String
    public var name: LocalizedText
    public var description: LocalizedText
    public var category: String
    public var regions: [String]
    public var icon: String
    public var files: [CatalogFile]
}

public struct CatalogIndex: Codable, Sendable, Hashable {
    public var schema: Int
    public var extensions: [CatalogEntry]
}

/// The market is a folder in the GitHub repository, so publishing an extension is a pull request and
/// there is no server to run. Hashes in the index catch truncated or corrupted downloads.
public struct ExtensionCatalog: Sendable {
    public static let defaultBaseURL = URL(string: "https://raw.githubusercontent.com/skingko/PastAi/main/extensions/")!

    let baseURL: URL
    let session: URLSession

    public init(baseURL: URL = defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func fetchIndex() async throws -> CatalogIndex {
        try decode(try await download(baseURL.appending(path: "index.json")))
    }

    /// The copy of the catalog shipped in the app, used when GitHub cannot be reached.
    public static func bundledIndex(at root: URL) throws -> CatalogIndex {
        let data = try Data(contentsOf: root.appending(path: "index.json"))
        return try JSONDecoder().decode(CatalogIndex.self, from: data)
    }

    /// Downloads an entry into a temporary folder, verifying each file before anything can be installed.
    public func fetchExtension(_ entry: CatalogEntry) async throws -> URL {
        guard entry.files.contains(where: { $0.path == "extension.json" }) else {
            throw ExtensionError.invalidManifest("索引缺少 extension.json")
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "pastai-ext-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in entry.files {
            guard ExtensionValidator.isSafeRelativePath(file.path), ExtensionValidator.isSafeRelativePath(entry.folder) else {
                throw ExtensionError.invalidManifest("文件路径不安全：\(file.path)")
            }
            let data = try await download(baseURL.appending(path: entry.folder).appending(path: file.path))
            guard Self.sha256(data) == file.sha256 else { throw ExtensionError.integrityMismatch(file.path) }
            let destination = folder.appending(path: file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination)
        }
        return folder
    }

    /// True when the catalog has a newer version than what is installed.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func decode(_ data: Data) throws -> CatalogIndex {
        let index = try JSONDecoder().decode(CatalogIndex.self, from: data)
        guard index.schema <= ExtensionManifest.currentSchema else {
            throw ExtensionError.invalidManifest("市场需要更新版本的 PastAi")
        }
        return index
    }

    private func download(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ExtensionError.invalidManifest("下载失败：\(url.lastPathComponent)")
        }
        return data
    }
}
