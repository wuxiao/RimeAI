import Foundation
import RimeAIInputCore

/// Offline Apple Silicon MLX Qwen3-ASR streaming engine with native hotword
/// context biasing and Layer-2 deterministic hotword restoration.
///
/// 并发模型：管道写入可能因 worker 停滞而无限阻塞，所以它被隔离在一条
/// 串行 `writerQueue` 上（单写者排空循环 + 有界音频积压）；麦克风 source 的
/// start / stop / cancel 与所有定时兜底走各自独立的队列，`stop()`、`cancel()`
/// 和收尾超时永远不会被停滞的 worker 拖住。
public final class MLXQwen3ASREngine: VoiceDictationEngine, @unchecked Sendable {
    public static let adapterDescriptor = VoiceEngineDescriptor.systemManagedProbe(
        adapterID: "mlx-qwen3-asr",
        adapterVersion: "1.0.0",
        supportedLocales: ["zh-CN", "en-US"],
        capabilities: [.localASR, .streaming, .hotwordSnapshot],
        networkPolicy: .offline,
        audioFormat: .fixedLinearPCM(
            sampleRateHertz: VoicePCMFrame.sampleRateHertz,
            channelCount: 1,
            bitsPerChannel: 32
        ),
        hotwordMode: .boundedPhraseList(
            maximumEntries: VoiceDictationConstants.maximumHotwordCount
        ),
        maximumAlternatives: 1
    )

    public var descriptor: VoiceEngineDescriptor {
        Self.adapterDescriptor
    }

    /// Batch 5 x 20ms frames (= 100ms = 1600 samples) per pipe write.
    private static let audioBatchSamples = VoicePCMFrame.samplesPerFrame * 5
    private static let workerReadyTimeoutSeconds: TimeInterval = 20
    /// `start` 迟迟写不进 worker（上一代 worker 堵死管道）时的会话启动兜底：
    /// 最长模型加载时间之外再给 5 秒。
    private static let sessionStartTimeoutSeconds = workerReadyTimeoutSeconds + 5

    /// 写入受阻时最多积压的音频批次（每批 100ms，20 批 = 2 秒）。超过后丢弃
    /// 最旧的音频：内存与延迟都有界，worker 恢复后也不会补发过期的声音。
    static let maximumQueuedAudioBatches = 20

    private final class SendableWorkItem: @unchecked Sendable {
        let item: DispatchWorkItem
        init(_ block: @escaping @Sendable () -> Void) {
            item = DispatchWorkItem(block: block)
        }
        func cancel() {
            item.cancel()
        }
    }

    /// 一次听写会话的全部可变状态；除 `source` 自身外都只在 `lock` 内读写。
    private final class ActiveSession: @unchecked Sendable {
        let requestID: String
        let generation: UInt64
        let sink: @Sendable (VoiceDictationEngineEvent) -> Void
        let source: any VoicePCMSource
        let deadlineMilliseconds: Int
        var isFinalizing = false
        var isClosed = false
        /// `start` 已成功写入 worker；在它之前绝不写音频或 stop。
        var hasSentStart = false
        /// `source.stop()` 已排队但尚未返回：期间仍接收尾部采样，返回后再补齐最后一批。
        var isSourceStopPending = false
        /// 未凑满一批的采样。
        var pendingSamples: [Float] = []
        /// 等待写入管道的完整批次（旧 → 新），上限 `maximumQueuedAudioBatches`。
        var queuedAudioBatches: [[Float]] = []
        /// 积压写空后发送 stop。
        var isStopRequested = false
        var lastPartialText = ""
        var maximumDurationWork: SendableWorkItem?
        var finalizationTimeoutWork: SendableWorkItem?
        var startTimeoutWork: SendableWorkItem?

