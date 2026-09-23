import Foundation
import SQLite3
import Darwin

public enum SQLValue: Equatable, Sendable {
    case null, integer(Int64), real(Double), text(String), blob(Data)

    public var string: String? { if case let .text(value) = self { value } else { nil } }
    public var integer: Int64? { if case let .integer(value) = self { value } else { nil } }
}

public struct StateDatabaseError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Host-owned, serial SQLite storage. Supply your own path, ordered migrations and schema.
/// Transactions are synchronous and may not escape or be nested. Values use bound parameters.
/// Adapted from REL's database.rs and migrations.rs; no REL application tables are included.
// Every operation holds this recursive lock, including the entire transaction closure.
// No connection or statement pointer escapes; initialization and destruction are exclusive.
public final class StateDatabase: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var handle: OpaquePointer?
    private var inTransaction = false

    public init(url: URL, migrations: [String], schema: [String: [String]]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw StateDatabaseError("Could not create or open state database.") }
        Darwin.close(descriptor)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let failure = failure()
            sqlite3_close(handle); handle = nil
            throw failure
        }
        do {
            sqlite3_busy_timeout(handle, 5_000)
            guard try query("PRAGMA journal_mode = WAL").first?["journal_mode"]?.string == "wal" else {
                throw StateDatabaseError("Could not enable SQLite WAL mode.")
            }
            try executeScript("PRAGMA foreign_keys = ON; PRAGMA synchronous = NORMAL; PRAGMA wal_autocheckpoint = 1000; PRAGMA journal_size_limit = 67108864;")
            try transaction {
                let version = Int(try query("PRAGMA user_version").first?["user_version"]?.integer ?? 0)
                guard version >= 0, version <= migrations.count else { throw StateDatabaseError("State database is newer than this build supports.") }
                if version == 0, !(try tableNames()).isEmpty { throw StateDatabaseError("Unversioned state database is not supported.") }
                for index in version..<migrations.count {
                    try executeScript(migrations[index])
                    try executeScript("PRAGMA user_version = \(index + 1)")
                }
                try validate(schema)
            }
            for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
            }
        } catch {
            sqlite3_close(handle); handle = nil
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    public func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    public func query(_ sql: String, _ values: [SQLValue] = []) throws -> [[String: SQLValue]] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [[String: SQLValue]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw failure() }
            var row: [String: SQLValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    row[name] = .text(String(decoding: UnsafeBufferPointer(start: sqlite3_column_text(statement, index), count: count), as: UTF8.self))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    row[name] = .blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, index)!, count: count))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
    }

    @discardableResult public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !inTransaction else { throw StateDatabaseError("Nested state transactions are not supported.") }
        try executeScript("BEGIN IMMEDIATE")
        inTransaction = true
        defer { inTransaction = false }
        do {
            let result = try body()
            try executeScript("COMMIT")
            return result
        } catch {
            try? executeScript("ROLLBACK")
            throw error
        }
    }

    private func executeScript(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        do {
            guard sqlite3_bind_parameter_count(statement) == values.count else { throw StateDatabaseError("Incorrect SQLite parameter count.") }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let status: Int32
                switch value {
                case .null: status = sqlite3_bind_null(statement, index)
                case let .integer(number): status = sqlite3_bind_int64(statement, index, number)
                case let .real(number): status = sqlite3_bind_double(statement, index, number)
                case let .text(text): status = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), transient) }
                case let .blob(data):
                    status = data.isEmpty ? sqlite3_bind_zeroblob(statement, index, 0) : data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
                }
                guard status == SQLITE_OK else { throw failure() }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }

    private func tableNames() throws -> Set<String> {
        Set(try query("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").compactMap { $0["name"]?.string })
    }

    private func validate(_ schema: [String: [String]]) throws {
        guard try tableNames() == Set(schema.keys) else { throw StateDatabaseError("State database contains missing or unsupported tables.") }
        for (table, columns) in schema {
            let actual = Set(try query("SELECT name FROM pragma_table_info(?)", [.text(table)]).compactMap { $0["name"]?.string })
            guard Set(columns).isSubset(of: actual) else { throw StateDatabaseError("State database is missing required columns in \(table).") }
        }
        guard try query("PRAGMA foreign_key_check").isEmpty else { throw StateDatabaseError("State database contains invalid references.") }
        guard try query("PRAGMA quick_check").first?["quick_check"]?.string == "ok" else { throw StateDatabaseError("State database failed its integrity check.") }
    }

    private func failure() -> StateDatabaseError {
        StateDatabaseError("SQLite: \(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open database")")
    }
}
