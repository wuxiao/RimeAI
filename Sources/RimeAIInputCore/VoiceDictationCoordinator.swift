import Foundation

typealias VoiceDictationTimeoutCancellation = @Sendable () -> Void
typealias VoiceDictationTimeoutScheduler = @Sendable (
    _ delay: TimeInterval,
    _ operation: @escaping @Sendable () -> Void
) -> VoiceDictationTimeoutCancellation

private final class VoiceDictationDispatchTimeout: @unchecked Sendable {
    let workItem: DispatchWorkItem

    init(operation: @escaping @Sendable () -> Void) {
        workItem = DispatchWorkItem(block: operation)
    }

    func cancel() {
        workItem.cancel()
    }
}

/// 语音听写粘合层：把 `VoiceDictationClientMachine` 的效果落到
/// `VoiceDictationClientTransport`，把服务端消息回灌状态机，并
/// 分别维护录音期 delta 超时与松开后的 final 超时。输入法侧只与本类型交互。
/// 会话语义仍由状态机决定；本类型不做任何上屏决策。
public final class VoiceDictationCoordinator: @unchecked Sendable {
    private struct CallbackSet: Sendable {
        var onPreview: (@Sendable (
            _ stable: String,
            _ partial: String,
            _ pendingConfirm: Bool,
            _ polishApplied: Bool
        ) -> Void)? = nil
        var onCommit: (@Sendable (String) -> Bool)? = nil
        var onPhaseChanged: (@Sendable (
            VoiceDictationClientPhase
        ) -> Void)? = nil
        var onAnnounce: (@Sendable (VoiceDictationErrorCode) -> Void)? = nil
        var onMicrophoneAuthorizationNeeded: (@Sendable () -> Void)? = nil
        var onDisabled: (@Sendable () -> Void)? = nil
    }

    public struct Configuration: Sendable {
        public var socketPath: String
        /// 测试与 ad-hoc 开发必须显式使用 UDS；产品调用点传入不可变构建
        /// 配置。authenticatedXPC 初始化失败时 fail closed，不回退 UDS。
        public var transportPreference: VoiceDictationPreferredTransport
        public var connectTimeout: TimeInterval
        /// socket 已连接并发送 hello 后，等待合法 voice_ready 的上限。
        public var helloResponseTimeout: TimeInterval
        public var deltaTimeout: TimeInterval
        /// `nil` 时沿用本次 start 的 deadline；测试可注入更短超时。
        public var finalTimeout: TimeInterval?
        /// UI 回调的派发队列；产品代码用主队列，测试可注入并发队列。
        public var uiQueue: DispatchQueue

        public init(
            socketPath: String,
            transportPreference: VoiceDictationPreferredTransport =
                .currentBuildConfiguration,
            connectTimeout: TimeInterval = 3,
            helloResponseTimeout: TimeInterval = 3,
            deltaTimeout: TimeInterval = TimeInterval(
                VoiceDictationConstants.deltaTimeoutMilliseconds
            ) / 1_000,
            finalTimeout: TimeInterval? = nil,
            uiQueue: DispatchQueue = .main
        ) {
            self.socketPath = socketPath
            self.transportPreference = transportPreference
            self.connectTimeout = connectTimeout
            self.helloResponseTimeout = helloResponseTimeout
            self.deltaTimeout = deltaTimeout
            self.finalTimeout = finalTimeout
            self.uiQueue = uiQueue
        }
    }

