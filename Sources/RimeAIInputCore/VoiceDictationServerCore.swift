import Foundation

/// 服务端已校验并交给引擎的完整启动请求。`requestID` 是 helper 内部的
/// 唯一控制句柄；`wireRequestID` 仅用于关联客户端协议消息，不能用于
/// stop/cancel 寻址。
public struct VoiceDictationEngineRequest: Equatable, Sendable {
    public let requestID: String
    public let wireRequestID: String
    public let compositionID: String
    public let applicationSessionID: String
    public let bundleID: String
    public let mode: VoiceDictationMode
    public let deadlineMilliseconds: Int
    public let maximumDurationMilliseconds: Int
    public let hotwordSnapshot: VoiceHotwordSnapshot

    public init(
        requestID: String,
        wireRequestID: String,
        compositionID: String,
        applicationSessionID: String,
        bundleID: String,
        mode: VoiceDictationMode,
        deadlineMilliseconds: Int,
        maximumDurationMilliseconds: Int,
        hotwordSnapshot: VoiceHotwordSnapshot = .empty
    ) {
        self.requestID = requestID
        self.wireRequestID = wireRequestID
        self.compositionID = compositionID
        self.applicationSessionID = applicationSessionID
        self.bundleID = bundleID
        self.mode = mode
        self.deadlineMilliseconds = deadlineMilliseconds
        self.maximumDurationMilliseconds = maximumDurationMilliseconds
        self.hotwordSnapshot = hotwordSnapshot
    }
}

/// 语音 helper 的 ASR 引擎抽象。实现负责音频采集与识别，通过回调
/// 产出增量或最终结果；引擎不得直接触达协议或传输层。
public protocol VoiceDictationEngine: Sendable {
    /// 引擎身份、资产证据和真实能力的唯一来源。
    var descriptor: VoiceEngineDescriptor { get }

    func start(
        _ request: VoiceDictationEngineRequest,
        events: @escaping @Sendable (VoiceDictationEngineEvent) -> Void
    )

    /// 停止接收当前语音段的新音频，并促使引擎产出最终结果。
    func stop(requestID: String)

    func cancel(requestID: String)
}

