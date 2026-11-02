import Foundation

public struct AgentSessionInfo: Identifiable, Sendable, Hashable {
    public var id: Int64
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
}

extension ClipService {
    public func createAgentSession(title: String, now: Date = Date()) async throws -> Int64 {
        try await database.write { db in
            try db.execute("INSERT INTO agentSession(title, createdAt, updatedAt) VALUES (?, ?, ?)", [title, now, now])
            return db.lastInsertRowID
        }
    }

    public func agentSessions(limit: Int = 100) async throws -> [AgentSessionInfo] {
        try await database.read { db in
            try db.query("SELECT id, title, createdAt, updatedAt FROM agentSession ORDER BY updatedAt DESC LIMIT ?", [limit]) { row in
                AgentSessionInfo(id: row.int64(0), title: row.string(1), createdAt: row.date(2), updatedAt: row.date(3))
            }
        }
    }

    public func deleteAgentSession(id: Int64) async throws {
        try await database.write { db in
            try db.execute("DELETE FROM agentSession WHERE id = ?", [id])
        }
    }

    /// History is append-only: models that sign their reasoning reject a conversation whose past changed.
    public func appendAgentMessage(sessionID: Int64, payloadJSON: String, now: Date = Date()) async throws {
        try await database.write { db in
            try db.execute("INSERT INTO agentMessage(sessionID, payloadJSON, createdAt) VALUES (?, ?, ?)", [sessionID, payloadJSON, now])
            try db.execute("UPDATE agentSession SET updatedAt = ? WHERE id = ?", [now, sessionID])
        }
    }

    public func agentMessages(sessionID: Int64) async throws -> [String] {
        try await database.read { db in
            try db.query("SELECT payloadJSON FROM agentMessage WHERE sessionID = ? ORDER BY id", [sessionID]) { $0.string(0) }
        }
    }
}
