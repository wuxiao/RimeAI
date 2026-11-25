import Foundation
import Testing
@testable import RimeAIInputCore

@Suite("Voice history and usage statistics store")
struct VoiceHistoryStoreTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "VoiceHistoryStoreTests.\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    @Test("records history, supports search/filter, and computes usage stats")
    func recordsHistoryAndComputesStats() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try VoiceHistoryStore(
            databaseURL: dir.appendingPathComponent("voice-history.sqlite3")
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 25, hour: 15, minute: 0
        ))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!

        try store.recordSession(VoiceHistoryRecord(
            createdAt: yesterday,
            bundleIdentifier: "com.apple.Notes",
            rawText: "嗯，昨天开会讨论了发布计划",
            finalText: "昨天开会讨论了发布计划。",
            actionKind: .polish,
            polishStyle: .concise,
            durationMilliseconds: 4_000,
            autoPasted: true
        ))
        try store.recordSession(VoiceHistoryRecord(
            createdAt: now,
            bundleIdentifier: "com.tencent.xinWeChat",
            rawText: "今天下午三点见",
            finalText: "See you at 3 PM today.",
            actionKind: .translate,
            targetLanguage: .english,
            durationMilliseconds: 3_000,
            autoPasted: true
        ))
        try store.recordSession(VoiceHistoryRecord(
            createdAt: now.addingTimeInterval(10),
            bundleIdentifier: "com.apple.Notes",
            rawText: "记录一条普通听写",
            finalText: "记录一条普通听写",
            actionKind: .dictation,
            durationMilliseconds: 2_000,
            autoPasted: false
        ))

        let all = try store.listRecords()
        #expect(all.count == 3)
        #expect(all.first?.actionKind == .dictation)

        let translations = try store.listRecords(actionKind: .translate)
        #expect(translations.count == 1)
        #expect(translations.first?.finalText == "See you at 3 PM today.")
        #expect(translations.first?.rawText == "今天下午三点见")

        let searchHits = try store.listRecords(query: "发布计划")
        #expect(searchHits.count == 1)

        let summary = try store.usageSummary(now: now, calendar: calendar)
        #expect(summary.totalSessions == 3)
        #expect(summary.todaySessions == 2)
        #expect(summary.last7DaysSessions == 3)
        #expect(summary.polishedSessions == 1)
        #expect(summary.translatedSessions == 1)
        #expect(summary.dictationSessions == 1)
        #expect(summary.autoPastedSessions == 2)
        #expect(summary.totalDurationMilliseconds == 9_000)
        #expect(summary.activeDayStreak == 2)
        #expect(summary.historyRecordCount == 3)
        #expect(summary.averageCharsPerMinute > 0)
        #expect(summary.estimatedMinutesSaved > 0)
        #expect(summary.topApps.count == 2)
    }

    @Test("stats still accumulate when history text storage is disabled")
    func statsWorkWithoutStoringText() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try VoiceHistoryStore(
            databaseURL: dir.appendingPathComponent("voice-history.sqlite3")
        )

        try store.recordSession(
            VoiceHistoryRecord(
                bundleIdentifier: "com.apple.TextEdit",
                rawText: "测试私密文本",
                finalText: "测试私密文本",
                actionKind: .dictation,
                durationMilliseconds: 2_500,
                autoPasted: true
            ),
            storeHistoryText: false
        )

        #expect(try store.listRecords().isEmpty)
        let summary = try store.usageSummary()
        #expect(summary.totalSessions == 1)
        #expect(summary.totalCharacters == 6)
        #expect(summary.historyRecordCount == 0)
    }

    @Test("delete, clearHistory, resetUsageStatistics, and JSONL export work independently")
    func managementOperations() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try VoiceHistoryStore(
            databaseURL: dir.appendingPathComponent("voice-history.sqlite3")
        )
        let first = VoiceHistoryRecord(
            bundleIdentifier: "com.apple.Notes",
            rawText: "第一条",
            finalText: "第一条",
            actionKind: .dictation,
            durationMilliseconds: 1_000,
            autoPasted: true
        )
        let second = VoiceHistoryRecord(
            bundleIdentifier: "com.apple.Notes",
            rawText: "第二条",
            finalText: "第二条",
            actionKind: .polish,
            polishStyle: .formal,
            durationMilliseconds: 1_500,
            autoPasted: true
        )
        try store.recordSession(first)
        try store.recordSession(second)

        let exportURL = dir.appendingPathComponent("export.jsonl")
        try store.exportHistoryJSONL(to: exportURL)
        let exported = try String(contentsOf: exportURL, encoding: .utf8)
        #expect(exported.contains("第一条"))
        #expect(exported.contains("第二条"))

        try store.deleteRecord(id: first.id)
        #expect(try store.listRecords().count == 1)

        try store.clearHistory()
        #expect(try store.listRecords().isEmpty)
        // Clearing text preserves usage stats
        #expect(try store.usageSummary().totalSessions == 2)

        try store.resetUsageStatistics()
        #expect(try store.usageSummary().totalSessions == 0)
    }

    // MARK: - LIKE escaping, delete semantics and file permissions

    @Test("LIKE wildcards in the search query match literally")
    func searchTreatsLikeWildcardsAsLiteralCharacters() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try VoiceHistoryStore(
            databaseURL: dir.appendingPathComponent("voice-history.sqlite3")
        )
        let texts = [
            "进度 100% 完成",
            "第 100 号记录",
            "a_b 测试",
            "路径 C:\\temp 测试",
            "普通记录",
        ]
        for (index, text) in texts.enumerated() {
            try store.recordSession(VoiceHistoryRecord(
                createdAt: Date().addingTimeInterval(Double(index)),
                bundleIdentifier: "com.apple.Notes",
                rawText: text,
                finalText: text,
                actionKind: .dictation,
                durationMilliseconds: 1_000,
                autoPasted: false
            ))
        }
        #expect(try store.listRecords().count == 5)

        let percent = try store.listRecords(query: "100%")
        #expect(percent.map(\.finalText) == ["进度 100% 完成"])
        // 没有转义时 "%100%%" 也会命中“第 100 号记录”，"%_%" 会命中所有记录。
        #expect(try store.listRecords(query: "100").count == 2)
        #expect(try store.listRecords(query: "_").map(\.finalText) == ["a_b 测试"])
        #expect(try store.listRecords(query: "a_b").map(\.finalText) == ["a_b 测试"])
        #expect(try store.listRecords(query: "\\").map(\.finalText) == ["路径 C:\\temp 测试"])
        #expect(try store.listRecords(query: "记录").count == 2)
    }

    @Test("search patterns escape percent, underscore and backslash")
    func likePatternEscapesWildcards() {
        #expect(VoiceHistoryStore.likePattern(containing: "100%") == "%100\\%%")
        #expect(VoiceHistoryStore.likePattern(containing: "a_b") == "%a\\_b%")
        #expect(VoiceHistoryStore.likePattern(containing: "C:\\temp") == "%C:\\\\temp%")
        #expect(VoiceHistoryStore.likePattern(containing: "普通 记录") == "%普通 记录%")
    }

    @Test("deleting a record reports whether a row was actually removed")
    func deleteRecordReportsMissingRows() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try VoiceHistoryStore(
            databaseURL: dir.appendingPathComponent("voice-history.sqlite3")
        )
        let record = VoiceHistoryRecord(
            bundleIdentifier: "com.apple.Notes",
            rawText: "会被删除的记录",
            finalText: "会被删除的记录",
            actionKind: .dictation,
            durationMilliseconds: 1_000,
            autoPasted: false
        )
        try store.recordSession(record)

        // 不存在的 id：DELETE 语句成功执行但影响 0 行。
        #expect(try store.deleteRecord(id: UUID()) == false)
        #expect(try store.listRecords().count == 1)

        #expect(try store.deleteRecord(id: record.id))
        #expect(try store.listRecords().isEmpty)
        // 重复删除同一条也返回 false。
        #expect(try store.deleteRecord(id: record.id) == false)
    }

    @Test("database and WAL/SHM sidecar files stay owner-only (0600)")
    func databaseAndSidecarFilesAreOwnerOnly() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileManager = FileManager.default
        let databaseURL = dir.appendingPathComponent("voice-history.sqlite3")
        func permissions(_ url: URL) -> Int? {
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return (try? fileManager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        }
        let sidecars = [
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]

        let store = try VoiceHistoryStore(databaseURL: databaseURL)
        try store.recordSession(VoiceHistoryRecord(
            bundleIdentifier: "com.apple.Notes",
            rawText: "权限检查",
            finalText: "权限检查",
            actionKind: .dictation,
            durationMilliseconds: 1_000,
            autoPasted: false
        ))
        #expect(permissions(databaseURL) == 0o600)
        // WAL 模式下写入会创建旁车文件；它们存在时必须是 0600。
        for sidecar in sidecars where permissions(sidecar) != nil {
            #expect(permissions(sidecar) == 0o600)
        }

        // 模拟旧版本或外部恢复留下的 0644 文件：重新打开时尽力收紧。
        for url in [databaseURL] + sidecars where permissions(url) != nil {
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        let reopened = try VoiceHistoryStore(databaseURL: databaseURL)
        try reopened.recordSession(VoiceHistoryRecord(
            bundleIdentifier: "com.apple.Notes",
            rawText: "再次写入",
            finalText: "再次写入",
            actionKind: .dictation,
            durationMilliseconds: 1_000,
            autoPasted: false
        ))
        #expect(permissions(databaseURL) == 0o600)
        for sidecar in sidecars where permissions(sidecar) != nil {
            #expect(permissions(sidecar) == 0o600)
        }
    }
}
