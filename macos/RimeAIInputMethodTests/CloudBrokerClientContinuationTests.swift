import Foundation
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
}
