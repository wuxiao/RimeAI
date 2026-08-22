@preconcurrency import AVFoundation
import Foundation
import RimeAIInputCore

enum VoiceMicrophoneAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

protocol VoiceMicrophoneAuthorizationProviding: Sendable {
    func authorizationStatus() -> VoiceMicrophoneAuthorizationState
    func requestAuthorization(
        _ completion: @escaping @Sendable (VoiceMicrophoneAuthorizationState) -> Void
    )
}

private final class SystemVoiceMicrophoneAuthorizationProvider:
    VoiceMicrophoneAuthorizationProviding,
    @unchecked Sendable
{
    func authorizationStatus() -> VoiceMicrophoneAuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .authorized
        case .restricted, .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization(
        _ completion: @escaping @Sendable (VoiceMicrophoneAuthorizationState) -> Void
    ) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            completion(granted ? .authorized : .denied)
        }
    }
}

enum VoicePCMInputCaptureFailure: Error, Equatable, Sendable {
    case invalidInput
}

protocol VoicePCMInputCapturing: AnyObject, Sendable {
    func start(
        onChunk: @escaping @Sendable (VoicePCMInputChunk) -> Void,
        onFailure: @escaping @Sendable (VoicePCMInputCaptureFailure) -> Void
    ) throws

    /// Returns only after the tap has been removed and callbacks already in
    /// flight have returned to the audio engine.
    func stop()
}

enum VoicePCMSourceStartError: Error, Equatable {
    case microphoneUnavailable
}

private final class SystemAVAudioEngineInputCapture:
    VoicePCMInputCapturing,
    @unchecked Sendable
{
    private let lifecycleLock = NSLock()
    private let callbackCondition = NSCondition()

    private var audioEngine: AVAudioEngine?
    private var tapInstalled = false
    private var isActive = false
    private var generation: UInt64 = 0
    private var callbacksInFlight = 0

    func start(
        onChunk: @escaping @Sendable (VoicePCMInputChunk) -> Void,
        onFailure: @escaping @Sendable (VoicePCMInputCaptureFailure) -> Void
    ) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        callbackCondition.lock()
        if isActive {
            callbackCondition.unlock()
            return
        }
        generation &+= 1
        let captureGeneration = generation
        callbackCondition.unlock()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.commonFormat == .pcmFormatFloat32,
            format.sampleRate.isFinite,
            format.sampleRate > 0,
            (1...2).contains(Int(format.channelCount))
        else {
            throw VoicePCMSourceStartError.microphoneUnavailable
        }

        callbackCondition.lock()
        isActive = true
        audioEngine = engine
        callbackCondition.unlock()

        inputNode.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: format
        ) { [weak self] buffer, _ in
            guard let self,
                self.beginCallback(generation: captureGeneration)
            else {
                return
            }
            defer { self.endCallback() }

            do {
                // Snapshot synchronously on the tap thread. The AVFoundation
                // buffer is never retained or sent to another queue.
                onChunk(try VoicePCMInputChunk(copying: buffer))
            } catch {
                onFailure(.invalidInput)
            }
        }

        callbackCondition.lock()
        tapInstalled = true
        callbackCondition.unlock()

        do {
            engine.prepare()
            try engine.start()
        } catch {
            stopWhileLifecycleLocked()
            throw VoicePCMSourceStartError.microphoneUnavailable
        }
    }

    func stop() {
        lifecycleLock.lock()
        stopWhileLifecycleLocked()
        lifecycleLock.unlock()
    }

    deinit {
        stop()
    }

    private func beginCallback(generation expectedGeneration: UInt64) -> Bool {
        callbackCondition.lock()
        defer { callbackCondition.unlock() }
        guard isActive, generation == expectedGeneration else {
            return false
        }
        callbacksInFlight += 1
        return true
    }

    private func endCallback() {
        callbackCondition.lock()
        callbacksInFlight -= 1
        if callbacksInFlight == 0 {
            callbackCondition.broadcast()
        }
        callbackCondition.unlock()
    }

    /// `lifecycleLock` must be held by the caller.
    private func stopWhileLifecycleLocked() {
        callbackCondition.lock()
        let engine = audioEngine
        let shouldRemoveTap = tapInstalled
        isActive = false
        generation &+= 1
        tapInstalled = false
        callbackCondition.unlock()

        if shouldRemoveTap {
            engine?.inputNode.removeTap(onBus: 0)
        }
        engine?.stop()

        callbackCondition.lock()
        while callbacksInFlight > 0 {
            callbackCondition.wait()
        }
        if audioEngine === engine {
            audioEngine = nil
        }
        callbackCondition.unlock()
    }
}

