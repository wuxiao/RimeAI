import Foundation
import SQLite3

/// Domain mapping (LP-007) plus store-level statistics, export and
/// clear. Unmapped bundles always resolve to `global`; the cold-start
/// rule (a domain only earns its own artifacts past a commit-count
/// threshold) is enforced by the Python consolidation loop, which owns
/// the `domain_stats` counters.
extension PhraseBookStore {

    /// Resolves the effective domain for a bundle identifier.
    public func domain(
        for bundleIdentifier: String
    ) throws -> String {
        let bundle = bundleIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !bundle.isEmpty else {
            return PhraseBookDomain.global
        }
        return try queue.sync {
            let statement = try prepare(
                "SELECT domain FROM domain_map WHERE bundle_id = ?"
            )
            defer { sqlite3_finalize(statement) }
            try bind(bundle, to: statement, index: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return PhraseBookDomain.global
            }
            return columnText(statement, index: 0)
        }
    }

    @discardableResult
    public func setDomainMapping(
        bundleIdentifier: String,
        domain rawDomain: String
    ) throws -> Bool {
        let bundle = bundleIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let domain = try validatedDomain(rawDomain)
        guard !bundle.isEmpty else {
            throw PhraseBookError.invalidDomain
        }
        return try queue.sync {
            try transaction {
                let statement = try prepare(
                    """
                    INSERT INTO domain_map(bundle_id, domain)
                    VALUES (?, ?)
                    ON CONFLICT(bundle_id) DO UPDATE SET domain = excluded.domain
                    """
                )
                defer { sqlite3_finalize(statement) }
                try bind(bundle, to: statement, index: 1)
                try bind(domain, to: statement, index: 2)
                try stepDone(statement)
            }
            return true
        }
    }

    @discardableResult
    public func removeDomainMapping(
        bundleIdentifier: String
    ) throws -> Bool {
        try queue.sync {
            let statement = try prepare(
                "DELETE FROM domain_map WHERE bundle_id = ?"
            )
            defer { sqlite3_finalize(statement) }
            try bind(bundleIdentifier, to: statement, index: 1)
            try stepDone(statement)
            guard let database else { return false }
            return sqlite3_changes(database) > 0
        }
    }

