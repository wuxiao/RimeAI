import AppKit
import XCTest
@testable import RimeAIInputMethod

/// 运行时核心修复与听写浮窗：润色中直接上屏原文、云端热词 opt-in、
/// 润色截断回退、收紧后的超时，以及浮窗的 HIG 按钮次序、key window
/// 按键处理、状态可视化、降级/失败卡片与键帽式快捷键录制器。
/// 纯策略见 `VoiceRuntimePolicyTests`，设置页展示见
/// `VoiceSettingsPresentationTests`。
@MainActor
final class VoiceUIAndRuntimeTests: XCTestCase {
    private let anchor = NSRect(x: 300, y: 400, width: 2, height: 20)

    // MARK: - 润色/翻译中直接上屏原文（P0）

    func testPlainSpaceReturnAndEnterCommitRawTextWhileTransforming() {
        func decide(
            keyCode: UInt16,
            transforming: Bool,
            plain: Bool = true,
            pending: Bool = false
        ) -> VoiceDictationKeyDecision {
            VoiceDictationKeyRouter.decision(
                keyCode: keyCode,
                isExactVoiceShortcut: false,
                shortcutRegistered: false,
                hasActiveSession: true,
                pendingConfirmation: pending,
                isTransforming: transforming,
                isPlainConfirmationKey: plain
            )
        }

        // 空格 49 / 回车 36 / 小键盘 Enter 76：转换中一律“直接上屏原文”。
        for keyCode in [UInt16(49), 36, 76] {
            XCTAssertEqual(
                decide(keyCode: keyCode, transforming: true),
                .commitRawDuringTransform,
                "keyCode=\(keyCode)"
            )
        }
        // 不在转换中时保持既有语义：待确认才上屏，否则取消并透传按键。
        XCTAssertEqual(decide(keyCode: 49, transforming: false), .cancelAndContinue)
        XCTAssertEqual(decide(keyCode: 36, transforming: false, pending: true), .confirm)
        // 带修饰键的空格/回车（⌘空格等）不属于“直接上屏”。
        XCTAssertEqual(decide(keyCode: 49, transforming: true, plain: false), .cancelAndContinue)
        // Esc 仍然是取消；其他按键不劫持。
        XCTAssertEqual(decide(keyCode: 53, transforming: true), .cancelAndConsume)
        XCTAssertEqual(decide(keyCode: 0, transforming: true), .cancelAndContinue)
    }

    func testRawCommitNeverRecordsASkippedTranslationAsTranslated() {
        XCTAssertEqual(VoiceTransformRawCommit.plan(for: .dictation).actionKind, .dictation)
        let translated = VoiceTransformRawCommit.plan(for: .translate(.autoEnZh))
        XCTAssertEqual(translated.actionKind, .dictation, "原文未经翻译，不得记作一次翻译")
        XCTAssertNil(translated.targetLanguage)
        XCTAssertFalse(translated.polishApplied)
    }

    // MARK: - 云端热词 opt-in

    func testCloudHotwordsAreSentOnlyWhenOptedIn() {
        XCTAssertEqual(
            VoiceCloudHotwordPolicy.cloudHotwords(isEnabled: false, activeHotwords: ["张三", "RimeAI"]),
            [],
            "未显式开启时热词上下文绝不能离开本机"
        )
        XCTAssertEqual(
            VoiceCloudHotwordPolicy.cloudHotwords(isEnabled: true, activeHotwords: ["张三", "RimeAI"]),
            ["张三", "RimeAI"]
        )
    }

    // MARK: - 云端润色截断守卫

