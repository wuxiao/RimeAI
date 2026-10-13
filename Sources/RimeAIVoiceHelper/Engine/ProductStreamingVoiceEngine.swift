import Foundation
import RimeAIInputCore

typealias ProductStreamingVoiceScheduledCancellation = @Sendable () -> Void
typealias ProductStreamingVoiceScheduler = @Sendable (
    _ milliseconds: Int,
    _ operation: @escaping @Sendable () -> Void
) -> ProductStreamingVoiceScheduledCancellation

private final class ProductStreamingVoiceDispatchTimeout:
    @unchecked Sendable
{
    let workItem: DispatchWorkItem

    init(operation: @escaping @Sendable () -> Void) {
        workItem = DispatchWorkItem(block: operation)
    }

    func cancel() {
        workItem.cancel()
    }
}

public enum ProductStreamingVoiceEngineError: Error, Equatable, Sendable {
    case invalidDescriptor
    case artifactGenerationMismatch
}

/// Product-managed streaming ASR engine. Runtime/model loading remains outside
/// this type; callers must inject a descriptor produced from a verified lease,
/// a per-session PCM source factory, and the already-loaded recognizer driver.
public final class ProductStreamingVoiceEngine: VoiceDictationEngine,
    @unchecked Sendable
{
    public static let maximumBufferedFrames = 100
    public static let maximumHotwordUTF8Bytes = 128

    private final class EventChannel: @unchecked Sendable {
        private enum State {
            case active
            case finished
            case invalidated
        }

        private let lock = NSLock()
        private let sink: @Sendable (VoiceDictationEngineEvent) -> Void
        private var state = State.active

        init(sink: @escaping @Sendable (VoiceDictationEngineEvent) -> Void) {
            self.sink = sink
        }

        func emit(_ event: VoiceDictationEngineEvent) {
            lock.lock()
            guard state == .active else {
                lock.unlock()
                return
            }
            lock.unlock()
            // Never invoke product-external code while holding the admission
            // lock. An emit already admitted before invalidate may finish, but
            // no later emit can enter the sink.
            sink(event)
        }

        func finish(_ event: VoiceDictationEngineEvent) {
            lock.lock()
            guard state == .active else {
                lock.unlock()
                return
            }
            state = .finished
            lock.unlock()
            sink(event)
        }

        func invalidate() {
            lock.lock()
            state = .invalidated
            lock.unlock()
        }
    }

    /// Serializes the three synchronous source commands without holding the
    /// engine state lock. Stop/cancel revoke the start permit before waiting for
    /// the command queue, so a command that has not entered `source.start` can
    /// never do so afterwards. A cancel that races an in-flight start is applied
    /// before the cancelling caller returns.
    private final class SourceLifecycle: @unchecked Sendable {
        enum StartOutcome {
            case started
            case skipped
            case failed
        }

        private enum Disposition {
            case accepting
            case stopping
            case cancelled
        }

        let source: any VoicePCMSource
        private let lock = NSLock()
        private let commandQueue: DispatchQueue
        private let commandQueueKey = DispatchSpecificKey<UInt8>()
        private let callbackMarkerKey: String
        private var disposition = Disposition.accepting
        private var isInvokingSource = false
        private var didStop = false
        private var didCancel = false
        private var cancelCompletions: [@Sendable () -> Void] = []

        init(source: any VoicePCMSource, generation: UInt64) {
            self.source = source
            callbackMarkerKey =
                "fun.wwcn.rimeai.voice-helper.product-source-callback.\(generation).\(UUID().uuidString)"
            commandQueue = DispatchQueue(
                label: "fun.wwcn.rimeai.voice-helper.product-source.\(generation)"
            )
            commandQueue.setSpecific(key: commandQueueKey, value: 1)
        }

        func start(
            onFrame: @escaping @Sendable (VoicePCMFrame) -> Void,
            onFailure: @escaping @Sendable (VoicePCMSourceFailure) -> Void
        ) -> StartOutcome {
            runSynchronously {
                self.lock.lock()
                guard self.disposition == .accepting else {
                    self.lock.unlock()
                    return .skipped
                }
                self.isInvokingSource = true
                self.lock.unlock()

                let failed: Bool
                do {
                    try self.source.start(
                        onFrame: { [weak self] frame in
                            self?.invokeSourceCallback {
                                onFrame(frame)
                            }
                        },
                        onFailure: { [weak self] failure in
                            self?.invokeSourceCallback {
                                onFailure(failure)
                            }
                        }
                    )
                    failed = false
                } catch {
                    failed = true
                }

                self.lock.lock()
                self.isInvokingSource = false
                let remainsAccepting = self.disposition == .accepting
                let mustCancel = self.disposition == .cancelled
                self.lock.unlock()
                if mustCancel {
                    self.applyCancelIfNeeded()
                }
                guard remainsAccepting else { return .skipped }
                return failed ? .failed : .started
            }
        }

        func stop() {
            lock.lock()
            if disposition == .accepting {
                disposition = .stopping
            }
            let shouldStop = disposition == .stopping
            lock.unlock()
            guard shouldStop else { return }

            runSynchronously {
                self.lock.lock()
                guard self.disposition == .stopping, !self.didStop else {
                    self.lock.unlock()
                    return
                }
                self.didStop = true
                self.isInvokingSource = true
                self.lock.unlock()
                self.source.stop()
                self.lock.lock()
                self.isInvokingSource = false
                let mustCancel = self.disposition == .cancelled
                self.lock.unlock()
                if mustCancel {
                    self.applyCancelIfNeeded()
                }
            }
        }

        func cancel(
            onApplied: @escaping @Sendable () -> Void = {}
        ) {
            let isSourceCallbackReentry = isInsideSourceCallback
            lock.lock()
            disposition = .cancelled
            if didCancel {
                lock.unlock()
                onApplied()
                return
            }
            cancelCompletions.append(onApplied)
            let mustDefer = isOnCommandQueue && isInvokingSource
            lock.unlock()
            guard !mustDefer else { return }
            if isSourceCallbackReentry {
                commandQueue.async { [weak self] in
                    self?.applyCancelIfNeeded()
                }
                return
            }
            runSynchronously {
                self.applyCancelIfNeeded()
            }
        }

        private func applyCancelIfNeeded() {
            lock.lock()
            guard disposition == .cancelled, !didCancel else {
                lock.unlock()
                return
            }
            didCancel = true
            isInvokingSource = true
            lock.unlock()
            source.cancel()
            lock.lock()
            isInvokingSource = false
            let completions = cancelCompletions
            cancelCompletions.removeAll(keepingCapacity: false)
            lock.unlock()
            completions.forEach { $0() }
        }

        private var isOnCommandQueue: Bool {
            DispatchQueue.getSpecific(key: commandQueueKey) == 1
        }

        private var isInsideSourceCallback: Bool {
            Thread.current.threadDictionary[callbackMarkerKey] != nil
        }

        private func invokeSourceCallback(
            _ callback: () -> Void
        ) {
            let dictionary = Thread.current.threadDictionary
            let previousMarker = dictionary[callbackMarkerKey]
            dictionary[callbackMarkerKey] = true
            defer {
                if let previousMarker {
                    dictionary[callbackMarkerKey] = previousMarker
                } else {
                    dictionary.removeObject(forKey: callbackMarkerKey)
                }
            }
            callback()
        }

        private func runSynchronously<T>(_ operation: () -> T) -> T {
            if isOnCommandQueue {
                return operation()
            }
            return commandQueue.sync(execute: operation)
        }
    }

    private final class ResetCompletion: @unchecked Sendable {
        enum Outcome {
            case ready
            case stale
            case failed
        }

        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var outcome: Outcome?

        func complete(_ outcome: Outcome) {
            lock.lock()
            guard self.outcome == nil else {
                lock.unlock()
                return
            }
            self.outcome = outcome
            lock.unlock()
            semaphore.signal()
        }

        func wait() -> Outcome {
            semaphore.wait()
            lock.lock()
            defer { lock.unlock() }
            return outcome ?? .stale
        }
    }

    private struct Preparation {
        let requestID: String
        let generation: UInt64
        let channel: EventChannel
        var stopRequested = false
    }

    private final class Session: @unchecked Sendable {
        enum Phase {
            case accepting
            case stopping
            case finalizing
        }

        struct PartialPayload: Equatable {
            let stableText: String
            let partialText: String
        }

        let request: VoiceDictationEngineRequest
        let generation: UInt64
        let channel: EventChannel
        let sourceLifecycle: SourceLifecycle
        let hotwords: [String]
        var phase = Phase.accepting
        var bufferedFrames: [VoicePCMFrame] = []
        var isDrainScheduled = false
        var stableText = ""
        var currentPartialText = ""
        var lastEmittedPartial: PartialPayload?
        var maximumDurationCancellation:
            ProductStreamingVoiceScheduledCancellation?
        var finalDeadlineCancellation:
            ProductStreamingVoiceScheduledCancellation?

        init(
            request: VoiceDictationEngineRequest,
            generation: UInt64,
            channel: EventChannel,
            sourceLifecycle: SourceLifecycle,
            hotwords: [String]
        ) {
            self.request = request
            self.generation = generation
            self.channel = channel
            self.sourceLifecycle = sourceLifecycle
            self.hotwords = hotwords
        }
    }

    public let descriptor: VoiceEngineDescriptor

    private let sourceFactory: any VoicePCMSourceFactory
    private let recognizerDriver: any VoiceStreamingRecognizerDriver
    private let hotwordProvider: any VoiceHotwordProviding
    private let scheduleAfterMilliseconds: ProductStreamingVoiceScheduler
    private let lock = NSLock()
    private let decoderQueue = DispatchQueue(
        label: "fun.wwcn.rimeai.voice-helper.product-streaming.decoder"
    )
    private let decoderQueueKey = DispatchSpecificKey<UInt8>()
    /// Couples lifecycle mutation with enqueue order of reset/cancel commands.
    /// It is never held while waiting for decoder work or source callbacks.
    private let driverCommandLock = NSLock()
    private var generation: UInt64 = 0
    private var preparation: Preparation?
    private var session: Session?
    /// Decoder-queue confined; never read or written from another queue.
    private var driverGeneration: UInt64?

    convenience init(
        descriptor: VoiceEngineDescriptor,
        sourceFactory: any VoicePCMSourceFactory,
        recognizerDriver: any VoiceStreamingRecognizerDriver,
        hotwordProvider: any VoiceHotwordProviding
    ) throws {
        try self.init(
            descriptor: descriptor,
            sourceFactory: sourceFactory,
            recognizerDriver: recognizerDriver,
            hotwordProvider: hotwordProvider,
            scheduleAfterMilliseconds: { milliseconds, operation in
                let timeout = ProductStreamingVoiceDispatchTimeout(
                    operation: operation
                )
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + .milliseconds(milliseconds),
                    execute: timeout.workItem
                )
                return { timeout.cancel() }
            }
        )
    }

    init(
        descriptor: VoiceEngineDescriptor,
        sourceFactory: any VoicePCMSourceFactory,
        recognizerDriver: any VoiceStreamingRecognizerDriver,
        hotwordProvider: any VoiceHotwordProviding,
        scheduleAfterMilliseconds: @escaping ProductStreamingVoiceScheduler
    ) throws {
        guard Self.accepts(descriptor) else {
            throw ProductStreamingVoiceEngineError.invalidDescriptor
        }
        guard descriptor.artifactGeneration
            == recognizerDriver.artifactGeneration
        else {
            throw ProductStreamingVoiceEngineError
                .artifactGenerationMismatch
        }
        self.descriptor = descriptor
        self.sourceFactory = sourceFactory
        self.recognizerDriver = recognizerDriver
        self.hotwordProvider = hotwordProvider
        self.scheduleAfterMilliseconds = scheduleAfterMilliseconds
        decoderQueue.setSpecific(key: decoderQueueKey, value: 1)
    }

    public func start(
        _ request: VoiceDictationEngineRequest,
        events: @escaping @Sendable (VoiceDictationEngineEvent) -> Void
    ) {
        let channel = EventChannel(sink: events)
        lock.lock()
        guard preparation == nil, session == nil else {
            lock.unlock()
            channel.finish(.failed(.asrOverload, retryable: true))
            return
        }
        generation &+= 1
        let sessionGeneration = generation
        preparation = Preparation(
            requestID: request.requestID,
            generation: sessionGeneration,
            channel: channel
        )
        lock.unlock()

        let hotwords: [String]
        do {
            let snapshot = try hotwordProvider.snapshot(
                for: request,
                maximumEntries: maximumHotwords
            )
            guard snapshot.isValid,
                  snapshot.phrases.count <= maximumHotwords
            else {
                throw ProductStreamingVoiceEngineError.invalidDescriptor
            }
            let normalized = Self.normalizedHotwords(
                snapshot.phrases,
                maximumEntries: maximumHotwords
            )
            guard normalized == snapshot.phrases else {
                throw ProductStreamingVoiceEngineError.invalidDescriptor
            }
            hotwords = normalized
        } catch {
            failPreparation(
                generation: sessionGeneration,
                channel: channel,
                code: .asrEngineError
            )
            return
        }

        let source: any VoicePCMSource
        do {
            source = try sourceFactory.makeSource()
        } catch {
            failPreparation(
                generation: sessionGeneration,
                channel: channel,
                code: .micUnavailable
            )
            return
        }

        let sourceLifecycle = SourceLifecycle(
            source: source,
            generation: sessionGeneration
        )
        let newSession = Session(
            request: request,
            generation: sessionGeneration,
            channel: channel,
            sourceLifecycle: sourceLifecycle,
            hotwords: hotwords
        )
        let resetCompletion = ResetCompletion()
        driverCommandLock.lock()
        lock.lock()
        guard let currentPreparation = preparation,
              currentPreparation.generation == sessionGeneration
        else {
            lock.unlock()
            driverCommandLock.unlock()
            sourceLifecycle.cancel()
            return
        }
        let stopWasRequested = currentPreparation.stopRequested
        preparation = nil
        session = newSession
        let resetOperation: @Sendable () -> Void = { [weak self] in
            guard let self else {
                resetCompletion.complete(.stale)
                return
            }
            self.lock.lock()
            let isCurrent = self.session?.generation == sessionGeneration
            self.lock.unlock()
            guard isCurrent else {
                resetCompletion.complete(.stale)
                return
            }
            do {
                try self.recognizerDriver.startSession(hotwords: hotwords)
                self.driverGeneration = sessionGeneration
                self.lock.lock()
                let remainsCurrent =
                    self.session?.generation == sessionGeneration
                self.lock.unlock()
                resetCompletion.complete(remainsCurrent ? .ready : .stale)
            } catch {
                // reset may have partially initialized the native stream.
                self.recognizerDriver.cancel()
                self.driverGeneration = nil
                resetCompletion.complete(.failed)
            }
        }
        let resetInline = isOnDecoderQueue
        if !resetInline {
            decoderQueue.async(execute: resetOperation)
        }
        lock.unlock()
        driverCommandLock.unlock()
        if resetInline {
            resetOperation()
        }

        switch resetCompletion.wait() {
        case .ready:
            break
        case .stale:
            return
        case .failed:
            failSession(
                generation: sessionGeneration,
                code: .asrEngineError,
                retryable: true
            )
            return
        }

        if stopWasRequested {
            beginStop(
                requestID: request.requestID,
                expectedGeneration: sessionGeneration
            )
        }

        lock.lock()
        let shouldStart = session?.generation == sessionGeneration
            && session?.phase == .accepting
        lock.unlock()
        guard shouldStart else { return }

        let sourceStartOutcome = sourceLifecycle.start(
            onFrame: { [weak self] frame in
                self?.receive(frame, generation: sessionGeneration)
            },
            onFailure: { [weak self] failure in
                self?.sourceFailed(
                    failure,
                    generation: sessionGeneration
                )
            }
        )
        switch sourceStartOutcome {
        case .started:
            break
        case .skipped:
            return
        case .failed:
            failSession(
                generation: sessionGeneration,
                code: .micUnavailable,
                retryable: true
            )
            return
        }

        scheduleMaximumDuration(
            request.maximumDurationMilliseconds,
            generation: sessionGeneration,
            requestID: request.requestID
        )
    }

    public func stop(requestID: String) {
        beginStop(requestID: requestID, expectedGeneration: nil)
    }

    private func beginStop(
        requestID: String,
        expectedGeneration: UInt64?
    ) {
        lock.lock()
        if var preparation,
           preparation.requestID == requestID,
           (expectedGeneration == nil
                || preparation.generation == expectedGeneration)
        {
            preparation.stopRequested = true
            self.preparation = preparation
            lock.unlock()
            return
        }
        guard let session, session.request.requestID == requestID,
              session.phase == .accepting,
              expectedGeneration == nil
                || session.generation == expectedGeneration
        else {
            lock.unlock()
            return
        }
        session.phase = .stopping
        let expectedGeneration = session.generation
        let sourceLifecycle = session.sourceLifecycle
        let maximumDurationCancellation =
            session.maximumDurationCancellation
        session.maximumDurationCancellation = nil
        lock.unlock()

        maximumDurationCancellation?()

        // The source contract permits stop() to synchronously flush a padded
        // tail frame. Keep the session in `.stopping` until it returns so that
        // tail enters the same bounded FIFO before finish is queued.
        sourceLifecycle.stop()

        lock.lock()
        guard let current = self.session,
              current.generation == expectedGeneration,
              current.phase == .stopping
        else {
            lock.unlock()
            return
        }
        current.phase = .finalizing
        let deadlineMilliseconds = max(
            VoiceDictationConstants.minimumDeadlineMilliseconds,
            min(
                current.request.deadlineMilliseconds,
                VoiceDictationConstants.maximumDeadlineMilliseconds
            )
        )
        lock.unlock()

        let finalDeadlineCancellation = scheduleAfterMilliseconds(
            deadlineMilliseconds
        ) { [weak self] in
            self?.finalDeadlineReached(generation: expectedGeneration)
        }
        lock.lock()
        let shouldKeepDeadline: Bool
        if let latest = self.session,
           latest.generation == expectedGeneration,
           latest.phase == .finalizing
        {
            latest.finalDeadlineCancellation = finalDeadlineCancellation
            shouldKeepDeadline = true
        } else {
            shouldKeepDeadline = false
        }
        lock.unlock()
        if !shouldKeepDeadline {
            finalDeadlineCancellation()
            return
        }

        decoderQueue.async { [weak self] in
            self?.finishSession(generation: expectedGeneration)
        }
    }

    public func cancel(requestID: String) {
        driverCommandLock.lock()
        lock.lock()
        if let preparation, preparation.requestID == requestID {
            self.preparation = nil
            generation &+= 1
            lock.unlock()
            driverCommandLock.unlock()
            preparation.channel.invalidate()
            return
        }
        guard let session, session.request.requestID == requestID else {
            lock.unlock()
            driverCommandLock.unlock()
            return
        }
        self.session = nil
        generation &+= 1
        session.bufferedFrames.removeAll(keepingCapacity: false)
        let maximumDurationCancellation =
            session.maximumDurationCancellation
        let finalDeadlineCancellation = session.finalDeadlineCancellation
        session.maximumDurationCancellation = nil
        session.finalDeadlineCancellation = nil
        let isDecoderQueue = isOnDecoderQueue
        let sourceCancelledGate: DispatchSemaphore?
        if isDecoderQueue {
            sourceCancelledGate = nil
        } else {
            let gate = DispatchSemaphore(value: 0)
            sourceCancelledGate = gate
            enqueueDriverCancel(
                generation: session.generation,
                after: gate
            )
        }
        lock.unlock()

        if !isDecoderQueue {
            driverCommandLock.unlock()
        }

        session.channel.invalidate()
        maximumDurationCancellation?()
        finalDeadlineCancellation?()
        if isDecoderQueue {
            session.sourceLifecycle.cancel()
            if driverGeneration == session.generation {
                recognizerDriver.cancel()
                driverGeneration = nil
            }
            driverCommandLock.unlock()
        } else {
            session.sourceLifecycle.cancel {
                sourceCancelledGate?.signal()
            }
        }
    }

    private var maximumHotwords: Int {
        guard case let .boundedPhraseList(maximumEntries) =
            descriptor.hotwordMode
        else {
            return 0
        }
        return maximumEntries
    }

    private func failPreparation(
        generation expectedGeneration: UInt64,
        channel: EventChannel,
        code: VoiceDictationErrorCode
    ) {
        lock.lock()
        guard preparation?.generation == expectedGeneration else {
            lock.unlock()
            return
        }
        preparation = nil
        generation &+= 1
        lock.unlock()
        channel.finish(.failed(code, retryable: true))
    }

    private func failSession(
        generation expectedGeneration: UInt64,
        code: VoiceDictationErrorCode,
        retryable: Bool
    ) {
        // Fast stale check lets callbacks invoked synchronously by source.cancel
        // return without contending on the command linearization lock.
        lock.lock()
        let mayBeCurrent = session?.generation == expectedGeneration
        lock.unlock()
        guard mayBeCurrent else { return }

        driverCommandLock.lock()
        lock.lock()
        guard let session, session.generation == expectedGeneration else {
            lock.unlock()
            driverCommandLock.unlock()
            return
        }
        self.session = nil
        generation &+= 1
        session.bufferedFrames.removeAll(keepingCapacity: false)
        let maximumDurationCancellation =
            session.maximumDurationCancellation
        let finalDeadlineCancellation = session.finalDeadlineCancellation
        session.maximumDurationCancellation = nil
        session.finalDeadlineCancellation = nil
        let isDecoderQueue = isOnDecoderQueue
        let sourceCancelledGate: DispatchSemaphore?
        if isDecoderQueue {
            sourceCancelledGate = nil
        } else {
            let gate = DispatchSemaphore(value: 0)
            sourceCancelledGate = gate
            enqueueDriverCancel(
                generation: session.generation,
                after: gate
            )
        }
        lock.unlock()

        if !isDecoderQueue {
            driverCommandLock.unlock()
        }
        maximumDurationCancellation?()
        finalDeadlineCancellation?()
        if isDecoderQueue {
            session.sourceLifecycle.cancel()
            if driverGeneration == session.generation {
                recognizerDriver.cancel()
                driverGeneration = nil
            }
            driverCommandLock.unlock()
            session.channel.finish(.failed(code, retryable: retryable))
        } else {
            session.sourceLifecycle.cancel {
                sourceCancelledGate?.signal()
                session.channel.finish(.failed(
                    code,
                    retryable: retryable
                ))
            }
        }
    }

    private func receive(
        _ frame: VoicePCMFrame,
        generation expectedGeneration: UInt64
    ) {
        guard frame.isValid else {
            failSession(
                generation: expectedGeneration,
                code: .asrEngineError,
                retryable: true
            )
            return
        }

        lock.lock()
        guard let session, session.generation == expectedGeneration,
              session.phase == .accepting || session.phase == .stopping
        else {
            lock.unlock()
            return
        }
        guard session.bufferedFrames.count < Self.maximumBufferedFrames else {
            lock.unlock()
            failSession(
                generation: expectedGeneration,
                code: .asrOverload,
                retryable: true
            )
            return
        }
        session.bufferedFrames.append(frame)
        let shouldScheduleDrain = !session.isDrainScheduled
        session.isDrainScheduled = true
        lock.unlock()

        if shouldScheduleDrain {
            decoderQueue.async { [weak self] in
                self?.drainFrames(generation: expectedGeneration)
            }
        }
    }

    private func sourceFailed(
        _ failure: VoicePCMSourceFailure,
        generation expectedGeneration: UInt64
    ) {
        failSession(
            generation: expectedGeneration,
            code: failure.code,
            retryable: failure.retryable
        )
    }

    private func drainFrames(generation expectedGeneration: UInt64) {
        while true {
            lock.lock()
            guard let session, session.generation == expectedGeneration else {
                lock.unlock()
                return
            }
            guard !session.bufferedFrames.isEmpty else {
                session.isDrainScheduled = false
                lock.unlock()
                return
            }
            let frame = session.bufferedFrames.removeFirst()
            lock.unlock()

            guard driverGeneration == expectedGeneration else {
                failSessionFromDecoderQueue(
                    generation: expectedGeneration,
                    code: .asrEngineError,
                    retryable: true
                )
                return
            }

            let update: VoiceStreamingRecognitionUpdate
            do {
                update = try recognizerDriver.accept(samples: frame.samples)
            } catch {
                failSessionFromDecoderQueue(
                    generation: expectedGeneration,
                    code: .asrEngineError,
                    retryable: true
                )
                return
            }

            if update.isEndpoint {
                guard driverGeneration == expectedGeneration else {
                    failSessionFromDecoderQueue(
                        generation: expectedGeneration,
                        code: .asrEngineError,
                        retryable: true
                    )
                    return
                }
                do {
                    try recognizerDriver.resetEndpoint()
                } catch {
                    failSessionFromDecoderQueue(
                        generation: expectedGeneration,
                        code: .asrEngineError,
                        retryable: true
                    )
                    return
                }
            }
            handleRecognitionUpdate(
                update,
                generation: expectedGeneration
            )
        }
    }

    private func finishSession(generation expectedGeneration: UInt64) {
        lock.lock()
        guard let session, session.generation == expectedGeneration,
              session.phase == .finalizing
        else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard driverGeneration == expectedGeneration else {
            failSessionFromDecoderQueue(
                generation: expectedGeneration,
                code: .asrEngineError,
                retryable: true
            )
            return
        }

        let update: VoiceStreamingRecognitionUpdate
        do {
            update = try recognizerDriver.finish()
        } catch {
            failSessionFromDecoderQueue(
                generation: expectedGeneration,
                code: .asrEngineError,
                retryable: true
            )
            return
        }

        let finishedText = Self.normalizedDriverText(update.text)
        driverCommandLock.lock()
        lock.lock()
        guard let current = self.session,
              current.generation == expectedGeneration,
              current.phase == .finalizing
        else {
            lock.unlock()
            driverCommandLock.unlock()
            return
        }
        let currentSegment = finishedText.isEmpty
            ? current.currentPartialText
            : finishedText
        let finalText = Self.boundedConcatenation(
            current.stableText,
            currentSegment
        )
        guard !finalText.isEmpty else {
            lock.unlock()
            driverCommandLock.unlock()
            failSessionFromDecoderQueue(
                generation: expectedGeneration,
                code: .asrTimeout,
                retryable: true
            )
            return
        }
        self.session = nil
        generation &+= 1
        current.bufferedFrames.removeAll(keepingCapacity: false)
        let maximumDurationCancellation =
            current.maximumDurationCancellation
        let finalDeadlineCancellation = current.finalDeadlineCancellation
        current.maximumDurationCancellation = nil
        current.finalDeadlineCancellation = nil
        driverGeneration = nil
        lock.unlock()
        driverCommandLock.unlock()

        maximumDurationCancellation?()
        finalDeadlineCancellation?()
        // `finish()` returns the final hypothesis but the native recognizer
        // still owns its per-request stream (including hotword/context state).
        // Destroy it before publishing the terminal event so a synchronous
        // next start cannot observe or retain the previous request's state.
        recognizerDriver.cancel()
        current.channel.finish(.finished(
            text: finalText,
            confidence: 0,
            polishApplied: false
        ))
    }

    private func handleRecognitionUpdate(
        _ update: VoiceStreamingRecognitionUpdate,
        generation expectedGeneration: UInt64
    ) {
        let text = Self.normalizedDriverText(update.text)
        lock.lock()
        guard let session, session.generation == expectedGeneration else {
            lock.unlock()
            return
        }
        if update.isEndpoint {
            if !text.isEmpty {
                session.stableText = Self.boundedConcatenation(
                    session.stableText,
                    text
                )
            }
            session.currentPartialText = ""
        } else {
            let remaining = max(
                0,
                VoiceDictationConstants.maximumTextCharacters
                    - session.stableText.count
            )
            session.currentPartialText = String(text.prefix(remaining))
        }

        let payload = Session.PartialPayload(
            stableText: session.stableText,
            partialText: session.currentPartialText
        )
        guard !payload.stableText.isEmpty || !payload.partialText.isEmpty,
              payload != session.lastEmittedPartial
        else {
            lock.unlock()
            return
        }
        session.lastEmittedPartial = payload
        let channel = session.channel
        lock.unlock()
        channel.emit(.partial(
            stableText: payload.stableText,
            partialText: payload.partialText,
            confidence: 0
        ))
    }

    private func failSessionFromDecoderQueue(
        generation expectedGeneration: UInt64,
        code: VoiceDictationErrorCode,
        retryable: Bool
    ) {
        driverCommandLock.lock()
        lock.lock()
        guard let session, session.generation == expectedGeneration else {
            lock.unlock()
            driverCommandLock.unlock()
            return
        }
        self.session = nil
        generation &+= 1
        session.bufferedFrames.removeAll(keepingCapacity: false)
        let maximumDurationCancellation =
            session.maximumDurationCancellation
        let finalDeadlineCancellation = session.finalDeadlineCancellation
        session.maximumDurationCancellation = nil
        session.finalDeadlineCancellation = nil
        lock.unlock()

        maximumDurationCancellation?()
        finalDeadlineCancellation?()
        session.sourceLifecycle.cancel()
        if driverGeneration == expectedGeneration {
            recognizerDriver.cancel()
            driverGeneration = nil
        }
        driverCommandLock.unlock()
        session.channel.finish(.failed(code, retryable: retryable))
    }

    private func scheduleMaximumDuration(
        _ milliseconds: Int,
        generation expectedGeneration: UInt64,
        requestID: String
    ) {
        let boundedMilliseconds = max(
            1,
            min(
                milliseconds,
                VoiceDictationConstants.maximumDurationMilliseconds
            )
        )
        let cancellation = scheduleAfterMilliseconds(
            boundedMilliseconds
        ) { [weak self] in
            self?.beginStop(
                requestID: requestID,
                expectedGeneration: expectedGeneration
            )
        }
        lock.lock()
        let shouldKeep: Bool
        if let session,
           session.generation == expectedGeneration,
           session.phase == .accepting
        {
            session.maximumDurationCancellation = cancellation
            shouldKeep = true
        } else {
            shouldKeep = false
        }
        lock.unlock()
        if !shouldKeep {
            cancellation()
        }
    }

    private func finalDeadlineReached(generation expectedGeneration: UInt64) {
        failSession(
            generation: expectedGeneration,
            code: .asrTimeout,
            retryable: true
        )
    }

    private var isOnDecoderQueue: Bool {
        DispatchQueue.getSpecific(key: decoderQueueKey) == 1
    }

    /// Must be called while `driverCommandLock` linearizes this submission
    /// against installation of the next generation's reset command.
    private func enqueueDriverCancel(
        generation expectedGeneration: UInt64,
        after sourceCancelledGate: DispatchSemaphore
    ) {
        decoderQueue.async { [weak self] in
            sourceCancelledGate.wait()
            guard let self,
                  self.driverGeneration == expectedGeneration
            else {
                return
            }
            self.recognizerDriver.cancel()
            self.driverGeneration = nil
        }
    }

    private static func normalizedDriverText(_ value: String) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(
            VoiceDictationConstants.maximumTextCharacters
        ))
    }

    private static func normalizedHotwords(
        _ phrases: [String],
        maximumEntries: Int
    ) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []
        normalized.reserveCapacity(min(phrases.count, maximumEntries))
        for phrase in phrases where normalized.count < maximumEntries {
            let compatibilityNormalized = phrase
                .precomposedStringWithCompatibilityMapping
            guard !compatibilityNormalized.unicodeScalars.contains(where: {
                      $0.value < 0x20
                          || (0x7f ... 0x9f).contains($0.value)
                  }),
                  !compatibilityNormalized.contains("/"),
                  !compatibilityNormalized.contains(":"),
                  !compatibilityNormalized.contains("#"),
                  !compatibilityNormalized.contains("@")
            else {
                continue
            }
            let trimmed = compatibilityNormalized.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty,
                  trimmed.utf8.count <= Self.maximumHotwordUTF8Bytes,
                  seen.insert(trimmed).inserted
            else {
                continue
            }
            normalized.append(trimmed)
        }
        return normalized
    }

    private static func boundedConcatenation(
        _ prefix: String,
        _ suffix: String
    ) -> String {
        String((prefix + suffix).prefix(
            VoiceDictationConstants.maximumTextCharacters
        ))
    }

    private static func accepts(_ descriptor: VoiceEngineDescriptor) -> Bool {
        guard descriptor.isStructurallyValid,
              descriptor.hasIntegrityVerifiedProductArtifact,
              descriptor.assetManagement == .productManaged,
              descriptor.qualification ==
                .integrityVerifiedProductArtifact,
              descriptor.networkPolicy == .offline,
              descriptor.capabilities.contains(.localASR),
              descriptor.capabilities.contains(.streaming),
              !descriptor.capabilities.contains(.cloudASR),
              descriptor.maximumAlternatives == 1
        else {
            return false
        }
        switch descriptor.hotwordMode {
        case .unsupported:
            guard !descriptor.capabilities.contains(.hotwordSnapshot) else {
                return false
            }
        case let .boundedPhraseList(maximumHotwords):
            guard maximumHotwords > 0,
                  descriptor.capabilities.contains(.hotwordSnapshot)
            else {
                return false
            }
        }
        guard case let .fixedLinearPCM(sampleRate, channels, bits) =
            descriptor.audioFormat
        else {
            return false
        }
        return sampleRate == VoicePCMFrame.sampleRateHertz
            && channels == 1
            && bits == 32
    }
}
