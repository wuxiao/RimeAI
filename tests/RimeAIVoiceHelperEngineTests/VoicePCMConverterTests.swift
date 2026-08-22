@preconcurrency import AVFoundation
import Foundation
import RimeAIInputCore
import Testing
@testable import RimeAIVoiceHelperEngine

private func makeFloatBuffer(
    sampleRate: Double,
    channels: Int,
    frameCount: Int,
    interleaved: Bool = false,
    sample: (Int, Int) -> Float
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: AVAudioChannelCount(channels),
        interleaved: interleaved
    )!
    let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frameCount)
    )!
    buffer.frameLength = AVAudioFrameCount(frameCount)

    let channelData = buffer.floatChannelData!
    if interleaved {
        for frame in 0..<frameCount {
            for channel in 0..<channels {
                channelData[0][frame * channels + channel] = sample(frame, channel)
            }
        }
    } else {
        for channel in 0..<channels {
            for frame in 0..<frameCount {
                channelData[channel][frame] = sample(frame, channel)
            }
        }
    }
    return buffer
}

private func makeInt16Buffer() -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
    buffer.frameLength = 32
    return buffer
}

private func flattened(_ frames: [VoicePCMFrame]) -> [Float] {
    frames.flatMap(\.samples)
}

private func mean(_ samples: ArraySlice<Float>) -> Float {
    samples.reduce(0, +) / Float(samples.count)
}

private func waitUntil(
    _ predicate: @escaping @Sendable () -> Bool
) async -> Bool {
    for _ in 0..<100 {
        if predicate() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return predicate()
}

private func waitSucceeded(
    _ semaphore: DispatchSemaphore,
    timeout: TimeInterval = 1
) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
}

private final class PCMCallbackCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFrames: [VoicePCMFrame] = []
    private var storedFailures: [VoicePCMSourceFailure] = []

    func append(frame: VoicePCMFrame) {
        lock.lock()
        storedFrames.append(frame)
        lock.unlock()
    }

    func append(failure: VoicePCMSourceFailure) {
        lock.lock()
        storedFailures.append(failure)
        lock.unlock()
    }

    var frames: [VoicePCMFrame] {
        lock.lock()
        defer { lock.unlock() }
        return storedFrames
    }

    var failures: [VoicePCMSourceFailure] {
        lock.lock()
        defer { lock.unlock() }
        return storedFailures
    }
}

private final class MicrophoneAuthorizationDouble:
    VoiceMicrophoneAuthorizationProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var currentStatus: VoiceMicrophoneAuthorizationState
    private var completions:
        [@Sendable (VoiceMicrophoneAuthorizationState) -> Void] = []
    private var storedRequestCount = 0
    private let blocksStatusQuery: Bool
    private let statusQueryEntered = DispatchSemaphore(value: 0)
    private let statusQueryRelease = DispatchSemaphore(value: 0)

    init(
        _ status: VoiceMicrophoneAuthorizationState,
        blocksStatusQuery: Bool = false
    ) {
        currentStatus = status
        self.blocksStatusQuery = blocksStatusQuery
    }

    func authorizationStatus() -> VoiceMicrophoneAuthorizationState {
        lock.lock()
        let status = currentStatus
        lock.unlock()
        if blocksStatusQuery {
            statusQueryEntered.signal()
            statusQueryRelease.wait()
        }
        return status
    }

    func requestAuthorization(
        _ completion: @escaping @Sendable (VoiceMicrophoneAuthorizationState) -> Void
    ) {
        lock.lock()
        storedRequestCount += 1
        completions.append(completion)
        lock.unlock()
    }

    func resolve(_ status: VoiceMicrophoneAuthorizationState) {
        lock.lock()
        currentStatus = status
        let pending = completions
        completions.removeAll()
        lock.unlock()
        pending.forEach { $0(status) }
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestCount
    }

    func waitForStatusQuery() -> Bool {
        waitSucceeded(statusQueryEntered)
    }

    func releaseStatusQuery() {
        statusQueryRelease.signal()
    }
}

