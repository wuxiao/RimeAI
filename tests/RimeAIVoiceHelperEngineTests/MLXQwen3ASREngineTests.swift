import Foundation
import RimeAIInputCore
import Testing
@testable import RimeAIVoiceHelperEngine

private final class FakePCMSource: VoicePCMSource, @unchecked Sendable {
    private let lock = NSLock()
    private var frameSink: (@Sendable (VoicePCMFrame) -> Void)?
    private var failureSink: (@Sendable (VoicePCMSourceFailure) -> Void)?
    var started = false
    var stopped = false
    var cancelled = false

    func start(
        onFrame: @escaping @Sendable (VoicePCMFrame) -> Void,
        onFailure: @escaping @Sendable (VoicePCMSourceFailure) -> Void
    ) throws {
        lock.lock()
        started = true
        frameSink = onFrame
        failureSink = onFailure
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func emitFrame(value: Float = 0.2) {
        lock.lock()
        let sink = frameSink
        lock.unlock()
        let samples = Array(repeating: value, count: VoicePCMFrame.samplesPerFrame)
        sink?(VoicePCMFrame(samples: samples))
    }

    func emitFailure(_ failure: VoicePCMSourceFailure) {
        lock.lock()
        let sink = failureSink
        lock.unlock()
        sink?(failure)
    }
}

private final class FakePCMSourceFactory: VoicePCMSourceFactory, @unchecked Sendable {
    let source = FakePCMSource()
    func makeSource() throws -> any VoicePCMSource { source }
}

private final class FakeMLXQwen3Worker:
    MLXQwen3ASRWorkerControlling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var handler: (@Sendable (MLXQwen3ASRWorkerEvent) -> Void)?
    var startedRequests: [(String, [String])] = []
    var receivedSampleCount = 0
    var stoppedRequests: [String] = []
    var cancelledRequests: [String] = []
    var ready = true
    let startSignal = DispatchSemaphore(value: 0)
    let stopSignal = DispatchSemaphore(value: 0)

    var isReady: Bool { ready }

    func startIfNeeded(
        onEvent: @escaping @Sendable (MLXQwen3ASRWorkerEvent) -> Void
    ) throws {
        lock.lock()
        handler = onEvent
        lock.unlock()
    }

    func waitUntilReady(timeoutSeconds: TimeInterval) -> Bool {
        ready
    }

    func sendStart(requestID: String, hotwords: [String]) throws {
        lock.lock()
        startedRequests.append((requestID, hotwords))
        lock.unlock()
        startSignal.signal()
    }

    func sendAudio(requestID: String, samples: [Float]) throws {
        lock.lock()
        receivedSampleCount += samples.count
        lock.unlock()
    }

    func sendStop(requestID: String) throws {
        lock.lock()
        stoppedRequests.append(requestID)
        lock.unlock()
        stopSignal.signal()
    }

    func sendCancel(requestID: String) {
        lock.lock()
        cancelledRequests.append(requestID)
        lock.unlock()
    }

    func shutdown() {}

