import Foundation
import XCTest
@testable import RimeAIInputCore

final class VoicePostCommitCorrectionLearnerTests: XCTestCase {
    // MARK: - Chinese Homophone & Near-Homophone Learning

    func testExtractsExactMandarinHomophoneCorrectionAndExpandsPhrase() throws {
        let corrections = VoicePostCommitCorrectionLearner.extractCorrections(
            original: "网易八哥说，其实还有一个很好的功能",
            edited: "网易叭哥说，其实还有一个很好的功能"
        )
        XCTAssertEqual(corrections.count, 1)
        let first = try XCTUnwrap(corrections.first)
        XCTAssertTrue(first.wrongText.contains("八哥"))
        XCTAssertTrue(first.correctedText.contains("叭哥"))
        XCTAssertEqual(first.hotword, first.correctedText)
        XCTAssertEqual(first.wrongText.count, first.correctedText.count)
        XCTAssertGreaterThanOrEqual(first.correctedText.count, 2)
        XCTAssertNotNil(first.pinyinKeys)
    }

    func testRespectsRimeHintedPhraseBoundary() throws {
        let corrections = VoicePostCommitCorrectionLearner.extractCorrections(
            original: "我在试用网易八哥说这个软件",
            edited: "我在试用网易叭哥说这个软件",
            hintedRimePhrase: "叭哥说",
            hintedRimePinyin: "bageshuo"
        )
        XCTAssertEqual(corrections.count, 1)
        let first = try XCTUnwrap(corrections.first)
        XCTAssertEqual(first.wrongText, "八哥说")
        XCTAssertEqual(first.correctedText, "叭哥说")
        XCTAssertEqual(first.hotword, "叭哥说")
        XCTAssertEqual(first.pinyinKeys, "bageshuo")
    }

    func testExtractsMultiCharHomophoneAndFuzzyMandarinCorrection() throws {
        let exact = VoicePostCommitCorrectionLearner.extractCorrections(
            original: "今天配置了雾松拼音词库",
            edited: "今天配置了雾凇拼音词库"
        )
        XCTAssertEqual(exact.count, 1)
        let exactFirst = try XCTUnwrap(exact.first)
        XCTAssertTrue(exactFirst.wrongText.contains("雾松"))
        XCTAssertTrue(exactFirst.correctedText.contains("雾凇"))

        // Fuzzy retroflex zh/z or sh/s near-homophone: 张山 -> 张三
        let fuzzy = VoicePostCommitCorrectionLearner.extractCorrections(
            original: "明天把文档发给张山看一下",
            edited: "明天把文档发给张三看一下"
        )
        XCTAssertEqual(fuzzy.count, 1)
        let fuzzyFirst = try XCTUnwrap(fuzzy.first)
        XCTAssertEqual(fuzzyFirst.wrongText, "张山")
        XCTAssertEqual(fuzzyFirst.correctedText, "张三")
    }

    // MARK: - English & Mixed-Script Corrections

    func testExtractsEnglishSpaceCollapseAndCasingCorrection() throws {
        let spaced = VoicePostCommitCorrectionLearner.extractCorrections(
            original: "我现在用 Rime AI 写代码",
            edited: "我现在用 RimeAI 写代码"
        )
        XCTAssertEqual(spaced.count, 1)
        let spacedFirst = try XCTUnwrap(spaced.first)
        XCTAssertEqual(spacedFirst.wrongText, "Rime AI")
        XCTAssertEqual(spacedFirst.correctedText, "RimeAI")

        let spelling = VoicePostCommitCorrectionLearner.extractCorrections(
            original: "刚才用 wisper 录了一段话",
            edited: "刚才用 Wispr 录了一段话"
        )
        XCTAssertEqual(spelling.count, 1)
        let spellingFirst = try XCTUnwrap(spelling.first)
        XCTAssertEqual(spellingFirst.wrongText, "wisper")
        XCTAssertEqual(spellingFirst.correctedText, "Wispr")
    }