private final class PCMInputCaptureDouble:
    VoicePCMInputCapturing,
    @unchecked Sendable
{
    typealias Handlers = (
        chunk: @Sendable (VoicePCMInputChunk) -> Void,
        failure: @Sendable (VoicePCMInputCaptureFailure) -> Void
    )

    private let lock = NSLock()
    private var handlers: [Handlers] = []
    private var storedStartCount = 0
    private var storedStopCount = 0
    private var chunkForNextStop: VoicePCMInputChunk?
    var startError: Error?

    func start(
        onChunk: @escaping @Sendable (VoicePCMInputChunk) -> Void,
        onFailure: @escaping @Sendable (VoicePCMInputCaptureFailure) -> Void
    ) throws {
        lock.lock()
        storedStartCount += 1
        let error = startError
        if error == nil {
            handlers.append((onChunk, onFailure))
        }
        lock.unlock()
        if let error {
            throw error
        }
    }

    func stop() {
        lock.lock()
        storedStopCount += 1
        let chunk = chunkForNextStop
        chunkForNextStop = nil
        let handler = handlers.last?.chunk
        lock.unlock()
        if let chunk, let handler {
            handler(chunk)
        }
    }

    func emitDuringNextStop(_ chunk: VoicePCMInputChunk) {
        lock.lock()
        chunkForNextStop = chunk
        lock.unlock()
    }

    func emit(_ chunk: VoicePCMInputChunk, fromStart index: Int) {
        lock.lock()
        let handler = handlers[index].chunk
        lock.unlock()
        handler(chunk)
    }

    func emitFailure(fromStart index: Int) {
        lock.lock()
        let handler = handlers[index].failure
        lock.unlock()
        handler(.invalidInput)
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStartCount
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStopCount
    }
}

private final class ConverterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFinishCount = 0
    private var storedDiscardCount = 0

    func recordFinish() {
        lock.lock()
        storedFinishCount += 1
        lock.unlock()
    }

    func recordDiscard() {
        lock.lock()
        storedDiscardCount += 1
        lock.unlock()
    }

    var finishCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedFinishCount
    }

    var discardCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDiscardCount
    }
}

private final class ConverterDouble: VoicePCMConverting, @unchecked Sendable {
    private let probe: ConverterProbe
    private let tailValue: Float?

    init(probe: ConverterProbe, tailValue: Float? = nil) {
        self.probe = probe
        self.tailValue = tailValue
    }

    func append(_ chunk: VoicePCMInputChunk) throws -> [VoicePCMFrame] {
        guard let value = chunk.samples.first else {
            return []
        }
        return [
            VoicePCMFrame(
                samples: [Float](
                    repeating: value,
                    count: VoicePCMFrame.samplesPerFrame
                )
            ),
        ]
    }

    func finish(padTail: Bool) throws -> [VoicePCMFrame] {
        probe.recordFinish()
        guard padTail, let tailValue else {
            return []
        }
        return [
            VoicePCMFrame(
                samples: [Float](
                    repeating: tailValue,
                    count: VoicePCMFrame.samplesPerFrame
                )
            ),
        ]
    }

    func discard() {
        probe.recordDiscard()
    }
}

private final class BlockingConverter: VoicePCMConverting, @unchecked Sendable {
    private let lock = NSLock()
    private let appendEntered = DispatchSemaphore(value: 0)
    private let appendRelease = DispatchSemaphore(value: 0)
    private var hasBlocked = false

    func append(_ chunk: VoicePCMInputChunk) throws -> [VoicePCMFrame] {
        lock.lock()
        let shouldBlock = !hasBlocked
        hasBlocked = true
        lock.unlock()

        if shouldBlock {
            appendEntered.signal()
            appendRelease.wait()
        }
        guard let value = chunk.samples.first else {
            return []
        }
        return [
            VoicePCMFrame(
                samples: [Float](
                    repeating: value,
                    count: VoicePCMFrame.samplesPerFrame
                )
            ),
        ]
    }

    func finish(padTail: Bool) throws -> [VoicePCMFrame] { [] }

    func discard() {}

    func waitForBlockedAppend() -> Bool {
        waitSucceeded(appendEntered)
    }

    func releaseAppend() {
        appendRelease.signal()
    }
}

