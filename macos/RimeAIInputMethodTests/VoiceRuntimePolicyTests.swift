import AppKit
import XCTest
@testable import RimeAIInputMethod

/// 语音运行时的纯策略：右 ⌘ 点按误触发防护与失活补发松开、启动闸门的
/// 阻断原因、翻译热键注册计划、失败浮窗的动作与去留。
@MainActor
final class VoiceRuntimePolicyTests: XCTestCase {
    // MARK: - 右 ⌘ 点按

    func testPointerGuardDisarmsTapAfterCommandClickOrScroll() {
        var guardState = VoiceModifierTapPointerGuard()
        // 按下时无任何指针活动，松开时也没有：干净的点按。
        guardState.armed(lastPointerActivityAt: nil)
        XCTAssertFalse(guardState.pointerActivityIntervened(lastPointerActivityAt: nil))

        // 按下后发生了 ⌘+点击 / ⌘+滚轮：指针活动时间前移，撤销触发。
        guardState.armed(lastPointerActivityAt: 100)
        XCTAssertTrue(guardState.pointerActivityIntervened(lastPointerActivityAt: 103.5))
        // 撤销后回到全新待命态；下一次按下必须重新 arm。
        XCTAssertEqual(guardState, VoiceModifierTapPointerGuard())

        // 按下期间指针时间不变（同一次事件）：不是组合操作。
        guardState.armed(lastPointerActivityAt: 500)
        XCTAssertFalse(guardState.pointerActivityIntervened(lastPointerActivityAt: 500))

        // 开机后首次指针事件恰好发生在按下期间：同样撤销。
        var firstEver = VoiceModifierTapPointerGuard()
        firstEver.armed(lastPointerActivityAt: nil)
        XCTAssertTrue(firstEver.pointerActivityIntervened(lastPointerActivityAt: 7))
    }

    func testRealPointerActivityQueryReturnsAConsistentTimestamp() {
        let first = VoicePointerActivity.lastPointerEventTimestamp()
        let second = VoicePointerActivity.lastPointerEventTimestamp()
        if let first, let second {
            // 同一时间基：相邻两次查询得到的“最近指针活动时刻”必须一致。
            XCTAssertEqual(first, second, accuracy: 0.05)
        }
    }

    func testToggleDictationReleasesOnDeactivateOnlyWhileRecording() {
        XCTAssertTrue(VoiceModifierTapPolicy.shouldReleaseOnDeactivate(
            isModifierTap: true, phase: .listening(requestID: "request-1")
        ))
        XCTAssertTrue(VoiceModifierTapPolicy.shouldReleaseOnDeactivate(
            isModifierTap: true, phase: .connecting
        ))
        // 收尾/待确认阶段带 requestID：此时再 stop 会打断最终识别，不得补发松开。
        let settledPhases: [VoiceDictationClientPhase] = [
            .finalizing(requestID: "request-1"),
            .pendingConfirm(requestID: "request-1"),
            .idle,
            .disabled,
        ]
        for phase in settledPhases {
            XCTAssertFalse(VoiceModifierTapPolicy.shouldReleaseOnDeactivate(isModifierTap: true, phase: phase))
        }
        XCTAssertFalse(VoiceModifierTapPolicy.shouldReleaseOnDeactivate(
            isModifierTap: false, phase: .listening(requestID: "request-1")
        ))
    }

    func testSecondaryHotKeyPlanActivatesOnlyDistinctSecondaryShortcut() {
        XCTAssertEqual(
            VoiceSecondaryHotKeyPlan.plan(
                secondaryShortcut: nil,
                primaryShortcut: .function
            ),
            .deactivate
        )
        XCTAssertEqual(
            VoiceSecondaryHotKeyPlan.plan(
                secondaryShortcut: .function,
                primaryShortcut: .function
            ),
            .deactivate
        )
        XCTAssertEqual(
            VoiceSecondaryHotKeyPlan.plan(
                secondaryShortcut: .rightCommand,
                primaryShortcut: .function
            ),
            .activate(.rightCommand)
        )
    }