    func testExtractsCrossScriptTransliterationCorrection() throws {
        let corrections = VoicePostCommitCorrectionLearner.extractCorrections(
            original: "帮我打开克劳德写个脚本",
            edited: "帮我打开Claude写个脚本"
        )
        XCTAssertEqual(corrections.count, 1)
        let first = try XCTUnwrap(corrections.first)
        XCTAssertEqual(first.wrongText, "克劳德")
        XCTAssertEqual(first.correctedText, "Claude")
    }

    // MARK: - Anchor Isolation & Trailing Continuation

    func testAnchorIsolationAndTrailingContinuation() throws {
        let anchor = VoicePostCommitAnchor(
            committedText: "网易八哥说很好用",
            bundleIdentifier: "com.example.chat",
            appSessionID: "session-1",
            insertionUTF16Offset: 4,
            prefixAnchor: "笔记：",
            suffixAnchor: ""
        )
        // User fixed "八" -> "叭" AND appended "，推荐试试" at the end.
        let window = "笔记：网易叭哥说很好用，推荐试试"
        let corrections = VoicePostCommitCorrectionLearner.extractCorrections(
            anchor: anchor,
            documentWindow: window,
            hintedRimePhrase: "叭哥说",
            hintedRimePinyin: "bageshuo"
        )
        XCTAssertEqual(corrections.count, 1)
        let first = try XCTUnwrap(corrections.first)
        XCTAssertEqual(first.wrongText, "八哥说")
        XCTAssertEqual(first.correctedText, "叭哥说")
    }

    func testTailBackspaceFallbackWithoutDocumentReadback() {
        let tail = VoicePostCommitTailEdit(
            deletedTrailingCharacters: 3,
            replacementText: "叭哥说",
            replacementPinyin: "bageshuo"
        )
        let learned = VoicePostCommitCorrectionLearner
            .extractCorrectionFromTailEdit(
                committedText: "我试了一下网易八哥说",
                tailEdit: tail
            )
        XCTAssertEqual(learned?.wrongText, "八哥说")
        XCTAssertEqual(learned?.correctedText, "叭哥说")
        XCTAssertEqual(learned?.pinyinKeys, "bageshuo")
    }

    // MARK: - Anti-Pollution Rejection Guards

    func testRejectsSemanticMindChange() {
        let corrections = VoicePostCommitCorrectionLearner.extractCorrections(
            original: "明天下午三点开会讨论方案",
            edited: "后天下午三点开会讨论方案"
        )
        XCTAssertTrue(corrections.isEmpty)
    }

    func testRejectsTrivialPronounAndGrammarSwaps() {
        let pronoun = VoicePostCommitCorrectionLearner.extractCorrections(
            original: "我把文件发给他了",
            edited: "我把文件发给她了"
        )
        XCTAssertTrue(pronoun.isEmpty)

        let particle = VoicePostCommitCorrectionLearner.extractCorrections(
            original: "跑的很快",
            edited: "跑得很快"
        )
        XCTAssertTrue(particle.isEmpty)
    }

    func testRejectsPureDeletionPunctuationAndDigitChanges() {
        let deletion = VoicePostCommitCorrectionLearner.extractCorrections(
            original: "我觉得今天天气真的非常不错",
            edited: "我觉得今天天气不错"
        )
        XCTAssertTrue(deletion.isEmpty)

        let punct = VoicePostCommitCorrectionLearner.extractCorrections(
            original: "今天开会讨论一下，没问题",
            edited: "今天开会讨论一下。没问题！"
        )
        XCTAssertTrue(punct.isEmpty)

        let digits = VoicePostCommitCorrectionLearner.extractCorrections(
            original: "这是2025年的总结报告",
            edited: "这是2026年的总结报告"
        )
        XCTAssertTrue(digits.isEmpty)
    }

