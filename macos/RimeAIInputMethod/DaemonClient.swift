import Foundation
import Network

extension Notification.Name {
    static let rimeAIDaemonStatusDidChange = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.daemon-status-did-change"
    )
}

final class DaemonClient: @unchecked Sendable {
    typealias Completion = @Sendable (SemanticInferenceResult?) -> Void
    typealias ReadyCompletion = @MainActor @Sendable (
        Result<Void, Error>
    ) -> Void

    static let shared = DaemonClient()

    private struct PendingRequest {
        let completion: Completion
    }

    private let queue = DispatchQueue(label: "fun.wwcn.rimeai.daemon-client")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let socketPath: String
    private var connection: NWConnection?
    private var connectionState = DaemonClientConnectionState()
    private var readyWaitState = DaemonClientReadyWaitState()
    private var readyCompletion: ReadyCompletion?
    private var connectionTimeout: DispatchWorkItem?
    private var helloTimeout: DispatchWorkItem?
    private var receiveBuffer = Data()
    private var outbound = DaemonClientOutboundQueue()
    private var pending: [String: PendingRequest] = [:]
    private var circuitBreaker = FailureCircuitBreaker()
    private var modelArtifactID = "尚未连接"
    private var modelArtifacts: [DaemonModelArtifact] = []
    private var daemonOfflineLock = false

