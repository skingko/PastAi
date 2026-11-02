import Foundation

extension ClipService {
    /// Applies a batch atomically and records what is needed to undo it.
    @discardableResult
    public func apply(
        _ mutations: [ClipMutation],
        source: ChangeSource,
        summary: String,
        batchID: String = UUID().uuidString,
        now: Date = Date()
    ) async throws -> AppliedMutations {
        let result = try await database.write { db -> AppliedMutations in
            var created = AppliedMutations(batchID: batchID, createdClipIDs: [], createdPinboardIDs: [])
            for mutation in mutations {
                let inverses = try Self.perform(mutation, db: db, now: now, created: &created)
                for inverse in inverses {
                    let json = String(data: try JSONEncoder().encode(inverse), encoding: .utf8) ?? "{}"
                    try db.execute(
                        "INSERT INTO changeLog(batchID, source, summary, inverseJSON, createdAt) VALUES (?, ?, ?, ?, ?)",
                        [batchID, source.rawValue, summary, json, now]
                    )
                }
            }
            return created
        }
        notify(.updated(0))
        notify(.pinboardsChanged)
        return result
    }

    /// Runs a batch's inverses newest first, so later steps unwind before the ones they depended on.
    public func undo(batchID: String, now: Date = Date()) async throws {
        try await database.write { db in
            let rows = try db.query(
                "SELECT id, inverseJSON FROM changeLog WHERE batchID = ? AND undoneAt IS NULL ORDER BY id DESC",
                [batchID]
            ) { ($0.int64(0), $0.string(1)) }
            var ignored = AppliedMutations(batchID: batchID, createdClipIDs: [], createdPinboardIDs: [])
            for (id, json) in rows {
                let inverse = try JSONDecoder().decode(ClipMutation.self, from: Data(json.utf8))
                _ = try Self.perform(inverse, db: db, now: now, created: &ignored)
                try db.execute("UPDATE changeLog SET undoneAt = ? WHERE id = ?", [now, id])
            }
        }
        notify(.updated(0))
        notify(.pinboardsChanged)
    }

    public func recentBatches(source: ChangeSource? = nil, limit: Int = 50) async throws -> [ChangeBatch] {
        try await database.read { db in
            let filter = source == nil ? "" : "WHERE source = ?"
            var arguments: [any SQLBindable] = source.map { [$0.rawValue] } ?? []
            arguments.append(limit)
            return try db.query(
                """
                SELECT batchID, source, summary, count(*), min(createdAt), max(undoneAt IS NOT NULL)
                FROM changeLog \(filter) GROUP BY batchID ORDER BY min(id) DESC LIMIT ?
                """,
                arguments
            ) { row in
                ChangeBatch(
                    id: row.string(0), source: ChangeSource(rawValue: row.string(1)) ?? .user, summary: row.string(2),
                    count: row.int(3), createdAt: row.date(4), isUndone: row.bool(5)
                )
            }
        }
    }

    public func createPinboard(name: String, colorHex: String? = nil) async throws -> Int64 {
        let result = try await apply([.createPinboard(name: name, colorHex: colorHex)], source: .user, summary: "新建 Pinboard \(name)")
        return result.createdPinboardIDs[0]
    }

    public func updatePinboard(_ board: Pinboard) async throws {
        try await database.write { db in
            try db.execute(
                "UPDATE pinboard SET name = ?, colorHex = ?, aiHidden = ? WHERE id = ?",
                [board.name, board.colorHex, board.aiHidden, board.id]
            )
        }
        notify(.pinboardsChanged)
    }

    public func reorderPinboards(_ orderedIDs: [Int64]) async throws {
        try await database.write { db in
            for (index, id) in orderedIDs.enumerated() {
                try db.execute("UPDATE pinboard SET sortOrder = ? WHERE id = ?", [index, id])
            }
        }
        notify(.pinboardsChanged)
    }

    public func deletePinboard(id: Int64) async throws {
        try await database.write { db in
            try db.execute("DELETE FROM pinboard WHERE id = ?", [id])
        }
        notify(.pinboardsChanged)
    }

