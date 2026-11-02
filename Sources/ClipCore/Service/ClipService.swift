import Foundation
import os

/// The one entry point to the library. The panel, the main window and the agent all call this.
public final class ClipService: Sendable {
    public let paths: AppPaths
    public let blobs: BlobStore
    let database: ClipDatabase

    /// Payloads at or below this size stay in SQLite; reads are faster than a file per small clip.
    static let inlineLimit = 32 * 1024
    static let previewCharacters = 2_000
    static let indexedCharacters = 100_000

    private let subscribers = OSAllocatedUnfairLock(initialState: [UUID: AsyncStream<ClipChange>.Continuation]())

    public init(paths: AppPaths) throws {
        self.paths = paths
        blobs = BlobStore(directory: paths.blobs)
        database = try ClipDatabase(path: paths.database.path)
    }

    public func changes() -> AsyncStream<ClipChange> {
        AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let id = UUID()
            subscribers.withLock { $0[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.subscribers.withLock { _ = $0.removeValue(forKey: id) }
            }
        }
    }

    func notify(_ change: ClipChange) {
        subscribers.withLock { current in
            current.values.forEach { $0.yield(change) }
        }
    }

    // MARK: Ingest

    public struct IngestResult: Sendable {
        public var clipID: Int64
        public var isNew: Bool
    }

