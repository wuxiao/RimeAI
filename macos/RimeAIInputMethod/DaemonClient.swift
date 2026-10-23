import Foundation
import os

/// LM-002 验证全链路插桩：infer→连接→hello→结果→熔断的生死链
/// 经 unified log（subsystem fun.wwcn.rimeai, category daemon-client）
/// 直接观察，消除推断。用后可整体移除。
private let daemonClientLog = Logger(
    subsystem: "fun.wwcn.rimeai",
    category: "daemon-client"
)

extension Notification.Name {
    static let rimeAIDaemonStatusDidChange = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.daemon-status-did-change"
    )
}

/// 守护进程客户端：daemon hello/ready 握手、模型工件状态、
/// 熔断与状态通知。连接管线（分帧、重连、串行发送、超时、
/// 代际计数）由 `NDJSONUDSTransport` 提供。
final class DaemonClient: @unchecked Sendable {
    typealias Completion = @Sendable (SemanticInferenceResult?) -> Void
    typealias ReadyCompletion = @MainActor @Sendable (
        Result<Void, Error>
    ) -> Void
    /// 异步神经整句迟到帧路由（reveal A-F1：按 requestID 注册，
    /// 帧到达时一次性取回；与 `pending` 表同队列变更、同生命周期
    /// 清理——不再用被最新 controller init 覆盖的单例单槽，避免多
    /// IMK controller 并存时迟到帧被路由到错误 pipeline 后静默
    /// 丢弃）。容量有界：仅保留最近 16 条（流水线侧本就只接受
    /// latest-request-wins，被逐出的都是必 stale 的旧请求）。
    private static let sentenceLateRouteCapacity = 16
    private var sentenceLateRoutes:
        [String: @MainActor @Sendable (DaemonSentenceLateFrame) -> Void] = [:]
    private var sentenceLateRouteOrder: [String] = []

    static let shared = DaemonClient()

    private struct PendingRequest {
        let completion: Completion
    }

    private var queue: DispatchQueue { transport.queue }
    private let transport: NDJSONUDSTransport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var connectionState = DaemonClientConnectionState()
    private var readyWaitState = DaemonClientReadyWaitState()
    private var readyCompletion: ReadyCompletion?
    private var helloTimeout: DispatchWorkItem?
    private var pending: [String: PendingRequest] = [:]
    private var circuitBreaker = FailureCircuitBreaker()
    private var modelArtifactID = "尚未连接"
    private var modelArtifacts: [DaemonModelArtifact] = []
    private var daemonOfflineLock = false
    /// daemon hello 通告的 capability 快照（LM-003 反馈帧门控）。
    /// 与其它可变状态同在 transport 队列上读写；对外快照经
    /// `supportsSentenceFeedback` 读取时持锁。
    private var serverCapabilities: Set<String> = []
    private let capabilitiesLock = NSLock()

