import Foundation
import SQLite3

/// One installed domain lexicon (schema v2 asset row).
public struct DomainLexicon: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let domain: String
    public let version: String
    public let entryCount: Int
    public let isEnabled: Bool
    public let license: String
    public let attribution: String
    public let installedAt: Date

    public init(
        id: String,
        name: String,
        domain: String,
        version: String,
        entryCount: Int,
        isEnabled: Bool,
        license: String,
        attribution: String,
        installedAt: Date
    ) {
        self.id = id
        self.name = name
        self.domain = domain
        self.version = version
        self.entryCount = entryCount
        self.isEnabled = isEnabled
        self.license = license
        self.attribution = attribution
        self.installedAt = installedAt
    }
}

/// One pronunciation row of a lexicon entry (homographs span rows).
public struct DomainLexiconEntry: Equatable, Sendable, Identifiable {
    public let lexiconId: String
    public let text: String
    public let pinyinKeys: String
    public let weight: Int
    public let isBlocked: Bool

    public var id: String { "\(lexiconId)\u{1F}\(text)\u{1F}\(pinyinKeys)" }

    public init(
        lexiconId: String,
        text: String,
        pinyinKeys: String,
        weight: Int,
        isBlocked: Bool
    ) {
        self.lexiconId = lexiconId
        self.text = text
        self.pinyinKeys = pinyinKeys
        self.weight = weight
        self.isBlocked = isBlocked
    }
}

/// Result of one import: what landed, what was rejected, and whether an
/// existing lexicon was replaced.
public struct LexiconInstallResult: Equatable, Sendable {
    public let lexicon: DomainLexicon
    public let insertedEntries: Int
    public let rejectedLineCount: Int
    public let rejectedLines: [(line: Int, reason: String)]
    public let replacedPrevious: Bool

    public init(
        lexicon: DomainLexicon,
        insertedEntries: Int,
        rejectedLineCount: Int,
        rejectedLines: [(line: Int, reason: String)],
        replacedPrevious: Bool
    ) {
        self.lexicon = lexicon
        self.insertedEntries = insertedEntries
        self.rejectedLineCount = rejectedLineCount
        self.rejectedLines = rejectedLines
        self.replacedPrevious = replacedPrevious
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.lexicon == rhs.lexicon
            && lhs.insertedEntries == rhs.insertedEntries
            && lhs.rejectedLineCount == rhs.rejectedLineCount
    }
}

public enum DomainLexiconError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidDomain
    case emptyDictionary
    case lexiconNotFound(String)
    case sqlite(code: Int32, message: String)
    case fileSystem(String)
}

/// Asset-side store for domain lexicons: install / replace, enable /
/// disable, uninstall, entry curation (block / unblock, cross-reading),
/// and the snapshot-facing query used for candidate fusion.
///
/// Mirrors the `PhraseBookStore` layout: one serialized queue, one
/// SQLite connection against the same database file. DDL is shared via
/// `LexiconSchema`; this store never touches `user_version` (the
/// phrasebook store owns the schema version).
public final class DomainLexiconStore: @unchecked Sendable {
    public static let maximumEntriesPerLexicon =
        RimeDictYamlParser.maximumEntries

    public let databaseURL: URL

    let queue = DispatchQueue(
        label: "fun.wwcn.rimeai.domain-lexicon-store"
    )
    private let fileManager: FileManager
    var database: OpaquePointer?

