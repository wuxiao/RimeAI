import Foundation
import SQLite3

public enum PhraseEntrySource: String, Codable, Sendable {
    case auto
    case user
    case llm
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
}

/// L1 phrasebook storage shared by the input method (candidate lookup and
/// the settings page) and the Python consolidation loop (frequency updates).
/// All Swift access is serialized through one queue; concurrent writers
/// from the daemon are handled by SQLite's busy timeout.
public final class PhraseBookStore: @unchecked Sendable {
    public static let schemaVersion = 1

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
            sql += """
                 ORDER BY count DESC, last_used_ms DESC
                LIMIT \(max(0, limit))
                """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            if let domain {
                try bind(try normalizedDomain(domain), to: statement, index: 1)
            }
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
    }
}
