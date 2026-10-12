import CryptoKit
import Foundation
import SQLite3

/// Phrase mutation APIs for the settings page (user curation) and the
/// Python consolidation loop (auto-learned frequency updates).
extension PhraseBookStore {
    /// Adds or reinforces a user-curated phrase (protected, `source=user`).
    @discardableResult
    public func addUserPhrase(
        text: String,
        pinyinKeys: String,
        domain: String = PhraseBookDomain.global
    ) throws -> PhraseBookEntry {
        try upsertPhrase(
            text: text,
            pinyinKeys: pinyinKeys,
            domain: domain,
            source: .user,
            protected: true
        )
    }

    /// Python consolidation uses this write path for auto-learned phrases.
    public func recordAutoPhrase(
        text: String,
        pinyinKeys: String,
        domain: String,
        at timestamp: Date = Date()
    ) throws {
        _ = try upsertPhrase(
            text: text,
            pinyinKeys: pinyinKeys,
            domain: domain,
            source: .auto,
            protected: false,
            usedAt: timestamp
        )
    }

    /// Idempotently adopts the legacy 256 personal English tokens as
    /// protected user phrases. Returns how many were newly inserted.
    @discardableResult
    public func adoptUserTokens(
        _ tokens: Set<String>,
        domain: String = PhraseBookDomain.global
    ) throws -> Int {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let resolved = try normalizedDomain(domain)
        return try queue.sync {
            var inserted = 0
            try transaction {
                for token in tokens.sorted() {
                    let trimmed = token.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).lowercased()
                    guard !trimmed.isEmpty,
                          trimmed.utf8.count <= 256
                    else {
                        continue
                    }
                    let statement = try prepare(
                        """
                        INSERT INTO phrasebook_entries(
                            id, domain, text, pinyin_keys, count,
                            first_seen_ms, last_used_ms, source, protected
                        ) VALUES (?, ?, ?, ?, 1, ?, ?, 'user', 1)
                        ON CONFLICT(domain, text) DO NOTHING
                        """
                    )
                    defer { sqlite3_finalize(statement) }
                    try bind(
                        Self.entryIdentifier(
                            domain: resolved,
                            text: trimmed
                        ),
                        to: statement,
                        index: 1
                    )
                    try bind(resolved, to: statement, index: 2)
                    try bind(trimmed, to: statement, index: 3)
                    try bind(trimmed, to: statement, index: 4)
                    sqlite3_bind_int64(statement, 5, nowMs)
                    sqlite3_bind_int64(statement, 6, nowMs)
                    try stepDone(statement)
                    if let database, sqlite3_changes(database) > 0 {
                        inserted += 1
                    }
                }
            }
            return inserted
        }
    }

    @discardableResult
    public func setProtected(
        id: String,
        isProtected: Bool
    ) throws -> Bool {
        try queue.sync {
            let statement = try prepare(
                "UPDATE phrasebook_entries SET protected = ? WHERE id = ?"
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, isProtected ? 1 : 0)
            try bind(id, to: statement, index: 2)
            try stepDone(statement)
            guard let database else { return false }
            return sqlite3_changes(database) > 0
        }
    }

    @discardableResult
    public func delete(id: String) throws -> Bool {
        try queue.sync {
            let statement = try prepare(
                "DELETE FROM phrasebook_entries WHERE id = ?"
            )
            defer { sqlite3_finalize(statement) }
            try bind(id, to: statement, index: 1)
            try stepDone(statement)
            guard let database else { return false }
            return sqlite3_changes(database) > 0
        }
    }

    // MARK: - Internals

    private func upsertPhrase(
        text rawText: String,
        pinyinKeys rawPinyin: String,
        domain rawDomain: String,
        source: PhraseEntrySource,
        protected: Bool,
        usedAt: Date = Date()
    ) throws -> PhraseBookEntry {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinyin = rawPinyin.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        let domain = try normalizedDomain(rawDomain)
        guard !text.isEmpty,
              text.utf8.count <= 1_024,
              !text.contains("\u{0000}"),
              pinyin.utf8.count <= 256
        else {
            throw PhraseBookError.invalidPhrase
        }
        let identifier = Self.entryIdentifier(domain: domain, text: text)
        let nowMs = Int64(usedAt.timeIntervalSince1970 * 1_000)
        return try queue.sync {
            try transaction {
                let statement = try prepare(
                    """
                    INSERT INTO phrasebook_entries(
                        id, domain, text, pinyin_keys, count,
                        first_seen_ms, last_used_ms, source, protected
                    ) VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?)
                    ON CONFLICT(domain, text) DO UPDATE SET
                        count = count + 1,
                        last_used_ms = excluded.last_used_ms,
                        protected = MAX(protected, excluded.protected)
                    """
                )
                defer { sqlite3_finalize(statement) }
                try bind(identifier, to: statement, index: 1)
                try bind(domain, to: statement, index: 2)
                try bind(text, to: statement, index: 3)
                try bind(pinyin, to: statement, index: 4)
                sqlite3_bind_int64(statement, 5, nowMs)
                sqlite3_bind_int64(statement, 6, nowMs)
                try bind(source.rawValue, to: statement, index: 7)
                sqlite3_bind_int(statement, 8, protected ? 1 : 0)
                try stepDone(statement)
            }
            // Reinforced rows must report the stored row (real count,
            // first-seen timestamp and possibly upgraded protection),
            // not the insert-time snapshot.
            let read = try prepare(
                """
                SELECT id, domain, text, pinyin_keys, count,
                       first_seen_ms, last_used_ms, source, protected
                FROM phrasebook_entries
                WHERE domain = ? AND text = ?
                """
            )
            defer { sqlite3_finalize(read) }
            try bind(domain, to: read, index: 1)
            try bind(text, to: read, index: 2)
            let entries = try readEntries(read)
            guard let entry = entries.first else {
                throw PhraseBookError.invalidPhrase
            }
            return entry
        }
    }

    /// Content-addressed identifier: stable SHA-256 of domain + separator
    /// + text, so Python and Swift derive identical ids for one phrase.
    static func entryIdentifier(domain: String, text: String) -> String {
        let payload = Data("\(domain)\u{1F}\(text)".utf8)
        return SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func readEntries(
        _ statement: OpaquePointer
    ) throws -> [PhraseBookEntry] {
        var values: [PhraseBookEntry] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                break
            }
            guard status == SQLITE_ROW else {
                throw currentSQLiteError(code: status)
            }
            guard let source = PhraseEntrySource(
                rawValue: columnText(statement, index: 7)
            ) else {
                continue
            }
            values.append(
                PhraseBookEntry(
                    id: columnText(statement, index: 0),
                    domain: columnText(statement, index: 1),
                    text: columnText(statement, index: 2),
                    pinyinKeys: columnText(statement, index: 3),
                    count: Int(sqlite3_column_int64(statement, 4)),
                    firstSeenAt: Date(
                        timeIntervalSince1970:
                            Double(sqlite3_column_int64(statement, 5))
                            / 1_000
                    ),
                    lastUsedAt: Date(
                        timeIntervalSince1970:
                            Double(sqlite3_column_int64(statement, 6))
                            / 1_000
                    ),
                    source: source,
                    isProtected: sqlite3_column_int(statement, 8) != 0
                )
            )
        }
        return values
    }
}
