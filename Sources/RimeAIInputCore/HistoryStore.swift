import Foundation
import SQLite3

public enum HistoryCommitSource: String, Codable, Sendable {
    case rimeMain = "rime_main"
    case localSemantic = "local_semantic"
    case phraseBook = "phrase_book"
    case cloudExact = "cloud_exact"
    case cloudFuzzy = "cloud_fuzzy"
    case cloudGenerated = "cloud_generated"
    case rawPinyin = "raw_pinyin"
    case continuation = "continuation"
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

    let queue = DispatchQueue(
        label: "fun.wwcn.rimeai.history-store"
    )
    private let fileManager: FileManager
    var database: OpaquePointer?

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
                try execute("DELETE FROM consolidation_state")
                try execute(
                    "INSERT INTO consolidation_state(id) VALUES (1)"
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

    // MARK: - Schema

    private func configureDatabase() throws {
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA secure_delete=ON")
        try execute("PRAGMA busy_timeout=1000")
        let existingUserVersion = try queryInt64("PRAGMA user_version")
        try createMetadataSchema()
        try createCommitSchema()
        try createDerivedSchema(existingUserVersion: existingUserVersion)
    }

    private func createMetadataSchema() throws {
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
    }

    private func createCommitSchema() throws {
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
                embedding BLOB,
                consolidation_state TEXT NOT NULL DEFAULT 'raw'
            )
            """
        )
        let hasConsolidationColumn = try queryInt64(
            """
            SELECT COUNT(*) FROM pragma_table_info('history_commits')
            WHERE name = 'consolidation_state'
            """
        )
        if hasConsolidationColumn == 0 {
            // v1 databases predate the language-profile pipeline; every
            // existing row starts as raw material for consolidation.
            try execute(
                """
                ALTER TABLE history_commits
                ADD COLUMN consolidation_state TEXT NOT NULL DEFAULT 'raw'
                """
            )
        }
        try execute(
            """
            CREATE INDEX IF NOT EXISTS history_commits_time
            ON history_commits(committed_at_ms)
            """
        )
    }

    private func createDerivedSchema(
        existingUserVersion: Int64
    ) throws {
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
        try execute(
            """
            CREATE TABLE IF NOT EXISTS consolidation_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                statistics_watermark INTEGER NOT NULL DEFAULT 0,
                semantic_watermark INTEGER NOT NULL DEFAULT 0,
                updated_at_ms INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        try execute(
            "INSERT OR IGNORE INTO consolidation_state(id) VALUES (1)"
        )
        try createFullTextSchema()
        try execute(
            """
            CREATE TABLE IF NOT EXISTS history_metrics (
                key TEXT PRIMARY KEY NOT NULL,
                value INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        if existingUserVersion < 2 {
            try execute("PRAGMA user_version=2")
        }
    }

    private func createFullTextSchema() throws {
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
    }
}