    public init(
        databaseURL: URL,
        fileManager: FileManager = .default
    ) throws {
        self.databaseURL = databaseURL
        self.fileManager = fileManager

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
            } ?? "could not open lexicon database"
            if let opened {
                sqlite3_close_v2(opened)
            }
            throw DomainLexiconError.sqlite(code: status, message: message)
        }
        database = opened

        do {
            try configureDatabase()
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

    // MARK: - Install / replace

    /// Installs (or replaces, same id) a parsed Rime dictionary into the
    /// given domain. Replacement drops the previous rows wholesale —
    /// lexicons are regenerable assets — so blocked flags do not
    /// survive a reinstall.
    @discardableResult
    public func install(
        _ dictionary: ParsedRimeDictionary,
        domain: String = PhraseBookDomain.global,
        license: String = "",
        attribution: String = ""
    ) throws -> LexiconInstallResult {
        let identifier = dictionary.identifier
        guard !identifier.isEmpty else {
            throw DomainLexiconError.invalidIdentifier
        }
        guard dictionary.entries.count <= Self.maximumEntriesPerLexicon
        else {
            throw DomainLexiconError.emptyDictionary
        }
        let resolvedDomain: String
        do {
            resolvedDomain = try PhraseBookStoreProxy
                .normalizedDomain(domain)
        } catch {
            throw DomainLexiconError.invalidDomain
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        return try queue.sync {
            var replaced = false
            try transaction {
                replaced = try lexiconExists(identifier)
                try run(
                    "DELETE FROM lexicon_entries WHERE lexicon_id = ?",
                    [identifier]
                )
                try run("DELETE FROM lexicons WHERE id = ?", [identifier])
                try run(
                    """
                    INSERT INTO lexicons(
                        id, name, domain, version, entry_count,
                        enabled, license, attribution, installed_at_ms
                    ) VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)
                    """,
                    [
                        identifier,
                        dictionary.name.isEmpty ? identifier : dictionary.name,
                        resolvedDomain,
                        dictionary.version,
                        String(dictionary.entries.count),
                        license,
                        attribution,
                        String(nowMs),
                    ]
                )
                for entry in dictionary.entries {
                    try run(
                        """
                        INSERT INTO lexicon_entries(
                            lexicon_id, text, pinyin_keys, weight, blocked
                        ) VALUES (?, ?, ?, ?, 0)
                        """,
                        [
                            identifier,
                            entry.text,
                            entry.pinyinKeys,
                            String(entry.weight),
                        ]
                    )
                }
            }
            guard let lexicon = try readLexiconLocked(id: identifier) else {
                throw DomainLexiconError.sqlite(
                    code: SQLITE_CORRUPT,
                    message: "installed lexicon missing after insert"
                )
            }
            return LexiconInstallResult(
                lexicon: lexicon,
                insertedEntries: dictionary.entries.count,
                rejectedLineCount: dictionary.rejectedLineCount,
                rejectedLines: dictionary.rejectedLines,
                replacedPrevious: replaced
            )
        }
    }

    /// Convenience: parse + install in one step.
    @discardableResult
    public func installDictYaml(
        _ source: String,
        domain: String = PhraseBookDomain.global,
        license: String = "",
        attribution: String = ""
    ) throws -> LexiconInstallResult {
        let dictionary: ParsedRimeDictionary
        do {
            dictionary = try RimeDictYamlParser.parse(source)
        } catch RimeDictYamlParser.ParseError.emptyDocument {
            throw DomainLexiconError.emptyDictionary
        }
        return try install(
            dictionary,
            domain: domain,
            license: license,
            attribution: attribution
        )
    }

    // MARK: - Lifecycle

    @discardableResult
    public func setEnabled(
        id: String,
        isEnabled: Bool
    ) throws -> Bool {
        try queue.sync {
            try run(
                "UPDATE lexicons SET enabled = ? WHERE id = ?",
                [isEnabled ? "1" : "0", id]
            )
            return changes() > 0
        }
    }

    /// Uninstall drops the lexicon row and its entries. Returns false
    /// when the id was unknown.
    @discardableResult
    public func uninstall(id: String) throws -> Bool {
        try queue.sync {
            var removed = false
            try transaction {
                try run(
                    "DELETE FROM lexicon_entries WHERE lexicon_id = ?",
                    [id]
                )
                try run("DELETE FROM lexicons WHERE id = ?", [id])
                removed = changes() > 0
            }
            return removed
        }
    }

    public func lexicons() throws -> [DomainLexicon] {
        try queue.sync {
            let statement = try prepare(
                """
                SELECT id, name, domain, version, entry_count,
                       enabled, license, attribution, installed_at_ms
                FROM lexicons
                ORDER BY id
                """
            )
            defer { sqlite3_finalize(statement) }
            var values: [DomainLexicon] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append(
                    DomainLexicon(
                        id: columnText(statement, index: 0),
                        name: columnText(statement, index: 1),
                        domain: columnText(statement, index: 2),
                        version: columnText(statement, index: 3),
                        entryCount: Int(
                            sqlite3_column_int64(statement, 4)
                        ),
                        isEnabled: sqlite3_column_int64(statement, 5)
                            != 0,
                        license: columnText(statement, index: 6),
                        attribution: columnText(statement, index: 7),
                        installedAt: Date(
                            timeIntervalSince1970:
                                Double(
                                    sqlite3_column_int64(statement, 8)
                                )
                                / 1_000
                        )
                    )
                )
            }
            return values
        }
    }

    // MARK: - Entry curation

    /// Lists entries of one lexicon (blocked rows included; the UI and
    /// the fusion query filter by `isBlocked`).
    public func entries(
        lexiconId: String,
        limit: Int = 500
    ) throws -> [DomainLexiconEntry] {
        guard limit > 0 else {
            return []
        }
        return try queue.sync {
            let statement = try prepare(
                """
                SELECT text, pinyin_keys, weight, blocked
                FROM lexicon_entries
                WHERE lexicon_id = ?
                ORDER BY weight DESC, text
                LIMIT ?
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(lexiconId, to: statement, index: 1)
            sqlite3_bind_int(statement, 2, Int32(limit))
            var values: [DomainLexiconEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append(
                    DomainLexiconEntry(
                        lexiconId: lexiconId,
                        text: columnText(statement, index: 0),
                        pinyinKeys: columnText(statement, index: 1),
                        weight: Int(
                            sqlite3_column_int64(statement, 2)
                        ),
                        isBlocked: sqlite3_column_int64(statement, 3)
                            != 0
                    )
                )
            }
            return values
        }
    }

    /// Blocks (or unblocks) every pronunciation of one text in one
    /// lexicon — the cross-reading semantics promised by the design
    /// doc. Returns the number of affected rows.
    @discardableResult
    public func setEntryBlocked(
        lexiconId: String,
        text: String,
        isBlocked: Bool
    ) throws -> Int {
        try queue.sync {
            try run(
                """
                UPDATE lexicon_entries
                SET blocked = ?
                WHERE lexicon_id = ? AND text = ?
                """,
                [isBlocked ? "1" : "0", lexiconId, text]
            )
            return changes()
        }
    }

    // MARK: - Fusion source

    /// All entries of enabled lexicons (all mounted domains,
    /// unblocked), wrapped as `PhraseBookEntry` rows for the candidate
    /// snapshot. Domain filtering happens at query time, mirroring the
    /// learned-entries snapshot (caller's domain or `global`).
    public func snapshotEntries(
        limit: Int
    ) throws -> [PhraseBookEntry] {
        guard limit > 0 else {
            return []
        }
        return try queue.sync {
            let statement = try prepare(
                """
                SELECT e.text, e.pinyin_keys, e.weight, l.domain
                FROM lexicon_entries AS e
                JOIN lexicons AS l ON l.id = e.lexicon_id
                WHERE l.enabled = 1
                  AND e.blocked = 0
                ORDER BY e.weight DESC
                LIMIT ?
                """
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))
            var values: [PhraseBookEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append(
                    PhraseBookEntry(
                        id: "lexicon:\(columnText(statement, index: 3))"
                            + ":\(columnText(statement, index: 0))"
                            + ":\(columnText(statement, index: 1))",
                        domain: columnText(statement, index: 3),
                        text: columnText(statement, index: 0),
                        pinyinKeys: columnText(statement, index: 1),
                        count: Int(sqlite3_column_int64(statement, 2)),
                        firstSeenAt: .distantPast,
                        lastUsedAt: .distantPast,
                        source: .lexicon,
                        isProtected: false
                    )
                )
            }
            return values
        }
    }

    /// Moves every lexicon mounted on `source` to `target`. Called by
    /// the phrasebook domain rename path so lexicons follow their
    /// domain. Returns moved lexicon count.
    func migrateDomain(from source: String, to target: String) throws -> Int {
        try queue.sync {
            try run(
                "UPDATE lexicons SET domain = ? WHERE domain = ?",
                [target, source]
            )
            return changes()
        }
    }

    // MARK: - Internals

    private func configureDatabase() throws {
        for ddl in LexiconSchema.install() {
            try execute(ddl)
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA busy_timeout=1000")
        try execute("PRAGMA secure_delete=ON")
    }

    private func lexiconExists(_ id: String) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM lexicons WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, index: 1)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Queue-held variant of `readLexicon`: identical SQL, but no
    /// `queue.sync` — only call while already holding the store queue,
    /// otherwise the nested sync deadlocks the serial queue.
    private func readLexiconLocked(id: String) throws -> DomainLexicon? {
        let statement = try prepare(
            """
            SELECT id, name, domain, version, entry_count,
                   enabled, license, attribution, installed_at_ms
            FROM lexicons
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return DomainLexicon(
            id: columnText(statement, index: 0),
            name: columnText(statement, index: 1),
            domain: columnText(statement, index: 2),
            version: columnText(statement, index: 3),
            entryCount: Int(sqlite3_column_int64(statement, 4)),
            isEnabled: sqlite3_column_int64(statement, 5) != 0,
            license: columnText(statement, index: 6),
            attribution: columnText(statement, index: 7),
            installedAt: Date(
                timeIntervalSince1970:
                    Double(sqlite3_column_int64(statement, 8)) / 1_000
            )
        )
    }

    private func changes() -> Int {
        guard let database else { return 0 }
        return Int(sqlite3_changes(database))
    }
}

/// The domain validator lives on `PhraseBookStore` (single source of
/// truth for domain rules). This tiny proxy keeps
/// `DomainLexiconStore.install` readable without widening store
/// visibility.
enum PhraseBookStoreProxy {
    static func normalizedDomain(_ raw: String) throws -> String {
        try PhraseBookDomain.normalize(raw)
    }
}
