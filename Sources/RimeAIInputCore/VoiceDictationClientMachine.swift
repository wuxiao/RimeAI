import Foundation

/// 语音听写客户端状态机（输入法侧）。纯逻辑、无 IO；网络层把效果
/// 落到 UDS。状态与不变量见 docs/VOICE_INPUT_DESIGN.md 第 3.8 节。
public enum VoiceDictationClientPhase: Equatable, Sendable {
    case idle
    case connecting
    case listening(requestID: String)
    case pendingConfirm(requestID: String)
    case disabled
}

/// 状态机要求传输层执行的效果。
public enum VoiceDictationClientEffect: Equatable, Sendable {
    case sendHello(VoiceHelloRequest)
    case sendStart(VoiceDictationStart)
    case sendCancel(VoiceDictationCancel)
    case sendAccept(VoiceDictationAccept)
    case commitText(String)
    case showPreview(
        stable: String,
        partial: String,
        pendingConfirm: Bool,
        polishApplied: Bool
    )
    case requestMicrophoneAuthorization
    case announceFailure(VoiceDictationErrorCode)
    case voiceDisabled
}

/// 一次听写会话的宿主上下文，由输入法在触发语音快捷键时提供。
public struct VoiceDictationSessionContext: Equatable, Sendable {
    public let compositionID: UUID
    public let appSessionID: String
    public let bundleID: String
    public let mode: VoiceDictationMode
    public let deadlineMilliseconds: Int

    public init(
        compositionID: UUID,
        appSessionID: String,
        bundleID: String,
        mode: VoiceDictationMode = .direct,
        deadlineMilliseconds: Int = 1_500
    ) {
        self.compositionID = compositionID
        self.appSessionID = appSessionID
        self.bundleID = bundleID
        self.mode = mode
        self.deadlineMilliseconds = deadlineMilliseconds
    }
}

public struct VoiceDictationClientMachine: Sendable {
    public private(set) var phase: VoiceDictationClientPhase = .idle
    public private(set) var secureInputActive = false
    public private(set) var microphoneDenied = false

    /// 熔断：同一安装会话内连续协议错误或连接失败。
    public private(set) var consecutiveProtocolFailures = 0

    private var context: VoiceDictationSessionContext?
    private var lastDeltaSequence = 0
    private var previewStableText = ""
    private var previewPartialText = ""
    private var pendingConfirmText = ""

    public init() {}

    // MARK: - 会话启动

    /// 语音快捷键。Secure Input 活跃、麦克风被拒或已熔断时拒绝启动。
    @discardableResult
    public mutating func voiceShortcutPressed(
        _ context: VoiceDictationSessionContext
    ) -> [VoiceDictationClientEffect] {
        guard phase == .idle,
              !secureInputActive,
              !microphoneDenied
        else {
            return []
        }
        self.context = context
        phase = .connecting
        return [.sendHello(
            VoiceHelloRequest()
        )]
    }

    /// 收到 voice_ready：兼容则发 start，不兼容按协议失败处理并断开。
    @discardableResult
    public mutating func ready(
        _ response: VoiceReadyResponse
    ) -> [VoiceDictationClientEffect] {
        guard phase == .connecting,
              let context
        else {
            return []
        }
        guard response.isCompatible,
              response.supports(context.mode)
        else {
            return protocolFailure(.incompatibleProtocol)
        }
        let requestID = UUID().uuidString
        lastDeltaSequence = 0
        previewStableText = ""
        previewPartialText = ""
        phase = .listening(requestID: requestID)
        let start = VoiceDictationStart(
            requestID: requestID,
            compositionID: context.compositionID,
            appSessionID: context.appSessionID,
            bundleID: context.bundleID,
            mode: context.mode,
            deadlineMilliseconds: context.deadlineMilliseconds
        )
        guard start.isValid else {
            return protocolFailure(.invalidRequest)
        }
        return [.sendStart(start)]
    }

    // MARK: - 服务端消息

    /// 乱序、重复或不匹配的 delta 直接丢弃；无效文本按协议失败处理。
    @discardableResult
    public mutating func delta(
        _ delta: VoiceDictationDelta
    ) -> [VoiceDictationClientEffect] {
        guard case let .listening(requestID) = phase,
              delta.requestID == requestID
        else {
            return []
        }
        guard delta.isValid else {
            return protocolFailure(.internalError)
        }
        guard delta.sequence > lastDeltaSequence else {
            return []
        }
        lastDeltaSequence = delta.sequence
        previewStableText = delta.stableText
        previewPartialText = delta.partialText
        return [.showPreview(
            stable: delta.stableText,
            partial: delta.partialText,
            pendingConfirm: false,
            polishApplied: false
        )]
    }

