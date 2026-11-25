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
}