    /// Returns the inverse mutations, in the order they should be logged.
    private static func perform(
        _ mutation: ClipMutation,
        db: SQLiteConnection,
        now: Date,
        created: inout AppliedMutations
    ) throws -> [ClipMutation] {
        switch mutation {
        case .setText(let id, let text):
            guard let detail = try ClipService.detail(db, id: id, scope: .user) else { throw ClipServiceError.clipNotFound(id) }
            guard detail.clip.kind.isTextual else { throw ClipServiceError.notEditable(id) }
            let inverse = ClipMutation.restoreContent(
                clipID: id, text: detail.clip.plainText, kind: detail.clip.kind,
                contentHash: detail.clip.contentHash, representations: detail.representations
            )
            let plain = Representation(
                itemIndex: 0, position: 0, uti: PasteboardTypes.plainText,
                inlineData: Data(text.utf8), blobHash: nil, byteSize: Int64(text.utf8.count)
            )
            try writeContent(
                id: id, text: text, kind: TextClassifier.classify(text), hash: uniqueHash(ClipBuilder.textHash(text), clipID: id, db: db),
                // Rich text and HTML would still show the old wording, so an edited clip keeps plain text only.
                representations: [plain], db: db
            )
            return [inverse]

        case .restoreContent(let id, let text, let kind, let hash, let representations):
            try requireClip(id, db: db)
            try writeContent(id: id, text: text, kind: kind, hash: uniqueHash(hash, clipID: id, db: db), representations: representations, db: db)
            return []

        case .setTitle(let id, let title):
            let previous = try db.first("SELECT title FROM clip WHERE id = ?", [id]) { $0.optionalString(0) }
            guard let previous else { throw ClipServiceError.clipNotFound(id) }
            try db.execute("UPDATE clip SET title = ? WHERE id = ?", [title, id])
            try ClipService.refreshIndex(id, db: db)
            return [.setTitle(clipID: id, title: previous)]

        case .setTags(let id, let tags):
            try requireClip(id, db: db)
            let previous = try ClipService.tags(db, clipID: id)
            try db.execute("DELETE FROM clipTag WHERE clipID = ?", [id])
            for tag in Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !tag.isEmpty {
                try db.execute("INSERT OR IGNORE INTO tag(name) VALUES (?)", [tag])
                try db.execute(
                    "INSERT OR IGNORE INTO clipTag(clipID, tagID) SELECT ?, id FROM tag WHERE name = ? COLLATE NOCASE",
                    [id, tag]
                )
            }
            try ClipService.refreshIndex(id, db: db)
            return [.setTags(clipID: id, tags: previous)]

        case .setAIHidden(let id, let hidden):
            let previous = try db.first("SELECT aiHidden FROM clip WHERE id = ?", [id]) { $0.bool(0) }
            guard let previous else { throw ClipServiceError.clipNotFound(id) }
            try db.execute("UPDATE clip SET aiHidden = ? WHERE id = ?", [hidden, id])
            return [.setAIHidden(clipID: id, hidden: previous)]

        case .addToPinboard(let id, let pinboardID):
            try requireClip(id, db: db)
            guard try db.scalarInt("SELECT count(*) FROM pinboard WHERE id = ?", [pinboardID]) > 0 else {
                throw ClipServiceError.pinboardNotFound(pinboardID)
            }
            try db.execute("INSERT OR IGNORE INTO pinboardClip(pinboardID, clipID, addedAt) VALUES (?, ?, ?)", [pinboardID, id, now])
            return db.changes > 0 ? [.removeFromPinboard(clipID: id, pinboardID: pinboardID)] : []

        case .removeFromPinboard(let id, let pinboardID):
            try db.execute("DELETE FROM pinboardClip WHERE pinboardID = ? AND clipID = ?", [pinboardID, id])
            return db.changes > 0 ? [.addToPinboard(clipID: id, pinboardID: pinboardID)] : []

        case .softDelete(let id):
            try requireClip(id, db: db)
            try db.execute("UPDATE clip SET deletedAt = ? WHERE id = ? AND deletedAt IS NULL", [now, id])
            return db.changes > 0 ? [.restore(clipID: id)] : []

        case .restore(let id):
            try requireClip(id, db: db)
            try db.execute("UPDATE clip SET deletedAt = NULL WHERE id = ?", [id])
            return db.changes > 0 ? [.softDelete(clipID: id)] : []

        case .createText(let text, let title, let pinboardID):
            let hash = try uniqueHash(ClipBuilder.textHash(text), clipID: nil, db: db)
            try db.execute(
                """
                INSERT INTO clip(kind, title, plainText, textLength, sourceAppName, contentHash, byteSize, createdAt, lastCopiedAt, isSensitive, enrichedAt)
                VALUES (?, ?, ?, ?, 'PastAi', ?, ?, ?, ?, ?, ?)
                """,
                [
                    TextClassifier.classify(text).rawValue, title, text, text.count, hash, text.utf8.count, now, now,
                    SensitiveDetector.isSensitive(text), now,
                ]
            )
            let id = db.lastInsertRowID
            try ClipService.insertRepresentations(
                [Representation(itemIndex: 0, position: 0, uti: PasteboardTypes.plainText, inlineData: Data(text.utf8), blobHash: nil, byteSize: Int64(text.utf8.count))],
                clipID: id, db: db
            )
            try ClipService.refreshIndex(id, db: db)
            created.createdClipIDs.append(id)
            var inverses: [ClipMutation] = [.softDelete(clipID: id)]
            if let pinboardID {
                try db.execute("INSERT OR IGNORE INTO pinboardClip(pinboardID, clipID, addedAt) VALUES (?, ?, ?)", [pinboardID, id, now])
                inverses.append(.removeFromPinboard(clipID: id, pinboardID: pinboardID))
            }
            return inverses

        case .createPinboard(let name, let colorHex):
            let order = Int(try db.scalarInt("SELECT coalesce(max(sortOrder), -1) + 1 FROM pinboard"))
            let color = colorHex ?? Pinboard.palette[order % Pinboard.palette.count]
            try db.execute(
                "INSERT INTO pinboard(name, colorHex, sortOrder, createdAt) VALUES (?, ?, ?, ?)",
                [name, color, order, now]
            )
            let id = db.lastInsertRowID
            created.createdPinboardIDs.append(id)
            return [.deletePinboard(id: id)]

        case .deletePinboard(let id):
            try db.execute("DELETE FROM pinboard WHERE id = ?", [id])
            return []
        }
    }