public struct AVAudioEnginePCMSourceFactory: VoicePCMSourceFactory, Sendable {
    public init() {}

    public func makeSource() throws -> any VoicePCMSource {
        AVAudioEnginePCMSource()
    }
}

/// AVFoundation microphone source for the product recognizer. Authorization,
/// tap snapshots, conversion, framing, and callback delivery have separate
/// seams so tests never need to open the real microphone.
public final class AVAudioEnginePCMSource: VoicePCMSource, @unchecked Sendable {
    private final class CompletionSignal: @unchecked Sendable {
        private let lock = NSLock()
        private let group = DispatchGroup()
        private var isFinished = false

        init() { group.enter() }

        func finish() {
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            isFinished = true
            lock.unlock()
            group.leave()
        }

        func wait() { group.wait() }
    }

    private final class Session: @unchecked Sendable {
        enum Phase: Equatable {
            case starting
            case queryingAuthorization
            case requestingAuthorization
            case startingCapture
            case running
            case stoppingNormally
            case failed
            case cancelled
            case terminated
        }

        let generation: UInt64
        let frameSink: @Sendable (VoicePCMFrame) -> Void
        let failureSink: @Sendable (VoicePCMSourceFailure) -> Void
        var phase: Phase = .starting
        var converter: (any VoicePCMConverting)?
        var pendingChunks = 0
        var captureStarted = false
        var captureStartOperation: CompletionSignal?
        var failureTeardownSignal: CompletionSignal?
        var normalStopSignal: CompletionSignal?
        var failureCallbackFinished = false
        var failureCaptureTeardownFinished = true

        init(
            generation: UInt64,
            frameSink: @escaping @Sendable (VoicePCMFrame) -> Void,
            failureSink: @escaping @Sendable (VoicePCMSourceFailure) -> Void
        ) {
            self.generation = generation
            self.frameSink = frameSink
            self.failureSink = failureSink
        }
    }

    private enum StopPlan {
        case none
        case flush(session: Session, signal: CompletionSignal)
        case invalidate(
            session: Session,
            operationToWaitFor: CompletionSignal?,
            stopCapture: Bool
        )
        case wait(signal: CompletionSignal)
    }

    /// Includes the chunk currently being converted. With the system tap size,
    /// this bounds queued owned PCM to roughly four seconds.
    static let maximumPendingChunks = 100

    private let authorizationProvider: any VoiceMicrophoneAuthorizationProviding
    private let capture: any VoicePCMInputCapturing
    private let converterFactory: @Sendable () throws -> any VoicePCMConverting
    private let workQueue: DispatchQueue
    private let workQueueKey = DispatchSpecificKey<UInt8>()
    private let callbackQueue: DispatchQueue
    private let callbackQueueKey = DispatchSpecificKey<UInt8>()
    private let invalidationObserver: @Sendable () -> Void
    private let teardownQueue = DispatchQueue(
        label: "fun.wwcn.rimeai.voice-helper.product-pcm-source.teardown"
    )
    private let controlLock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var activeSession: Session?

    public convenience init() {
        self.init(
            authorizationProvider: SystemVoiceMicrophoneAuthorizationProvider(),
            capture: SystemAVAudioEngineInputCapture(),
            converterFactory: { VoicePCMConverter() }
        )
    }

