import Foundation

/// 语音 helper 的 ASR 引擎抽象。实现负责音频采集与识别，通过回调
/// 产出增量或最终结果；引擎不得直接触达协议或传输层。
public protocol VoiceDictationEngine: Sendable {
    /// 用于握手与 final 的引擎标识。
    var engineID: String { get }

    func start(
        requestID: String,
        mode: VoiceDictationMode,
        deadlineMilliseconds: Int,
        maximumDurationMilliseconds: Int,
        events: @escaping @Sendable (VoiceDictationEngineEvent) -> Void
    )

    func cancel(requestID: String)
}

/// 引擎产出的事件；由 ServerCore 负责校验、sequence 分配与会话关停。
public enum VoiceDictationEngineEvent: Equatable, Sendable {
    case partial(stableText: String, partialText: String, confidence: Double)
    case finished(
        text: String,
        confidence: Double,
        polishApplied: Bool
    )
    case failed(VoiceDictationErrorCode, retryable: Bool)
}

/// 引擎无关的服务端会话核心：只做协议校验、latest-wins、sequence
/// 分配和会话关停，不做 IO。传输层把客户端消息送进 `handle`，
/// 并注入 `setEmitHandler` 接收异步输出。每个输出恰好投递一次：
/// emit 已注入时经 emit 送出，否则出现在 handle 的返回值里。
/// 不变量见 docs/VOICE_INPUT_DESIGN.md 第 3 节。
public final class VoiceDictationServerCore: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public var capabilities: Set<String>
        public var networkPolicy: VoiceNetworkPolicy

        public init(
            capabilities: Set<String>,
            networkPolicy: VoiceNetworkPolicy
        ) {
            self.capabilities = capabilities
            self.networkPolicy = networkPolicy
        }

        public static let localOnly = Configuration(
            capabilities: ["local_asr", "streaming"],
            networkPolicy: .offline
        )
    }

    /// 服务端待发送的完整协议消息；传输层只做编码。
    public enum Output: Equatable, Sendable {
        case ready(VoiceReadyResponse)
        case delta(VoiceDictationDelta)
        case final(VoiceDictationFinal)
        case error(VoiceDictationError)
        case disconnect
    }

    private struct Session {
        let requestID: String
        var lastSequence = 0
        var isClosed = false
        var finalAcceptHash: String?
    }

    private let lock = NSLock()
    private let configuration: Configuration
    private let engine: any VoiceDictationEngine
    private var session: Session?
    private var isHandshakeComplete = false
    private var outbox: [Output] = []
    private var emit: (@Sendable ([Output]) -> Void)?

    public init(
        configuration: Configuration = .localOnly,
        engine: any VoiceDictationEngine
    ) {
        self.configuration = configuration
        self.engine = engine
    }

    /// 异步输出的出口；传输层注入。注入后新输出改走 emit，
    /// handle 的返回值不再携带（避免重复投递）。
    public func setEmitHandler(
        _ handler: @escaping @Sendable ([Output]) -> Void
    ) {
        lock.lock()
        emit = handler
        lock.unlock()
    }

    public var readyResponse: VoiceReadyResponse {
        VoiceReadyResponse(
            capabilities: Array(configuration.capabilities).sorted(),
            networkPolicy: configuration.networkPolicy,
            asrEngineID: engine.engineID
        )
    }

    // MARK: - 客户端消息入口

    @discardableResult
    public func handle(_ message: VoiceHelloRequest) -> [Output] {
        lock.lock()
        guard message.protocolVersion
            == VoiceDictationConstants.protocolVersion,
            message.clientID == VoiceDictationConstants.clientID
        else {
            lock.unlock()
            return [.disconnect]
        }
        isHandshakeComplete = true
        outbox.append(.ready(readyResponse))
        lock.unlock()
        return deliverOutbox()
    }

    @discardableResult
    public func handle(_ message: VoiceDictationStart) -> [Output] {
        lock.lock()
        guard isHandshakeComplete else {
            lock.unlock()
            return [.disconnect]
        }
        guard message.isValid else {
            outbox.append(.error(VoiceDictationError(
                requestID: message.requestID,
                errorCode: .invalidRequest,
                retryable: false
            )))
            lock.unlock()
            return deliverOutbox()
        }
        let hasASR = configuration.capabilities.contains("local_asr")
            || configuration.capabilities.contains("cloud_asr")
        let supportsMode = message.mode != .polish
            || configuration.capabilities.contains("polish")
        guard hasASR, supportsMode else {
            outbox.append(.error(VoiceDictationError(
                requestID: message.requestID,
                errorCode: .invalidRequest,
                retryable: false
            )))
            lock.unlock()
            return deliverOutbox()
        }

        // latest-wins：新 start 隐含取消前一会话并丢弃其缓冲，
        // 不为前一会话产生任何后续消息。引擎调用必须发生在锁外：
        // 引擎可能同步回调事件，ingestEngineEvent 需要重新拿锁。
        var cancelledRequestID: String?
        if var previous = session, !previous.isClosed {
            previous.isClosed = true
            session = previous
            cancelledRequestID = previous.requestID
        }
        session = Session(requestID: message.requestID)
        let requestID = message.requestID
        let mode = message.mode
        let deadline = message.deadlineMilliseconds
        let maximumDuration = message.maximumDurationMilliseconds
        lock.unlock()

        if let cancelledRequestID {
            engine.cancel(requestID: cancelledRequestID)
        }
        engine.start(
            requestID: requestID,
            mode: mode,
            deadlineMilliseconds: deadline,
            maximumDurationMilliseconds: maximumDuration,
            events: engineEventSink(requestID: requestID)
        )
        return deliverOutbox()
    }

    @discardableResult
    public func handle(_ message: VoiceDictationCancel) -> [Output] {
        lock.lock()
        guard isHandshakeComplete else {
            lock.unlock()
            return [.disconnect]
        }
        var cancelledRequestID: String?
        if var session, !session.isClosed {
            session.isClosed = true
            self.session = session
            cancelledRequestID = session.requestID
        }
        lock.unlock()
        if let cancelledRequestID {
            engine.cancel(requestID: cancelledRequestID)
        }
        return deliverOutbox()
    }

    @discardableResult
    public func handle(_ message: VoiceDictationAccept) -> [Output] {
        lock.lock()
        defer { lock.unlock() }
        guard isHandshakeComplete else {
            return []
        }
        guard message.isValid else {
            return []
        }
        // 哈希与服务端已知 final 不一致时静默丢弃：清除会话，
        // 不重发结果，不产生任何输出。
        if let session, let finalAcceptHash = session.finalAcceptHash,
           finalAcceptHash != message.acceptedTextSHA256
        {
            self.session = nil
        }
        return []
    }

    @discardableResult
    public func handleUnexpectedMessage() -> [Output] {
        lock.lock()
        let shouldDisconnect = !isHandshakeComplete
        if shouldDisconnect {
            session = nil
            outbox.removeAll()
        }
        lock.unlock()
        return shouldDisconnect ? [.disconnect] : []
    }

    // MARK: - 引擎事件

    private func engineEventSink(
        requestID: String
    ) -> @Sendable (VoiceDictationEngineEvent) -> Void {
        { [weak self] event in
            self?.ingestEngineEvent(requestID: requestID, event: event)
        }
    }

    private func ingestEngineEvent(
        requestID: String,
        event: VoiceDictationEngineEvent
    ) {
        lock.lock()
        guard var session, session.requestID == requestID,
              !session.isClosed
        else {
            lock.unlock()
            return
        }

        switch event {
        case let .partial(stableText, partialText, confidence):
            session.lastSequence += 1
            let delta = VoiceDictationDelta(
                requestID: requestID,
                sequence: session.lastSequence,
                stableText: stableText,
                partialText: partialText,
                confidence: confidence,
                elapsedMilliseconds: 0
            )
            if delta.isValid {
                self.session = session
                outbox.append(.delta(delta))
            } else {
                session.isClosed = true
                self.session = session
                outbox.append(.error(VoiceDictationError(
                    requestID: requestID,
                    errorCode: .asrEngineError,
                    retryable: false
                )))
            }

        case let .finished(text, confidence, polishApplied):
            session.isClosed = true
            let final = VoiceDictationFinal(
                requestID: requestID,
                finalText: text,
                confidence: confidence,
                asrEngineID: engine.engineID,
                polishApplied: polishApplied,
                elapsedMilliseconds: 0
            )
            if final.isValid {
                session.finalAcceptHash = VoiceDictationAccept
                    .acceptHash(for: final.finalText)
                self.session = session
                outbox.append(.final(final))
            } else {
                self.session = session
                outbox.append(.error(VoiceDictationError(
                    requestID: requestID,
                    errorCode: .asrEngineError,
                    retryable: false
                )))
            }

        case let .failed(errorCode, retryable):
            session.isClosed = true
            self.session = session
            // 润色失败必须由引擎降级为 direct finished；独立
            // polish_failed 错误是协议违规，只能断开连接。
            if errorCode == .polishFailed {
                outbox.append(.disconnect)
            } else {
                outbox.append(.error(VoiceDictationError(
                    requestID: requestID,
                    errorCode: errorCode,
                    retryable: retryable
                )))
            }
        }
        let hasEmitHandler = emit != nil
        lock.unlock()
        guard hasEmitHandler else {
            // 同步回调（engine.start 调用栈内）且无 emit：
            // 留在 outbox，由 handle 的返回值送出。
            return
        }
        _ = deliverOutbox()
    }

    // MARK: - 投递

    /// outbox 恰好投递一次：emit 存在则回调并返回空数组，
    /// 否则返回给 handle 的调用方。
    private func deliverOutbox() -> [Output] {
        lock.lock()
        guard !outbox.isEmpty else {
            lock.unlock()
            return []
        }
        let pending = outbox
        outbox.removeAll()
        let handler = emit
        lock.unlock()
        if let handler {
            handler(pending)
            return []
        }
        return pending
    }
}
