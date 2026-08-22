import CryptoKit
import Foundation
import Testing
@testable import RimeAIInputCore
@testable import RimeAIVoiceEvaluationDriver
import RimeAIVoiceHelperEngine
@_spi(VoiceEvaluation) import RimeAIVoicePerformanceHelperBridge

@Suite(.serialized)
struct VoiceEvaluationRunnerTests {
    @Test
    func routesPacedWAVThroughServerCoreAndStopsOnlyAtEOF() throws {
        let fixture = try RunnerWAVFixture(frameCount: 400)
        defer { fixture.remove() }
        let plan = try fixture.makePlan()
        let clock = AdvancingEvaluationClock()
        let engineState = FrameDrivenEngineState()
        let descriptor = Self.productDescriptor
        let runner = VoiceEvaluationRunner(
            engineFactory: { _, sourceFactory in
                FrameDrivenEvaluationEngine(
                    descriptor: descriptor,
                    sourceFactory: sourceFactory,
                    state: engineState
                )
            },
            schedule: { delay, operation in
                clock.advance(by: delay)
                operation()
            },
            monotonicNowMilliseconds: clock.now
        )

        let observations = try runner.run(plan: plan)

        #expect(observations.count == 1)
        #expect(observations[0].sampleID == "sample-1")
        #expect(observations[0].outcome == .final)
        #expect(engineState.frameCount == 2)
        #expect(engineState.stopFrameCounts == [1])
        let encoded = try JSONEncoder().encode(observations[0])
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["stop_received_elapsed_ms"] as? Double == 27)
        let final = try #require(object["final"] as? [String: Any])
        #expect(final["elapsed_ms"] as? Double == 29)
    }

    @Test
    func rejectsPolishCapabilityForTheNonePostprocessorPolicy() throws {
        let fixture = try RunnerWAVFixture(frameCount: 400)
        defer { fixture.remove() }
        let plan = try fixture.makePlan()
        let clock = AdvancingEvaluationClock()
        let descriptor = Self.makeProductDescriptor(
            capabilities: [
                .localASR, .streaming, .hotwordSnapshot, .polish,
            ]
        )
        let runner = VoiceEvaluationRunner(
            engineFactory: { _, sourceFactory in
                FrameDrivenEvaluationEngine(
                    descriptor: descriptor,
                    sourceFactory: sourceFactory,
                    state: FrameDrivenEngineState()
                )
            },
            schedule: { delay, operation in
                clock.advance(by: delay)
                operation()
            },
            monotonicNowMilliseconds: clock.now
        )

        #expect(throws: VoiceEvaluationError.self) {
            try runner.run(plan: plan)
        }
    }

    @Test
    func rejectsReadyThatAdvertisesPolishForTheNonePostprocessorPolicy() throws {
        let fixture = try RunnerWAVFixture(frameCount: 400)
        defer { fixture.remove() }
        let plan = try fixture.makePlan()
        let clock = AdvancingEvaluationClock()
        let descriptors = EvaluationDescriptorSequence([
            Self.productDescriptor,
            Self.makeProductDescriptor(capabilities: [
                .localASR, .streaming, .hotwordSnapshot, .polish,
            ]),
        ])
        let runner = VoiceEvaluationRunner(
            engineFactory: { _, sourceFactory in
                FrameDrivenEvaluationEngine(
                    descriptorProvider: descriptors.next,
                    sourceFactory: sourceFactory,
                    state: FrameDrivenEngineState()
                )
            },
            schedule: { delay, operation in
                clock.advance(by: delay)
                operation()
            },
            monotonicNowMilliseconds: clock.now
        )

        #expect(throws: VoiceEvaluationError.self) {
            try runner.run(plan: plan)
        }
    }

    @Test
    func rejectsPolishedFinalForTheNonePostprocessorPolicy() throws {
        let fixture = try RunnerWAVFixture(frameCount: 400)
        defer { fixture.remove() }
        let plan = try fixture.makePlan()
        let clock = AdvancingEvaluationClock()
        let descriptor = Self.productDescriptor
        let runner = VoiceEvaluationRunner(
            engineFactory: { _, sourceFactory in
                FrameDrivenEvaluationEngine(
                    descriptor: descriptor,
                    sourceFactory: sourceFactory,
                    state: FrameDrivenEngineState(),
                    polishApplied: true
                )
            },
            schedule: { delay, operation in
                clock.advance(by: delay)
                operation()
            },
            monotonicNowMilliseconds: clock.now
        )

        #expect(throws: VoiceEvaluationError.self) {
            try runner.run(plan: plan)
        }
    }

    private static let productDescriptor = makeProductDescriptor(
        capabilities: [.localASR, .streaming, .hotwordSnapshot]
    )

    private static func makeProductDescriptor(
        capabilities: Set<VoiceEngineCapability>
    ) -> VoiceEngineDescriptor {
        VoiceEngineDescriptor(
            adapterID: "sherpa-onnx",
            adapterVersion: "1.0",
            assetManagement: .productManaged,
            qualification: .integrityVerifiedProductArtifact,
            artifactID: VoiceASRArtifactID(rawValue: "artifact-v1"),
            artifactSHA256:
                "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            artifactGeneration: UUID(),
            supportedLocales: ["zh-CN", "en-US"],
            capabilities: capabilities,
            networkPolicy: .offline,
            audioFormat: .fixedLinearPCM(
                sampleRateHertz: 16_000,
                channelCount: 1,
                bitsPerChannel: 32
            ),
            hotwordMode: .boundedPhraseList(maximumEntries: 64),
            maximumAlternatives: 1
        )
    }
}

