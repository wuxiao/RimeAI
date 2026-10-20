import Foundation
import SQLite3

public enum PhraseEntrySource: String, Codable, Sendable {
    case auto
    case user
    case llm
    /// 查询侧包装：词库命中从不写入 `phrasebook_entries`，只在融合
    /// 查询里以 `PhraseBookEntry` 形态返回给既有 pipeline。
    case lexicon
}

/// One learned (or user-curated) phrase in the L1 phrasebook. `pinyinKeys`
/// mirrors `HistoryCommit.pinyin`: the concatenated letter segments of the
/// commit, without punctuation.
public struct PhraseBookEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let domain: String
    public let text: String
    public let pinyinKeys: String
    public let count: Int
    public let firstSeenAt: Date
    public let lastUsedAt: Date
    public let source: PhraseEntrySource
    public let isProtected: Bool

    public init(
        id: String,
        domain: String,
        text: String,
        pinyinKeys: String,
        count: Int,
        firstSeenAt: Date,
        lastUsedAt: Date,
        source: PhraseEntrySource,
        isProtected: Bool
    ) {
        self.id = id
        self.domain = domain
        self.text = text
        self.pinyinKeys = pinyinKeys
        self.count = count
        self.firstSeenAt = firstSeenAt
        self.lastUsedAt = lastUsedAt
        self.source = source
        self.isProtected = isProtected
    }
}

public struct PhraseBookStatistics: Equatable, Sendable {
    public let entryCount: Int
    public let protectedCount: Int
    public let domains: [String]
    public let generation: Int64
}

public struct PhraseDomainMapping: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let domain: String

    public init(bundleIdentifier: String, domain: String) {
        self.bundleIdentifier = bundleIdentifier
        self.domain = domain
    }
}

public enum PhraseBookError: Error, Equatable, Sendable {
    case invalidPhrase
    case invalidDomain
    case sqlite(code: Int32, message: String)
    case fileSystem(String)
}

public enum PhraseBookDomain {
    public static let global = "global"
    public static let maximumNameLength = 64

    /// Single source of truth for domain-name rules, shared by the
    /// phrasebook store, the lexicon store, the settings UI, the daemon
    /// request validator and the broker profile store: trimmed,
    /// lowercased, `[a-z0-9-]`, at most 64 characters. Empty input is
    /// not a domain; callers that accept "no domain" use `normalize`.
    public static func validate(
        _ raw: String
    ) throws -> String {
        let domain = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !domain.isEmpty,
              domain.count <= PhraseBookDomain.maximumNameLength,
              domain.allSatisfy(\.isLowercaseLetterOrDigitOrHyphen)
        else {
            throw PhraseBookError.invalidDomain
        }
        return domain
    }

    /// Normalizes a domain name for storage; empty input resolves to
    /// `global`, anything else must satisfy `validate`.
    public static func normalize(
        _ raw: String
    ) throws -> String {
        let domain = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !domain.isEmpty else {
            return PhraseBookDomain.global
        }
        return try PhraseBookDomain.validate(domain)
    }
}

/// L1 phrasebook storage shared by the input method (candidate lookup and
/// the settings page) and the Python consolidation loop (frequency updates).
/// All Swift access is serialized through one queue; concurrent writers
/// from the daemon are handled by SQLite's busy timeout.
public final class PhraseBookStore: @unchecked Sendable {
    /// v2：新增领域词库表（`lexicons` / `lexicon_entries`，见
    /// `LexiconSchema`）。学习表结构不变。
    public static let schemaVersion = 2

    public let databaseURL: URL

    let queue = DispatchQueue(
        label: "fun.wwcn.rimeai.phrasebook-store"
    )
    private let fileManager: FileManager
    var database: OpaquePointer?

