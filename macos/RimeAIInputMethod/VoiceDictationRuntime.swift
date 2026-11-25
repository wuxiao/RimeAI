import AppKit
import ApplicationServices
import Carbon
import Foundation

/// 进程级语音会话宿主。InputMethodKit 可能为不同客户端创建多个
/// controller；语音 socket、状态机和浮层必须只有一份，并在回调上屏前
/// 重新核验最初的 owner、client、应用会话与光标位置。
/// 切换到其他输入法或无输入框时，由 `GlobalVoiceRuntimeOwner` 承接，
/// 保持跨任意应用与输入法的一致体验。
@MainActor
protocol VoiceDictationRuntimeOwner: AnyObject {
    /// 为 true 时表示当前并非由 RimeAI IMK 控制器托管（如系统英文 ABC 或其他输入法），
    /// 上屏统一经由剪贴板 + `⌘V` 回退路径执行。
    var usesClipboardPasteForCommit: Bool { get }

    func voiceRuntimeTargetIsValid(
        client: AnyObject,
        appSessionID: String,
        selection: NSRange,
        anchorRect: NSRect
    ) -> Bool

    func voiceRuntimeCommit(
        _ text: String,
        client: AnyObject,
        appSessionID: String,
        selection: NSRange,
        anchorRect: NSRect
    ) -> Bool

    func voiceRuntimeDidBecomeUnavailable()
    func voiceRuntimeDidBecomeAvailable()
    func voiceRuntimeSecureInputDetected()
}

extension VoiceDictationRuntimeOwner {
    var usesClipboardPasteForCommit: Bool { false }
}

/// 跨输入法全局会话的轻量宿主：当用户切换到 ABC、第三方输入法或非 IMK 区域时
/// 负责核验前台应用未切换、拒绝 Secure Input 并把上屏交给 `VoiceClipboardPaster`。
@MainActor
private final class GlobalVoiceRuntimeOwner: VoiceDictationRuntimeOwner {
    var targetFrontmostPID: pid_t?
    var usesClipboardPasteForCommit: Bool { true }

    func voiceRuntimeTargetIsValid(
        client: AnyObject,
        appSessionID: String,
        selection: NSRange,
        anchorRect: NSRect
    ) -> Bool {
        guard !IsSecureEventInputEnabled(),
              let expectedPID = targetFrontmostPID,
              let currentPID = NSWorkspace.shared.frontmostApplication?
                  .processIdentifier
        else {
            return false
        }
        return currentPID == expectedPID
    }

    func voiceRuntimeCommit(
        _ text: String,
        client: AnyObject,
        appSessionID: String,
        selection: NSRange,
        anchorRect: NSRect
    ) -> Bool {
        // 全局会话无 IMKTextInput，返回 false 交由 VoiceClipboardPaster（⌘V）上屏。
        false
    }

    func voiceRuntimeDidBecomeUnavailable() {
        VoiceGlobalHotKeyService.shared.reconcileHotKeys()
    }

    func voiceRuntimeDidBecomeAvailable() {
        VoiceGlobalHotKeyService.shared.reconcileHotKeys()
    }

    func voiceRuntimeSecureInputDetected() {
        VoiceDictationRuntime.shared.handleGlobalSecureInputDetected()
    }
}

@MainActor
final class VoiceDictationRuntime {
    static let shared = VoiceDictationRuntime()

    private let coordinator: VoiceDictationCoordinator
    private let panel = VoiceDictationPanelController()
    private let settings = RimeAISettingsStore.shared
    private let soundPlayer = VoiceSoundEffectsPlayer.shared
    private let audioMuter = VoiceSystemAudioMuter.shared
    private let historyService = VoiceHistoryService.shared
    private let globalOwner = GlobalVoiceRuntimeOwner()

