import Foundation
import SQLite3

/// `sqlite3_bind_*` needs this sentinel to copy buffers; the Swift importer does not expose it.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public let sql: String?

    public var description: String { "SQLite \(code): \(message)" + (sql.map { " [\($0)]" } ?? "") }
    public var isConstraintViolation: Bool { code & 0xFF == SQLITE_CONSTRAINT }
}

public enum SQLValue: Sendable, Hashable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Date: SQLBindable { public var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { map(\.sqlValue) ?? .null }
}

/// One result row. Only valid inside the `query` closure that received it.
public struct Row {
    fileprivate let statement: OpaquePointer

    public func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }
    public func int64(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    public func int(_ index: Int32) -> Int { Int(int64(index)) }
    public func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    public func bool(_ index: Int32) -> Bool { int64(index) != 0 }

    public func optionalInt64(_ index: Int32) -> Int64? { isNull(index) ? nil : int64(index) }
    public func optionalString(_ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }
    public func string(_ index: Int32) -> String { optionalString(index) ?? "" }
    public func date(_ index: Int32) -> Date { Date(timeIntervalSince1970: double(index)) }
    public func optionalDate(_ index: Int32) -> Date? { isNull(index) ? nil : date(index) }
    public func optionalData(_ index: Int32) -> Data? {
        guard !isNull(index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

/// A single connection. Thread confinement is the caller's job: `ClipDatabase` owns one queue per connection.
public final class SQLiteConnection: @unchecked Sendable {
    private let handle: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]

    public init(path: String, readOnly: Bool = false) throws {
        var pointer: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &pointer, flags, nil)
        guard code == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(pointer)
            throw SQLiteError(code: code, message: message, sql: nil)
        }
        handle = pointer
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        statements.values.forEach { sqlite3_finalize($0) }
        sqlite3_close_v2(handle)
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    public var changes: Int { Int(sqlite3_changes(handle)) }

    /// Runs one or more statements with no parameters: schema scripts and PRAGMAs.
    public func script(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard code == SQLITE_OK else {
            throw SQLiteError(code: code, message: message.map { String(cString: $0) } ?? "exec failed", sql: sql)
        }
    }

    public func execute(_ sql: String, _ arguments: [any SQLBindable] = []) throws {
        let statement = try prepare(sql, arguments)
        defer { sqlite3_reset(statement) }
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW { code = sqlite3_step(statement) }
        guard code == SQLITE_DONE else { throw lastError(code: code, sql: sql) }
    }

    public func query<T>(_ sql: String, _ arguments: [any SQLBindable] = [], _ map: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql, arguments)
        defer { sqlite3_reset(statement) }
        var results: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                results.append(try map(Row(statement: statement)))
            } else if code == SQLITE_DONE {
                return results
            } else {
                throw lastError(code: code, sql: sql)
            }
        }
    }

    public func first<T>(_ sql: String, _ arguments: [any SQLBindable] = [], _ map: (Row) throws -> T) throws -> T? {
        let statement = try prepare(sql, arguments)
        defer { sqlite3_reset(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_ROW { return try map(Row(statement: statement)) }
        guard code == SQLITE_DONE else { throw lastError(code: code, sql: sql) }
        return nil
    }

    public func scalarInt(_ sql: String, _ arguments: [any SQLBindable] = []) throws -> Int64 {
        try first(sql, arguments) { $0.int64(0) } ?? 0
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try script("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try script("COMMIT")
            return result
        } catch {
            try? script("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ arguments: [any SQLBindable]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
            sqlite3_clear_bindings(statement)
        } else {
            var pointer: OpaquePointer?
            let code = sqlite3_prepare_v2(handle, sql, -1, &pointer, nil)
            guard code == SQLITE_OK, let pointer else { throw lastError(code: code, sql: sql) }
            statement = pointer
            statements[sql] = pointer
        }
        for (offset, argument) in arguments.enumerated() {
            let code = bind(argument.sqlValue, to: statement, at: Int32(offset + 1))
            guard code == SQLITE_OK else {
                sqlite3_reset(statement)
                throw lastError(code: code, sql: sql)
            }
        }
        return statement
    }

    private func bind(_ value: SQLValue, to statement: OpaquePointer, at index: Int32) -> Int32 {
        switch value {
        case .null:
            return sqlite3_bind_null(statement, index)
        case .int(let value):
            return sqlite3_bind_int64(statement, index, value)
        case .double(let value):
            return sqlite3_bind_double(statement, index, value)
        case .text(let value):
            return sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        case .blob(let value):
            return value.withUnsafeBytes { buffer in
                // A nil pointer would bind NULL, so an empty blob needs a real zero-length buffer.
                if buffer.isEmpty { return sqlite3_bind_zeroblob(statement, index, 0) }
                return sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
            }
        }
    }

    private func lastError(code: Int32, sql: String) -> SQLiteError {
        SQLiteError(code: sqlite3_extended_errcode(handle), message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }
}
