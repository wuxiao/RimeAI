import Foundation
import Testing
@testable import RimeAIInputCore

@Suite("Voice opt-in settings and learned correction recency")
struct VoiceSettingsOptInAndLearnedCorrectionTests {
    private func makeStore() -> (RimeAISettingsStore, UserDefaults) {
        let suiteName = "VoiceSettingsOptInTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (RimeAISettingsStore(defaults: defaults), defaults)
    }

    // MARK: - Opt-in settings

    @Test("cloud hotwords and AX fallback read are independent opt-ins, off by default")
    func optInDefaultsAndSetters() {
        let (store, defaults) = makeStore()
        #expect(!store.voiceCloudHotwordsEnabled)
        #expect(!store.voiceAXFallbackReadEnabled)
        // 既有语音体验开关的默认值保持不变。
        #expect(store.voiceAutoPasteEnabled)
        #expect(store.voiceHistoryEnabled)
        #expect(store.voiceMuteSystemAudioEnabled)
        #expect(store.voiceAutoLearnCorrectionsEnabled)

        store.setVoiceCloudHotwordsEnabled(true)
        #expect(store.voiceCloudHotwordsEnabled)
        #expect(!store.voiceAXFallbackReadEnabled)
        store.voiceAXFallbackReadEnabled = true
        #expect(store.voiceAXFallbackReadEnabled)

        let reloaded = RimeAISettingsStore(defaults: defaults)
        #expect(reloaded.voiceCloudHotwordsEnabled)
        #expect(reloaded.voiceAXFallbackReadEnabled)

        // 两个开关互不影响，属性与 setter 函数行为一致。
        reloaded.setVoiceCloudHotwordsEnabled(false)
        #expect(!reloaded.voiceCloudHotwordsEnabled)
        #expect(reloaded.voiceAXFallbackReadEnabled)
        reloaded.setVoiceAXFallbackReadEnabled(false)
        #expect(!reloaded.voiceAXFallbackReadEnabled)
    }

    @Test("each opt-in setter posts exactly one settings change")
    func optInSettersNotifyOnce() {
        let (store, _) = makeStore()
        let counter = NotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .rimeAISettingsDidChange,
            object: store,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.setVoiceCloudHotwordsEnabled(true)
        #expect(counter.currentValue == 1)
        store.voiceAXFallbackReadEnabled = true
        #expect(counter.currentValue == 2)
    }

    @Test("opt-ins round-trip through export/import and reset to off")
    func optInExportImportAndReset() throws {
        let (source, _) = makeStore()
        source.setVoiceCloudHotwordsEnabled(true)
        source.setVoiceAXFallbackReadEnabled(true)
        let exported = source.exportSnapshot()
        #expect(exported.voiceCloudHotwordsEnabled)
        #expect(exported.voiceAXFallbackReadEnabled)

        let (destination, _) = makeStore()
        try destination.applyImport(exported, hasCloudCredential: false)
        #expect(destination.voiceCloudHotwordsEnabled)
        #expect(destination.voiceAXFallbackReadEnabled)
        #expect(destination.exportSnapshot() == exported)

        destination.restoreDefaults()
        #expect(!destination.voiceCloudHotwordsEnabled)
        #expect(!destination.voiceAXFallbackReadEnabled)

        destination.setVoiceCloudHotwordsEnabled(true)
        destination.setVoiceAXFallbackReadEnabled(true)
        destination.resetAllProductData()
        #expect(!destination.voiceCloudHotwordsEnabled)
        #expect(!destination.voiceAXFallbackReadEnabled)
    }