    @discardableResult
    public mutating func finalResult(
        _ final: VoiceDictationFinal
    ) -> [VoiceDictationClientEffect] {
        guard case let .listening(requestID) = phase,
              final.requestID == requestID
        else {
            return []
        }
        guard final.isValid else {
            return protocolFailure(.internalError)
        }
        pendingConfirmText = final.finalText
        previewStableText = final.finalText
        previewPartialText = ""
        phase = .pendingConfirm(requestID: requestID)
        return [.showPreview(
            stable: final.finalText,
            partial: "",
            pendingConfirm: true,
            polishApplied: final.polishApplied
        )]
    }

    @discardableResult
    public mutating func serverError(
        _ error: VoiceDictationError
    ) -> [VoiceDictationClientEffect] {
        guard error.isValid,
              !error.isProtocolViolation
        else {
            return protocolFailure(.internalError)
        }
        guard hasActiveSession(error.requestID)
        else {
            return []
        }
        resetSession()
        if error.errorCode == .micDenied {
            microphoneDenied = true
            return [.requestMicrophoneAuthorization]
        }
        return [.announceFailure(error.errorCode)]
    }

    // MARK: - 用户与宿主事件

    /// `Space`/回车：上屏的唯一触发。上屏后回传 accept 哈希。
    @discardableResult
    public mutating func userConfirmed()
        -> [VoiceDictationClientEffect] {
        guard case let .pendingConfirm(requestID) = phase,
              !pendingConfirmText.isEmpty
        else {
            return []
        }
        let text = pendingConfirmText
        let accept = VoiceDictationAccept(
            requestID: requestID,
            acceptedTextSHA256: VoiceDictationAccept.acceptHash(for: text)
        )
        resetSession()
        return [.commitText(text), .sendAccept(accept)]
    }

    /// `Esc`：录音、润色、待确认阶段全可用。
    @discardableResult
    public mutating func userCancelled()
        -> [VoiceDictationClientEffect] {
        guard let requestID = activeRequestIDForCancel() else {
            return []
        }
        resetSession()
        return [.sendCancel(
            VoiceDictationCancel(
                requestID: requestID,
                reason: .userAbort
            )
        )]
    }

    /// 宿主应用切换。
    @discardableResult
    public mutating func sessionSwitched()
        -> [VoiceDictationClientEffect] {
        guard let requestID = activeRequestIDForCancel() else {
            return []
        }
        resetSession()
        return [.sendCancel(
            VoiceDictationCancel(
                requestID: requestID,
                reason: .sessionSwitch
            )
        )]
    }

    /// Secure Input 状态变化：活跃时取消会话并阻止新会话。
    @discardableResult
    public mutating func secureInputChanged(active: Bool)
        -> [VoiceDictationClientEffect] {
        secureInputActive = active
        guard active,
              let requestID = activeRequestIDForCancel()
        else {
            return []
        }
        resetSession()
        return [.sendCancel(
            VoiceDictationCancel(
                requestID: requestID,
                reason: .secureInput
            )
        )]
    }

    /// delta 间隔超时且无 final：主动取消，静默失败，不计熔断。
    @discardableResult
    public mutating func deltaTimedOut()
        -> [VoiceDictationClientEffect] {
        guard case let .listening(requestID) = phase else {
            return []
        }
        resetSession()
        return [.sendCancel(
            VoiceDictationCancel(
                requestID: requestID,
                reason: .clientTimeout
            )
        )]
    }

    /// 连接失败：计熔断。
    @discardableResult
    public mutating func connectionFailed()
        -> [VoiceDictationClientEffect] {
        guard phase != .idle else {
            return []
        }
        resetSession()
        return registerProtocolFailure()
    }

    /// 设置中心显式重试：清除熔断与麦克风拒绝标记。
    public mutating func userRetriedVoice() {
        consecutiveProtocolFailures = 0
        microphoneDenied = false
        if phase == .disabled {
            phase = .idle
        }
    }

    // MARK: - 私有

    private func hasActiveSession(_ requestID: String) -> Bool {
        switch phase {
        case let .listening(active), let .pendingConfirm(active):
            return active == requestID
        case .idle, .connecting, .disabled:
            return false
        }
    }

    private func activeRequestIDForCancel() -> String? {
        switch phase {
        case let .listening(requestID), let .pendingConfirm(requestID):
            return requestID
        case .idle, .connecting, .disabled:
            return nil
        }
    }

    private mutating func resetSession() {
        context = nil
        lastDeltaSequence = 0
        previewStableText = ""
        previewPartialText = ""
        pendingConfirmText = ""
        if phase != .disabled {
            phase = .idle
        }
    }

    /// 连续 3 次协议错误或连接失败后禁用语音入口。
    private mutating func protocolFailure(
        _ code: VoiceDictationErrorCode
    ) -> [VoiceDictationClientEffect] {
        resetSession()
        let failureEffects = registerProtocolFailure()
        return [.announceFailure(code)] + failureEffects
    }

    private mutating func registerProtocolFailure()
        -> [VoiceDictationClientEffect] {
        consecutiveProtocolFailures += 1
        guard consecutiveProtocolFailures
            >= VoiceDictationConstants.circuitBreakerLimit
        else {
            return []
        }
        phase = .disabled
        return [.voiceDisabled]
    }
}
