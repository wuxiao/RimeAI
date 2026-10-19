import Foundation

/// Aggregates all three learning artifacts (L1 phrasebook, L2 user LM,
/// L3 style profiles) into one export document (PRD 4.1 / LP-DESIGN §7:
/// "画像、短语库、L2 计数全部可一键导出").
public enum LanguageProfileExporter {
    public static let formatIdentifier = "rimeai-language-profile-export"

    /// Builds the aggregate payload as a JSON object tree. `userLM` is
    /// `NSNull` when the artifact has never been written.
    public static func payload(
        phrasebook: PhraseBookStore,
        languageProfileDirectory: URL
    ) throws -> [String: Any] {
        [
            "format": formatIdentifier,
            "version": 2,
            "exported_at_ms": Int(
                Date().timeIntervalSince1970 * 1000
            ),
            "phrasebook": try phrasebookPayload(phrasebook),
            "user_lm": try userLMPayload(languageProfileDirectory),
            "style_profiles": try styleProfilePayloads(
                languageProfileDirectory
            ),
        ]
    }

    public static func export(
        phrasebook: PhraseBookStore,
        languageProfileDirectory: URL,
        to destination: URL
    ) throws {
        let object = try payload(
            phrasebook: phrasebook,
            languageProfileDirectory: languageProfileDirectory
        )
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .prettyPrinted]
        )
        try data.write(to: destination, options: .atomic)
    }

    private static func phrasebookPayload(
        _ store: PhraseBookStore
    ) throws -> [String: Any] {
        struct PhrasebookSection: Encodable {
            let entries: [PhraseBookEntry]
            let domainMappings: [PhraseDomainMapping]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(
            PhrasebookSection(
                entries: try store.entries(limit: 1_000_000),
                domainMappings: try store.domainMappings()
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
