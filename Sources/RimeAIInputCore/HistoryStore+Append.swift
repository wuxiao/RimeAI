import Foundation
import SQLite3

extension HistoryStore {
    public func append(_ commit: HistoryCommit) throws {
        try queue.sync {
            try appendLocked(commit)
        }
    }

    public func appendAsync(
        _ commit: HistoryCommit,
        completion: (@Sendable (Result<Void, HistoryStoreError>) -> Void)? = nil
    ) {
        queue.async { [self] in
            do {
                try appendLocked(commit)
                completion?(.success(()))
            } catch let error as HistoryStoreError {
                completion?(.failure(error))
            } catch {
                completion?(
                    .failure(.fileSystem(error.localizedDescription))
                )
            }
        }
    }

    public func records(limit: Int? = nil) throws -> [HistoryCommit] {
        try queue.sync {
            var sql = """
                SELECT id, committed_at_ms, bundle_id, pinyin,
                       committed_text, source
                FROM history_commits
                ORDER BY committed_at_ms ASC, rowid ASC
                """
            if let limit {
                sql += " LIMIT \(max(0, limit))"
            }
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            var values: [HistoryCommit] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let id = UUID(uuidString: columnText(statement, index: 0)),
                    let source = HistoryCommitSource(
                        rawValue: columnText(statement, index: 5)
                    )
                else {
                    continue
                }
                values.append(
                    HistoryCommit(
                        id: id,
                        committedAt: Date(
                            timeIntervalSince1970:
                                Double(sqlite3_column_int64(statement, 1))
                                / 1_000
                        ),
                        bundleIdentifier: columnText(statement, index: 2),
                        pinyin: columnText(statement, index: 3),
                        committedText: columnText(statement, index: 4),
                        source: source
                    )
                )
            }
            return values
        }
    }

    public func exportJSONL(to destination: URL) throws {
        let values = try records()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var payload = Data()
        for value in values {
            payload.append(try encoder.encode(value))
            payload.append(UInt8(ascii: "\n"))
        }
        do {
            try payload.write(to: destination, options: .atomic)
        } catch {
            throw HistoryStoreError.fileSystem(error.localizedDescription)
        }
    }

    func appendLocked(_ commit: HistoryCommit) throws {
        let bundleIdentifier = commit.bundleIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !bundleIdentifier.isEmpty,
              !commit.committedText.isEmpty,
              !commit.committedText.contains("\u{0000}"),
              commit.committedText.utf8.count <= 16_384,
              commit.pinyin.utf8.count <= 256
        else {
            throw HistoryStoreError.invalidRecord
        }
        try transaction {
            let statement = try prepare(
                """
                INSERT OR IGNORE INTO history_commits(
                    id, committed_at_ms, bundle_id, pinyin,
                    committed_text, source
                ) VALUES (?, ?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(commit.id.uuidString, to: statement, index: 1)
            sqlite3_bind_int64(
                statement,
                2,
                Int64(commit.committedAt.timeIntervalSince1970 * 1_000)
            )
            try bind(bundleIdentifier, to: statement, index: 3)
            try bind(commit.pinyin, to: statement, index: 4)
            try bind(commit.committedText, to: statement, index: 5)
            try bind(commit.source.rawValue, to: statement, index: 6)
            try stepDone(statement)
            guard let database, sqlite3_changes(database) > 0 else {
                return
            }

            let fts = try prepare(
                """
                INSERT INTO history_fts(
                    commit_id, committed_text, pinyin
                ) VALUES (?, ?, ?)
                """
            )
            defer { sqlite3_finalize(fts) }
            try bind(commit.id.uuidString, to: fts, index: 1)
            try bind(commit.committedText, to: fts, index: 2)
            try bind(commit.pinyin, to: fts, index: 3)
            try stepDone(fts)

            let job = try prepare(
                """
                INSERT INTO embedding_jobs(
                    commit_id, status, attempts,
                    next_attempt_ms, created_at_ms
                ) VALUES (?, 'pending', 0, 0, ?)
                """
            )
            defer { sqlite3_finalize(job) }
            try bind(commit.id.uuidString, to: job, index: 1)
            sqlite3_bind_int64(
                job,
                2,
                Int64(commit.committedAt.timeIntervalSince1970 * 1_000)
            )
            try stepDone(job)
        }
    }
}
