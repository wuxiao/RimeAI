import Foundation
import SQLite3

public enum HistoryCommitSource: String, Codable, Sendable {
    case rimeMain = "rime_main"
    case localSemantic = "local_semantic"
    case cloudExact = "cloud_exact"
    case cloudFuzzy = "cloud_fuzzy"
    case rawPinyin = "raw_pinyin"
}

public struct HistoryCommit: Codable, Equatable, Sendable {
    public let id: UUID
    public let committedAt: Date
    public let bundleIdentifier: String
    public let pinyin: String
    public let committedText: String
    public let source: HistoryCommitSource

    public init(
        id: UUID = UUID(),
        committedAt: Date = Date(),
        bundleIdentifier: String,
        pinyin: String,
        committedText: String,
        source: HistoryCommitSource
    ) {
        self.id = id
        self.committedAt = committedAt
        self.bundleIdentifier = bundleIdentifier
        self.pinyin = pinyin
        self.committedText = committedText
        self.source = source
    }
}

public struct HistoryStoreStatistics: Equatable, Sendable {
    public let recordCount: Int
    public let generation: Int64
    public let pendingEmbeddingJobs: Int
    public let unembeddedRecords: Int
}

public struct HistoryContextSnapshot: Equatable, Sendable {
    public let recentText: String
    public let relevantSnippets: [CloudHistorySnippet]
    public let generation: Int64

    public init(
        recentText: String,
        relevantSnippets: [CloudHistorySnippet],
        generation: Int64
    ) {
        self.recentText = recentText
        self.relevantSnippets = relevantSnippets
        self.generation = generation
    }
}

public enum HistoryStoreError: Error, Equatable, Sendable {
    case invalidRecord
    case sqlite(code: Int32, message: String)
    case fileSystem(String)
}

public final class HistoryStore: @unchecked Sendable {
    public let databaseURL: URL
    public let vectorIndexURL: URL

    private let queue = DispatchQueue(
        label: "fun.wwcn.rimeai.history-store"
    )
    private let fileManager: FileManager
    private var database: OpaquePointer?

