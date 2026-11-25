import Foundation
import RimeAIInputCore
import Testing
@testable import RimeAIVoiceHelperEngine

// MARK: - Test doubles

/// 可以在 `sendAudio` 上无限停滞的 worker：模拟管道写满、Python worker 卡死。
private final class StallingMLXQwen3Worker:
    MLXQwen3ASRWorkerControlling,
    @unchecked Sendable
{
    private let handlerLock = NSLock()
    private var handler: (@Sendable (MLXQwen3ASRWorkerEvent) -> Void)?
    private let stateLock = NSLock()
    private var stalled = false
    private var audioBatches: [[Float]] = []
    private var startedRequests: [String] = []
    private var stoppedRequests: [String] = []
    private var cancelledRequests: [String] = []
    private var shutdownCount = 0
    private var startIfNeededCount = 0

    /// 第一次停滞写入进入 `sendAudio` 时触发。
    let stalledWriteEntered = DispatchSemaphore(value: 0)
    private let releaseStalls = DispatchSemaphore(value: 0)
    private var enteredStallCount = 0

    var isReady: Bool { true }

    func startIfNeeded(
        onEvent: @escaping @Sendable (MLXQwen3ASRWorkerEvent) -> Void
    ) throws {
        handlerLock.lock()
        handler = onEvent
        handlerLock.unlock()
        stateLock.lock()
        startIfNeededCount += 1
        stateLock.unlock()
    }

    func waitUntilReady(timeoutSeconds: TimeInterval) -> Bool {
        true
    }

    func sendStart(requestID: String, hotwords: [String]) throws {
        stateLock.lock()
        startedRequests.append(requestID)
        stateLock.unlock()
    }

    func sendAudio(requestID: String, samples: [Float]) throws {
        stateLock.lock()
        let isStalled = stalled
        if isStalled {
            enteredStallCount += 1
            let firstStall = enteredStallCount == 1
            stateLock.unlock()
            if firstStall {
                stalledWriteEntered.signal()
            }
            _ = releaseStalls.wait(timeout: .now() + 30)
        } else {
            stateLock.unlock()
        }
        stateLock.lock()
        audioBatches.append(samples)
        stateLock.unlock()
    }

    func sendStop(requestID: String) throws {
        stateLock.lock()
        stoppedRequests.append(requestID)
        stateLock.unlock()
    }

    func sendCancel(requestID: String) {
        stateLock.lock()
        cancelledRequests.append(requestID)
        stateLock.unlock()
    }

    func shutdown() {
        stateLock.lock()
        shutdownCount += 1
        stateLock.unlock()
    }

    // MARK: Controls

    func stall() {
        stateLock.lock()
        stalled = true
        stateLock.unlock()
    }

    /// 解除停滞；每一条曾卡住的写入各放行一次。
    func releaseAllStalls() {
        stateLock.lock()
        let count = max(enteredStallCount, 1)
        stalled = false
        stateLock.unlock()
        for _ in 0 ..< count {
            releaseStalls.signal()
        }
    }

    func emit(_ event: MLXQwen3ASRWorkerEvent) {
        handlerLock.lock()
        let sink = handler
        handlerLock.unlock()
        sink?(event)
    }

    var recordedBatchCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return audioBatches.count
    }

    /// 每一批的采样数。
    var recordedBatchSampleCounts: [Int] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return audioBatches.map(\.count)
    }

    /// 每一批的首个采样值（测试用它标识批次先后）。
    var recordedBatchMarkers: [Float] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return audioBatches.compactMap(\.first)
    }

    var recordedStopRequests: [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stoppedRequests
    }

    var recordedCancelRequests: [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelledRequests
    }

    var recordedStartRequests: [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return startedRequests
    }

    var launchCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return startIfNeededCount
    }
}

private final class RecordingPCMSource: VoicePCMSource, @unchecked Sendable {
    private let lock = NSLock()
    private var frameSink: (@Sendable (VoicePCMFrame) -> Void)?
    private var started = false
    private var stopped = false
    private var cancelled = false

    func start(
        onFrame: @escaping @Sendable (VoicePCMFrame) -> Void,
        onFailure: @escaping @Sendable (VoicePCMSourceFailure) -> Void
    ) throws {
        lock.lock()
        started = true
        frameSink = onFrame
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
        sink?(VoicePCMFrame(samples: Array(
            repeating: value,
            count: VoicePCMFrame.samplesPerFrame
        )))
    }

