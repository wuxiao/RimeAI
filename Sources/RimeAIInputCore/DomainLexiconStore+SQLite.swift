import Foundation
import SQLite3

/// Low-level SQLite helpers for `DomainLexiconStore`, mirroring the
/// layout of `PhraseBookStore+SQLite` (which itself mirrors
/// `HistoryStore+SQLite`). Only call while holding `queue.sync`.
extension DomainLexiconStore {
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
            throw DomainLexiconError.sqlite(
                code: SQLITE_MISUSE,
                message: "lexicon database is closed"
            )
        }
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw DomainLexiconError.sqlite(code: status, message: detail)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else {
            throw DomainLexiconError.sqlite(
                code: SQLITE_MISUSE,
                message: "lexicon database is closed"
            )
        }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw DomainLexiconError.sqlite(
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
        let status = sqlite3_bind_text(
            statement,
            index,
            value,
            -1,
            transient
        )
        guard status == SQLITE_OK else {
            throw sqliteError(code: status)
        }
    }

    /// Prepared-statement execute with bound string parameters, in
    /// order.
    func run(_ sql: String, _ values: [String]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            try bind(value, to: statement, index: Int32(offset + 1))
        }
        try stepDone(statement)
    }

    func stepDone(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw sqliteError(code: status)
        }
    }

    func columnText(
        _ statement: OpaquePointer,
        index: Int32
    ) -> String {
        guard let cString = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: cString)
    }

    func sqliteError(code: Int32) -> DomainLexiconError {
        guard let database else {
            return DomainLexiconError.sqlite(
                code: code,
                message: "lexicon database is closed"
            )
        }
        return DomainLexiconError.sqlite(
            code: code,
            message: String(cString: sqlite3_errmsg(database))
        )
    }
}
