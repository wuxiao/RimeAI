import XCTest

private final class TestCandidateCollector {
    var values: [String] = []
}

private func collectTestCandidate(
    _ text: UnsafePointer<CChar>?,
    _ comment: UnsafePointer<CChar>?,
    _ index: Int,
    _ context: UnsafeMutableRawPointer?
) {
    guard let text, let context else {
        return
    }
    let collector = Unmanaged<TestCandidateCollector>
        .fromOpaque(context)
        .takeUnretainedValue()
    collector.values.append(String(cString: text))
}

final class RimeCandidateIntegrationTests: XCTestCase {
    func testLibrimeProducesAndCommitsSimplifiedChineseCandidate() throws {
        let fileManager = FileManager.default
        let bundle = Bundle(for: Self.self)
        guard let resources = bundle.url(
            forResource: "RimeData",
            withExtension: nil
        ) else {
            XCTFail("RimeData is missing from the test bundle")
            return
        }

        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "RimeAIKeyboardTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? fileManager.removeItem(at: root)
        }
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)
        try fileManager.createDirectory(
            at: user,
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(
            at: resources.appendingPathComponent("shared", isDirectory: true),
            to: shared
        )
        try fileManager.copyItem(
            at: resources.appendingPathComponent(
                "user-build",
                isDirectory: true
            ),
            to: user.appendingPathComponent("build", isDirectory: true)
        )

        var error = [CChar](repeating: 0, count: 512)
        let engine = error.withUnsafeMutableBufferPointer { errorBuffer in
            shared.path.withCString { sharedPath in
                user.path.withCString { userPath in
                    "luna_pinyin_simp".withCString { schema in
                        rai_engine_create_prebuilt(
                            sharedPath,
                            userPath,
                            schema,
                            errorBuffer.baseAddress,
                            errorBuffer.count
                        )
                    }
                }
            }
        }
        guard let engine else {
            XCTFail("librime start failed: \(message(from: error))")
            return
        }
        defer {
            rai_engine_destroy(engine)
        }

        let collector = TestCandidateCollector()
        let context = Unmanaged.passUnretained(collector).toOpaque()
        let count = error.withUnsafeMutableBufferPointer { errorBuffer in
            "nihao".withCString { input in
                rai_engine_candidates(
                    engine,
                    input,
                    10,
                    collectTestCandidate,
                    context,
                    errorBuffer.baseAddress,
                    errorBuffer.count
                )
            }
        }
        XCTAssertGreaterThan(count, 0, message(from: error))
        XCTAssertTrue(
            collector.values.contains("你好"),
            "Expected 你好 in candidates, got \(collector.values)"
        )

        var committed = [CChar](repeating: 0, count: 1024)
        let committedLength = committed.withUnsafeMutableBufferPointer {
            committedBuffer in
            error.withUnsafeMutableBufferPointer { errorBuffer in
                "nihao".withCString { input in
                    rai_engine_commit_candidate(
                        engine,
                        input,
                        0,
                        committedBuffer.baseAddress,
                        committedBuffer.count,
                        errorBuffer.baseAddress,
                        errorBuffer.count
                    )
                }
            }
        }
        XCTAssertGreaterThan(committedLength, 0, message(from: error))
        let committedText = committed.withUnsafeBufferPointer { buffer in
            String(cString: buffer.baseAddress!)
        }
        XCTAssertFalse(committedText.isEmpty)

        collector.values = []
        let partialCount = error.withUnsafeMutableBufferPointer {
            errorBuffer in
            "mingtiantianqi".withCString { input in
                rai_engine_candidates(
                    engine,
                    input,
                    20,
                    collectTestCandidate,
                    context,
                    errorBuffer.baseAddress,
                    errorBuffer.count
                )
            }
        }
        XCTAssertGreaterThan(partialCount, 0, message(from: error))
        let partialIndex = try XCTUnwrap(
            collector.values.firstIndex(of: "明天")
        )
        var selected = [CChar](repeating: 0, count: 1024)
        var remaining = [CChar](repeating: 0, count: 1024)
        let partialResult = error.withUnsafeMutableBufferPointer {
            errorBuffer in
            selected.withUnsafeMutableBufferPointer { selectedBuffer in
                remaining.withUnsafeMutableBufferPointer { remainingBuffer in
                    "mingtiantianqi".withCString { input in
                        "明天".withCString { expected in
                            rai_engine_select_candidate(
                                engine,
                                input,
                                partialIndex,
                                expected,
                                selectedBuffer.baseAddress,
                                selectedBuffer.count,
                                remainingBuffer.baseAddress,
                                remainingBuffer.count,
                                errorBuffer.baseAddress,
                                errorBuffer.count
                            )
                        }
                    }
                }
            }
        }
        XCTAssertEqual(
            partialResult,
            Int32(RAI_CANDIDATE_SELECTION_PARTIAL)
        )
        XCTAssertEqual(string(from: selected), "明天")
        XCTAssertEqual(string(from: remaining), "tianqi")

        collector.values = []
        let tailCount = error.withUnsafeMutableBufferPointer { errorBuffer in
            "tianqi".withCString { input in
                rai_engine_candidates(
                    engine,
                    input,
                    20,
                    collectTestCandidate,
                    context,
                    errorBuffer.baseAddress,
                    errorBuffer.count
                )
            }
        }
        XCTAssertGreaterThan(tailCount, 0, message(from: error))
        let correctedTailIndex = try XCTUnwrap(
            collector.values.firstIndex(of: "天启")
        )
        selected = [CChar](repeating: 0, count: 1024)
        remaining = [CChar](repeating: 0, count: 1024)
        let tailResult = error.withUnsafeMutableBufferPointer { errorBuffer in
            selected.withUnsafeMutableBufferPointer { selectedBuffer in
                remaining.withUnsafeMutableBufferPointer { remainingBuffer in
                    "tianqi".withCString { input in
                        "天启".withCString { expected in
                            rai_engine_select_candidate(
                                engine,
                                input,
                                correctedTailIndex,
                                expected,
                                selectedBuffer.baseAddress,
                                selectedBuffer.count,
                                remainingBuffer.baseAddress,
                                remainingBuffer.count,
                                errorBuffer.baseAddress,
                                errorBuffer.count
                            )
                        }
                    }
                }
            }
        }
        XCTAssertEqual(
            tailResult,
            Int32(RAI_CANDIDATE_SELECTION_COMPLETE)
        )
        XCTAssertEqual(string(from: selected), "天启")
        XCTAssertEqual(string(from: remaining), "")
    }

    private func message(from buffer: [CChar]) -> String {
        let decoded = string(from: buffer)
        return decoded.isEmpty ? "no librime error text" : decoded
    }

    private func string(from buffer: [CChar]) -> String {
        String(
            decoding: buffer.prefix { $0 != 0 }.map {
                UInt8(bitPattern: $0)
            },
            as: UTF8.self
        )
    }
}
