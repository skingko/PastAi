import Foundation

extension ClipService {
    public struct RetentionReport: Sendable, Equatable {
        public var trashed = 0
        public var purged = 0
        public var evicted = 0
        public var blobsRemoved = 0
    }

    /// Pinned clips are never touched: history expiry and the media cap both skip them.
    @discardableResult
    public func runRetention(_ policy: RetentionPolicy, now: Date = Date()) async throws -> RetentionReport {
        let (report, removedIDs) = try await database.write { db -> (RetentionReport, [Int64]) in
            var report = RetentionReport()
            let unpinned = "NOT EXISTS (SELECT 1 FROM pinboardClip pc WHERE pc.clipID = clip.id)"

            if policy.historyDays > 0 {
                let cutoff = now.addingTimeInterval(-Double(policy.historyDays) * 86_400)
                try db.execute(
                    "UPDATE clip SET deletedAt = ? WHERE deletedAt IS NULL AND lastCopiedAt < ? AND \(unpinned)",
                    [now, cutoff]
                )
                report.trashed = db.changes
            }

            let trashCutoff = now.addingTimeInterval(-Double(RetentionPolicy.trashDays) * 86_400)
            var removed = try db.query("SELECT id FROM clip WHERE deletedAt IS NOT NULL AND deletedAt < ?", [trashCutoff]) { $0.int64(0) }
            report.purged = removed.count

            var mediaBytes = try db.scalarInt(
                "SELECT coalesce(sum(byteSize), 0) FROM clip WHERE kind IN ('image','video','audio','file') AND id NOT IN (SELECT value FROM json_each(?))",
                [Self.jsonArray(removed)]
            )
            if mediaBytes > policy.mediaCapBytes {
                let candidates = try db.query(
                    """
                    SELECT id, byteSize FROM clip
                    WHERE kind IN ('image','video','audio','file') AND \(unpinned) AND id NOT IN (SELECT value FROM json_each(?))
                    ORDER BY coalesce(lastUsedAt, lastCopiedAt) ASC
                    """,
                    [Self.jsonArray(removed)]
                ) { ($0.int64(0), $0.int64(1)) }
                for (id, size) in candidates where mediaBytes > policy.mediaCapBytes {
                    removed.append(id)
                    mediaBytes -= size
                    report.evicted += 1
                }
            }

            for id in removed {
                try db.execute("DELETE FROM clip WHERE id = ?", [id])
                try db.execute("DELETE FROM clipFTS WHERE rowid = ?", [id])
            }
            try db.execute(
                "DELETE FROM changeLog WHERE createdAt < ?",
                [now.addingTimeInterval(-Double(RetentionPolicy.trashDays) * 86_400)]
            )
            return (report, removed)
        }

        for id in removedIDs {
            try? FileManager.default.removeItem(at: paths.files.appending(path: String(id)))
            try? FileManager.default.removeItem(at: paths.thumbnails.appending(path: "\(id).jpg"))
        }

        let referenced = try await database.read { db in
            Set(try db.query("SELECT DISTINCT blobHash FROM representation WHERE blobHash IS NOT NULL") { $0.string(0) })
        }
        var final = report
        // Undo log entries may still point at a blob, so nothing younger than the log's own lifetime goes.
        final.blobsRemoved = blobs.sweep(
            keeping: referenced,
            olderThan: now.addingTimeInterval(-Double(RetentionPolicy.trashDays) * 86_400)
        )
        if !removedIDs.isEmpty || report.trashed > 0 { notify(.removed) }
        return final
    }

    /// Permanently removes everything in the trash. Called only from an explicit user confirmation.
    public func emptyTrash() async throws {
        let removed = try await database.write { db -> [Int64] in
            let ids = try db.query("SELECT id FROM clip WHERE deletedAt IS NOT NULL") { $0.int64(0) }
            for id in ids {
                try db.execute("DELETE FROM clip WHERE id = ?", [id])
                try db.execute("DELETE FROM clipFTS WHERE rowid = ?", [id])
            }
            return ids
        }
        for id in removed {
            try? FileManager.default.removeItem(at: paths.files.appending(path: String(id)))
            try? FileManager.default.removeItem(at: paths.thumbnails.appending(path: "\(id).jpg"))
        }
        notify(.removed)
    }

    private static func jsonArray(_ ids: [Int64]) -> String {
        "[" + ids.map(String.init).joined(separator: ",") + "]"
    }
}