    public init(
        databaseURL: URL,
        vectorIndexURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.databaseURL = databaseURL
        self.vectorIndexURL = vectorIndexURL
            ?? databaseURL.deletingLastPathComponent()
                .appendingPathComponent(
                    "history-hnsw-v1.bin",
                    isDirectory: false
                )
        self.fileManager = fileManager

        let directory = databaseURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch {
            throw HistoryStoreError.fileSystem(error.localizedDescription)
        }

        var opened: OpaquePointer?
        let status = sqlite3_open_v2(
            databaseURL.path,
            &opened,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let opened else {
            let message = opened.map {
                String(cString: sqlite3_errmsg($0))
            } ?? "could not open history database"
            if let opened {
                sqlite3_close_v2(opened)
            }
            throw HistoryStoreError.sqlite(code: status, message: message)
        }
        database = opened

        do {
            try configureDatabase()
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: databaseURL.path
            )
        } catch {
            sqlite3_close_v2(opened)
            database = nil
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

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

    public func recentText(maxCharacters: Int = 600) throws -> String {
        guard maxCharacters > 0 else {
            return ""
        }
        return try queue.sync {
            try recentTextLocked(maxCharacters: maxCharacters)
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

    public func relevantSnippets(
        query rawQuery: String,
        maximumCount: Int = 8
    ) throws -> [CloudHistorySnippet] {
        let query = rawQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty, maximumCount > 0 else {
            return []
        }
        return try queue.sync {
            try relevantSnippetsLocked(
                query: query,
                maximumCount: maximumCount
            )
        }
    }

    public func contextSnapshot(
        query rawQuery: String,
        maxRecentCharacters: Int = 600,
        maximumSnippetCount: Int = 8
    ) throws -> HistoryContextSnapshot {
        let query = rawQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return try queue.sync {
            let generation = try queryInt64(
                "SELECT generation FROM history_metadata WHERE id = 1"
            )
            let recent = maxRecentCharacters > 0
                ? try recentTextLocked(
                    maxCharacters: min(maxRecentCharacters, 600)
                )
                : ""
            let snippets = !query.isEmpty && maximumSnippetCount > 0
                ? try relevantSnippetsLocked(
                    query: query,
                    maximumCount: min(maximumSnippetCount, 8)
                )
                : []
            return HistoryContextSnapshot(
                recentText: recent,
                relevantSnippets: snippets,
                generation: generation
            )
        }
    }

    public func statistics() throws -> HistoryStoreStatistics {
        try queue.sync {
            HistoryStoreStatistics(
                recordCount: Int(
                    try queryInt64("SELECT COUNT(*) FROM history_commits")
                ),
                generation: try queryInt64(
                    "SELECT generation FROM history_metadata WHERE id = 1"
                ),
                pendingEmbeddingJobs: Int(
                    try queryInt64(
                        """
                        SELECT COUNT(*) FROM embedding_jobs
                        WHERE status IN ('pending', 'retry')
                        """
                    )
                ),
                unembeddedRecords: Int(
                    try queryInt64(
                        """
                        SELECT COUNT(*) FROM history_commits
                        WHERE embedding_state != 'ready'
                        """
                    )
                )
            )
        }
    }

    @discardableResult
    public func clearAll() throws -> Int64 {
        let generation = try queue.sync {
            try transaction {
                try execute("DELETE FROM history_fts")
                try execute("DELETE FROM embedding_jobs")
                try execute("DELETE FROM history_commits")
                try execute(
                    """
                    UPDATE history_metadata
                    SET generation = generation + 1
                    WHERE id = 1
                    """
                )
            }
            try execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try execute("VACUUM")
            return try queryInt64(
                "SELECT generation FROM history_metadata WHERE id = 1"
            )
        }
        do {
            let derivedURLs = [
                vectorIndexURL,
                vectorIndexURL.deletingPathExtension()
                    .appendingPathExtension("tmp"),
            ]
            for url in derivedURLs
            where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        } catch {
            throw HistoryStoreError.fileSystem(error.localizedDescription)
        }
        return generation
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

    private func configureDatabase() throws {
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA secure_delete=ON")
        try execute("PRAGMA busy_timeout=1000")
        try execute("PRAGMA user_version=1")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS history_metadata (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                generation INTEGER NOT NULL
            )
            """
        )
        try execute(
            """
            INSERT OR IGNORE INTO history_metadata(id, generation)
            VALUES (1, 0)
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS history_commits (
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
            )
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS history_commits_time
            ON history_commits(committed_at_ms)
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS embedding_jobs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                commit_id TEXT NOT NULL UNIQUE
                    REFERENCES history_commits(id) ON DELETE CASCADE,
                status TEXT NOT NULL DEFAULT 'pending',
                attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt_ms INTEGER NOT NULL DEFAULT 0,
                created_at_ms INTEGER NOT NULL
            )
            """
        )
        do {
            try execute(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS history_fts
                USING fts5(
                    commit_id UNINDEXED,
                    committed_text,
                    pinyin,
                    tokenize='trigram'
                )
                """
            )
        } catch {
            // Older SQLite builds may omit the trigram tokenizer. Preserve a
            // searchable local fallback instead of failing history capture.
            try execute(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS history_fts
                USING fts5(
                    commit_id UNINDEXED,
                    committed_text,
                    pinyin,
                    tokenize='unicode61'
                )
                """
            )
        }
        try execute(
            """
            CREATE TABLE IF NOT EXISTS history_metrics (
                key TEXT PRIMARY KEY NOT NULL,
                value INTEGER NOT NULL DEFAULT 0
            )
            """
        )
    }

    private func appendLocked(_ commit: HistoryCommit) throws {
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

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func relevantSnippetsUsingLike(
        query: String,
        maximumCount: Int
    ) throws -> [CloudHistorySnippet] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let statement = try prepare(
            """
            SELECT id, committed_text, bundle_id, committed_at_ms, 1.0
            FROM history_commits
            WHERE committed_text LIKE ? ESCAPE '\\'
               OR pinyin LIKE ? ESCAPE '\\'
            ORDER BY committed_at_ms DESC
            LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind("%\(escaped)%", to: statement, index: 1)
        try bind("%\(escaped)%", to: statement, index: 2)
        sqlite3_bind_int(statement, 3, Int32(maximumCount))
        return try readSnippets(statement)
    }

    private func recentTextLocked(maxCharacters: Int) throws -> String {
        let statement = try prepare(
            """
            SELECT committed_text
            FROM history_commits
            ORDER BY committed_at_ms DESC, rowid DESC
            LIMIT 4096
            """
        )
        defer { sqlite3_finalize(statement) }
        var newestFirst: [String] = []
        var characterCount = 0
        while sqlite3_step(statement) == SQLITE_ROW,
              characterCount < maxCharacters
        {
            let value = columnText(statement, index: 0)
            newestFirst.append(value)
            characterCount += value.count
        }
        return String(
            newestFirst.reversed().joined().suffix(maxCharacters)
        )
    }

    private func relevantSnippetsLocked(
        query: String,
        maximumCount: Int
    ) throws -> [CloudHistorySnippet] {
        let limit = min(max(maximumCount, 1), 8)
        do {
            let ftsQuery = "\""
                + query.replacingOccurrences(of: "\"", with: "\"\"")
                + "\""
            let statement = try prepare(
                """
                SELECT c.id, c.committed_text, c.bundle_id,
                       c.committed_at_ms, bm25(history_fts)
                FROM history_fts
                JOIN history_commits c
                  ON c.id = history_fts.commit_id
                WHERE history_fts MATCH ?
                ORDER BY bm25(history_fts), c.committed_at_ms DESC
                LIMIT ?
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(ftsQuery, to: statement, index: 1)
            sqlite3_bind_int(statement, 2, Int32(limit))
            return try readSnippets(statement)
        } catch {
            return try relevantSnippetsUsingLike(
                query: query,
                maximumCount: limit
            )
        }
    }

    private func readSnippets(
        _ statement: OpaquePointer
    ) throws -> [CloudHistorySnippet] {
        var values: [CloudHistorySnippet] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                break
            }
            guard status == SQLITE_ROW else {
                throw currentSQLiteError(code: status)
            }
            let rawScore = sqlite3_column_double(statement, 4)
            let score = rawScore.isFinite
                ? 1 / (1 + abs(rawScore))
                : 0
            values.append(
                CloudHistorySnippet(
                    id: columnText(statement, index: 0),
                    text: columnText(statement, index: 1),
                    bundleIdentifier: columnText(statement, index: 2),
                    committedAtMilliseconds: sqlite3_column_int64(
                        statement,
                        3
                    ),
                    score: score
                )
            )
        }
        return values
    }

    private func execute(_ sql: String) throws {
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

    private func prepare(_ sql: String) throws -> OpaquePointer {
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

    private func bind(
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

    private func stepDone(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else {
            throw currentSQLiteError(code: status)
        }
    }

    private func queryInt64(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW else {
            throw currentSQLiteError(code: status)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func columnText(
        _ statement: OpaquePointer,
        index: Int32
    ) -> String {
        guard let value = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: value)
    }

    private func currentSQLiteError(code: Int32) -> HistoryStoreError {
        guard let database else {
            return .sqlite(code: code, message: "history database is closed")
        }
        return .sqlite(
            code: code,
            message: String(cString: sqlite3_errmsg(database))
        )
    }
}
