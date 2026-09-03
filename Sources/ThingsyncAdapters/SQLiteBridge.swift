import SQLite3

/// SQLite's convention for a caller-owned string that must be copied
/// rather than referenced past the call -- there is no Swift-visible
/// `SQLITE_TRANSIENT` macro, so this is the standard cast used to obtain it.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

public struct SQLiteOpenFlags: OptionSet, Sendable {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let readOnly = SQLiteOpenFlags(rawValue: SQLITE_OPEN_READONLY)
    public static let readWrite = SQLiteOpenFlags(rawValue: SQLITE_OPEN_READWRITE)
    public static let create = SQLiteOpenFlags(rawValue: SQLITE_OPEN_CREATE)
    public static let uri = SQLiteOpenFlags(rawValue: SQLITE_OPEN_URI)
}

/// A single SQLite connection. Deliberately thin: precise control over the
/// open mode is the entire point of writing this instead of reaching for a
/// wrapper package -- doctor's WAL-sidecar diagnosis depends on opening
/// with exactly `[.readOnly, .uri]` against `file:<path>?mode=ro`, never
/// `immutable`, matching things.py exactly.
public final class SQLiteConnection {
    fileprivate let handle: OpaquePointer

    public init(path: String, flags: SQLiteOpenFlags) throws {
        var db: OpaquePointer?
        let status = sqlite3_open_v2(path, &db, flags.rawValue, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed with code \(status)"
            if let db { sqlite3_close(db) }
            throw SQLiteError("failed to open \(path): \(message)")
        }
        handle = db
    }

    deinit {
        sqlite3_close(handle)
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError("failed to prepare statement (\(sql)): \(String(cString: sqlite3_errmsg(handle)))")
        }
        return SQLiteStatement(handle: stmt)
    }

    /// Execute a statement with no result rows expected (DDL, INSERT, ...).
    public func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError("failed to execute (\(sql)): \(String(cString: sqlite3_errmsg(handle)))")
        }
    }
}

/// One prepared statement. Each query the adapter runs is its own implicit
/// transaction, matching things.py exactly -- multi-query reads are not a
/// single consistent snapshot.
public final class SQLiteStatement {
    private let handle: OpaquePointer

    fileprivate init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_finalize(handle)
    }

    public func bind(_ value: String, at index: Int32) {
        sqlite3_bind_text(handle, index, value, -1, sqliteTransient)
    }

    public func bind(_ value: Int, at index: Int32) {
        sqlite3_bind_int64(handle, index, Int64(value))
    }

    public func bindNull(at index: Int32) {
        sqlite3_bind_null(handle, index)
    }

    /// Advances to the next row. Returns false once rows are exhausted.
    @discardableResult
    public func step() throws -> Bool {
        let status = sqlite3_step(handle)
        switch status {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError("step failed with code \(status)")
        }
    }

    public func columnText(_ index: Int32) -> String? {
        guard sqlite3_column_type(handle, index) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: cString)
    }

    public func columnInt(_ index: Int32) -> Int? {
        guard sqlite3_column_type(handle, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(handle, index))
    }
}
