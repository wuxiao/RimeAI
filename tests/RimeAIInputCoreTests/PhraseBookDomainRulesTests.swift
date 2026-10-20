import Foundation
import Testing
@testable import RimeAIInputCore

/// Domain-name rules and the repair path for domains written under the
/// old, looser character set.
@Suite("domain naming rules and legacy domain migration")
struct PhraseBookDomainRulesTests {
    @Test("legacy domain names with underscores are migrated on open")
    func legacyDomainNamesAreMigrated() throws {
        // `_` 曾经是合法域名字符。规则收紧后，这类域名下的学习行再也
        // 无法在设置页触达（孤儿数据）：开库时把 `_` 折成 `-` 并重算
        // 内容寻址 id。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RimeAI-PhraseBookLegacy-\(UUID().uuidString)",
                isDirectory: true
            )
        let database = directory.appendingPathComponent("phrasebook.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try PhraseBookStore(databaseURL: database)
        // 绕过校验直接写入旧域名行（模拟旧版本库）。
        try store.execute(
            """
            INSERT INTO phrasebook_entries(
                id, domain, text, pinyin_keys, count,
                first_seen_ms, last_used_ms, source, protected
            ) VALUES(
                'legacy-id', 'work_chat', '旧域短语', 'jiuduan', 3,
                1, 2, 'auto', 0
            )
            """
        )

        // 重新开库 → init 里的迁移把旧域名折成连字符形式。
        let reopened = try PhraseBookStore(databaseURL: database)
        let migrated = try reopened.entries(domain: "work-chat")
        #expect(migrated.count == 1)
        #expect(migrated.first?.text == "旧域短语")
        #expect(
            migrated.first?.id
                == PhraseBookStore.entryIdentifier(
                    domain: "work-chat",
                    text: "旧域短语"
                )
        )
        // 旧域名下不再有残留行（全量扫描，不限 global）。
        #expect(
            try reopened.entries(limit: 100).allSatisfy {
                $0.domain != "work_chat"
            }
        )
    }

    @Test("PhraseBookDomain.validate is the single rule entry point")
    func domainValidationEntryPoint() throws {
        #expect(try PhraseBookDomain.validate("Work-Chat") == "work-chat")
        #expect(throws: PhraseBookError.invalidDomain.self) {
            try PhraseBookDomain.validate("")
        }
        #expect(throws: PhraseBookError.invalidDomain.self) {
            try PhraseBookDomain.validate("work_chat")
        }
        #expect(throws: PhraseBookError.invalidDomain.self) {
            try PhraseBookDomain.validate("中文域")
        }
        // normalize 把空域解析为 global，validate 不接受空域。
        #expect(
            try PhraseBookDomain.normalize("  ") == PhraseBookDomain.global
        )
    }
}