    public init(
        databaseURL: URL,
        fileManager: FileManager = .default
    ) throws {
        self.databaseURL = databaseURL
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
            throw PhraseBookError.fileSystem(error.localizedDescription)
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
            } ?? "could not open phrasebook database"
            if let opened {
                sqlite3_close_v2(opened)
            }
            throw PhraseBookError.sqlite(code: status, message: message)
        }
        database = opened

        do {
            try configureDatabase()
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: databaseURL.path
            )
            // Repair legacy domain names once, at open time: rows written
            // when `_` was still an accepted domain character would
            // otherwise stay unreachable under the dead name.
            try? migrateLegacyDomainNames()
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

    // MARK: - Phrase queries

    /// Candidate-injection lookup: exact-then-prefix pinyin matches in the
    /// caller's domain first, then the global domain.
    public func phrases(
        matchingPinyin query: String,
        domain: String = PhraseBookDomain.global,
        limit: Int = 5
    ) throws -> [PhraseBookEntry] {
        let trimmed = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard !trimmed.isEmpty, limit > 0 else {
            return []
        }
        return try queue.sync {
            let resolved = try normalizedDomain(domain)
            // LIKE wildcards in the query must be literal: pinyin keys
            // are [a-z'] from the composition path, but the API is
            // public, so %/_ are escaped and matched verbatim.
            let escaped = trimmed
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let statement = try prepare(
                """
                SELECT id, domain, text, pinyin_keys, count,
                       first_seen_ms, last_used_ms, source, protected
                FROM phrasebook_entries
                WHERE (domain = ? OR domain = ?)
                  AND (pinyin_keys = ? OR pinyin_keys LIKE ? ESCAPE '\\')
                ORDER BY (pinyin_keys = ?) DESC,
                         (domain = ?) DESC,
                         count DESC,
                         last_used_ms DESC
                LIMIT ?
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(resolved, to: statement, index: 1)
            try bind(PhraseBookDomain.global, to: statement, index: 2)
            try bind(trimmed, to: statement, index: 3)
            try bind("\(escaped)%", to: statement, index: 4)
            try bind(trimmed, to: statement, index: 5)
            try bind(resolved, to: statement, index: 6)
            sqlite3_bind_int(statement, 7, Int32(limit))
            return try readEntries(statement)
        }
    }

    /// Settings-page listing, optionally filtered by domain.
    public func entries(
        domain: String? = nil,
        limit: Int = 500
    ) throws -> [PhraseBookEntry] {
        try queue.sync {
            var sql = """
                SELECT id, domain, text, pinyin_keys, count,
                       first_seen_ms, last_used_ms, source, protected
                FROM phrasebook_entries
                """
            if domain != nil {
                sql += " WHERE domain = ?"
            }
            // LIMIT is bound, never interpolated (P2-12); the dynamic
            // fragment above is a fixed literal chosen by `domain != nil`.
            sql += """
                 ORDER BY count DESC, last_used_ms DESC
                LIMIT ?
                """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            var index: Int32 = 1
            if let domain {
                try bind(try normalizedDomain(domain), to: statement, index: index)
                index += 1
            }
            sqlite3_bind_int64(statement, index, Int64(max(0, limit)))
            return try readEntries(statement)
        }
    }

    /// Total number of learning entries. Used by the export to report
    /// whether the export cap truncated the payload.
    public func entryCount() throws -> Int {
        try queue.sync {
            Int(
                try queryInt64(
                    "SELECT COUNT(*) FROM phrasebook_entries"
                )
            )
        }
    }

    /// Typing-path snapshot (P2-13): protected and user-added entries are
    /// pinned ahead of the frequency ordering so the snapshot cap can
    /// never cut them, no matter how long the auto-learned tail grows.
    public func snapshotEntries(limit: Int) throws -> [PhraseBookEntry] {
        try queue.sync {
            let statement = try prepare(
                """
                SELECT id, domain, text, pinyin_keys, count,
                       first_seen_ms, last_used_ms, source, protected
                FROM phrasebook_entries
                ORDER BY (protected = 1 OR source = 'user') DESC,
                         count DESC, last_used_ms DESC
                LIMIT ?
                """
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(max(0, limit)))
            return try readEntries(statement)
        }
    }

    /// Personalized ASCII tokens for the mixed-composition resolver
    /// (LP-006): pure lowercase-ASCII phrases across all domains, most
    /// frequent first. Replaces the legacy 256-entry personal English
    /// word list.
    public func englishTokens(limit: Int = 512) throws -> [String] {
        guard limit > 0 else {
            return []
        }
        return try queue.sync {
            let statement = try prepare(
                """
                SELECT DISTINCT text FROM phrasebook_entries
                WHERE text GLOB '[a-z][a-z0-9]*'
                ORDER BY count DESC, last_used_ms DESC
                LIMIT ?
                """
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))
            var tokens: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                tokens.append(columnText(statement, index: 0))
            }
            return tokens
        }
    }

    // MARK: - Schema

    private func configureDatabase() throws {
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA secure_delete=ON")
        try execute("PRAGMA busy_timeout=1000")
        try execute("PRAGMA user_version=\(Self.schemaVersion)")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS phrasebook_metadata (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                generation INTEGER NOT NULL
            )
            """
        )
        try execute(
            """
            INSERT OR IGNORE INTO phrasebook_metadata(id, generation)
            VALUES (1, 0)
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS phrasebook_entries (
                id TEXT PRIMARY KEY NOT NULL,
                domain TEXT NOT NULL,
                text TEXT NOT NULL,
                pinyin_keys TEXT NOT NULL,
                count INTEGER NOT NULL,
                first_seen_ms INTEGER NOT NULL,
                last_used_ms INTEGER NOT NULL,
                source TEXT NOT NULL,
                protected INTEGER NOT NULL DEFAULT 0,
                UNIQUE(domain, text)
            )
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS phrasebook_entries_domain_pinyin
            ON phrasebook_entries(domain, pinyin_keys)
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS domain_map (
                bundle_id TEXT PRIMARY KEY NOT NULL,
                domain TEXT NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS domain_stats (
                domain TEXT PRIMARY KEY NOT NULL,
                commit_count INTEGER NOT NULL DEFAULT 0,
                updated_at_ms INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        // Schema v2: domain-lexicon asset tables (shared DDL with
        // `DomainLexiconStore`; every statement is idempotent).
        for ddl in LexiconSchema.install() {
            try execute(ddl)
        }
        try repairEntryIdentifiers()
    }

    /// Re-assigns content-addressed ids for rows whose id drifted from
    /// sha256(domain \u{1F} text) — pre-fix domain renames moved rows
    /// without recomputing ids, which later caused primary-key collisions
    /// when a recreated domain relearned the same text. Idempotent.
    private func repairEntryIdentifiers() throws {
        let statement = try prepare(
            "SELECT id, domain, text FROM phrasebook_entries"
        )
        var stale: [(oldId: String, domain: String, text: String)] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                sqlite3_finalize(statement)
                throw currentSQLiteError(code: status)
            }
            let id = columnText(statement, index: 0)
            let domain = columnText(statement, index: 1)
            let text = columnText(statement, index: 2)
            if id != Self.entryIdentifier(domain: domain, text: text) {
                stale.append((id, domain, text))
            }
        }
        sqlite3_finalize(statement)
        guard !stale.isEmpty else { return }
        try transaction {
            for row in stale {
                try run(
                    "UPDATE phrasebook_entries SET id = ? WHERE id = ?",
                    [
                        Self.entryIdentifier(
                            domain: row.domain,
                            text: row.text
                        ),
                        row.oldId,
                    ]
                )
            }
        }
    }
}
