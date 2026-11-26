import AppKit
import ApplicationServices
import Carbon
import XCTest
@testable import RimeAIInputMethod

/// 上屏后自动纠错观察器的隐私边界：通过辅助功能读取光标周边文本必须
/// 显式 opt-in（默认关闭），且仍受授权与安全输入约束。
@MainActor
final class VoicePostCommitEditTrackerTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        suites = []
        super.tearDown()
    }

    private func makeStore() -> RimeAISettingsStore {
        let suite = "fun.wwcn.inputmethod.RimeAI.tests.ax.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return RimeAISettingsStore(defaults: defaults)
    }

    // MARK: - Pure Gate

    func testAXFallbackRequiresOptInTrustAndNoSecureInput() {
        // 唯一放行的组合。
        XCTAssertTrue(VoicePostCommitEditTracker.axFallbackReadIsAllowed(
            optIn: true, isProcessTrusted: true, isSecureInput: false
        ))
        for optIn in [false, true] {
            for trusted in [false, true] {
                for secure in [false, true] {
                    let allowed = VoicePostCommitEditTracker.axFallbackReadIsAllowed(
                        optIn: optIn, isProcessTrusted: trusted, isSecureInput: secure
                    )
                    XCTAssertEqual(
                        allowed,
                        optIn && trusted && !secure,
                        "optIn=\(optIn) trusted=\(trusted) secure=\(secure)"
                    )
                }
            }
        }
    }

    // MARK: - Settings Defaults (contract shared with RimeAIInputCore)

    func testAXFallbackReadAndCloudHotwordsAreOptInAndDefaultOff() {
        let store = makeStore()

        XCTAssertFalse(store.voiceAXFallbackReadEnabled, "读取光标周边文本默认必须关闭")
        XCTAssertFalse(store.voiceCloudHotwordsEnabled, "向云端发送热词默认必须关闭")

        store.setVoiceAXFallbackReadEnabled(true)
        store.setVoiceCloudHotwordsEnabled(true)
        XCTAssertTrue(store.voiceAXFallbackReadEnabled)
        XCTAssertTrue(store.voiceCloudHotwordsEnabled)

        store.setVoiceAXFallbackReadEnabled(false)
        store.setVoiceCloudHotwordsEnabled(false)
        XCTAssertFalse(store.voiceAXFallbackReadEnabled)
        XCTAssertFalse(store.voiceCloudHotwordsEnabled)
    }

    // MARK: - Tracker Instance

    func testTrackerNeverUsesAXFallbackWhileOptedOut() {
        let tracker = VoicePostCommitEditTracker(settings: makeStore())

        XCTAssertFalse(tracker.isAXFallbackReadEnabled)
    }

    func testTrackerOptInStillRequiresAccessibilityTrust() {
        let store = makeStore()
        store.setVoiceAXFallbackReadEnabled(true)
        let tracker = VoicePostCommitEditTracker(settings: store)

        // 测试进程通常未被授予辅助功能权限：仅 opt-in 不足以放行。
        let trusted = AXIsProcessTrusted()
        XCTAssertEqual(
            tracker.isAXFallbackReadEnabled,
            trusted && !IsSecureEventInputEnabled()
        )
        if !trusted {
            XCTAssertFalse(tracker.isAXFallbackReadEnabled)
        }
    }

    func testTurningOptInOffImmediatelyClosesTheGate() {
        let store = makeStore()
        store.setVoiceAXFallbackReadEnabled(true)
        let tracker = VoicePostCommitEditTracker(settings: store)

        store.setVoiceAXFallbackReadEnabled(false)

        XCTAssertFalse(tracker.isAXFallbackReadEnabled)
    }

    func testClearEphemeralDataIsSafeWithoutAnActiveSession() {
        let tracker = VoicePostCommitEditTracker(settings: makeStore())

        tracker.clearEphemeralData()
        tracker.cancelForSecureInput()

        XCTAssertFalse(tracker.isAXFallbackReadEnabled)
    }

    // MARK: - Bidirectional Learning & Unified L1 Vocabulary

    func testKeyboardTrackingNeedsVoiceEnabledAndNeverTouchesVoiceDictionaries() {
        let store = makeStore()
        store.voiceEnabled = false
        let tracker = VoicePostCommitEditTracker(
            settings: store,
            phraseRecorder: { _, _, _ in
                XCTFail("keyboard tracking must not record voice phrases")
            },
            keyboardPreferenceRecorder: { _, _, _ in
                XCTFail("keyboard tracking must stay off while voice is disabled")
            }
        )

        // 语音未开启：不建锚点（调用方因此不会做任何客户端访问），也不学习。
        XCTAssertNil(
            tracker.makeKeyboardCommitAnchor(
                committedText: "时间",
                bundleIdentifier: "com.test.Editor",
                appSessionID: "sess-1"
            )
        )
        XCTAssertFalse(tracker.canLearn(for: "com.test.Editor"))
    }

    func testKeyboardReselectionOnlyRecordsAKeyboardPreference() {
        let store = makeStore()
        store.voiceEnabled = true
        store.voiceAutoLearnCorrectionsEnabled = true
        var voicePhrases: [(String, String, String)] = []
        var keyboardPreferences: [(String, String, String)] = []
        let tracker = VoicePostCommitEditTracker(
            settings: store,
            phraseRecorder: { text, pinyin, bundle in
                voicePhrases.append((text, pinyin, bundle))
            },
            keyboardPreferenceRecorder: { text, pinyin, bundle in
                keyboardPreferences.append((text, pinyin, bundle))
            }
        )
        let bundle = "com.test.Editor"

        // 上屏首选 → 退格 → 改选同音词。
        tracker.armKeyboardCommit(
            anchor: VoicePostCommitAnchor(
                committedText: "时间",
                bundleIdentifier: bundle,
                appSessionID: "sess-1"
            )
        )
        // 其他应用里的退格与本会话无关。
        tracker.noteUncomposedBackspace(client: nil, bundleIdentifier: "com.other.App")
        XCTAssertFalse(tracker.hasPendingUserEdits)

        tracker.noteUncomposedBackspace(client: nil, bundleIdentifier: bundle)
        tracker.noteUncomposedBackspace(client: nil, bundleIdentifier: bundle)
        XCTAssertTrue(tracker.hasPendingUserEdits)

        tracker.noteKeyboardCommit(
            text: "事件",
            pinyin: "shijian",
            client: nil,
            bundleIdentifier: bundle
        )
        tracker.settleNowIfMatching(
            client: nil,
            reason: .returnKey,
            bundleIdentifier: bundle
        )

        // 偏好只进键盘短语库；语音纠错映射与热词列表保持原样。
        XCTAssertEqual(keyboardPreferences.count, 1)
        XCTAssertEqual(keyboardPreferences.first?.0, "事件")
        XCTAssertEqual(keyboardPreferences.first?.1, "shijian")
        XCTAssertEqual(keyboardPreferences.first?.2, bundle)
        XCTAssertTrue(voicePhrases.isEmpty)
        XCTAssertTrue(store.voiceLearnedCorrections.isEmpty)
        XCTAssertTrue(store.voiceCustomHotwords.isEmpty)
        XCTAssertFalse(tracker.hasPendingUserEdits)
    }

    func testContinuedTypingAfterKeyboardCommitLearnsNothing() {
        let store = makeStore()
        store.voiceEnabled = true
        var keyboardPreferences: [(String, String, String)] = []
        let tracker = VoicePostCommitEditTracker(
            settings: store,
            phraseRecorder: { _, _, _ in },
            keyboardPreferenceRecorder: { text, pinyin, bundle in
                keyboardPreferences.append((text, pinyin, bundle))
            }
        )
        let bundle = "com.test.Editor"

        // 上屏后继续正常输入（没有退格）：只换锚点，不产生任何学习。
        for committed in ["时间", "安排", "好了"] {
            tracker.armKeyboardCommit(
                anchor: VoicePostCommitAnchor(
                    committedText: committed,
                    bundleIdentifier: bundle,
                    appSessionID: "sess-1"
                )
            )
        }
        tracker.settleNowIfMatching(
            client: nil,
            reason: .returnKey,
            bundleIdentifier: bundle
        )

        XCTAssertTrue(keyboardPreferences.isEmpty)
    }

    func testUserCuratedHotwordsJoinTheReadModelWithoutDatabaseRows() {
        let entries = RimeAIPhraseBookService.makeHotwordEntries(
            ["雾凇拼音", "RimeAI", "Go语言", "x", " a "]
        )

        // 只在内存里参与候选与混输词表；不合规的词条被丢弃。
        XCTAssertEqual(entries.map(\.text), ["雾凇拼音", "RimeAI", "Go语言"])
        XCTAssertEqual(
            entries.map(\.pinyinKeys),
            ["wusongpinyin", "rimeai", "goyuyan"]
        )
        XCTAssertTrue(entries.allSatisfy { $0.domain == PhraseBookDomain.global })
        XCTAssertTrue(entries.allSatisfy(\.isProtected))

        let vocab = RimeAIPhraseBookService.buildEnglishVocabulary(
            entries: [],
            hotwordEntries: entries,
            lexiconEntries: [],
            limit: 64
        )
        XCTAssertEqual(vocab.orderedTokens, ["rimeai"])
        XCTAssertEqual(vocab.casedTokens["rimeai"], "RimeAI")
    }

    func testBuildEnglishVocabularyPreservesCasingAndEmbeddedTokens() {
        let entries = [
            PhraseBookEntry(
                id: "1",
                domain: "global",
                text: "rimeai",
                pinyinKeys: "rimeai",
                count: 10,
                firstSeenAt: Date(timeIntervalSince1970: 10),
                lastUsedAt: Date(timeIntervalSince1970: 10),
                source: .auto,
                isProtected: false
            ),
            PhraseBookEntry(
                id: "2",
                domain: "global",
                text: "RimeAI",
                pinyinKeys: "rimeai",
                count: 1,
                firstSeenAt: Date(timeIntervalSince1970: 20),
                lastUsedAt: Date(timeIntervalSince1970: 20),
                source: .user,
                isProtected: true
            ),
            PhraseBookEntry(
                id: "3",
                domain: "coding",
                text: "FastAPI接口",
                pinyinKeys: "fastapijiekou",
                count: 3,
                firstSeenAt: Date(timeIntervalSince1970: 30),
                lastUsedAt: Date(timeIntervalSince1970: 30),
                source: .auto,
                isProtected: false
            ),
        ]
        let lexiconEntries = [
            PhraseBookEntry(
                id: "4",
                domain: "coding",
                text: "GraphQL",
                pinyinKeys: "graphql",
                count: 5,
                firstSeenAt: Date(timeIntervalSince1970: 5),
                lastUsedAt: Date(timeIntervalSince1970: 5),
                source: .lexicon,
                isProtected: false
            ),
        ]

        let vocab = RimeAIPhraseBookService.buildEnglishVocabulary(
            entries: entries,
            lexiconEntries: lexiconEntries,
            limit: 64
        )

        XCTAssertEqual(Set(vocab.orderedTokens), ["rimeai", "fastapi", "graphql"])
        XCTAssertEqual(vocab.casedTokens["rimeai"], "RimeAI")
        XCTAssertEqual(vocab.casedTokens["fastapi"], "FastAPI")
        XCTAssertEqual(vocab.casedTokens["graphql"], "GraphQL")
    }

    func testVoiceCloudHotwordPolicyPrioritizesTranscriptMatchesWhenTruncating() {
        var hotwords = (1 ... 40).map { "无关词条\($0)" }
        hotwords.append("雾凇拼音")
        hotwords.append("FastAPI")

        let selected = VoiceCloudHotwordPolicy.cloudHotwords(
            isEnabled: true,
            activeHotwords: hotwords,
            transcript: "测试无松拼音和 fast api"
        )

        XCTAssertEqual(selected.count, 32)
        XCTAssertTrue(selected.contains("雾凇拼音"))
        XCTAssertTrue(selected.contains("FastAPI"))
    }
}
