import Foundation

/// Aggregates all three learning artifacts (L1 phrasebook, L2 user LM,
/// L3 style profiles) into one export document (PRD 4.1 / LP-DESIGN §7:
/// "画像、短语库、L2 计数全部可一键导出").
public enum LanguageProfileExporter {
    public static let formatIdentifier = "rimeai-language-profile-export"

    /// Upper bound on exported L1 entries. The learning table has no
    /// eviction yet (design §4.1: time-decayed eviction is planned), so
    /// a long-lived profile can hold hundreds of thousands of phrases; a
    /// single JSON document plus its gzip payload would then be
    /// gigabytes and fully resident in memory. Exports are capped and
    /// say so explicitly instead of silently producing a huge file.
    public static let maximumExportEntries = 50_000

    /// Builds the aggregate payload as a JSON object tree. `userLM` is
    /// `NSNull` when the artifact has never been written.
    public static func payload(
        phrasebook: PhraseBookStore,
        languageProfileDirectory: URL,
        maximumEntries: Int = LanguageProfileExporter.maximumExportEntries
    ) throws -> [String: Any] {
        [
            "format": formatIdentifier,
            "version": 2,
            "exported_at_ms": Int(
                Date().timeIntervalSince1970 * 1000
            ),
            "phrasebook": try phrasebookPayload(
                phrasebook,
                maximumEntries: maximumEntries
            ),
            "user_lm": try userLMPayload(languageProfileDirectory),
            "style_profiles": try styleProfilePayloads(
                languageProfileDirectory
            ),
        ]
    }

    public static func export(
        phrasebook: PhraseBookStore,
        languageProfileDirectory: URL,
        to destination: URL,
        maximumEntries: Int = LanguageProfileExporter.maximumExportEntries
    ) throws {
        let object = try payload(
            phrasebook: phrasebook,
            languageProfileDirectory: languageProfileDirectory,
            maximumEntries: maximumEntries
        )
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .prettyPrinted]
        )
        try writeOwnerOnly(data, to: destination)
    }

    /// Writes the export so only its owner can read it.
    ///
    /// Foundation's `.atomic` write creates the file with the process
    /// umask (0644 in a default macOS session), which would expose the
    /// user's complete typing profile — L1 phrases, L2 n-gram counts and
    /// the L3 style profile — to every local account. Write an
    /// owner-only temporary file next to the destination and move it
    /// into place instead, the same way the credential store writes
    /// `cloud.env`.
    private static func writeOwnerOnly(
        _ data: Data,
        to destination: URL
    ) throws {
        let manager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".rimeai-language-profile-export-\(UUID().uuidString).tmp",
                isDirectory: false
            )
        let created = manager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw PhraseBookError.fileSystem(
                "language profile export could not be created"
            )
        }
        do {
            _ = try manager.replaceItemAt(
                destination,
                withItemAt: temporary
            )
        } catch {
            _ = try? manager.removeItem(at: temporary)
            throw error
        }
        // Replacing an existing destination can keep that file's own
        // permissions; re-assert the owner-only mode. A failure here
        // means the export is readable by other local accounts, so it
        // must not be swallowed.
        try manager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }

    private static func phrasebookPayload(
        _ store: PhraseBookStore,
        maximumEntries: Int
    ) throws -> [String: Any] {
        struct PhrasebookSection: Encodable {
            let entries: [PhraseBookEntry]
            let domainMappings: [PhraseDomainMapping]
            let truncated: Bool
            let availableEntries: Int
        }
        // One extra row tells us whether the cap actually cut anything.
        let fetched = try store.entries(limit: maximumEntries + 1)
        let truncated = fetched.count > maximumEntries
        let entries = truncated
            ? Array(fetched.prefix(maximumEntries))
            : fetched
        let available = try store.entryCount()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(
            PhrasebookSection(
                entries: entries,
                domainMappings: try store.domainMappings(),
                truncated: truncated,
                availableEntries: available
            )
        )
        guard let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else {
            throw PhraseBookError.fileSystem("phrasebook export payload")
        }
        return object
    }

    private static func userLMPayload(_ directory: URL) throws -> Any {
        let url = directory.appendingPathComponent("user-lm.json.gz")
        guard let compressed = try? Data(contentsOf: url), !compressed.isEmpty
        else {
            return NSNull()
        }
        let decoded = try GzipCodec.decode(compressed)
        return try JSONSerialization.jsonObject(with: decoded)
    }

    private static func styleProfilePayloads(
        _ directory: URL
    ) throws -> [String: Any] {
        let items =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []
        var profiles: [String: Any] = [:]
        for item in items {
            let name = item.lastPathComponent
            guard name.hasPrefix("profile-"), name.hasSuffix(".json") else {
                continue
            }
            let domain = String(
                name.dropFirst("profile-".count).dropLast(".json".count)
            )
            let data = try Data(contentsOf: item)
            profiles[domain] = try JSONSerialization.jsonObject(with: data)
        }
        return profiles
    }
}
