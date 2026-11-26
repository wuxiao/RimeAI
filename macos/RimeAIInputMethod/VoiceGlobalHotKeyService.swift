import AppKit
import Carbon
import Foundation
import InputMethodKit

/// 进程级全局语音快捷键协调器：
/// 让语音听写 / 一键翻译快捷键（包括裸右 `⌘` 点按与 `⌃⇧V` / `⌃⇧T` 组合键）
/// 在**任意应用、任意输入法（含系统英文 ABC、第三方输入法或无输入框状态）**下
/// 均能可靠触发，不再绑定到单个 `IMKInputController` 的激活生命周期。
///
/// 隐私与安全边界：
/// - 绝不读取或记录普通键盘文本流；仅在启用语音且非 Secure Input 时处理
///   已配置的语音快捷键与裸右 `⌘` 点按。
/// - 组合操作防护同时使用全局/本地 `keyDown` 复位与 CoreGraphics HID 空闲时间
///   查询（`CGEventSource.secondsSinceLastEventType`），即便未授予输入监控权限
///   也不会把 `右⌘+C/V` 或 `右⌘+点击` 误判为点按触发。
@MainActor
final class VoiceGlobalHotKeyService {
    static let shared = VoiceGlobalHotKeyService()

    private let settings = RimeAISettingsStore.shared
    private weak var activeIMKController: RimeAIInputController?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var settingsObserver: NSObjectProtocol?
    private var serviceStateObserver: NSObjectProtocol?
    private var secureInputRecoveryTimer: DispatchSourceTimer?
    private var dictationModifierTapDetector = VoiceModifierTapDetector()
    private var secondaryDictationModifierTapDetector = VoiceModifierTapDetector()
    private var translateModifierTapDetector = VoiceModifierTapDetector()
    private var dictationPointerGuard = VoiceModifierTapPointerGuard()
    private var secondaryDictationPointerGuard = VoiceModifierTapPointerGuard()
    private var translatePointerGuard = VoiceModifierTapPointerGuard()
    private var modifierDeduplicator = VoiceModifierEventDeduplicator()
    private var isStarted = false
    private var hotKeyRegistrationFailed = false

    private init() {}

    /// 全局事件监听是否已启动（用于判断是否可跨输入法保持录音与停止能力）。
    var isGlobalMonitorActive: Bool {
        globalEventMonitor != nil
    }