    init(
        authorizationProvider: any VoiceMicrophoneAuthorizationProviding,
        capture: any VoicePCMInputCapturing,
        converterFactory: @escaping @Sendable () throws -> any VoicePCMConverting,
        callbackQueue: DispatchQueue? = nil,
        invalidationObserver: @escaping @Sendable () -> Void = {}
    ) {
        self.authorizationProvider = authorizationProvider
        self.capture = capture
        self.converterFactory = converterFactory
        workQueue = DispatchQueue(
            label: "fun.wwcn.rimeai.voice-helper.product-pcm-source.work"
        )
        self.callbackQueue = callbackQueue ?? DispatchQueue(
            label: "fun.wwcn.rimeai.voice-helper.product-pcm-source.callback"
        )
        self.invalidationObserver = invalidationObserver
        workQueue.setSpecific(key: workQueueKey, value: 1)
        self.callbackQueue.setSpecific(key: callbackQueueKey, value: 1)
    }

    public func start(
        onFrame: @escaping @Sendable (VoicePCMFrame) -> Void,
        onFailure: @escaping @Sendable (VoicePCMSourceFailure) -> Void
    ) throws {
        // Reserve a generation before any external authorization query. This
        // lets stop/cancel invalidate an attempt while that query is blocked.
        controlLock.lock()
        guard activeSession == nil else {
            controlLock.unlock()
            return
        }
        nextGeneration &+= 1
        let session = Session(
            generation: nextGeneration,
            frameSink: onFrame,
            failureSink: onFailure
        )
        activeSession = session
        controlLock.unlock()

        let newConverter: any VoicePCMConverting
        do {
            newConverter = try converterFactory()
        } catch {
            controlLock.lock()
            if activeSession === session {
                session.phase = .terminated
                activeSession = nil
            }
            controlLock.unlock()
            throw VoicePCMSourceStartError.microphoneUnavailable
        }

        controlLock.lock()
        guard activeSession === session, session.phase == .starting else {
            controlLock.unlock()
            newConverter.discard()
            return
        }
        session.converter = newConverter
        session.phase = .queryingAuthorization
        controlLock.unlock()

        let authorization = authorizationProvider.authorizationStatus()

        controlLock.lock()
        guard activeSession === session,
            session.phase == .queryingAuthorization
        else {
            controlLock.unlock()
            return
        }
        switch authorization {
        case .authorized:
            session.phase = .startingCapture
            controlLock.unlock()
            beginCapture(for: session)
        case .denied:
            controlLock.unlock()
            transitionToFailure(
                session,
                failure: VoicePCMSourceFailure(
                    code: .micDenied,
                    retryable: false
                )
            )
        case .notDetermined:
            session.phase = .requestingAuthorization
            controlLock.unlock()
            authorizationProvider.requestAuthorization { [weak self, session] result in
                self?.handleAuthorization(result, session: session)
            }
        }
    }

    public func stop() { stopNormally() }

    public func cancel() { invalidateCurrentSession() }

    private func handleAuthorization(
        _ authorization: VoiceMicrophoneAuthorizationState,
        session: Session
    ) {
        controlLock.lock()
        guard activeSession === session,
            session.phase == .requestingAuthorization
        else {
            controlLock.unlock()
            return
        }
        switch authorization {
        case .authorized:
            session.phase = .startingCapture
            controlLock.unlock()
            beginCapture(for: session)
        case .notDetermined, .denied:
            controlLock.unlock()
            transitionToFailure(
                session,
                failure: VoicePCMSourceFailure(
                    code: .micDenied,
                    retryable: false
                )
            )
        }
    }

    private func beginCapture(for session: Session) {
        let operation = CompletionSignal()
        controlLock.lock()
        guard activeSession === session, session.phase == .startingCapture else {
            controlLock.unlock()
            operation.finish()
            return
        }
        session.captureStartOperation = operation
        controlLock.unlock()

        let startError: Error?
        do {
            try capture.start(
                onChunk: { [weak self, session] chunk in
                    self?.receive(chunk, session: session)
                },
                onFailure: { [weak self, session] _ in
                    self?.transitionToFailure(
                        session,
                        failure: VoicePCMSourceFailure(
                            code: .micUnavailable,
                            retryable: false
                        )
                    )
                }
            )
            startError = nil
        } catch {
            startError = error
        }

        if startError == nil {
            completeSuccessfulCaptureStart(
                session: session,
                operation: operation
            )
        } else {
            completeFailedCaptureStart(
                session: session,
                operation: operation
            )
        }
    }

