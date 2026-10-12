import Foundation
import SQLite3

extension HistoryStore {
    public func recentText(maxCharacters: Int = 600) throws -> String {
        guard maxCharacters > 0 else {
            return ""
        }
        return try queue.sync {
            try recentTextLocked(maxCharacters: maxCharacters)
        }
    }

    public func relevantSnippets(
        query rawQuery: String,
        maximumCount: Int = 8
    ) throws -> [CloudHistorySnippet] {
        let query = rawQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty, maximumCount > 0 else {
            return []
        }
        return try queue.sync {
            try relevantSnippetsLocked(
                query: query,
                maximumCount: maximumCount
            )
        }
    }

    public func contextSnapshot(
        query rawQuery: String,
        maxRecentCharacters: Int = 600,
        maximumSnippetCount: Int = 8
    ) throws -> HistoryContextSnapshot {
        let query = rawQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return try queue.sync {
            let generation = try queryInt64(
                "SELECT generation FROM history_metadata WHERE id = 1"
            )
            let recent = maxRecentCharacters > 0
                ? try recentTextLocked(
                    maxCharacters: min(maxRecentCharacters, 600)
                )
                : ""
            let snippets = !query.isEmpty && maximumSnippetCount > 0
                ? try relevantSnippetsLocked(
                    query: query,
                    maximumCount: min(maximumSnippetCount, 8)
                )
                : []
            return HistoryContextSnapshot(
                recentText: recent,
                relevantSnippets: snippets,
                generation: generation
            )
        }
    }

    func recentTextLocked(maxCharacters: Int) throws -> String {
        // raw_pinyin 记录的是回车把未转换的拼音原样上屏：技术上算提了
        // 交，但不是用户确认的中文信息，不能作为上下文带给模型。记录
        // 本身保留（审计/导出），只在读取侧排除。
        let statement = try prepare(
            """
            SELECT committed_text
            FROM history_commits
            WHERE source != 'raw_pinyin'
            ORDER BY committed_at_ms DESC, rowid DESC
            LIMIT 4096
            """
        )
        defer { sqlite3_finalize(statement) }
        var newestFirst: [String] = []
        var characterCount = 0
        while sqlite3_step(statement) == SQLITE_ROW,
              characterCount < maxCharacters
        {
            let value = columnText(statement, index: 0)
            newestFirst.append(value)
            characterCount += value.count
        }
        return String(
            newestFirst.reversed().joined().suffix(maxCharacters)
        )
    }

    private func relevantSnippetsUsingLike(
        query: String,
        maximumCount: Int
    ) throws -> [CloudHistorySnippet] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let statement = try prepare(
            """
            SELECT id, committed_text, bundle_id, committed_at_ms, 1.0
            FROM history_commits
            WHERE (committed_text LIKE ? ESCAPE '\\'
               OR pinyin LIKE ? ESCAPE '\\')
              AND source != 'raw_pinyin'
            ORDER BY committed_at_ms DESC
            LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind("%\(escaped)%", to: statement, index: 1)
        try bind("%\(escaped)%", to: statement, index: 2)
        sqlite3_bind_int(statement, 3, Int32(maximumCount))
        return try readSnippets(statement)
    }

    func relevantSnippetsLocked(
        query: String,
        maximumCount: Int
    ) throws -> [CloudHistorySnippet] {
        let limit = min(max(maximumCount, 1), 8)
        do {
            let ftsQuery = "\""
                + query.replacingOccurrences(of: "\"", with: "\"\"")
                + "\""
            let statement = try prepare(
                """
                SELECT c.id, c.committed_text, c.bundle_id,
                       c.committed_at_ms, bm25(history_fts)
                FROM history_fts
                JOIN history_commits c
                  ON c.id = history_fts.commit_id
                WHERE history_fts MATCH ?
                  AND c.source != 'raw_pinyin'
                ORDER BY bm25(history_fts), c.committed_at_ms DESC
                LIMIT ?
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(ftsQuery, to: statement, index: 1)
            sqlite3_bind_int(statement, 2, Int32(limit))
            return try readSnippets(statement)
        } catch {
            return try relevantSnippetsUsingLike(
                query: query,
                maximumCount: limit
            )
        }
    }

    private func readSnippets(
        _ statement: OpaquePointer
    ) throws -> [CloudHistorySnippet] {
        var values: [CloudHistorySnippet] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                break
            }
            guard status == SQLITE_ROW else {
                throw currentSQLiteError(code: status)
            }
            let rawScore = sqlite3_column_double(statement, 4)
            let score = rawScore.isFinite
                ? 1 / (1 + abs(rawScore))
                : 0
            values.append(
                CloudHistorySnippet(
                    id: columnText(statement, index: 0),
                    text: columnText(statement, index: 1),
                    bundleIdentifier: columnText(statement, index: 2),
                    committedAtMilliseconds: sqlite3_column_int64(
                        statement,
                        3
                    ),
                    score: score
                )
            )
        }
        return values
    }
}
