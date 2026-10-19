import Foundation
import CSQLite

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public var code: Int32
    public var message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// Minimal original wrapper over the SQLite C API: prepared statements only,
/// no string-built SQL with user data.
final class SQLiteDatabase {
    private(set) var handle: OpaquePointer?

    /// Opens an empty in-memory database.
    init() throws {
        guard sqlite3_open_v2(":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(code: SQLITE_CANTOPEN, message: message)
        }
        try execute("PRAGMA foreign_keys = ON")
    }

    /// Opens an in-memory copy of serialized database bytes. The input is copied;
    /// the caller's data (the archive member) is never modified.
    convenience init(bytes: Data) throws {
        try self.init()
        guard bytes.count >= 100, bytes.prefix(16) == Data("SQLite format 3\u{0}".utf8) else {
            throw SQLiteError(code: SQLITE_NOTADB, message: "The show database is not an SQLite file.")
        }
        let size = sqlite3_int64(bytes.count)
        guard let buffer = sqlite3_malloc64(sqlite3_uint64(bytes.count)) else { throw SQLiteError(code: SQLITE_NOMEM, message: "Out of memory") }
        bytes.withUnsafeBytes { raw in buffer.copyMemory(from: raw.baseAddress!, byteCount: bytes.count) }
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE)
        let rc = sqlite3_deserialize(handle, "main", buffer.assumingMemoryBound(to: UInt8.self), size, size, flags)
        guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: lastMessage) }
        try execute("PRAGMA foreign_keys = ON")
        let check = try scalarText("PRAGMA quick_check")
        guard check == "ok" else { throw SQLiteError(code: SQLITE_CORRUPT, message: "Database integrity check failed: \(check ?? "unknown")") }
    }

    deinit { sqlite3_close_v2(handle) }

    var lastMessage: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database" }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? lastMessage
            sqlite3_free(error)
            throw SQLiteError(code: rc, message: message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw SQLiteError(code: rc, message: "\(lastMessage) in: \(sql)") }
        return SQLiteStatement(statement, db: self)
    }

    /// Runs `body` inside one transaction; rolls back on error.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func scalarInt(_ sql: String) throws -> Int64? {
        let s = try prepare(sql)
        return try s.step() ? s.int64(0) : nil
    }

    func scalarText(_ sql: String) throws -> String? {
        let s = try prepare(sql)
        return try s.step() ? s.text(0) : nil
    }

    var userVersion: Int {
        get { (try? scalarInt("PRAGMA user_version")).flatMap { $0 }.map(Int.init) ?? 0 }
    }

    func setUserVersion(_ v: Int) throws { try execute("PRAGMA user_version = \(v)") }

    /// A consistent snapshot of the whole database as bytes.
    func serialize() throws -> Data {
        var size: sqlite3_int64 = 0
        guard let pointer = sqlite3_serialize(handle, "main", &size, 0) else {
            throw SQLiteError(code: SQLITE_NOMEM, message: "Could not serialize the show database.")
        }
        defer { sqlite3_free(pointer) }
        return Data(bytes: pointer, count: Int(size))
    }
}

final class SQLiteStatement {
    private let statement: OpaquePointer
    private let db: SQLiteDatabase

    init(_ statement: OpaquePointer, db: SQLiteDatabase) {
        self.statement = statement
        self.db = db
    }

    deinit { sqlite3_finalize(statement) }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    @discardableResult
    func bind(_ values: [SQLValue]) throws -> SQLiteStatement {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(statement, index)
            case .int(let v): rc = sqlite3_bind_int64(statement, index, v)
            case .double(let v): rc = sqlite3_bind_double(statement, index, v)
            case .text(let v): rc = sqlite3_bind_text(statement, index, v, -1, SQLiteStatement.transient)
            case .blob(let v):
                rc = v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(v.count), SQLiteStatement.transient) }
            }
            guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: db.lastMessage) }
        }
        return self
    }

    /// Executes a statement that returns no rows.
    func run(_ values: [SQLValue] = []) throws {
        try bind(values)
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE else { throw SQLiteError(code: rc, message: db.lastMessage) }
    }

    /// Advances to the next row; false when done.
    func step() throws -> Bool {
        let rc = sqlite3_step(statement)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw SQLiteError(code: rc, message: db.lastMessage)
    }

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(statement, i) == SQLITE_NULL }
    func isInteger(_ i: Int32) -> Bool { sqlite3_column_type(statement, i) == SQLITE_INTEGER }
    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(statement, i) }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(statement, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(statement, i) }
    func text(_ i: Int32) -> String {
        guard let p = sqlite3_column_text(statement, i) else { return "" }
        return String(cString: p)
    }
    func optionalText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
}

enum SQLValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    static func optional(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
    static func int(_ v: Int) -> SQLValue { .int(Int64(v)) }
    static func bool(_ v: Bool) -> SQLValue { .int(v ? 1 : 0) }
}
