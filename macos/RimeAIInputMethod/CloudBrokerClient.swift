import Foundation
import Network

extension Notification.Name {
    static let rimeAICloudBrokerStatusDidChange = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.cloud-broker-status-did-change"
    )
}

final class CloudBrokerClient: @unchecked Sendable {
    typealias Completion = @Sendable (CloudInferenceResponse?) -> Void

    static let shared = CloudBrokerClient()

    private struct PendingRequest {
        let completion: Completion
    }

    private struct OutboundFrame {
        let requestID: String?
        let data: Data
    }

    private struct HelloRequest: Encodable {
        let schemaVersion = 1
        let type = "hello"
        let clientID: String
        /// Advertises that this client can decode `generate` decisions.
        /// Brokers that do not know the capability simply ignore it, and
        /// this client keeps working with brokers that never send it.
        let capabilities = ["text-generation"]

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
            schemaVersion == 1
                && type == "hello"
                && status == "ok"
                && endpoint
                    == RimeAICloudConfiguration.endpoint.absoluteString
                && Set(RimeAICloudConfiguration.rankingModelIDs)
                    .isSubset(of: Set(models))
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

    private let queue = DispatchQueue(
        label: "fun.wwcn.rimeai.cloud-broker-client"
    )
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let socketPath: String
    private var connection: NWConnection?
    private var isTransportReady = false
    private var isReady = false
    private var receiveBuffer = Data()
    private var outbound: [OutboundFrame] = []
    private var pending: [String: PendingRequest] = [:]

    private init() {
        socketPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("RimeAI", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("rimeai-cloud.sock")
            .path
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
                  let payload = encodeInferenceLine(
                      request,
                      apiKey: apiKey
                  )
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            pending[request.requestID] = PendingRequest(
                completion: completion
            )
            outbound.append(
                OutboundFrame(requestID: request.requestID, data: payload)
            )
            ensureConnection()
            flushOutbound()
            queue.asyncAfter(
                deadline: .now() + .milliseconds(
                    request.deadlineMilliseconds + 25
                )
            ) {
                [weak self] in
                self?.expire(requestID: request.requestID)
            }
        }
    }

    func connect() {
        queue.async { [self] in ensureConnection() }
    }

    func cancel(requestID: String) {
        queue.async { [self] in
            guard pending.removeValue(forKey: requestID) != nil else {
                return
            }
            outbound.removeAll { $0.requestID == requestID }
            if isReady,
               let payload = encodeLine(CancelRequest(requestID: requestID))
            {
                outbound.append(OutboundFrame(requestID: nil, data: payload))
                flushOutbound()
            }
        }
    }

    func disconnect() {
        queue.async { [self] in
            tearDown(failPending: true, status: "已断开")
        }
    }

    private func ensureConnection() {
        guard connection == nil else {
            return
        }
        let next = NWConnection(to: .unix(path: socketPath), using: .tcp)
        connection = next
        publishStatus("正在连接")
        next.stateUpdateHandler = { [weak self, weak next] state in
            guard let self, let next else {
                return
            }
            self.queue.async {
                self.handle(state: state, connection: next)
            }
        }
        next.start(queue: queue)
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
            isTransportReady = true
            if let hello = encodeLine(
                HelloRequest(
                    clientID: Bundle.main.bundleIdentifier
                        ?? "fun.wwcn.inputmethod.RimeAI"
                )
            ) {
                sendHandshake(hello, on: connection)
            } else {
                tearDown(failPending: true, status: "握手编码失败")
                return
            }
            receiveNext(on: connection)
        case .failed, .cancelled:
            tearDown(failPending: true, status: "连接失败")
        default:
            break
        }
    }

    private func flushOutbound() {
        guard isTransportReady, isReady, let connection else {
            return
        }
        let frames = outbound
        outbound.removeAll(keepingCapacity: true)
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
                        guard self.connection === connection else {
                            return
                        }
                        self.tearDown(
                            failPending: true,
                            status: "发送失败"
                        )
                    }
                }
            )
        }
    }

    private func sendHandshake(
        _ data: Data,
        on connection: NWConnection
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
                    guard self.connection === connection else {
                        return
                    }
                    self.tearDown(
                        failPending: true,
                        status: "握手发送失败"
                    )
                }
            }
        )
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self, weak connection] data, _, complete, error in
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
                if complete || error != nil {
                    self.tearDown(
                        failPending: true,
                        status: "连接中断"
                    )
                    return
                }
                self.receiveNext(on: connection)
            }
        }
    }

    private func processCompleteLines() {
        while let index = receiveBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(receiveBuffer[..<index])
            receiveBuffer.removeSubrange(...index)
            if !line.isEmpty {
                process(line: line)
            }
        }
        if receiveBuffer.count > 1_048_576 {
            tearDown(failPending: true, status: "协议帧过大")
        }
    }

    private func process(line: Data) {
        if !isReady {
            guard let hello = try? decoder.decode(
                HelloResponse.self,
                from: line
            ), hello.isCompatible else {
                tearDown(failPending: true, status: "协议不兼容")
                return
            }
            isReady = true
            flushOutbound()
            publishStatus("就绪")
            return
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

    private func expire(requestID: String) {
        guard let request = pending.removeValue(forKey: requestID) else {
            return
        }
        outbound.removeAll { $0.requestID == requestID }
        if isReady,
           let payload = encodeLine(CancelRequest(requestID: requestID))
        {
            outbound.append(OutboundFrame(requestID: nil, data: payload))
            flushOutbound()
        }
        publishStatus("请求超时")
        DispatchQueue.main.async { request.completion(nil) }
    }

    private func finish(
        requestID: String,
        result: CloudInferenceResponse?
    ) {
        guard let request = pending.removeValue(forKey: requestID) else {
            return
        }
        DispatchQueue.main.async { request.completion(result) }
    }

    private func tearDown(failPending: Bool, status: String) {
        let old = connection
        connection = nil
        isTransportReady = false
        isReady = false
        receiveBuffer.removeAll(keepingCapacity: false)
        outbound.removeAll(keepingCapacity: false)
        old?.stateUpdateHandler = nil
        old?.cancel()
        publishStatus(status)
        if failPending {
            let values = pending.values
            pending.removeAll(keepingCapacity: false)
            for value in values {
                DispatchQueue.main.async { value.completion(nil) }
            }
        }
    }

    private func publishStatus(_ status: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .rimeAICloudBrokerStatusDidChange,
                object: nil,
                userInfo: ["status": status]
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

    private func encodeInferenceLine(
        _ request: CloudInferenceRequest,
        apiKey: String
    ) -> Data? {
        guard let encoded = try? encoder.encode(request),
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
