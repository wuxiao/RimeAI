import Foundation
import SQLite3

/// Low-level SQLite helpers shared across the `HistoryStore` extension
/// files. All access is funneled through the store's serial queue by the
/// calling API, so these helpers must only be invoked while holding
/// `queue.sync`.
extension HistoryStore {
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String) throws {
        guard let database else {
            throw HistoryStoreError.sqlite(
                code: SQLITE_MISUSE,
                message: "history database is closed"
            )
        }
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw HistoryStoreError.sqlite(code: status, message: detail)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else {
            throw HistoryStoreError.sqlite(
                code: SQLITE_MISUSE,
                message: "history database is closed"
            )
        }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw HistoryStoreError.sqlite(
                code: status,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        return statement
    }

    func bind(
        _ value: String,
        to statement: OpaquePointer,
        index: Int32
    ) throws {
        let transient = unsafeBitCast(
            -1,
            to: sqlite3_destructor_type.self
        )
        let status = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, transient)
        }
        guard status == SQLITE_OK else {
            throw currentSQLiteError(code: status)
        }
    }

    func stepDone(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else {
            throw currentSQLiteError(code: status)
        }
    }

    func queryInt64(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW else {
            throw currentSQLiteError(code: status)
        }
        return sqlite3_column_int64(statement, 0)
    }

    func columnText(
        _ statement: OpaquePointer,
        index: Int32
    ) -> String {
        guard let value = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: value)
    }

    func currentSQLiteError(code: Int32) -> HistoryStoreError {
        guard let database else {
            return .sqlite(code: code, message: "history database is closed")
        }
        return .sqlite(
            code: code,
            message: String(cString: sqlite3_errmsg(database))
        )
    }
}
