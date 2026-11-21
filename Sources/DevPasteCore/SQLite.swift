import Foundation
import SQLite3

/// A small wrapper over the SQLite C API. Not thread safe on its own: HistoryStore serialises access.
public enum SQLValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDB {
    let handle: OpaquePointer

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            throw SQLiteError(code: rc, message: message)
        }
        handle = db
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit { sqlite3_close(handle) }

    private func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Runs one or more statements with no parameters and no results wanted.
    func exec(_ sql: String) throws {
        let rc = sqlite3_exec(handle, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
    }

    /// Runs one statement with parameters. Returns the number of changed rows.
    @discardableResult
    func run(_ sql: String, _ args: [SQLValue] = []) throws -> Int {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc) }
        return Int(sqlite3_changes(handle))
    }

    /// Runs a query and calls `row` for each result row.
    func query(_ sql: String, _ args: [SQLValue] = [], row: (Row) throws -> Void) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            try row(Row(stmt: stmt))
        }
    }

    func scalarInt(_ sql: String, _ args: [SQLValue] = []) throws -> Int64 {
        var value: Int64 = 0
        try query(sql, args) { value = $0.int(0) }
        return value
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// A consistent copy of the live database (H2). Never copy a live SQLite file by hand.
    func vacuumInto(_ path: String) throws {
        try exec("VACUUM INTO '\(path.replacingOccurrences(of: "'", with: "''"))'")
    }

    /// Replaces this database's contents with another file's, using SQLite's online backup API.
    func restore(fromFile path: String) throws {
        var source: OpaquePointer?
        let rc = sqlite3_open_v2(path, &source, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let source else {
            if let source { sqlite3_close(source) }
            throw SQLiteError(code: rc, message: "could not open \(path)")
        }
        defer { sqlite3_close(source) }
        guard let backup = sqlite3_backup_init(handle, "main", source, "main") else { throw error(sqlite3_errcode(handle)) }
        let step = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE else { throw SQLiteError(code: step, message: "restore did not complete") }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc) }
        for (index, value) in args.enumerated() {
            let i = Int32(index + 1)
            let brc: Int32
            switch value {
            case .null:
                brc = sqlite3_bind_null(stmt, i)
            case .int(let v):
                brc = sqlite3_bind_int64(stmt, i, v)
            case .double(let v):
                brc = sqlite3_bind_double(stmt, i, v)
            case .text(let v):
                brc = sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                if v.isEmpty {
                    brc = sqlite3_bind_zeroblob(stmt, i, 0)
                } else {
                    brc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
                }
            }
            if brc != SQLITE_OK {
                sqlite3_finalize(stmt)
                throw error(brc)
            }
        }
        return stmt
    }
}

struct Row {
    let stmt: OpaquePointer

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }

    func text(_ i: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: p)
    }

    func blob(_ i: Int32) -> Data? {
        if isNull(i) { return nil }
        let count = Int(sqlite3_column_bytes(stmt, i))
        guard count > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: count)
    }
}