        init(
            requestID: String,
            generation: UInt64,
            sink: @escaping @Sendable (VoiceDictationEngineEvent) -> Void,
            source: any VoicePCMSource,
            deadlineMilliseconds: Int
        ) {
            self.requestID = requestID
            self.generation = generation
            self.sink = sink
            self.source = source
            self.deadlineMilliseconds = deadlineMilliseconds
        }
    }

    /// 会话结束时需要收尾的资源（在 `lock` 内一次性取出）。
    private struct SessionTeardown: Sendable {
        let requestID: String
        let sink: @Sendable (VoiceDictationEngineEvent) -> Void
        let maximumDurationWork: SendableWorkItem?
        let finalizationTimeoutWork: SendableWorkItem?
        let startTimeoutWork: SendableWorkItem?

        func cancelTimers() {
            maximumDurationWork?.cancel()
            finalizationTimeoutWork?.cancel()
            startTimeoutWork?.cancel()
        }
    }

    private let sourceFactory: any VoicePCMSourceFactory
    private let worker: any MLXQwen3ASRWorkerControlling
    private let lock = NSLock()
    /// 唯一调用 `worker.send*` 的串行队列。写入可能卡在停滞的 worker 上，
    /// 但只会卡住这条队列。
    private let writerQueue = DispatchQueue(
        label: "fun.wwcn.rimeai.voice-helper.mlx-qwen3-asr.writer",
        qos: .userInitiated
    )
    /// 只执行麦克风 source 的 start / stop / cancel，从不写管道，所以不会被
    /// 停滞的 worker 拖住。
    private let lifecycleQueue = DispatchQueue(
        label: "fun.wwcn.rimeai.voice-helper.mlx-qwen3-asr.lifecycle",
        qos: .userInitiated
    )
    /// 会话启动序列（拉起 worker、等 ready、写 start）。与 lifecycleQueue 分开：
    /// 冷启动最长 20 秒的模型加载不会推迟 stop / cancel。
    private let bootstrapQueue = DispatchQueue(
        label: "fun.wwcn.rimeai.voice-helper.mlx-qwen3-asr.bootstrap",
        qos: .userInitiated
    )
    /// 定时兜底（最长时长、收尾超时、启动超时）。独立队列，永不被管道写入阻塞。
    private let timerQueue = DispatchQueue(
        label: "fun.wwcn.rimeai.voice-helper.mlx-qwen3-asr.timers",
        qos: .userInitiated
    )
    private var generation: UInt64 = 0
    private var activeSession: ActiveSession?
    /// 单写者标记：至多一个排空循环在 writerQueue 上运行。
    private var isWriterDraining = false
    private var totalDroppedAudioBatches = 0

    /// 默认惰性预热：helper 启动时不加载 MLX 模型，首次会话才拉起 worker。
    public convenience init(
        serviceScriptPath: String? = nil,
        modelDirectoryPath: String? = nil
    ) {
        let worker = SubprocessMLXQwen3ASRWorker(
            serviceScriptPath: serviceScriptPath
                ?? SubprocessMLXQwen3ASRWorker.defaultServiceScriptPath(),
            modelDirectoryPath: modelDirectoryPath
                ?? ProcessInfo.processInfo.environment["RIMEAI_VOICE_MLX_MODEL_DIR"]
        )
        self.init(
            sourceFactory: AVAudioEnginePCMSourceFactory(),
            worker: worker,
            eagerWarmup: false
        )
    }

    /// - Parameter eagerWarmup: 显式 opt-in 时在后台预拉起 worker；默认关闭。
    init(
        sourceFactory: any VoicePCMSourceFactory,
        worker: any MLXQwen3ASRWorkerControlling,
        eagerWarmup: Bool = false
    ) {
        self.sourceFactory = sourceFactory
        self.worker = worker
        if eagerWarmup {
            bootstrapQueue.async { [weak self] in
                guard let self else { return }
                try? self.worker.startIfNeeded { [weak self] event in
                    self?.handleWorkerEvent(event)
                }
            }
        }
    }

    deinit {
        worker.shutdown()
    }