    private func completeSuccessfulCaptureStart(
        session: Session,
        operation: CompletionSignal
    ) {
        controlLock.lock()
        let remainsActive = activeSession === session
        if session.captureStartOperation === operation {
            session.captureStartOperation = nil
        }
        if remainsActive, session.phase == .startingCapture {
            session.captureStarted = true
            session.phase = .running
            controlLock.unlock()
            operation.finish()
            return
        }
        let failedDuringStart = remainsActive && session.phase == .failed
        controlLock.unlock()

        // Undo capture before releasing stop/cancel waiters if termination or
        // a synchronous capture callback invalidated this generation.
        capture.stop()
        if failedDuringStart {
            markFailureCaptureTeardownFinished(for: session)
        }
        operation.finish()
    }

    private func completeFailedCaptureStart(
        session: Session,
        operation: CompletionSignal
    ) {
        // A backend may have installed a tap before throwing.
        capture.stop()

        var shouldReportStartFailure = false
        controlLock.lock()
        if session.captureStartOperation === operation {
            session.captureStartOperation = nil
        }
        if activeSession === session, session.phase == .startingCapture {
            session.captureStarted = false
            session.phase = .failed
            session.failureCallbackFinished = false
            session.failureCaptureTeardownFinished = true
            shouldReportStartFailure = true
        } else if activeSession === session, session.phase == .failed {
            session.failureCaptureTeardownFinished = true
            session.failureTeardownSignal?.finish()
            session.failureTeardownSignal = nil
            finalizeFailedSessionIfReadyLocked(session)
        }
        controlLock.unlock()
        operation.finish()

        if shouldReportStartFailure {
            discardConverterEventually(for: session)
            enqueueFailureCallback(
                VoicePCMSourceFailure(
                    code: .micUnavailable,
                    retryable: true
                ),
                session: session
            )
        }
    }

    private func receive(_ chunk: VoicePCMInputChunk, session: Session) {
        controlLock.lock()
        guard acceptsChunksLocked(session) else {
            controlLock.unlock()
            return
        }
        guard session.pendingChunks < Self.maximumPendingChunks else {
            controlLock.unlock()
            transitionToFailure(
                session,
                failure: VoicePCMSourceFailure(
                    code: .asrOverload,
                    retryable: true
                )
            )
            return
        }
        session.pendingChunks += 1
        controlLock.unlock()

        workQueue.async { [weak self, session] in
            self?.process(chunk, session: session)
        }
    }

    private func process(_ chunk: VoicePCMInputChunk, session: Session) {
        defer {
            controlLock.lock()
            session.pendingChunks -= 1
            controlLock.unlock()
        }

        controlLock.lock()
        guard acceptsChunksLocked(session), let converter = session.converter else {
            controlLock.unlock()
            return
        }
        controlLock.unlock()

        do {
            enqueueFrames(try converter.append(chunk), session: session)
        } catch {
            transitionToFailure(
                session,
                failure: VoicePCMSourceFailure(
                    code: .micUnavailable,
                    retryable: false
                )
            )
        }
    }

    private func transitionToFailure(
        _ session: Session,
        failure: VoicePCMSourceFailure
    ) {
        controlLock.lock()
        guard activeSession === session, canFailLocked(session.phase) else {
            controlLock.unlock()
            return
        }
        let captureStartIsInFlight = session.captureStartOperation != nil
        let shouldStopCapture = session.captureStarted && !captureStartIsInFlight
        session.phase = .failed
        session.failureCallbackFinished = false
        session.failureCaptureTeardownFinished =
            !captureStartIsInFlight && !session.captureStarted
        if shouldStopCapture {
            session.failureTeardownSignal = CompletionSignal()
        }
        controlLock.unlock()

        discardConverterEventually(for: session)
        enqueueFailureCallback(failure, session: session)

        if shouldStopCapture {
            teardownQueue.async { [weak self, session] in
                guard let self else { return }
                self.capture.stop()
                self.markFailureCaptureTeardownFinished(for: session)
            }
        }
    }

