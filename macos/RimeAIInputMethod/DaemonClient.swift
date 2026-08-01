import Foundation
import Network

extension Notification.Name {
    static let rimeAIDaemonStatusDidChange = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.daemon-status-did-change"
    )
}

final class DaemonClient: @unchecked Sendable {
    typealias Completion = @Sendable (SemanticInferenceResult?) -> Void

    static let shared = DaemonClient()

    private struct PendingRequest {
        let completion: Completion
    }

    private let queue = DispatchQueue(label: "fun.wwcn.rimeai.daemon-client")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let socketPath: String
    private var connection: NWConnection?
    private var isReady = false
    private var receiveBuffer = Data()
    private var outbound: [Data] = []
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
            outbound.append(payload)
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

    func cancel(requestID: String) {
        queue.async { [self] in
            guard pending.removeValue(forKey: requestID) != nil else {
                return
            }
            if let payload = encodeLine(
                DaemonCancelRequest(requestID: requestID)
            ) {
                outbound.append(payload)
                ensureConnection()
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

    private func ensureConnection() {
        guard connection == nil else {
            return
        }
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
                self.handle(state: state, connection: connection)
            }
        }
        connection.start(queue: queue)
    }

    private func handle(
        state: NWConnection.State,
        connection: NWConnection
    ) {
        guard self.connection === connection else {
            return
        }
        switch state {
        case .ready:
            isReady = true
            if let hello = encodeLine(
                DaemonHelloRequest(
                    clientID: Bundle.main.bundleIdentifier
                        ?? "fun.wwcn.inputmethod.RimeAI"
                )
            ) {
                outbound.insert(hello, at: 0)
            }
            flushOutbound()
            receiveNext(on: connection)
        case .failed, .cancelled:
            tearDownConnection(
                failPending: true,
                recordFailure: true,
                status: "连接失败"
            )
        default:
            break
        }
    }

    private func flushOutbound() {
        guard isReady, let connection else {
            return
        }
        let frames = outbound
        outbound.removeAll(keepingCapacity: true)
        for frame in frames {
            connection.send(
                content: frame,
                completion: .contentProcessed { [weak self] error in
                    guard error != nil else {
                        return
                    }
                    self?.queue.async {
                        self?.tearDownConnection(
                            failPending: true,
                            recordFailure: true,
                            status: "发送失败"
                        )
                    }
                }
            )
        }
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else {
                return
            }
            self.queue.async {
                guard self.connection === connection else {
                    return
                }
                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    self.processCompleteLines()
                }
                if error != nil || isComplete {
                    self.tearDownConnection(
                        failPending: true,
                        recordFailure: true,
                        status: "连接中断"
                    )
                    return
                }
                self.receiveNext(on: connection)
            }
        }
    }

    private func processCompleteLines() {
        let newline = UInt8(ascii: "\n")
        while let index = receiveBuffer.firstIndex(of: newline) {
            let line = Data(receiveBuffer[..<index])
            receiveBuffer.removeSubrange(...index)
            guard !line.isEmpty else {
                continue
            }
            process(line: line)
        }
        if receiveBuffer.count > 1_048_576 {
            tearDownConnection(
                failPending: true,
                recordFailure: true,
                status: "协议帧过大"
            )
        }
    }

    private func process(line: Data) {
        if let hello = try? decoder.decode(
            DaemonHelloResponse.self,
            from: line
        ) {
            if !hello.isCompatible {
                tearDownConnection(
                    failPending: true,
                    recordFailure: true,
                    status: "协议不兼容"
                )
                return
            }
            modelArtifactID = hello.modelArtifactID
            modelArtifacts = hello.modelArtifacts ?? []
            daemonOfflineLock = hello.offlineLock == true
            publishStatus("就绪")
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
        if let payload = encodeLine(
            DaemonCancelRequest(requestID: requestID)
        ) {
            outbound.append(payload)
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
        status: String
    ) {
        let oldConnection = connection
        connection = nil
        isReady = false
        receiveBuffer.removeAll(keepingCapacity: false)
        outbound.removeAll(keepingCapacity: false)
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
