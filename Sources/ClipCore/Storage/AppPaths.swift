import CryptoKit
import Foundation

public struct AppPaths: Sendable {
    public let root: URL

    public var database: URL { root.appending(path: "library.sqlite") }
    public var blobs: URL { root.appending(path: "blobs", directoryHint: .isDirectory) }
    public var files: URL { root.appending(path: "files", directoryHint: .isDirectory) }
    public var thumbnails: URL { root.appending(path: "thumbnails", directoryHint: .isDirectory) }
    public var previews: URL { root.appending(path: "previews", directoryHint: .isDirectory) }

    public init(root: URL) throws {
        self.root = root
        for directory in [root, blobs, files, thumbnails, previews] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public static func applicationSupport() throws -> AppPaths {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try AppPaths(root: base.appending(path: "PastAi", directoryHint: .isDirectory))
    }
}

/// Content-addressed storage for pasteboard payloads too large to keep inside SQLite.
public struct BlobStore: Sendable {
    let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func url(for hash: String) -> URL {
        directory.appending(path: String(hash.prefix(2)), directoryHint: .isDirectory).appending(path: hash)
    }

    @discardableResult
    public func put(_ data: Data) throws -> String {
        let hash = Hashing.sha256(data)
        let destination = url(for: hash)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        }
        return hash
    }

    public func read(_ hash: String) throws -> Data {
        try Data(contentsOf: url(for: hash), options: .mappedIfSafe)
    }

    /// Removes blobs nothing references. The age guard keeps blobs an undo may still need.
    public func sweep(keeping referenced: Set<String>, olderThan cutoff: Date) -> Int {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else {
            return 0
        }
        var removed = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, !referenced.contains(url.lastPathComponent) else { continue }
            guard let modified = values?.contentModificationDate, modified < cutoff else { continue }
            if (try? manager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}

public enum Hashing {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }
}