    /// UI 回调统一在主线程派发。单项属性保留给静态装配与测试；产品会话
    /// 使用 `setCallbacks` 原子替换整组回调，避免网络线程读到跨代混合值。
    public var onPreview: (@Sendable (
        _ stable: String,
        _ partial: String,
        _ pendingConfirm: Bool,
        _ polishApplied: Bool
    ) -> Void)? {
        get { callbackValue(\.onPreview) }
        set { setCallbackValue(\.onPreview, to: newValue) }
    }
    /// 返回 `true` 表示目标应用已实际完成 insertText；只有此时才发送
    /// accept 回执。返回 `false`（如焦点/安全输入已变化）不会确认上屏。
    public var onCommit: (@Sendable (String) -> Bool)? {
        get { callbackValue(\.onCommit) }
        set { setCallbackValue(\.onCommit, to: newValue) }
    }
    /// 不携带听写文本；用于录音面板按状态显示/收起。
    public var onPhaseChanged: (@Sendable (
        VoiceDictationClientPhase
    ) -> Void)? {
        get { callbackValue(\.onPhaseChanged) }
        set { setCallbackValue(\.onPhaseChanged, to: newValue) }
    }
    public var onAnnounce: (@Sendable (VoiceDictationErrorCode) -> Void)? {
        get { callbackValue(\.onAnnounce) }
        set { setCallbackValue(\.onAnnounce, to: newValue) }
    }
    public var onMicrophoneAuthorizationNeeded: (@Sendable () -> Void)? {
        get { callbackValue(\.onMicrophoneAuthorizationNeeded) }
        set {
            setCallbackValue(
                \.onMicrophoneAuthorizationNeeded,
                to: newValue
            )
        }
    }
    public var onDisabled: (@Sendable () -> Void)? {
        get { callbackValue(\.onDisabled) }
        set { setCallbackValue(\.onDisabled, to: newValue) }
    }

    private let lock = NSLock()
    private let configuration: Configuration
    private let transport: any VoiceDictationClientTransporting
    private var machine = VoiceDictationClientMachine()
    private var lastPublishedPhase: VoiceDictationClientPhase = .idle
    private var deltaTimeoutWork: DispatchWorkItem?
    private var finalTimeoutWork: DispatchWorkItem?
    private var helloResponseTimeoutCancellation:
        VoiceDictationTimeoutCancellation?
    private var deltaTimeoutGeneration: UInt64 = 0
    private var finalTimeoutGeneration: UInt64 = 0
    private var helloResponseTimeoutGeneration: UInt64 = 0
    private var activeFinalTimeout = TimeInterval(
        VoiceDictationConstants.maximumDeadlineMilliseconds
    ) / 1_000
    private var isConnected = false
    private var isConnecting = false
    private var connectionGeneration: UInt64 = 0
    /// 覆盖“算出 effects 后、真正执行前”这一窗口；任何较新的宿主或
    /// 会话事件都会让旧网络/UI effect 失效。
    private var effectEpoch: UInt64 = 0
    private var callbacks = CallbackSet()
    private let scheduleHelloResponseTimeout: VoiceDictationTimeoutScheduler

