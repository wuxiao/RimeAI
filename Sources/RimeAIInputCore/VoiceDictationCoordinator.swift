import Foundation

/// 语音听写粘合层：把 `VoiceDictationClientMachine` 的效果落到
/// `VoiceDictationClientTransport`，把服务端消息回灌状态机，并
/// 维护 delta 超时定时器。输入法侧只与本类型交互。
/// 会话语义仍由状态机决定；本类型不做任何上屏决策。
public final class VoiceDictationCoordinator: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var socketPath: String
        public var connectTimeout: TimeInterval
        public var deltaTimeout: TimeInterval
        /// UI 回调的派发队列；产品代码用主队列，测试可注入并发队列。
        public var uiQueue: DispatchQueue

        public init(
            socketPath: String,
            connectTimeout: TimeInterval = 3,
            deltaTimeout: TimeInterval = TimeInterval(
                VoiceDictationConstants.deltaTimeoutMilliseconds
            ) / 1_000,
            uiQueue: DispatchQueue = .main
        ) {
            self.socketPath = socketPath
            self.connectTimeout = connectTimeout
            self.deltaTimeout = deltaTimeout
            self.uiQueue = uiQueue
        }
    }

    /// UI 回调统一在主线程派发。
    public var onPreview: (@Sendable (
        _ stable: String,
        _ partial: String,
        _ pendingConfirm: Bool,
        _ polishApplied: Bool
    ) -> Void)?
    public var onCommit: (@Sendable (String) -> Void)?
    public var onAnnounce: (@Sendable (VoiceDictationErrorCode) -> Void)?
    public var onMicrophoneAuthorizationNeeded: (@Sendable () -> Void)?
    public var onDisabled: (@Sendable () -> Void)?

    private let lock = NSLock()
    private let configuration: Configuration
    private let transport: VoiceDictationClientTransport
    private var machine = VoiceDictationClientMachine()
    private var deltaTimeoutWork: DispatchWorkItem?
    private var isConnected = false
    private var isConnecting = false

    public init(configuration: Configuration) {
        self.configuration = configuration
        transport = VoiceDictationClientTransport(
            socketPath: configuration.socketPath
        )
        transport.setMessageHandler { [weak self] message in
            self?.handleServerMessage(message)
        }
        transport.setDisconnectHandler { [weak self] in
            self?.handleDisconnect()
        }
    }

    // MARK: - 输入法入口

    public func startDictation(
        _ context: VoiceDictationSessionContext
    ) {
        lock.lock()
        let effects = machine.voiceShortcutPressed(context)
        lock.unlock()
        apply(effects)
    }

    public func userConfirmed() {
        lock.lock()
        let effects = machine.userConfirmed()
        lock.unlock()
        apply(effects)
    }

    public func userCancelled() {
        lock.lock()
        let effects = machine.userCancelled()
        lock.unlock()
        apply(effects)
    }

    public func sessionSwitched() {
        lock.lock()
        let effects = machine.sessionSwitched()
        lock.unlock()
        apply(effects)
    }

    public func secureInputChanged(active: Bool) {
        lock.lock()
        let effects = machine.secureInputChanged(active: active)
        lock.unlock()
        apply(effects)
    }

    public func userRetriedVoice() {
        lock.lock()
        machine.userRetriedVoice()
        lock.unlock()
    }

    public var phaseForTesting: VoiceDictationClientPhase {
        lock.lock()
        defer { lock.unlock() }
        return machine.phase
    }

    // MARK: - 服务端消息回灌

    private func handleServerMessage(_ message: VoiceServerMessage) {
        lock.lock()
        let effects: [VoiceDictationClientEffect]
        switch message {
        case .ready(let response):
            effects = machine.ready(response)
        case .delta(let delta):
            effects = machine.delta(delta)
        case .final(let final):
            effects = machine.finalResult(final)
        case .error(let error):
            effects = machine.serverError(error)
        }
        lock.unlock()
        apply(effects)
    }

    private func handleDisconnect() {
        cancelDeltaTimeout()
        lock.lock()
        isConnected = false
        let effects = machine.connectionFailed()
        lock.unlock()
        apply(effects)
    }

    // MARK: - 效果执行

    private func apply(_ effects: [VoiceDictationClientEffect]) {
        for effect in effects {
            switch effect {
            case .sendHello:
                sendHello()
            case .sendStart(let message):
                armDeltaTimeout()
                transport.send(.start(message))
            case .sendCancel(let message):
                cancelDeltaTimeout()
                transport.send(.cancel(message))
            case .sendAccept(let message):
                transport.send(.accept(message))
            case .commitText(let text):
                dispatchToMain { [onCommit] in
                    onCommit?(text)
                }
            case .showPreview(let stable, let partial, let pendingConfirm, let polishApplied):
                // 待确认阶段不再有 delta：取消超时，避免空转定时器。
                if pendingConfirm {
                    cancelDeltaTimeout()
                } else {
                    armDeltaTimeout()
                }
                dispatchToMain { [onPreview] in
                    onPreview?(stable, partial, pendingConfirm, polishApplied)
                }
            case .requestMicrophoneAuthorization:
                dispatchToMain { [onMicrophoneAuthorizationNeeded] in
                    onMicrophoneAuthorizationNeeded?()
                }
            case .announceFailure(let code):
                dispatchToMain { [onAnnounce] in
                    onAnnounce?(code)
                }
            case .voiceDisabled:
                dispatchToMain { [onDisabled] in
                    onDisabled?()
                }
            }
        }
    }

    private func sendHello() {
        lock.lock()
        if isConnected {
            lock.unlock()
            transport.send(.hello(VoiceHelloRequest()))
            return
        }
        guard !isConnecting else {
            lock.unlock()
            return
        }
        isConnecting = true
        lock.unlock()

        let connectTimeout = configuration.connectTimeout
        Task.detached { [weak self] in
            guard let self else {
                return
            }
            do {
                try await self.transport.connect(timeout: connectTimeout)
                self.handleConnectSuccess()
            } catch {
                self.handleConnectFailure()
            }
        }
    }

    private func handleConnectSuccess() {
        lock.lock()
        isConnected = true
        isConnecting = false
        lock.unlock()
        transport.send(.hello(VoiceHelloRequest()))
    }

    private func handleConnectFailure() {
        lock.lock()
        let effects = machine.connectionFailed()
        lock.unlock()
        apply(effects)
    }

    // MARK: - delta 超时

    private func armDeltaTimeout() {
        cancelDeltaTimeout()
        let work = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.lock.lock()
            let effects = self.machine.deltaTimedOut()
            self.lock.unlock()
            self.apply(effects)
        }
        deltaTimeoutWork = work
        DispatchQueue.global().asyncAfter(
            deadline: .now() + configuration.deltaTimeout,
            execute: work
        )
    }

    private func cancelDeltaTimeout() {
        lock.lock()
        let work = deltaTimeoutWork
        deltaTimeoutWork = nil
        lock.unlock()
        work?.cancel()
    }

    private func dispatchToMain(
        _ operation: @escaping @Sendable () -> Void
    ) {
        configuration.uiQueue.async(execute: operation)
    }
}