    func testTranslationHotKeyIsDeactivatedWheneverShortcutsMatch() {
        XCTAssertEqual(
            VoiceTranslationHotKeyPlan.plan(translateShortcut: .defaultTranslate, dictationShortcut: .default),
            .activate
        )
        XCTAssertEqual(
            VoiceTranslationHotKeyPlan.plan(translateShortcut: .rightCommand, dictationShortcut: .rightCommand),
            .deactivate
        )
        XCTAssertEqual(
            VoiceTranslationHotKeyPlan.plan(translateShortcut: .function, dictationShortcut: .function),
            .deactivate
        )
        XCTAssertEqual(
            VoiceTranslationHotKeyPlan.plan(
                translateShortcut: .rightCommand,
                dictationShortcut: .function,
                secondaryDictationShortcut: .rightCommand
            ),
            .deactivate
        )
        XCTAssertEqual(
            VoiceTranslationHotKeyPlan.plan(
                translateShortcut: .defaultTranslate,
                dictationShortcut: .function,
                secondaryDictationShortcut: .rightCommand
            ),
            .activate
        )
    }

    // MARK: - 启动闸门

    func testStartGateReportsTheFirstBlockingReason() {
        func blocker(
            voice: Bool = true,
            aiAllowed: Bool = true,
            host: Bool = true,
            composition: Bool = false,
            secure: Bool = false
        ) -> VoiceDictationStartBlocker? {
            VoiceDictationStartGate.blocker(
                voiceEnabled: voice,
                aiAllowed: aiAllowed,
                isHostActive: host,
                hasActiveComposition: composition,
                isSecureInput: secure
            )
        }

        XCTAssertNil(blocker())
        XCTAssertEqual(blocker(voice: false, secure: true), .secureInput, "安全输入优先于其他原因")
        XCTAssertEqual(blocker(voice: false), .voiceDisabled)
        XCTAssertEqual(blocker(aiAllowed: false), .aiDisabledForApplication)
        XCTAssertEqual(blocker(host: false), .hostInactive)
        XCTAssertEqual(blocker(composition: true), .compositionActive)
        for reason in [VoiceDictationStartBlocker.secureInput, .voiceDisabled, .aiDisabledForApplication,
                       .hostInactive, .compositionActive, .helperDisabled, .microphoneDenied]
        {
            XCTAssertFalse(reason.message.isEmpty, "每个阻断原因都必须有面向用户的说明")
        }
    }

    // MARK: - 失败浮窗动作

    func testFailurePresentationOffersSettingsForPermissionsAndAutoDismissesTransientErrors() {
        XCTAssertEqual(
            VoiceFailurePresentation.presentation(for: .micDenied).settingsPane,
            .microphone
        )
        XCTAssertEqual(VoiceFailurePresentation.presentation(for: .micDenied).autoDismissSeconds, nil)

        let transient = VoiceFailurePresentation.presentation(for: .asrTimeout)
        XCTAssertTrue(transient.offersRetry)
        XCTAssertEqual(transient.autoDismissSeconds, 6)

        XCTAssertEqual(
            VoiceFailurePresentation.presentation(for: .incompatibleProtocol).offersRetry,
            false,
            "版本不兼容时重试无效"
        )
        for code in [VoiceDictationErrorCode.micUnavailable, .asrEngineError, .asrOverload, .internalError] {
            XCTAssertEqual(VoiceFailurePresentation.presentation(for: code).autoDismissSeconds, 6)
        }
    }

    // MARK: - 润色/收尾中再次按右 ⌘（策略 A）

