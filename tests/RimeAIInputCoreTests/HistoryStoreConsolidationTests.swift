import Foundation
import SQLite3
import Testing
@testable import RimeAIInputCore

/// The consolidation state machine itself is owned by the Python daemon
/// (rimeai_daemon/consolidation.py); these tests only pin the on-disk
/// schema Swift is responsible for: the v1→v2 migration of
/// `history_commits.consolidation_state` and the `consolidation_state`
/// watermark table the daemon reads and writes.
@Suite("History consolidation schema (LP-001)")
struct HistoryStoreConsolidationTests {
    @Test("v1 databases migrate to the consolidation schema as raw")
    func v1Migration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RimeAI-HistoryMigrationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite3")

        // Build a legacy v1 database without consolidation_state.
        var raw: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &raw) == SQLITE_OK,
              let raw
        else {
            Issue.record("could not create legacy database")
            return
        }
        defer { sqlite3_close_v2(raw) }
        let legacySQL = """
            PRAGMA user_version=1;
            CREATE TABLE history_metadata (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                generation INTEGER NOT NULL
            );
            INSERT INTO history_metadata(id, generation) VALUES (1, 0);
            CREATE TABLE history_commits (
                id TEXT PRIMARY KEY NOT NULL,
                committed_at_ms INTEGER NOT NULL,
                bundle_id TEXT NOT NULL,
                pinyin TEXT NOT NULL,
                committed_text TEXT NOT NULL,
                source TEXT NOT NULL,
                embedding_model TEXT,
                embedding_dimension INTEGER,
                embedding_state TEXT NOT NULL DEFAULT 'pending',
                embedding BLOB
            );
            INSERT INTO history_commits(
                id, committed_at_ms, bundle_id, pinyin,
                committed_text, source
            ) VALUES (
                '00000000-0000-0000-0000-000000000009',
                1000, 'com.example.Legacy', 'ceshi', '旧记录', 'rime_main'
            );
            CREATE TABLE embedding_jobs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                commit_id TEXT NOT NULL UNIQUE
                    REFERENCES history_commits(id) ON DELETE CASCADE,
                status TEXT NOT NULL DEFAULT 'pending',
                attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt_ms INTEGER NOT NULL DEFAULT 0,
                created_at_ms INTEGER NOT NULL
            );
            CREATE TABLE history_metrics (
                key TEXT PRIMARY KEY NOT NULL,
                value INTEGER NOT NULL DEFAULT 0
            );
            """
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(raw, legacySQL, nil, nil, &message) == SQLITE_OK
        else {
            let detail = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            Issue.record("legacy schema failed: \(detail)")
            return
        }

        // Opening the store performs the migration in-process.
        let store = try HistoryStore(databaseURL: databaseURL)
        #expect(try store.records().count == 1)

        #expect(try scalarText(raw, "SELECT consolidation_state FROM history_commits WHERE id = '00000000-0000-0000-0000-000000000009'") == "raw")
        #expect(try scalarInt64(raw, "PRAGMA user_version") == 2)
        #expect(
            try scalarInt64(
                raw,
                "SELECT COUNT(*) FROM pragma_table_info('history_commits') WHERE name = 'consolidation_state'"
            ) == 1
        )
        #expect(
            try scalarInt64(
                raw,
                "SELECT statistics_watermark FROM consolidation_state WHERE id = 1"
            ) == 0
        )
        #expect(
            try scalarInt64(
                raw,
                "SELECT semantic_watermark FROM consolidation_state WHERE id = 1"
            ) == 0
        )
    }

    @Test("clearAll resets the daemon watermark row along with records")
    func clearAllResetsWatermarkRow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RimeAI-HistoryMigrationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite3")

        var raw: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &raw) == SQLITE_OK, let raw
        else {
            Issue.record("could not create database")
            return
        }
        defer { sqlite3_close_v2(raw) }
        let store = try HistoryStore(databaseURL: databaseURL)
        try store.append(
            HistoryCommit(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                committedAt: Date(timeIntervalSince1970: 1),
                bundleIdentifier: "com.example.Editor",
                pinyin: "ceshi",
                committedText: "测试",
                source: .rimeMain
            )
        )
        // Simulate the daemon advancing the watermarks, then clear all.
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(
            raw,
            """
            UPDATE consolidation_state
            SET statistics_watermark = 9, semantic_watermark = 9
            WHERE id = 1;
            """,
            nil,
            nil,
            &message
        ) == SQLITE_OK
        else {
            let detail = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            Issue.record("watermark update failed: \(detail)")
            return
        }

        _ = try store.clearAll()

        #expect(try store.statistics().recordCount == 0)
        #expect(
            try scalarInt64(
                raw,
                "SELECT statistics_watermark FROM consolidation_state WHERE id = 1"
            ) == 0
        )
        #expect(
            try scalarInt64(
                raw,
                "SELECT semantic_watermark FROM consolidation_state WHERE id = 1"
            ) == 0
        )
    }

    private func scalarInt64(
        _ database: OpaquePointer,
        _ sql: String
    ) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            == SQLITE_OK
        else {
            throw HistoryStoreError.sqlite(
                code: sqlite3_errcode(database),
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW
        else {
            throw HistoryStoreError.sqlite(
                code: sqlite3_errcode(database),
                message: "expected a row for: \(sql)"
            )
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func scalarText(
        _ database: OpaquePointer,
        _ sql: String
    ) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            == SQLITE_OK
        else {
            throw HistoryStoreError.sqlite(
                code: sqlite3_errcode(database),
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0)
        else {
            throw HistoryStoreError.sqlite(
                code: sqlite3_errcode(database),
                message: "expected a text row for: \(sql)"
            )
        }
        return String(cString: text)
    }
}
