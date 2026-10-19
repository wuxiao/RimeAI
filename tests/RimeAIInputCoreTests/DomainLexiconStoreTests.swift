import Foundation
import Testing
@testable import RimeAIInputCore

@Suite("Domain lexicon store (schema v2)")
struct DomainLexiconStoreTests {
    private func makeStore() throws -> (
        DomainLexiconStore, PhraseBookStore, URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RimeAI-LexiconTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let database = directory.appendingPathComponent("phrasebook.sqlite3")
        // PhraseBookStore first: it owns the schema version bump; the
        // lexicon store then proves it can open the same file standalone.
        let phraseStore = try PhraseBookStore(databaseURL: database)
        let lexiconStore = try DomainLexiconStore(databaseURL: database)
        return (lexiconStore, phraseStore, directory)
    }

    private static let medicalYAML = """
        ---
        name: medical-test
        version: "2"
        ...
        # 一词多行 = 多音字
        冠心病\tguan xin bing\t100
        心律失常\txin lv shi chang\t99%
        冠心病\tguan xin bing\t90
        克罗恩病\tke luo en bing
        不好行\thuai hang
        """

    @Test("install parses dict.yaml, dedupes and clamps weights")
    func installParsesAndDedupes() throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try store.installDictYaml(
            Self.medicalYAML,
            domain: "medical"
        )
        #expect(result.lexicon.id == "medical-test")
        #expect(result.lexicon.domain == "medical")
        #expect(result.lexicon.version == "2")
        #expect(result.insertedEntries == 4)
        // Duplicate (text, pinyin) row merged, not duplicated.
        #expect(!result.replacedPrevious)

        let entries = try store.entries(lexiconId: "medical-test")
        #expect(entries.count == 4)
        let guanxinning = entries.first { $0.text == "冠心病" }
        #expect(guanxinning?.pinyinKeys == "guanxinbing")
        // Rime weight 100 maps to 10 (w/10, clamped 1–99); the dupe's
        // 90 loses to the stronger row.
        #expect(guanxinning?.weight == 10)
        // 99% percent-suffix form maps to 9.
        let arrhythmia = entries.first { $0.text == "心律失常" }
        #expect(arrhythmia?.weight == 9)
        // Missing weight falls back to the default of 50 → clamp keeps 9
        // for explicit small weights: ke luo en bing has no weight column.
        let crohn = entries.first { $0.text == "克罗恩病" }
        #expect(crohn?.weight == 50)
    }

    @Test("multi-reading homographs survive as distinct rows")
    func multiReadingHomographs() throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.installDictYaml(
            """
            ---
            name: polyphone
            ...
            重载\tzhong zai\t80
            重载\tchong zai\t60
            """,
            domain: "global"
        )
        let entries = try store.entries(lexiconId: "polyphone")
        #expect(entries.count == 2)
        #expect(
            Set(entries.map(\.pinyinKeys))
                == Set(["zhongzai", "chongzai"])
        )
    }

    @Test("reinstall replaces rows wholesale and reports it")
    func reinstallReplaces() throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.installDictYaml(
            """
            ---
            name: replace-me
            ...
            旧词\tjiu ci\t10
            """,
            domain: "global"
        )
        let second = try store.installDictYaml(
            """
            ---
            name: replace-me
            version: "2"
            ...
            新词\txin ci\t20
            """,
            domain: "global"
        )
        #expect(second.replacedPrevious)
        #expect(second.insertedEntries == 1)
        let entries = try store.entries(lexiconId: "replace-me")
        #expect(entries.map(\.text) == ["新词"])
        #expect(try store.lexicons().first?.version == "2")
    }

    @Test("enable/disable gates the fusion snapshot; block gates entries")
    func lifecycleAndCuration() throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.installDictYaml(
            Self.medicalYAML,
            domain: "medical"
        )

        // Fusion snapshot sees all four entries while enabled.
        var snapshot = try store.snapshotEntries(limit: 100)
        #expect(snapshot.count == 4)
        #expect(snapshot.allSatisfy { $0.source == .lexicon })
        #expect(snapshot.allSatisfy { $0.domain == "medical" })

        // Blocking is cross-reading: both 冠心病 rows disappear.
        _ = try store.setEntryBlocked(
            lexiconId: "medical-test",
            text: "冠心病",
            isBlocked: true
        )
        snapshot = try store.snapshotEntries(limit: 100)
        #expect(snapshot.count == 3)
        #expect(!snapshot.contains { $0.text == "冠心病" })

        // Disabled lexicons contribute nothing.
        _ = try store.setEnabled(id: "medical-test", isEnabled: false)
        #expect(try store.snapshotEntries(limit: 100).isEmpty)

        _ = try store.setEnabled(id: "medical-test", isEnabled: true)
        // Unknown id flips nothing.
        #expect(
            !(try store.setEnabled(id: "ghost", isEnabled: true))
        )

        // Uninstall drops rows; second uninstall reports false.
        #expect(try store.uninstall(id: "medical-test"))
        #expect(!(try store.uninstall(id: "medical-test")))
        #expect(try store.lexicons().isEmpty)
    }

    @Test("renameDomain migrates lexicon mounts alongside phrases")
    func renameDomainMigratesLexicons() throws {
        let (lexiconStore, phraseStore, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try lexiconStore.installDictYaml(
            Self.medicalYAML,
            domain: "medical"
        )
        _ = try phraseStore.renameDomain(from: "medical", to: "clinic")
        let lexicons = try lexiconStore.lexicons()
        #expect(lexicons.first?.domain == "clinic")
        // Fusion snapshot now answers on the renamed domain.
        let snapshot = try lexiconStore.snapshotEntries(limit: 100)
        #expect(snapshot.allSatisfy { $0.domain == "clinic" })
    }

    @Test("schema v1 databases upgrade in place without data loss")
    func v1UpgradeKeepsLearnedPhrases() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RimeAI-LexiconMigrate-\(UUID().uuidString)",
                isDirectory: true
            )
        let database = directory.appendingPathComponent("phrasebook.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Simulate a v1 database: learned phrase present, version 1.
        let legacy = try PhraseBookStore(databaseURL: database)
        try legacy.addUserPhrase(
            text: "老短语",
            pinyinKeys: "laoduanayu".replacingOccurrences(
                of: "y", with: "yu"
            )
        )
        try legacy.execute("PRAGMA user_version=1")

        // Opening through either store upgrades DDL idempotently…
        let lexiconStore = try DomainLexiconStore(databaseURL: database)
        try lexiconStore.installDictYaml(
            Self.medicalYAML,
            domain: "global"
        )
        // …and the learned phrase survives.
        let reopened = try PhraseBookStore(databaseURL: database)
        let learned = try reopened.phrases(matchingPinyin: "laoduan")
        #expect(learned.first?.text == "老短语")
    }

    @Test("invalid dictionaries and domains are rejected")
    func rejectsInvalidInput() throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: DomainLexiconError.emptyDictionary) {
            try store.installDictYaml("not a dictionary", domain: "global")
        }
        #expect(throws: DomainLexiconError.emptyDictionary) {
            try store.installDictYaml(
                "---\nname: x\n...\n",
                domain: "global"
            )
        }
        #expect(throws: DomainLexiconError.invalidDomain) {
            try store.installDictYaml(
                Self.medicalYAML,
                domain: "Not A Domain"
            )
        }
    }
}