    public func ingest(_ draft: CaptureDraft, now: Date = Date()) async throws -> IngestResult {
        // Blob writes sit outside the transaction: they are content-addressed, so a rollback only leaves
        // an orphan for the sweep, and a slow disk must not hold the write lock.
        var representations: [Representation] = []
        for stored in draft.entries {
            let size = Int64(stored.entry.data.count)
            if stored.entry.data.count <= Self.inlineLimit {
                representations.append(Representation(
                    itemIndex: stored.itemIndex, position: stored.position, uti: stored.entry.uti,
                    inlineData: stored.entry.data, blobHash: nil, byteSize: size
                ))
            } else {
                let hash = try blobs.put(stored.entry.data)
                representations.append(Representation(
                    itemIndex: stored.itemIndex, position: stored.position, uti: stored.entry.uti,
                    inlineData: nil, blobHash: hash, byteSize: size
                ))
            }
        }
        let frozen = representations
        let result = try await database.write { db -> IngestResult in
            if let existing = try db.first("SELECT id FROM clip WHERE contentHash = ?", [draft.contentHash], { $0.int64(0) }) {
                try db.execute(
                    """
                    UPDATE clip SET lastCopiedAt = ?, copyCount = copyCount + 1, deletedAt = NULL,
                        sourceBundleID = coalesce(?, sourceBundleID), sourceAppName = coalesce(?, sourceAppName)
                    WHERE id = ?
                    """,
                    [now, draft.source.bundleID, draft.source.name, existing]
                )
                return IngestResult(clipID: existing, isNew: false)
            }
            let metadata = Self.encodeMetadata(draft.metadata)
            try db.execute(
                """
                INSERT INTO clip(kind, plainText, textLength, sourceBundleID, sourceAppName, contentHash, byteSize,
                    createdAt, lastCopiedAt, isSensitive, metadataJSON)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    draft.kind.rawValue, draft.plainText, draft.plainText?.count ?? 0, draft.source.bundleID, draft.source.name,
                    draft.contentHash, draft.byteSize, now, now, draft.isSensitive, metadata,
                ]
            )
            let id = db.lastInsertRowID
            try Self.insertRepresentations(frozen, clipID: id, db: db)
            for (position, file) in draft.files.enumerated() {
                try db.execute(
                    """
                    INSERT INTO clipFile(clipID, position, originalPath, bookmark, fileName, uti, byteSize, isDirectory)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [id, position, file.path, file.bookmark, file.fileName, file.uti, file.byteSize, file.isDirectory]
                )
            }
            try Self.refreshIndex(id, db: db)
            return IngestResult(clipID: id, isNew: true)
        }
        notify(result.isNew ? .inserted(result.clipID) : .updated(result.clipID))
        return result
    }

    static func insertRepresentations(_ representations: [Representation], clipID: Int64, db: SQLiteConnection) throws {
        for representation in representations {
            try db.execute(
                """
                INSERT INTO representation(clipID, itemIndex, position, uti, inlineData, blobHash, byteSize)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    clipID, representation.itemIndex, representation.position, representation.uti,
                    representation.inlineData, representation.blobHash, representation.byteSize,
                ]
            )
        }
    }

    // MARK: Reads

    public func list(_ query: ClipQuery, scope: AccessScope = .user) async throws -> [Clip] {
        try await database.read { db in
            let columns = Self.clipColumns(fullText: false)
            if let match = SearchText.matchExpression(for: query.text) {
                let matched = try Self.search(db, query, scope: scope, match: match, columns: columns)
                if !matched.isEmpty || query.offset > 0 { return matched }
            }
            return try Self.fetch(db, query, scope: scope, columns: columns)
        }
    }

    public func count(_ query: ClipQuery, scope: AccessScope = .user) async throws -> Int {
        try await database.read { db in
            var unlimited = query
            unlimited.limit = -1
            unlimited.offset = 0
            var plan = Self.plan(unlimited, scope: scope)
            if let match = SearchText.matchExpression(for: query.text) {
                let arguments = plan.arguments + [match]
                let sql = "SELECT count(*) FROM clipFTS JOIN clip ON clip.id = clipFTS.rowid \(plan.joins) \(plan.whereClause) AND clipFTS MATCH ?"
                let matched = Int(try db.scalarInt(sql, arguments))
                if matched > 0 { return matched }
            }
            Self.addSubstringFilter(query.text, to: &plan)
            return Int(try db.scalarInt("SELECT count(*) FROM clip \(plan.joins) \(plan.whereClause)", plan.arguments))
        }
    }

    public func detail(id: Int64, scope: AccessScope = .user) async throws -> ClipDetail? {
        try await database.read { db in try Self.detail(db, id: id, scope: scope) }
    }

    public func pinboards(scope: AccessScope = .user) async throws -> [Pinboard] {
        try await database.read { db in
            let filter = scope == .agent ? "WHERE aiHidden = 0" : ""
            return try db.query(
                "SELECT id, name, colorHex, sortOrder, aiHidden, createdAt FROM pinboard \(filter) ORDER BY sortOrder, id"
            ) { row in
                Pinboard(
                    id: row.int64(0), name: row.string(1), colorHex: row.string(2),
                    sortOrder: row.int(3), aiHidden: row.bool(4), createdAt: row.date(5)
                )
            }
        }
    }

    public func pinboardCounts() async throws -> [Int64: Int] {
        try await database.read { db in
            let rows = try db.query(
                """
                SELECT pc.pinboardID, count(*) FROM pinboardClip pc JOIN clip ON clip.id = pc.clipID
                WHERE clip.deletedAt IS NULL GROUP BY pc.pinboardID
                """
            ) { ($0.int64(0), $0.int(1)) }
            return Dictionary(uniqueKeysWithValues: rows)
        }
    }

    public func tags(scope: AccessScope = .user) async throws -> [(name: String, count: Int)] {
        let rows = try await database.read { db -> [TagCount] in
            let visibility = scope == .agent ? "AND \(Self.agentVisibilitySQL)" : ""
            return try db.query(
                """
                SELECT tag.name, count(*) FROM tag
                JOIN clipTag ON clipTag.tagID = tag.id
                JOIN clip ON clip.id = clipTag.clipID
                WHERE clip.deletedAt IS NULL \(visibility)
                GROUP BY tag.id ORDER BY count(*) DESC, tag.name
                """
            ) { TagCount(name: $0.string(0), count: $0.int(1)) }
        }
        return rows.map { ($0.name, $0.count) }
    }

    public func sourceApps(scope: AccessScope = .user) async throws -> [SourceApp] {
        try await database.read { db in
            let visibility = scope == .agent ? "AND \(Self.agentVisibilitySQL)" : ""
            return try db.query(
                """
                SELECT sourceBundleID, max(sourceAppName), count(*) FROM clip
                WHERE deletedAt IS NULL AND sourceBundleID IS NOT NULL \(visibility)
                GROUP BY sourceBundleID ORDER BY count(*) DESC
                """
            ) { SourceApp(bundleID: $0.string(0), name: $0.string(1), count: $0.int(2)) }
        }
    }

    public func stats(scope: AccessScope = .user, now: Date = Date()) async throws -> LibraryStats {
        try await database.read { db in
            let visibility = scope == .agent ? "AND \(Self.agentVisibilitySQL)" : ""
            let base = "FROM clip WHERE deletedAt IS NULL \(visibility)"
            let byKind = try db.query("SELECT kind, count(*) \(base) GROUP BY kind") { ($0.string(0), $0.int(1)) }
            let bySource = try db.query(
                "SELECT coalesce(sourceAppName, '未知'), count(*) \(base) GROUP BY 1 ORDER BY 2 DESC LIMIT 20"
            ) { ($0.string(0), $0.int(1)) }
            return LibraryStats(
                total: Int(try db.scalarInt("SELECT count(*) \(base)")),
                byKind: Dictionary(uniqueKeysWithValues: byKind),
                bySource: Dictionary(bySource, uniquingKeysWith: +),
                last7Days: Int(try db.scalarInt("SELECT count(*) \(base) AND lastCopiedAt >= ?", [now.addingTimeInterval(-7 * 86_400)])),
                last30Days: Int(try db.scalarInt("SELECT count(*) \(base) AND lastCopiedAt >= ?", [now.addingTimeInterval(-30 * 86_400)])),
                totalBytes: try db.scalarInt("SELECT coalesce(sum(byteSize), 0) \(base)")
            )
        }
    }

    /// Groups of visible clips that share normalised text. Exact binary duplicates are already merged on capture.
    public func duplicateGroups(scope: AccessScope = .user, limit: Int = 50) async throws -> [[Int64]] {
        try await database.read { db in
            let visibility = scope == .agent ? "AND \(Self.agentVisibilitySQL)" : ""
            let rows = try db.query(
                """
                SELECT id, plainText FROM clip
                WHERE deletedAt IS NULL AND plainText IS NOT NULL AND textLength BETWEEN 1 AND 20000 \(visibility)
                ORDER BY lastCopiedAt DESC LIMIT 20000
                """
            ) { ($0.int64(0), $0.string(1)) }
            var groups: [String: [Int64]] = [:]
            var order: [String] = []
            for (id, text) in rows {
                let key = text.lowercased().filter { !$0.isWhitespace }
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(id)
            }
            return order.compactMap { groups[$0] }.filter { $0.count > 1 }.prefix(limit).map(\.self)
        }
    }

    // MARK: Pasteboard bookkeeping

    public func recordUse(clipID: Int64, now: Date = Date()) async throws {
        try await database.write { db in
            try db.execute("UPDATE clip SET useCount = useCount + 1, lastUsedAt = ? WHERE id = ?", [now, clipID])
        }
    }

    /// Reads a representation regardless of whether it lives inline or in the blob store.
    public func data(for representation: Representation) throws -> Data? {
        if let inline = representation.inlineData { return inline }
        return try representation.blobHash.map { try blobs.read($0) }
    }

    /// Prefers the live file so pastes pick up the current version, then the snapshot.
    public func resolveURL(for file: ClipFile) -> URL? {
        let manager = FileManager.default
        if manager.fileExists(atPath: file.originalPath) { return URL(fileURLWithPath: file.originalPath) }
        if let bookmark = file.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale), manager.fileExists(atPath: url.path) {
                return url
            }
        }
        if let snapshot = file.snapshotPath {
            let url = paths.files.appending(path: snapshot)
            if manager.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    public func setSnapshot(fileID: Int64, relativePath: String) async throws {
        try await database.write { db in
            try db.execute("UPDATE clipFile SET snapshotPath = ? WHERE id = ?", [relativePath, fileID])
        }
    }

    // MARK: Enrichment

    public func pendingEnrichment(limit: Int) async throws -> [Int64] {
        try await database.read { db in
            try db.query("SELECT id FROM clip WHERE enrichedAt IS NULL AND deletedAt IS NULL ORDER BY id DESC LIMIT ?", [limit]) { $0.int64(0) }
        }
    }

    public func saveEnrichment(
        clipID: Int64,
        thumbnailPath: String?,
        ocrText: String?,
        metadata: ClipMetadata?,
        now: Date = Date()
    ) async throws {
        try await database.write { db in
            let current = try db.first("SELECT metadataJSON FROM clip WHERE id = ?", [clipID]) { Self.decodeMetadata($0.optionalString(0)) }
            guard var merged = current else { return }
            if let metadata {
                merged.pixelWidth = metadata.pixelWidth ?? merged.pixelWidth
                merged.pixelHeight = metadata.pixelHeight ?? merged.pixelHeight
                merged.durationSeconds = metadata.durationSeconds ?? merged.durationSeconds
                merged.mediaTitle = metadata.mediaTitle ?? merged.mediaTitle
                merged.artist = metadata.artist ?? merged.artist
            }
            try db.execute(
                "UPDATE clip SET thumbnailPath = coalesce(?, thumbnailPath), ocrText = coalesce(?, ocrText), metadataJSON = ?, enrichedAt = ? WHERE id = ?",
                [thumbnailPath, ocrText, Self.encodeMetadata(merged), now, clipID]
            )
            if ocrText != nil { try Self.refreshIndex(clipID, db: db) }
        }
        notify(.updated(clipID))
    }

    // MARK: Row mapping

    private struct TagCount: Sendable {
        var name: String
        var count: Int
    }

    static let agentVisibilitySQL = """
        clip.isSensitive = 0 AND clip.aiHidden = 0 AND NOT EXISTS (
            SELECT 1 FROM pinboardClip hiddenLink JOIN pinboard hiddenBoard ON hiddenBoard.id = hiddenLink.pinboardID
            WHERE hiddenLink.clipID = clip.id AND hiddenBoard.aiHidden = 1
        )
        """

    static func clipColumns(fullText: Bool) -> String {
        let text = fullText ? "clip.plainText" : "substr(clip.plainText, 1, \(previewCharacters))"
        return """
            clip.id, clip.kind, clip.title, \(text), clip.textLength, clip.sourceBundleID, clip.sourceAppName,
            clip.contentHash, clip.byteSize, clip.createdAt, clip.lastCopiedAt, clip.lastUsedAt, clip.copyCount,
            clip.useCount, clip.isSensitive, clip.aiHidden, clip.ocrText, clip.metadataJSON, clip.thumbnailPath,
            clip.enrichedAt, clip.deletedAt
            """
    }

    static func decodeClip(_ row: Row) -> Clip {
        Clip(
            id: row.int64(0),
            kind: ClipKind(rawValue: row.string(1)) ?? .other,
            title: row.optionalString(2),
            plainText: row.optionalString(3),
            textLength: row.int(4),
            sourceBundleID: row.optionalString(5),
            sourceAppName: row.optionalString(6),
            contentHash: row.string(7),
            byteSize: row.int64(8),
            createdAt: row.date(9),
            lastCopiedAt: row.date(10),
            lastUsedAt: row.optionalDate(11),
            copyCount: row.int(12),
            useCount: row.int(13),
            isSensitive: row.bool(14),
            aiHidden: row.bool(15),
            ocrText: row.optionalString(16),
            metadata: decodeMetadata(row.optionalString(17)),
            thumbnailPath: row.optionalString(18),
            enrichedAt: row.optionalDate(19),
            deletedAt: row.optionalDate(20)
        )
    }

    static func encodeMetadata(_ metadata: ClipMetadata) -> String? {
        (try? JSONEncoder().encode(metadata)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decodeMetadata(_ json: String?) -> ClipMetadata {
        json.flatMap { try? JSONDecoder().decode(ClipMetadata.self, from: Data($0.utf8)) } ?? ClipMetadata()
    }

    // MARK: Query planning

    struct QueryPlan {
        var joins = ""
        var whereClause = ""
        var arguments: [any SQLBindable] = []
        var order = "clip.lastCopiedAt DESC, clip.id DESC"
    }

    static func plan(_ query: ClipQuery, scope: AccessScope) -> QueryPlan {
        var plan = QueryPlan()
        var conditions: [String] = []
        switch query.collection {
        case .history:
            conditions.append("clip.deletedAt IS NULL")
        case .pinboard(let id):
            plan.joins = "JOIN pinboardClip pc ON pc.clipID = clip.id"
            conditions.append("pc.pinboardID = ?")
            plan.arguments.append(id)
            conditions.append("clip.deletedAt IS NULL")
            plan.order = "pc.addedAt DESC, clip.id DESC"
        case .trash:
            conditions.append("clip.deletedAt IS NOT NULL")
            plan.order = "clip.deletedAt DESC"
        }
        if !query.kinds.isEmpty {
            conditions.append("clip.kind IN (\(query.kinds.map { _ in "?" }.joined(separator: ",")))")
            let names: [String] = query.kinds.map(\.rawValue).sorted()
            plan.arguments.append(contentsOf: names as [any SQLBindable])
        }
        if let source = query.sourceBundleID {
            conditions.append("clip.sourceBundleID = ?")
            plan.arguments.append(source)
        }
        if let from = query.from {
            conditions.append("clip.lastCopiedAt >= ?")
            plan.arguments.append(from)
        }
        if let to = query.to {
            conditions.append("clip.lastCopiedAt <= ?")
            plan.arguments.append(to)
        }
        if let tag = query.tag {
            conditions.append(
                "EXISTS (SELECT 1 FROM clipTag ct JOIN tag t ON t.id = ct.tagID WHERE ct.clipID = clip.id AND t.name = ? COLLATE NOCASE)"
            )
            plan.arguments.append(tag)
        }
        if scope == .agent {
            conditions.append(agentVisibilitySQL)
        }
        plan.whereClause = "WHERE " + conditions.joined(separator: " AND ")
        return plan
    }

    /// Scoring every hit is what makes a common word slow, so only the newest hits are ranked. Filters sit
    /// inside the window, so a filtered search still reaches older clips, and counts stay exact.
    static let rankingWindow = 1_500

    private static func search(_ db: SQLiteConnection, _ query: ClipQuery, scope: AccessScope, match: String, columns: String) throws -> [Clip] {
        var plan = plan(query, scope: scope)
        plan.whereClause += " AND clipFTS MATCH ?"
        plan.arguments.append(match)
        plan.arguments.append(max(rankingWindow, query.offset + query.limit))
        plan.arguments.append(Date())
        plan.arguments.append(query.limit)
        plan.arguments.append(query.offset)
        // bm25 is negative and smaller is better, so subtracting a recency bonus favours recent clips.
        let sql = """
            WITH matched AS (
                SELECT clipFTS.rowid AS clipID, bm25(clipFTS, 10.0, 1.0, 1.0, 5.0) AS score
                FROM clipFTS JOIN clip ON clip.id = clipFTS.rowid \(plan.joins) \(plan.whereClause)
                ORDER BY clipFTS.rowid DESC LIMIT ?
            )
            SELECT \(columns) FROM matched JOIN clip ON clip.id = matched.clipID
            ORDER BY matched.score - 3.0 / (1.0 + (? - clip.lastCopiedAt) / 86400.0)
            LIMIT ? OFFSET ?
            """
        return try db.query(sql, plan.arguments, decodeClip)
    }

    private static func fetch(_ db: SQLiteConnection, _ query: ClipQuery, scope: AccessScope, columns: String) throws -> [Clip] {
        var plan = plan(query, scope: scope)
        addSubstringFilter(query.text, to: &plan)
        plan.arguments.append(query.limit)
        plan.arguments.append(query.offset)
        let sql = "SELECT \(columns) FROM clip \(plan.joins) \(plan.whereClause) ORDER BY \(plan.order) LIMIT ? OFFSET ?"
        return try db.query(sql, plan.arguments, decodeClip)
    }

    private static func addSubstringFilter(_ text: String, to plan: inout QueryPlan) {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        let pattern = SearchText.likePattern(for: needle)
        plan.whereClause += " AND (clip.plainText LIKE ? ESCAPE '\\' OR clip.title LIKE ? ESCAPE '\\' OR clip.ocrText LIKE ? ESCAPE '\\')"
        plan.arguments.append(contentsOf: [pattern, pattern, pattern])
    }

    static func detail(_ db: SQLiteConnection, id: Int64, scope: AccessScope) throws -> ClipDetail? {
        let visibility = scope == .agent ? "AND clip.deletedAt IS NULL AND \(agentVisibilitySQL)" : ""
        let sql = "SELECT \(clipColumns(fullText: true)) FROM clip WHERE clip.id = ? \(visibility)"
        guard let clip = try db.first(sql, [id], decodeClip) else { return nil }
        let representations = try db.query(
            "SELECT itemIndex, position, uti, inlineData, blobHash, byteSize FROM representation WHERE clipID = ? ORDER BY itemIndex, position",
            [id]
        ) { row in
            Representation(
                itemIndex: row.int(0), position: row.int(1), uti: row.string(2),
                inlineData: row.optionalData(3), blobHash: row.optionalString(4), byteSize: row.int64(5)
            )
        }
        let files = try db.query(
            """
            SELECT id, clipID, position, originalPath, bookmark, snapshotPath, fileName, uti, byteSize, isDirectory
            FROM clipFile WHERE clipID = ? ORDER BY position
            """,
            [id]
        ) { row in
            ClipFile(
                id: row.int64(0), clipID: row.int64(1), position: row.int(2), originalPath: row.string(3),
                bookmark: row.optionalData(4), snapshotPath: row.optionalString(5), fileName: row.string(6),
                uti: row.optionalString(7), byteSize: row.int64(8), isDirectory: row.bool(9)
            )
        }
        let boards = try db.query("SELECT pinboardID FROM pinboardClip WHERE clipID = ?", [id]) { $0.int64(0) }
        return ClipDetail(clip: clip, representations: representations, files: files, pinboardIDs: boards, tags: try tags(db, clipID: id))
    }

    static func tags(_ db: SQLiteConnection, clipID: Int64) throws -> [String] {
        try db.query(
            "SELECT tag.name FROM tag JOIN clipTag ON clipTag.tagID = tag.id WHERE clipTag.clipID = ? ORDER BY tag.name",
            [clipID]
        ) { $0.string(0) }
    }

    /// Keeps the FTS row in step with the clip. CJK text is split here, at the only place that writes the index.
    static func refreshIndex(_ id: Int64, db: SQLiteConnection) throws {
        try db.execute("DELETE FROM clipFTS WHERE rowid = ?", [id])
        struct Indexable { var title: String?; var text: String?; var ocr: String? }
        guard let row = try db.first(
            "SELECT title, substr(plainText, 1, \(indexedCharacters)), ocrText FROM clip WHERE id = ?",
            [id],
            { Indexable(title: $0.optionalString(0), text: $0.optionalString(1), ocr: $0.optionalString(2)) }
        ) else { return }
        let tagText = try tags(db, clipID: id).joined(separator: " ")
        try db.execute(
            "INSERT INTO clipFTS(rowid, title, body, ocr, tags) VALUES (?, ?, ?, ?, ?)",
            [
                id, SearchText.segment(row.title ?? ""), SearchText.segment(row.text ?? ""),
                SearchText.segment(row.ocr ?? ""), SearchText.segment(tagText),
            ]
        )
    }
}