    private func markFailureCaptureTeardownFinished(for session: Session) {
        controlLock.lock()
        if activeSession === session, session.phase == .failed {
            session.captureStarted = false
            session.failureCaptureTeardownFinished = true
            session.failureTeardownSignal?.finish()
            session.failureTeardownSignal = nil
            finalizeFailedSessionIfReadyLocked(session)
        } else {
            session.failureTeardownSignal?.finish()
            session.failureTeardownSignal = nil
        }
        controlLock.unlock()
    }

    private func enqueueFailureCallback(
        _ failure: VoicePCMSourceFailure,
        session: Session
    ) {
        callbackQueue.async { [weak self, session] in
            guard let self else { return }
            self.controlLock.lock()
            guard self.activeSession === session, session.phase == .failed else {
                self.controlLock.unlock()
                return
            }
            let sink = session.failureSink
            self.controlLock.unlock()

            sink(failure)

            self.controlLock.lock()
            if self.activeSession === session, session.phase == .failed {
                session.failureCallbackFinished = true
                self.finalizeFailedSessionIfReadyLocked(session)
            }
            self.controlLock.unlock()
        }
    }

    private func finalizeFailedSessionIfReadyLocked(_ session: Session) {
        guard activeSession === session,
            session.phase == .failed,
            session.failureCallbackFinished,
            session.failureCaptureTeardownFinished
        else {
            return
        }
        session.phase = .terminated
        activeSession = nil
    }

    private func discardConverterEventually(for session: Session) {
        workQueue.async { [session] in
            session.converter?.discard()
        }
    }

    private func stopNormally() {
        let plan: StopPlan
        controlLock.lock()
        guard let session = activeSession else {
            controlLock.unlock()
            return
        }
        switch session.phase {
        case .running:
            let signal = CompletionSignal()
            session.phase = .stoppingNormally
            session.normalStopSignal = signal
            plan = .flush(session: session, signal: signal)
        case .stoppingNormally:
            if let signal = session.normalStopSignal {
                plan = .wait(signal: signal)
            } else {
                plan = .none
            }
        case .startingCapture:
            session.phase = .cancelled
            activeSession = nil
            plan = .invalidate(
                session: session,
                operationToWaitFor: session.captureStartOperation,
                stopCapture: session.captureStartOperation == nil
            )
        case .failed:
            let waitSignal =
                session.captureStartOperation ?? session.failureTeardownSignal
            session.phase = .cancelled
            activeSession = nil
            plan = .invalidate(
                session: session,
                operationToWaitFor: waitSignal,
                stopCapture: false
            )
        case .starting, .queryingAuthorization, .requestingAuthorization:
            session.phase = .cancelled
            activeSession = nil
            plan = .invalidate(
                session: session,
                operationToWaitFor: nil,
                stopCapture: false
            )
        case .cancelled, .terminated:
            plan = .none
        }
        controlLock.unlock()
        executeStopPlan(plan)
    }

    private func invalidateCurrentSession() {
        let plan: StopPlan
        controlLock.lock()
        guard let session = activeSession else {
            controlLock.unlock()
            return
        }
        switch session.phase {
        case .stoppingNormally:
            // The normal-stop owner owns capture teardown. Invalidation here
            // remains independent of its conversion backlog.
            session.phase = .cancelled
            activeSession = nil
            plan = .invalidate(
                session: session,
                operationToWaitFor: nil,
                stopCapture: false
            )
        case .startingCapture:
            session.phase = .cancelled
            activeSession = nil
            plan = .invalidate(
                session: session,
                operationToWaitFor: session.captureStartOperation,
                stopCapture: session.captureStartOperation == nil
            )
        case .running:
            session.phase = .cancelled
            activeSession = nil
            plan = .invalidate(
                session: session,
                operationToWaitFor: nil,
                stopCapture: true
            )
        case .failed:
            let waitSignal =
                session.captureStartOperation ?? session.failureTeardownSignal
            session.phase = .cancelled
            activeSession = nil
            plan = .invalidate(
                session: session,
                operationToWaitFor: waitSignal,
                stopCapture: false
            )
        case .starting, .queryingAuthorization, .requestingAuthorization:
            session.phase = .cancelled
            activeSession = nil
            plan = .invalidate(
                session: session,
                operationToWaitFor: nil,
                stopCapture: false
            )
        case .cancelled, .terminated:
            plan = .none
        }
        controlLock.unlock()
        invalidationObserver()
        executeStopPlan(plan)
    }

