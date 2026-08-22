import AppKit
import Carbon
import Foundation

/// 进程级语音会话宿主。InputMethodKit 可能为不同客户端创建多个
/// controller；语音 socket、状态机和浮层必须只有一份，并在回调上屏前
/// 重新核验最初的 owner、client、应用会话与光标位置。
@MainActor
protocol VoiceDictationRuntimeOwner: AnyObject {
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

@MainActor
final class VoiceDictationRuntime {
    static let shared = VoiceDictationRuntime()

    private let coordinator: VoiceDictationCoordinator
    private let panel = VoiceDictationPanelController()
    private let settings = RimeAISettingsStore.shared

    private weak var activeOwner: (any VoiceDictationRuntimeOwner)?
    private weak var currentOwner: (any VoiceDictationRuntimeOwner)?
    private weak var targetClient: AnyObject?
    private var targetAppSessionID: String?
    private var targetSelection = NSRange(location: NSNotFound, length: 0)
    private var anchorRect = NSRect.zero
    private var validationTimer: DispatchSourceTimer?
    private var observedPhase: VoiceDictationClientPhase = .idle
    private var activeGeneration: UUID?
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
            transportPreference: .currentBuildConfiguration
        ))
        configureCallbacks(generation: nil)
        observeProcessState()
    }

    var phase: VoiceDictationClientPhase {
        coordinator.phaseForTesting
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
        guard activeOwner === owner else {
            return false
        }
        if case .pendingConfirm = phase {
            return true
        }
        return false
    }

    func claim(owner: any VoiceDictationRuntimeOwner) {
        panel.hide()
        if let activeOwner, activeOwner !== owner {
            invalidateActiveSession(reason: .sessionSwitch)
        }
        currentOwner = owner
    }

    @discardableResult
    func start(
        owner: any VoiceDictationRuntimeOwner,
        client: AnyObject,
        context: VoiceDictationSessionContext,
        selection: NSRange,
        anchorRect: NSRect
    ) -> Bool {
        guard currentOwner === owner else {
            return false
        }
        guard !IsSecureEventInputEnabled() else {
            owner.voiceRuntimeSecureInputDetected()
            return false
        }
        guard owner.voiceRuntimeTargetIsValid(
            client: client,
            appSessionID: context.appSessionID,
            selection: selection,
            anchorRect: anchorRect
        ) else {
            return false
        }
        guard phase == .idle else {
            return false
        }
        if let previousOwner = activeOwner, previousOwner !== owner {
            invalidateActiveSession(reason: .sessionSwitch)
        }

        activeOwner = owner
        currentOwner = owner
        targetClient = client
        targetAppSessionID = context.appSessionID
        targetSelection = selection
        self.anchorRect = anchorRect
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
        panel.showConnecting(
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
        let previousPhase = phase
        coordinator.stopDictation()
        switch previousPhase {
        case .listening:
            settings.record(.voiceStopped)
            observedPhase = phase
            panel.showFinalizing(
                anchorRect: anchorRect,
                onCancel: cancellationHandler(owner: owner)
            )
        case .connecting:
            // 松开发生在 helper 完成握手之前：本次录音从未启动。
            clearTarget(hidePanel: true)
        case .idle, .finalizing, .pendingConfirm, .disabled:
            break
        }
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

    func cancel(owner: any VoiceDictationRuntimeOwner) {
        guard activeOwner === owner else {
            if currentOwner === owner {
                panel.hide()
            }
            return
        }
        let wasActive = isActive(owner: owner)
        coordinator.userCancelled()
        if wasActive {
            settings.record(.voiceCancelled)
        }
        clearTarget(hidePanel: true)
    }

    func sessionSwitched(owner: any VoiceDictationRuntimeOwner) {
        guard activeOwner === owner else {
            if currentOwner === owner {
                panel.hide()
            }
            return
        }
        invalidateActiveSession(reason: .sessionSwitch)
    }

    func secureInputChanged(
        active: Bool,
        owner: any VoiceDictationRuntimeOwner
    ) {
        coordinator.secureInputChanged(active: active)
        guard active else {
            return
        }
        if currentOwner === owner {
            panel.hide()
        }
        if activeOwner === owner {
            settings.record(.voiceCancelled)
            clearTarget(hidePanel: true)
        }
    }

    func deactivate(owner: any VoiceDictationRuntimeOwner) {
        sessionSwitched(owner: owner)
        if currentOwner === owner {
            panel.hide()
            currentOwner = nil
        }
        VoiceHotKeyManager.shared.deactivate(owner: owner)
    }

    func dismissTransientPanel(owner: any VoiceDictationRuntimeOwner) {
        guard currentOwner === owner, activeOwner == nil else {
            return
        }
        panel.hide()
    }

    func shutdown() {
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
        permissionBlocked = false
        activeGeneration = nil
        activeOwner = nil
        currentOwner = nil
        targetClient = nil
        targetAppSessionID = nil
    }

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
        guard let owner = activeOwner, targetIsValid(owner: owner) else {
            invalidateActiveSession(reason: .sessionSwitch)
            return
        }
        if pendingConfirm {
            if !recordedFinal {
                settings.record(.voiceFinalShown)
                recordedFinal = true
            }
        } else if !recordedPreview {
            settings.record(.voicePreviewShown)
            recordedPreview = true
        }
        observedPhase = phase
        panel.updatePreview(
            stable: stable,
            partial: partial,
            pendingConfirm: pendingConfirm,
            polishApplied: polishApplied,
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
            onCancel: cancellationHandler(
                owner: owner,
                generation: generation
            )
        )
    }

    private func handleCommit(_ text: String, generation: UUID?) -> Bool {
        guard let generation, generation == activeGeneration else {
            return false
        }
        defer {
            confirming = false
            clearTarget(hidePanel: true)
        }
        guard let owner = activeOwner,
              let client = targetClient,
              let appSessionID = targetAppSessionID,
              targetIsValid(owner: owner),
              !text.isEmpty,
              text.count <= VoiceDictationConstants.maximumTextCharacters,
              !text.contains("\n"),
              !text.contains("\r")
        else {
            settings.record(.voiceFailure)
            return false
        }
        let committed = owner.voiceRuntimeCommit(
            text,
            client: client,
            appSessionID: appSessionID,
            selection: targetSelection,
            anchorRect: anchorRect
        )
        settings.record(committed ? .voiceAccepted : .voiceFailure)
        return committed
    }

    private func handleFailure(
        _ code: VoiceDictationErrorCode,
        generation: UUID?
    ) {
        guard let generation, generation == activeGeneration else {
            return
        }
        let owner = activeOwner
        let failureAnchor = anchorRect
        let canPresentAtOriginalTarget = owner.map {
            targetIsValid(owner: $0)
        } ?? false
        settings.record(.voiceFailure)
        clearTarget(hidePanel: !canPresentAtOriginalTarget)
        if code == .incompatibleProtocol {
            owner?.voiceRuntimeDidBecomeUnavailable()
        }
        guard canPresentAtOriginalTarget else {
            return
        }
        panel.showFailure(
            failureMessage(for: code),
            anchorRect: failureAnchor,
            onCancel: { [weak self] in self?.panel.hide() }
        )
    }

    private func handleMicrophoneDenied(generation: UUID?) {
        guard let generation, generation == activeGeneration else {
            return
        }
        let owner = activeOwner
        let failureAnchor = anchorRect
        let canPresentAtOriginalTarget = owner.map {
            targetIsValid(owner: $0)
        } ?? false
        permissionBlocked = true
        settings.record(.voiceMicrophoneDenied)
        clearTarget(hidePanel: !canPresentAtOriginalTarget)
        if let owner {
            VoiceHotKeyManager.shared.deactivate(owner: owner)
            owner.voiceRuntimeDidBecomeUnavailable()
        }
        guard canPresentAtOriginalTarget else {
            return
        }
        panel.showFailure(
            "麦克风或语音识别权限已被拒绝。请在系统设置的“隐私与安全性”中允许 RimeAI Voice Helper 使用这两项权限，然后在 RimeAI 设置中重试。",
            anchorRect: failureAnchor,
            onCancel: { [weak self] in self?.panel.hide() }
        )
    }

    private func handleDisabled(generation: UUID?) {
        guard let generation, generation == activeGeneration else {
            return
        }
        let owner = activeOwner
        let failureAnchor = anchorRect
        let canPresentAtOriginalTarget = owner.map {
            targetIsValid(owner: $0)
        } ?? false
        settings.record(.voiceDisabled)
        clearTarget(hidePanel: !canPresentAtOriginalTarget)
        if let owner {
            VoiceHotKeyManager.shared.deactivate(owner: owner)
            owner.voiceRuntimeDidBecomeUnavailable()
        }
        guard canPresentAtOriginalTarget else {
            return
        }
        panel.showFailure(
            "语音服务连续失败，已在本次输入法进程中停用。请在 RimeAI 设置中检查 helper 后重试。",
            anchorRect: failureAnchor,
            onCancel: { [weak self] in self?.panel.hide() }
        )
    }

    private func handlePhaseChanged(
        _ newPhase: VoiceDictationClientPhase,
        generation: UUID?
    ) {
        guard let generation, generation == activeGeneration else {
            return
        }
        observedPhase = newPhase
        guard let owner = activeOwner else {
            return
        }
        switch newPhase {
        case .listening:
            panel.showListening(
                anchorRect: anchorRect,
                onCancel: cancellationHandler(
                    owner: owner,
                    generation: generation
                )
            )
        case .finalizing:
            panel.showFinalizing(
                anchorRect: anchorRect,
                onCancel: cancellationHandler(
                    owner: owner,
                    generation: generation
                )
            )
        case .idle:
            // Coordinator 先发布 idle，再排入同一主队列上的 failure/commit
            // effect。延后一轮让 effect 先显示错误或完成提交；若 effect 因
            // 断连被丢弃，这个兜底仍会清理 confirming，避免永久吞键。
            let expectedGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.activeGeneration == expectedGeneration,
                      self.phase == .idle
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
                self.permissionBlocked = false
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
            clearTarget(hidePanel: true)
            return
        }
        if IsSecureEventInputEnabled() {
            // 由 controller 统一进入 Secure Input；它会回调
            // secureInputChanged，原子地撤销会话、热键与易失上下文。
            owner.voiceRuntimeSecureInputDetected()
            return
        }
        guard targetIsValid(owner: owner) else {
            invalidateActiveSession(reason: .sessionSwitch)
            return
        }
    }

    private func targetIsValid(
        owner: any VoiceDictationRuntimeOwner
    ) -> Bool {
        guard currentOwner === owner,
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
            hadActiveSession = false
        }
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

    private func clearTarget(hidePanel: Bool) {
        validationTimer?.cancel()
        validationTimer = nil
        if hidePanel {
            panel.hide()
        }
        targetClient = nil
        targetAppSessionID = nil
        targetSelection = NSRange(location: NSNotFound, length: 0)
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