    func testRejectsWholesaleRewrite() {
        let rewrite = VoicePostCommitCorrectionLearner.extractCorrections(
            original: "今天下午去公园散步",
            edited: "晚上回家做一顿火锅"
        )
        XCTAssertTrue(rewrite.isEmpty)
    }

    // MARK: - Deterministic Applier

    func testApplierPrefersLongestMatchAndRespectsASCIIWordBoundaries() {
        let corrections: [String: String] = [
            "八哥": "叭哥",
            "网易八哥说": "网易叭哥说",
            "rime ai": "RimeAI",
            "克劳德": "Claude",
        ]
        let input = "我在用 rime ai 和克劳德评测网易八哥说，还有 prime air 不该被改"
        let applied = VoiceLearnedCorrectionApplier.apply(
            input,
            corrections: corrections
        )
        XCTAssertEqual(
            applied,
            "我在用 RimeAI 和Claude评测网易叭哥说，还有 prime air 不该被改"
        )
    }

    // MARK: - Settings Persistence & Schema-8 Compatibility

    func testSettingsRecordLearnedCorrectionUpdatesHotwordsAndOverridesReverse() throws {
        let suiteName = "fun.wwcn.rimeai.tests.voice-learn.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RimeAISettingsStore(defaults: defaults)

        XCTAssertTrue(store.voiceAutoLearnCorrectionsEnabled)
        XCTAssertTrue(store.voiceLearnedCorrections.isEmpty)

        let firstAdded = store.recordVoiceLearnedCorrection(
            wrong: "八哥说",
            corrected: "叭哥说",
            hotword: "叭哥说"
        )
        XCTAssertTrue(firstAdded)
        XCTAssertEqual(store.voiceLearnedCorrections["八哥说"], "叭哥说")
        XCTAssertEqual(store.voiceCustomHotwords.first, "叭哥说")

        // Duplicate record reports no change.
        let duplicate = store.recordVoiceLearnedCorrection(
            wrong: "八哥说",
            corrected: "叭哥说",
            hotword: "叭哥说"
        )
        XCTAssertFalse(duplicate)

        // Reverse correction removes stale inverse mapping to avoid flip-flop.
        let reversed = store.recordVoiceLearnedCorrection(
            wrong: "叭哥说",
            corrected: "八哥说",
            hotword: "八哥说"
        )
        XCTAssertTrue(reversed)
        XCTAssertNil(store.voiceLearnedCorrections["八哥说"])
        XCTAssertEqual(store.voiceLearnedCorrections["叭哥说"], "八哥说")

        // Export & re-import round-trip preserves learned corrections.
        let exported = store.exportSnapshot()
        let encoded = try JSONEncoder().encode(exported)
        let suiteName2 = "fun.wwcn.rimeai.tests.voice-learn-import.\(UUID().uuidString)"
        let defaults2 = try XCTUnwrap(UserDefaults(suiteName: suiteName2))
        defer { defaults2.removePersistentDomain(forName: suiteName2) }
        let store2 = RimeAISettingsStore(defaults: defaults2)
        try store2.applyImport(encoded, hasCloudCredential: false)
        XCTAssertEqual(store2.voiceLearnedCorrections, ["叭哥说": "八哥说"])
        XCTAssertTrue(store2.voiceCustomHotwords.contains("八哥说"))

        // restoreDefaults preserves user-learned dictionary; resetAllProductData clears it.
        store2.voiceAutoLearnCorrectionsEnabled = false
        store2.restoreDefaults()
        XCTAssertTrue(store2.voiceAutoLearnCorrectionsEnabled)
        XCTAssertEqual(store2.voiceLearnedCorrections, ["叭哥说": "八哥说"])

        store2.resetAllProductData()
        XCTAssertTrue(store2.voiceLearnedCorrections.isEmpty)
        XCTAssertTrue(store2.voiceCustomHotwords.isEmpty)
    }
}
