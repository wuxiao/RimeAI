import Foundation
import SQLite3

public struct VoiceHistoryRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let bundleIdentifier: String
    public let rawText: String
    public let finalText: String
    public let actionKind: VoicePostProcessAction
    public let polishStyle: VoicePolishStyle?
    public let targetLanguage: VoiceTranslationLanguage?
    public let durationMilliseconds: Int
    public let characterCount: Int
    public let autoPasted: Bool

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        bundleIdentifier: String,
        rawText: String,
        finalText: String,
        actionKind: VoicePostProcessAction,
        polishStyle: VoicePolishStyle? = nil,
        targetLanguage: VoiceTranslationLanguage? = nil,
        durationMilliseconds: Int,
        autoPasted: Bool
    ) {
        self.id = id
        self.createdAt = createdAt
        self.bundleIdentifier = bundleIdentifier
        self.rawText = rawText
        self.finalText = finalText
        self.actionKind = actionKind
        self.polishStyle = polishStyle
        self.targetLanguage = targetLanguage
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.characterCount = finalText.count
        self.autoPasted = autoPasted
    }
}

public struct VoiceDailyUsageStat: Codable, Equatable, Sendable {
    public let dayKey: String
    public let sessionCount: Int
    public let characterCount: Int
    public let durationMilliseconds: Int
    public let polishedCount: Int
    public let translatedCount: Int
    public let autoPastedCount: Int

    public init(
        dayKey: String,
        sessionCount: Int,
        characterCount: Int,
        durationMilliseconds: Int,
        polishedCount: Int,
        translatedCount: Int,
        autoPastedCount: Int
    ) {
        self.dayKey = dayKey
        self.sessionCount = sessionCount
        self.characterCount = characterCount
        self.durationMilliseconds = durationMilliseconds
        self.polishedCount = polishedCount
        self.translatedCount = translatedCount
        self.autoPastedCount = autoPastedCount
    }
}