    func testRepeatTriggerDecisionCoversEveryPhaseAndTransformingState() {
        XCTAssertEqual(
            VoiceRepeatTriggerDecision.decide(phase: .idle, isTransforming: false),
            .startNewSession
        )
        XCTAssertEqual(
            VoiceRepeatTriggerDecision.decide(phase: .connecting, isTransforming: false),
            .stopRecording
        )
        XCTAssertEqual(
            VoiceRepeatTriggerDecision.decide(
                phase: .listening(requestID: "r1"),
                isTransforming: false
            ),
            .stopRecording
        )
        XCTAssertEqual(
            VoiceRepeatTriggerDecision.decide(
                phase: .pendingConfirm(requestID: "r1"),
                isTransforming: true
            ),
            .flushTransformAndRestart,
            "润色在途再次点按：必须抢占保底上屏并立刻续录"
        )
        XCTAssertEqual(
            VoiceRepeatTriggerDecision.decide(
                phase: .pendingConfirm(requestID: "r1"),
                isTransforming: false
            ),
            .commitPendingAndRestart
        )
        XCTAssertEqual(
            VoiceRepeatTriggerDecision.decide(
                phase: .finalizing(requestID: "r1"),
                isTransforming: false
            ),
            .queueRestartAfterFinalizing
        )
        XCTAssertEqual(
            VoiceRepeatTriggerDecision.decide(phase: .disabled, isTransforming: false),
            .ignoreDisabled
        )
    }

    // MARK: - 全局修饰键去重与 HID 键盘组合防护

    func testModifierEventDeduplicatorDropsDuplicateEdgesWithinWindow() {
        var dedup = VoiceModifierEventDeduplicator()
        XCTAssertTrue(dedup.shouldProcess(keyCode: 54, modifiers: [.command], timestamp: 100.000))
        // 全局监控器与 IMK 控制器同时投递同一物理按下事件：必须只处理一次。
        XCTAssertFalse(dedup.shouldProcess(keyCode: 54, modifiers: [.command], timestamp: 100.002))
        // 松开边沿修饰键不同：正常放行。
        XCTAssertTrue(dedup.shouldProcess(keyCode: 54, modifiers: [], timestamp: 100.120))
        XCTAssertFalse(dedup.shouldProcess(keyCode: 54, modifiers: [], timestamp: 100.123))
        // 超过去重窗口后的下一次独立按下：正常放行。
        XCTAssertTrue(dedup.shouldProcess(keyCode: 54, modifiers: [.command], timestamp: 100.400))
    }

    func testPointerGuardAlsoDisarmsTapWhenHIDKeyDownIntervenes() {
        var guardState = VoiceModifierTapPointerGuard()
        guardState.armed(lastPointerActivityAt: 10.0, lastKeyDownActivityAt: 20.0)
        // 右 ⌘ 按下期间按了 C（即使无输入监控权限，HID keyDown 时间戳前移）：撤销触发。
        XCTAssertTrue(
            guardState.pointerActivityIntervened(
                lastPointerActivityAt: 10.0,
                lastKeyDownActivityAt: 20.08
            )
        )

        // 指针与按键时间均未推进：干净的右 ⌘ 点按。
        guardState.armed(lastPointerActivityAt: 10.0, lastKeyDownActivityAt: 20.08)
        XCTAssertFalse(
            guardState.pointerActivityIntervened(
                lastPointerActivityAt: 10.0,
                lastKeyDownActivityAt: 20.08
            )
        )
    }

    // MARK: - 边说边润色（分句流水线）