private func makeChunk(value: Float = 0.25) -> VoicePCMInputChunk {
    try! VoicePCMInputChunk(
        sampleRate: 48_000,
        channelCount: 1,
        frameCount: 1,
        storageLayout: .planar,
        samples: [value]
    )
}

private func makeSource(
    authorization: MicrophoneAuthorizationDouble,
    capture: PCMInputCaptureDouble,
    probe: ConverterProbe = ConverterProbe(),
    tailValue: Float? = nil,
    converterFactory: (@Sendable () throws -> any VoicePCMConverting)? = nil,
    callbackQueue: DispatchQueue? = nil,
    invalidationObserver: @escaping @Sendable () -> Void = {}
) -> AVAudioEnginePCMSource {
    AVAudioEnginePCMSource(
        authorizationProvider: authorization,
        capture: capture,
        converterFactory: converterFactory ?? {
            ConverterDouble(probe: probe, tailValue: tailValue)
        },
        callbackQueue: callbackQueue,
        invalidationObserver: invalidationObserver
    )
}

@Test
func converts48kInterleavedStereoToOwned16kMonoFrames() throws {
    let buffer = makeFloatBuffer(
        sampleRate: 48_000,
        channels: 2,
        frameCount: 4_800,
        interleaved: true
    ) { frame, channel in
        let ramp = Float(frame) / 48_000
        return (channel == 0 ? 0.2 : 0.6) + ramp
    }
    let converter = VoicePCMConverter()

    var frames = try converter.append(buffer)
    // Mutating the source storage after append must not affect returned frames.
    buffer.floatChannelData?[0][0] = -1
    frames.append(contentsOf: try converter.finish(padTail: true))

    let samples = flattened(frames)
    #expect(frames.count == 5)
    #expect(frames.allSatisfy { $0.isValid })
    #expect(abs(samples[800] - 0.45) < 0.025)
    #expect(samples[300] < samples[1_300])
    #expect(samples[0] > -0.5)
}

@Test
func converts44_1kMonoWithStableAmplitudeAndOrder() throws {
    let buffer = makeFloatBuffer(
        sampleRate: 44_100,
        channels: 1,
        frameCount: 4_410
    ) { frame, _ in
        0.15 + Float(frame) / 88_200
    }
    let converter = VoicePCMConverter()

    var frames = try converter.append(buffer)
    frames.append(contentsOf: try converter.finish(padTail: true))
    let samples = flattened(frames)

    #expect(frames.count == 5)
    #expect(abs(samples[800] - 0.175) < 0.025)
    #expect(mean(samples[200..<500]) < mean(samples[1_100..<1_400]))
}

@Test
func framingPreservesOrderAcrossInputBufferBoundaries() throws {
    let first = makeFloatBuffer(
        sampleRate: 48_000,
        channels: 1,
        frameCount: 480
    ) { _, _ in 0.1 }
    let second = makeFloatBuffer(
        sampleRate: 48_000,
        channels: 1,
        frameCount: 480
    ) { _, _ in 0.5 }
    let converter = VoicePCMConverter()

    var frames = try converter.append(first)
    frames.append(contentsOf: try converter.append(second))
    frames.append(contentsOf: try converter.finish(padTail: true))

    #expect(frames.count == 1)
    #expect(mean(frames[0].samples[40..<120]) < 0.2)
    #expect(mean(frames[0].samples[210..<290]) > 0.4)
}

@Test
func normalFinishPadsOnlyTheFinalPartialFrame() throws {
    let buffer = makeFloatBuffer(
        sampleRate: 48_000,
        channels: 1,
        frameCount: 480
    ) { _, _ in 0.3 }
    let converter = VoicePCMConverter()

    var frames = try converter.append(buffer)
    frames.append(contentsOf: try converter.finish(padTail: true))

    #expect(frames.count == 1)
    #expect(frames[0].isValid)
    #expect(mean(frames[0].samples[40..<120]) > 0.25)
    #expect(frames[0].samples.suffix(100).allSatisfy { $0 == 0 })
}

