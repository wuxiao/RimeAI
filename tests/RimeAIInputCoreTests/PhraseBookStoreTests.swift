import Foundation
import Testing
@testable import RimeAIInputCore

@Suite("L1 phrasebook storage (LP-002/LP-007)")
struct PhraseBookStoreTests {
    private func makeStore() throws -> (PhraseBookStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RimeAI-PhraseBookTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let database = directory.appendingPathComponent("phrasebook.sqlite3")
        return (
            try PhraseBookStore(databaseURL: database),
            directory
        )
    }

    @Test("user phrases surface via exact and prefix pinyin lookup")
    func lookupOrdering() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.addUserPhrase(
            text: "这个API需要加timeout配置",
            pinyinKeys: "zhegeAPIxuyaojiatimeoutpeizhi",
            domain: "global"
        )
        try store.recordAutoPhrase(
            text: "这个安排",
            pinyinKeys: "zhegeanpai",
            domain: "global"
        )
        try store.recordAutoPhrase(
            text: "这个安排",
            pinyinKeys: "zhegeanpai",
            domain: "global"
        )

        let exact = try store.phrases(matchingPinyin: "zhegeanpai")
        #expect(exact.first?.text == "这个安排")
        #expect(exact.first?.count == 2)

        let prefix = try store.phrases(matchingPinyin: "zhege")
        #expect(prefix.map(\.text).contains("这个API需要加timeout配置"))
        // Exact matches outrank prefix matches.
        #expect(prefix.first?.text == "这个安排")