    /// 进程启动时调用一次（单测环境不启动）。
    func start() {
        guard !isStarted else {
            reconcileHotKeys()
            return
        }
        isStarted = true
        installEventMonitors()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .rimeAISettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hotKeyRegistrationFailed = false
                self?.resetModifierTapDetectors()
                self?.reconcileHotKeys()
            }
        }
        serviceStateObserver = NotificationCenter.default.addObserver(
            forName: .rimeAIVoiceServiceStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hotKeyRegistrationFailed = false
                self?.reconcileHotKeys()
            }
        }
        reconcileHotKeys()
    }

    func shutdown() {
        stopSecureInputRecoveryTimer()
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        if let serviceStateObserver {
            NotificationCenter.default.removeObserver(serviceStateObserver)
            self.serviceStateObserver = nil
        }
        VoiceHotKeyManager.shared.deactivate(owner: self)
        activeIMKController = nil
        resetModifierTapDetectors()
        isStarted = false
    }

    func registerActiveController(_ controller: RimeAIInputController) {
        activeIMKController = controller
    }

    func unregisterActiveController(_ controller: RimeAIInputController) {
        if activeIMKController === controller {
            activeIMKController = nil
        }
    }

    /// 根据当前语音总开关、熔断态与安全输入态同步全局热键注册。
    func reconcileHotKeys() {
        let runtime = VoiceDictationRuntime.shared
        guard settings.aiEnabled,
              settings.voiceEnabled,
              runtime.canRegisterHotKey
        else {
            stopSecureInputRecoveryTimer()
            VoiceHotKeyManager.shared.deactivate(owner: self)
            return
        }
        if IsSecureEventInputEnabled() {
            VoiceHotKeyManager.shared.deactivate(owner: self)
            startSecureInputRecoveryTimer()
            return
        }
        stopSecureInputRecoveryTimer()

        do {
            try VoiceHotKeyManager.shared.activate(
                owner: self,
                shortcut: settings.voiceShortcut,
                onPressed: { [weak self] in
                    self?.handleTriggeredShortcut(
                        intent: .dictation,
                        isToggleShortcut: false
                    )
                },
                onReleased: { [weak self] in
                    self?.handleReleasedHoldShortcut()
                },
                onSecureInputDetected: { [weak self] in
                    self?.handleSecureInputDetected()
                }
            )
            hotKeyRegistrationFailed = false
        } catch {
            if !hotKeyRegistrationFailed {
                settings.record(.voiceFailure)
            }
            hotKeyRegistrationFailed = true
        }
        reconcileSecondaryHotKey()
        reconcileTranslationHotKey()
    }

    private func reconcileSecondaryHotKey() {
        let plan = VoiceSecondaryHotKeyPlan.plan(
            secondaryShortcut: settings.voiceSecondaryShortcut,
            primaryShortcut: settings.voiceShortcut
        )
        switch plan {
        case .deactivate:
            VoiceHotKeyManager.shared.deactivateSecondary(owner: self)
        case let .activate(secondaryShortcut):
            do {
                try VoiceHotKeyManager.shared.activateSecondary(
                    owner: self,
                    shortcut: secondaryShortcut,
                    onPressed: { [weak self] in
                        self?.handleTriggeredShortcut(
                            intent: .dictation,
                            isToggleShortcut: false
                        )
                    },
                    onReleased: { [weak self] in
                        self?.handleReleasedHoldShortcut()
                    },
                    onSecureInputDetected: { [weak self] in
                        self?.handleSecureInputDetected()
                    }
                )
            } catch {
                // activateSecondary 已记录 .failed 状态并发出通知，保留供设置页展示。
            }
        }
    }

    private func reconcileTranslationHotKey() {
        let translateShortcut = settings.voiceTranslateShortcut
        let plan = VoiceTranslationHotKeyPlan.plan(
            translateShortcut: translateShortcut,
            dictationShortcut: settings.voiceShortcut,
            secondaryDictationShortcut: settings.voiceSecondaryShortcut
        )
        switch plan {
        case .deactivate:
            VoiceHotKeyManager.shared.deactivateTranslation(owner: self)
        case .activate:
            do {
                try VoiceHotKeyManager.shared.activateTranslation(
                    owner: self,
                    shortcut: translateShortcut,
                    onPressed: { [weak self] in
                        guard let self else { return }
                        self.handleTriggeredShortcut(
                            intent: .translate(
                                self.settings.voiceTranslateTargetLanguage
                            ),
                            isToggleShortcut: false
                        )
                    },
                    onReleased: { [weak self] in
                        self?.handleReleasedHoldShortcut()
                    }
                )
            } catch {
                VoiceHotKeyManager.shared.deactivateTranslation(owner: self)
            }
        }
    }

    // MARK: - 统一修饰键点按与全局事件监控

    /// 任意非修饰键按下（IMK 路径、全局监控或本地监控均可调用）：立即取消待确认的右 `⌘` 点按。
    func noteNonModifierKeyDown() {
        dictationModifierTapDetector.handleOtherKeyDown()
        secondaryDictationModifierTapDetector.handleOtherKeyDown()
        translateModifierTapDetector.handleOtherKeyDown()
        dictationPointerGuard.reset()
        secondaryDictationPointerGuard.reset()
        translatePointerGuard.reset()
    }

    func resetModifierTapDetectors() {
        dictationModifierTapDetector.reset()
        secondaryDictationModifierTapDetector.reset()
        translateModifierTapDetector.reset()
        dictationPointerGuard.reset()
        secondaryDictationPointerGuard.reset()
        translatePointerGuard.reset()
        modifierDeduplicator.reset()
    }

    /// 处理 `flagsChanged` 事件（IMK 控制器与全局/本地事件监控器共用，内部自动去重）。
    func handleFlagsChanged(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        timestamp: TimeInterval,
        controller: RimeAIInputController? = nil,
        client: (any IMKTextInput)? = nil
    ) {
        let modifiers = Self.voiceKeyModifiers(modifierFlags)
        guard modifierDeduplicator.shouldProcess(
            keyCode: keyCode,
            modifiers: modifiers,
            timestamp: timestamp
        ) else {
            return
        }
        guard settings.aiEnabled, settings.voiceEnabled else {
            resetModifierTapDetectors()
            return
        }
        if IsSecureEventInputEnabled(), let controller, let client {
            // 安全输入下仍继续评估点按：若用户确实完成一次干净的右 ⌘ 点按，
            // 后续 handleTriggeredShortcut 会给出“安全输入已开启”的明确提示。
            controller.enterSecureInput(client: client)
        }

        let dictationShortcut = settings.voiceShortcut
        let secondaryShortcut = settings.voiceSecondaryShortcut
        let translateShortcut = settings.voiceTranslateShortcut

        let dictationTriggered = dictationShortcut.isModifierTap
            ? evaluateModifierTap(
                detector: &dictationModifierTapDetector,
                pointerGuard: &dictationPointerGuard,
                keyCode: keyCode,
                modifiers: modifiers,
                timestamp: timestamp,
                shortcut: dictationShortcut
            )
            : false
        let secondaryTriggered: Bool
        if let secondaryShortcut,
           secondaryShortcut.isModifierTap,
           secondaryShortcut != dictationShortcut
        {
            secondaryTriggered = evaluateModifierTap(
                detector: &secondaryDictationModifierTapDetector,
                pointerGuard: &secondaryDictationPointerGuard,
                keyCode: keyCode,
                modifiers: modifiers,
                timestamp: timestamp,
                shortcut: secondaryShortcut
            )
        } else {
            secondaryDictationModifierTapDetector.reset()
            secondaryDictationPointerGuard.reset()
            secondaryTriggered = false
        }
        let translateTriggered = translateShortcut.isModifierTap
            && translateShortcut != dictationShortcut
            && translateShortcut != secondaryShortcut
            ? evaluateModifierTap(
                detector: &translateModifierTapDetector,
                pointerGuard: &translatePointerGuard,
                keyCode: keyCode,
                modifiers: modifiers,
                timestamp: timestamp,
                shortcut: translateShortcut
            )
            : false

        guard dictationTriggered || secondaryTriggered || translateTriggered else {
            return
        }

        if let controller, let client {
            if controller.isHostActive {
                controller.adoptActiveClient(client as AnyObject)
            } else {
                controller.beginHostActivation(client as AnyObject)
            }
            controller.activateSession(for: client)
            registerActiveController(controller)
        }

        let intent: VoiceSessionIntent = translateTriggered
            ? .translate(settings.voiceTranslateTargetLanguage)
            : .dictation
        handleTriggeredShortcut(
            intent: intent,
            isToggleShortcut: true,
            preferredController: controller
        )
    }

    /// 触发一次听写/翻译快捷键动作（按住说话按下，或右 `⌘` 点按切换）。
    func handleTriggeredShortcut(
        intent: VoiceSessionIntent,
        isToggleShortcut: Bool,
        preferredController: RimeAIInputController? = nil
    ) {
        let runtime = VoiceDictationRuntime.shared
        let matchedController = resolveMatchingIMKController(
            preferred: preferredController
        )

        if IsSecureEventInputEnabled() {
            settings.record(.privacyBlocked)
            runtime.presentStartBlockedToast(
                .secureInput,
                anchorRect: matchedController?.fallbackVoiceAnchorRect()
                    ?? runtime.fallbackAnchorRect()
            )
            handleSecureInputDetected()
            return
        }

        let decision = VoiceRepeatTriggerDecision.decide(
            phase: runtime.phase,
            isTransforming: runtime.isTransforming
        )
        switch decision {
        case .startNewSession:
            startSession(intent: intent, matchedController: matchedController)
        case .stopRecording:
            if isToggleShortcut {
                runtime.stopActiveSession()
            }
        case .flushTransformAndRestart:
            runtime.flushTransformAndRestart(intent: intent) { [weak self] in
                guard let self else { return }
                let latestController = self.resolveMatchingIMKController(
                    preferred: preferredController
                )
                self.startSession(
                    intent: intent,
                    matchedController: latestController
                )
            }
        case .commitPendingAndRestart:
            runtime.commitPendingAndRestart(intent: intent) { [weak self] in
                guard let self else { return }
                let latestController = self.resolveMatchingIMKController(
                    preferred: preferredController
                )
                self.startSession(
                    intent: intent,
                    matchedController: latestController
                )
            }
        case .queueRestartAfterFinalizing:
            runtime.queueRestartAfterFinalizing(intent: intent) { [weak self] in
                guard let self else { return }
                let latestController = self.resolveMatchingIMKController(
                    preferred: preferredController
                )
                self.startSession(
                    intent: intent,
                    matchedController: latestController
                )
            }
        case .ignoreDisabled:
            if let blocker = runtime.startBlocker {
                runtime.presentStartBlockedToast(
                    blocker,
                    anchorRect: matchedController?.fallbackVoiceAnchorRect()
                        ?? runtime.fallbackAnchorRect()
                )
            }
        }
    }

    private func handleReleasedHoldShortcut() {
        VoiceDictationRuntime.shared.stopActiveSession()
    }

    private func startSession(
        intent: VoiceSessionIntent,
        matchedController: RimeAIInputController?
    ) {
        if let controller = matchedController,
           let client = controller.activeClientObject as? any IMKTextInput
        {
            _ = controller.startVoiceDictation(client: client, intent: intent)
        } else {
            _ = VoiceDictationRuntime.shared.startGlobal(intent: intent)
        }
    }

    /// 只有当系统当前选中的输入源确实是 RimeAI、且控制器处于激活态、有有效客户端
    /// 且所属应用就是当前前台应用时，才走 IMK 直连会话；否则（切换到 ABC / 第三方
    /// 输入法 / 无输入框）走全局会话。
    private func resolveMatchingIMKController(
        preferred: RimeAIInputController?
    ) -> RimeAIInputController? {
        guard Self.isRimeAIInputSourceSelected() else {
            return nil
        }
        let candidate = preferred ?? activeIMKController
        guard let controller = candidate,
              controller.isHostActive,
              let client = controller.activeClientObject as? any IMKTextInput
        else {
            return nil
        }
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?
            .bundleIdentifier
        let clientBundleID = controller.currentBundleIdentifier
            ?? client.bundleIdentifier()
        if let frontmostBundleID,
           let clientBundleID,
           frontmostBundleID != clientBundleID
        {
            return nil
        }
        return controller
    }

    private static func isRimeAIInputSourceSelected() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?
            .takeRetainedValue(),
              let idPointer = TISGetInputSourceProperty(
                  source,
                  kTISPropertyInputSourceID
              )
        else {
            return false
        }
        let sourceID = Unmanaged<CFString>.fromOpaque(idPointer)
            .takeUnretainedValue() as String
        return sourceID.hasPrefix("fun.wwcn.inputmethod.RimeAI")
    }

    private func evaluateModifierTap(
        detector: inout VoiceModifierTapDetector,
        pointerGuard: inout VoiceModifierTapPointerGuard,
        keyCode: UInt16,
        modifiers: VoiceDictationKeyModifiers,
        timestamp: TimeInterval,
        shortcut: VoiceDictationShortcut
    ) -> Bool {
        let triggered = detector.handleFlagsChanged(
            keyCode: keyCode,
            modifiers: modifiers,
            timestamp: timestamp,
            shortcut: shortcut
        )
        var semantic = modifiers
        semantic.remove([.capsLock, .numericPad])
        if shortcut.isModifierTap,
           keyCode == shortcut.keyCode,
           semantic == shortcut.modifiers
        {
            pointerGuard.armed(
                lastPointerActivityAt: VoicePointerActivity
                    .lastPointerEventTimestamp(),
                lastKeyDownActivityAt: VoicePointerActivity
                    .lastKeyDownEventTimestamp()
            )
            return false
        }
        guard triggered else {
            pointerGuard.reset()
            return false
        }
        return !pointerGuard.pointerActivityIntervened(
            lastPointerActivityAt: VoicePointerActivity
                .lastPointerEventTimestamp(),
            lastKeyDownActivityAt: VoicePointerActivity
                .lastKeyDownEventTimestamp()
        )
    }

    private func installEventMonitors() {
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMonitoredEvent(event)
            }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMonitoredEvent(event)
            }
            return event
        }
    }

    private func handleMonitoredEvent(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            handleFlagsChanged(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp
            )
        case .keyDown:
            noteNonModifierKeyDown()
            handleGlobalSessionKeyDown(event)
        default:
            break
        }
    }

    /// 全局会话（非 RimeAI 输入法下）支持按 Esc 取消、润色中按空格/回车直接上屏原文。
    private func handleGlobalSessionKeyDown(_ event: NSEvent) {
        let runtime = VoiceDictationRuntime.shared
        guard runtime.isGlobalSessionActive else {
            return
        }
        let modifiers = Self.voiceKeyModifiers(event.modifierFlags)
        if event.keyCode == 53,
           VoiceDictationKeyRouter.isPlainConfirmation(modifiers: modifiers)
        {
            runtime.cancelActiveGlobalSession()
            return
        }
        let isConfirmKey = (event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76)
            && VoiceDictationKeyRouter.isPlainConfirmation(modifiers: modifiers)
        if runtime.isTransforming, isConfirmKey {
            runtime.commitRawDuringGlobalTransform()
        }
    }

    private func handleSecureInputDetected() {
        activeIMKController?.enterSecureInputIfPossible()
        VoiceDictationRuntime.shared.handleGlobalSecureInputDetected()
        startSecureInputRecoveryTimer()
    }

    private func startSecureInputRecoveryTimer() {
        guard secureInputRecoveryTimer == nil else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .milliseconds(400),
            repeating: .milliseconds(400),
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !IsSecureEventInputEnabled() else {
                    return
                }
                self.stopSecureInputRecoveryTimer()
                self.reconcileHotKeys()
            }
        }
        secureInputRecoveryTimer = timer
        timer.resume()
    }

    private func stopSecureInputRecoveryTimer() {
        secureInputRecoveryTimer?.cancel()
        secureInputRecoveryTimer = nil
    }

    static func voiceKeyModifiers(
        _ modifiers: NSEvent.ModifierFlags
    ) -> VoiceDictationKeyModifiers {
        let semantic = modifiers.intersection(.deviceIndependentFlagsMask)
        var result: VoiceDictationKeyModifiers = []
        let mapping: [(NSEvent.ModifierFlags, VoiceDictationKeyModifiers)] = [
            (.capsLock, .capsLock),
            (.shift, .shift),
            (.control, .control),
            (.option, .option),
            (.command, .command),
            (.numericPad, .numericPad),
            (.help, .help),
            (.function, .function),
        ]
        for (appKitFlag, voiceFlag) in mapping
        where semantic.contains(appKitFlag) {
            result.insert(voiceFlag)
        }
        return result
    }
}