@Test
func discardDropsConverterAndFramingTail() throws {
    let buffer = makeFloatBuffer(
        sampleRate: 48_000,
        channels: 1,
        frameCount: 480
    ) { _, _ in 0.3 }
    let converter = VoicePCMConverter()

    #expect(try converter.append(buffer).isEmpty)
    converter.discard()
    #expect(try converter.finish(padTail: true).isEmpty)
}

@Test
func invalidAndNonFiniteInputsFailClosed() throws {
    let converter = VoicePCMConverter()
    #expect(throws: VoicePCMConversionError.self) {
        try converter.append(makeInt16Buffer())
    }
    #expect(throws: VoicePCMConversionError.self) {
        try VoicePCMInputChunk(
            sampleRate: .nan,
            channelCount: 1,
            frameCount: 1,
            storageLayout: .planar,
            samples: [0]
        )
    }
    #expect(throws: VoicePCMConversionError.self) {
        try VoicePCMInputChunk(
            sampleRate: 48_000,
            channelCount: 3,
            frameCount: 1,
            storageLayout: .interleaved,
            samples: [0, 0, 0]
        )
    }
    #expect(throws: VoicePCMConversionError.self) {
        try VoicePCMInputChunk(
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 1,
            storageLayout: .planar,
            samples: [.infinity]
        )
    }
}

@Test
func deniedMicrophoneAuthorizationFailsWithoutOpeningCapture() async throws {
    let authorization = MicrophoneAuthorizationDouble(.denied)
    let capture = PCMInputCaptureDouble()
    let source = makeSource(authorization: authorization, capture: capture)
    let collector = PCMCallbackCollector()

    try source.start(
        onFrame: collector.append,
        onFailure: collector.append
    )

    #expect(await waitUntil { !collector.failures.isEmpty })
    #expect(collector.failures == [
        VoicePCMSourceFailure(code: .micDenied, retryable: false),
    ])
    #expect(collector.frames.isEmpty)
    #expect(capture.startCount == 0)
    #expect(authorization.requestCount == 0)
}

@Test
func cancelInvalidatesAStartBlockedInAuthorizationStatus() throws {
    let authorization = MicrophoneAuthorizationDouble(
        .authorized,
        blocksStatusQuery: true
    )
    let capture = PCMInputCaptureDouble()
    let source = makeSource(authorization: authorization, capture: capture)
    let startReturned = DispatchSemaphore(value: 0)
    let cancelReturned = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
        try? source.start(onFrame: { _ in }, onFailure: { _ in })
        startReturned.signal()
    }
    #expect(authorization.waitForStatusQuery())

    DispatchQueue.global().async {
        source.cancel()
        cancelReturned.signal()
    }
    #expect(waitSucceeded(cancelReturned, timeout: 0.25))

    authorization.releaseStatusQuery()
    #expect(waitSucceeded(startReturned))
    #expect(capture.startCount == 0)
    #expect(authorization.requestCount == 0)
}

@Test
func stopInvalidatesAStartBlockedInAuthorizationStatus() throws {
    let authorization = MicrophoneAuthorizationDouble(
        .notDetermined,
        blocksStatusQuery: true
    )
    let capture = PCMInputCaptureDouble()
    let source = makeSource(authorization: authorization, capture: capture)
    let startReturned = DispatchSemaphore(value: 0)
    let stopReturned = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
        try? source.start(onFrame: { _ in }, onFailure: { _ in })
        startReturned.signal()
    }
    #expect(authorization.waitForStatusQuery())

    DispatchQueue.global().async {
        source.stop()
        stopReturned.signal()
    }
    #expect(waitSucceeded(stopReturned, timeout: 0.25))

    authorization.releaseStatusQuery()
    #expect(waitSucceeded(startReturned))
    #expect(capture.startCount == 0)
    #expect(authorization.requestCount == 0)
}

@Test
func asynchronousAuthorizationDenialFailsClosed() async throws {
    let authorization = MicrophoneAuthorizationDouble(.notDetermined)
    let capture = PCMInputCaptureDouble()
    let source = makeSource(authorization: authorization, capture: capture)
    let collector = PCMCallbackCollector()

    try source.start(
        onFrame: collector.append,
        onFailure: collector.append
    )
    authorization.resolve(.denied)

    #expect(await waitUntil { !collector.failures.isEmpty })
    #expect(collector.failures == [
        VoicePCMSourceFailure(code: .micDenied, retryable: false),
    ])
    #expect(capture.startCount == 0)
}