        let miss = try store.phrases(matchingPinyin: "bucunzai")
        #expect(miss.isEmpty)
    }

    @Test("reinforcing an existing phrase returns the stored row")
    func reinforcedUpsertReturnsStoredRow() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try store.addUserPhrase(
            text: "这个安排",
            pinyinKeys: "zhegeanpai"
        )
        #expect(first.count == 1)
        #expect(first.isProtected)

        // Reinforcement (auto-learned hit on an existing user phrase)
        // must report the stored row: incremented count, upgraded
        // protection and the original source, not the insert snapshot.
        try store.recordAutoPhrase(
            text: "这个安排",
            pinyinKeys: "zhegeanpai",
            domain: "global",
            at: Date(timeIntervalSince1970: 1_000)
        )
        let reinforced = try store.phrases(matchingPinyin: "zhegeanpai")
        #expect(reinforced.first?.count == 2)
        #expect(reinforced.first?.isProtected == true)
        #expect(reinforced.first?.source == .user)
        // ... and addUserPhrase's returned entry reflects the same row.
        let again = try store.addUserPhrase(
            text: "这个安排",
            pinyinKeys: "zhegeanpai"
        )
        #expect(again.count == 3)
        #expect(again.isProtected)
        #expect(again.source == .user)
    }

    @Test("domain hits outrank global with equal scores")
    func domainPriority() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.addUserPhrase(
            text: "接口设计",
            pinyinKeys: "jiekousheji",
            domain: "global"
        )
        try store.recordAutoPhrase(
            text: "接口实现",
            pinyinKeys: "jiekoushixian",
            domain: "work"
        )

        let domainHits = try store.phrases(
            matchingPinyin: "jiekou",
            domain: "work"
        )
        #expect(domainHits.map(\.text) == ["接口实现", "接口设计"])

        let globalHits = try store.phrases(matchingPinyin: "jiekou")
        #expect(globalHits.map(\.text) == ["接口设计"])
    }

    @Test("protect and delete manage entry lifecycle")
    func lifecycle() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = try store.addUserPhrase(
            text: "口头禅",
            pinyinKeys: "koutouchan"
        )
        #expect(entry.isProtected)
        #expect(entry.source == .user)

        #expect(try store.setProtected(id: entry.id, isProtected: false))
        #expect(
            try store.entries().first?.isProtected == false
        )

        #expect(try store.delete(id: entry.id))
        #expect(try store.entries().isEmpty)
        #expect(!(try store.delete(id: entry.id)))
    }

    @Test("bundle mappings resolve with global fallback")
    func domainMapping() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try store.domain(for: "com.example.Anything") == "global")

        try store.setDomainMapping(
            bundleIdentifier: "com.example.Chat",
            domain: "chat"
        )
        #expect(try store.domain(for: "com.example.Chat") == "chat")
        #expect(try store.domainMappings() == [
            PhraseDomainMapping(
                bundleIdentifier: "com.example.Chat",
                domain: "chat"
            )
        ])

        try store.setDomainMapping(
            bundleIdentifier: "com.example.Chat",
            domain: "casual"
        )
        #expect(try store.domain(for: "com.example.Chat") == "casual")

        #expect(try store.removeDomainMapping(bundleIdentifier: "com.example.Chat"))
        #expect(try store.domain(for: "com.example.Chat") == "global")
    }

    @Test("renameDomain moves phrases, merges counts and mappings")
    func renameMerges() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.recordAutoPhrase(text: "口径", pinyinKeys: "koujing", domain: "a")
        try store.recordAutoPhrase(text: "口径", pinyinKeys: "koujing", domain: "b")
        try store.recordAutoPhrase(text: "口径", pinyinKeys: "koujing", domain: "b")
        try store.recordAutoPhrase(text: "独有", pinyinKeys: "duyou", domain: "b")
        try store.setDomainMapping(bundleIdentifier: "com.example.B", domain: "b")

        let moved = try store.renameDomain(from: "b", to: "a")
        #expect(moved == 1)

        let merged = try store.entries(domain: "a")
        let koujing = merged.first { $0.text == "口径" }
        #expect(koujing?.count == 3)
        #expect(merged.contains { $0.text == "独有" })
        #expect(try store.entries(domain: "b").isEmpty)
        #expect(try store.domain(for: "com.example.B") == "a")
    }

    @Test("deleteDomain folds phrases back into global")
    func deleteFolds() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.recordAutoPhrase(text: "行话", pinyinKeys: "hanghua", domain: "work")
        try store.setDomainMapping(bundleIdentifier: "com.example.Work", domain: "work")

        #expect(try store.deleteDomain("work") == 1)
        #expect(try store.entries(domain: "global").count == 1)
        #expect(try store.domain(for: "com.example.Work") == "global")
    }

    @Test("adoptUserTokens is idempotent and protects entries")
    func tokenMigration() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try store.adoptUserTokens(["kubernetes", "CRD"])
        #expect(first == 2)
        let second = try store.adoptUserTokens(["kubernetes", "CRD"])
        #expect(second == 0)

        let entries = try store.entries()
        #expect(entries.count == 2)
        let allProtected = entries.allSatisfy { $0.isProtected }
        let allUser = entries.allSatisfy { $0.source == .user }
        #expect(allProtected)
        #expect(allUser)
        #expect(
            try store.phrases(matchingPinyin: "kubernetes")
                .map(\.text) == ["kubernetes"]
        )
    }

    @Test("clearAll wipes artifacts and bumps generation")
    func clearAll() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.addUserPhrase(text: "临时", pinyinKeys: "linshi")
        #expect(try store.statistics().generation == 0)

        let generation = try store.clearAll()
        #expect(generation == 1)
        #expect(try store.entries().isEmpty)
        #expect(
            try store.statistics()
                == PhraseBookStatistics(
                    entryCount: 0,
                    protectedCount: 0,
                    domains: [],
                    generation: 1
                )
        )
    }

    @Test("exportJSON serializes entries and mappings")
    func export() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.addUserPhrase(text: "导出", pinyinKeys: "daochu")
        try store.setDomainMapping(bundleIdentifier: "com.example.X", domain: "x")

        let destination = directory.appendingPathComponent("export.json")
        try store.exportJSON(to: destination)
        let payload = try String(
            contentsOf: destination,
            encoding: .utf8
        )
        #expect(payload.contains("导出"))
        #expect(payload.contains("com.example.X"))
    }

    @Test("invalid phrases and domains are rejected")
    func validation() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: PhraseBookError.invalidPhrase.self) {
            try store.addUserPhrase(text: "", pinyinKeys: "kong")
        }
        #expect(throws: PhraseBookError.invalidDomain.self) {
            try store.addUserPhrase(
                text: "词",
                pinyinKeys: "ci",
                domain: "Not Valid!"
            )
        }
        #expect(throws: PhraseBookError.invalidDomain.self) {
            try store.setDomainMapping(
                bundleIdentifier: "com.example.X",
                domain: String(repeating: "x", count: 65)
            )
        }
        // Empty domain normalizes to global instead of throwing.
        let entry = try store.addUserPhrase(
            text: "默认域",
            pinyinKeys: "morenyu",
            domain: "  "
        )
        #expect(entry.domain == PhraseBookDomain.global)
    }

    @Test("english tokens feed the mixed-composition resolver")
    func englishTokenLookup() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<5 {
            try store.recordAutoPhrase(
                text: "iphone",
                pinyinKeys: "iphone",
                domain: "global"
            )
        }
        try store.recordAutoPhrase(
            text: "kubernetes",
            pinyinKeys: "kubernetes",
            domain: "work"
        )
        // Mixed-language and Chinese-only phrases never qualify.
        try store.recordAutoPhrase(
            text: "这个API需要加timeout配置",
            pinyinKeys: "zhegeapixuyaojiatimeoutpeizhi",
            domain: "global"
        )
        try store.recordAutoPhrase(
            text: "这个安排",
            pinyinKeys: "zhegeanpai",
            domain: "global"
        )

        let tokens = try store.englishTokens()
        #expect(tokens.first == "iphone")
        #expect(tokens.contains("kubernetes"))
        #expect(!tokens.contains { text in
            text.contains { !$0.isASCII }
        })

        let limited = try store.englishTokens(limit: 1)
        #expect(limited == ["iphone"])
    }
}
