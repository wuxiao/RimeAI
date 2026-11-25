import Foundation
import Network
import XCTest
@testable import RimeAIInputMethod

/// 续写请求的线格式与响应解码：续写帧与推断帧共用一条 NDJSON
/// 连接，线格式偏差会让 broker 拒收或让客户端 tearDown。
final class CloudBrokerClientContinuationTests: XCTestCase {
    private func makeRequest() -> CloudContinuationRequest {
        CloudContinuationRequest(
            requestID: "req-continuation-1",
            clientSessionID: "session-1",
            bundleIdentifier: "com.example.TextEdit",
            modelID: "glm-5.3-flash",
            recentContext: "床前明月光",
            historySnippets: [
                CloudHistorySnippet(
                    id: "h1",
                    text: "举头望明月",
                    bundleIdentifier: "com.example.TextEdit",
                    committedAtMilliseconds: 1_760_000_000_000,
                    score: 0.9
                ),
            ],
            historyGeneration: 42,
            deadlineMilliseconds: 2_000
        )
    }

    func testContinuationLineEncodingIncludesApiKeyAndType() throws {
        let line = try XCTUnwrap(
            CloudBrokerClient.shared.encodeLine(
                makeRequest(),
                apiKey: "test-api-key"
            )
        )
        XCTAssertEqual(line.last, UInt8(ascii: "\n"))

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: line) as? [String: Any]
        )
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["type"] as? String, "continuation")
        XCTAssertEqual(object["request_id"] as? String, "req-continuation-1")
        XCTAssertEqual(object["client_session_id"] as? String, "session-1")
        XCTAssertEqual(object["bundle_id"] as? String, "com.example.TextEdit")
        XCTAssertEqual(object["model_id"] as? String, "glm-5.3-flash")
        XCTAssertEqual(object["recent_context"] as? String, "床前明月光")
        XCTAssertEqual(object["history_generation"] as? Int, 42)
        XCTAssertEqual(object["deadline_ms"] as? Int, 2_000)
        XCTAssertEqual(object["api_key"] as? String, "test-api-key")
        let snippets = try XCTUnwrap(
            object["history_snippets"] as? [[String: Any]]
        )
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets.first?["text"] as? String, "举头望明月")
    }

    func testContinuationResponseDecoding() throws {
        let json = """
            {
              "status": "ok",
              "request_id": "req-continuation-1",
              "decision": "generate",
              "generated_text": "疑是地上霜",
              "confidence": 0.9,
              "model_id": "glm-5.3-flash",
              "elapsed_ms": 123.0
            }
            """
        let response = try JSONDecoder().decode(
            CloudContinuationResponse.self,
            from: json.data(using: .utf8)!
        )
        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.requestID, "req-continuation-1")
        XCTAssertEqual(response.decision, "generate")
        XCTAssertEqual(response.generatedText, "疑是地上霜")
        XCTAssertEqual(response.confidence, 0.9)
        XCTAssertEqual(response.modelID, "glm-5.3-flash")
        XCTAssertEqual(response.elapsedMilliseconds, 123.0)

        // abstain 形态：只带 status/reason，其余缺省也必须能解。
        let abstain = try JSONDecoder().decode(
            CloudContinuationResponse.self,
            from: """
                {"status": "ok", "request_id": "r2", "decision": "abstain",
                 "reason": "low_confidence"}
                """.data(using: .utf8)!
        )
        XCTAssertEqual(abstain.decision, "abstain")
        XCTAssertEqual(abstain.reason, "low_confidence")
        XCTAssertNil(abstain.generatedText)
    }

    /// 迟到帧墓碑：取消/超时后 broker 仍送达的结果必须被静默丢弃
    /// （命中即消耗），而不是落入推断解码器拆除整条连接。
    func testRetirementLogConsumesOnceAndStaysBounded() {
        var log = ContinuationRetirementLog()
        XCTAssertFalse(log.consume("never-seen"))

        log.retire("req-a")
        log.retire("req-b")
        XCTAssertTrue(log.consume("req-a"))
        // 一请求一帧：消耗后同 ID 的重复帧不再命中。
        XCTAssertFalse(log.consume("req-a"))
        XCTAssertTrue(log.consume("req-b"))

        for i in 0 ..< (ContinuationRetirementLog.capacity + 8) {
            log.retire("req-\(i)")
        }
        XCTAssertEqual(log.ids.count, ContinuationRetirementLog.capacity)
        // FIFO：最旧的条目先被淘汰。
        XCTAssertFalse(log.consume("req-0"))
        XCTAssertTrue(log.consume("req-\(ContinuationRetirementLog.capacity + 7)"))

        log.retire("req-c")
        log.reset()
        XCTAssertFalse(log.consume("req-c"))
    }

    /// 回归测试：云端建议展示后，主线程触发 `sendSentenceFeedback`
    /// （如按 1/2/3 拒绝云端改选主候选、Tab 采纳或退格过期）必须切回
    /// 传输串行队列再访问 `transport.canSendApplicationFrames` /
    /// `enqueueOutbound` / `flushOutbound`，不得在主线程触碰
    /// `dispatchPrecondition(.onQueue(queue))` 导致输入法进程 SIGTRAP。
    func testSendSentenceFeedbackFromMainThreadHopsToTransportQueueAndDeliversFrame() throws {
        XCTAssertTrue(Thread.isMainThread)
        let socketPath = makeTemporarySocketPath()
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = try FakeCloudBrokerUDSServer(
            socketPath: socketPath,
            capabilities: [
                "candidate-id-only",
                "cancel",
                "latest-request-wins",
                "history-generation",
                "sentence-feedback",
            ]
        )
        server.start()
        defer { server.stop() }

        let client = CloudBrokerClient(socketPath: socketPath)
        defer { client.disconnect() }
        client.connect()

        XCTAssertTrue(
            waitUntil(timeout: 3.0) {
                client.resolvedModelID(for: "__probe_unknown_model__")
                    == "glm-5.3-flash"
            },
            "CloudBrokerClient 未在预期时间内完成 hello 握手"
        )

        client.sendSentenceFeedback(requestID: "req-cloud-1", outcome: "rejected")

        XCTAssertTrue(
            waitUntil(timeout: 3.0) {
                server.receivedLines.contains { line in
                    line.contains("\"type\":\"sentence_feedback\"")
                        && line.contains("\"request_id\":\"req-cloud-1\"")
                        && line.contains("\"outcome\":\"rejected\"")
                }
            },
            "假 broker 未收到 sentence_feedback 帧，已收行：\(server.receivedLines)"
        )
    }

    /// 断开连接后能力集必须清空，再次从主线程调用 `sendSentenceFeedback`
    /// 保持静默 no-op，不崩也不重发。
    func testSendSentenceFeedbackAfterDisconnectIsSafeNoOp() throws {
        XCTAssertTrue(Thread.isMainThread)
        let socketPath = makeTemporarySocketPath()
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = try FakeCloudBrokerUDSServer(
            socketPath: socketPath,
            capabilities: [
                "candidate-id-only",
                "cancel",
                "latest-request-wins",
                "history-generation",
                "sentence-feedback",
            ]
        )
        server.start()
        defer { server.stop() }

        let client = CloudBrokerClient(socketPath: socketPath)
        client.connect()
        XCTAssertTrue(
            waitUntil(timeout: 3.0) {
                client.resolvedModelID(for: "__probe_unknown_model__")
                    == "glm-5.3-flash"
            }
        )

        client.disconnect()
        XCTAssertTrue(
            waitUntil(timeout: 3.0) {
                client.resolvedModelID(for: "__probe_unknown_model__")
                    == "__probe_unknown_model__"
            }
        )

        client.sendSentenceFeedback(requestID: "req-after-close", outcome: "expired")
        // 同步排队一次 queue.sync（经 resolvedModelID）确保异步块已跑完。
        _ = client.resolvedModelID(for: "__sync__")
        XCTAssertFalse(
            server.receivedLines.contains { $0.contains("req-after-close") }
        )
    }

    private func makeTemporarySocketPath() -> String {
        let shortID = UUID().uuidString.prefix(8)
        return "/tmp/rimeai-cloud-test-\(shortID).sock"
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

/// 测试用极简 UDS 假 broker：收到客户端 hello 行后立刻回复兼容的
/// hello 响应，并记录之后收到的所有 NDJSON 行。
private final class FakeCloudBrokerUDSServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fun.wwcn.rimeai.test.fake-cloud-broker")
    private let listener: NWListener
    private let helloResponseData: Data
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var lineBuffer = Data()
    private var lines: [String] = []
    private var helloReplied = false

    init(socketPath: String, capabilities: [String]) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        let responseObject: [String: Any] = [
            "schema_version": 1,
            "type": "hello",
            "status": "ok",
            "endpoint": RimeAICloudConfiguration.endpoint.absoluteString,
            "models": ["glm-5.3-flash"],
            "capabilities": capabilities,
        ]
        var encoded = try JSONSerialization.data(
            withJSONObject: responseObject,
            options: [.sortedKeys]
        )
        encoded.append(UInt8(ascii: "\n"))
        helloResponseData = encoded
    }

    var receivedLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.queue.async {
                self.accept(connection)
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [self] in
            listener.cancel()
            for connection in connections {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receiveLoop(on: connection)
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty {
                self.ingest(data, on: connection)
            }
            if error == nil && !isComplete {
                self.receiveLoop(on: connection)
            }
        }
    }

    private func ingest(_ data: Data, on connection: NWConnection) {
        lineBuffer.append(data)
        let newline = UInt8(ascii: "\n")
        while let idx = lineBuffer.firstIndex(of: newline) {
            let lineData = Data(lineBuffer[..<idx])
            lineBuffer.removeSubrange(...idx)
            guard !lineData.isEmpty else { continue }
            let line = String(decoding: lineData, as: UTF8.self)
            lock.lock()
            lines.append(line)
            lock.unlock()
            if !helloReplied, line.contains("\"type\":\"hello\"") {
                helloReplied = true
                connection.send(
                    content: helloResponseData,
                    completion: .contentProcessed { _ in }
                )
            }
        }
    }
}