    func emit(_ event: MLXQwen3ASRWorkerEvent) {
        lock.lock()
        let h = handler
        lock.unlock()
        h?(event)
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [VoiceDictationEngineEvent] = []

    func append(_ event: VoiceDictationEngineEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var snapshot: [VoiceDictationEngineEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

@Suite("MLXQwen3ASREngine")
struct MLXQwen3ASREngineTests {
    @Test("descriptor advertises offline streaming local ASR with 128 hotwords")
    func descriptorCapabilities() {
        let descriptor = MLXQwen3ASREngine.adapterDescriptor
        #expect(descriptor.isStructurallyValid)
        #expect(descriptor.protocolEngineID == "mlx-qwen3-asr")
        #expect(descriptor.networkPolicy == .offline)
        #expect(descriptor.advertisedMaximumHotwords == 128)
        #expect(Set(descriptor.advertisedProtocolCapabilities) == [
            "local_asr",
            "streaming",
            "hotword_snapshot",
        ])
    }

    @Test("forwards hotwords, batches PCM frames, emits partials and final")
    func streamingAndFinalFlow() throws {
        let sourceFactory = FakePCMSourceFactory()
        let worker = FakeMLXQwen3Worker()
        let engine = MLXQwen3ASREngine(
            sourceFactory: sourceFactory,
            worker: worker,
            eagerWarmup: false
        )

        let recorder = EventRecorder()
        let finished = DispatchSemaphore(value: 0)

        let hotwords = try VoiceHotwordSnapshot(
            phrases: ["RimeAI", "雾凇拼音", "FastAPI"]
        )
        let request = VoiceDictationEngineRequest(
            requestID: "req-mlx-1",
            wireRequestID: "wire-1",
            compositionID: UUID().uuidString,
            applicationSessionID: "sess-1",
            bundleID: "com.apple.Terminal",
            mode: .direct,
            deadlineMilliseconds: 4_000,
            maximumDurationMilliseconds: 30_000,
            hotwordSnapshot: hotwords
        )

        engine.start(request) { event in
            recorder.append(event)
            if case .finished = event {
                finished.signal()
            }
        }

        #expect(worker.startSignal.wait(timeout: .now() + 2) == .success)
        #expect(worker.startedRequests.count == 1)
        #expect(worker.startedRequests[0].1 == ["RimeAI", "雾凇拼音", "FastAPI"])

        for _ in 0 ..< 6 {
            sourceFactory.source.emitFrame(value: 0.25)
        }
        worker.emit(.partial(
            requestID: "req-mlx-1",
            stableText: "我们用",
            partialText: "RimeAI",
            confidence: 0.9
        ))

        engine.stop(requestID: "req-mlx-1")
        #expect(worker.stopSignal.wait(timeout: .now() + 2) == .success)
        #expect(sourceFactory.source.stopped)
        #expect(worker.receivedSampleCount == VoicePCMFrame.samplesPerFrame * 6)

        worker.emit(.final(
            requestID: "req-mlx-1",
            text: "我们用 RimeAI 测试 FastAPI。",
            confidence: 0.95,
            polishApplied: false
        ))

        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(recorder.snapshot == [
            .partial(stableText: "我们用", partialText: "RimeAI", confidence: 0.9),
            .finished(
                text: "我们用 RimeAI 测试 FastAPI。",
                confidence: 0.95,
                polishApplied: false
            ),
        ])
    }

    @Test("empty final falls back to last partial or fails with asrTimeout")
    func emptyFinalHandling() {
        let sourceFactory = FakePCMSourceFactory()
        let worker = FakeMLXQwen3Worker()
        let engine = MLXQwen3ASREngine(
            sourceFactory: sourceFactory,
            worker: worker,
            eagerWarmup: false
        )

        let recorder = EventRecorder()
        let done = DispatchSemaphore(value: 0)

        let request = VoiceDictationEngineRequest(
            requestID: "req-empty",
            wireRequestID: "wire-empty",
            compositionID: UUID().uuidString,
            applicationSessionID: "sess-1",
            bundleID: "com.apple.Terminal",
            mode: .direct,
            deadlineMilliseconds: 2_000,
            maximumDurationMilliseconds: 10_000
        )

        engine.start(request) { event in
            recorder.append(event)
            done.signal()
        }
        #expect(worker.startSignal.wait(timeout: .now() + 2) == .success)

        engine.stop(requestID: "req-empty")
        #expect(worker.stopSignal.wait(timeout: .now() + 2) == .success)
        worker.emit(.final(
            requestID: "req-empty",
            text: "",
            confidence: 0.0,
            polishApplied: false
        ))

        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(recorder.snapshot == [.failed(.asrTimeout, retryable: true)])
    }

    @Test("unlimited duration (0 ms) does not auto-stop and preserves long text")
    func unlimitedDurationAndLongText() {
        let sourceFactory = FakePCMSourceFactory()
        let worker = FakeMLXQwen3Worker()
        let engine = MLXQwen3ASREngine(
            sourceFactory: sourceFactory,
            worker: worker,
            eagerWarmup: false
        )

        let recorder = EventRecorder()
        let finished = DispatchSemaphore(value: 0)
        let longText = String(repeating: "测试不限时长不限字数", count: 40) // 400 chars

        let request = VoiceDictationEngineRequest(
            requestID: "req-unlimited",
            wireRequestID: "wire-unlimited",
            compositionID: UUID().uuidString,
            applicationSessionID: "sess-1",
            bundleID: "com.apple.Terminal",
            mode: .direct,
            deadlineMilliseconds: 10_000,
            maximumDurationMilliseconds: 0
        )

        engine.start(request) { event in
            recorder.append(event)
            if case .finished = event {
                finished.signal()
            }
        }

        #expect(worker.startSignal.wait(timeout: .now() + 2) == .success)
        // Briefly sleep to prove 0 ms does not trigger an immediate auto-stop.
        Thread.sleep(forTimeInterval: 0.1)
        #expect(worker.stoppedRequests.isEmpty)

        worker.emit(.partial(
            requestID: "req-unlimited",
            stableText: longText,
            partialText: "",
            confidence: 0.9
        ))
        engine.stop(requestID: "req-unlimited")
        #expect(worker.stopSignal.wait(timeout: .now() + 2) == .success)
        worker.emit(.final(
            requestID: "req-unlimited",
            text: longText,
            confidence: 0.95,
            polishApplied: false
        ))

        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(recorder.snapshot == [
            .partial(stableText: longText, partialText: "", confidence: 0.9),
            .finished(text: longText, confidence: 0.95, polishApplied: false),
        ])
    }
}