public extension VoiceDictationEngine {
    /// Product-managed engines include an immutable artifact digest prefix so
    /// one adapter's model revisions cannot be conflated in results.
    var engineID: String { descriptor.protocolEngineID }
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
    private static let maximumRequestIDsPerConnection = 4_096

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
        /// 只在 helper 内部使用的唯一引擎句柄。wire requestID 可被异常或
        /// 恶意客户端跨会话复用，绝不能用它直接寻址引擎控制面。
        let engineRequestID: String
        let generation: UInt64
        let startedAtMilliseconds: Double
        var lastSequence = 0
        var lastElapsedMilliseconds = 0.0
        var isFinalizing = false
        var isClosed = false
        var finalAcceptHash: String?
    }

    private let lock = NSLock()
    private let engine: any VoiceDictationEngine
    private let engineDescriptor: VoiceEngineDescriptor
    private let monotonicNowMilliseconds: @Sendable () -> Double
    private var session: Session?
    private var isHandshakeComplete = false
    private var outbox: [Output] = []
    private var connectionEpoch: UInt64 = 0
    /// 同一连接内每次会话切换/取消都会前进。异步输出既绑定连接 epoch，
    /// 也绑定生成它的 output epoch，防止已取出的旧 disconnect/final 在
    /// 新 start 之后落地。
    private var outputEpoch: UInt64 = 0
    private var sessionGeneration: UInt64 = 0
    /// 同一连接内 wire requestID 不得复用；否则已进入传输队列的旧输出
    /// 无法仅凭协议字段与新会话区分。连接 reset 后由 epoch 隔离并清空。
    private var seenRequestIDs: Set<String> = []
    private var emit: (@Sendable ([Output], UInt64, UInt64) -> Void)?
    private var isDrainingOutbox = false

    public init(
        engine: any VoiceDictationEngine,
        monotonicNowMilliseconds: @escaping @Sendable () -> Double = {
            ProcessInfo.processInfo.systemUptime * 1_000
        }
    ) {
        self.engine = engine
        self.engineDescriptor = engine.descriptor
        self.monotonicNowMilliseconds = monotonicNowMilliseconds
    }

    /// 异步输出的出口；传输层注入。注入后新输出改走 emit，
    /// handle 的返回值不再携带（避免重复投递）。
    public func setEmitHandler(
        _ handler: @escaping @Sendable ([Output]) -> Void
    ) {
        setConnectionScopedEmitHandler { outputs, _, _ in
            handler(outputs)
        }
    }

    /// 传输层使用的连接作用域出口。`connectionEpoch` 在每次连接 reset 时
    /// 前进，使已从旧引擎回调中取出的输出无法在重连后落到新客户端。
    func setConnectionScopedEmitHandler(
        _ handler: @escaping @Sendable ([Output], UInt64, UInt64) -> Void
    ) {
        lock.lock()
        emit = handler
        lock.unlock()
    }

    /// 传输层在自己的 routeLock 内、真正发送前复验这两个 epoch。
    /// 这样“旧 batch 已从 outbox 取出→新 start→旧 batch 恢复”会被丢弃。
    func isCurrentOutputScope(
        connectionEpoch expectedConnectionEpoch: UInt64,
        outputEpoch expectedOutputEpoch: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return connectionEpoch == expectedConnectionEpoch
            && outputEpoch == expectedOutputEpoch
    }

    public var readyResponse: VoiceReadyResponse {
        VoiceReadyResponse(
            capabilities: engineDescriptor.advertisedProtocolCapabilities,
            networkPolicy: engineDescriptor.networkPolicy,
            asrEngineID: engineDescriptor.protocolEngineID,
            maximumHotwords: engineDescriptor.advertisedMaximumHotwords
        )
    }

    /// 仅暴露是否仍等待回执，不暴露 final 文本或哈希。
    var hasPendingFinalAcknowledgement: Bool {
        lock.lock()
        defer { lock.unlock() }
        return session?.finalAcceptHash != nil
    }

    /// 每条 UDS 连接都必须重新 hello；连接替换或关闭时同时作废旧会话。
    @discardableResult
    func resetConnection() -> UInt64 {
        lock.lock()
        let engineRequestIDToCancel: String?
        if let session {
            engineRequestIDToCancel = session.engineRequestID
        } else {
            engineRequestIDToCancel = nil
        }
        isHandshakeComplete = false
        session = nil
        outbox.removeAll()
        seenRequestIDs.removeAll()
        connectionEpoch &+= 1
        outputEpoch &+= 1
        let newEpoch = connectionEpoch
        lock.unlock()
        if let engineRequestIDToCancel {
            engine.cancel(requestID: engineRequestIDToCancel)
        }
        return newEpoch
    }

    // MARK: - 客户端消息入口

    @discardableResult
    public func handle(_ message: VoiceHelloRequest) -> [Output] {
        lock.lock()
        guard message.isValid else {
            let engineRequestIDToCancel: String?
            if let session {
                engineRequestIDToCancel = session.engineRequestID
            } else {
                engineRequestIDToCancel = nil
            }
            isHandshakeComplete = false
            session = nil
            outbox.removeAll()
            seenRequestIDs.removeAll()
            outputEpoch &+= 1
            lock.unlock()
            if let engineRequestIDToCancel {
                engine.cancel(requestID: engineRequestIDToCancel)
            }
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
            let error = VoiceDictationError(
                requestID: message.requestID,
                errorCode: .invalidRequest,
                retryable: false
            )
            if session?.requestID == message.requestID || !error.isValid {
                let engineRequestID = failConnectionLocked()
                lock.unlock()
                if let engineRequestID {
                    engine.cancel(requestID: engineRequestID)
                }
                return [.disconnect]
            }
            outbox.append(.error(error))
            lock.unlock()
            return deliverOutbox()
        }
        let advertisedCapabilities = Set(
            engineDescriptor.advertisedProtocolCapabilities
        )
        let hasASR = advertisedCapabilities.contains("local_asr")
            || advertisedCapabilities.contains("cloud_asr")
        let supportsMode = message.mode != .polish
            || advertisedCapabilities.contains("polish")
        let supportsHotwordSnapshot = advertisedCapabilities.contains(
            "hotword_snapshot"
        )
        let hotwordContractMatches = supportsHotwordSnapshot
            ? message.hotwordSnapshot.map {
                $0.phrases.count
                    <= engineDescriptor.advertisedMaximumHotwords
            } == true
            // 不支持热词的引擎：空快照等价于没有热词，载荷为空才放行。
            : message.hotwordSnapshot.map(\.isEmpty) ?? true
        guard hasASR, supportsMode, hotwordContractMatches else {
            if session?.requestID == message.requestID {
                let engineRequestID = failConnectionLocked()
                lock.unlock()
                if let engineRequestID {
                    engine.cancel(requestID: engineRequestID)
                }
                return [.disconnect]
            }
            outbox.append(.error(VoiceDictationError(
                requestID: message.requestID,
                errorCode: .invalidRequest,
                retryable: false
            )))
            lock.unlock()
            return deliverOutbox()
        }
        guard seenRequestIDs.count < Self.maximumRequestIDsPerConnection,
              seenRequestIDs.insert(message.requestID).inserted
        else {
            // 相同 wire ID 下，旧输出和新会话在协议上不可区分。不能发送
            // invalid_request 让客户端 idle 而旧麦克风仍工作；直接取消内部
            // 句柄并断开，下一连接以新 epoch/空集合重新握手。
            let engineRequestID = failConnectionLocked()
            lock.unlock()
            if let engineRequestID {
                engine.cancel(requestID: engineRequestID)
            }
            return [.disconnect]
        }

        // latest-wins：新 start 隐含取消前一会话并丢弃其缓冲，
        // 不为前一会话产生任何后续消息。引擎调用必须发生在锁外：
        // 引擎可能同步回调事件，ingestEngineEvent 需要重新拿锁。
        var cancelledEngineRequestID: String?
        if var previous = session {
            // 即使协议状态已 closed，引擎清理仍可能在另一个回调线程上尚未
            // 完成。新 start 必须再次幂等 cancel 旧内部句柄并等待返回，避免
            // 单实例 ASR 把新段误判为 overload。
            previous.isClosed = true
            session = previous
            cancelledEngineRequestID = previous.engineRequestID
        }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        let engineRequestID = UUID().uuidString
        outputEpoch &+= 1
        outbox.removeAll()
        session = Session(
            requestID: message.requestID,
            engineRequestID: engineRequestID,
            generation: generation,
            startedAtMilliseconds: monotonicNowMilliseconds()
        )
        let engineRequest = VoiceDictationEngineRequest(
            requestID: engineRequestID,
            wireRequestID: message.requestID,
            compositionID: message.compositionID,
            applicationSessionID: message.appSessionID,
            bundleID: message.bundleID,
            mode: message.mode,
            deadlineMilliseconds: message.deadlineMilliseconds,
            maximumDurationMilliseconds: message.maximumDurationMilliseconds,
            hotwordSnapshot: message.hotwordSnapshot ?? .empty
        )
        lock.unlock()

        if let cancelledEngineRequestID {
            engine.cancel(requestID: cancelledEngineRequestID)
        }
        engine.start(
            engineRequest,
            events: engineEventSink(
                requestID: message.requestID,
                sessionGeneration: generation
            )
        )
        return deliverOutbox()
    }

    @discardableResult
    public func handle(_ message: VoiceDictationStop) -> [Output] {
        lock.lock()
        guard isHandshakeComplete else {
            lock.unlock()
            return [.disconnect]
        }
        guard message.isValid else {
            let error = VoiceDictationError(
                requestID: message.requestID,
                errorCode: .invalidRequest,
                retryable: false
            )
            if session?.requestID == message.requestID || !error.isValid {
                let engineRequestID = failConnectionLocked()
                lock.unlock()
                if let engineRequestID {
                    engine.cancel(requestID: engineRequestID)
                }
                return [.disconnect]
            }
            outbox.append(.error(error))
            lock.unlock()
            return deliverOutbox()
        }
        guard var session,
              session.requestID == message.requestID,
              !session.isClosed,
              !session.isFinalizing
        else {
            lock.unlock()
            return deliverOutbox()
        }
        session.isFinalizing = true
        let engineRequestID = session.engineRequestID
        self.session = session
        lock.unlock()

        // stop 与 cancel 不同：引擎应结束音频并异步产出 final。
        // 调用必须在锁外，以允许引擎同步回调最终事件。
        engine.stop(requestID: engineRequestID)
        return deliverOutbox()
    }

    @discardableResult
    public func handle(_ message: VoiceDictationCancel) -> [Output] {
        lock.lock()
        guard isHandshakeComplete else {
            lock.unlock()
            return [.disconnect]
        }
        guard message.isValid else {
            let engineRequestID = failConnectionLocked()
            lock.unlock()
            if let engineRequestID {
                engine.cancel(requestID: engineRequestID)
            }
            return [.disconnect]
        }
        var cancelledEngineRequestID: String?
        if var session, session.requestID == message.requestID {
            if !session.isClosed {
                session.isClosed = true
                cancelledEngineRequestID = session.engineRequestID
            }
            // Esc/会话取消在 final 已生成但尚未确认时也必须清掉待确认状态；
            // 此时引擎已结束，无需再次 cancel，但 accept 不能再生效。
            self.session = nil
            outbox.removeAll()
            outputEpoch &+= 1
        }
        lock.unlock()
        if let cancelledEngineRequestID {
            engine.cancel(requestID: cancelledEngineRequestID)
        }
        return deliverOutbox()
    }

    @discardableResult
    public func handle(_ message: VoiceDictationAccept) -> [Output] {
        lock.lock()
        guard isHandshakeComplete else {
            lock.unlock()
            return []
        }
        guard message.isValid else {
            let engineRequestID = failConnectionLocked()
            lock.unlock()
            if let engineRequestID {
                engine.cancel(requestID: engineRequestID)
            }
            return [.disconnect]
        }
        guard let session,
              session.requestID == message.requestID,
              let finalAcceptHash = session.finalAcceptHash,
              finalAcceptHash == message.acceptedTextSHA256
        else {
            lock.unlock()
            return []
        }
        // 只有当前 request 的匹配回执才结束会话；旧 request 或错误文本
        // 的回执静默丢弃，绝不能清除当前待确认状态。
        self.session = nil
        outbox.removeAll()
        outputEpoch &+= 1
        lock.unlock()
        return []
    }

    // MARK: - 引擎事件

    private func engineEventSink(
        requestID: String,
        sessionGeneration: UInt64
    ) -> @Sendable (VoiceDictationEngineEvent) -> Void {
        { [weak self] event in
            self?.ingestEngineEvent(
                requestID: requestID,
                sessionGeneration: sessionGeneration,
                event: event
            )
        }
    }

    private func ingestEngineEvent(
        requestID: String,
        sessionGeneration: UInt64,
        event: VoiceDictationEngineEvent
    ) {
        lock.lock()
        guard var session, session.requestID == requestID,
              session.generation == sessionGeneration,
              !session.isClosed
        else {
            lock.unlock()
            return
        }

        var shouldCancelEngine = false
        switch event {
        case let .partial(stableText, partialText, confidence):
            let elapsed = elapsedMilliseconds(for: session)
            session.lastElapsedMilliseconds = elapsed
            let cumulativeText = stableText + partialText

            if stableText.count + partialText.count
                > VoiceDictationConstants.maximumTextCharacters
            {
                // delta 的协议长度是两个字段各自的 Character 数之和。
                // 拼接边界可能让组合字符合并，不能只检查 cumulativeText.count；
                // 一旦字段总长度超限，就安全截至完整 Character 并 final。
                session.isClosed = true
                let final = VoiceDictationFinal(
                    requestID: requestID,
                    finalText: VoiceTextValidation
                        .truncatedToMaximumCharacters(cumulativeText),
                    confidence: confidence,
                    asrEngineID: engineDescriptor.protocolEngineID,
                    polishApplied: false,
                    elapsedMilliseconds: elapsed
                )
                if final.isValid {
                    session.finalAcceptHash = VoiceDictationAccept
                        .acceptHash(for: final.finalText)
                    outbox.append(.final(final))
                } else {
                    outbox.append(.error(VoiceDictationError(
                        requestID: requestID,
                        errorCode: .asrEngineError,
                        retryable: false
                    )))
                }
                self.session = session
                shouldCancelEngine = true
            } else {
                session.lastSequence += 1
                let delta = VoiceDictationDelta(
                    requestID: requestID,
                    sequence: session.lastSequence,
                    stableText: stableText,
                    partialText: partialText,
                    confidence: confidence,
                    elapsedMilliseconds: elapsed
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
                    shouldCancelEngine = true
                }
            }

        case let .finished(text, confidence, polishApplied):
            let elapsed = elapsedMilliseconds(for: session)
            session.lastElapsedMilliseconds = elapsed
            session.isClosed = true
            let final = VoiceDictationFinal(
                requestID: requestID,
                finalText: VoiceTextValidation
                    .truncatedToMaximumCharacters(text),
                confidence: confidence,
                asrEngineID: engineDescriptor.protocolEngineID,
                polishApplied: polishApplied,
                elapsedMilliseconds: elapsed
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
        let engineRequestID = session.engineRequestID
        let hasEmitHandler = emit != nil
        lock.unlock()
        if shouldCancelEngine {
            engine.cancel(requestID: engineRequestID)
        }
        guard hasEmitHandler else {
            // 同步回调（engine.start 调用栈内）且无 emit：
            // 留在 outbox，由 handle 的返回值送出。
            return
        }
        _ = deliverOutbox()
    }

    /// 从服务端观察到 start 到当前事件的单调耗时。若测试注入的时钟
    /// 异常回退或给出非有限值，沿用上一事件耗时而不是生成无效协议值。
    private func elapsedMilliseconds(for session: Session) -> Double {
        let measured = monotonicNowMilliseconds()
            - session.startedAtMilliseconds
        guard measured.isFinite else {
            return session.lastElapsedMilliseconds
        }
        return max(session.lastElapsedMilliseconds, max(measured, 0))
    }

    /// 仅在持有 `lock` 时调用；引擎 cancel 必须由调用方在解锁后执行。
    private func failConnectionLocked() -> String? {
        let engineRequestID = session?.engineRequestID
        isHandshakeComplete = false
        session = nil
        outbox.removeAll()
        seenRequestIDs.removeAll()
        outputEpoch &+= 1
        return engineRequestID
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
        guard emit != nil else {
            let pending = outbox
            outbox.removeAll()
            lock.unlock()
            return pending
        }
        guard !isDrainingOutbox else {
            lock.unlock()
            return []
        }
        isDrainingOutbox = true

        while true {
            let pending = outbox
            outbox.removeAll()
            let handler = emit
            let connectionScope = connectionEpoch
            let outputScope = outputEpoch
            lock.unlock()
            handler?(pending, connectionScope, outputScope)

            lock.lock()
            guard !outbox.isEmpty, emit != nil else {
                isDrainingOutbox = false
                lock.unlock()
                return []
            }
        }
    }
}