    private init() {
        let socketPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("RimeAI", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("rimeai.sock")
            .path
        transport = NDJSONUDSTransport(
            configuration: NDJSONUDSTransport.Configuration(
                socketPath: socketPath,
                queueLabel: "fun.wwcn.rimeai.daemon-client",
                connectTimeoutMilliseconds: 3_000
            )
        )
        transport.setEventHandler { [weak self] event in
            self?.handle(event)
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func infer(
        _ request: SemanticInferenceRequest,
        completion: @escaping Completion
    ) {
        queue.async { [self] in
            guard circuitBreaker.allowsRequest() else {
                daemonClientLog.notice("infer rejected by circuit breaker: req=\(request.requestID, privacy: .public)")
                publishStatus("熔断冷却中")
                let result = SemanticInferenceResult(
                    status: "circuit_open",
                    requestID: request.requestID,
                    compositionID: request.compositionID,
                    revision: request.revision,
                    appSessionID: request.appSessionID,
                    rankedCandidate: nil,
                    sentenceSuggestion: nil,
                    confidence: nil
                )
                DispatchQueue.main.async {
                    completion(result)
                }
                return
            }
            pending[request.requestID] = PendingRequest(
                completion: completion
            )
            guard let payload = encodeLine(request) else {
                finish(requestID: request.requestID, result: nil)
                return
            }
            transport.enqueueOutbound(
                data: payload,
                requestID: request.requestID
            )
            ensureConnection()
            transport.flushOutbound()
            transport.scheduleTimeout(
                afterMilliseconds: request.deadlineMilliseconds + 50
            ) { [weak self] in
                self?.expire(requestID: request.requestID)
            }
        }
    }

    func connect() {
        queue.async { [self] in
            guard circuitBreaker.allowsRequest() else {
                publishStatus("熔断冷却中")
                return
            }
            ensureConnection()
        }
    }

    /// 为一次 allowSentence 请求登记迟到帧路由（发送闭包内在发送前
    /// 调用；帧到达或连接拆除时消费/清除）。
    func registerSentenceLateRoute(
        requestID: String,
        handler: @escaping @MainActor @Sendable (
            DaemonSentenceLateFrame
        ) -> Void
    ) {
        queue.async { [self] in
            sentenceLateRoutes[requestID] = handler
            sentenceLateRouteOrder.append(requestID)
            while sentenceLateRouteOrder.count
                > Self.sentenceLateRouteCapacity
            {
                let evicted = sentenceLateRouteOrder.removeFirst()
                if evicted != requestID {
                    sentenceLateRoutes.removeValue(forKey: evicted)
                }
            }
        }
    }

    /// 帧到达时一次性取回路由（无路由 = 未登记/已消费/已逐出，
    /// 流水线侧本就会按 stale 丢弃）。
    private func takeSentenceLateRoute(
        requestID: String?
    ) -> (@MainActor @Sendable (DaemonSentenceLateFrame) -> Void)? {
        guard let requestID,
              let handler = sentenceLateRoutes
                  .removeValue(forKey: requestID)
        else {
            return nil
        }
        sentenceLateRouteOrder.removeAll { $0 == requestID }
        return handler
    }

    func invalidateCurrentGeneration(
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        queue.async { [self] in
            tearDownConnection(
                failPending: true,
                recordFailure: false,
                status: "已失效旧连接"
            )
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    func connectWhenReady(completion: @escaping ReadyCompletion) {
        queue.async { [self] in
            tearDownConnection(
                failPending: true,
                recordFailure: false,
                status: "正在建立新的认证连接"
            )
            let generation = ensureConnection()
            readyWaitState.arm(generation: generation)
            readyCompletion = completion
        }
    }

    func cancel(requestID: String) {
        queue.async { [self] in
            guard pending.removeValue(forKey: requestID) != nil else {
                return
            }
            let shouldSendCancel = wireCancelPolicy(requestID: requestID)
            if shouldSendCancel,
               let payload = encodeLine(
                DaemonCancelRequest(requestID: requestID)
            ) {
                transport.enqueueOutbound(data: payload, requestID: nil)
                transport.flushOutbound()
            }
        }
    }

    func disconnect() {
        queue.async { [self] in
            tearDownConnection(
                failPending: true,
                recordFailure: false,
                status: "已断开"
            )
        }
    }
}

// MARK: - 传输层事件与握手

private extension DaemonClient {
    func handle(_ event: NDJSONUDSTransport.Event) {
        switch event {
        case let .connectionReady(generation):
            handleTransportReady(generation: generation)
        case let .lineReceived(generation, line):
            process(line: line, generation: generation)
        case let .connectionClosed(_, reason):
            handleTransportClosed(reason: reason)
        }
    }

    func handleTransportReady(generation: UInt64) {
        daemonClientLog.notice("transport ready: gen=\(generation, privacy: .public)")
        guard connectionState.transportBecameReady(generation: generation),
              let hello = encodeLine(
                DaemonHelloRequest(
                    clientID: Bundle.main.bundleIdentifier
                        ?? "fun.wwcn.inputmethod.RimeAI"
                )
              )
        else {
            tearDownConnection(
                failPending: true,
                recordFailure: true,
                status: "握手编码失败"
            )
            return
        }
        transport.sendImmediate(hello)
        armHelloTimeout(generation: generation)
    }

    func handleTransportClosed(
        reason: NDJSONUDSTransport.CloseReason
    ) {
        daemonClientLog.notice("transport closed: reason=\(String(describing: reason), privacy: .public)")
        tearDownConnection(
            failPending: true,
            recordFailure: true,
            status: reason.localizedStatusDescription
        )
    }

    /// 建立新连接；握手状态机与传输层代际保持同步推进。
    @discardableResult
    func ensureConnection() -> UInt64 {
        let generation = transport.open()
        guard connectionState.phase == .disconnected else {
            return generation
        }
        _ = connectionState.beginConnection()
        assert(
            connectionState.generation == generation,
            "握手状态机与传输层代际失步"
        )
        modelArtifactID = "尚未连接"
        modelArtifacts = []
        daemonOfflineLock = false
        publishStatus("正在连接")
        return generation
    }

    func armHelloTimeout(generation: UInt64) {
        cancelHelloTimeout()
        helloTimeout = transport.scheduleTimeout(
            afterMilliseconds: 3_000
        ) { [weak self] in
            guard let self,
                  self.connectionState.shouldExpireHello(
                      generation: generation
                  )
            else {
                return
            }
            self.tearDownConnection(
                failPending: true,
                recordFailure: true,
                status: "握手超时"
            )
        }
    }

    func cancelHelloTimeout() {
        helloTimeout?.cancel()
        helloTimeout = nil
    }

    func process(line: Data, generation: UInt64) {
        if connectionState.phase == .awaitingHello {
            guard let hello = try? decoder.decode(
                DaemonHelloResponse.self,
                from: line
            ) else {
                daemonClientLog.notice(
                    "hello rejected: decode failed len=\(line.count, privacy: .public)"
                )
                tearDownConnection(
                    failPending: true,
                    recordFailure: true,
                    status: "协议不兼容"
                )
                return
            }
            guard connectionState.acceptHello(
                hello,
                generation: generation
            ) else {
                let stateGeneration = connectionState.generation
                let statePhase = String(describing: connectionState.phase)
                let compatible = hello.isCompatible
                let diagnosis = "stateGen=\(stateGeneration) frameGen=\(generation) "
                    + "phase=\(statePhase) compatible=\(compatible)"
                daemonClientLog.notice(
                    "hello rejected: \(diagnosis, privacy: .public)"
                )
                tearDownConnection(
                    failPending: true,
                    recordFailure: true,
                    status: "协议不兼容"
                )
                return
            }
            cancelHelloTimeout()
            daemonClientLog.notice("hello accepted: model=\(hello.modelArtifactID, privacy: .public) caps=\(hello.capabilities.count, privacy: .public)")
            modelArtifactID = hello.modelArtifactID
            modelArtifacts = hello.modelArtifacts ?? []
            daemonOfflineLock = true
            capabilitiesLock.lock()
            serverCapabilities = Set(hello.capabilities)
            capabilitiesLock.unlock()
            transport.markProtocolReady()
            publishStatus("就绪")
            completeReadyWaiter(
                generation: generation,
                result: .success(())
            )
            return
        }
        guard connectionState.canAcceptApplicationFrame(
            generation: generation
        ) else {
            tearDownConnection(
                failPending: true,
                recordFailure: true,
                status: "握手未完成"
            )
            return
        }
        guard let result = try? decoder.decode(
            SemanticInferenceResult.self,
            from: line
        )
        else {
            tearDownConnection(
                failPending: true,
                recordFailure: true,
                status: "响应格式错误"
            )
            return
        }
        if result.type == "cancelled" {
            return
        }
        if result.type == "sentence_late" {
            // 神经臂迟到帧：独立于在途请求槽（同步 result 可能已消费
            // 完成该 requestID），按 requestID 路由到发起请求的
            // pipeline（绑定校验仍在流水线侧执行）。
            if let frame = try? decoder.decode(
                DaemonSentenceLateFrame.self,
                from: line
            ) {
                let handler = takeSentenceLateRoute(
                    requestID: frame.requestID
                )
                if let handler {
                    DispatchQueue.main.async {
                        handler(frame)
                    }
                }
            }
            return
        }
        guard result.schemaVersion == 1,
              result.type == "result",
              let requestID = result.requestID
        else {
            tearDownConnection(
                failPending: true,
                recordFailure: true,
                status: "响应协议错误"
            )
            return
        }
        if result.status == "ok" {
            circuitBreaker.recordSuccess()
            publishStatus("就绪")
        } else if ["timeout", "engine_error"].contains(result.status) {
            circuitBreaker.recordFailure()
            publishStatus(
                circuitBreaker.allowsRequest()
                    ? "推理失败"
                    : "熔断冷却中"
            )
        } else if result.status == "circuit_open" {
            // circuit_open 是客户端自身熔断拒绝的回声（DaemonClient
            // 熔断分支构造的结果），不是服务端新失败：不得再
            // recordFailure——否则每次被拒都把 openUntil 顺延 30 秒，
            // 只要用户持续打字（含续写等高频 daemon 调用），熔断
            // 永不过期，“本地模型暂不可用”自锁（2026-10-23 实锤）。
            publishStatus("服务端熔断")
        }
        finish(requestID: requestID, result: result)
    }
}

// MARK: - 请求收尾与连接拆除

private extension DaemonClient {
    /// 撤回本地队列中该请求的帧，并按原语义决定是否补发
    /// 线上 cancel：只有已真正发出的请求才需要服务端取消。
    func wireCancelPolicy(requestID: String) -> Bool {
        let hadBufferedApplication = transport.removeOutboundFrames(
            requestID: requestID
        )
        return hadBufferedApplication
            ? false
            : transport.canSendApplicationFrames
    }

    func expire(requestID: String) {
        daemonClientLog.notice("request expired: req=\(requestID, privacy: .public)")
        guard let request = pending.removeValue(forKey: requestID) else {
            return
        }
        circuitBreaker.recordFailure()
        publishStatus(
            circuitBreaker.allowsRequest()
                ? "请求超时"
                : "熔断冷却中"
        )
        if wireCancelPolicy(requestID: requestID),
           let payload = encodeLine(
               DaemonCancelRequest(requestID: requestID)
           )
        {
            transport.enqueueOutbound(data: payload, requestID: nil)
            transport.flushOutbound()
        }
        DispatchQueue.main.async {
            request.completion(nil)
        }
    }

    func finish(
        requestID: String,
        result: SemanticInferenceResult?
    ) {
        guard let request = pending.removeValue(forKey: requestID) else {
            return
        }
        DispatchQueue.main.async {
            request.completion(result)
        }
    }

    func tearDownConnection(
        failPending: Bool,
        recordFailure: Bool,
        status: String
    ) {
        let invalidatedGeneration = connectionState.generation
        _ = connectionState.invalidate(
            generation: invalidatedGeneration
        )
        cancelHelloTimeout()
        transport.close()
        modelArtifactID = "尚未连接"
        modelArtifacts = []
        daemonOfflineLock = false
        sentenceLateRoutes.removeAll(keepingCapacity: false)
        sentenceLateRouteOrder.removeAll(keepingCapacity: false)
        if recordFailure {
            circuitBreaker.recordFailure()
        }
        publishStatus(
            circuitBreaker.allowsRequest()
                ? status
                : "熔断冷却中"
        )
        completeReadyWaiter(
            generation: invalidatedGeneration,
            result: .failure(readinessError(status: status))
        )
        if failPending {
            let requests = pending.values
            pending.removeAll(keepingCapacity: false)
            for request in requests {
                DispatchQueue.main.async {
                    request.completion(nil)
                }
            }
        }
    }

    func completeReadyWaiter(
        generation: UInt64,
        result: Result<Void, Error>
    ) {
        let shouldComplete: Bool
        switch result {
        case .success:
            shouldComplete = readyWaitState.consumeReady(
                generation: generation,
                connectionState: connectionState
            )
        case .failure:
            shouldComplete = readyWaitState.consumeFailure(
                generation: generation
            )
        }
        guard shouldComplete, let completion = readyCompletion else {
            return
        }
        readyCompletion = nil
        DispatchQueue.main.async {
            completion(result)
        }
    }

    func readinessError(status: String) -> NSError {
        NSError(
            domain: "fun.wwcn.inputmethod.RimeAI.daemon-readiness",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Daemon 未通过本代协议握手：\(status)",
            ]
        )
    }

    func publishStatus(_ status: String) {
        let artifactID = modelArtifactID
        let artifacts = modelArtifacts
        let offlineLock = daemonOfflineLock
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .rimeAIDaemonStatusDidChange,
                object: nil,
                userInfo: [
                    "status": status,
                    "model_artifact_id": artifactID,
                    "model_artifacts": artifacts,
                    "offline_lock": offlineLock,
                ]
            )
        }
    }

    func encodeLine<T: Encodable>(_ value: T) -> Data? {
        guard var data = try? encoder.encode(value) else {
            return nil
        }
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

// MARK: - LM-003 传感层反馈（internal：controller 依赖注入用）

extension DaemonClient {
    /// daemon 是否通告了 `sentence-feedback`（反馈帧发送门控）。
    var supportsSentenceFeedback: Bool {
        capabilitiesLock.lock()
        defer { capabilitiesLock.unlock() }
        return serverCapabilities.contains("sentence-feedback")
    }

    /// 把用户对已展示建议的裁决发往 daemon 决策日志（fire-and-forget，
    /// 无响应；未通告 capability 的旧 daemon 静默跳过，不计数不重试）。
    func sendSentenceFeedback(requestID: String, outcome: String) {
        queue.async { [self] in
            guard supportsSentenceFeedback,
                  let payload = encodeLine(
                      DaemonSentenceFeedback(
                          requestID: requestID,
                          outcome: outcome
                      )
                  )
            else { return }
            transport.enqueueOutbound(data: payload, requestID: nil)
            transport.flushOutbound()
        }
    }
}