@Test
func cancelFencesADeniedCallbackAlreadyQueuedForDelivery() throws {
    let authorization = MicrophoneAuthorizationDouble(.denied)
    let capture = PCMInputCaptureDouble()
    let callbackQueue = DispatchQueue(
        label: "test.voice-pcm-source.blocked-callback"
    )
    let callbackBlockEntered = DispatchSemaphore(value: 0)
    let callbackBlockRelease = DispatchSemaphore(value: 0)
    let sessionInvalidated = DispatchSemaphore(value: 0)
    callbackQueue.async {
        callbackBlockEntered.signal()
        callbackBlockRelease.wait()
    }
    #expect(waitSucceeded(callbackBlockEntered))

    let source = makeSource(
        authorization: authorization,
        capture: capture,
        callbackQueue: callbackQueue,
        invalidationObserver: { sessionInvalidated.signal() }
    )
    let collector = PCMCallbackCollector()
    try source.start(
        onFrame: collector.append,
        onFailure: collector.append
    )

    let cancelReturned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        source.cancel()
        cancelReturned.signal()
    }
    #expect(waitSucceeded(sessionInvalidated))
    #expect(!waitSucceeded(cancelReturned, timeout: 0.05))

    callbackBlockRelease.signal()
    #expect(waitSucceeded(cancelReturned))
    #expect(collector.frames.isEmpty)
    #expect(collector.failures.isEmpty)
    #expect(capture.startCount == 0)
}

@Test
func stopWhileAuthorizationIsPendingInvalidatesLateGrant() async throws {
    let authorization = MicrophoneAuthorizationDouble(.notDetermined)
    let capture = PCMInputCaptureDouble()
    let source = makeSource(authorization: authorization, capture: capture)
    let collector = PCMCallbackCollector()

    try source.start(
        onFrame: collector.append,
        onFailure: collector.append
    )
    source.stop()
    authorization.resolve(.authorized)
    try? await Task.sleep(for: .milliseconds(25))

    #expect(capture.startCount == 0)
    #expect(collector.frames.isEmpty)
    #expect(collector.failures.isEmpty)
}

@Test
func cancelWhileAuthorizationIsPendingInvalidatesLateGrant() async throws {
    let authorization = MicrophoneAuthorizationDouble(.notDetermined)
    let capture = PCMInputCaptureDouble()
    let source = makeSource(authorization: authorization, capture: capture)
    let collector = PCMCallbackCollector()

    try source.start(
        onFrame: collector.append,
        onFailure: collector.append
    )
    source.cancel()
    authorization.resolve(.authorized)
    try? await Task.sleep(for: .milliseconds(25))

    #expect(capture.startCount == 0)
    #expect(collector.frames.isEmpty)
    #expect(collector.failures.isEmpty)
}

@Test
func sourceIsIdempotentAndRejectsLateTapGenerations() async throws {
    let authorization = MicrophoneAuthorizationDouble(.authorized)
    let capture = PCMInputCaptureDouble()
    let source = makeSource(authorization: authorization, capture: capture)
    let collector = PCMCallbackCollector()

    try source.start(
        onFrame: collector.append,
        onFailure: collector.append
    )
    try source.start(
        onFrame: collector.append,
        onFailure: collector.append
    )
    #expect(capture.startCount == 1)

    capture.emit(makeChunk(value: 0.1), fromStart: 0)
    #expect(await waitUntil { collector.frames.count == 1 })
    source.stop()
    source.stop()
    #expect(capture.stopCount == 1)

    capture.emit(makeChunk(value: 0.9), fromStart: 0)
    try source.start(
        onFrame: collector.append,
        onFailure: collector.append
    )
    capture.emit(makeChunk(value: 0.8), fromStart: 0)
    capture.emit(makeChunk(value: 0.2), fromStart: 1)
    #expect(await waitUntil { collector.frames.count == 2 })
    source.cancel()
    capture.emit(makeChunk(value: 0.7), fromStart: 1)
    try? await Task.sleep(for: .milliseconds(20))

    #expect(collector.frames.map { $0.samples[0] } == [0.1, 0.2])
    #expect(collector.failures.isEmpty)
}