    private static func requireClip(_ id: Int64, db: SQLiteConnection) throws {
        guard try db.scalarInt("SELECT count(*) FROM clip WHERE id = ?", [id]) > 0 else {
            throw ClipServiceError.clipNotFound(id)
        }
    }

    private static func writeContent(
        id: Int64, text: String?, kind: ClipKind, hash: String, representations: [Representation], db: SQLiteConnection
    ) throws {
        try db.execute(
            "UPDATE clip SET plainText = ?, textLength = ?, kind = ?, contentHash = ?, byteSize = ?, isSensitive = ? WHERE id = ?",
            [
                text, text?.count ?? 0, kind.rawValue, hash,
                representations.reduce(Int64(0)) { $0 + $1.byteSize }, text.map(SensitiveDetector.isSensitive) ?? false, id,
            ]
        )
        try db.execute("DELETE FROM representation WHERE clipID = ?", [id])
        try ClipService.insertRepresentations(representations, clipID: id, db: db)
        try ClipService.refreshIndex(id, db: db)
    }

    /// Edits can make two clips identical; both must survive, so the later one gets a salted hash.
    private static func uniqueHash(_ hash: String, clipID: Int64?, db: SQLiteConnection) throws -> String {
        let existing = try db.first("SELECT id FROM clip WHERE contentHash = ?", [hash]) { $0.int64(0) }
        guard let existing, existing != clipID else { return hash }
        return Hashing.sha256("\(hash):\(UUID().uuidString)")
    }
}