    var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private final class RecordingPCMSourceFactory: VoicePCMSourceFactory, @unchecked Sendable {
    private(set) var sources: [RecordingPCMSource] = []
    private let lock = NSLock()

    func makeSource() throws -> any VoicePCMSource {
        let source = RecordingPCMSource()
        lock.lock()
        sources.append(source)
        lock.unlock()
        return source
    }

    var lastSource: RecordingPCMSource? {
        lock.lock()
        defer { lock.unlock() }
        return sources.last
    }
}

private final class EngineEventRecorder: @unchecked Sendable {
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

private func waitUntil(
    timeout: TimeInterval = 3,
    _ condition: @escaping () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        usleep(5_000)
    }
    return condition()
}

private func makeRequest(
    requestID: String,
    deadlineMilliseconds: Int,
    maximumDurationMilliseconds: Int = 0
) -> VoiceDictationEngineRequest {
    VoiceDictationEngineRequest(
        requestID: requestID,
        wireRequestID: "wire-\(requestID)",
        compositionID: UUID().uuidString,
        applicationSessionID: "sess-backpressure",
        bundleID: "com.apple.Terminal",
        mode: .direct,
        deadlineMilliseconds: deadlineMilliseconds,
        maximumDurationMilliseconds: maximumDurationMilliseconds
    )
}

// MARK: - Tests

@Suite("MLXQwen3ASREngine backpressure")
struct MLXQwen3ASREngineBackpressureTests {
    private let framesPerBatch = 5

    /// 先让一条音频写入卡在 worker 里，再返回（source, worker）。
    private func makeStalledEngine(
        requestID: String,
        deadlineMilliseconds: Int,
        recorder: EngineEventRecorder
    ) -> (
        engine: MLXQwen3ASREngine,
        worker: StallingMLXQwen3Worker,
        factory: RecordingPCMSourceFactory
    ) {
        let worker = StallingMLXQwen3Worker()
        let factory = RecordingPCMSourceFactory()
        let engine = MLXQwen3ASREngine(
            sourceFactory: factory,
            worker: worker,
            eagerWarmup: false
        )
        worker.stall()
        engine.start(makeRequest(
            requestID: requestID,
            deadlineMilliseconds: deadlineMilliseconds
        )) { event in
            recorder.append(event)
        }
        return (engine, worker, factory)
    }