    public func domainMappings() throws -> [PhraseDomainMapping] {
        try queue.sync {
            let statement = try prepare(
                "SELECT bundle_id, domain FROM domain_map ORDER BY bundle_id"
            )
            defer { sqlite3_finalize(statement) }
            var values: [PhraseDomainMapping] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append(
                    PhraseDomainMapping(
                        bundleIdentifier: columnText(statement, index: 0),
                        domain: columnText(statement, index: 1)
                    )
                )
            }
            return values
        }
    }

    /// Renames (or merges) a domain; affected phrase rows move to the
    /// target domain and mappings follow. Returns moved phrase count.
    @discardableResult
    public func renameDomain(
        from source: String,
        to target: String
    ) throws -> Int {
        let sourceDomain = try validatedDomain(source)
        let targetDomain = try validatedDomain(target)
        guard sourceDomain != targetDomain else {
            return 0
        }
        return try queue.sync {
            var moved = 0
            try transaction {
                try run(
                    """
                    UPDATE phrasebook_entries AS src
                    SET domain = ?
                    WHERE src.domain = ?
                      AND NOT EXISTS (
                          SELECT 1 FROM phrasebook_entries AS dst
                          WHERE dst.domain = ?
                            AND dst.text = src.text
                      )
                    """,
                    [targetDomain, sourceDomain, targetDomain]
                )
                if let database {
                    moved = Int(sqlite3_changes(database))
                }
                // Remaining rows collided with existing target phrases:
                // fold their counts into the winners, then drop them.
                try run(
                    """
                    UPDATE phrasebook_entries
                    SET count = count + (
                        SELECT IFNULL(SUM(count), 0)
                        FROM phrasebook_entries AS loser
                        WHERE loser.domain = ?
                          AND loser.text = phrasebook_entries.text
                    )
                    WHERE domain = ?
                    """,
                    [sourceDomain, targetDomain]
                )
                try run(
                    "DELETE FROM phrasebook_entries WHERE domain = ?",
                    [sourceDomain]
                )
                try run(
                    """
                    UPDATE domain_map
                    SET domain = ?
                    WHERE domain = ?
                    """,
                    [targetDomain, sourceDomain]
                )
                try run(
                    """
                    INSERT INTO domain_stats(domain, commit_count, updated_at_ms)
                    VALUES (
                        ?,
                        (
                            SELECT IFNULL(SUM(commit_count), 0)
                            FROM domain_stats
                            WHERE domain IN (?, ?)
                        ),
                        CAST(strftime('%s', 'now') AS INT) * 1000
                    )
                    ON CONFLICT(domain) DO UPDATE SET
                        commit_count = excluded.commit_count,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                    [targetDomain, sourceDomain, targetDomain]
                )
                try run(
                    "DELETE FROM domain_stats WHERE domain = ?",
                    [sourceDomain]
                )
            }
            return moved
        }
    }

    /// Deletes a domain: phrases fold back into `global` (counts merged),
    /// mappings reset to `global`. Returns folded phrase count.
    @discardableResult
    public func deleteDomain(_ source: String) throws -> Int {
        try renameDomain(
            from: source,
            to: PhraseBookDomain.global
        )
    }

    public func statistics() throws -> PhraseBookStatistics {
        try queue.sync {
            let domains: [String] = {
                let statement = try? prepare(
                    "SELECT DISTINCT domain FROM phrasebook_entries ORDER BY domain"
                )
                guard let statement else { return [] }
                defer { sqlite3_finalize(statement) }
                var names: [String] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    names.append(columnText(statement, index: 0))
                }
                return names
            }()
            return PhraseBookStatistics(
                entryCount: Int(
                    try queryInt64(
                        "SELECT COUNT(*) FROM phrasebook_entries"
                    )
                ),
                protectedCount: Int(
                    try queryInt64(
                        "SELECT COUNT(*) FROM phrasebook_entries WHERE protected = 1"
                    )
                ),
                domains: domains,
                generation: try queryInt64(
                    """
                    SELECT generation FROM phrasebook_metadata
                    WHERE id = 1
                    """
                )
            )
        }
    }

    /// Clears every learned artifact and bumps the store generation.
    @discardableResult
    public func clearAll() throws -> Int64 {
        try queue.sync {
            try transaction {
                try execute("DELETE FROM phrasebook_entries")
                try execute("DELETE FROM domain_map")
                try execute("DELETE FROM domain_stats")
                try execute(
                    """
                    UPDATE phrasebook_metadata
                    SET generation = generation + 1
                    WHERE id = 1
                    """
                )
            }
            return try queryInt64(
                """
                SELECT generation FROM phrasebook_metadata
                WHERE id = 1
                """
            )
        }
    }

    public func exportJSON(to destination: URL) throws {
        struct ExportPayload: Encodable {
            let entries: [PhraseBookEntry]
            let domainMappings: [PhraseDomainMapping]
        }
        let payload = ExportPayload(
            entries: try entries(limit: 100_000),
            domainMappings: try domainMappings()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(payload).write(
                to: destination,
                options: .atomic
            )
        } catch {
            throw PhraseBookError.fileSystem(error.localizedDescription)
        }
    }

    // MARK: - Internals

    /// Prepared-statement execute with bound string parameters, in
    /// order. Only call while holding `queue.sync`.
    func run(_ sql: String, _ values: [String]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            try bind(value, to: statement, index: Int32(offset + 1))
        }
        try stepDone(statement)
    }

    func validatedDomain(_ raw: String) throws -> String {
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

    /// Pure normalization (no database access): empty resolves to
    /// `global`, anything else must satisfy `validatedDomain`. Safe to
    /// call off the store queue.
    func normalizedDomain(_ raw: String) throws -> String {
        let domain = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !domain.isEmpty else {
            return PhraseBookDomain.global
        }
        return try validatedDomain(domain)
    }
}

private extension Character {
    var isLowercaseLetterOrDigitOrHyphen: Bool {
        (isASCII && (isLetter && !isUppercase)) || (isASCII && isNumber)
            || self == "-" || self == "_"
    }
}