    private init() {
        socketPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("RimeAI", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("rimeai.sock")
            .path
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func infer(
        _ request: SemanticInferenceRequest,
        completion: @escaping Completion
    ) {
        queue.async { [self] in
            guard circuitBreaker.allowsRequest() else {
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
            outbound.enqueueApplication(
                requestID: request.requestID,
                data: payload
            )
            ensureConnection()
            flushOutbound()
            queue.asyncAfter(
                deadline: .now()
                    + .milliseconds(request.deadlineMilliseconds + 50)
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
            let shouldSendCancel = outbound.cancelRequest(
                requestID: requestID,
                protocolReady: connectionState.canSendApplicationFrames
            )
            if shouldSendCancel,
               let payload = encodeLine(
                DaemonCancelRequest(requestID: requestID)
            ) {
                outbound.enqueueControl(data: payload)
                flushOutbound()
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

    @discardableResult
    private func ensureConnection() -> UInt64 {
        guard connection == nil else {
            return connectionState.generation
        }
        let generation = connectionState.beginConnection()
        modelArtifactID = "尚未连接"
        modelArtifacts = []
        daemonOfflineLock = false
        let connection = NWConnection(
            to: .unix(path: socketPath),
            using: .tcp
        )
        self.connection = connection
        publishStatus("正在连接")
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else {
                return
            }
            self.queue.async {
                self.handle(
                    state: state,
                    connection: connection,
                    generation: generation
                )
            }
        }
        armConnectionTimeout(
            on: connection,
            generation: generation
        )
        connection.start(queue: queue)
        return generation
    }

    private func handle(
        state: NWConnection.State,
        connection: NWConnection,
        generation: UInt64
    ) {
        guard self.connection === connection,
              connectionState.generation == generation
        else {
            return
        }
        switch state {
        case .ready:
            cancelConnectionTimeout()
            guard connectionState.transportBecameReady(
                generation: generation
            ), let hello = encodeLine(
                DaemonHelloRequest(
                    clientID: Bundle.main.bundleIdentifier
                        ?? "fun.wwcn.inputmethod.RimeAI"
                )
            ) else {
                tearDownConnection(
                    failPending: true,
                    recordFailure: true,
                    status: "握手编码失败",
                    generation: generation
                )
                return
            }
            sendHandshake(
                hello,
                on: connection,
                generation: generation
            )
            armHelloTimeout(
                on: connection,
                generation: generation
            )
            receiveNext(on: connection, generation: generation)
        case .failed, .cancelled:
            tearDownConnection(
                failPending: true,
                recordFailure: true,
                status: "连接失败",
                generation: generation
            )
        default:
            break
        }
    }

    private func flushOutbound() {
        guard connectionState.canSendApplicationFrames,
              let connection
        else {
            return
        }
        let generation = connectionState.generation
        let frames = outbound.drain()
        for frame in frames {
            connection.send(
                content: frame.data,
                completion: .contentProcessed {
                    [weak self, weak connection] error in
                    guard error != nil,
                          let self,
                          let connection
                    else {
                        return
                    }
                    self.queue.async {
                        guard self.connection === connection,
                              self.connectionState.generation == generation
                        else {
                            return
                        }
                        self.tearDownConnection(
                            failPending: true,
                            recordFailure: true,
                            status: "发送失败",
                            generation: generation
                        )
                    }
                }
            )
        }
    }

    private func sendHandshake(
        _ data: Data,
        on connection: NWConnection,
        generation: UInt64
    ) {
        connection.send(
            content: data,
            completion: .contentProcessed {
                [weak self, weak connection] error in
                guard error != nil,
                      let self,
                      let connection
                else {
                    return
                }
                self.queue.async {
                    guard self.connection === connection,
                          self.connectionState.generation == generation
                    else {
                        return
                    }
                    self.tearDownConnection(
                        failPending: true,
                        recordFailure: true,
                        status: "握手发送失败",
                        generation: generation
                    )
                }
            }
        )
    }

    private func armHelloTimeout(
        on connection: NWConnection,
        generation: UInt64
    ) {
        cancelHelloTimeout()
        let work = DispatchWorkItem { [weak self, weak connection] in
            guard let self,
                  let connection,
                  self.connection === connection,
                  self.connectionState.shouldExpireHello(
                      generation: generation
                  )
            else {
                return
            }
            self.tearDownConnection(
                failPending: true,
                recordFailure: true,
                status: "握手超时",
                generation: generation
            )
        }
        helloTimeout = work
        queue.asyncAfter(deadline: .now() + .seconds(3), execute: work)
    }

    private func armConnectionTimeout(
        on connection: NWConnection,
        generation: UInt64
    ) {
        cancelConnectionTimeout()
        let work = DispatchWorkItem { [weak self, weak connection] in
            guard let self,
                  let connection,
                  self.connection === connection,
                  self.connectionState.shouldExpireConnection(
                      generation: generation
                  )
            else {
                return
            }
            self.tearDownConnection(
                failPending: true,
                recordFailure: true,
                status: "连接建立超时",
                generation: generation
            )
        }
        connectionTimeout = work
        queue.asyncAfter(deadline: .now() + .seconds(3), execute: work)
    }

    private func cancelConnectionTimeout() {
        connectionTimeout?.cancel()
        connectionTimeout = nil
    }

    private func cancelHelloTimeout() {
        helloTimeout?.cancel()
        helloTimeout = nil
    }

    private func receiveNext(
        on connection: NWConnection,
        generation: UInt64
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else {
                return
            }
            self.queue.async {
                guard self.connection === connection,
                      self.connectionState.generation == generation
                else {
                    return
                }
                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    self.processCompleteLines(generation: generation)
                }
                // Parsing can synchronously invalidate this generation. Do not
                // let an EOF/error delivered in the same receive callback tear
                // it down (and fail its waiters) a second time.
                guard self.connection === connection,
                      self.connectionState.generation == generation,
                      self.connectionState.phase != .disconnected
                else {
                    return
                }
                if error != nil || isComplete {
                    self.tearDownConnection(
                        failPending: true,
                        recordFailure: true,
                        status: "连接中断",
                        generation: generation
                    )
                    return
                }
                self.receiveNext(
                    on: connection,
                    generation: generation
                )
            }
        }
    }

    private func processCompleteLines(generation: UInt64) {
        let newline = UInt8(ascii: "\n")
        while let index = receiveBuffer.firstIndex(of: newline) {
            let line = Data(receiveBuffer[..<index])
            receiveBuffer.removeSubrange(...index)
            guard !line.isEmpty else {
                continue
            }
            process(line: line, generation: generation)
        }
        if receiveBuffer.count > 1_048_576 {
            tearDownConnection(
                failPending: true,
                recordFailure: true,
                status: "协议帧过大",
                generation: generation
            )
        }
    }

    private func process(line: Data, generation: UInt64) {
        if connectionState.phase == .awaitingHello {
            guard let hello = try? decoder.decode(
                DaemonHelloResponse.self,
                from: line
            ), connectionState.acceptHello(
                hello,
                generation: generation
            ) else {
                tearDownConnection(
                    failPending: true,
                    recordFailure: true,
                    status: "协议不兼容",
                    generation: generation
                )
                return
            }
            cancelHelloTimeout()
            modelArtifactID = hello.modelArtifactID
            modelArtifacts = hello.modelArtifacts ?? []
            daemonOfflineLock = true
            flushOutbound()
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
                status: "握手未完成",
                generation: generation
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
                status: "响应格式错误",
                generation: generation
            )
            return
        }
        if result.type == "cancelled" {
            return
        }
        guard result.schemaVersion == 1,
              result.type == "result",
              let requestID = result.requestID
        else {
            tearDownConnection(
                failPending: true,
                recordFailure: true,
                status: "响应协议错误",
                generation: generation
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
            circuitBreaker.recordFailure()
            publishStatus("服务端熔断")
        }
        finish(requestID: requestID, result: result)
    }

    private func expire(requestID: String) {
        guard let request = pending.removeValue(forKey: requestID) else {
            return
        }
        circuitBreaker.recordFailure()
        publishStatus(
            circuitBreaker.allowsRequest()
                ? "请求超时"
                : "熔断冷却中"
        )
        let shouldSendCancel = outbound.cancelRequest(
            requestID: requestID,
            protocolReady: connectionState.canSendApplicationFrames
        )
        if shouldSendCancel,
           let payload = encodeLine(
               DaemonCancelRequest(requestID: requestID)
           )
        {
            outbound.enqueueControl(data: payload)
            flushOutbound()
        }
        DispatchQueue.main.async {
            request.completion(nil)
        }
    }

    private func finish(
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

    private func tearDownConnection(
        failPending: Bool,
        recordFailure: Bool,
        status: String,
        generation: UInt64? = nil
    ) {
        let invalidatedGeneration = generation
            ?? connectionState.generation
        if let generation {
            guard connectionState.invalidate(generation: generation) else {
                return
            }
        } else {
            _ = connectionState.invalidate(
                generation: connectionState.generation
            )
        }
        cancelConnectionTimeout()
        cancelHelloTimeout()
        let oldConnection = connection
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: false)
        outbound.removeAll()
        modelArtifactID = "尚未连接"
        modelArtifacts = []
        daemonOfflineLock = false
        oldConnection?.stateUpdateHandler = nil
        oldConnection?.cancel()
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

    private func completeReadyWaiter(
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

    private func readinessError(status: String) -> NSError {
        NSError(
            domain: "fun.wwcn.inputmethod.RimeAI.daemon-readiness",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Daemon 未通过本代协议握手：\(status)",
            ]
        )
    }

    private func publishStatus(_ status: String) {
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

    private func encodeLine<T: Encodable>(_ value: T) -> Data? {
        guard var data = try? encoder.encode(value) else {
            return nil
        }
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
