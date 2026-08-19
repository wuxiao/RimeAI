import Foundation
import Testing
@testable import RimeAIInputCore

@Suite("Plaintext cross-application history")
struct HistoryStoreTests {
    private func makeStore() throws -> (HistoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RimeAI-HistoryStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let database = directory.appendingPathComponent("history.sqlite3")
        return (
            try HistoryStore(databaseURL: database),
            directory
        )
    }

    @Test("successful RimeAI commits persist across applications")
    func appendAndRead() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = HistoryCommit(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            committedAt: Date(timeIntervalSince1970: 1),
            bundleIdentifier: "com.example.Editor",
            pinyin: "mingling",
            committedText: "命令",
            source: .rimeMain
        )
        let second = HistoryCommit(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            committedAt: Date(timeIntervalSince1970: 2),
            bundleIdentifier: "com.example.Chat",
            pinyin: "xiazai",
            committedText: "下载完成",
            source: .cloudExact
        )

        try store.append(first)
        try store.append(second)
        try store.append(second)

        #expect(try store.records() == [first, second])
        #expect(try store.recentText(maxCharacters: 5) == "令下载完成")
        #expect(
            try store.statistics()
                == HistoryStoreStatistics(
                    recordCount: 2,
                    generation: 0,
                    pendingEmbeddingJobs: 2,
                    unembeddedRecords: 2
                )
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: store.databaseURL.path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("clear advances generation and removes every derived artifact")
    func clearAll() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.append(
            HistoryCommit(
                bundleIdentifier: "com.example.Editor",
                pinyin: "ceshi",
                committedText: "测试",
                source: .rimeMain
            )
        )
        try Data("derived".utf8).write(to: store.vectorIndexURL)
        let temporaryIndex = store.vectorIndexURL
            .deletingPathExtension()
            .appendingPathExtension("tmp")
        try Data("partial".utf8).write(to: temporaryIndex)

        let generation = try store.clearAll()

        #expect(generation == 1)
        #expect(try store.records().isEmpty)
        #expect(try store.recentText().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.vectorIndexURL.path))
        #expect(!FileManager.default.fileExists(atPath: temporaryIndex.path))
        #expect(try store.statistics().pendingEmbeddingJobs == 0)
    }

    @Test("history exports plaintext JSONL without credentials")
    func export() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.append(
            HistoryCommit(
                bundleIdentifier: "com.example.Editor",
                pinyin: "mingwen",
                committedText: "明文历史",
                source: .localSemantic
            )
        )
        let exportURL = directory.appendingPathComponent("history.jsonl")

        try store.exportJSONL(to: exportURL)

        let value = try String(contentsOf: exportURL, encoding: .utf8)
        #expect(value.contains("明文历史"))
        #expect(value.contains("com.example.Editor"))
        #expect(!value.lowercased().contains("api_key"))
    }

    @Test("relevant snippets search pinyin across applications")
    func relevantSnippets() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.append(
            HistoryCommit(
                bundleIdentifier: "com.example.Editor",
                pinyin: "xiangmumingcheng",
                committedText: "海豚项目",
                source: .rimeMain
            )
        )
        try store.append(
            HistoryCommit(
                bundleIdentifier: "com.example.Chat",
                pinyin: "wuguanneirong",
                committedText: "无关内容",
                source: .rimeMain
            )
        )

        let snippets = try store.relevantSnippets(
            query: "xiangmumingcheng"
        )

        #expect(snippets.count == 1)
        #expect(snippets[0].text == "海豚项目")
        #expect(snippets[0].bundleIdentifier == "com.example.Editor")

        let snapshot = try store.contextSnapshot(
            query: "xiangmumingcheng"
        )
        #expect(snapshot.generation == 0)
        #expect(snapshot.recentText == "海豚项目无关内容")
        #expect(snapshot.relevantSnippets == snippets)
    }

    @Test("invalid or empty commits are rejected")
    func invalidRecord() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: HistoryStoreError.invalidRecord) {
            try store.append(
                HistoryCommit(
                    bundleIdentifier: "com.example.Editor",
                    pinyin: "",
                    committedText: "",
                    source: .rawPinyin
                )
            )
        }
    }
}
