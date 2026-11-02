import ClipCore
import Foundation

/// What an import did. Holds only counts and format names, never anything taken from a clip,
/// so it is safe to show, log or hand to anyone.
public struct PasteImportReport: Codable, Sendable, Equatable {
    public var total = 0
    public var imported = 0
    public var alreadyPresent = 0
    public var skippedSecret = 0
    public var skippedIgnoredApp = 0
    public var unreadable = 0
    public var unreadableReasons: [String: Int] = [:]
    public var kinds: [String: Int] = [:]
    public var pinboardsCreated = 0
    public var pinboardsHiddenFromAI = 0
    public var pinned = 0
    public var titled = 0
    public var bytes: Int64 = 0
    /// Records whose file is no longer on this Mac. They keep what is left, a path or just the file name.
    public var missingFiles = 0
    /// Records whose file is gone but which still held the picture, so the picture was kept instead.
    public var recoveredImages = 0

    public init() {}
}

public enum PasteImportError: Error, LocalizedError, Equatable {
    case libraryNotFound

    public var errorDescription: String? {
        switch self {
        case .libraryNotFound: L("没有找到 Paste 的数据")
        }
    }
}

/// Reads Paste's Core Data store directly. Opened read-only, so Paste can stay open and is never modified.
public struct PasteImporter: Sendable {
    let library: URL
    let service: ClipService
    let ignoredApps: Set<String>

    public init(library: URL, service: ClipService, ignoredApps: Set<String> = []) {
        self.library = library
        self.service = service
        self.ignoredApps = ignoredApps
    }

    /// The folder holding `db.sqlite`, for the Setapp and direct builds of Paste.
    public static func locateLibrary(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let candidates = [
            "Library/Application Support/com.wiheads.paste-setapp",
            "Library/Containers/com.wiheads.paste/Data/Library/Application Support/com.wiheads.paste",
            "Library/Application Support/com.wiheads.paste",
        ]
        return candidates
            .map { home.appending(path: $0, directoryHint: .isDirectory) }
            .first { FileManager.default.fileExists(atPath: $0.appending(path: "db.sqlite").path) }
    }

    private struct Item: Sendable {
        var dataKey: Int64
        var list: Int64?
        var timestamp: Date
        var title: String?
        var bundleID: String?
        var appName: String?
    }

    private struct Board: Sendable {
        var key: Int64
        var name: String
    }

