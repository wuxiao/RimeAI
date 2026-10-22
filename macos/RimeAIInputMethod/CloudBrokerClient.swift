import Foundation

extension Notification.Name {
    static let rimeAICloudBrokerStatusDidChange = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.cloud-broker-status-did-change"
    )
}

/// 续写请求的退役登记：本地已取消/超时的 continuation，broker 仍可能
/// 送达结果帧。退役 ID 用于把这类迟到帧静默丢弃，而不是落入推断
/// 解码器触发整连接 tearDown。有界 FIFO，命中即消耗（一请求一帧）。
struct ContinuationRetirementLog {
    static let capacity = 32

    private(set) var ids: [String] = []

    mutating func retire(_ requestID: String) {
        ids.append(requestID)
        while ids.count > Self.capacity {
            ids.removeFirst()
        }
    }

    /// 命中退役 ID 时返回 true 并消耗该条目；未命中返回 false。
    mutating func consume(_ requestID: String) -> Bool {
        guard let index = ids.firstIndex(of: requestID) else {
            return false
        }
        ids.remove(at: index)
        return true
    }

    mutating func reset() {
        ids.removeAll(keepingCapacity: false)
    }
}

/// 云端代理客户端：请求/响应配对与协议握手校验。
/// 连接管线（分帧、重连、串行发送、超时、代际计数）由
/// `NDJSONUDSTransport` 提供。
final class CloudBrokerClient: @unchecked Sendable {
    typealias Completion = @Sendable (CloudInferenceResponse?) -> Void
    typealias ContinuationCompletion =
        @Sendable (CloudContinuationResponse?) -> Void

    static let shared = CloudBrokerClient()

    private struct PendingRequest {
        let completion: Completion
    }

    private struct PendingContinuation {
        let completion: ContinuationCompletion
    }