    func testIncrementalPolishPipelineCachesPrefixAndReusesOnFinal() {
        var pipeline = VoiceIncrementalPolishPipeline()
        pipeline.reset(style: .concise)

        // 不足最小句长或无句末标点：不派发。
        XCTAssertNil(pipeline.nextChunkToDispatch(stableText: "嗯，你好世界"))
        XCTAssertNil(
            pipeline.nextChunkToDispatch(
                stableText: "这是一段没有句末标点而且还在持续输入的很长的语音识别预览文本"
            )
        )

        let seg1 = "嗯，这个输入法现在有一个很严重的问题就是润色太慢了。"
        let dispatched = pipeline.nextChunkToDispatch(
            stableText: seg1 + "后面还没说完",
            requestIDGenerator: { "inc-1" }
        )
        XCTAssertEqual(dispatched?.requestID, "inc-1")
        XCTAssertEqual(dispatched?.chunk, seg1)
        // 已有在途增量请求时不并发派发第二个。
        XCTAssertNil(pipeline.nextChunkToDispatch(stableText: seg1 + "这是第二句也很长而且结束了。"))

        XCTAssertTrue(
            pipeline.completeInFlight(
                requestID: "inc-1",
                polishedChunk: "这个输入法现在有一个很严重的问题，就是润色太慢了。"
            )
        )

        // 最终文本完全覆盖：0ms 直接出稿。
        XCTAssertEqual(
            pipeline.planForFinal(seg1),
            .completeImmediately(
                polishedText: "这个输入法现在有一个很严重的问题，就是润色太慢了。"
            )
        )

        // 最终文本多出尾部：只发送尾部做小请求。
        XCTAssertEqual(
            pipeline.planForFinal(seg1 + "嗯，希望能优化一下。"),
            .polishTail(
                polishedPrefix: "这个输入法现在有一个很严重的问题，就是润色太慢了。",
                rawTail: "嗯，希望能优化一下。"
            )
        )

        // 若 ASR 最终改写了前缀：安全退回整段润色，不拼接错位文本。
        XCTAssertEqual(
            pipeline.planForFinal("完全被改写的新句子。"),
            .polishFull(rawText: "完全被改写的新句子。")
        )
    }

    func testIncrementalPolishPipelineRejectsTruncatedChunkAndJoinsStructuredLines() {
        var pipeline = VoiceIncrementalPolishPipeline()
        pipeline.reset(style: .structured)

        let longSeg = String(repeating: "这是一段超过八十字的长听写句子用于验证增量润色的截断守卫。", count: 4)
        let dispatched = pipeline.nextChunkToDispatch(
            stableText: longSeg,
            requestIDGenerator: { "inc-long" }
        )
        XCTAssertNotNil(dispatched)
        // 输出不足原文 60%：拒绝并入缓存前缀。
        XCTAssertFalse(
            pipeline.completeInFlight(requestID: "inc-long", polishedChunk: "截断了。")
        )
        XCTAssertEqual(pipeline.completedSourcePrefix, "")

        XCTAssertEqual(
            VoiceIncrementalPolishPipeline.joinPolished(
                "第一，去掉语气词。",
                "第二，做好格式化。",
                style: .structured
            ),
            "第一，去掉语气词。\n第二，做好格式化。"
        )
        XCTAssertEqual(
            VoiceIncrementalPolishPipeline.joinPolished(
                "Hello world.",
                "Next sentence.",
                style: .concise
            ),
            "Hello world. Next sentence."
        )
    }

    // MARK: - 宿主 markedRange 空范围兼容

    func testMarkedRangePolicyTreatsZeroLengthRangeAsEmpty() {
        XCTAssertFalse(
            VoiceClientMarkedRangePolicy.hasMarkedText(
                NSRange(location: NSNotFound, length: 0)
            )
        )
        // Electron / Chromium / 断联 XPC proxy 无组合文本时常返回 {0, 0}。
        XCTAssertFalse(
            VoiceClientMarkedRangePolicy.hasMarkedText(
                NSRange(location: 0, length: 0)
            )
        )
        XCTAssertFalse(
            VoiceClientMarkedRangePolicy.hasMarkedText(
                NSRange(location: 12, length: 0)
            )
        )
        XCTAssertTrue(
            VoiceClientMarkedRangePolicy.hasMarkedText(
                NSRange(location: 0, length: 3)
            )
        )
        XCTAssertTrue(
            VoiceClientMarkedRangePolicy.hasMarkedText(
                NSRange(location: 5, length: 2)
            )
        )
    }

    // MARK: - IMK 光标矩形可用性