@Suite("Rime dict.yaml parser")
struct RimeDictYamlParserTests {
    @Test("pinyin normalization covers ü, combining diaeresis and case")
    func pinyinNormalization() {
        #expect(
            RimeDictYamlParser.normalizedPinyinKeys("Lü Xian")
                == "lvxian"
        )
        #expect(
            RimeDictYamlParser.normalizedPinyinKeys("lü xian") == "lvxian"
        )
        #expect(
            RimeDictYamlParser.normalizedPinyinKeys("nü") == "nv"
        )
        #expect(
            RimeDictYamlParser.normalizedPinyinKeys(
                "u\u{0308}"
            ) == "v"
        )
        #expect(
            RimeDictYamlParser.normalizedPinyinKeys("GUAN XIN") == "guanxin"
        )
        #expect(RimeDictYamlParser.normalizedPinyinKeys("") == nil)
        #expect(RimeDictYamlParser.normalizedPinyinKeys("好啊1") == nil)
        #expect(RimeDictYamlParser.normalizedPinyinKeys("zhōng") == nil)
    }

    @Test("weights accept plain, percent and clamp to 1–99")
    func weightNormalization() {
        #expect(RimeDictYamlParser.normalizedWeight("100") == 10)
        #expect(RimeDictYamlParser.normalizedWeight("100%") == 10)
        #expect(RimeDictYamlParser.normalizedWeight("999") == 99)
        #expect(RimeDictYamlParser.normalizedWeight("5") == 1)
        #expect(RimeDictYamlParser.normalizedWeight("x") == nil)
        #expect(RimeDictYamlParser.normalizedWeight("0") == nil)
    }

    @Test("identifier normalization mirrors domain rules")
    func identifierNormalization() {
        #expect(
            RimeDictYamlParser.normalizedIdentifier("IT 编程")
                == "it"
        )
        #expect(
            RimeDictYamlParser.normalizedIdentifier("Medical_Test-2")
                == "medical-test-2"
        )
        #expect(RimeDictYamlParser.normalizedIdentifier(nil) == "")
    }

    @Test("malformed rows are counted, not fatal")
    func rejectionsAreReported() throws {
        let parsed = try RimeDictYamlParser.parse(
            """
            ---
            name: broken
            ...
            好词\thao ci\t30
            没有拼音的词
            声调词\thǎo cí
            # 注释行
            """
        )
        #expect(parsed.identifier == "broken")
        #expect(parsed.entries.count == 1)
        #expect(parsed.rejectedLineCount == 2)
        #expect(parsed.rejectedLines.count == 2)
        #expect(parsed.rejectedLines.first?.reason.contains("拼音") == true)
    }

    @Test("documents without the header-end marker are rejected")
    func rejectsHeaderOnlyDocuments() {
        #expect(
            (try? RimeDictYamlParser.parse("---\nname: x\n"))
                == nil
        )
        #expect((try? RimeDictYamlParser.parse("")) == nil)
    }
}