    func testPolishTruncationGuardFallsBackForLongInputs() {
        let input = String(repeating: "这是一段足够长的听写内容。", count: 10)
        XCTAssertGreaterThanOrEqual(input.count, VoiceCloudPolishTruncationGuard.minimumInputCharacters)

        XCTAssertTrue(
            VoiceCloudPolishTruncationGuard.looksTruncated(
                input: input,
                output: String(input.prefix(input.count / 2))
            ),
            "长输入只返回一半：判为截断，回退本地润色"
        )
        XCTAssertFalse(
            VoiceCloudPolishTruncationGuard.looksTruncated(
                input: input,
                output: String(input.prefix(Int(Double(input.count) * 0.75)))
            )
        )
        // 短输入本就容易有大幅删减，不触发。
        XCTAssertFalse(
            VoiceCloudPolishTruncationGuard.looksTruncated(input: "嗯那个你好", output: "你好")
        )
        XCTAssertFalse(
            VoiceCloudPolishTruncationGuard.fallbackStatus.isEmpty,
            "回退时必须给出清晰的状态说明"
        )
    }

    // MARK: - 超时口径

    func testSessionTimingIsTightened() {
        XCTAssertEqual(VoiceSessionTiming.finalizationDeadlineMilliseconds, 10_000)
        XCTAssertLessThan(
            VoiceSessionTiming.finalizationDeadlineMilliseconds,
            VoiceDictationConstants.maximumDeadlineMilliseconds,
            "不再沿用 30s 协议上限"
        )
        XCTAssertEqual(VoiceSessionTiming.cloudTransformDeadline(for: .polish), 6_000)
        XCTAssertEqual(VoiceSessionTiming.cloudTransformDeadline(for: .translate), 10_000)
        XCTAssertLessThan(
            VoiceSessionTiming.cloudTransformDeadline(for: .polish),
            VoiceSessionTiming.cloudTransformDeadline(for: .translate)
        )
    }

    // MARK: - 浮窗：HIG 次序与主按钮

    func testPendingConfirmationUsesHIGOrderWithASinglePrimaryAction() {
        let panel = VoiceDictationPanelController()

        panel.updatePreview(
            stable: "今天下午三点开会",
            partial: "",
            pendingConfirm: true,
            polishApplied: true,
            anchorRect: anchor,
            onConfirm: {},
            onCopy: {},
            onCancel: {}
        )

        let snapshot = panel.testingSnapshot
        XCTAssertEqual(snapshot.visibleButtonTitlesLeftToRight, ["关闭", "复制", "上屏"])
        XCTAssertEqual(snapshot.hint, "空格/回车上屏 · Esc 关闭")
        XCTAssertTrue(snapshot.confirmIsPrimary)
        // 实际落位：关闭在最左，上屏在最右。
        let cancelX = snapshot.buttonFrames["关闭"]?.minX
        let copyX = snapshot.buttonFrames["复制"]?.minX
        let confirmX = snapshot.buttonFrames["上屏"]?.minX
        XCTAssertNotNil(cancelX)
        XCTAssertNotNil(copyX)
        XCTAssertNotNil(confirmX)
        XCTAssertLessThan(cancelX!, copyX!)
        XCTAssertLessThan(copyX!, confirmX!)
        XCTAssertEqual(snapshot.status, "已润色")
        panel.hide()
    }

    func testPanelHandlesSpaceReturnCommandCAndEscapeWhenItIsTheKeyWindow() {
        let panel = VoiceDictationPanelController()
        var confirmed = 0
        var copied = 0
        var cancelled = 0
        panel.updatePreview(
            stable: "你好世界",
            partial: "",
            pendingConfirm: true,
            polishApplied: false,
            anchorRect: anchor,
            onConfirm: { confirmed += 1 },
            onCopy: { copied += 1 },
            onCancel: { cancelled += 1 }
        )

        // 用户点选了浮窗里的文字后面板成为 key window：空格/回车必须仍是“上屏”。
        XCTAssertTrue(panel.simulateKeyEquivalent(keyCode: 49))
        XCTAssertTrue(panel.simulateKeyEquivalent(keyCode: 36))
        XCTAssertEqual(confirmed, 2)
        // ⌘C：没有选中范围时复制完整文本。
        XCTAssertTrue(panel.simulateKeyEquivalent(keyCode: 8, modifiers: .command))
        XCTAssertEqual(copied, 1)
        XCTAssertTrue(panel.simulateKeyEquivalent(keyCode: 53))
        XCTAssertEqual(cancelled, 1)
        panel.hide()
    }