    func testCaretRectPolicyAcceptsZeroWidthInsertionPointAndRejectsPlaceholders() {
        // 常规光标矩形原样返回。
        XCTAssertEqual(
            VoiceCaretRectPolicy.normalizedAnchor(
                NSRect(x: 120, y: 300, width: 1, height: 18)
            ),
            NSRect(x: 120, y: 300, width: 1, height: 18)
        )
        // Electron / 微信空输入框的零宽插入点：是真实光标，归一化为 1pt 宽，
        // 下游的 isEmpty 判定才不会把它当成无锚点。
        XCTAssertEqual(
            VoiceCaretRectPolicy.normalizedAnchor(
                NSRect(x: 120, y: 300, width: 0, height: 18)
            ),
            NSRect(x: 120, y: 300, width: 1, height: 18)
        )
        // 未排版出真实光标的占位值、零行高、负宽与非有限坐标一律不可用。
        XCTAssertNil(VoiceCaretRectPolicy.normalizedAnchor(.zero))
        XCTAssertNil(VoiceCaretRectPolicy.normalizedAnchor(
            NSRect(x: 0, y: 0, width: 0, height: 18)
        ))
        XCTAssertNil(VoiceCaretRectPolicy.normalizedAnchor(
            NSRect(x: 120, y: 300, width: 4, height: 0)
        ))
        XCTAssertNil(VoiceCaretRectPolicy.normalizedAnchor(
            NSRect(x: 120, y: 300, width: -1, height: 18)
        ))
        XCTAssertNil(VoiceCaretRectPolicy.normalizedAnchor(
            NSRect(x: CGFloat.nan, y: 300, width: 2, height: 18)
        ))
        XCTAssertNil(VoiceCaretRectPolicy.normalizedAnchor(
            NSRect(x: 120, y: CGFloat.infinity, width: 2, height: 18)
        ))
    }

    // MARK: - 采样式目标校验去抖

    func testTargetValidityDebouncerIgnoresTransientBlipsAndLatchesSustainedInvalidity() {
        var debouncer = VoiceTargetValidityDebouncer()
        let interval = VoiceTargetValidityDebouncer.lockoutInterval

        // 首个无效采样只开始计时，不判定失效。
        XCTAssertFalse(debouncer.noteSample(isValid: false, at: 100))
        // 窗口内恢复有效：清零，不锁死（此前单次抖动就会永久废掉自动上屏）。
        XCTAssertFalse(debouncer.noteSample(isValid: true, at: 100.1))
        XCTAssertNil(debouncer.firstInvalidSampleAt)

        // 连续无效但尚未满窗口：仍不锁死。
        XCTAssertFalse(debouncer.noteSample(isValid: false, at: 200))
        XCTAssertFalse(
            debouncer.noteSample(isValid: false, at: 200 + interval - 0.05)
        )
        // 中途一次有效采样必须让计时重来。
        XCTAssertFalse(
            debouncer.noteSample(isValid: true, at: 200 + interval - 0.02)
        )
        XCTAssertFalse(debouncer.noteSample(isValid: false, at: 400))

        // 真实的焦点切换是持续状态：连续无效满窗口后判定失效，并保持到恢复有效。
        XCTAssertTrue(
            debouncer.noteSample(isValid: false, at: 400 + interval + 0.05)
        )
        XCTAssertTrue(
            debouncer.noteSample(isValid: false, at: 400 + interval + 0.2)
        )
        XCTAssertFalse(debouncer.noteSample(isValid: true, at: 401))
        XCTAssertNil(debouncer.firstInvalidSampleAt)

        // 有效/无效交替的抖动无论持续多久都不会锁死。
        var alternating = VoiceTargetValidityDebouncer()
        for step in 0..<40 {
            XCTAssertFalse(
                alternating.noteSample(
                    isValid: step.isMultiple(of: 2),
                    at: Double(step) * 0.07
                )
            )
        }

        debouncer.reset()
        XCTAssertEqual(debouncer, VoiceTargetValidityDebouncer())
    }

    // MARK: - 录音/处理期焦点暂离与回切恢复