@Test
func boundedBacklogFailsImmediatelyWithRetryableOverload() async throws {
    let authorization = MicrophoneAuthorizationDouble(.authorized)
    let capture = PCMInputCaptureDouble()
    let converter = BlockingConverter()
    let source = makeSource(
        authorization: authorization,
        capture: capture,
        converterFactory: { converter }
    )
    let collector = PCMCallbackCollector()
    try source.start(
        onFrame: collector.append,
        onFailure: collector.append
    )

    capture.emit(makeChunk(value: 0.1), fromStart: 0)
    #expect(converter.waitForBlockedAppend())
    defer { converter.releaseAppend() }

    for index in 1..<AVAudioEnginePCMSource.maximumPendingChunks {
        capture.emit(
            makeChunk(value: Float(index) / 1_000),
            fromStart: 0
        )
    }
    // This chunk exceeds the hard cap while the first conversion is blocked.
    capture.emit(makeChunk(value: 0.9), fromStart: 0)

    #expect(await waitUntil { !collector.failures.isEmpty })
    #expect(collector.failures == [
        VoicePCMSourceFailure(code: .asrOverload, retryable: true),
    ])
    #expect(collector.frames.isEmpty)
}

@Test
func cancelDoesNotWaitBehindABlockedConverter() async throws {
    let authorization = MicrophoneAuthorizationDouble(.authorized)
    let capture = PCMInputCaptureDouble()
    let converter = BlockingConverter()
    let source = makeSource(
        authorization: authorization,
        capture: capture,
        converterFactory: { converter }
    )
    let collector = PCMCallbackCollector()
    try source.start(
        onFrame: collector.append,
        onFailure: collector.append
    )

    // Start a dedicated waiter before creating the blocked conversion. Using
    // DispatchQueue.global() here made the assertion measure shared-pool
    // scheduling latency under the full parallel suite instead of whether
    // cancel itself waits for the converter.
    let cancelReady = DispatchSemaphore(value: 0)
    let beginCancel = DispatchSemaphore(value: 0)
    let cancelReturned = DispatchSemaphore(value: 0)
    let cancelThread = Thread {
        cancelReady.signal()
        beginCancel.wait()
        source.cancel()
        cancelReturned.signal()
    }
    cancelThread.qualityOfService = .userInitiated
    cancelThread.start()
    try #require(waitSucceeded(cancelReady, timeout: 2))

    capture.emit(makeChunk(value: 0.4), fromStart: 0)
    #expect(converter.waitForBlockedAppend())

    beginCancel.signal()
    let returnedBeforeConverterRelease = waitSucceeded(
        cancelReturned,
        timeout: 2
    )

    converter.releaseAppend()
    if !returnedBeforeConverterRelease {
        // Let a genuinely blocked cancellation unwind before the test exits.
        _ = waitSucceeded(cancelReturned, timeout: 2)
    }
    #expect(returnedBeforeConverterRelease)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(collector.frames.isEmpty)
    #expect(collector.failures.isEmpty)
}