    private func executeStopPlan(_ plan: StopPlan) {
        switch plan {
        case .none:
            return
        case let .wait(signal):
            signal.wait()
        case let .invalidate(session, operationToWaitFor, stopCapture):
            operationToWaitFor?.wait()
            if stopCapture {
                capture.stop()
            }
            drainCallbackQueue()
            discardConverterEventually(for: session)
        case let .flush(session, signal):
            performNormalFlush(session: session, signal: signal)
        }
    }

    private func performNormalFlush(
        session: Session,
        signal: CompletionSignal
    ) {
        defer { signal.finish() }

        // capture.stop waits for tap callbacks already in flight; their owned
        // chunks are queued before the workQueue barrier below.
        capture.stop()
        controlLock.lock()
        if activeSession === session, session.phase == .stoppingNormally {
            session.captureStarted = false
        }
        controlLock.unlock()

        var finishFailure: VoicePCMSourceFailure?
        performOnWorkQueueSync {
            controlLock.lock()
            guard activeSession === session,
                session.phase == .stoppingNormally,
                let converter = session.converter
            else {
                controlLock.unlock()
                return
            }
            controlLock.unlock()

            do {
                let frames = try converter.finish(padTail: true)
                guard frames.allSatisfy(\.isValid) else {
                    throw VoicePCMConversionError.conversionFailed
                }
                enqueueFrames(frames, session: session)
            } catch {
                converter.discard()
                finishFailure = VoicePCMSourceFailure(
                    code: .micUnavailable,
                    retryable: false
                )
            }
        }

        if let finishFailure {
            controlLock.lock()
            if activeSession === session, session.phase == .stoppingNormally {
                session.phase = .failed
                session.failureCallbackFinished = false
                session.failureCaptureTeardownFinished = true
                controlLock.unlock()
                enqueueFailureCallback(finishFailure, session: session)
            } else {
                controlLock.unlock()
            }
        }

        drainCallbackQueue()

        controlLock.lock()
        if activeSession === session, session.phase == .stoppingNormally {
            session.phase = .terminated
            activeSession = nil
        }
        controlLock.unlock()
    }

    private func enqueueFrames(_ frames: [VoicePCMFrame], session: Session) {
        for frame in frames {
            guard frame.isValid else {
                transitionToFailure(
                    session,
                    failure: VoicePCMSourceFailure(
                        code: .micUnavailable,
                        retryable: false
                    )
                )
                return
            }
            callbackQueue.async { [weak self, session] in
                guard let self else { return }
                self.controlLock.lock()
                guard self.acceptsChunksLocked(session) else {
                    self.controlLock.unlock()
                    return
                }
                let sink = session.frameSink
                self.controlLock.unlock()
                sink(frame)
            }
        }
    }

    private func acceptsChunksLocked(_ session: Session) -> Bool {
        guard activeSession === session else { return false }
        switch session.phase {
        case .startingCapture, .running, .stoppingNormally:
            return true
        case .starting, .queryingAuthorization, .requestingAuthorization,
            .failed, .cancelled, .terminated:
            return false
        }
    }

    private func canFailLocked(_ phase: Session.Phase) -> Bool {
        switch phase {
        case .starting, .queryingAuthorization, .requestingAuthorization,
            .startingCapture, .running, .stoppingNormally:
            return true
        case .failed, .cancelled, .terminated:
            return false
        }
    }

    private func drainCallbackQueue() {
        guard DispatchQueue.getSpecific(key: callbackQueueKey) == nil else {
            return
        }
        callbackQueue.sync {}
    }

    private func performOnWorkQueueSync<T>(
        _ operation: () throws -> T
    ) rethrows -> T {
        if DispatchQueue.getSpecific(key: workQueueKey) != nil {
            return try operation()
        }
        return try workQueue.sync(execute: operation)
    }
}