    func testTargetRecoveryPolicyPreservesTargetDuringInProgressPhasesAndLocksOutPendingConfirm() {
        let inProgressPhases: [(VoiceDictationClientPhase, Bool)] = [
            (.connecting, false),
            (.listening(requestID: "r1"), false),
            (.finalizing(requestID: "r1"), false),
            (.pendingConfirm(requestID: "r1"), true),
        ]
        for (phase, isTransforming) in inProgressPhases {
            XCTAssertFalse(
                VoiceSessionTargetRecoveryPolicy.shouldLockOutAutoPasteOnSustainedInvalidity(
                    phase: phase,
                    isTransforming: isTransforming
                ),
                "录音/收尾/润色期间临时失焦（通知弹窗或切窗查资料）不得永久锁死自动上屏"
            )
            XCTAssertTrue(
                VoiceSessionTargetRecoveryPolicy.shouldHandOffControllerToGlobal(
                    phase: phase,
                    isTransforming: isTransforming,
                    isSameApp: false,
                    targetWasEditableAtStart: true,
                    hasTargetPID: true,
                    isGlobalMonitorActive: true
                ),
                "IMK 会话中途切到其他应用时应移交 globalOwner 绑定原 PID，切回原应用后照常上屏"
            )
            XCTAssertFalse(
                VoiceSessionTargetRecoveryPolicy.shouldDetachGlobalSessionOnClaim(
                    phase: phase,
                    isTransforming: isTransforming,
                    targetCurrentlyValid: false
                ),
                "录音/收尾/润色期间其他应用激活 IMK 控制器不得永久拆离绑定原 PID 的全局会话"
            )
        }

        // 开始时本就无光标，或全局监控不可用 / 无原 PID：绝不错误升级。
        XCTAssertFalse(
            VoiceSessionTargetRecoveryPolicy.shouldHandOffControllerToGlobal(
                phase: .listening(requestID: "r1"),
                isTransforming: false,
                isSameApp: false,
                targetWasEditableAtStart: false,
                hasTargetPID: true,
                isGlobalMonitorActive: true
            )
        )
        XCTAssertFalse(
            VoiceSessionTargetRecoveryPolicy.shouldHandOffControllerToGlobal(
                phase: .listening(requestID: "r1"),
                isTransforming: false,
                isSameApp: true,
                targetWasEditableAtStart: true,
                hasTargetPID: true,
                isGlobalMonitorActive: false
            )
        )

        // 手动待确认态（非转换中）：切去其他应用时应立即拆离为常驻复制卡片，同应用切输入法则保留。
        let pending = VoiceDictationClientPhase.pendingConfirm(requestID: "r1")
        XCTAssertTrue(
            VoiceSessionTargetRecoveryPolicy.shouldLockOutAutoPasteOnSustainedInvalidity(
                phase: pending,
                isTransforming: false
            )
        )
        XCTAssertTrue(
            VoiceSessionTargetRecoveryPolicy.shouldHandOffControllerToGlobal(
                phase: pending,
                isTransforming: false,
                isSameApp: true,
                targetWasEditableAtStart: true,
                hasTargetPID: true,
                isGlobalMonitorActive: true
            )
        )
        XCTAssertFalse(
            VoiceSessionTargetRecoveryPolicy.shouldHandOffControllerToGlobal(
                phase: pending,
                isTransforming: false,
                isSameApp: false,
                targetWasEditableAtStart: true,
                hasTargetPID: true,
                isGlobalMonitorActive: true
            )
        )
        XCTAssertTrue(
            VoiceSessionTargetRecoveryPolicy.shouldDetachGlobalSessionOnClaim(
                phase: pending,
                isTransforming: false,
                targetCurrentlyValid: false
            )
        )
        XCTAssertFalse(
            VoiceSessionTargetRecoveryPolicy.shouldDetachGlobalSessionOnClaim(
                phase: pending,
                isTransforming: false,
                targetCurrentlyValid: true
            )
        )
    }
}
