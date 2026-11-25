import Foundation
import RimeAIInputCore
import Testing

@Suite("VoiceHotwordMerger & Custom Hotword Settings")
struct VoiceHotwordMergerTests {
    @Test("merges custom, phrasebook, and session hotwords in priority order")
    func priorityAndDeduplication() {
        let snapshot = VoiceHotwordMerger.merge(
            customPhrases: ["RimeAI", "特展", "invalid/path", "RimeAI"],
            phraseBookPhrases: ["特展", "雾凇拼音", "FastAPI"],
            sessionRimePhrases: ["FastAPI", "Kubernetes"],
            maximumEntries: 4
        )
        #expect(snapshot.isValid)
        #expect(snapshot.phrases == ["RimeAI", "特展", "雾凇拼音", "FastAPI"])
    }

    @Test("settings store persists custom voice hotwords and phrasebook toggle")
    func settingsPersistenceAndExportImport() throws {
        let suiteName = "fun.wwcn.rimeai.tests.voice-hotwords.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RimeAISettingsStore(defaults: defaults)
        #expect(store.voicePhraseBookHotwordsEnabled == true)
        #expect(store.voiceCustomHotwords.isEmpty)

        store.voiceCustomHotwords = [
            "  RimeAI ",
            "雾凇拼音",
            "a", // too short -> filtered
            "bad/slash", // disallowed char -> filtered
            "RimeAI", // duplicate -> deduped
            "FastAPI",
        ]
        #expect(store.voiceCustomHotwords == ["RimeAI", "雾凇拼音", "FastAPI"])

        store.voicePhraseBookHotwordsEnabled = false
        let exported = store.exportSnapshot()
        #expect(exported.schemaVersion == 8)
        #expect(exported.voicePhraseBookHotwordsEnabled == false)
        #expect(exported.voiceCustomHotwords == ["RimeAI", "雾凇拼音", "FastAPI"])

        // restoreDefaults keeps user custom hotwords (same boundary as personalEnglishTokens)
        store.restoreDefaults()
        #expect(store.voicePhraseBookHotwordsEnabled == true)
        #expect(store.voiceCustomHotwords == ["RimeAI", "雾凇拼音", "FastAPI"])

        // Re-import restores both fields
        let encoded = try JSONEncoder().encode(exported)
        try store.applyImport(encoded, hasCloudCredential: false)
        #expect(store.voicePhraseBookHotwordsEnabled == false)
        #expect(store.voiceCustomHotwords == ["RimeAI", "雾凇拼音", "FastAPI"])

        // resetAllProductData clears everything
        store.resetAllProductData()
        #expect(store.voiceCustomHotwords.isEmpty)
        #expect(store.voicePhraseBookHotwordsEnabled == true)
    }
}
