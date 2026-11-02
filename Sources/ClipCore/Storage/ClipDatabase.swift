import Foundation

/// WAL database with one writer and one reader connection, each confined to its own serial queue.
public final class ClipDatabase: Sendable {
    private let writer: SQLiteConnection
    private let reader: SQLiteConnection
    private let writeQueue = DispatchQueue(label: "pastai.db.write", qos: .userInitiated)
    private let readQueue = DispatchQueue(label: "pastai.db.read", qos: .userInitiated)

    public init(path: String) throws {
        writer = try SQLiteConnection(path: path)
        try writer.script("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;")
        try Self.migrate(writer)
        reader = try SQLiteConnection(path: path, readOnly: true)
        try reader.script("PRAGMA foreign_keys = ON; PRAGMA query_only = ON;")
    }

    public func read<T: Sendable>(_ body: @escaping @Sendable (SQLiteConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            readQueue.async { [reader] in
                continuation.resume(with: Result { try body(reader) })
            }
        }
    }

    public func write<T: Sendable>(_ body: @escaping @Sendable (SQLiteConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.async { [writer] in
                continuation.resume(with: Result { try writer.transaction { try body(writer) } })
            }
        }
    }

    private static func migrate(_ connection: SQLiteConnection) throws {
        let current = Int(try connection.scalarInt("PRAGMA user_version"))
        for (index, script) in migrations.enumerated() where index >= current {
            try connection.transaction {
                try connection.script(script)
                try connection.script("PRAGMA user_version = \(index + 1)")
            }
        }
    }

    private static let migrations: [String] = [
        """
        CREATE TABLE clip(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            title TEXT,
            plainText TEXT,
            textLength INTEGER NOT NULL DEFAULT 0,
            sourceBundleID TEXT,
            sourceAppName TEXT,
            contentHash TEXT NOT NULL,
            byteSize INTEGER NOT NULL DEFAULT 0,
            createdAt REAL NOT NULL,
            lastCopiedAt REAL NOT NULL,
            lastUsedAt REAL,
            copyCount INTEGER NOT NULL DEFAULT 1,
            useCount INTEGER NOT NULL DEFAULT 0,
            isSensitive INTEGER NOT NULL DEFAULT 0,
            aiHidden INTEGER NOT NULL DEFAULT 0,
            ocrText TEXT,
            metadataJSON TEXT,
            thumbnailPath TEXT,
            enrichedAt REAL,
            deletedAt REAL
        );
        CREATE UNIQUE INDEX clipHash ON clip(contentHash);
        CREATE INDEX clipTimeline ON clip(deletedAt, lastCopiedAt DESC, id DESC);
        CREATE INDEX clipKindTimeline ON clip(kind, deletedAt, lastCopiedAt DESC);
        CREATE INDEX clipSource ON clip(sourceBundleID);

        CREATE TABLE representation(
            id INTEGER PRIMARY KEY,
            clipID INTEGER NOT NULL REFERENCES clip(id) ON DELETE CASCADE,
            itemIndex INTEGER NOT NULL,
            position INTEGER NOT NULL,
            uti TEXT NOT NULL,
            inlineData BLOB,
            blobHash TEXT,
            byteSize INTEGER NOT NULL
        );
        CREATE INDEX representationClip ON representation(clipID, itemIndex, position);
        CREATE INDEX representationBlob ON representation(blobHash);

        CREATE TABLE clipFile(
            id INTEGER PRIMARY KEY,
            clipID INTEGER NOT NULL REFERENCES clip(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            originalPath TEXT NOT NULL,
            bookmark BLOB,
            snapshotPath TEXT,
            fileName TEXT NOT NULL,
            uti TEXT,
            byteSize INTEGER NOT NULL DEFAULT 0,
            isDirectory INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX clipFileClip ON clipFile(clipID, position);

        CREATE TABLE pinboard(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            colorHex TEXT NOT NULL,
            sortOrder INTEGER NOT NULL,
            aiHidden INTEGER NOT NULL DEFAULT 0,
            createdAt REAL NOT NULL
        );

        CREATE TABLE pinboardClip(
            pinboardID INTEGER NOT NULL REFERENCES pinboard(id) ON DELETE CASCADE,
            clipID INTEGER NOT NULL REFERENCES clip(id) ON DELETE CASCADE,
            addedAt REAL NOT NULL,
            PRIMARY KEY(pinboardID, clipID)
        ) WITHOUT ROWID;
        CREATE INDEX pinboardClipByClip ON pinboardClip(clipID);

        CREATE TABLE tag(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE COLLATE NOCASE
        );

        CREATE TABLE clipTag(
            clipID INTEGER NOT NULL REFERENCES clip(id) ON DELETE CASCADE,
            tagID INTEGER NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
            PRIMARY KEY(clipID, tagID)
        ) WITHOUT ROWID;
        CREATE INDEX clipTagByTag ON clipTag(tagID);

        CREATE TABLE changeLog(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            batchID TEXT NOT NULL,
            source TEXT NOT NULL,
            summary TEXT NOT NULL,
            inverseJSON TEXT NOT NULL,
            createdAt REAL NOT NULL,
            undoneAt REAL
        );
        CREATE INDEX changeLogBatch ON changeLog(batchID);

        CREATE TABLE agentSession(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL
        );

        CREATE TABLE agentMessage(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sessionID INTEGER NOT NULL REFERENCES agentSession(id) ON DELETE CASCADE,
            payloadJSON TEXT NOT NULL,
            createdAt REAL NOT NULL
        );
        CREATE INDEX agentMessageSession ON agentMessage(sessionID, id);

        CREATE VIRTUAL TABLE clipFTS USING fts5(title, body, ocr, tags, tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3 4');
        """,
    ]
}
