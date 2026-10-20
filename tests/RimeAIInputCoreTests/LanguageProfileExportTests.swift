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

    @Test("exported file is owner-only (0600)")
    func exportWritesOwnerOnlyFile() throws {
        // 导出文件含用户全部学习短语、L2 计数与 L3 画像；Foundation 的
        // .atomic 写会沿用进程 umask（默认 0644），本机任何账号可读。
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(directory)
        try store.addUserPhrase(
            text: "口径",
            pinyinKeys: "koujing",
            domain: "global"
        )
        let destination = directory.appendingPathComponent("export.json")
        try LanguageProfileExporter.export(
            phrasebook: store,
            languageProfileDirectory: directory,
            to: destination
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: destination.path
        )
        let permissions = (attributes[.posixPermissions] as? NSNumber)?
            .intValue ?? 0
        #expect(permissions == 0o600)
    }

    @Test("export over an existing file keeps the owner-only mode")
    func exportReplacesExistingFileOwnerOnly() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(directory)
        let destination = directory.appendingPathComponent("export.json")
        try Data("stale".utf8).write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: destination.path
        )
        try LanguageProfileExporter.export(
            phrasebook: store,
            languageProfileDirectory: directory,
            to: destination
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: destination.path
        )
        let permissions = (attributes[.posixPermissions] as? NSNumber)?
            .intValue ?? 0
        #expect(permissions == 0o600)
    }

    @Test("export caps the entry count and says so")
    func exportCapsEntriesAndMarksTruncation() throws {
        // 学习表没有自动淘汰（设计 §4.1），导出必须有上限，否则长期用户
        // 会得到 GB 级 JSON；截断必须在文档里显式标注。
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(directory)
        for index in 0..<3 {
            try store.addUserPhrase(
                text: "短语\(index)",
                pinyinKeys: "duan\(index)",
                domain: "global"
            )
        }
        let payload = try LanguageProfileExporter.payload(
            phrasebook: store,
            languageProfileDirectory: directory,
            maximumEntries: 2
        )
        let phrasebook = payload["phrasebook"] as? [String: Any]
        let entries = phrasebook?["entries"] as? [[String: Any]]
        #expect(entries?.count == 2)
        #expect(phrasebook?["truncated"] as? Bool == true)
        #expect(phrasebook?["availableEntries"] as? Int == 3)
    }
}