public struct VoiceAppUsageStat: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let sessionCount: Int
    public let characterCount: Int
    public let durationMilliseconds: Int

    public init(
        bundleIdentifier: String,
        sessionCount: Int,
        characterCount: Int,
        durationMilliseconds: Int
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.sessionCount = sessionCount
        self.characterCount = characterCount
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct VoiceUsageSummary: Equatable, Sendable {
    /// 参考人工打字基线速度（字/分钟），用于估算语音输入节省的时间。
    public static let baselineTypingCharsPerMinute: Double = 45.0

    public let totalSessions: Int
    public let totalCharacters: Int
    public let totalDurationMilliseconds: Int
    public let todaySessions: Int
    public let todayCharacters: Int
    public let todayDurationMilliseconds: Int
    public let last7DaysSessions: Int
    public let last7DaysCharacters: Int
    public let dictationSessions: Int
    public let polishedSessions: Int
    public let translatedSessions: Int
    public let autoPastedSessions: Int
    public let activeDayStreak: Int
    public let historyRecordCount: Int
    public let topApps: [VoiceAppUsageStat]
    public let dailyTrend: [VoiceDailyUsageStat]

    public var averageCharsPerMinute: Double {
        guard totalDurationMilliseconds > 0, totalCharacters > 0 else {
            return 0
        }
        let minutes = Double(totalDurationMilliseconds) / 60_000.0
        guard minutes > 0 else { return 0 }
        return Double(totalCharacters) / minutes
    }

    /// 估算节省的分钟数：对比基线打字耗时减去实际说话耗时（不小于 0）。
    public var estimatedMinutesSaved: Double {
        guard totalCharacters > 0 else { return 0 }
        let typingMinutes = Double(totalCharacters)
            / Self.baselineTypingCharsPerMinute
        let speakingMinutes = Double(totalDurationMilliseconds) / 60_000.0
        return max(0, typingMinutes - speakingMinutes)
    }

    public static let empty = VoiceUsageSummary(
        totalSessions: 0,
        totalCharacters: 0,
        totalDurationMilliseconds: 0,
        todaySessions: 0,
        todayCharacters: 0,
        todayDurationMilliseconds: 0,
        last7DaysSessions: 0,
        last7DaysCharacters: 0,
        dictationSessions: 0,
        polishedSessions: 0,
        translatedSessions: 0,
        autoPastedSessions: 0,
        activeDayStreak: 0,
        historyRecordCount: 0,
        topApps: [],
        dailyTrend: []
    )
}

public enum VoiceHistoryStoreError: Error, Equatable, Sendable {
    case invalidRecord
    case sqlite(code: Int32, message: String)
    case fileSystem(String)
}

/// 本地语音历史记录与使用情况统计存储（SQLite，0600 权限）。
/// 与云端向量索引 history.sqlite3 完全隔离，只留存本机。
public final class VoiceHistoryStore: @unchecked Sendable {
    public static let maximumRetainedHistoryRecords = 5_000

    public let databaseURL: URL
    private let queue = DispatchQueue(
        label: "fun.wwcn.rimeai.voice-history-store"
    )
    private let fileManager: FileManager
    private var database: OpaquePointer?

    public init(
        databaseURL: URL,
        fileManager: FileManager = .default
    ) throws {
        self.databaseURL = databaseURL
        self.fileManager = fileManager

        let directory = databaseURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch {
            throw VoiceHistoryStoreError.fileSystem(error.localizedDescription)
        }

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
            } ?? "could not open voice history database"
            if let opened {
                sqlite3_close_v2(opened)
            }
            throw VoiceHistoryStoreError.sqlite(code: status, message: message)
        }
        database = opened

        do {
            // 先把主库收紧到 0600：随后 SQLite 新建的 WAL / SHM 旁车文件
            // 会继承同一权限位。
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: databaseURL.path
            )
            try configureDatabase()
            // 旧版本或外部恢复的库可能带着 0644 的主库 / 旁车文件：尽力修正，
            // 失败不影响使用。
            applyPrivateFilePermissions()
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

    /// 历史库及其 `-wal` / `-shm` 旁车文件（如存在）只允许当前用户读写。
    /// 尽力而为：文件系统不支持或文件被并发删除时静默跳过。
    private func applyPrivateFilePermissions() {
        for path in [
            databaseURL.path,
            databaseURL.path + "-wal",
            databaseURL.path + "-shm",
        ] where fileManager.fileExists(atPath: path) {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
        }
    }

    /// 记录一次语音会话：使用统计始终累加（不含文本），明文历史按
    /// `storeHistoryText` 开关决定是否落库。
    public func recordSession(
        _ record: VoiceHistoryRecord,
        storeHistoryText: Bool = true
    ) throws {
        let trimmedFinal = record.finalText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedFinal.isEmpty,
              !record.bundleIdentifier.isEmpty
        else {
            throw VoiceHistoryStoreError.invalidRecord
        }
        let createdAtMs = Int64(record.createdAt.timeIntervalSince1970 * 1_000)
        let dayKey = Self.dayKey(for: record.createdAt)
        let polishedIncrement: Int64 = record.actionKind == .polish ? 1 : 0
        let translatedIncrement: Int64 = record.actionKind == .translate ? 1 : 0
        let autoPastedIncrement: Int64 = record.autoPasted ? 1 : 0
        let charCount = Int64(trimmedFinal.count)
        let durationMs = Int64(max(0, record.durationMilliseconds))

        try queue.sync {
            try transaction {
                if storeHistoryText {
                    try insertHistoryLocked(
                        record: record,
                        createdAtMs: createdAtMs,
                        finalText: trimmedFinal,
                        charCount: charCount,
                        durationMs: durationMs
                    )
                    try pruneExcessHistoryLocked()
                }
                try upsertDailyStatsLocked(
                    dayKey: dayKey,
                    charCount: charCount,
                    durationMs: durationMs,
                    polished: polishedIncrement,
                    translated: translatedIncrement,
                    autoPasted: autoPastedIncrement
                )
                try upsertAppStatsLocked(
                    bundleIdentifier: record.bundleIdentifier,
                    charCount: charCount,
                    durationMs: durationMs,
                    lastUsedAtMs: createdAtMs
                )
            }
        }
        // 写入会（重新）创建 WAL / SHM 旁车文件，保持其权限与主库一致。
        applyPrivateFilePermissions()
    }

    /// 把用户输入的搜索词转成 `LIKE` 模式：`%`、`_`、`\` 按字面量匹配
    /// （SQL 中配合 `ESCAPE '\\'`），避免 "100%"、"a_b" 被当成通配符。
    static func likePattern(containing query: String) -> String {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    public func listRecords(
        query: String? = nil,
        actionKind: VoicePostProcessAction? = nil,
        limit: Int = 200,
        offset: Int = 0
    ) throws -> [VoiceHistoryRecord] {
        let boundedLimit = max(1, min(limit, 1_000))
        let boundedOffset = max(0, offset)
        let trimmedQuery = query?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveQuery = (trimmedQuery?.isEmpty == false)
            ? trimmedQuery
            : nil

        return try queue.sync {
            var clauses: [String] = []
            if effectiveQuery != nil {
                clauses.append(
                    "(final_text LIKE ? ESCAPE '\\' OR raw_text LIKE ? ESCAPE '\\' "
                        + "OR bundle_id LIKE ? ESCAPE '\\')"
                )
            }
            if actionKind != nil {
                clauses.append("action_kind = ?")
            }
            let whereClause = clauses.isEmpty
                ? ""
                : "WHERE " + clauses.joined(separator: " AND ")
            let sql = """
            SELECT id, created_at_ms, bundle_id, raw_text, final_text,
                   action_kind, polish_style, target_language,
                   duration_ms, auto_pasted
            FROM voice_history
            \(whereClause)
            ORDER BY created_at_ms DESC
            LIMIT ? OFFSET ?
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }

            var bindIndex: Int32 = 1
            if let q = effectiveQuery {
                let pattern = Self.likePattern(containing: q)
                try bindText(statement, index: bindIndex, value: pattern)
                bindIndex += 1
                try bindText(statement, index: bindIndex, value: pattern)
                bindIndex += 1
                try bindText(statement, index: bindIndex, value: pattern)
                bindIndex += 1
            }
            if let actionKind {
                try bindText(statement, index: bindIndex, value: actionKind.rawValue)
                bindIndex += 1
            }
            sqlite3_bind_int64(statement, bindIndex, Int64(boundedLimit))
            sqlite3_bind_int64(statement, bindIndex + 1, Int64(boundedOffset))

            var results: [VoiceHistoryRecord] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_ROW {
                    let idString = columnText(statement, index: 0) ?? ""
                    let id = UUID(uuidString: idString) ?? UUID()
                    let createdAtMs = sqlite3_column_int64(statement, 1)
                    let bundleID = columnText(statement, index: 2) ?? "unknown-client"
                    let rawText = columnText(statement, index: 3) ?? ""
                    let finalText = columnText(statement, index: 4) ?? ""
                    let actionRaw = columnText(statement, index: 5) ?? "dictation"
                    let action = VoicePostProcessAction(rawValue: actionRaw) ?? .dictation
                    let style = columnText(statement, index: 6)
                        .flatMap(VoicePolishStyle.init(rawValue:))
                    let language = columnText(statement, index: 7)
                        .flatMap(VoiceTranslationLanguage.init(rawValue:))
                    let durationMs = Int(sqlite3_column_int64(statement, 8))
                    let autoPasted = sqlite3_column_int64(statement, 9) != 0
                    results.append(VoiceHistoryRecord(
                        id: id,
                        createdAt: Date(
                            timeIntervalSince1970: Double(createdAtMs) / 1_000.0
                        ),
                        bundleIdentifier: bundleID,
                        rawText: rawText,
                        finalText: finalText,
                        actionKind: action,
                        polishStyle: style,
                        targetLanguage: language,
                        durationMilliseconds: durationMs,
                        autoPasted: autoPasted
                    ))
                } else if step == SQLITE_DONE {
                    break
                } else {
                    throw lastError(code: step)
                }
            }
            return results
        }
    }

    /// 删除一条历史记录。返回 `false` 表示该 id 不存在、未删除任何行。
    @discardableResult
    public func deleteRecord(id: UUID) throws -> Bool {
        try queue.sync {
            let statement = try prepare("DELETE FROM voice_history WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bindText(statement, index: 1, value: id.uuidString)
            let step = sqlite3_step(statement)
            guard step == SQLITE_DONE else {
                throw lastError(code: step)
            }
            // `sqlite3_step` 成功不代表删到了行：以实际受影响行数为准。
            return sqlite3_changes(database) > 0
        }
    }

    public func clearHistory() throws {
        try queue.sync {
            try transaction {
                try execute("DELETE FROM voice_history")
            }
            try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        applyPrivateFilePermissions()
    }

    public func resetUsageStatistics() throws {
        try queue.sync {
            try transaction {
                try execute("DELETE FROM voice_usage_daily")
                try execute("DELETE FROM voice_usage_apps")
            }
            try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        applyPrivateFilePermissions()
    }

    public func clearAll() throws {
        try queue.sync {
            try transaction {
                try execute("DELETE FROM voice_history")
                try execute("DELETE FROM voice_usage_daily")
                try execute("DELETE FROM voice_usage_apps")
            }
            try execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try execute("VACUUM")
        }
        applyPrivateFilePermissions()
    }

    public func exportHistoryJSONL(to destination: URL) throws {
        let records = try listRecords(limit: Self.maximumRetainedHistoryRecords)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var output = Data()
        for record in records {
            let line = try encoder.encode(record)
            output.append(line)
            output.append(0x0A)
        }
        do {
            try output.write(to: destination, options: .atomic)
        } catch {
            throw VoiceHistoryStoreError.fileSystem(error.localizedDescription)
        }
    }

    public func usageSummary(
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> VoiceUsageSummary {
        try queue.sync {
            let dailyRows = try loadAllDailyStatsLocked()
            let topApps = try loadTopAppsLocked(limit: 5)
            let historyCount = Int(
                try queryInt64("SELECT COUNT(*) FROM voice_history")
            )

            var totalSessions = 0
            var totalChars = 0
            var totalDuration = 0
            var polishedSessions = 0
            var translatedSessions = 0
            var autoPastedSessions = 0

            let todayKey = Self.dayKey(for: now, calendar: calendar)
            let recentKeys = Self.recentDayKeys(
                endingAt: now,
                days: 7,
                calendar: calendar
            )
            let recentKeySet = Set(recentKeys)

            var byDay: [String: VoiceDailyUsageStat] = [:]
            var activeDays = Set<String>()

            for row in dailyRows {
                totalSessions += row.sessionCount
                totalChars += row.characterCount
                totalDuration += row.durationMilliseconds
                polishedSessions += row.polishedCount
                translatedSessions += row.translatedCount
                autoPastedSessions += row.autoPastedCount
                byDay[row.dayKey] = row
                if row.sessionCount > 0 {
                    activeDays.insert(row.dayKey)
                }
            }

            let todayRow = byDay[todayKey]
            let last7Sessions = dailyRows
                .filter { recentKeySet.contains($0.dayKey) }
                .reduce(0) { $0 + $1.sessionCount }
            let last7Chars = dailyRows
                .filter { recentKeySet.contains($0.dayKey) }
                .reduce(0) { $0 + $1.characterCount }

            let dailyTrend = recentKeys.map { key in
                byDay[key] ?? VoiceDailyUsageStat(
                    dayKey: key,
                    sessionCount: 0,
                    characterCount: 0,
                    durationMilliseconds: 0,
                    polishedCount: 0,
                    translatedCount: 0,
                    autoPastedCount: 0
                )
            }

            let streak = Self.computeStreak(
                activeDays: activeDays,
                now: now,
                calendar: calendar
            )
            let dictationSessions = max(
                0,
                totalSessions - polishedSessions - translatedSessions
            )

            return VoiceUsageSummary(
                totalSessions: totalSessions,
                totalCharacters: totalChars,
                totalDurationMilliseconds: totalDuration,
                todaySessions: todayRow?.sessionCount ?? 0,
                todayCharacters: todayRow?.characterCount ?? 0,
                todayDurationMilliseconds: todayRow?.durationMilliseconds ?? 0,
                last7DaysSessions: last7Sessions,
                last7DaysCharacters: last7Chars,
                dictationSessions: dictationSessions,
                polishedSessions: polishedSessions,
                translatedSessions: translatedSessions,
                autoPastedSessions: autoPastedSessions,
                activeDayStreak: streak,
                historyRecordCount: historyCount,
                topApps: topApps,
                dailyTrend: dailyTrend
            )
        }
    }

    // MARK: - Day Key & Streak Helpers

    static func dayKey(
        for date: Date,
        calendar: Calendar = .current
    ) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func recentDayKeys(
        endingAt date: Date,
        days: Int,
        calendar: Calendar = .current
    ) -> [String] {
        guard days > 0 else { return [] }
        return (0 ..< days).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: date)
                .map { dayKey(for: $0, calendar: calendar) }
        }
    }

    static func computeStreak(
        activeDays: Set<String>,
        now: Date,
        calendar: Calendar = .current
    ) -> Int {
        guard !activeDays.isEmpty else { return 0 }
        let todayKey = dayKey(for: now, calendar: calendar)
        var cursor: Date
        if activeDays.contains(todayKey) {
            cursor = now
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  activeDays.contains(dayKey(for: yesterday, calendar: calendar))
        {
            cursor = yesterday
        } else {
            return 0
        }
        var streak = 0
        while activeDays.contains(dayKey(for: cursor, calendar: calendar)) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor)
            else {
                break
            }
            cursor = previous
        }
        return streak
    }

    // MARK: - SQLite Internals

    private func configureDatabase() throws {
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA secure_delete=ON")
        try execute("PRAGMA busy_timeout=1000")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS voice_history (
                id TEXT PRIMARY KEY NOT NULL,
                created_at_ms INTEGER NOT NULL,
                bundle_id TEXT NOT NULL,
                raw_text TEXT NOT NULL,
                final_text TEXT NOT NULL,
                action_kind TEXT NOT NULL,
                polish_style TEXT,
                target_language TEXT,
                duration_ms INTEGER NOT NULL DEFAULT 0,
                character_count INTEGER NOT NULL DEFAULT 0,
                auto_pasted INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS voice_history_time
            ON voice_history(created_at_ms DESC)
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS voice_usage_daily (
                day_key TEXT PRIMARY KEY NOT NULL,
                session_count INTEGER NOT NULL DEFAULT 0,
                character_count INTEGER NOT NULL DEFAULT 0,
                duration_ms INTEGER NOT NULL DEFAULT 0,
                polished_count INTEGER NOT NULL DEFAULT 0,
                translated_count INTEGER NOT NULL DEFAULT 0,
                auto_pasted_count INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS voice_usage_apps (
                bundle_id TEXT PRIMARY KEY NOT NULL,
                session_count INTEGER NOT NULL DEFAULT 0,
                character_count INTEGER NOT NULL DEFAULT 0,
                duration_ms INTEGER NOT NULL DEFAULT 0,
                last_used_at_ms INTEGER NOT NULL DEFAULT 0
            )
            """
        )
    }

    private func insertHistoryLocked(
        record: VoiceHistoryRecord,
        createdAtMs: Int64,
        finalText: String,
        charCount: Int64,
        durationMs: Int64
    ) throws {
        let sql = """
        INSERT INTO voice_history (
            id, created_at_ms, bundle_id, raw_text, final_text,
            action_kind, polish_style, target_language,
            duration_ms, character_count, auto_pasted
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: record.id.uuidString)
        sqlite3_bind_int64(statement, 2, createdAtMs)
        try bindText(statement, index: 3, value: record.bundleIdentifier)
        try bindText(statement, index: 4, value: record.rawText)
        try bindText(statement, index: 5, value: finalText)
        try bindText(statement, index: 6, value: record.actionKind.rawValue)
        if let style = record.polishStyle {
            try bindText(statement, index: 7, value: style.rawValue)
        } else {
            sqlite3_bind_null(statement, 7)
        }
        if let lang = record.targetLanguage {
            try bindText(statement, index: 8, value: lang.rawValue)
        } else {
            sqlite3_bind_null(statement, 8)
        }
        sqlite3_bind_int64(statement, 9, durationMs)
        sqlite3_bind_int64(statement, 10, charCount)
        sqlite3_bind_int64(statement, 11, record.autoPasted ? 1 : 0)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE else {
            throw lastError(code: step)
        }
    }

    private func pruneExcessHistoryLocked() throws {
        let sql = """
        DELETE FROM voice_history
        WHERE id IN (
            SELECT id FROM voice_history
            ORDER BY created_at_ms DESC
            LIMIT -1 OFFSET \(Self.maximumRetainedHistoryRecords)
        )
        """
        try execute(sql)
    }

    private func upsertDailyStatsLocked(
        dayKey: String,
        charCount: Int64,
        durationMs: Int64,
        polished: Int64,
        translated: Int64,
        autoPasted: Int64
    ) throws {
        let sql = """
        INSERT INTO voice_usage_daily (
            day_key, session_count, character_count, duration_ms,
            polished_count, translated_count, auto_pasted_count
        ) VALUES (?, 1, ?, ?, ?, ?, ?)
        ON CONFLICT(day_key) DO UPDATE SET
            session_count = session_count + 1,
            character_count = character_count + excluded.character_count,
            duration_ms = duration_ms + excluded.duration_ms,
            polished_count = polished_count + excluded.polished_count,
            translated_count = translated_count + excluded.translated_count,
            auto_pasted_count = auto_pasted_count + excluded.auto_pasted_count
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: dayKey)
        sqlite3_bind_int64(statement, 2, charCount)
        sqlite3_bind_int64(statement, 3, durationMs)
        sqlite3_bind_int64(statement, 4, polished)
        sqlite3_bind_int64(statement, 5, translated)
        sqlite3_bind_int64(statement, 6, autoPasted)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE else {
            throw lastError(code: step)
        }
    }

    private func upsertAppStatsLocked(
        bundleIdentifier: String,
        charCount: Int64,
        durationMs: Int64,
        lastUsedAtMs: Int64
    ) throws {
        let sql = """
        INSERT INTO voice_usage_apps (
            bundle_id, session_count, character_count, duration_ms, last_used_at_ms
        ) VALUES (?, 1, ?, ?, ?)
        ON CONFLICT(bundle_id) DO UPDATE SET
            session_count = session_count + 1,
            character_count = character_count + excluded.character_count,
            duration_ms = duration_ms + excluded.duration_ms,
            last_used_at_ms = MAX(last_used_at_ms, excluded.last_used_at_ms)
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, index: 1, value: bundleIdentifier)
        sqlite3_bind_int64(statement, 2, charCount)
        sqlite3_bind_int64(statement, 3, durationMs)
        sqlite3_bind_int64(statement, 4, lastUsedAtMs)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE else {
            throw lastError(code: step)
        }
    }

    private func loadAllDailyStatsLocked() throws -> [VoiceDailyUsageStat] {
        let sql = """
        SELECT day_key, session_count, character_count, duration_ms,
               polished_count, translated_count, auto_pasted_count
        FROM voice_usage_daily
        ORDER BY day_key ASC
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var rows: [VoiceDailyUsageStat] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                rows.append(VoiceDailyUsageStat(
                    dayKey: columnText(statement, index: 0) ?? "",
                    sessionCount: Int(sqlite3_column_int64(statement, 1)),
                    characterCount: Int(sqlite3_column_int64(statement, 2)),
                    durationMilliseconds: Int(sqlite3_column_int64(statement, 3)),
                    polishedCount: Int(sqlite3_column_int64(statement, 4)),
                    translatedCount: Int(sqlite3_column_int64(statement, 5)),
                    autoPastedCount: Int(sqlite3_column_int64(statement, 6))
                ))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw lastError(code: step)
            }
        }
        return rows
    }

    private func loadTopAppsLocked(limit: Int) throws -> [VoiceAppUsageStat] {
        let sql = """
        SELECT bundle_id, session_count, character_count, duration_ms
        FROM voice_usage_apps
        ORDER BY character_count DESC, session_count DESC
        LIMIT ?
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(max(1, limit)))
        var rows: [VoiceAppUsageStat] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                rows.append(VoiceAppUsageStat(
                    bundleIdentifier: columnText(statement, index: 0) ?? "unknown",
                    sessionCount: Int(sqlite3_column_int64(statement, 1)),
                    characterCount: Int(sqlite3_column_int64(statement, 2)),
                    durationMilliseconds: Int(sqlite3_column_int64(statement, 3))
                ))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw lastError(code: step)
            }
        }
        return rows
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else {
            throw VoiceHistoryStoreError.sqlite(
                code: SQLITE_MISUSE,
                message: "database closed"
            )
        }
        let status = sqlite3_exec(database, sql, nil, nil, nil)
        guard status == SQLITE_OK else {
            throw lastError(code: status)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else {
            throw VoiceHistoryStoreError.sqlite(
                code: SQLITE_MISUSE,
                message: "database closed"
            )
        }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw lastError(code: status)
        }
        return statement
    }

    private func queryInt64(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            throw lastError(code: step)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func bindText(
        _ statement: OpaquePointer,
        index: Int32,
        value: String
    ) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status = value.withCString { cString in
            sqlite3_bind_text(statement, index, cString, -1, transient)
        }
        guard status == SQLITE_OK else {
            throw lastError(code: status)
        }
    }

    private func columnText(
        _ statement: OpaquePointer,
        index: Int32
    ) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: raw)
    }

    private func lastError(code: Int32) -> VoiceHistoryStoreError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "sqlite error"
        return .sqlite(code: code, message: message)
    }
}