    func testPanelSwallowsSpaceWhileListeningInsteadOfBeeping() {
        let panel = VoiceDictationPanelController()
        panel.showListening(anchorRect: anchor, onCancel: {})

        XCTAssertTrue(panel.simulateKeyEquivalent(keyCode: 49), "聆听中没有可确认内容：吞掉空格")

        panel.hide()
    }

    // MARK: - 浮窗：状态可视化

    func testConnectingAndTransformingShowSpinnerWhileListeningShowsTimer() {
        let panel = VoiceDictationPanelController()

        panel.showConnecting(anchorRect: anchor, onCancel: {})
        var snapshot = panel.testingSnapshot
        XCTAssertTrue(snapshot.showsSpinner)
        XCTAssertFalse(snapshot.dotIsVisible)
        XCTAssertNil(snapshot.recordingTimer)

        panel.showListening(anchorRect: anchor, onCancel: {})
        snapshot = panel.testingSnapshot
        XCTAssertFalse(snapshot.showsSpinner)
        XCTAssertTrue(snapshot.dotIsVisible)
        XCTAssertEqual(snapshot.recordingTimer, "0:00", "聆听中显示实时录音计时")

        panel.showTransforming(
            statusText: "润色中…",
            sourcePreview: "原文",
            anchorRect: anchor,
            onCancel: {}
        )
        snapshot = panel.testingSnapshot
        XCTAssertTrue(snapshot.showsSpinner)
        XCTAssertEqual(snapshot.hint, "空格/回车直接上屏原文 · Esc 取消")
        XCTAssertNil(snapshot.recordingTimer)
        panel.hide()
    }

    func testListeningTimerCountsFromTheRequestedStartInstant() {
        let panel = VoiceDictationPanelController()
        panel.showListening(
            anchorRect: anchor,
            recordingStartedAt: Date(timeIntervalSinceNow: -12.4),
            onCancel: {}
        )

        XCTAssertEqual(panel.testingSnapshot.recordingTimer, "0:12")
        XCTAssertEqual(panel.testingSnapshot.status, "", "计时独立于状态徽标，不改变既有状态文本")
        panel.hide()
    }

    func testRecordingTimerFormatting() {
        XCTAssertEqual(VoicePanelFormatting.recordingTimer(seconds: 0), "0:00")
        XCTAssertEqual(VoicePanelFormatting.recordingTimer(seconds: 12), "0:12")
        XCTAssertEqual(VoicePanelFormatting.recordingTimer(seconds: 65), "1:05")
        XCTAssertEqual(VoicePanelFormatting.recordingTimer(seconds: 3_723), "1:02:03")
        XCTAssertEqual(VoicePanelFormatting.recordingTimer(seconds: -5), "0:00")
        XCTAssertEqual(
            VoicePanelFormatting.elapsedSeconds(
                since: Date(timeIntervalSinceNow: -12.9),
                now: Date(timeIntervalSinceNow: -3.2)
            ),
            9
        )
    }

    // MARK: - 浮窗：降级复制卡片

    func testPersistentCopyExplainsAccessibilityFallbackAndOffersAuthorization() {
        let panel = VoiceDictationPanelController()

        panel.showPersistentCopy(
            text: "已复制的内容",
            reason: .accessibilityNeeded,
            anchorRect: anchor,
            onCopied: {},
            onClose: {}
        )

        var snapshot = panel.testingSnapshot
        XCTAssertEqual(snapshot.persistentCopyReason, .accessibilityNeeded)
        XCTAssertEqual(
            snapshot.hint,
            "已复制到剪贴板，请按 ⌘V 粘贴（开启辅助功能权限可自动粘贴）",
            "真实原因是缺少辅助功能权限时不得显示“未检测到光标”"
        )
        XCTAssertFalse(snapshot.accessibilityIsHidden)
        XCTAssertEqual(snapshot.visibleButtonTitlesLeftToRight, ["关闭", "复制 ⌘C", "授权辅助功能"])
        XCTAssertTrue(snapshot.hasCopyHandler)
        XCTAssertTrue(snapshot.confirmIsHidden)
        XCTAssertFalse(snapshot.hasConfirmHandler)

        panel.showPersistentCopy(
            text: "焦点切换后的内容",
            reason: .focusSwitched,
            anchorRect: anchor,
            onCopied: {},
            onClose: {}
        )
        snapshot = panel.testingSnapshot
        XCTAssertEqual(snapshot.hint, "焦点已切换，内容已保留在浮窗")
        XCTAssertTrue(snapshot.accessibilityIsHidden)
        panel.hide()
    }