    @Test("stop and the finalization timeout are never blocked by a stalled worker")
    func stopAndFinalizationTimeoutNeverBlock() {
        let recorder = EngineEventRecorder()
        let (engine, worker, factory) = makeStalledEngine(
            requestID: "req-stalled-stop",
            deadlineMilliseconds: 400,
            recorder: recorder
        )
        // 让 source 先启动，再灌入第一批音频把 writer 卡住。
        #expect(waitUntil { factory.lastSource?.isStarted == true })
        let source = factory.lastSource
        for _ in 0 ..< framesPerBatch {
            source?.emitFrame(value: 0.01)
        }
        #expect(worker.stalledWriteEntered.wait(timeout: .now() + 3) == .success)
        worker.emit(.partial(
            requestID: "req-stalled-stop",
            stableText: "我们用",
            partialText: "",
            confidence: 0.9
        ))

        let stopStarted = Date()
        engine.stop(requestID: "req-stalled-stop")
        let stopLatency = Date().timeIntervalSince(stopStarted)
        // stop() 立即返回；麦克风在另一条队列上很快停下。
        #expect(stopLatency < 0.5)
        #expect(waitUntil { source?.isStopped == true })

        // worker 始终不返回 final：收尾超时照常触发并用最后一个 partial 结束。
        #expect(waitUntil(timeout: 3) {
            recorder.snapshot.contains { event in
                if case .finished = event { return true }
                return false
            }
        })
        #expect(recorder.snapshot.last == .finished(
            text: "我们用",
            confidence: 0.75,
            polishApplied: false
        ))

        worker.releaseAllStalls()
        // 超时路径补发的 cancel 排在在途音频之后，最终送达 worker。
        #expect(waitUntil {
            worker.recordedCancelRequests.contains("req-stalled-stop")
        })
    }

    @Test("cancel returns immediately while the worker is stalled and frees the session")
    func cancelNeverBlocksAndFreesSession() {
        let firstRecorder = EngineEventRecorder()
        let (engine, worker, factory) = makeStalledEngine(
            requestID: "req-stalled-cancel",
            deadlineMilliseconds: 30_000,
            recorder: firstRecorder
        )
        #expect(waitUntil { factory.lastSource?.isStarted == true })
        for _ in 0 ..< framesPerBatch {
            factory.lastSource?.emitFrame(value: 0.02)
        }
        #expect(worker.stalledWriteEntered.wait(timeout: .now() + 3) == .success)

        let cancelStarted = Date()
        engine.cancel(requestID: "req-stalled-cancel")
        #expect(Date().timeIntervalSince(cancelStarted) < 0.5)
        // 会话已同步释放：卡住的 writer 不妨碍开始新的会话。
        #expect(waitUntil { factory.lastSource?.isCancelled == true })

        let secondRecorder = EngineEventRecorder()
        let second = makeRequest(
            requestID: "req-after-cancel",
            deadlineMilliseconds: 30_000
        )
        engine.start(second) { event in
            secondRecorder.append(event)
        }
        #expect(secondRecorder.snapshot.isEmpty)
        engine.cancel(requestID: "req-after-cancel")
        #expect(waitUntil { factory.lastSource?.isCancelled == true })

        worker.releaseAllStalls()
        // 已取消的会话不再向 worker 写 start；两条 cancel 都会送达。
        #expect(waitUntil {
            worker.recordedCancelRequests.count >= 2
        })
        #expect(!worker.recordedStartRequests.contains("req-after-cancel"))
        #expect(firstRecorder.snapshot.isEmpty)
    }

    @Test("audio backlog is bounded and drops the oldest batches first")
    func audioBacklogIsBounded() {
        let recorder = EngineEventRecorder()
        let (engine, worker, factory) = makeStalledEngine(
            requestID: "req-backlog",
            deadlineMilliseconds: 30_000,
            recorder: recorder
        )
        #expect(waitUntil { factory.lastSource?.isStarted == true })
        let source = factory.lastSource
        let maximumQueued = MLXQwen3ASREngine.maximumQueuedAudioBatches

        // 第 0 批：卡在 worker 的第一次写入里。
        for _ in 0 ..< framesPerBatch {
            source?.emitFrame(value: 0)
        }
        #expect(worker.stalledWriteEntered.wait(timeout: .now() + 3) == .success)

        func emitBatch(_ index: Int) {
            for _ in 0 ..< framesPerBatch {
                source?.emitFrame(value: Float(index + 1) / 100)
            }
        }
        // 第 1 … maximumQueued 批：正好填满有界积压，还没有丢弃。
        for index in 1 ... maximumQueued {
            emitBatch(index)
        }
        #expect(engine.droppedAudioBatchCount == 0)

        // 再多 5 批：最旧的 5 批（第 1 … 5 批）被丢弃。
        for index in (maximumQueued + 1) ... (maximumQueued + 5) {
            emitBatch(index)
        }
        #expect(engine.droppedAudioBatchCount == 5)

        worker.releaseAllStalls()
        let expectedDelivered = 1 + maximumQueued
        #expect(waitUntil { worker.recordedBatchCount == expectedDelivered })

        // 保留下来的顺序不变且都是最新的音频：在途的第 0 批 + 第 6 … 25 批
        // （`emitBatch` 用 (index + 1) / 100 标记批次）。
        let markers = worker.recordedBatchMarkers
        #expect(markers.count == expectedDelivered)
        #expect(markers.first == 0)
        #expect(markers.last == Float(maximumQueued + 6) / 100)
        #expect(
            markers == [0] + (6 ... (maximumQueued + 5)).map { Float($0 + 1) / 100 }
        )

        engine.cancel(requestID: "req-backlog")
    }

    @Test("the worker is launched lazily unless eager warmup is opted in")
    func lazyWarmupIsTheDefault() {
        // 默认：构造引擎不拉起 worker（不加载 MLX 模型），首次会话才启动。
        let lazyWorker = StallingMLXQwen3Worker()
        let lazyEngine = MLXQwen3ASREngine(
            sourceFactory: RecordingPCMSourceFactory(),
            worker: lazyWorker
        )
        Thread.sleep(forTimeInterval: 0.15)
        #expect(lazyWorker.launchCount == 0)
        lazyEngine.start(makeRequest(
            requestID: "req-lazy",
            deadlineMilliseconds: 5_000
        )) { _ in }
        #expect(waitUntil { lazyWorker.launchCount == 1 })
        lazyEngine.cancel(requestID: "req-lazy")

        // 显式 opt-in：构造时就在后台预拉起 worker。
        let eagerWorker = StallingMLXQwen3Worker()
        let eagerEngine = MLXQwen3ASREngine(
            sourceFactory: RecordingPCMSourceFactory(),
            worker: eagerWorker,
            eagerWarmup: true
        )
        #expect(waitUntil { eagerWorker.launchCount == 1 })
        eagerEngine.cancel(requestID: "none")
    }

    @Test("tail samples are flushed before stop once the source has stopped")
    func flushesTailSamplesBeforeStop() {
        let worker = StallingMLXQwen3Worker()
        let factory = RecordingPCMSourceFactory()
        let engine = MLXQwen3ASREngine(
            sourceFactory: factory,
            worker: worker,
            eagerWarmup: false
        )
        let recorder = EngineEventRecorder()
        engine.start(makeRequest(
            requestID: "req-tail",
            deadlineMilliseconds: 5_000
        )) { event in
            recorder.append(event)
        }
        #expect(waitUntil { factory.lastSource?.isStarted == true })
        // 6 帧 = 1 整批 + 320 个采样的尾巴。
        for _ in 0 ..< 6 {
            factory.lastSource?.emitFrame(value: 0.2)
        }
        engine.stop(requestID: "req-tail")
        #expect(waitUntil { worker.recordedStopRequests == ["req-tail"] })
        #expect(factory.lastSource?.isStopped == true)

        // 先写整批（5 × 320 采样），再写 source 停止后补齐的尾批（320 采样），最后才是 stop。
        #expect(worker.recordedBatchSampleCounts == [
            VoicePCMFrame.samplesPerFrame * 5,
            VoicePCMFrame.samplesPerFrame,
        ])
        worker.emit(.final(
            requestID: "req-tail",
            text: "尾巴",
            confidence: 0.9,
            polishApplied: false
        ))
        #expect(waitUntil {
            recorder.snapshot.contains { if case .finished = $0 { return true }; return false }
        })
    }
}