    public convenience init(configuration: Configuration) {
        self.init(
            configuration: configuration,
            scheduleHelloResponseTimeout: { delay, operation in
                let timeout = VoiceDictationDispatchTimeout(
                    operation: operation
                )
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + delay,
                    execute: timeout.workItem
                )
                return { timeout.cancel() }
            }
        )
    }

    init(
        configuration: Configuration,
        scheduleHelloResponseTimeout:
            @escaping VoiceDictationTimeoutScheduler
    ) {
        self.configuration = configuration
        self.scheduleHelloResponseTimeout = scheduleHelloResponseTimeout
        transport = VoiceDictationClientTransportFactory.make(
            preference: configuration.transportPreference,
            developmentSocketPath: configuration.socketPath
        )
        transport.setGenerationMessageHandler { [weak self] message, generation in
            self?.handleServerMessage(
                message,
                transportGeneration: generation
            )
        }
        transport.setGenerationDisconnectHandler { [weak self] generation in
            self?.handleDisconnect(transportGeneration: generation)
        }
    }

    /// 为一个宿主会话原子绑定完整回调组，并使已经算出但尚未执行的旧
    /// effects 失效。调用方应在 coordinator 为 idle 时、紧邻 start 调用。
    public func setCallbacks(
        onPreview: (@Sendable (
            _ stable: String,
            _ partial: String,
            _ pendingConfirm: Bool,
            _ polishApplied: Bool
        ) -> Void)?,
        onCommit: (@Sendable (String) -> Bool)?,
        onPhaseChanged: (@Sendable (
            VoiceDictationClientPhase
        ) -> Void)?,
        onAnnounce: (@Sendable (VoiceDictationErrorCode) -> Void)?,
        onMicrophoneAuthorizationNeeded: (@Sendable () -> Void)?,
        onDisabled: (@Sendable () -> Void)?
    ) {
        lock.lock()
        callbacks = CallbackSet(
            onPreview: onPreview,
            onCommit: onCommit,
            onPhaseChanged: onPhaseChanged,
            onAnnounce: onAnnounce,
            onMicrophoneAuthorizationNeeded:
                onMicrophoneAuthorizationNeeded,
            onDisabled: onDisabled
        )
        _ = advanceEffectEpochLocked()
        lock.unlock()
    }

    // MARK: - 输入法入口

    public func startDictation(
        _ context: VoiceDictationSessionContext
    ) {
        lock.lock()
        if isConnecting, machine.phase == .idle {
            // 上一次 connecting 会话可能已被松开/Esc 取消，但底层异步
            // connect 尚未返回。新会话必须先使它失效，否则 sendHello 会
            // 因 isConnecting 直接返回，随后旧 completion 又因 epoch 过期
            // 不会替新会话握手，造成永久卡在 connecting。
            connectionGeneration &+= 1
            isConnecting = false
            isConnected = false
            transport.close()
        }
        let effects = machine.voiceShortcutPressed(context)
        if !effects.isEmpty {
            activeFinalTimeout = configuration.finalTimeout
                ?? TimeInterval(context.deadlineMilliseconds) / 1_000
        }
        let phaseChange = phaseChangeLocked()
        guard !effects.isEmpty || phaseChange != nil else {
            lock.unlock()
            return
        }
        let epoch = advanceEffectEpochLocked()
        lock.unlock()
        publishPhase(phaseChange, epoch: epoch)
        apply(effects, epoch: epoch)
    }

    /// 按住说话按键松开：停止采集并等待唯一 final。
    public func stopDictation() {
        lock.lock()
        let effects = machine.userStoppedRecording()
        let remainsFinalizing: Bool
        if case .finalizing = machine.phase {
            remainsFinalizing = true
        } else {
            remainsFinalizing = false
        }
        let phaseChange = phaseChangeLocked()
        guard !effects.isEmpty || phaseChange != nil || remainsFinalizing else {
            lock.unlock()
            return
        }
        let epoch = advanceEffectEpochLocked()
        lock.unlock()

        cancelHelloResponseTimeout()
        publishPhase(phaseChange, epoch: epoch)
        if effects.isEmpty, remainsFinalizing,
           isEffectEpochCurrent(epoch)
        {
            // 重复松开不重复发 stop，但继续从当前时刻等待有限 final。
            armFinalTimeout(expectedEpoch: epoch)
        }
        apply(effects, epoch: epoch)
    }

    public func userConfirmed() {
        lock.lock()
        let effects = machine.userConfirmed()
        let phaseChange = phaseChangeLocked()
        guard !effects.isEmpty || phaseChange != nil else {
            lock.unlock()
            return
        }
        let epoch = advanceEffectEpochLocked()
        lock.unlock()
        publishPhase(phaseChange, epoch: epoch)
        apply(effects, epoch: epoch)
    }

    public func userCancelled() {
        lock.lock()
        let effects = machine.userCancelled()
        let phaseChange = phaseChangeLocked()
        guard !effects.isEmpty || phaseChange != nil else {
            lock.unlock()
            return
        }
        let epoch = advanceEffectEpochLocked()
        lock.unlock()
        cancelHelloResponseTimeout()
        publishPhase(phaseChange, epoch: epoch)
        apply(effects, epoch: epoch)
    }

    public func sessionSwitched() {
        lock.lock()
        let effects = machine.sessionSwitched()
        let phaseChange = phaseChangeLocked()
        let phaseToPublish = phaseChange ?? machine.phase
        let epoch = advanceEffectEpochLocked()
        lock.unlock()
        cancelHelloResponseTimeout()
        publishPhase(phaseToPublish, epoch: epoch)
        apply(effects, epoch: epoch)
    }

    public func secureInputChanged(active: Bool) {
        lock.lock()
        let effects = machine.secureInputChanged(active: active)
        guard active else {
            // Secure Input 解除只更新状态，不应使正在进行的 connect/hello
            // effect epoch 失效；否则对应 completion/timer 会被静默丢弃。
            lock.unlock()
            return
        }
        let phaseChange = phaseChangeLocked()
        let phaseToPublish = phaseChange ?? machine.phase
        let epoch = advanceEffectEpochLocked()
        lock.unlock()
        cancelHelloResponseTimeout()
        publishPhase(phaseToPublish, epoch: epoch)
        apply(effects, epoch: epoch)
    }

    public func userRetriedVoice() {
        // helper 可能已被重装/重启；显式重试必须新建连接并重新握手。
        resetConnection()
        lock.lock()
        machine.userRetriedVoice()
        let phaseChange = phaseChangeLocked()
        let epoch = advanceEffectEpochLocked()
        lock.unlock()
        publishPhase(phaseChange, epoch: epoch)
    }

    /// 关闭当前 socket 并清除会话/连接代际；下次 start 必须重新连接、
    /// 重新 hello。不会把主动重置计入协议熔断。
    public func resetConnection() {
        cancelHelloResponseTimeout()
        cancelDeltaTimeout()
        cancelFinalTimeout()
        lock.lock()
        connectionGeneration &+= 1
        isConnected = false
        isConnecting = false
        _ = machine.sessionSwitched()
        transport.close()
        let phaseChange = phaseChangeLocked()
        let phaseToPublish = phaseChange ?? machine.phase
        let epoch = advanceEffectEpochLocked()
        lock.unlock()
        publishPhase(phaseToPublish, epoch: epoch)
    }

    /// 应用退出或输入法控制器销毁时释放连接与所有计时器。
    public func shutdown() {
        resetConnection()
    }

    public var phaseForTesting: VoiceDictationClientPhase {
        lock.lock()
        defer { lock.unlock() }
        return machine.phase
    }

    // MARK: - 服务端消息回灌

    private func handleServerMessage(
        _ message: VoiceServerMessage,
        transportGeneration: UInt64
    ) {
        lock.lock()
        guard transport.isCurrentConnectionGeneration(transportGeneration)
        else {
            lock.unlock()
            return
        }
        let wasAwaitingReady = machine.phase == .connecting
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
        // 合法/不合法 ready，或其他协议错误，只要已经离开 connecting，
        // 都必须撤销 hello timer；被忽略的无关消息则继续等待 ready。
        let helloTimeoutCancellation = wasAwaitingReady
            && machine.phase != .connecting
            ? invalidateHelloResponseTimeoutLocked()
            : nil
        let phaseChange = phaseChangeLocked()
        guard !effects.isEmpty || phaseChange != nil else {
            lock.unlock()
            helloTimeoutCancellation?()
            return
        }
        let epoch = advanceEffectEpochLocked()
        lock.unlock()
        helloTimeoutCancellation?()
        publishPhase(phaseChange, epoch: epoch)
        apply(effects, epoch: epoch)
    }

    private func handleDisconnect(transportGeneration: UInt64) {
        lock.lock()
        guard transport.connectionGenerationSnapshot() == transportGeneration
        else {
            lock.unlock()
            return
        }
        connectionGeneration &+= 1
        isConnected = false
        isConnecting = false
        let helloTimeoutCancellation =
            invalidateHelloResponseTimeoutLocked()
        let effects = machine.connectionFailed()
        let phaseChange = phaseChangeLocked()
        let epoch = advanceEffectEpochLocked()
        lock.unlock()
        helloTimeoutCancellation?()
        cancelDeltaTimeout()
        cancelFinalTimeout()
        publishPhase(phaseChange, epoch: epoch)
        apply(effects, epoch: epoch)
    }

    // MARK: - 效果执行

    private func apply(
        _ effects: [VoiceDictationClientEffect],
        epoch: UInt64
    ) {
        guard let callbacks = callbackSnapshot(ifCurrentEpoch: epoch) else {
            return
        }
        for effect in effects {
            guard isEffectEpochCurrent(epoch) else {
                return
            }
            switch effect {
            case .sendHello:
                sendHello(epoch: epoch)
            case .sendStart(let message):
                cancelFinalTimeout(expectedEpoch: epoch)
                armDeltaTimeout(expectedEpoch: epoch)
                sendClientMessage(.start(message), ifCurrentEpoch: epoch)
            case .sendStop(let message):
                cancelDeltaTimeout(expectedEpoch: epoch)
                armFinalTimeout(expectedEpoch: epoch)
                sendClientMessage(.stop(message), ifCurrentEpoch: epoch)
            case .sendCancel(let message):
                cancelDeltaTimeout(expectedEpoch: epoch)
                cancelFinalTimeout(expectedEpoch: epoch)
                sendClientMessage(.cancel(message), ifCurrentEpoch: epoch)
            case .commitText(let text, let accept):
                cancelDeltaTimeout(expectedEpoch: epoch)
                cancelFinalTimeout(expectedEpoch: epoch)
                dispatchToMain { [weak self, onCommit = callbacks.onCommit] in
                    guard self?.isEffectEpochCurrent(epoch) == true else {
                        return
                    }
                    guard onCommit?(text) == true else {
                        return
                    }
                    self?.sendClientMessage(
                        .accept(accept),
                        ifCurrentEpoch: epoch
                    )
                }
            case .showPreview(let stable, let partial, let pendingConfirm, let polishApplied):
                // 待确认阶段不再有 delta：取消超时，避免空转定时器。
                if pendingConfirm {
                    cancelDeltaTimeout(expectedEpoch: epoch)
                    cancelFinalTimeout(expectedEpoch: epoch)
                } else {
                    armDeltaTimeout(expectedEpoch: epoch)
                }
                dispatchToMain { [weak self, onPreview = callbacks.onPreview] in
                    guard self?.isEffectEpochCurrent(epoch) == true else {
                        return
                    }
                    onPreview?(stable, partial, pendingConfirm, polishApplied)
                }
            case .requestMicrophoneAuthorization:
                cancelDeltaTimeout(expectedEpoch: epoch)
                cancelFinalTimeout(expectedEpoch: epoch)
                dispatchToMain {
                    [weak self,
                     onMicrophoneAuthorizationNeeded =
                        callbacks.onMicrophoneAuthorizationNeeded] in
                    guard self?.isEffectEpochCurrent(epoch) == true else {
                        return
                    }
                    onMicrophoneAuthorizationNeeded?()
                }
            case .announceFailure(let code):
                cancelDeltaTimeout(expectedEpoch: epoch)
                cancelFinalTimeout(expectedEpoch: epoch)
                dispatchToMain {
                    [weak self, onAnnounce = callbacks.onAnnounce] in
                    guard self?.isEffectEpochCurrent(epoch) == true else {
                        return
                    }
                    onAnnounce?(code)
                }
            case .voiceDisabled:
                cancelDeltaTimeout(expectedEpoch: epoch)
                cancelFinalTimeout(expectedEpoch: epoch)
                dispatchToMain { [weak self, onDisabled = callbacks.onDisabled] in
                    guard self?.isEffectEpochCurrent(epoch) == true else {
                        return
                    }
                    onDisabled?()
                }
            }
        }
    }

    /// epoch 校验与 NWConnection.send 的入队在同一 coordinator 锁内；
    /// 若宿主切换发生在旧 start 之后，它的 cancel 必然随后入队。
    private func sendClientMessage(
        _ message: VoiceClientMessage,
        ifCurrentEpoch expectedEpoch: UInt64
    ) {
        lock.lock()
        guard effectEpoch == expectedEpoch else {
            lock.unlock()
            return
        }
        transport.send(message)
        lock.unlock()
    }

    private func sendHello(epoch: UInt64) {
        lock.lock()
        guard effectEpoch == epoch else {
            lock.unlock()
            return
        }
        if isConnected {
            let generation = connectionGeneration
            transport.send(.hello(VoiceHelloRequest()))
            lock.unlock()
            armHelloResponseTimeout(
                connectionGeneration: generation,
                expectedEpoch: epoch
            )
            return
        }
        guard !isConnecting else {
            lock.unlock()
            return
        }
        isConnecting = true
        connectionGeneration &+= 1
        let generation = connectionGeneration
        lock.unlock()

        let connectTimeout = configuration.connectTimeout
        Task.detached { [weak self] in
            guard let self else {
                return
            }
            do {
                try await self.transport.connect(timeout: connectTimeout)
                self.handleConnectSuccess(
                    generation: generation,
                    effectEpoch: epoch
                )
            } catch {
                self.handleConnectFailure(
                    generation: generation,
                    effectEpoch: epoch
                )
            }
        }
    }

    private func handleConnectSuccess(
        generation: UInt64,
        effectEpoch expectedEpoch: UInt64
    ) {
        lock.lock()
        guard generation == connectionGeneration else {
            lock.unlock()
            return
        }
        isConnected = true
        isConnecting = false
        guard effectEpoch == expectedEpoch else {
            lock.unlock()
            return
        }
        let shouldSendHello = machine.phase == .connecting
        if shouldSendHello {
            transport.send(.hello(VoiceHelloRequest()))
        }
        lock.unlock()
        if shouldSendHello {
            armHelloResponseTimeout(
                connectionGeneration: generation,
                expectedEpoch: expectedEpoch
            )
        }
    }

    private func handleConnectFailure(
        generation: UInt64,
        effectEpoch expectedEpoch: UInt64
    ) {
        lock.lock()
        guard generation == connectionGeneration else {
            lock.unlock()
            return
        }
        isConnected = false
        isConnecting = false
        guard effectEpoch == expectedEpoch else {
            lock.unlock()
            return
        }
        let effects = machine.connectionFailed()
        let phaseChange = phaseChangeLocked()
        let epoch = advanceEffectEpochLocked()
        lock.unlock()
        publishPhase(phaseChange, epoch: epoch)
        apply(effects, epoch: epoch)
    }

    // MARK: - hello → voice_ready 超时

    private func armHelloResponseTimeout(
        connectionGeneration expectedConnectionGeneration: UInt64,
        expectedEpoch: UInt64
    ) {
        lock.lock()
        guard connectionGeneration == expectedConnectionGeneration,
              effectEpoch == expectedEpoch,
              isConnected,
              !isConnecting,
              machine.phase == .connecting
        else {
            lock.unlock()
            return
        }
        let previousCancellation = invalidateHelloResponseTimeoutLocked()
        let generation = helloResponseTimeoutGeneration
        lock.unlock()
        previousCancellation?()

        let cancellation = scheduleHelloResponseTimeout(
            configuration.helloResponseTimeout
        ) { [weak self] in
            self?.helloResponseTimedOut(
                timeoutGeneration: generation,
                connectionGeneration: expectedConnectionGeneration,
                effectEpoch: expectedEpoch
            )
        }

        lock.lock()
        guard helloResponseTimeoutGeneration == generation,
              connectionGeneration == expectedConnectionGeneration,
              effectEpoch == expectedEpoch,
              isConnected,
              !isConnecting,
              machine.phase == .connecting
        else {
            lock.unlock()
            cancellation()
            return
        }
        helloResponseTimeoutCancellation = cancellation
        lock.unlock()
    }

    private func helloResponseTimedOut(
        timeoutGeneration expectedTimeoutGeneration: UInt64,
        connectionGeneration expectedConnectionGeneration: UInt64,
        effectEpoch expectedEpoch: UInt64
    ) {
        lock.lock()
        guard helloResponseTimeoutGeneration == expectedTimeoutGeneration,
              connectionGeneration == expectedConnectionGeneration,
              effectEpoch == expectedEpoch,
              isConnected,
              !isConnecting,
              machine.phase == .connecting
        else {
            lock.unlock()
            return
        }
        _ = invalidateHelloResponseTimeoutLocked()
        connectionGeneration &+= 1
        isConnected = false
        isConnecting = false
        transport.close()
        let effects = machine.helloResponseTimedOut()
        let phaseChange = phaseChangeLocked()
        let epoch = advanceEffectEpochLocked()
        lock.unlock()

        publishPhase(phaseChange, epoch: epoch)
        apply(effects, epoch: epoch)
    }

    private func cancelHelloResponseTimeout() {
        lock.lock()
        let cancellation = invalidateHelloResponseTimeoutLocked()
        lock.unlock()
        cancellation?()
    }

    /// 调用方持有 `lock`；返回值必须在解锁后执行。
    private func invalidateHelloResponseTimeoutLocked()
        -> VoiceDictationTimeoutCancellation? {
        helloResponseTimeoutGeneration &+= 1
        let cancellation = helloResponseTimeoutCancellation
        helloResponseTimeoutCancellation = nil
        return cancellation
    }

    // MARK: - delta 超时

    private func armDeltaTimeout(expectedEpoch: UInt64? = nil) {
        cancelDeltaTimeout(expectedEpoch: expectedEpoch)
        lock.lock()
        guard expectedEpoch == nil || effectEpoch == expectedEpoch,
              case .listening = machine.phase
        else {
            lock.unlock()
            return
        }
        deltaTimeoutGeneration &+= 1
        let generation = deltaTimeoutGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.lock.lock()
            guard generation == self.deltaTimeoutGeneration else {
                self.lock.unlock()
                return
            }
            self.deltaTimeoutWork = nil
            let effects = self.machine.deltaTimedOut()
            let phaseChange = self.phaseChangeLocked()
            guard !effects.isEmpty || phaseChange != nil else {
                self.lock.unlock()
                return
            }
            let epoch = self.advanceEffectEpochLocked()
            self.lock.unlock()
            self.publishPhase(phaseChange, epoch: epoch)
            self.apply(effects, epoch: epoch)
        }
        deltaTimeoutWork = work
        lock.unlock()
        DispatchQueue.global().asyncAfter(
            deadline: .now() + configuration.deltaTimeout,
            execute: work
        )
    }

    private func cancelDeltaTimeout(expectedEpoch: UInt64? = nil) {
        lock.lock()
        guard expectedEpoch == nil || effectEpoch == expectedEpoch else {
            lock.unlock()
            return
        }
        deltaTimeoutGeneration &+= 1
        let work = deltaTimeoutWork
        deltaTimeoutWork = nil
        lock.unlock()
        work?.cancel()
    }

    // MARK: - 松开后的 final 超时

    private func armFinalTimeout(expectedEpoch: UInt64? = nil) {
        cancelFinalTimeout(expectedEpoch: expectedEpoch)
        lock.lock()
        guard expectedEpoch == nil || effectEpoch == expectedEpoch,
              case .finalizing = machine.phase
        else {
            lock.unlock()
            return
        }
        let timeout = activeFinalTimeout
        finalTimeoutGeneration &+= 1
        let generation = finalTimeoutGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.lock.lock()
            guard generation == self.finalTimeoutGeneration else {
                self.lock.unlock()
                return
            }
            self.finalTimeoutWork = nil
            let effects = self.machine.finalTimedOut()
            let phaseChange = self.phaseChangeLocked()
            guard !effects.isEmpty || phaseChange != nil else {
                self.lock.unlock()
                return
            }
            let epoch = self.advanceEffectEpochLocked()
            self.lock.unlock()
            self.publishPhase(phaseChange, epoch: epoch)
            self.apply(effects, epoch: epoch)
        }
        finalTimeoutWork = work
        lock.unlock()
        DispatchQueue.global().asyncAfter(
            deadline: .now() + timeout,
            execute: work
        )
    }

    private func cancelFinalTimeout(expectedEpoch: UInt64? = nil) {
        lock.lock()
        guard expectedEpoch == nil || effectEpoch == expectedEpoch else {
            lock.unlock()
            return
        }
        finalTimeoutGeneration &+= 1
        let work = finalTimeoutWork
        finalTimeoutWork = nil
        lock.unlock()
        work?.cancel()
    }

    private func dispatchToMain(
        _ operation: @escaping @Sendable () -> Void
    ) {
        configuration.uiQueue.async(execute: operation)
    }

    /// 调用方持有 `lock`；只发布真正的 phase 变化。
    private func phaseChangeLocked() -> VoiceDictationClientPhase? {
        guard machine.phase != lastPublishedPhase else {
            return nil
        }
        lastPublishedPhase = machine.phase
        return machine.phase
    }

    /// 调用方持有 `lock`。
    private func advanceEffectEpochLocked() -> UInt64 {
        effectEpoch &+= 1
        return effectEpoch
    }

    private func isEffectEpochCurrent(_ epoch: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return effectEpoch == epoch
    }

    private func callbackValue<Value>(
        _ keyPath: KeyPath<CallbackSet, Value>
    ) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return callbacks[keyPath: keyPath]
    }

    private func setCallbackValue<Value>(
        _ keyPath: WritableKeyPath<CallbackSet, Value>,
        to value: Value
    ) {
        lock.lock()
        callbacks[keyPath: keyPath] = value
        lock.unlock()
    }

    private func callbackSnapshot(
        ifCurrentEpoch expectedEpoch: UInt64
    ) -> CallbackSet? {
        lock.lock()
        defer { lock.unlock() }
        guard effectEpoch == expectedEpoch else {
            return nil
        }
        return callbacks
    }

    private func publishPhase(
        _ phase: VoiceDictationClientPhase?,
        epoch: UInt64
    ) {
        guard let phase else {
            return
        }
        lock.lock()
        guard effectEpoch == epoch else {
            lock.unlock()
            return
        }
        let onPhaseChanged = callbacks.onPhaseChanged
        configuration.uiQueue.async { [onPhaseChanged] in
            onPhaseChanged?(phase)
        }
        lock.unlock()
    }
}