    private weak var activeOwner: (any VoiceDictationRuntimeOwner)?
    private weak var currentOwner: (any VoiceDictationRuntimeOwner)?
    private weak var targetClient: AnyObject?
    private var targetAppSessionID: String?
    private var targetBundleIdentifier: String = "unknown-client"
    private var targetFrontmostPID: pid_t?
    private var targetSelection = NSRange(location: NSNotFound, length: 0)
    private var anchorRect = NSRect.zero
    private var hasEditableTarget = false
    private var validationTimer: DispatchSourceTimer?
    private var observedPhase: VoiceDictationClientPhase = .idle
    private var activeGeneration: UUID?
    private var activeIntent: VoiceSessionIntent = .dictation
    private var activeHotwords: [String] = []
    private var sessionStartedAt: Date?
    private var recordingDurationMilliseconds: Int = 0
    /// 云端润色/翻译在途：供按键路由判定“空格/回车直接上屏原文”以及右 ⌘ 抢占续录。
    private(set) var isTransforming = false
    /// 开始听写时是否存在可自动上屏的光标；用于区分“未检测到光标”与“焦点已切换”。
    private var targetWasEditableAtStart = false
    private var activeTransformRequestID: String?
    private var incrementalPolish = VoiceIncrementalPolishPipeline()
    private var pendingRestartAfterFinalizing: (
        intent: VoiceSessionIntent,
        onReadyToRestart: () -> Void
    )?
    private var pendingRawText: String?
    private var pendingPostProcessedText: String?
    private var pendingActionKind: VoicePostProcessAction = .dictation
    private var pendingPolishStyle: VoicePolishStyle?
    private var pendingTargetLanguage: VoiceTranslationLanguage?
    private var confirming = false
    private var recordedPreview = false
    private var recordedFinal = false
    private var permissionBlocked = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        coordinator = VoiceDictationCoordinator(configuration: .init(
            socketPath: layout.voiceSocket.path,
            transportPreference: .currentBuildConfiguration,
            // 不限制录音时长与句间停顿：录音期间不设 delta 超时，
            // 仅在用户主动结束或取消时收尾。
            deltaTimeout: nil
        ))
        configureCallbacks(generation: nil)
        observeProcessState()
        VoicePostCommitEditTracker.shared.onCorrectionsLearned = {
            [weak self] corrections, anchorRect in
            self?.presentLearnedCorrectionToast(
                corrections: corrections,
                anchorRect: anchorRect
            )
        }
    }

    private func presentLearnedCorrectionToast(
        corrections: [VoiceLearnedCorrection],
        anchorRect: NSRect
    ) {
        guard !corrections.isEmpty,
              phase == .idle,
              !isTransforming,
              !isShowingPersistentCopy,
              !IsSecureEventInputEnabled()
        else {
            return
        }
        let summary = corrections
            .prefix(2)
            .map { "\($0.wrongText) → \($0.correctedText)" }
            .joined(separator: "、")
        panel.showTransientToast(
            title: "已自动收录热词",
            message: summary,
            anchorRect: anchorRect,
            durationSeconds: 2.0
        )
    }

    var phase: VoiceDictationClientPhase {
        coordinator.phaseForTesting
    }

    var isShowingPersistentCopy: Bool {
        panel.isPersistentCopyVisible
    }

    var currentIntent: VoiceSessionIntent {
        activeIntent
    }

    /// 运行时层面的启动阻断原因（麦克风权限被拒后的进程内停用、连续失败熔断）。
    /// 控制器据此给出提示，而不是静默无反应。
    var startBlocker: VoiceDictationStartBlocker? {
        if permissionBlocked {
            return .microphoneDenied
        }
        if case .disabled = phase {
            return .helperDisabled
        }
        return nil
    }

    var isPermissionBlocked: Bool {
        permissionBlocked
    }

    /// 语音听写被阻断时的即时提示；已有常驻复制卡片时不抢占其位置。
    func presentStartBlockedToast(
        _ blocker: VoiceDictationStartBlocker,
        anchorRect: NSRect
    ) {
        guard activeOwner == nil, !isShowingPersistentCopy else {
            return
        }
        let anchor = anchorRect.isEmpty ? fallbackAnchorRect() : anchorRect
        panel.showTransientToast(
            title: VoiceDictationStartBlocker.toastTitle,
            message: blocker.message,
            anchorRect: anchor,
            durationSeconds: 3.5
        )
    }

    func fallbackAnchorRect() -> NSRect {
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y, width: 1, height: 20)
    }

    var canRegisterHotKey: Bool {
        guard !permissionBlocked else {
            return false
        }
        if case .disabled = phase {
            return false
        }
        return true
    }

    func isActive(owner: any VoiceDictationRuntimeOwner) -> Bool {
        guard activeOwner === owner else {
            return false
        }
        if isTransforming {
            return true
        }
        switch phase {
        case .connecting, .listening, .finalizing, .pendingConfirm:
            return true
        case .idle, .disabled:
            return confirming
        }
    }

    func isPendingConfirmation(
        owner: any VoiceDictationRuntimeOwner
    ) -> Bool {
        guard activeOwner === owner, !isTransforming else {
            return false
        }
        if case .pendingConfirm = phase {
            return true
        }
        return false
    }

    var isGlobalSessionActive: Bool {
        guard activeOwner === globalOwner else {
            return false
        }
        if isTransforming {
            return true
        }
        switch phase {
        case .connecting, .listening, .finalizing, .pendingConfirm:
            return true
        case .idle, .disabled:
            return confirming
        }
    }

    func claim(owner: any VoiceDictationRuntimeOwner) {
        if let activeOwner, activeOwner !== owner {
            // 若当前是同一前台应用内的全局会话，保留它以便切回 RimeAI 后照常上屏。
            let keepGlobalSession = activeOwner === globalOwner
                && globalOwner.voiceRuntimeTargetIsValid(
                    client: globalOwner,
                    appSessionID: targetAppSessionID ?? "",
                    selection: targetSelection,
                    anchorRect: anchorRect
                )
            if !keepGlobalSession {
                detachTargetIfActive()
            }
        } else if !isShowingPersistentCopy {
            panel.hide()
        }
        currentOwner = owner
    }

    /// 跨输入法全局启动听写（例如当前使用英文 ABC / 第三方输入法，或焦点不在 IMK 输入框）。
    @discardableResult
    func startGlobal(intent: VoiceSessionIntent = .dictation) -> Bool {
        if let blocker = startBlocker {
            presentStartBlockedToast(blocker, anchorRect: fallbackAnchorRect())
            return false
        }
        if IsSecureEventInputEnabled() {
            settings.record(.privacyBlocked)
            presentStartBlockedToast(.secureInput, anchorRect: fallbackAnchorRect())
            handleGlobalSecureInputDetected()
            return false
        }
        guard settings.aiEnabled, settings.voiceEnabled else {
            presentStartBlockedToast(.voiceDisabled, anchorRect: fallbackAnchorRect())
            return false
        }
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontApp?.bundleIdentifier ?? "unknown-client"
        guard settings.isAIAllowed(for: bundleID) else {
            presentStartBlockedToast(
                .aiDisabledForApplication,
                anchorRect: fallbackAnchorRect()
            )
            return false
        }
        globalOwner.targetFrontmostPID = frontApp?.processIdentifier
        currentOwner = globalOwner
        let anchor = globalAnchorRect()
        let sessionID = "global#\(bundleID)#\(UUID().uuidString)"
        return start(
            owner: globalOwner,
            client: globalOwner,
            context: VoiceDictationSessionContext(
                compositionID: UUID(),
                appSessionID: sessionID,
                bundleID: bundleID,
                deadlineMilliseconds: VoiceSessionTiming
                    .finalizationDeadlineMilliseconds,
                maximumDurationMilliseconds: VoiceDictationConstants
                    .unlimitedDurationMilliseconds,
                hotwordSnapshot: globalHotwordSnapshot(forBundleIdentifier: bundleID)
            ),
            selection: NSRange(location: NSNotFound, length: 0),
            anchorRect: anchor,
            hasEditableTarget: frontApp != nil,
            intent: intent
        )
    }

    func cancelActiveGlobalSession() {
        guard activeOwner === globalOwner else {
            return
        }
        cancel(owner: globalOwner)
    }

    func commitRawDuringGlobalTransform() {
        guard activeOwner === globalOwner, isTransforming else {
            return
        }
        commitRawDuringTransform(owner: globalOwner)
    }

    func handleGlobalSecureInputDetected() {
        VoicePostCommitEditTracker.shared.cancelForSecureInput()
        cancelActiveTransform()
        audioMuter.restoreImmediately()
        coordinator.secureInputChanged(active: true)
        panel.hide()
        if activeOwner != nil {
            settings.record(.voiceCancelled)
            clearTarget(hidePanel: true)
        }
    }

    /// IMK 控制器失活（切换输入法或切换应用）：
    /// - 若启用了全局监控且仍在同一前台应用（纯切换输入法），将活跃录音/润色平滑升级为
    ///   全局会话继续进行，不会中断或丢失。
    /// - 若已切换到其他应用，则保留听写与结果但关闭自动上屏（防误插到错误窗口）。
    func controllerDidDeactivate(owner: any VoiceDictationRuntimeOwner) {
        if activeOwner === owner {
            let currentFrontmostPID = NSWorkspace.shared.frontmostApplication?
                .processIdentifier
            let isSameApp = targetFrontmostPID != nil
                && currentFrontmostPID == targetFrontmostPID
            let isOngoing: Bool
            switch phase {
            case .connecting, .listening, .finalizing, .pendingConfirm:
                isOngoing = true
            case .idle, .disabled:
                isOngoing = isTransforming
            }
            if isSameApp,
               isOngoing,
               VoiceGlobalHotKeyService.shared.isGlobalMonitorActive
            {
                globalOwner.targetFrontmostPID = targetFrontmostPID
                activeOwner = globalOwner
                currentOwner = globalOwner
                targetClient = globalOwner
                return
            }
            detachTargetIfActive()
        } else if currentOwner === owner, !isShowingPersistentCopy {
            panel.hide()
        }
        if currentOwner === owner {
            currentOwner = nil
        }
    }

    private func globalHotwordSnapshot(
        forBundleIdentifier bundleIdentifier: String
    ) -> VoiceHotwordSnapshot {
        guard settings.voiceEnabled,
              settings.isAIAllowed(for: bundleIdentifier),
              !IsSecureEventInputEnabled()
        else {
            return .empty
        }
        let phraseBookPhrases: [String]
        if settings.voicePhraseBookHotwordsEnabled,
           settings.contextPolicy(for: bundleIdentifier) != .strict
        {
            phraseBookPhrases = RimeAIPhraseBookService.shared
                .voiceHotwordCandidates(
                    forBundleIdentifier: bundleIdentifier,
                    limit: 96
                )
        } else {
            phraseBookPhrases = []
        }
        return VoiceHotwordMerger.merge(
            customPhrases: settings.voiceCustomHotwords,
            phraseBookPhrases: phraseBookPhrases,
            sessionRimePhrases: []
        )
    }

    private func globalAnchorRect() -> NSRect {
        // 只查询聚焦控件的几何位置（绝不读取任何文本内容），不可得时退回鼠标位置。
        if AXIsProcessTrusted() {
            let systemWide = AXUIElementCreateSystemWide()
            var focusedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &focusedRef
            ) == .success,
               let focused = focusedRef
            {
                let element = focused as! AXUIElement
                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    element,
                    kAXPositionAttribute as CFString,
                    &posRef
                ) == .success,
                   AXUIElementCopyAttributeValue(
                       element,
                       kAXSizeAttribute as CFString,
                       &sizeRef
                   ) == .success,
                   let posValue = posRef,
                   let sizeValue = sizeRef
                {
                    var origin = CGPoint.zero
                    var size = CGSize.zero
                    if AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
                       AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
                       size.width > 0, size.height > 0,
                       let primaryHeight = NSScreen.screens.first?.frame.height
                    {
                        // AX 坐标原点在主屏左上角，转换为 AppKit 左下角坐标。
                        let cocoaY = primaryHeight - origin.y - min(size.height, 24)
                        return NSRect(
                            x: origin.x + 8,
                            y: cocoaY,
                            width: 2,
                            height: min(max(size.height, 18), 24)
                        )
                    }
                }
            }
        }
        return fallbackAnchorRect()
    }

    @discardableResult
    func start(
        owner: any VoiceDictationRuntimeOwner,
        client: AnyObject,
        context: VoiceDictationSessionContext,
        selection: NSRange,
        anchorRect: NSRect,
        hasEditableTarget: Bool = true,
        intent: VoiceSessionIntent = .dictation
    ) -> Bool {
        guard currentOwner === owner else {
            return false
        }
        guard !IsSecureEventInputEnabled() else {
            owner.voiceRuntimeSecureInputDetected()
            return false
        }
        guard phase == .idle else {
            return false
        }
        // 麦克风权限被拒或服务熔断后不再反复连接 helper：由调用方给出原因提示。
        guard startBlocker == nil else {
            return false
        }
        if isShowingPersistentCopy {
            panel.hide()
        }
        if let previousOwner = activeOwner, previousOwner !== owner {
            invalidateActiveSession(reason: .sessionSwitch)
        }

        let effectiveEditableTarget = hasEditableTarget
            && owner.voiceRuntimeTargetIsValid(
                client: client,
                appSessionID: context.appSessionID,
                selection: selection,
                anchorRect: anchorRect
            )

        activeOwner = owner
        currentOwner = owner
        targetClient = client
        targetAppSessionID = context.appSessionID
        targetBundleIdentifier = context.bundleID
        targetFrontmostPID = NSWorkspace.shared.frontmostApplication?
            .processIdentifier
        targetSelection = selection
        self.anchorRect = anchorRect
        self.hasEditableTarget = effectiveEditableTarget
        targetWasEditableAtStart = effectiveEditableTarget
        activeIntent = intent
        activeHotwords = context.hotwordSnapshot.phrases
        sessionStartedAt = Date()
        recordingDurationMilliseconds = 0
        isTransforming = false
        activeTransformRequestID = nil
        incrementalPolish.reset(style: settings.voicePolishStyle)
        pendingRestartAfterFinalizing = nil
        pendingRawText = nil
        pendingPostProcessedText = nil
        pendingActionKind = intent.isTranslation ? .translate : .dictation
        pendingPolishStyle = nil
        pendingTargetLanguage = nil
        confirming = false
        recordedPreview = false
        recordedFinal = false
        let generation = UUID()
        activeGeneration = generation
        configureCallbacks(generation: generation)
        coordinator.secureInputChanged(active: false)
        coordinator.startDictation(context)

        guard phase == .connecting else {
            clearTarget(hidePanel: true)
            return false
        }
        observedPhase = phase
        settings.record(.voiceStarted)

        // 先播放开始提示音，再延时静音系统输出，确保启动提示音清晰可听。
        let playSound = settings.voiceSoundEffectsEnabled
        if playSound {
            soundPlayer.play(.start, enabled: true)
        }
        audioMuter.beginMuting(
            afterMilliseconds: playSound
                ? VoiceSoundEffectsPlayer.startSoundLeadInMilliseconds
                : 0,
            enabled: settings.voiceMuteSystemAudioEnabled
        )

        panel.showConnecting(
            intent: intent,
            anchorRect: anchorRect,
            onCancel: cancellationHandler(
                owner: owner,
                generation: generation
            )
        )
        startValidationTimer()
        return true
    }

    func stop(owner: any VoiceDictationRuntimeOwner) {
        guard activeOwner === owner else {
            return
        }
        stopCurrentSession(owner: owner)
    }

    /// 跨控制器结束当前活跃录音（例如录音中途焦点切换后再按一次右 ⌘ 结束）。
    func stopActiveSession() {
        guard let owner = activeOwner else {
            return
        }
        stopCurrentSession(owner: owner)
    }

    private func stopCurrentSession(owner: any VoiceDictationRuntimeOwner) {
        let previousPhase = phase
        // 停止录音时立即恢复系统音频，随后播放停止提示音。
        audioMuter.restoreImmediately()
        if let startedAt = sessionStartedAt {
            recordingDurationMilliseconds = max(
                0,
                Int(Date().timeIntervalSince(startedAt) * 1_000)
            )
        }
        coordinator.stopDictation()
        switch previousPhase {
        case .listening:
            settings.record(.voiceStopped)
            soundPlayer.play(.stop)
            observedPhase = phase
            panel.showFinalizing(
                intent: activeIntent,
                anchorRect: anchorRect,
                onCancel: cancellationHandler(owner: owner)
            )
        case .connecting:
            // 松开发生在 helper 完成握手之前：本次录音从未启动。
            soundPlayer.play(.cancel)
            clearTarget(hidePanel: true)
        case .idle, .finalizing, .pendingConfirm, .disabled:
            break
        }
    }

    @discardableResult
    func copyPersistentPanelToPasteboard() -> Bool {
        panel.triggerCopyFromShortcut()
    }

    func dismissPersistentCopyPanel() {
        guard isShowingPersistentCopy else {
            return
        }
        panel.hide()
    }

    func confirm(owner: any VoiceDictationRuntimeOwner) {
        guard activeOwner === owner,
              isPendingConfirmation(owner: owner)
        else {
            return
        }
        confirming = true
        coordinator.userConfirmed()
        observedPhase = phase
    }

    /// 润色/翻译进行中按下空格或回车：取消在途的云端/本地转换，把已识别
    /// 的原文作为最终文本走正常上屏流程（历史、自动粘贴与降级策略全部沿用）。
    func commitRawDuringTransform(owner: any VoiceDictationRuntimeOwner) {
        guard activeOwner === owner,
              isTransforming,
              let generation = activeGeneration
        else {
            return
        }
        let rawText = (pendingRawText ?? "")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            return
        }
        cancelActiveTransform()
        let plan = VoiceTransformRawCommit.plan(for: activeIntent)
        completePostProcessing(
            finalText: rawText,
            rawText: rawText,
            actionKind: plan.actionKind,
            polishStyle: plan.polishStyle,
            targetLanguage: plan.targetLanguage,
            polishApplied: plan.polishApplied,
            customStatus: plan.status,
            owner: owner,
            generation: generation
        )
    }

    /// 策略 A：润色/翻译进行中再次按右 ⌘（或触发语音快捷键）：
    /// 立刻中止慢云端请求，用本地 0ms 润色保底上屏上一句（绝不丢字），随后无缝开启新一轮录音。
    func flushTransformAndRestart(
        intent: VoiceSessionIntent,
        onReadyToRestart: @escaping () -> Void
    ) {
        guard isTransforming, let owner = activeOwner else {
            onReadyToRestart()
            return
        }
        let rawText = (pendingRawText ?? "")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let previousIntent = activeIntent
        cancelActiveTransform()

        let finalText: String
        let actionKind: VoicePostProcessAction
        let polishStyle: VoicePolishStyle?
        if previousIntent.isTranslation {
            finalText = VoiceLocalPolisher.polish(rawText, style: .concise).text
            actionKind = .dictation
            polishStyle = nil
        } else {
            let style = settings.voicePolishStyle
            let localResult = VoiceLocalPolisher.polish(rawText, style: style)
            finalText = localResult.text
            actionKind = localResult.modified ? .polish : .dictation
            polishStyle = localResult.modified ? style : nil
        }

        let usedCommandV = commitSynchronouslyAndClear(
            finalText: finalText,
            rawText: rawText,
            actionKind: actionKind,
            polishStyle: polishStyle,
            targetLanguage: nil,
            owner: owner
        )
        invokeRestart(afterCommandVPaste: usedCommandV, onReadyToRestart)
    }

    /// 手动待确认态再次触发快捷键：先把上一句已就绪结果上屏，随后立即开始新一轮录音。
    func commitPendingAndRestart(
        intent: VoiceSessionIntent,
        onReadyToRestart: @escaping () -> Void
    ) {
        guard case .pendingConfirm = phase,
              !isTransforming,
              let owner = activeOwner
        else {
            onReadyToRestart()
            return
        }
        let rawText = pendingRawText ?? ""
        let finalText = pendingPostProcessedText ?? rawText
        let usedCommandV = commitSynchronouslyAndClear(
            finalText: finalText,
            rawText: rawText,
            actionKind: pendingActionKind,
            polishStyle: pendingPolishStyle,
            targetLanguage: pendingTargetLanguage,
            owner: owner
        )
        invokeRestart(afterCommandVPaste: usedCommandV, onReadyToRestart)
    }

    /// ASR 正在最终收尾阶段再次按右 ⌘：不丢弃当前音频，记下续录意图，
    /// 等 final 到达后立即本地 0ms 润色上屏并自动开启新一轮录音。
    func queueRestartAfterFinalizing(
        intent: VoiceSessionIntent,
        onReadyToRestart: @escaping () -> Void
    ) {
        guard case .finalizing = phase else {
            onReadyToRestart()
            return
        }
        pendingRestartAfterFinalizing = (
            intent: intent,
            onReadyToRestart: onReadyToRestart
        )
    }

    private func invokeRestart(
        afterCommandVPaste usedCommandV: Bool,
        _ onReadyToRestart: @escaping () -> Void
    ) {
        if usedCommandV {
            // 给 ⌘V 粘贴事件留出极短落地窗口，避免新会话在粘贴完成前采样旧光标选区。
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) {
                onReadyToRestart()
            }
        } else {
            onReadyToRestart()
        }
    }

    /// 同步把文本上屏并释放当前会话（用于策略 A 无缝续录前保底交付上一句）。
    /// 返回是否走了 `VoiceClipboardPaster` 合成 `⌘V` 路径。
    private func commitSynchronouslyAndClear(
        finalText: String,
        rawText: String,
        actionKind: VoicePostProcessAction,
        polishStyle: VoicePolishStyle?,
        targetLanguage: VoiceTranslationLanguage?,
        owner: any VoiceDictationRuntimeOwner
    ) -> Bool {
        let allowsNewlines = actionKind == .polish && polishStyle == .structured
        var cleanedFinal = Self.normalizeFinalOutput(
            finalText,
            allowsNewlines: allowsNewlines
        )
        if actionKind != .translate {
            cleanedFinal = applyLearnedCorrectionsIfAllowed(cleanedFinal)
        }
        let bundleID = targetBundleIdentifier
        let durationMs = recordingDurationMilliseconds
        let autoPasteEnabled = settings.voiceAutoPasteEnabled
        let targetStillEditable = hasEditableTarget && targetIsValid(owner: owner)
        let savedClient = targetClient
        let savedAppSessionID = targetAppSessionID
        let savedSelection = targetSelection
        let savedAnchor = anchorRect

        // 先结束旧 coordinator 会话，确保新会话 start() 时状态机已回到 idle。
        coordinator.userCancelled()
        audioMuter.restoreImmediately()

        guard !cleanedFinal.isEmpty, !IsSecureEventInputEnabled() else {
            clearTarget(hidePanel: true)
            return false
        }

        var committed = false
        var usedCommandV = false
        if targetStillEditable,
           let client = savedClient,
           let appSessionID = savedAppSessionID
        {
            if !owner.usesClipboardPasteForCommit {
                committed = owner.voiceRuntimeCommit(
                    cleanedFinal,
                    client: client,
                    appSessionID: appSessionID,
                    selection: savedSelection,
                    anchorRect: savedAnchor
                )
            }
            if !committed, autoPasteEnabled || owner.usesClipboardPasteForCommit {
                let outcome = VoiceClipboardPaster.paste(cleanedFinal)
                usedCommandV = outcome == .pastedViaCommandV
                committed = usedCommandV
            }
        } else {
            // 焦点已离开仍保底写入剪贴板与语音历史，防止无缝续录时丢失上一句。
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            _ = pasteboard.setString(cleanedFinal, forType: .string)
        }

        settings.record(.voiceAccepted)
        if actionKind == .polish {
            settings.record(.voicePolished)
        }
        if committed, autoPasteEnabled {
            settings.record(.voiceAutoPasted)
        }
        recordVoiceHistory(
            bundleID: bundleID,
            rawText: rawText,
            finalText: cleanedFinal,
            actionKind: actionKind,
            polishStyle: polishStyle,
            targetLanguage: targetLanguage,
            durationMs: durationMs,
            autoPasted: committed
        )
        clearTarget(hidePanel: true)
        return usedCommandV
    }

    func cancel(
        owner: any VoiceDictationRuntimeOwner,
        preserveTransformingDraftInHistory: Bool = false
    ) {
        guard activeOwner === owner else {
            if currentOwner === owner {
                panel.hide()
            }
            return
        }
        if preserveTransformingDraftInHistory,
           isTransforming,
           let raw = pendingRawText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty
        {
            let style = settings.voicePolishStyle
            let local = VoiceLocalPolisher.polish(raw, style: style)
            recordVoiceHistory(
                bundleID: targetBundleIdentifier,
                rawText: raw,
                finalText: local.text,
                actionKind: local.modified ? .polish : .dictation,
                polishStyle: local.modified ? style : nil,
                targetLanguage: nil,
                durationMs: recordingDurationMilliseconds,
                autoPasted: false
            )
        }
        let wasActive = isActive(owner: owner)
        cancelActiveTransform()
        audioMuter.restoreImmediately()
        coordinator.userCancelled()
        if wasActive {
            settings.record(.voiceCancelled)
            soundPlayer.play(.cancel)
        }
        clearTarget(hidePanel: true)
    }

    func sessionSwitched(owner: any VoiceDictationRuntimeOwner) {
        guard activeOwner === owner else {
            if currentOwner === owner, !isShowingPersistentCopy {
                panel.hide()
            }
            return
        }
        detachTargetIfActive()
    }

    func secureInputChanged(
        active: Bool,
        owner: any VoiceDictationRuntimeOwner
    ) {
        coordinator.secureInputChanged(active: active)
        guard active else {
            return
        }
        VoicePostCommitEditTracker.shared.cancelForSecureInput()
        cancelActiveTransform()
        audioMuter.restoreImmediately()
        panel.hide()
        if activeOwner === owner {
            settings.record(.voiceCancelled)
            clearTarget(hidePanel: true)
        }
    }

    func deactivate(owner: any VoiceDictationRuntimeOwner) {
        if activeOwner === owner {
            detachTargetIfActive()
        } else if currentOwner === owner, !isShowingPersistentCopy {
            panel.hide()
        }
        if currentOwner === owner {
            currentOwner = nil
        }
        VoiceHotKeyManager.shared.deactivate(owner: owner)
    }

    func dismissTransientPanel(owner: any VoiceDictationRuntimeOwner) {
        guard currentOwner === owner,
              activeOwner == nil,
              !isShowingPersistentCopy
        else {
            return
        }
        panel.hide()
    }

    func shutdown() {
        VoicePostCommitEditTracker.shared.clearEphemeralData()
        cancelActiveTransform()
        audioMuter.restoreImmediately()
        if let activeOwner {
            coordinator.sessionSwitched()
            VoiceHotKeyManager.shared.deactivate(owner: activeOwner)
        } else if let currentOwner {
            VoiceHotKeyManager.shared.deactivate(owner: currentOwner)
        }
        validationTimer?.cancel()
        validationTimer = nil
        panel.hide()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        coordinator.shutdown()
        setPermissionBlocked(false)
        activeGeneration = nil
        activeOwner = nil
        currentOwner = nil
        targetClient = nil
        targetAppSessionID = nil
    }

    // MARK: - Coordinator Callbacks

    private func configureCallbacks(generation: UUID?) {
        coordinator.setCallbacks(
            onPreview: { [weak self] stable, partial,
                         pendingConfirm, polishApplied in
                MainActor.assumeIsolated {
                    self?.handlePreview(
                        stable: stable,
                        partial: partial,
                        pendingConfirm: pendingConfirm,
                        polishApplied: polishApplied,
                        generation: generation
                    )
                }
            },
            onCommit: { [weak self] text in
                MainActor.assumeIsolated {
                    self?.handleCommit(text, generation: generation) ?? false
                }
            },
            onPhaseChanged: { [weak self] phase in
                MainActor.assumeIsolated {
                    self?.handlePhaseChanged(
                        phase,
                        generation: generation
                    )
                }
            },
            onAnnounce: { [weak self] code in
                MainActor.assumeIsolated {
                    self?.handleFailure(code, generation: generation)
                }
            },
            onMicrophoneAuthorizationNeeded: { [weak self] in
                MainActor.assumeIsolated {
                    self?.handleMicrophoneDenied(generation: generation)
                }
            },
            onDisabled: { [weak self] in
                MainActor.assumeIsolated {
                    self?.handleDisabled(generation: generation)
                }
            }
        )
    }

    private func handlePreview(
        stable: String,
        partial: String,
        pendingConfirm: Bool,
        polishApplied: Bool,
        generation: UUID?
    ) {
        guard let generation, generation == activeGeneration else {
            return
        }
        guard let owner = activeOwner else {
            return
        }
        if hasEditableTarget, !targetIsValid(owner: owner) {
            hasEditableTarget = false
        }
        if pendingConfirm {
            audioMuter.restoreImmediately()
            if recordingDurationMilliseconds == 0, let startedAt = sessionStartedAt {
                recordingDurationMilliseconds = max(
                    0,
                    Int(Date().timeIntervalSince(startedAt) * 1_000)
                )
            }
            if !recordedFinal {
                settings.record(.voiceFinalShown)
                recordedFinal = true
            }
            observedPhase = phase
            let rawText = (stable + partial).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            beginPostProcessing(
                rawText: rawText,
                asrPolishApplied: polishApplied,
                owner: owner,
                generation: generation
            )
            return
        }
        if !recordedPreview {
            settings.record(.voicePreviewShown)
            recordedPreview = true
        }
        observedPhase = phase
        scheduleIncrementalPolishIfNeeded(
            stable: stable,
            generation: generation
        )
        panel.updatePreview(
            stable: stable,
            partial: partial,
            pendingConfirm: false,
            polishApplied: polishApplied,
            intent: activeIntent,
            anchorRect: anchorRect,
            onConfirm: {},
            onCancel: cancellationHandler(
                owner: owner,
                generation: generation
            )
        )
    }

    // MARK: - Incremental Pipelined Polish (边说边润色)

    private func scheduleIncrementalPolishIfNeeded(
        stable: String,
        generation: UUID
    ) {
        guard activeIntent == .dictation,
              settings.voiceSmartPolishEnabled,
              settings.cloudConfigured,
              !IsSecureEventInputEnabled(),
              !stable.isEmpty,
              let apiKey = try? FileCloudCredentialStore.shared.loadAPIKey(),
              !apiKey.isEmpty
        else {
            return
        }
        let normalizedStable = applyLearnedCorrectionsIfAllowed(stable)
        guard let next = incrementalPolish.nextChunkToDispatch(
            stableText: normalizedStable
        ) else {
            return
        }
        let style = settings.voicePolishStyle
        let resolvedModel = CloudBrokerClient.shared.resolvedModelID(
            for: settings.cloudModelID
        )
        let request = CloudVoiceTransformRequest(
            requestID: next.requestID,
            clientSessionID: targetAppSessionID ?? "voice-session",
            bundleIdentifier: targetBundleIdentifier,
            modelID: resolvedModel,
            task: .polish,
            text: next.chunk,
            style: style,
            targetLanguage: nil,
            hotwords: VoiceCloudHotwordPolicy.cloudHotwords(
                isEnabled: settings.voiceCloudHotwordsEnabled,
                activeHotwords: activeHotwords
            ),
            deadlineMilliseconds: VoiceIncrementalPolishPipeline
                .incrementalDeadlineMilliseconds
        )
        CloudBrokerClient.shared.transformVoiceText(
            request,
            apiKey: apiKey
        ) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, self.activeGeneration == generation else {
                    return
                }
                if let response,
                   let polished = VoiceTransformTextPolicy.sanitizedOutput(
                       response,
                       for: request
                   )
                {
                    self.incrementalPolish.completeInFlight(
                        requestID: next.requestID,
                        polishedChunk: polished
                    )
                } else {
                    self.incrementalPolish.failInFlight(requestID: next.requestID)
                }
            }
        }
    }

    // MARK: - Post-Processing (Smart Polish & Translation)

    private func applyLearnedCorrectionsIfAllowed(_ text: String) -> String {
        guard !text.isEmpty,
              !IsSecureEventInputEnabled(),
              settings.voiceAutoLearnCorrectionsEnabled,
              settings.contextPolicy(for: targetBundleIdentifier) != .strict
        else {
            return text
        }
        let corrections = settings.voiceLearnedCorrections
        guard !corrections.isEmpty else {
            return text
        }
        return VoiceLearnedCorrectionApplier.apply(
            text,
            corrections: corrections
        )
    }

    private func beginPostProcessing(
        rawText: String,
        asrPolishApplied: Bool,
        owner: any VoiceDictationRuntimeOwner,
        generation: UUID
    ) {
        let normalizedRaw = applyLearnedCorrectionsIfAllowed(rawText)
        pendingRawText = normalizedRaw

        // 若用户在 finalizing 阶段已经按了右 ⌘ 续录：不等待慢云端，0ms 本地润色上屏后立即开启下一轮。
        if let queuedRestart = pendingRestartAfterFinalizing {
            pendingRestartAfterFinalizing = nil
            cancelActiveTransform()
            let style = settings.voicePolishStyle
            let localResult = VoiceLocalPolisher.polish(normalizedRaw, style: style)
            let usedCommandV = commitSynchronouslyAndClear(
                finalText: localResult.text,
                rawText: normalizedRaw,
                actionKind: activeIntent.isTranslation
                    ? .dictation
                    : (localResult.modified ? .polish : .dictation),
                polishStyle: activeIntent.isTranslation
                    ? nil
                    : (localResult.modified ? style : nil),
                targetLanguage: nil,
                owner: owner
            )
            invokeRestart(
                afterCommandVPaste: usedCommandV,
                queuedRestart.onReadyToRestart
            )
            return
        }

        guard !normalizedRaw.isEmpty else {
            completePostProcessing(
                finalText: normalizedRaw,
                rawText: normalizedRaw,
                actionKind: activeIntent.isTranslation ? .translate : .dictation,
                polishStyle: nil,
                targetLanguage: nil,
                polishApplied: asrPolishApplied,
                customStatus: nil,
                owner: owner,
                generation: generation
            )
            return
        }

        switch activeIntent {
        case let .translate(language):
            runCloudTransformOrFallback(
                task: .translate,
                rawText: normalizedRaw,
                style: nil,
                targetLanguage: language,
                owner: owner,
                generation: generation
            )
        case .dictation:
            guard settings.voiceSmartPolishEnabled else {
                completePostProcessing(
                    finalText: normalizedRaw,
                    rawText: normalizedRaw,
                    actionKind: .dictation,
                    polishStyle: nil,
                    targetLanguage: nil,
                    polishApplied: asrPolishApplied,
                    customStatus: nil,
                    owner: owner,
                    generation: generation
                )
                return
            }
            let style = settings.voicePolishStyle
            if let inFlightID = incrementalPolish.cancelInFlight() {
                CloudBrokerClient.shared.cancelVoiceTransform(requestID: inFlightID)
            }
            switch incrementalPolish.planForFinal(normalizedRaw) {
            case let .completeImmediately(polishedText):
                // 全部内容均已在录音期间完成增量润色：0ms 直接出稿。
                settings.record(.voicePolished)
                completePostProcessing(
                    finalText: polishedText,
                    rawText: normalizedRaw,
                    actionKind: .polish,
                    polishStyle: style,
                    targetLanguage: nil,
                    polishApplied: true,
                    customStatus: nil,
                    owner: owner,
                    generation: generation
                )
            case let .polishTail(polishedPrefix, rawTail):
                runCloudTransformOrFallback(
                    task: .polish,
                    rawText: normalizedRaw,
                    transformInput: rawTail,
                    polishedPrefix: polishedPrefix,
                    style: style,
                    targetLanguage: nil,
                    owner: owner,
                    generation: generation
                )
            case .polishFull:
                runCloudTransformOrFallback(
                    task: .polish,
                    rawText: normalizedRaw,
                    style: style,
                    targetLanguage: nil,
                    owner: owner,
                    generation: generation
                )
            }
        }
    }

    private func runCloudTransformOrFallback(
        task: CloudVoiceTransformTask,
        rawText: String,
        transformInput: String? = nil,
        polishedPrefix: String? = nil,
        style: VoicePolishStyle?,
        targetLanguage: VoiceTranslationLanguage?,
        owner: any VoiceDictationRuntimeOwner,
        generation: UUID
    ) {
        let inputText = transformInput ?? rawText
        let canUseCloud = settings.cloudConfigured
            && !IsSecureEventInputEnabled()
        let apiKey = canUseCloud
            ? (try? FileCloudCredentialStore.shared.loadAPIKey())
            : nil

        guard let apiKey, !apiKey.isEmpty else {
            applyLocalFallback(
                task: task,
                rawText: rawText,
                transformInput: transformInput,
                polishedPrefix: polishedPrefix,
                style: style,
                targetLanguage: targetLanguage,
                cloudReason: "未启用云增强",
                owner: owner,
                generation: generation
            )
            return
        }

        guard inputText.count <= VoiceTransformTextPolicy.maximumInputCharacters else {
            applyLocalFallback(
                task: task,
                rawText: rawText,
                transformInput: transformInput,
                polishedPrefix: polishedPrefix,
                style: style,
                targetLanguage: targetLanguage,
                cloudReason: "文本超长，已使用本地处理",
                owner: owner,
                generation: generation
            )
            return
        }

        let requestID = "voice-transform-\(UUID().uuidString)"
        let resolvedModel = CloudBrokerClient.shared.resolvedModelID(
            for: settings.cloudModelID
        )
        let request = CloudVoiceTransformRequest(
            requestID: requestID,
            clientSessionID: targetAppSessionID ?? "voice-session",
            bundleIdentifier: targetBundleIdentifier,
            modelID: resolvedModel,
            task: task,
            text: inputText,
            style: style,
            targetLanguage: targetLanguage,
            // 热词上下文可能含个人常用语与专有名词：仅在用户显式 opt-in 时发送。
            hotwords: VoiceCloudHotwordPolicy.cloudHotwords(
                isEnabled: settings.voiceCloudHotwordsEnabled,
                activeHotwords: activeHotwords
            ),
            deadlineMilliseconds: VoiceSessionTiming.cloudTransformDeadline(
                for: task
            )
        )

        isTransforming = true
        activeTransformRequestID = requestID
        let statusText: String
        switch task {
        case .translate:
            let langName = targetLanguage?.shortName ?? "目标语言"
            statusText = "翻译中 · \(langName)"
        case .polish:
            statusText = "润色中…"
        }
        panel.showTransforming(
            statusText: statusText,
            sourcePreview: rawText,
            anchorRect: anchorRect,
            onCancel: cancellationHandler(
                owner: owner,
                generation: generation
            )
        )

        CloudBrokerClient.shared.transformVoiceText(
            request,
            apiKey: apiKey
        ) { [weak self, weak owner] response in
            MainActor.assumeIsolated {
                guard let self,
                      let owner,
                      self.activeGeneration == generation,
                      self.activeTransformRequestID == requestID
                else {
                    return
                }
                self.isTransforming = false
                self.activeTransformRequestID = nil
                if let response,
                   let transformed = VoiceTransformTextPolicy.sanitizedOutput(
                       response,
                       for: request
                   )
                {
                    switch task {
                    case .translate:
                        self.settings.record(.voiceTranslated)
                        self.completePostProcessing(
                            finalText: transformed,
                            rawText: rawText,
                            actionKind: .translate,
                            polishStyle: nil,
                            targetLanguage: targetLanguage,
                            polishApplied: true,
                            customStatus: nil,
                            owner: owner,
                            generation: generation
                        )
                    case .polish:
                        if VoiceCloudPolishTruncationGuard.looksTruncated(
                            input: inputText,
                            output: transformed
                        ) {
                            // 大模型只返回了半句：宁可用本地润色的完整原文，也不上屏残句。
                            self.applyLocalFallback(
                                task: .polish,
                                rawText: rawText,
                                transformInput: transformInput,
                                polishedPrefix: polishedPrefix,
                                style: style,
                                targetLanguage: nil,
                                cloudReason: "云端润色结果不完整",
                                polishStatusNote: VoiceCloudPolishTruncationGuard
                                    .fallbackStatus,
                                owner: owner,
                                generation: generation
                            )
                            return
                        }
                        let resolvedStyle = style ?? .concise
                        let merged = if let polishedPrefix, !polishedPrefix.isEmpty {
                            VoiceIncrementalPolishPipeline.joinPolished(
                                polishedPrefix,
                                transformed,
                                style: resolvedStyle
                            )
                        } else {
                            transformed
                        }
                        self.settings.record(.voicePolished)
                        self.completePostProcessing(
                            finalText: merged,
                            rawText: rawText,
                            actionKind: .polish,
                            polishStyle: style,
                            targetLanguage: nil,
                            polishApplied: true,
                            customStatus: nil,
                            owner: owner,
                            generation: generation
                        )
                    }
                    return
                }
                self.applyLocalFallback(
                    task: task,
                    rawText: rawText,
                    transformInput: transformInput,
                    polishedPrefix: polishedPrefix,
                    style: style,
                    targetLanguage: targetLanguage,
                    cloudReason: "云端服务暂不可用",
                    owner: owner,
                    generation: generation
                )
            }
        }
    }

    private func applyLocalFallback(
        task: CloudVoiceTransformTask,
        rawText: String,
        transformInput: String? = nil,
        polishedPrefix: String? = nil,
        style: VoicePolishStyle?,
        targetLanguage: VoiceTranslationLanguage?,
        cloudReason: String,
        polishStatusNote: String? = nil,
        owner: any VoiceDictationRuntimeOwner,
        generation: UUID
    ) {
        switch task {
        case .polish:
            let resolvedStyle = style ?? .concise
            let finalText: String
            let wasModified: Bool
            if let polishedPrefix, !polishedPrefix.isEmpty,
               let tail = transformInput, !tail.isEmpty
            {
                let tailPolished = VoiceLocalPolisher.polish(
                    tail,
                    style: resolvedStyle
                )
                finalText = VoiceIncrementalPolishPipeline.joinPolished(
                    polishedPrefix,
                    tailPolished.text,
                    style: resolvedStyle
                )
                wasModified = true
            } else {
                let localResult = VoiceLocalPolisher.polish(
                    rawText,
                    style: resolvedStyle
                )
                finalText = localResult.text
                wasModified = localResult.modified
            }
            if wasModified {
                settings.record(.voicePolished)
            }
            // 未配置云增强时走本地润色属于正常路径，不重复提示；仅在云端
            // 返回不完整/超时等确实发生了回退时才说明原因。
            completePostProcessing(
                finalText: finalText,
                rawText: rawText,
                actionKind: wasModified ? .polish : .dictation,
                polishStyle: wasModified ? resolvedStyle : nil,
                targetLanguage: nil,
                polishApplied: wasModified,
                customStatus: polishStatusNote
                    ?? (wasModified ? "已润色" : nil),
                owner: owner,
                generation: generation
            )
        case .translate:
            // 翻译依赖云端模型；未配置或超时时保留本地润色后的原文，避免丢失口述内容。
            let cleaned = VoiceLocalPolisher.polish(rawText, style: .concise).text
            completePostProcessing(
                finalText: cleaned,
                rawText: rawText,
                actionKind: .dictation,
                polishStyle: nil,
                targetLanguage: targetLanguage,
                polishApplied: false,
                customStatus: "\(cloudReason)，已保留原文",
                owner: owner,
                generation: generation
            )
        }
    }

    private static func normalizeFinalOutput(
        _ text: String,
        allowsNewlines: Bool
    ) -> String {
        if allowsNewlines {
            return text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func completePostProcessing(
        finalText: String,
        rawText: String,
        actionKind: VoicePostProcessAction,
        polishStyle: VoicePolishStyle?,
        targetLanguage: VoiceTranslationLanguage?,
        polishApplied: Bool,
        customStatus: String?,
        owner: any VoiceDictationRuntimeOwner,
        generation: UUID
    ) {
        guard activeGeneration == generation else {
            return
        }
        let allowsNewlines = actionKind == .polish && polishStyle == .structured
        var cleanedFinal = Self.normalizeFinalOutput(
            finalText,
            allowsNewlines: allowsNewlines
        )
        if actionKind != .translate {
            cleanedFinal = applyLearnedCorrectionsIfAllowed(cleanedFinal)
        }

        guard !cleanedFinal.isEmpty else {
            // 未识别到有效语音内容时安静收起，不弹出空复制窗或报错。
            coordinator.userCancelled()
            clearTarget(hidePanel: true)
            return
        }

        pendingRawText = rawText
        pendingPostProcessedText = cleanedFinal
        pendingActionKind = actionKind
        pendingPolishStyle = polishStyle
        pendingTargetLanguage = targetLanguage
        isTransforming = false

        let canAutoInsert = hasEditableTarget && targetIsValid(owner: owner)
        if canAutoInsert {
            if settings.voiceAutoPasteEnabled {
                // 光标有焦点：结束听写后自动确认上屏，无需二次确认。
                confirm(owner: owner)
                return
            }
            panel.updatePreview(
                stable: cleanedFinal,
                partial: "",
                pendingConfirm: true,
                polishApplied: polishApplied,
                intent: activeIntent,
                customStatus: customStatus,
                anchorRect: anchorRect,
                onConfirm: { [weak self, weak owner] in
                    guard let self, let owner else {
                        return
                    }
                    guard generation == self.activeGeneration else {
                        return
                    }
                    self.confirm(owner: owner)
                },
                onCopy: { [weak self] in
                    guard let self,
                          generation == self.activeGeneration
                    else {
                        return
                    }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(cleanedFinal, forType: .string)
                    self.soundPlayer.play(.success)
                    self.coordinator.userCancelled()
                    self.clearTarget(hidePanel: true)
                },
                onCancel: cancellationHandler(
                    owner: owner,
                    generation: generation
                )
            )
            return
        }

        // 无光标焦点 / 焦点已离开：不自动上屏，也不自动消失；持续悬浮供手动点击复制或 ⌘C 复制。
        let savedAnchor = anchorRect
        let savedBundleID = targetBundleIdentifier
        let savedDurationMs = recordingDurationMilliseconds
        let badge = customStatus ?? (polishApplied ? "已润色" : nil)
        let copyReason: VoicePersistentCopyReason = targetWasEditableAtStart
            ? .focusSwitched
            : .noCursor

        coordinator.userCancelled()
        settings.record(.voiceAccepted)
        // 降级为手动复制卡片不等于“已上屏”：不播放成功音。
        recordVoiceHistory(
            bundleID: savedBundleID,
            rawText: rawText,
            finalText: cleanedFinal,
            actionKind: actionKind,
            polishStyle: polishStyle,
            targetLanguage: targetLanguage,
            durationMs: savedDurationMs,
            autoPasted: false
        )
        clearTarget(hidePanel: false)
        presentPersistentCopyPanel(
            text: cleanedFinal,
            badge: badge,
            reason: copyReason,
            anchorRect: savedAnchor.isEmpty ? fallbackAnchorRect() : savedAnchor
        )
    }

    private func presentPersistentCopyPanel(
        text: String,
        badge: String?,
        reason: VoicePersistentCopyReason,
        anchorRect: NSRect
    ) {
        panel.showPersistentCopy(
            text: text,
            badge: badge,
            reason: reason,
            anchorRect: anchorRect,
            onCopied: { [weak self] in
                self?.soundPlayer.play(.success)
            },
            onClose: { [weak self] in
                self?.panel.hide()
            }
        )
    }

    private func recordVoiceHistory(
        bundleID: String,
        rawText: String,
        finalText: String,
        actionKind: VoicePostProcessAction,
        polishStyle: VoicePolishStyle?,
        targetLanguage: VoiceTranslationLanguage?,
        durationMs: Int,
        autoPasted: Bool
    ) {
        let record = VoiceHistoryRecord(
            bundleIdentifier: bundleID,
            rawText: rawText,
            finalText: finalText,
            actionKind: actionKind,
            polishStyle: polishStyle,
            targetLanguage: targetLanguage,
            durationMilliseconds: durationMs,
            autoPasted: autoPasted
        )
        historyService.recordSessionAsync(
            record,
            storeHistoryText: settings.voiceHistoryEnabled
        )
    }

    // MARK: - Commit & Auto-Paste

    private func handleCommit(_ coordinatorText: String, generation: UUID?) -> Bool {
        guard let generation, generation == activeGeneration else {
            return false
        }
        let actionKind = pendingActionKind
        let polishStyle = pendingPolishStyle
        let allowsNewlines = actionKind == .polish && polishStyle == .structured
        let finalText = Self.normalizeFinalOutput(
            pendingPostProcessedText ?? coordinatorText,
            allowsNewlines: allowsNewlines
        )
        let rawText = pendingRawText ?? coordinatorText
        let targetLanguage = pendingTargetLanguage
        let bundleID = targetBundleIdentifier
        let durationMs = recordingDurationMilliseconds
        let autoPasteEnabled = settings.voiceAutoPasteEnabled
        let savedAnchor = anchorRect
        let targetStillEditable = hasEditableTarget
            && activeOwner.map { targetIsValid(owner: $0) } == true

        var persistentCopyReason: VoicePersistentCopyReason?
        let hadEditableTargetAtStart = targetWasEditableAtStart
        defer {
            confirming = false
            audioMuter.restoreImmediately()
            if let persistentCopyReason {
                // 无法直接上屏时绝不丢失文本：转为常驻手动复制浮窗，并说明真实原因。
                clearTarget(hidePanel: false)
                presentPersistentCopyPanel(
                    text: finalText,
                    badge: nil,
                    reason: persistentCopyReason,
                    anchorRect: savedAnchor.isEmpty
                        ? fallbackAnchorRect()
                        : savedAnchor
                )
            } else {
                clearTarget(hidePanel: true)
            }
        }

        guard !finalText.isEmpty,
              !IsSecureEventInputEnabled()
        else {
            settings.record(.voiceFailure)
            soundPlayer.play(.error)
            return false
        }

        var committed = false
        var preCommitAnchor: VoicePostCommitAnchor?
        var pasteOutcome: VoiceClipboardPaster.Outcome?
        let commitClientObject = targetClient
        if targetStillEditable,
           let owner = activeOwner,
           let client = targetClient,
           let appSessionID = targetAppSessionID
        {
            if !owner.usesClipboardPasteForCommit {
                if actionKind != .translate {
                    preCommitAnchor = VoicePostCommitEditTracker.shared
                        .capturePreCommitAnchor(
                            committedText: finalText,
                            bundleIdentifier: bundleID,
                            appSessionID: appSessionID,
                            client: client as? any IMKTextInput,
                            selection: targetSelection
                        )
                }
                committed = owner.voiceRuntimeCommit(
                    finalText,
                    client: client,
                    appSessionID: appSessionID,
                    selection: targetSelection,
                    anchorRect: anchorRect
                )
            }
            // 宿主拒绝 IMK insertText、上屏回读发现未真正写入，或全局跨输入法会话
            // （无 IMKTextInput）时，统一走 ⌘V 回退路径。回退结果（仅复制到剪贴板 /
            // 被安全输入阻断）反馈到浮窗，绝不误报“未检测到光标”。
            if !committed, autoPasteEnabled || owner.usesClipboardPasteForCommit {
                pasteOutcome = VoiceClipboardPaster.paste(finalText)
                committed = pasteOutcome == .pastedViaCommandV
            }
        }

        if committed {
            if let preCommitAnchor {
                VoicePostCommitEditTracker.shared.arm(
                    anchor: preCommitAnchor,
                    client: commitClientObject,
                    anchorRect: savedAnchor
                )
            }
            settings.record(.voiceAccepted)
            if autoPasteEnabled {
                settings.record(.voiceAutoPasted)
            }
            soundPlayer.play(.success)
            recordVoiceHistory(
                bundleID: bundleID,
                rawText: rawText,
                finalText: finalText,
                actionKind: actionKind,
                polishStyle: polishStyle,
                targetLanguage: targetLanguage,
                durationMs: durationMs,
                autoPasted: autoPasteEnabled
            )
            return true
        }

        // 无法直接上屏时绝不丢失文本：按真实原因转为常驻手动复制浮窗。
        // 提交瞬间目标已不可用（焦点/选区离开）即“焦点已切换”；目标仍有效却
        // 写不进去则是“宿主拒绝写入”。
        persistentCopyReason = VoiceClipboardFallbackPolicy.reason(
            pasteOutcome: pasteOutcome,
            hadEditableTarget: hadEditableTargetAtStart,
            focusSwitched: !targetStillEditable,
            isAccessibilityTrusted: VoiceAccessibilityAuthorization.isTrusted
        )
        settings.record(.voiceAccepted)
        // 降级为手动复制不等于成功上屏：不播放成功音。
        recordVoiceHistory(
            bundleID: bundleID,
            rawText: rawText,
            finalText: finalText,
            actionKind: actionKind,
            polishStyle: polishStyle,
            targetLanguage: targetLanguage,
            durationMs: durationMs,
            autoPasted: false
        )
        return false
    }

    private func presentFailure(
        _ message: String,
        presentation: VoiceFailurePresentation,
        anchorRect: NSRect
    ) {
        // 焦点已离开时也要给出反馈：锚点失效则退回到鼠标位置。
        panel.showFailure(
            message,
            presentation: presentation,
            anchorRect: anchorRect.isEmpty ? fallbackAnchorRect() : anchorRect,
            onRetry: { [weak self] in
                guard let self else {
                    return
                }
                self.panel.hide()
                NotificationCenter.default.post(
                    name: .rimeAIVoiceRetryRequested,
                    object: nil
                )
            },
            onCancel: { [weak self] in self?.panel.hide() }
        )
    }

    /// 权限阻断状态变化时通知设置窗口实时刷新服务状态。
    private func setPermissionBlocked(_ blocked: Bool) {
        guard permissionBlocked != blocked else {
            return
        }
        permissionBlocked = blocked
        NotificationCenter.default.post(
            name: .rimeAIVoiceServiceStateDidChange,
            object: self
        )
    }

    private func handleFailure(
        _ code: VoiceDictationErrorCode,
        generation: UUID?
    ) {
        guard let generation, generation == activeGeneration else {
            return
        }
        cancelActiveTransform()
        audioMuter.restoreImmediately()
        let owner = activeOwner
        let failureAnchor = anchorRect
        settings.record(.voiceFailure)
        soundPlayer.play(.error)
        clearTarget(hidePanel: true)
        if code == .incompatibleProtocol {
            owner?.voiceRuntimeDidBecomeUnavailable()
        }
        presentFailure(
            failureMessage(for: code),
            presentation: VoiceFailurePresentation.presentation(for: code),
            anchorRect: failureAnchor
        )
    }

    private func handleMicrophoneDenied(generation: UUID?) {
        guard let generation, generation == activeGeneration else {
            return
        }
        cancelActiveTransform()
        audioMuter.restoreImmediately()
        let owner = activeOwner
        let failureAnchor = anchorRect
        settings.record(.voiceMicrophoneDenied)
        soundPlayer.play(.error)
        clearTarget(hidePanel: true)
        if let owner {
            VoiceHotKeyManager.shared.deactivate(owner: owner)
            owner.voiceRuntimeDidBecomeUnavailable()
        }
        setPermissionBlocked(true)
        presentFailure(
            "麦克风或语音识别权限已被拒绝。请在系统设置的“隐私与安全性”中允许 "
                + "RimeAI Voice Helper 使用这两项权限，然后点“重试”。",
            presentation: .microphonePermission,
            anchorRect: failureAnchor
        )
    }

    private func handleDisabled(generation: UUID?) {
        guard let generation, generation == activeGeneration else {
            return
        }
        cancelActiveTransform()
        audioMuter.restoreImmediately()
        let owner = activeOwner
        let failureAnchor = anchorRect
        settings.record(.voiceDisabled)
        soundPlayer.play(.error)
        clearTarget(hidePanel: true)
        if let owner {
            VoiceHotKeyManager.shared.deactivate(owner: owner)
            owner.voiceRuntimeDidBecomeUnavailable()
        }
        presentFailure(
            "语音服务连续失败，已在本次输入法进程中停用。可点“重试”重新连接，"
                + "或到 RimeAI 设置中检查语音组件。",
            presentation: .serviceDisabled,
            anchorRect: failureAnchor
        )
    }

    private func handlePhaseChanged(
        _ newPhase: VoiceDictationClientPhase,
        generation: UUID?
    ) {
        guard let generation, generation == activeGeneration else {
            return
        }
        let previousPhase = observedPhase
        observedPhase = newPhase
        if (previousPhase == .disabled) != (newPhase == .disabled) {
            // 熔断/恢复：设置窗口的服务状态徽标需要实时刷新。
            NotificationCenter.default.post(
                name: .rimeAIVoiceServiceStateDidChange,
                object: self
            )
        }
        guard let owner = activeOwner else {
            return
        }
        switch newPhase {
        case .listening:
            panel.showListening(
                intent: activeIntent,
                anchorRect: anchorRect,
                recordingStartedAt: sessionStartedAt,
                onCancel: cancellationHandler(
                    owner: owner,
                    generation: generation
                )
            )
        case .finalizing:
            audioMuter.restoreImmediately()
            panel.showFinalizing(
                intent: activeIntent,
                anchorRect: anchorRect,
                onCancel: cancellationHandler(
                    owner: owner,
                    generation: generation
                )
            )
        case .idle:
            audioMuter.restoreImmediately()
            let expectedGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.activeGeneration == expectedGeneration,
                      self.phase == .idle,
                      !self.isTransforming
                else {
                    return
                }
                self.clearTarget(hidePanel: true)
            }
        case .disabled:
            handleDisabled(generation: generation)
        case .connecting, .pendingConfirm:
            break
        }
    }

    private func observeProcessState() {
        let retryObserver = NotificationCenter.default.addObserver(
            forName: .rimeAIVoiceRetryRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.panel.hide()
                self.setPermissionBlocked(false)
                self.coordinator.userRetriedVoice()
                self.currentOwner?.voiceRuntimeDidBecomeAvailable()
            }
        }
        let settingsObserver = NotificationCenter.default.addObserver(
            forName: .rimeAISettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      !self.settings.voiceEnabled || !self.settings.aiEnabled
                else {
                    return
                }
                if let activeOwner = self.activeOwner {
                    self.cancel(owner: activeOwner)
                }
                self.audioMuter.restoreImmediately()
                self.panel.hide()
            }
        }
        observers = [retryObserver, settingsObserver]
    }

    private func startValidationTimer() {
        validationTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .milliseconds(150),
            repeating: .milliseconds(150),
            leeway: .milliseconds(25)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.validateActiveSession()
            }
        }
        validationTimer = timer
        timer.resume()
    }

    private func validateActiveSession() {
        guard let owner = activeOwner else {
            clearTarget(hidePanel: !isShowingPersistentCopy)
            return
        }
        if IsSecureEventInputEnabled() {
            owner.voiceRuntimeSecureInputDetected()
            return
        }
        if hasEditableTarget, !targetIsValid(owner: owner) {
            // 光标焦点离开后不再强行取消录音；降级为“结束时常驻悬浮手动复制”。
            hasEditableTarget = false
        }
    }

    private func detachTargetIfActive() {
        guard activeOwner != nil else {
            return
        }
        // 焦点切换或应用失活时保留进行中的听写与结果，但永久关闭自动上屏，
        // 防止跨应用误上屏，结束后进入常驻手动复制浮窗。
        hasEditableTarget = false
        if case .pendingConfirm = phase,
           let text = pendingPostProcessedText,
           !text.isEmpty
        {
            let savedAnchor = anchorRect
            let savedBundleID = targetBundleIdentifier
            let savedDurationMs = recordingDurationMilliseconds
            let rawText = pendingRawText ?? text
            let actionKind = pendingActionKind
            let polishStyle = pendingPolishStyle
            let targetLanguage = pendingTargetLanguage

            coordinator.userCancelled()
            recordVoiceHistory(
                bundleID: savedBundleID,
                rawText: rawText,
                finalText: text,
                actionKind: actionKind,
                polishStyle: polishStyle,
                targetLanguage: targetLanguage,
                durationMs: savedDurationMs,
                autoPasted: false
            )
            clearTarget(hidePanel: false)
            presentPersistentCopyPanel(
                text: text,
                badge: nil,
                reason: .focusSwitched,
                anchorRect: savedAnchor
            )
        }
    }

    private func targetIsValid(
        owner: any VoiceDictationRuntimeOwner
    ) -> Bool {
        guard (currentOwner === owner || owner.usesClipboardPasteForCommit),
              let client = targetClient,
              let appSessionID = targetAppSessionID
        else {
            return false
        }
        return owner.voiceRuntimeTargetIsValid(
            client: client,
            appSessionID: appSessionID,
            selection: targetSelection,
            anchorRect: anchorRect
        )
    }

    private func invalidateActiveSession(
        reason: VoiceDictationCancelReason
    ) {
        let hadActiveSession: Bool
        switch phase {
        case .connecting, .listening, .finalizing, .pendingConfirm:
            hadActiveSession = true
        case .idle, .disabled:
            hadActiveSession = isTransforming
        }
        cancelActiveTransform()
        audioMuter.restoreImmediately()
        if reason == .secureInput {
            coordinator.secureInputChanged(active: true)
        } else {
            coordinator.sessionSwitched()
        }
        if hadActiveSession {
            settings.record(.voiceCancelled)
        }
        clearTarget(hidePanel: true)
    }

    private func cancelActiveTransform() {
        if let requestID = activeTransformRequestID {
            CloudBrokerClient.shared.cancelVoiceTransform(requestID: requestID)
            activeTransformRequestID = nil
        }
        if let incRequestID = incrementalPolish.cancelInFlight() {
            CloudBrokerClient.shared.cancelVoiceTransform(requestID: incRequestID)
        }
        isTransforming = false
    }

    private func clearTarget(hidePanel: Bool) {
        validationTimer?.cancel()
        validationTimer = nil
        cancelActiveTransform()
        incrementalPolish.reset(style: settings.voicePolishStyle)
        pendingRestartAfterFinalizing = nil
        audioMuter.restoreImmediately()
        if hidePanel {
            panel.hide()
        }
        targetClient = nil
        targetAppSessionID = nil
        targetBundleIdentifier = "unknown-client"
        targetFrontmostPID = nil
        targetSelection = NSRange(location: NSNotFound, length: 0)
        hasEditableTarget = false
        targetWasEditableAtStart = false
        activeIntent = .dictation
        activeHotwords = []
        sessionStartedAt = nil
        recordingDurationMilliseconds = 0
        pendingRawText = nil
        pendingPostProcessedText = nil
        pendingActionKind = .dictation
        pendingPolishStyle = nil
        pendingTargetLanguage = nil
        observedPhase = phase
        activeGeneration = nil
        confirming = false
        recordedPreview = false
        recordedFinal = false
        activeOwner = nil
    }

    private func cancellationHandler(
        owner: any VoiceDictationRuntimeOwner,
        generation: UUID? = nil
    ) -> () -> Void {
        let expectedGeneration = generation ?? activeGeneration
        return { [weak self, weak owner] in
            guard let self, let owner else {
                return
            }
            guard expectedGeneration == self.activeGeneration else {
                return
            }
            self.cancel(owner: owner)
        }
    }

    private func failureMessage(for code: VoiceDictationErrorCode) -> String {
        switch code {
        case .micDenied:
            return "麦克风权限已被拒绝。"
        case .micUnavailable:
            return "没有可用的麦克风输入设备。"
        case .asrEngineError:
            return "本地语音识别引擎启动失败。"
        case .asrTimeout:
            return "语音识别超时，本次内容未上屏。"
        case .asrOverload:
            return "语音识别资源暂时不足，请稍后重试。"
        case .polishFailed:
            return "听写文本处理失败，本次内容未上屏。"
        case .invalidRequest:
            return "语音 helper 拒绝了无效请求。"
        case .incompatibleProtocol:
            return "输入法与语音 helper 版本不兼容，请重新安装。"
        case .internalError:
            return "语音服务发生内部错误，本次内容未上屏。"
        }
    }
}