private final class FrameDrivenEvaluationEngine:
    VoiceDictationEngine,
    @unchecked Sendable
{
    var descriptor: VoiceEngineDescriptor { descriptorProvider() }
    private let descriptorProvider: @Sendable () -> VoiceEngineDescriptor
    private let sourceFactory: any VoicePCMSourceFactory
    private let state: FrameDrivenEngineState
    private let polishApplied: Bool
    private let lock = NSLock()
    private var source: (any VoicePCMSource)?
    private var requestID: String?
    private var events: (@Sendable (VoiceDictationEngineEvent) -> Void)?

    init(
        descriptor: VoiceEngineDescriptor,
        sourceFactory: any VoicePCMSourceFactory,
        state: FrameDrivenEngineState,
        polishApplied: Bool = false
    ) {
        self.descriptorProvider = { descriptor }
        self.sourceFactory = sourceFactory
        self.state = state
        self.polishApplied = polishApplied
    }

    init(
        descriptorProvider: @escaping @Sendable () -> VoiceEngineDescriptor,
        sourceFactory: any VoicePCMSourceFactory,
        state: FrameDrivenEngineState,
        polishApplied: Bool = false
    ) {
        self.descriptorProvider = descriptorProvider
        self.sourceFactory = sourceFactory
        self.state = state
        self.polishApplied = polishApplied
    }

    func start(
        _ request: VoiceDictationEngineRequest,
        events: @escaping @Sendable (VoiceDictationEngineEvent) -> Void
    ) {
        do {
            let source = try sourceFactory.makeSource()
            lock.lock()
            self.source = source
            requestID = request.requestID
            self.events = events
            lock.unlock()
            try source.start(
                onFrame: { [state] _ in
                    let count = state.appendFrame()
                    events(.partial(
                        stableText: "",
                        partialText: "p\(count)",
                        confidence: 0.5
                    ))
                },
                onFailure: { failure in
                    events(.failed(failure.code, retryable: failure.retryable))
                }
            )
        } catch {
            events(.failed(.micUnavailable, retryable: false))
        }
    }

    func stop(requestID: String) {
        lock.lock()
        guard self.requestID == requestID,
              let source,
              let events
        else {
            lock.unlock()
            return
        }
        lock.unlock()
        state.recordStop()
        source.stop()
        events(.finished(
            text: "你好",
            confidence: 0.75,
            polishApplied: polishApplied
        ))
    }

    func cancel(requestID: String) {
        lock.lock()
        let source = self.requestID == requestID ? self.source : nil
        lock.unlock()
        source?.cancel()
    }
}

private final class FrameDrivenEngineState: @unchecked Sendable {
    private let lock = NSLock()
    private var frameCountStorage = 0
    private var stopFrameCountStorage: [Int] = []

    func appendFrame() -> Int {
        lock.lock()
        frameCountStorage += 1
        let result = frameCountStorage
        lock.unlock()
        return result
    }

    func recordStop() {
        lock.lock()
        stopFrameCountStorage.append(frameCountStorage)
        lock.unlock()
    }

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return frameCountStorage
    }

    var stopFrameCounts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return stopFrameCountStorage
    }
}

private final class AdvancingEvaluationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var milliseconds = 0.0

    func advance(by value: Double) {
        lock.lock()
        milliseconds += value
        lock.unlock()
    }

    func now() -> Double {
        lock.lock()
        milliseconds += 1
        let result = milliseconds
        lock.unlock()
        return result
    }
}

private final class EvaluationDescriptorSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptors: [VoiceEngineDescriptor]
    private var index = 0

    init(_ descriptors: [VoiceEngineDescriptor]) {
        self.descriptors = descriptors
    }

    func next() -> VoiceEngineDescriptor {
        lock.lock()
        defer { lock.unlock() }
        let descriptor = descriptors[min(index, descriptors.count - 1)]
        index += 1
        return descriptor
    }
}

private final class RunnerWAVFixture {
    let root: URL
    let wavURL: URL
    let sha256: String

    init(frameCount: Int) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rimeai-runner-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        wavURL = root.appendingPathComponent("sample.wav")
        var data = Data()
        let byteCount = frameCount * 2
        data.append(contentsOf: "RIFF".utf8)
        data.runnerAppend(UInt32(36 + byteCount))
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.runnerAppend(UInt32(16))
        data.runnerAppend(UInt16(1))
        data.runnerAppend(UInt16(1))
        data.runnerAppend(UInt32(16_000))
        data.runnerAppend(UInt32(32_000))
        data.runnerAppend(UInt16(2))
        data.runnerAppend(UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.runnerAppend(UInt32(byteCount))
        for index in 0 ..< frameCount {
            data.runnerAppend(UInt16(bitPattern: Int16(2_000 + index)))
        }
        try data.write(to: wavURL)
        sha256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func makePlan() throws -> VoiceEvaluationPlan {
        let json = VoiceEvaluationPlanTests.validPlanJSON
            .replacingOccurrences(
                of: "/tmp/rimeai-artifact",
                with: root.appendingPathComponent("artifact").path
            )
            .replacingOccurrences(of: "/tmp/sample-1.wav", with: wavURL.path)
            .replacingOccurrences(
                of: String(repeating: "d", count: 64),
                with: sha256
            )
            .replacingOccurrences(of: "\"duration_ms\": 20", with: "\"duration_ms\": 25")
            .replacingOccurrences(of: "\"frame_count\": 320", with: "\"frame_count\": 400")
            .replacingOccurrences(
                of: "/tmp/observations.jsonl",
                with: root.appendingPathComponent("observations.jsonl").path
            )
        return try VoiceEvaluationPlan.decodeStrict(Data(json.utf8))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private extension Data {
    mutating func runnerAppend(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func runnerAppend(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
