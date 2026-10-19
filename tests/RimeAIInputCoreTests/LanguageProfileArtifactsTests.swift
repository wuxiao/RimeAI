import Foundation
import Testing
@testable import RimeAIInputCore

@Suite("domain operations cascade to L2/L3 artifacts (P2-16)")
struct LanguageProfileArtifactsTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RimeAI-ArtifactsTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func writeUserLM(
        _ domains: [String: Any],
        to directory: URL
    ) throws {
        let payload: [String: Any] = [
            "schema_version": 1,
            "model_type": "user-char-ngram",
            "domains": domains,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
        try GzipCodec.encode(data).write(
            to: directory.appendingPathComponent("user-lm.json.gz")
        )
    }

    private func readUserLMDomains(from directory: URL) throws
        -> [String: Any]
    {
        let data = try Data(
            contentsOf: directory.appendingPathComponent("user-lm.json.gz")
        )
        let decoded = try GzipCodec.decode(data)
        let payload = try JSONSerialization.jsonObject(with: decoded)
            as? [String: Any]
        return payload?["domains"] as? [String: Any] ?? [:]
    }

    private func countsPayload(characters: Int) -> [String: Any] {
        [
            "ngram_counts": ["2": ["接": ["口": 2]]],
            "prefix_counts": ["2": ["接": 2]],
            "characters": characters,
        ]
    }

    @Test("rename moves the domain's L2 counts and L3 profile")
    func renameCascadesToAllLayers() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeUserLM(["work": countsPayload(characters: 42)],
                        to: directory)
        try Data("{}".utf8).write(
            to: directory.appendingPathComponent("profile-work.json")
        )
        let revisions = directory.appendingPathComponent("revisions")
        try FileManager.default.createDirectory(
            at: revisions,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: revisions.appendingPathComponent("work-1700000000000.json")
        )

        try LanguageProfileArtifacts.renameDomain(
            from: "work",
            to: "chat",
            in: directory
        )

        let domains = try readUserLMDomains(from: directory)
        #expect(domains["work"] == nil)
        #expect(
            (domains["chat"] as? [String: Any])?["characters"] as? Int == 42
        )
        // L3 当前文件与修订史都跟随改名。
        #expect(
            (try? Data(
                contentsOf: directory.appendingPathComponent(
                    "profile-chat.json"
                )
            )) != nil
        )
        #expect(
            (try? Data(
                contentsOf: revisions.appendingPathComponent(
                    "chat-1700000000000.json"
                )
            )) != nil
        )
    }

    @Test("rename onto an existing domain merges L2 counters by summing")
    func renameOntoExistingDomainMergesCounts() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeUserLM(
            [
                "work": countsPayload(characters: 40),
                "chat": countsPayload(characters: 2),
            ],
            to: directory
        )
        // 目标域已有画像：源画像不得覆盖目标，只能归档进 revisions。
        try Data("{\"revision\":9}".utf8).write(
            to: directory.appendingPathComponent("profile-chat.json")
        )
        try Data("{\"revision\":3}".utf8).write(
            to: directory.appendingPathComponent("profile-work.json")
        )

        try LanguageProfileArtifacts.renameDomain(
            from: "work",
            to: "chat",
            in: directory
        )

        let domains = try readUserLMDomains(from: directory)
        #expect(domains["work"] == nil)
        let merged = domains["chat"] as? [String: Any]
        #expect(merged?["characters"] as? Int == 42)
        let prefixes = merged?["prefix_counts"] as? [String: Any]
        #expect((prefixes?["2"] as? [String: Any])?["接"] as? Int == 4)
        // 目标画像未被覆盖；源画像以修订形式跟随改名进入 target 的
        // revisions（改名=同域换名，修订史归属随之迁移）。
        let target = try String(
            contentsOf: directory.appendingPathComponent(
                "profile-chat.json"
            ),
            encoding: .utf8
        )
        #expect(target.contains("\"revision\":9"))
        let revisionFiles = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("revisions"),
            includingPropertiesForKeys: nil
        )
        #expect(
            revisionFiles.contains {
                $0.lastPathComponent.hasPrefix("chat-merged-")
            }
        )
        #expect(
            !revisionFiles.contains {
                $0.lastPathComponent.hasPrefix("work-")
            }
        )
    }

    @Test("delete removes the domain from L2 and its L3 artifacts")
    func deleteCascadesToAllLayers() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeUserLM(
            [
                "work": countsPayload(characters: 42),
                "global": countsPayload(characters: 7),
            ],
            to: directory
        )
        try Data("{}".utf8).write(
            to: directory.appendingPathComponent("profile-work.json")
        )
        let revisions = directory.appendingPathComponent("revisions")
        try FileManager.default.createDirectory(
            at: revisions,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: revisions.appendingPathComponent("work-1700000000000.json")
        )

        try LanguageProfileArtifacts.deleteDomain("work", in: directory)

        let domains = try readUserLMDomains(from: directory)
        #expect(domains["work"] == nil)
        #expect(domains["global"] != nil)
        #expect(
            (try? Data(
                contentsOf: directory.appendingPathComponent(
                    "profile-work.json"
                )
            )) == nil
        )
        #expect(
            (try? FileManager.default.contentsOfDirectory(
                at: revisions,
                includingPropertiesForKeys: nil
            ))?.isEmpty == true
        )
    }
}