    /// With `dryRun` everything is decoded and counted but nothing is written.
    public func run(dryRun: Bool, now: Date = Date(), progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> PasteImportReport {
        let store = library.appending(path: "db.sqlite")
        guard FileManager.default.fileExists(atPath: store.path) else { throw PasteImportError.libraryNotFound }
        let connection = try SQLiteConnection(path: store.path, readOnly: true)

        // Oldest first, so ids follow the original timeline.
        let items = try connection.query(
            """
            SELECT i.ZDATA, i.ZLIST, i.ZTIMESTAMP, i.ZTITLE, a.ZBUNDLEIDENTIFIER, a.ZNAME
            FROM ZITEMENTITY i LEFT JOIN ZAPPLICATIONENTITY a ON a.Z_PK = i.ZSOURCEAPPLICATION
            WHERE i.ZDATA IS NOT NULL ORDER BY i.ZTIMESTAMP ASC
            """
        ) { row in
            Item(
                dataKey: row.int64(0), list: row.optionalInt64(1),
                timestamp: Date(timeIntervalSinceReferenceDate: row.double(2)),
                title: row.optionalString(3), bundleID: row.optionalString(4), appName: row.optionalString(5)
            )
        }
        // Type 2 is a pinboard. The other list is Paste's own clipboard history.
        let boards = try connection.query("SELECT Z_PK, ZNAME FROM ZLISTENTITY WHERE ZRAWTYPE = 2 AND ZNAME IS NOT NULL") { Board(key: $0.int64(0), name: $0.string(1)) }

        var report = PasteImportReport()
        report.total = items.count
        let boardIDs = dryRun ? [:] : try await mapBoards(boards, report: &report, now: now)

        var followUps: [ClipMutation] = []
        let external = library.appending(path: ".db_SUPPORT/_EXTERNAL_DATA", directoryHint: .isDirectory)
        for (index, item) in items.enumerated() {
            progress(index, items.count)
            if let bundleID = item.bundleID, ignoredApps.contains(bundleID) {
                report.skippedIgnoredApp += 1
                continue
            }
            do {
                let blob = try connection.first("SELECT ZRAWPASTEBOARDITEMS FROM ZITEMDATAENTITY WHERE Z_PK = ?", [item.dataKey]) { $0.optionalData(0) } ?? nil
                guard let blob else { throw PasteRecordError.missingData }
                let decoded = try PasteRecordDecoder.pasteboardItems(blob: blob, externalRoot: external)
                let entries = PasteRecordDecoder.withoutDeadFileReferences(decoded)
                let types = Set(decoded.flatMap { $0.map(\.uti) })
                if !types.isDisjoint(with: PasteboardTypes.concealed) || !types.isDisjoint(with: PasteboardTypes.transient) {
                    report.skippedSecret += 1
                    continue
                }
                let snapshot = PasteboardSnapshot(items: entries)
                guard let draft = ClipBuilder.build(snapshot, source: SourceInfo(bundleID: item.bundleID, name: item.appName)) else {
                    throw PasteRecordError.empty
                }
                report.kinds[draft.kind.rawValue, default: 0] += 1
                report.bytes += draft.entries.reduce(Int64(0)) { $0 + Int64($1.entry.data.count) }
                let recovered = entries != decoded
                let namedOnly = draft.files.isEmpty && !recovered && types.contains(PasteboardTypes.fileURL)
                if namedOnly || draft.files.contains(where: { !FileManager.default.fileExists(atPath: $0.path) }) { report.missingFiles += 1 }
                if recovered { report.recoveredImages += 1 }
                if dryRun {
                    report.imported += 1
                    continue
                }
                let result = try await service.ingest(draft, now: item.timestamp, importedAt: now)
                if result.isNew {
                    report.imported += 1
                    await FileSnapshotter(service: service).snapshotFiles(of: result.clipID)
                } else {
                    report.alreadyPresent += 1
                }
                if result.isNew, let title = item.title, !title.isEmpty {
                    followUps.append(.setTitle(clipID: result.clipID, title: title))
                    report.titled += 1
                }
                if let list = item.list, let board = boardIDs[list] {
                    followUps.append(.addToPinboard(clipID: result.clipID, pinboardID: board))
                    report.pinned += 1
                }
            } catch {
                report.unreadable += 1
                report.unreadableReasons[Self.reason(for: error), default: 0] += 1
            }
        }
        if !followUps.isEmpty {
            try await service.apply(followUps, source: .user, summary: L("从 Paste 导入"))
        }
        progress(items.count, items.count)
        return report
    }

    /// Never includes error text, which could quote the data that failed to parse.
    private static func reason(for error: any Error) -> String {
        (error as? PasteRecordError)?.rawValue ?? String(describing: type(of: error))
    }

    private func mapBoards(_ boards: [Board], report: inout PasteImportReport, now: Date) async throws -> [Int64: Int64] {
        var existing = Dictionary(try await service.pinboards().map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var mapped: [Int64: Int64] = [:]
        for board in boards {
            if let found = existing[board.name] {
                mapped[board.key] = found.id
                continue
            }
            let id = try await service.createPinboard(name: board.name)
            mapped[board.key] = id
            report.pinboardsCreated += 1
            guard var created = try await service.pinboards().first(where: { $0.id == id }) else { continue }
            // A board named for credentials must not become visible to AI just by moving here.
            if Self.looksPrivate(board.name) {
                created.aiHidden = true
                try await service.updatePinboard(created)
                report.pinboardsHiddenFromAI += 1
            }
            existing[board.name] = created
        }
        return mapped
    }

    static func looksPrivate(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["密码", "口令", "密钥", "私钥", "账号", "password", "passcode", "credential", "secret", "token", "private"].contains(where: lowered.contains)
    }
}

enum PasteRecordError: String, Error {
    case missingData
    case empty
    case badMarker
    case missingExternalFile
    case undecodableCompression
    case unexpectedStructure
}

/// Undoes the layers Paste and Core Data wrap around a clip's pasteboard data.
enum PasteRecordDecoder {
    static func pasteboardItems(blob: Data, externalRoot: URL) throws -> [[PasteboardEntry]] {
        let stored = try unwrapExternalStorage(blob, externalRoot: externalRoot)
        let plist = try decompress(stored)
        return try parse(plist).map { order($0) }
    }

    /// Screenshot tools put a temporary file on the pasteboard along with the picture. Once that file is
    /// gone the path is worthless and the picture is the only copy left. Finder's icon is not such a picture.
    static func withoutDeadFileReferences(_ items: [[PasteboardEntry]]) -> [[PasteboardEntry]] {
        items.map { item in
            guard let reference = item.first(where: { $0.uti == PasteboardTypes.fileURL }),
                  let url = ClipBuilder.fileURL(from: reference.data),
                  !FileManager.default.fileExists(atPath: url.path),
                  !item.contains(where: { $0.uti == "com.apple.icns" }) else { return item }
            let images = item.filter { PasteboardTypes.images.contains($0.uti) }
            return images.isEmpty ? item : images
        }
    }

    /// Core Data prefixes external-storage attributes: 1 means inline, 2 means a file named by a UUID.
    static func unwrapExternalStorage(_ blob: Data, externalRoot: URL) throws -> Data {
        guard let marker = blob.first else { throw PasteRecordError.missingData }
        let body = blob.dropFirst()
        switch marker {
        case 1:
            return Data(body)
        case 2:
            guard let name = String(data: Data(body.prefix { $0 != 0 }), encoding: .ascii), !name.isEmpty, !name.contains("/") else {
                throw PasteRecordError.badMarker
            }
            let file = externalRoot.appending(path: name)
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { throw PasteRecordError.missingExternalFile }
            return data
        default:
            throw PasteRecordError.badMarker
        }
    }

    static func decompress(_ data: Data) throws -> Data {
        func isRecord(_ candidate: Data) -> Bool {
            candidate.starts(with: Data("bplist".utf8)) || candidate.first == UInt8(ascii: "[")
        }
        if isRecord(data) { return data }
        let algorithms: [NSData.CompressionAlgorithm]
        if data.starts(with: Data("bv41".utf8)) {
            algorithms = [.lz4, .lzfse]
        } else if data.starts(with: Data("bv".utf8)) {
            algorithms = [.lzfse, .lz4]
        } else {
            // A headerless stream is raw deflate, which is what Foundation's zlib algorithm produces.
            algorithms = [.zlib, .lzma]
        }
        for algorithm in algorithms {
            if let output = try? (data as NSData).decompressed(using: algorithm) as Data, isRecord(output) {
                return output
            }
        }
        throw PasteRecordError.undecodableCompression
    }

    /// An array of pasteboard items, each a dictionary holding `{ uti: data }`. Most records are property
    /// lists; a few are JSON, where the data is Base64.
    static func parse(_ record: Data) throws -> [[PasteboardEntry]] {
        let root = record.first == UInt8(ascii: "[")
            ? try? JSONSerialization.jsonObject(with: record)
            : try? PropertyListSerialization.propertyList(from: record, format: nil)
        guard let items = root as? [[String: Any]] else { throw PasteRecordError.unexpectedStructure }
        let parsed = items.map { item -> [PasteboardEntry] in
            item.values.flatMap { value -> [PasteboardEntry] in
                guard let representations = value as? [String: Any] else { return [] }
                return representations.compactMap { uti, payload in
                    let data = payload as? Data ?? (payload as? String).flatMap { Data(base64Encoded: $0) }
                    return data.map { PasteboardEntry(uti: uti, data: $0) }
                }
            }
        }.filter { !$0.isEmpty }
        guard !parsed.isEmpty else { throw PasteRecordError.unexpectedStructure }
        return parsed
    }

    /// Property lists lose the declared order of types, which `ClipBuilder` reads as fidelity.
    /// Text goes first so a table copied from a spreadsheet stays text rather than its rendered picture.
    static func order(_ entries: [PasteboardEntry]) -> [PasteboardEntry] {
        func rank(_ uti: String) -> Int {
            switch uti {
            case PasteboardTypes.fileURL: 0
            case PasteboardTypes.plainText: 1
            case PasteboardTypes.rtf: 2
            case PasteboardTypes.html: 3
            default: PasteboardTypes.images.contains(uti) ? 4 : 5
            }
        }
        return entries.sorted { (rank($0.uti), $0.uti) < (rank($1.uti), $1.uti) }
    }
}