@Test
func normalStopFlushesTailButCancelAndFailureDiscardIt() async throws {
    let authorization = MicrophoneAuthorizationDouble(.authorized)

    let stopCapture = PCMInputCaptureDouble()
    let stopProbe = ConverterProbe()
    let stopSource = makeSource(
        authorization: authorization,
        capture: stopCapture,
        probe: stopProbe,
        tailValue: 0.75
    )
    let stopCollector = PCMCallbackCollector()
    try stopSource.start(
        onFrame: stopCollector.append,
        onFailure: stopCollector.append
    )
    stopSource.stop()

    #expect(stopCollector.frames.map { $0.samples[0] } == [0.75])
    #expect(stopProbe.finishCount == 1)
    #expect(stopCollector.failures.isEmpty)

    let cancelCapture = PCMInputCaptureDouble()
    let cancelProbe = ConverterProbe()
    let cancelSource = makeSource(
        authorization: authorization,
        capture: cancelCapture,
        probe: cancelProbe,
        tailValue: 0.8
    )
    let cancelCollector = PCMCallbackCollector()
    try cancelSource.start(
        onFrame: cancelCollector.append,
        onFailure: cancelCollector.append
    )
    cancelSource.cancel()

    #expect(cancelCollector.frames.isEmpty)
    #expect(cancelProbe.finishCount == 0)
    #expect(await waitUntil { cancelProbe.discardCount == 1 })
    #expect(cancelProbe.discardCount == 1)

    let failureCapture = PCMInputCaptureDouble()
    let failureProbe = ConverterProbe()
    let failureSource = makeSource(
        authorization: authorization,
        capture: failureCapture,
        probe: failureProbe,
        tailValue: 0.9
    )
    let failureCollector = PCMCallbackCollector()
    try failureSource.start(
        onFrame: failureCollector.append,
        onFailure: failureCollector.append
    )
    failureCapture.emitFailure(fromStart: 0)

    #expect(await waitUntil { !failureCollector.failures.isEmpty })
    #expect(await waitUntil { failureProbe.discardCount == 1 })
    #expect(failureCollector.frames.isEmpty)
    #expect(failureProbe.finishCount == 0)
    #expect(failureProbe.discardCount == 1)
    #expect(failureCollector.failures == [
        VoicePCMSourceFailure(code: .micUnavailable, retryable: false),
    ])
}

@Test
func stopDrainsAnInFlightTapButCancelDiscardsIt() throws {
    let authorization = MicrophoneAuthorizationDouble(.authorized)

    let stopCapture = PCMInputCaptureDouble()
    let stopSource = makeSource(
        authorization: authorization,
        capture: stopCapture
    )
    let stopCollector = PCMCallbackCollector()
    try stopSource.start(
        onFrame: stopCollector.append,
        onFailure: stopCollector.append
    )
    stopCapture.emitDuringNextStop(makeChunk(value: 0.35))
    stopSource.stop()

    #expect(stopCollector.frames.map { $0.samples[0] } == [0.35])
    #expect(stopCollector.failures.isEmpty)

    let cancelCapture = PCMInputCaptureDouble()
    let cancelSource = makeSource(
        authorization: authorization,
        capture: cancelCapture
    )
    let cancelCollector = PCMCallbackCollector()
    try cancelSource.start(
        onFrame: cancelCollector.append,
        onFailure: cancelCollector.append
    )
    cancelCapture.emitDuringNextStop(makeChunk(value: 0.65))
    cancelSource.cancel()

    #expect(cancelCollector.frames.isEmpty)
    #expect(cancelCollector.failures.isEmpty)
}

@Test
func preauthorizedCaptureStartFailureIsRetryableAndFenced() async throws {
    let authorization = MicrophoneAuthorizationDouble(.authorized)
    let capture = PCMInputCaptureDouble()
    capture.startError = VoicePCMSourceStartError.microphoneUnavailable
    let source = makeSource(authorization: authorization, capture: capture)
    let collector = PCMCallbackCollector()

    try source.start(
        onFrame: collector.append,
        onFailure: collector.append
    )
    #expect(await waitUntil { !collector.failures.isEmpty })
    source.stop()

    #expect(collector.frames.isEmpty)
    #expect(collector.failures == [
        VoicePCMSourceFailure(code: .micUnavailable, retryable: true),
    ])
    #expect(capture.startCount == 1)
}

@Test
func authorizedAfterPromptCaptureStartFailureIsRetryable() async throws {
    let authorization = MicrophoneAuthorizationDouble(.notDetermined)
    let capture = PCMInputCaptureDouble()
    capture.startError = VoicePCMSourceStartError.microphoneUnavailable
    let source = makeSource(authorization: authorization, capture: capture)
    let collector = PCMCallbackCollector()

    try source.start(
        onFrame: collector.append,
        onFailure: collector.append
    )
    #expect(authorization.requestCount == 1)
    authorization.resolve(.authorized)

    #expect(await waitUntil { !collector.failures.isEmpty })
    #expect(collector.frames.isEmpty)
    #expect(collector.failures == [
        VoicePCMSourceFailure(code: .micUnavailable, retryable: true),
    ])
    #expect(capture.startCount == 1)
}