    @Test("exports written before the opt-ins existed import as disabled")
    func legacyExportWithoutOptInsImportsDisabled() throws {
        let (source, _) = makeStore()
        source.setVoiceCloudHotwordsEnabled(true)
        source.setVoiceAXFallbackReadEnabled(true)
        let encoder = JSONEncoder()
        var object = try #require(
            try JSONSerialization.jsonObject(
                with: encoder.encode(source.exportSnapshot())
            ) as? [String: Any]
        )
        object.removeValue(forKey: "voiceCloudHotwordsEnabled")
        object.removeValue(forKey: "voiceAXFallbackReadEnabled")
        object.removeValue(forKey: "voiceLearnedCorrectionsOrder")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let (destination, _) = makeStore()
        // 目标原本是开启的：缺失的键必须显式落回关闭，而不是保留旧值。
        destination.setVoiceCloudHotwordsEnabled(true)
        destination.setVoiceAXFallbackReadEnabled(true)
        try destination.applyImport(legacyData, hasCloudCredential: false)
        #expect(!destination.voiceCloudHotwordsEnabled)
        #expect(!destination.voiceAXFallbackReadEnabled)
    }

    // MARK: - Learned corrections: 128-item cap evicts the oldest, never the newest

    private func correctionKey(_ index: Int) -> String {
        String(format: "词条%03d错", index)
    }

    private func correctionValue(_ index: Int) -> String {
        String(format: "正词%03d对", index)
    }

    /// 字典序排在所有 `词条…` 之后的键：旧实现按字母序淘汰时会把它直接丢掉。
    private let alphabeticallyLastKey = "龘最新错词"

    private func fillToCap(_ store: RimeAISettingsStore) {
        for index in 1 ... 128 {
            store.recordVoiceLearnedCorrection(
                wrong: correctionKey(index),
                corrected: correctionValue(index),
                hotword: correctionValue(index)
            )
        }
    }

    @Test("a newly learned correction survives the 128-item cap; the oldest is evicted")
    func newestCorrectionSurvivesCap() {
        let (store, _) = makeStore()
        fillToCap(store)
        #expect(store.voiceLearnedCorrections.count == 128)
        #expect(store.voiceLearnedCorrectionsOrder == (1 ... 128).map(correctionKey))

        let added = store.recordVoiceLearnedCorrection(
            wrong: alphabeticallyLastKey,
            corrected: "最新正词",
            hotword: "最新正词"
        )
        #expect(added)

        let corrections = store.voiceLearnedCorrections
        #expect(corrections.count == 128)
        #expect(corrections[alphabeticallyLastKey] == "最新正词")
        // 最旧的第 1 条被淘汰，其余旧词条全部保留。
        #expect(corrections[correctionKey(1)] == nil)
        #expect(corrections[correctionKey(2)] == correctionValue(2))
        #expect(corrections[correctionKey(128)] == correctionValue(128))
        #expect(store.voiceLearnedCorrectionsOrder.first == correctionKey(2))
        #expect(store.voiceLearnedCorrectionsOrder.last == alphabeticallyLastKey)
    }

    @Test("re-learning an existing correction refreshes its recency")
    func relearningRefreshesRecency() {
        let (store, _) = makeStore()
        fillToCap(store)
        // 重新学到第 2 条：它成为最新，而不是停留在最初插入的位置。
        store.recordVoiceLearnedCorrection(
            wrong: correctionKey(2),
            corrected: "修正后的正词",
            hotword: "修正后的正词"
        )
        store.recordVoiceLearnedCorrection(
            wrong: alphabeticallyLastKey,
            corrected: "最新正词",
            hotword: "最新正词"
        )
        store.recordVoiceLearnedCorrection(
            wrong: "龘第二新词",
            corrected: "第二正词",
            hotword: "第二正词"
        )

        let corrections = store.voiceLearnedCorrections
        #expect(corrections.count == 128)
        // 先淘汰第 1 条，再淘汰当前最旧的第 3 条；被刷新过的第 2 条保留。
        #expect(corrections[correctionKey(1)] == nil)
        #expect(corrections[correctionKey(2)] == "修正后的正词")
        #expect(corrections[correctionKey(3)] == nil)
        #expect(corrections[correctionKey(4)] == correctionValue(4))
        #expect(corrections[alphabeticallyLastKey] == "最新正词")
        #expect(corrections["龘第二新词"] == "第二正词")
        #expect(store.voiceLearnedCorrectionsOrder.first == correctionKey(4))
        // 被刷新过的第 2 条排在两条新学的词条之前、其余旧词条之后。
        #expect(store.voiceLearnedCorrectionsOrder.suffix(3) == [
            correctionKey(2), alphabeticallyLastKey, "龘第二新词",
        ])
    }

    @Test("learned correction recency order survives export/import")
    func recencyOrderSurvivesExportImport() throws {
        let (source, _) = makeStore()
        fillToCap(source)
        source.recordVoiceLearnedCorrection(
            wrong: alphabeticallyLastKey,
            corrected: "最新正词",
            hotword: "最新正词"
        )
        let exported = source.exportSnapshot()
        #expect(exported.voiceLearnedCorrectionsOrder.count == 128)
        #expect(exported.voiceLearnedCorrectionsOrder.first == correctionKey(2))
        #expect(exported.voiceLearnedCorrectionsOrder.last == alphabeticallyLastKey)

        let (destination, _) = makeStore()
        try destination.applyImport(exported, hasCloudCredential: false)
        // 导入后再学一条：淘汰的是导入顺序里最旧的词条，新学的词条保留。
        destination.recordVoiceLearnedCorrection(
            wrong: "龘导入后新词",
            corrected: "导入后正词",
            hotword: "导入后正词"
        )
        let corrections = destination.voiceLearnedCorrections
        #expect(corrections.count == 128)
        #expect(corrections[correctionKey(2)] == nil)
        #expect(corrections[correctionKey(3)] == correctionValue(3))
        #expect(corrections[alphabeticallyLastKey] == "最新正词")
        #expect(corrections["龘导入后新词"] == "导入后正词")
    }

    @Test("legacy stores without a recency array keep loading and gain one on the next write")
    func legacyStoreWithoutOrderArray() {
        let (store, defaults) = makeStore()
        var legacy: [String: String] = [:]
        for index in 1 ... 128 {
            legacy[correctionKey(index)] = correctionValue(index)
        }
        defaults.set(
            legacy,
            forKey: RimeAISettingsStore.Keys.voiceLearnedCorrections
        )
        #expect(
            defaults.stringArray(
                forKey: RimeAISettingsStore.Keys.voiceLearnedCorrectionsOrder
            ) == nil
        )
        #expect(store.voiceLearnedCorrections.count == 128)

        store.recordVoiceLearnedCorrection(
            wrong: alphabeticallyLastKey,
            corrected: "最新正词",
            hotword: "最新正词"
        )
        let corrections = store.voiceLearnedCorrections
        #expect(corrections.count == 128)
        #expect(corrections[alphabeticallyLastKey] == "最新正词")
        // 没有顺序信息的旧词条按确定性的字母序倒序淘汰：保留字母序靠前的词条。
        #expect(corrections[correctionKey(1)] == correctionValue(1))
        #expect(corrections[correctionKey(127)] == correctionValue(127))
        #expect(corrections[correctionKey(128)] == nil)
        #expect(
            defaults.stringArray(
                forKey: RimeAISettingsStore.Keys.voiceLearnedCorrectionsOrder
            )?.last == alphabeticallyLastKey
        )
    }

    @Test("clearing the correction dictionary also clears its recency order")
    func clearingCorrectionsClearsOrder() {
        let (store, defaults) = makeStore()
        fillToCap(store)
        store.voiceLearnedCorrections = [:]
        #expect(store.voiceLearnedCorrections.isEmpty)
        #expect(store.voiceLearnedCorrectionsOrder.isEmpty)
        #expect(
            defaults.stringArray(
                forKey: RimeAISettingsStore.Keys.voiceLearnedCorrectionsOrder
            ) == []
        )
    }

    // MARK: - Pure normalization helper

    @Test("normalization with an explicit order evicts from the front of that order")
    func normalizationEvictsOldestOfGivenOrder() {
        var raw: [String: String] = [:]
        var order: [String] = []
        for index in 1 ... 130 {
            let key = correctionKey(index)
            raw[key] = correctionValue(index)
            order.append(key)
        }
        let result = RimeAISettingsStore.normalizedVoiceLearnedCorrectionsWithOrder(
            raw,
            order: order
        )
        #expect(result.order == Array(order.dropFirst(2)))
        #expect(result.order.last == correctionKey(130))
        #expect(result.corrections.count == 128)
        #expect(result.corrections[correctionKey(1)] == nil)
        #expect(result.corrections[correctionKey(2)] == nil)
        #expect(result.corrections[correctionKey(3)] == correctionValue(3))

        // 倒序的 order 淘汰的是另一头：淘汰完全由 order 决定。
        let reversed = RimeAISettingsStore.normalizedVoiceLearnedCorrectionsWithOrder(
            raw,
            order: order.reversed()
        )
        #expect(reversed.corrections[correctionKey(130)] == nil)
        #expect(reversed.corrections[correctionKey(1)] == correctionValue(1))
    }

    @Test("normalization without order keeps the alphabetically first 128 entries")
    func normalizationWithoutOrderMatchesLegacyBehaviour() {
        var raw: [String: String] = [:]
        for index in 1 ... 130 {
            raw[correctionKey(index)] = correctionValue(index)
        }
        let legacy = RimeAISettingsStore.normalizedVoiceLearnedCorrections(raw)
        #expect(legacy.count == 128)
        #expect(Set(legacy.keys) == Set(raw.keys.sorted().prefix(128)))
        // 等价的字典调用：order 缺省值与旧签名行为一致。
        #expect(
            RimeAISettingsStore.normalizedVoiceLearnedCorrections(raw, order: [])
                == legacy
        )
    }

    @Test("normalization drops invalid entries and unknown order keys")
    func normalizationIgnoresInvalidEntries() {
        let raw: [String: String] = [
            "有效错词": "有效正词",
            "x": "有效正词", // 键过短
            "有效错词二": "y", // 值过短
            "相同键": "相同键", // 键值相同：不是纠错
        ]
        let result = RimeAISettingsStore.normalizedVoiceLearnedCorrectionsWithOrder(
            raw,
            order: ["不存在的键", "有效错词", "有效错词", "x"]
        )
        #expect(result.corrections == ["有效错词": "有效正词"])
        #expect(result.order == ["有效错词"])
    }
}

private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.withLock { value += 1 }
    }

    var currentValue: Int {
        lock.withLock { value }
    }
}