    /// 因写入积压超限而丢弃的音频批次数（每批 100ms）。
    var droppedAudioBatchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalDroppedAudioBatches
    }

    // MARK: - Session Control

    public func start(
        _ request: VoiceDictationEngineRequest,
        events: @escaping @Sendable (VoiceDictationEngineEvent) -> Void
    ) {
        let source: any VoicePCMSource
        do {
            source = try sourceFactory.makeSource()
        } catch {
            events(.failed(.micUnavailable, retryable: false))
            return
        }

        lock.lock()
        guard activeSession == nil else {
            lock.unlock()
            events(.failed(.asrOverload, retryable: true))
            return
        }
        generation &+= 1
        let sessionGeneration = generation
        let clampedDeadline = max(
            VoiceDictationConstants.minimumDeadlineMilliseconds,
            min(
                request.deadlineMilliseconds,
                VoiceDictationConstants.maximumDeadlineMilliseconds
            )
        )
        let session = ActiveSession(
            requestID: request.requestID,
            generation: sessionGeneration,
            sink: events,
            source: source,
            deadlineMilliseconds: clampedDeadline
        )
        if request.maximumDurationMilliseconds > 0 {
            let maxDurationWork = SendableWorkItem { [weak self] in
                self?.stop(requestID: request.requestID)
            }
            session.maximumDurationWork = maxDurationWork
            let maxDurationSeconds =
                Double(request.maximumDurationMilliseconds) / 1_000.0
            timerQueue.asyncAfter(
                deadline: .now() + maxDurationSeconds,
                execute: maxDurationWork.item
            )
        }
        let startTimeoutWork = SendableWorkItem { [weak self] in
            self?.handleStartTimeout(generation: sessionGeneration)
        }
        session.startTimeoutWork = startTimeoutWork
        timerQueue.asyncAfter(
            deadline: .now() + Self.sessionStartTimeoutSeconds,
            execute: startTimeoutWork.item
        )
        activeSession = session
        lock.unlock()

        let hotwords = request.hotwordSnapshot.phrases
        bootstrapQueue.async { [weak self] in
            self?.bootstrapSession(
                generation: sessionGeneration,
                requestID: request.requestID,
                hotwords: hotwords
            )
        }
    }

    /// 在 bootstrapQueue 上运行：拉起 worker、等待就绪，再把 `start` 交给
    /// writerQueue 串行写入。这里不碰麦克风 source。
    private func bootstrapSession(
        generation sessionGeneration: UInt64,
        requestID: String,
        hotwords: [String]
    ) {
        do {
            try worker.startIfNeeded { [weak self] event in
                self?.handleWorkerEvent(event)
            }
            guard worker.waitUntilReady(
                timeoutSeconds: Self.workerReadyTimeoutSeconds
            ) else {
                failSession(
                    generation: sessionGeneration,
                    code: .asrEngineError,
                    retryable: true
                )
                return
            }
            guard isSessionActive(
                generation: sessionGeneration,
                allowFinalizing: false
            ) else {
                return
            }
            writerQueue.async { [weak self] in
                self?.writeSessionStart(
                    generation: sessionGeneration,
                    requestID: requestID,
                    hotwords: hotwords
                )
            }
        } catch {
            failSession(
                generation: sessionGeneration,
                code: .asrEngineError,
                retryable: true
            )
        }
    }

    /// 在 writerQueue 上运行：写入 `start`，成功后启动麦克风。
    private func writeSessionStart(
        generation sessionGeneration: UInt64,
        requestID: String,
        hotwords: [String]
    ) {
        lock.lock()
        guard let session = activeSession,
              session.generation == sessionGeneration,
              !session.isClosed,
              !session.hasSentStart
        else {
            lock.unlock()
            return
        }
        lock.unlock()

        do {
            try worker.sendStart(requestID: requestID, hotwords: hotwords)
        } catch {
            failSession(
                generation: sessionGeneration,
                code: .asrEngineError,
                retryable: true
            )
            return
        }

        lock.lock()
        // 写 start 期间会话可能已被 stop / cancel。
        guard activeSession === session, !session.isClosed else {
            lock.unlock()
            return
        }
        session.hasSentStart = true
        session.startTimeoutWork?.cancel()
        session.startTimeoutWork = nil
        // 检查与入队在同一把锁内：随后的 stop() 只会排在 source.start 之后。
        let shouldStartSource = !session.isFinalizing
        if shouldStartSource {
            lifecycleQueue.async { [weak self] in
                self?.startSource(session, generation: sessionGeneration)
            }
        }
        kickWriterLocked()
        lock.unlock()
    }

    /// 在 lifecycleQueue 上运行。
    private func startSource(_ session: ActiveSession, generation: UInt64) {
        do {
            try session.source.start(
                onFrame: { [weak self] frame in
                    self?.ingestAudioFrame(frame, generation: generation)
                },
                onFailure: { [weak self] failure in
                    self?.failSession(
                        generation: generation,
                        code: failure.code,
                        retryable: failure.retryable
                    )
                }
            )
        } catch {
            failSession(
                generation: generation,
                code: .micUnavailable,
                retryable: false
            )
        }
    }

    public func stop(requestID: String) {
        lock.lock()
        guard let session = activeSession,
              session.requestID == requestID,
              !session.isClosed,
              !session.isFinalizing
        else {
            lock.unlock()
            return
        }
        session.isFinalizing = true
        let sessionGeneration = session.generation
        session.maximumDurationWork?.cancel()
        session.maximumDurationWork = nil
        let deadlineMilliseconds = session.deadlineMilliseconds
        let timeoutWork = SendableWorkItem { [weak self] in
            self?.handleFinalizationTimeout(generation: sessionGeneration)
        }
        session.finalizationTimeoutWork = timeoutWork
        session.isStopRequested = true
        session.isSourceStopPending = true
        // source.stop() 可能要等转换积压（数百毫秒），放到 lifecycleQueue；它不写管道。
        lifecycleQueue.async { [weak self] in
            session.source.stop()
            self?.finishSourceStop(session)
        }
        kickWriterLocked()
        // 收尾超时从此刻起算：与管道是否拥堵、source.stop() 是否耗时无关，
        // 所以 stop() 之后一定会结束。
        timerQueue.asyncAfter(
            deadline: .now() + Double(deadlineMilliseconds) / 1_000.0,
            execute: timeoutWork.item
        )
        lock.unlock()
    }

    /// 在 lifecycleQueue 上运行：source 已停，补齐最后一批采样，允许写 stop。
    private func finishSourceStop(_ session: ActiveSession) {
        lock.lock()
        defer { lock.unlock() }
        guard activeSession === session, !session.isClosed else { return }
        session.isSourceStopPending = false
        if !session.pendingSamples.isEmpty {
            enqueueAudioBatchLocked(session, batch: session.pendingSamples)
            session.pendingSamples.removeAll(keepingCapacity: false)
        }
        kickWriterLocked()
    }

    public func cancel(requestID: String) {
        lock.lock()
        guard let session = activeSession,
              session.requestID == requestID
        else {
            lock.unlock()
            return
        }
        let teardown = retireSessionLocked(session)
        lock.unlock()

        teardown.cancelTimers()
        lifecycleQueue.async { session.source.cancel() }
        // 取消消息排在在途音频之后；即使 writer 被停滞的 worker 卡住，会话也已结束。
        writerQueue.async { [weak self] in
            self?.worker.sendCancel(requestID: requestID)
        }
    }

    // MARK: - Audio & Worker Event Handling

    /// 在 source 的回调队列上运行：只做有界入队，从不写管道、从不阻塞。
    private func ingestAudioFrame(
        _ frame: VoicePCMFrame,
        generation expectedGeneration: UInt64
    ) {
        lock.lock()
        guard let session = activeSession,
              session.generation == expectedGeneration,
              !session.isClosed,
              session.hasSentStart,
              // 收尾期间在 source.stop() 返回前继续接收尾部采样，返回后丢弃。
              !session.isFinalizing || session.isSourceStopPending
        else {
            lock.unlock()
            return
        }
        session.pendingSamples.append(contentsOf: frame.samples)
        if session.pendingSamples.count >= Self.audioBatchSamples {
            let batch = session.pendingSamples
            session.pendingSamples.removeAll(keepingCapacity: true)
            enqueueAudioBatchLocked(session, batch: batch)
        }
        kickWriterLocked()
        lock.unlock()
    }

    /// 调用方持 `lock`。积压超过上限时丢弃最旧的音频。
    private func enqueueAudioBatchLocked(
        _ session: ActiveSession,
        batch: [Float]
    ) {
        session.queuedAudioBatches.append(batch)
        while session.queuedAudioBatches.count > Self.maximumQueuedAudioBatches {
            session.queuedAudioBatches.removeFirst()
            totalDroppedAudioBatches += 1
        }
    }

    /// 调用方持 `lock`：保证至多一个排空循环在 writerQueue 上运行。
    private func kickWriterLocked() {
        guard !isWriterDraining else { return }
        isWriterDraining = true
        writerQueue.async { [weak self] in
            self?.drainWriter()
        }
    }

    /// 在 writerQueue 上运行的单写者排空循环。只有这一个线程会写 worker 管道：
    /// 音频 → （source 停止后）stop。一次写卡住时后续批次留在有界积压里。
    private func drainWriter() {
        while true {
            lock.lock()
            guard let session = activeSession,
                  !session.isClosed,
                  session.hasSentStart
            else {
                isWriterDraining = false
                lock.unlock()
                return
            }
            if let batch = session.queuedAudioBatches.first {
                session.queuedAudioBatches.removeFirst()
                let requestID = session.requestID
                let sessionGeneration = session.generation
                lock.unlock()
                do {
                    try worker.sendAudio(requestID: requestID, samples: batch)
                } catch {
                    failSession(
                        generation: sessionGeneration,
                        code: .asrEngineError,
                        retryable: true
                    )
                }
                continue
            }
            // stop 必须排在全部音频之后，且等 source 真正停止。
            guard session.isStopRequested, !session.isSourceStopPending else {
                isWriterDraining = false
                lock.unlock()
                return
            }
            session.isStopRequested = false
            let requestID = session.requestID
            let sessionGeneration = session.generation
            lock.unlock()
            do {
                try worker.sendStop(requestID: requestID)
            } catch {
                failSession(
                    generation: sessionGeneration,
                    code: .asrEngineError,
                    retryable: true
                )
            }
        }
    }

    private func handleWorkerEvent(_ event: MLXQwen3ASRWorkerEvent) {
        switch event {
        case .ready:
            return
        case let .partial(requestID, stableText, partialText, confidence):
            lock.lock()
            guard let session = activeSession,
                  session.requestID == requestID,
                  !session.isClosed,
                  !session.isFinalizing
            else {
                lock.unlock()
                return
            }
            let combined = stableText + partialText
            guard !combined.isEmpty else {
                lock.unlock()
                return
            }
            session.lastPartialText = combined
            let sink = session.sink
            lock.unlock()
            sink(.partial(
                stableText: stableText,
                partialText: partialText,
                confidence: confidence
            ))

        case let .final(requestID, text, confidence, polishApplied):
            lock.lock()
            guard let session = activeSession,
                  session.requestID == requestID,
                  !session.isClosed
            else {
                lock.unlock()
                return
            }
            let resolvedText = text.isEmpty ? session.lastPartialText : text
            let teardown = retireSessionLocked(session)
            lock.unlock()

            teardown.cancelTimers()
            if resolvedText.isEmpty {
                teardown.sink(.failed(.asrTimeout, retryable: true))
            } else {
                teardown.sink(.finished(
                    text: resolvedText,
                    confidence: confidence,
                    polishApplied: polishApplied
                ))
            }

        case let .error(requestID, code):
            lock.lock()
            let matchingGeneration = activeSession?.requestID == requestID
                ? activeSession?.generation
                : nil
            lock.unlock()
            if let matchingGeneration {
                failSession(
                    generation: matchingGeneration,
                    code: code,
                    retryable: true
                )
            }

        case .terminated:
            lock.lock()
            let matchingGeneration = activeSession?.generation
            lock.unlock()
            if let matchingGeneration {
                failSession(
                    generation: matchingGeneration,
                    code: .asrEngineError,
                    retryable: true
                )
            }
        }
    }

    /// 收尾超时：worker 在 deadline 内没有返回 final，用最后一个 partial 结束。
    /// 运行在 timerQueue 上，不依赖 writerQueue，所以管道被堵死也一定会触发。
    private func handleFinalizationTimeout(generation expectedGeneration: UInt64) {
        lock.lock()
        guard let session = activeSession,
              session.generation == expectedGeneration,
              !session.isClosed
        else {
            lock.unlock()
            return
        }
        let fallbackText = session.lastPartialText
        let teardown = retireSessionLocked(session)
        lock.unlock()

        teardown.cancelTimers()
        writerQueue.async { [weak self] in
            self?.worker.sendCancel(requestID: teardown.requestID)
        }
        if !fallbackText.isEmpty {
            teardown.sink(.finished(
                text: fallbackText,
                confidence: 0.75,
                polishApplied: false
            ))
        } else {
            teardown.sink(.failed(.asrTimeout, retryable: true))
        }
    }

    /// 启动兜底：`start` 迟迟写不进 worker（管道被上一代 worker 堵死）。
    private func handleStartTimeout(generation expectedGeneration: UInt64) {
        lock.lock()
        guard let session = activeSession,
              session.generation == expectedGeneration,
              !session.isClosed,
              !session.hasSentStart
        else {
            lock.unlock()
            return
        }
        lock.unlock()
        failSession(
            generation: expectedGeneration,
            code: .asrEngineError,
            retryable: true
        )
    }

    private func failSession(
        generation expectedGeneration: UInt64,
        code: VoiceDictationErrorCode,
        retryable: Bool
    ) {
        lock.lock()
        guard let session = activeSession,
              session.generation == expectedGeneration,
              !session.isClosed
        else {
            lock.unlock()
            return
        }
        let teardown = retireSessionLocked(session)
        lock.unlock()

        teardown.cancelTimers()
        lifecycleQueue.async { session.source.cancel() }
        writerQueue.async { [weak self] in
            self?.worker.sendCancel(requestID: teardown.requestID)
        }
        teardown.sink(.failed(code, retryable: retryable))
    }

    /// 调用方持 `lock`：把会话置为已结束并取回需要收尾的资源。
    private func retireSessionLocked(_ session: ActiveSession) -> SessionTeardown {
        session.isClosed = true
        session.pendingSamples.removeAll(keepingCapacity: false)
        session.queuedAudioBatches.removeAll(keepingCapacity: false)
        session.isStopRequested = false
        session.isSourceStopPending = false
        if activeSession === session {
            activeSession = nil
        }
        let teardown = SessionTeardown(
            requestID: session.requestID,
            sink: session.sink,
            maximumDurationWork: session.maximumDurationWork,
            finalizationTimeoutWork: session.finalizationTimeoutWork,
            startTimeoutWork: session.startTimeoutWork
        )
        session.maximumDurationWork = nil
        session.finalizationTimeoutWork = nil
        session.startTimeoutWork = nil
        return teardown
    }

    private func isSessionActive(
        generation expectedGeneration: UInt64,
        allowFinalizing: Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let session = activeSession,
              session.generation == expectedGeneration,
              !session.isClosed
        else {
            return false
        }
        return allowFinalizing || !session.isFinalizing
    }
}