    // MARK: - 浮窗：失败卡片

    func testFailureCardOffersRetryAndContextualSystemSettings() {
        let panel = VoiceDictationPanelController()
        var retries = 0

        panel.showFailure(
            "麦克风或语音识别权限已被拒绝。",
            presentation: .microphonePermission,
            anchorRect: anchor,
            onRetry: { retries += 1 },
            onCancel: {}
        )
        var snapshot = panel.testingSnapshot
        XCTAssertFalse(snapshot.retryIsHidden)
        XCTAssertFalse(snapshot.settingsIsHidden, "权限类失败必须给出系统设置入口")
        XCTAssertFalse(snapshot.showsSpinner)
        XCTAssertTrue(snapshot.dotIsVisible)

        panel.showFailure(
            "识别超时。",
            presentation: .transient,
            anchorRect: anchor,
            onRetry: { retries += 1 },
            onCancel: {}
        )
        snapshot = panel.testingSnapshot
        XCTAssertFalse(snapshot.retryIsHidden)
        XCTAssertTrue(snapshot.settingsIsHidden, "非权限类失败不需要系统设置按钮")
        panel.hide()
        XCTAssertEqual(retries, 0)
    }

    // MARK: - 浮窗：会话内宽度单调

    func testPanelWidthIsMonotonicWithinASessionAndResetsBetweenSessions() {
        let panel = VoiceDictationPanelController()
        panel.showConnecting(anchorRect: anchor, onCancel: {})
        let connectingWidth = panel.testingSnapshot.panelSize.width

        let longText = String(repeating: "这是一段需要自动换行并动态调整弹窗高度的语音转写测试内容。", count: 4)
        panel.updatePreview(
            stable: longText,
            partial: "",
            pendingConfirm: false,
            polishApplied: false,
            anchorRect: anchor,
            onConfirm: {},
            onCancel: {}
        )
        let longWidth = panel.testingSnapshot.panelSize.width
        panel.updatePreview(
            stable: "短",
            partial: "",
            pendingConfirm: false,
            polishApplied: false,
            anchorRect: anchor,
            onConfirm: {},
            onCancel: {}
        )
        let revisedWidth = panel.testingSnapshot.panelSize.width

        XCTAssertGreaterThanOrEqual(longWidth, connectingWidth)
        XCTAssertEqual(revisedWidth, longWidth, "ASR 片段由长改短时宽度不得回缩（避免左右呼吸）")
        XCTAssertLessThanOrEqual(longWidth, 380)

        panel.hide()
        panel.showConnecting(anchorRect: anchor, onCancel: {})
        XCTAssertLessThanOrEqual(panel.testingSnapshot.panelSize.width, connectingWidth, "新会话重置宽度")
        panel.hide()
    }

    // MARK: - 快捷键录制器

    func testKeycapCaptureButtonKeepsAFixedWidthInEveryState() {
        let button = SettingsShortcutCaptureButton()
        let width = button.intrinsicContentSize.width
        XCTAssertEqual(width, SettingsShortcutCaptureButton.keycapWidth)

        button.showShortcut("⌃⇧V")
        button.beginCapture()
        XCTAssertEqual(button.intrinsicContentSize.width, width)
        button.showValidationFailure()
        XCTAssertEqual(button.intrinsicContentSize.width, width, "出错抖动时相邻控件不得跳动")
        button.cancelCapture()
        XCTAssertEqual(button.intrinsicContentSize.width, width)
        XCTAssertEqual(button.title, "更改…（当前 ⌃⇧V）")
        XCTAssertEqual(button.accessibilityValue() as? String, "⌃⇧V")
    }
}
