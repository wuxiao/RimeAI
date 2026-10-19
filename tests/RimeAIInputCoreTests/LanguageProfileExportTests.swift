import Foundation
import Testing
@testable import RimeAIInputCore

@Suite("language profile export aggregates all three layers (P1-4)")
struct LanguageProfileExportTests {
    private func makeStore(
        _ directory: URL
    ) throws -> PhraseBookStore {
        try PhraseBookStore(
            databaseURL: directory.appendingPathComponent(
                "phrasebook.sqlite3"
            )
        )
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RimeAI-ExportTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    @Test("payload contains phrasebook, user LM, and style profiles")
    func aggregatesAllLayers() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileDirectory = directory.appendingPathComponent(
            "language_profile",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: profileDirectory,
            withIntermediateDirectories: true
        )

        let store = try makeStore(directory)
        try store.addUserPhrase(
            text: "口径",
            pinyinKeys: "koujing",
            domain: "global"
        )
        try store.setDomainMapping(
            bundleIdentifier: "com.example.Work",
            domain: "work"
        )

        // L2 artifact in the daemon's gzip-JSON format.
        let userLM = """
            {"schema_version":1,"model_type":"user-char-ngram","domains":{"global":{"characters":42}}}
            """
        try GzipCodec.encode(Data(userLM.utf8)).write(
            to: profileDirectory.appendingPathComponent("user-lm.json.gz")
        )
        // L3 style profile.
        let profile = """
            {"domain":"global","revision":3,"traits":{"register":["casual"]}}
            """
        try Data(profile.utf8).write(
            to: profileDirectory.appendingPathComponent(
                "profile-global.json"
            )
        )

        let payload = try LanguageProfileExporter.payload(
            phrasebook: store,
            languageProfileDirectory: profileDirectory
        )

        #expect(
            payload["format"] as? String
                == LanguageProfileExporter.formatIdentifier
        )
        let phrasebook = payload["phrasebook"] as? [String: Any]
        let entries = phrasebook?["entries"] as? [[String: Any]]
        #expect(entries?.count == 1)
        let mappings = phrasebook?["domainMappings"] as? [[String: Any]]
        #expect(mappings?.count == 1)
        let lm = payload["user_lm"] as? [String: Any]
        let domains = lm?["domains"] as? [String: Any]
        #expect((domains?["global"] as? [String: Any])?["characters"] as? Int == 42)
        let profiles = payload["style_profiles"] as? [String: Any]
        let global = profiles?["global"] as? [String: Any]
        #expect(global?["revision"] as? Int == 3)
    }

    @Test("missing L2 artifact exports as null instead of failing")
    func missingUserLMExportsNull() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(directory)
        let payload = try LanguageProfileExporter.payload(
            phrasebook: store,
            languageProfileDirectory: directory
        )
        #expect(payload["user_lm"] is NSNull)
        #expect((payload["style_profiles"] as? [String: Any])?.isEmpty == true)
    }

    @Test("export writes a parseable JSON document atomically")
    func exportWritesParseableDocument() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(directory)
        let destination = directory.appendingPathComponent("export.json")
        try LanguageProfileExporter.export(
            phrasebook: store,
            languageProfileDirectory: directory,
            to: destination
        )
        let data = try Data(contentsOf: destination)
        let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        #expect(object?["version"] as? Int == 2)
    }
}