    private struct HelloRequest: Encodable {
        let schemaVersion = 1
        let type = "hello"
        let clientID: String
        /// Advertises that this client can decode `generate` decisions.
        /// Brokers that do not know the capability simply ignore it, and
        /// this client keeps working with brokers that never send it.
        /// `continuation-generation` advertises the post-commit
        /// continuation round-trip (request type `continuation`).
        let capabilities = ["text-generation", "continuation-generation"]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case type
            case clientID = "client_id"
            case capabilities
        }
    }

    private struct HelloResponse: Decodable {
        let schemaVersion: Int
        let type: String
        let status: String
        let endpoint: String
        let models: [String]
        let capabilities: [String]

        var isCompatible: Bool {
            // 模型集不再要求包含客户端已知的全部模型：旧 broker 只
            // 报 glm-5.3 时握手仍应通过，模型选择交给
            // `resolvedModelID(for:)` 协商回落。
            schemaVersion == 1
                && type == "hello"
                && status == "ok"
                && endpoint
                    == RimeAICloudConfiguration.endpoint.absoluteString
                && !models.isEmpty
                && Set([
                    "candidate-id-only",
                    "cancel",
                    "latest-request-wins",
                    "history-generation",
                ]).isSubset(of: Set(capabilities))
        }

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case type
            case status
            case endpoint
            case models
            case capabilities
        }
    }

    private struct CancelRequest: Encodable {
        let schemaVersion = 1
        let type = "cancel"
        let requestID: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case type
            case requestID = "request_id"
        }
    }

    /// LM-003 传感层反馈帧（与 daemon 侧 DaemonSentenceFeedback 同形）。
    private struct SentenceFeedbackFrame: Encodable {
        let schemaVersion = 1
        let type = "sentence_feedback"
        let requestID: String
        let outcome: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case type
            case requestID = "request_id"
            case outcome
        }
    }

    /// 响应信封：仅取 request_id 用于推断/续写两条 pending 表的分流。
    private struct ResponseEnvelope: Decodable {
        let requestID: String

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
        }
    }

    private var queue: DispatchQueue { transport.queue }
    private let transport: NDJSONUDSTransport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var isReady = false
    /// broker hello 通告的 capability 快照（LM-003 云端反馈帧门控）。
    private var serverCapabilities: Set<String> = []
    /// Models the broker advertised in its last successful hello. Empty
    /// before the first handshake; model negotiation then stays a no-op.
    private var availableModels: Set<String> = []
    private var pending: [String: PendingRequest] = [:]
    private var pendingContinuations: [String: PendingContinuation] = [:]
    /// Tombstones for continuation requests we cancelled or expired
    /// locally: the broker may still deliver their result frame, and such
    /// a late frame must be dropped quietly instead of falling into the
    /// inference decoder and tearing down the whole connection. Cleared
    /// on tearDown.
    private var retiredContinuations = ContinuationRetirementLog()

    private init() {
        let socketPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("RimeAI", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("rimeai-cloud.sock")
            .path
        transport = NDJSONUDSTransport(
            configuration: NDJSONUDSTransport.Configuration(
                socketPath: socketPath,
                queueLabel: "fun.wwcn.rimeai.cloud-broker-client"
            )
        )
        transport.setEventHandler { [weak self] event in
            self?.handle(event)
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func infer(
        _ request: CloudInferenceRequest,
        apiKey: String,
        completion: @escaping Completion
    ) {
        queue.async { [self] in
            guard request.isValid,
                  !apiKey.isEmpty,
                  apiKey.utf8.count <= 512,
                  let payload = encodeLine(request, apiKey: apiKey)
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            pending[request.requestID] = PendingRequest(
                completion: completion
            )
            transport.enqueueOutbound(
                data: payload,
                requestID: request.requestID
            )
            ensureConnection()
            transport.flushOutbound()
            transport.scheduleTimeout(
                afterMilliseconds: request.deadlineMilliseconds + 25
            ) {
                [weak self] in
                self?.expire(requestID: request.requestID)
            }
        }
    }

    func connect() {
        queue.async { [self] in ensureConnection() }
    }

    /// 上屏后续写请求：与 infer 同一条连接，按 request_id 解多路复用。
    /// 超时口径与协调器守卫一致：deadline + 50ms 后以 nil 回调。
    func continuation(
        _ request: CloudContinuationRequest,
        apiKey: String,
        completion: @escaping ContinuationCompletion
    ) {
        queue.async { [self] in
            guard ContinuationTextPolicy.isValid(request: request),
                  !apiKey.isEmpty,
                  apiKey.utf8.count <= 512,
                  let payload = encodeLine(request, apiKey: apiKey)
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            pendingContinuations[request.requestID] = PendingContinuation(
                completion: completion
            )
            transport.enqueueOutbound(
                data: payload,
                requestID: request.requestID
            )
            ensureConnection()
            transport.flushOutbound()
            transport.scheduleTimeout(
                afterMilliseconds: request.deadlineMilliseconds + 50
            ) {
                [weak self] in
                self?.expireContinuation(requestID: request.requestID)
            }
        }
    }

    func cancelContinuation(requestID: String) {
        queue.async { [self] in
            guard pendingContinuations.removeValue(forKey: requestID) != nil
            else {
                return
            }
            retireContinuationID(requestID)
            sendWireCancel(requestID: requestID)
        }
    }

    /// Model negotiation for mixed-version deployments: when the broker
    /// (e.g. an un-upgraded one) does not offer the preferred model, fall
    /// back to the first client-known model it does offer, so the cloud
    /// path keeps working instead of failing every request with
    /// "model is not allowed". Unconnected or already-compatible
    /// selections return the preference unchanged.
    func resolvedModelID(for preferredModelID: String) -> String {
        queue.sync {
            guard !availableModels.isEmpty,
                  !availableModels.contains(preferredModelID)
            else {
                return preferredModelID
            }
            let fallback = RimeAICloudConfiguration.rankingModelIDs
                .first { availableModels.contains($0) }
            return fallback ?? preferredModelID
        }
    }

    func cancel(requestID: String) {
        queue.async { [self] in
            guard pending.removeValue(forKey: requestID) != nil else {
                return
            }
            sendWireCancel(requestID: requestID)
        }
    }

    func disconnect() {
        queue.async { [self] in
            tearDown(failPending: true, status: "已断开")
        }
    }
}

// MARK: - 传输层事件与请求收尾

private extension CloudBrokerClient {
    func handle(_ event: NDJSONUDSTransport.Event) {
        switch event {
        case .connectionReady:
            if let hello = encodeLine(
                HelloRequest(
                    clientID: Bundle.main.bundleIdentifier
                        ?? "fun.wwcn.inputmethod.RimeAI"
                )
            ) {
                transport.sendImmediate(hello)
            } else {
                tearDown(failPending: true, status: "握手编码失败")
            }
        case let .lineReceived(_, line):
            process(line: line)
        case let .connectionClosed(_, reason):
            tearDown(
                failPending: true,
                status: reason.localizedStatusDescription
            )
        }
    }

    /// 撤回本地队列中该请求的帧，并按原语义补发线上 cancel：只有
    /// 已真正发出的请求才需要服务端取消（推断与续写两条收尾路径
    /// 共用）。
    func sendWireCancel(requestID: String) {
        transport.removeOutboundFrames(requestID: requestID)
        guard transport.canSendApplicationFrames,
              let payload = encodeLine(CancelRequest(requestID: requestID))
        else {
            return
        }
        transport.enqueueOutbound(data: payload, requestID: nil)
        transport.flushOutbound()
    }

    func ensureConnection() {
        guard !transport.hasActiveConnection else {
            return
        }
        transport.open()
        publishStatus("正在连接")
    }

    func process(line: Data) {
        if !isReady {
            guard let hello = try? decoder.decode(
                HelloResponse.self,
                from: line
            ), hello.isCompatible else {
                tearDown(failPending: true, status: "协议不兼容")
                return
            }
            isReady = true
            availableModels = Set(hello.models)
            serverCapabilities = Set(hello.capabilities)
            transport.markProtocolReady()
            publishStatus("就绪")
            return
        }
        // 续写响应无法按 CloudInferenceResponse 解码（缺决策字段），
        // 先解信封取 request_id 分流，避免续写帧误触推断路径的
        // tearDown。
        if let envelope = try? decoder.decode(
            ResponseEnvelope.self,
            from: line
        ) {
            if pendingContinuations[envelope.requestID] != nil {
                guard let result = try? decoder.decode(
                    CloudContinuationResponse.self,
                    from: line
                ) else {
                    tearDown(failPending: true, status: "响应格式错误")
                    return
                }
                publishStatus("就绪")
                finishContinuation(
                    requestID: envelope.requestID,
                    result: result
                )
                return
            }
            if retiredContinuations.consume(envelope.requestID) {
                // Late result for a continuation we already cancelled or
                // expired: drop it quietly.
                return
            }
        }
        guard let result = try? decoder.decode(
            CloudInferenceResponse.self,
            from: line
        ) else {
            tearDown(failPending: true, status: "响应格式错误")
            return
        }
        publishStatus("就绪")
        finish(requestID: result.requestID, result: result)
    }

    func expire(requestID: String) {
        guard let request = pending.removeValue(forKey: requestID) else {
            return
        }
        sendWireCancel(requestID: requestID)
        publishStatus("请求超时")
        DispatchQueue.main.async { request.completion(nil) }
    }

    func expireContinuation(requestID: String) {
        guard let request = pendingContinuations.removeValue(
            forKey: requestID
        ) else {
            return
        }
        retireContinuationID(requestID)
        sendWireCancel(requestID: requestID)
        DispatchQueue.main.async { request.completion(nil) }
    }

    private func retireContinuationID(_ requestID: String) {
        retiredContinuations.retire(requestID)
    }

    func finish(
        requestID: String,
        result: CloudInferenceResponse?
    ) {
        guard let request = pending.removeValue(forKey: requestID) else {
            return
        }
        DispatchQueue.main.async { request.completion(result) }
    }

    func finishContinuation(
        requestID: String,
        result: CloudContinuationResponse?
    ) {
        guard let request = pendingContinuations.removeValue(
            forKey: requestID
        ) else {
            return
        }
        DispatchQueue.main.async { request.completion(result) }
    }

    func tearDown(failPending: Bool, status: String) {
        transport.close()
        isReady = false
        availableModels = []
        retiredContinuations.reset()
        publishStatus(status)
        if failPending {
            let values = pending.values
            pending.removeAll(keepingCapacity: false)
            for value in values {
                DispatchQueue.main.async { value.completion(nil) }
            }
            let continuations = pendingContinuations.values
            pendingContinuations.removeAll(keepingCapacity: false)
            for value in continuations {
                DispatchQueue.main.async { value.completion(nil) }
            }
        }
    }

    func publishStatus(_ status: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .rimeAICloudBrokerStatusDidChange,
                object: nil,
                userInfo: ["status": status]
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

// MARK: - 请求编码（internal，供单测直接验证线格式）

extension CloudBrokerClient {
    /// 请求体 + api_key 的 NDJSON 行：推断与续写请求共用。
    func encodeLine<T: Encodable>(
        _ value: T,
        apiKey: String
    ) -> Data? {
        guard let encoded = try? encoder.encode(value),
              var object = try? JSONSerialization.jsonObject(
                  with: encoded
              ) as? [String: Any]
        else {
            return nil
        }
        object["api_key"] = apiKey
        guard var data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else {
            return nil
        }
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

// MARK: - LM-003 传感层反馈（internal：controller 依赖注入用）

extension CloudBrokerClient {
    /// 云端建议的裁决帧（fire-and-forget，无响应）：broker 通告
    /// `sentence-feedback` capability 时才发送；旧 broker 静默跳过
    /// （不计数不重试，传感层永不反向影响输入路径）。
    func sendSentenceFeedback(requestID: String, outcome: String) {
        guard serverCapabilities.contains("sentence-feedback"),
              transport.canSendApplicationFrames,
              let payload = encodeLine(
                  SentenceFeedbackFrame(
                      requestID: requestID,
                      outcome: outcome
                  )
              )
        else { return }
        transport.enqueueOutbound(data: payload, requestID: nil)
        transport.flushOutbound()
    }
}
