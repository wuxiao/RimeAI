import Foundation
import RimeAIInputCore
import RimeAIVoiceHelperEngine
@_spi(VoiceEvaluation) import RimeAIVoicePerformanceHelperBridge

struct VoiceEvaluationRunner: Sendable {
    typealias EngineFactory = @Sendable (
        _ plan: VoiceEvaluationPlan,
        _ sourceFactory: any VoicePCMSourceFactory
    ) throws -> any VoiceDictationEngine

    private let engineFactory: EngineFactory
    private let schedule: WAVReplayPCMSource.Schedule?
    private let monotonicNowMilliseconds: @Sendable () -> Double

    static let production = Self(
        engineFactory: { plan, sourceFactory in
            try SherpaOnnxEvaluationVoiceEngineFactory.makeEngine(
                at: plan.artifactDirectory,
                sourceFactory: sourceFactory,
                hotwordProvider: RequestVoiceHotwordProvider()
            )
        }
    )

    init(
        engineFactory: @escaping EngineFactory,
        schedule: WAVReplayPCMSource.Schedule? = nil,
        monotonicNowMilliseconds: @escaping @Sendable () -> Double = {
            ProcessInfo.processInfo.systemUptime * 1_000
        }
    ) {
        self.engineFactory = engineFactory
        self.schedule = schedule
        self.monotonicNowMilliseconds = monotonicNowMilliseconds
    }

    func run(plan: VoiceEvaluationPlan) throws
        -> [VoiceEvaluationObservation]
    {
        let sourceFactory = VoiceEvaluationReplaySourceFactory(
            schedule: schedule,
            monotonicNowMilliseconds: monotonicNowMilliseconds
        )
        let engine = try engineFactory(plan, sourceFactory)
        try Self.validateEngine(engine, against: plan)
        let serverClock = VoiceEvaluationServerClock(
            underlyingNowMilliseconds: monotonicNowMilliseconds
        )
        let core = VoiceDictationServerCore(
            engine: engine,
            monotonicNowMilliseconds: serverClock.now
        )
        let state = VoiceEvaluationRunState(
            expectedEngineID: plan.artifact.engineID
        )
        core.setEmitHandler { outputs in state.consume(outputs) }
        state.consume(core.handle(VoiceHelloRequest()))
        let ready = try state.requireReady()
        try Self.validateReady(ready, against: plan)

        var observations: [VoiceEvaluationObservation] = []
        observations.reserveCapacity(plan.samples.count)
        for (index, sample) in plan.samples.enumerated() {
            let requestID = "evaluation-\(index + 1)"
            try sourceFactory.prepare(sample: sample) {
                do {
                    try state.recordStop(
                        elapsedMilliseconds: serverClock
                            .elapsedSinceRecordedServerAnchor()
                    )
                    state.consume(core.handle(VoiceDictationStop(
                        requestID: requestID
                    )))
                } catch {
                    state.reject()
                }
            }
            serverClock.armForNextStart()
            try state.begin(sampleID: sample.sampleID, requestID: requestID)
            let start = VoiceDictationStart(
                requestID: requestID,
                compositionID: UUID(),
                appSessionID: "voice-evaluation",
                bundleID: "fun.wwcn.rimeai.voice-evaluation",
                mode: .direct,
                deadlineMilliseconds: VoiceDictationConstants
                    .maximumDeadlineMilliseconds,
                maximumDurationMilliseconds: VoiceDictationConstants
                    .maximumDurationMilliseconds,
                hotwordSnapshot: plan.hotwordSnapshot
            )
            state.consume(core.handle(start))
            try sourceFactory.requireConsumed()
            let timeout = sample.durationMilliseconds / 1_000 + 10
            observations.append(try state.waitForTerminal(
                timeoutSeconds: timeout
            ))
        }
        guard observations.map(\.sampleID) == plan.samples.map(\.sampleID)
        else { throw VoiceEvaluationError.rejected }
        return observations
    }

    private static func validateEngine(
        _ engine: any VoiceDictationEngine,
        against plan: VoiceEvaluationPlan
    ) throws {
        let descriptor = engine.descriptor
        guard descriptor.isStructurallyValid,
              descriptor.hasIntegrityVerifiedProductArtifact,
              descriptor.networkPolicy == .offline,
              descriptor.capabilities.contains(.localASR),
              descriptor.capabilities.contains(.streaming),
              !plan.policy.hotwordsEnabled
                  || descriptor.capabilities.contains(.hotwordSnapshot),
              !descriptor.capabilities.contains(.cloudASR),
              !descriptor.capabilities.contains(.polish),
              descriptor.adapterID == plan.artifact.adapterID,
              descriptor.artifactID?.rawValue == plan.artifact.artifactID,
              descriptor.artifactSHA256
                == plan.artifact.artifactContentSHA256,
              descriptor.protocolEngineID == plan.artifact.engineID,
              descriptor.supportedLocales.contains(plan.recognizerLocale)
        else { throw VoiceEvaluationError.rejected }
    }

    private static func validateReady(
        _ ready: VoiceReadyResponse,
        against plan: VoiceEvaluationPlan
    ) throws {
        let capabilities = Set(ready.capabilities)
        guard ready.isCompatible,
              ready.networkPolicy == .offline,
              capabilities.contains(VoiceEngineCapability.localASR.rawValue),
              capabilities.contains(VoiceEngineCapability.streaming.rawValue),
              !plan.policy.hotwordsEnabled
                || capabilities.contains(
                    VoiceEngineCapability.hotwordSnapshot.rawValue
                ),
              !capabilities.contains(VoiceEngineCapability.cloudASR.rawValue),
              !capabilities.contains(VoiceEngineCapability.polish.rawValue),
              plan.hotwordSnapshot.phrases.count <= ready.maximumHotwords,
              ready.asrEngineID == plan.artifact.engineID
        else { throw VoiceEvaluationError.rejected }
    }
}

private final class VoiceEvaluationServerClock: @unchecked Sendable {
    private let lock = NSLock()
    private let underlyingNowMilliseconds: @Sendable () -> Double
    private var shouldRecordAnchor = false
    private var recordedAnchorMilliseconds: Double?

    init(
        underlyingNowMilliseconds: @escaping @Sendable () -> Double
    ) {
        self.underlyingNowMilliseconds = underlyingNowMilliseconds
    }

    func armForNextStart() {
        lock.lock()
        shouldRecordAnchor = true
        recordedAnchorMilliseconds = nil
        lock.unlock()
    }

    func now() -> Double {
        let value = underlyingNowMilliseconds()
        lock.lock()
        if shouldRecordAnchor {
            recordedAnchorMilliseconds = value
            shouldRecordAnchor = false
        }
        lock.unlock()
        return value
    }

    func elapsedSinceRecordedServerAnchor() throws -> Double {
        let value = underlyingNowMilliseconds()
        lock.lock()
        let anchor = recordedAnchorMilliseconds
        lock.unlock()
        guard let anchor,
              value.isFinite,
              anchor.isFinite,
              value >= anchor
        else { throw VoiceEvaluationError.rejected }
        return value - anchor
    }
}

private final class VoiceEvaluationReplaySourceFactory:
    VoicePCMSourceFactory,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let schedule: WAVReplayPCMSource.Schedule?
    private let monotonicNowMilliseconds:
        WAVReplayPCMSource.MonotonicNowMilliseconds
    private var prepared: WAVReplayPCMSource?

    init(
        schedule: WAVReplayPCMSource.Schedule?,
        monotonicNowMilliseconds: @escaping
            WAVReplayPCMSource.MonotonicNowMilliseconds
    ) {
        self.schedule = schedule
        self.monotonicNowMilliseconds = monotonicNowMilliseconds
    }

    func prepare(
        sample: VoiceEvaluationSample,
        onEndOfFile: @escaping @Sendable () -> Void
    ) throws {
        let source: WAVReplayPCMSource
        if let schedule {
            source = try WAVReplayPCMSource(
                audioURL: sample.audioURL,
                expectedSHA256: sample.audioSHA256,
                expectedDurationMilliseconds: sample.durationMilliseconds,
                expectedSampleRateHertz: sample.sampleRateHertz,
                expectedChannels: sample.channels,
                expectedFrameCount: sample.frameCount,
                schedule: schedule,
                monotonicNowMilliseconds: monotonicNowMilliseconds,
                onEndOfFile: onEndOfFile
            )
        } else {
            source = try WAVReplayPCMSource(
                audioURL: sample.audioURL,
                expectedSHA256: sample.audioSHA256,
                expectedDurationMilliseconds: sample.durationMilliseconds,
                expectedSampleRateHertz: sample.sampleRateHertz,
                expectedChannels: sample.channels,
                expectedFrameCount: sample.frameCount,
                onEndOfFile: onEndOfFile
            )
        }
        lock.lock()
        guard prepared == nil else {
            lock.unlock()
            throw VoiceEvaluationError.rejected
        }
        prepared = source
        lock.unlock()
    }

    func makeSource() throws -> any VoicePCMSource {
        lock.lock()
        guard let prepared else {
            lock.unlock()
            throw VoiceEvaluationError.rejected
        }
        self.prepared = nil
        lock.unlock()
        return prepared
    }

    func requireConsumed() throws {
        lock.lock()
        let wasConsumed = prepared == nil
        lock.unlock()
        guard wasConsumed else { throw VoiceEvaluationError.rejected }
    }
}

private final class VoiceEvaluationRunState: @unchecked Sendable {
    private struct ActiveSample {
        let sampleID: String
        let requestID: String
        var partials: [VoiceEvaluationPartial] = []
        var stopElapsedMilliseconds: Double?
        var terminal: VoiceEvaluationObservation?
    }

    private let condition = NSCondition()
    private let expectedEngineID: String
    private var ready: VoiceReadyResponse?
    private var active: ActiveSample?
    private var isRejected = false

    init(expectedEngineID: String) {
        self.expectedEngineID = expectedEngineID
    }

    func begin(sampleID: String, requestID: String) throws {
        condition.lock()
        defer { condition.unlock() }
        guard !isRejected,
              ready != nil,
              active?.terminal != nil || active == nil
        else { throw VoiceEvaluationError.rejected }
        active = ActiveSample(sampleID: sampleID, requestID: requestID)
    }

    func consume(_ outputs: [VoiceDictationServerCore.Output]) {
        condition.lock()
        for output in outputs where !isRejected {
            switch output {
            case let .ready(value):
                guard ready == nil, active == nil else {
                    isRejected = true
                    continue
                }
                ready = value
            case let .delta(value):
                guard var active,
                      active.requestID == value.requestID,
                      active.terminal == nil,
                      active.partials.count < 4_096
                else {
                    isRejected = true
                    continue
                }
                active.partials.append(VoiceEvaluationPartial(
                    sequence: value.sequence,
                    text: value.stableText + value.partialText,
                    elapsedMilliseconds: value.elapsedMilliseconds
                ))
                self.active = active
            case let .final(value):
                guard var active,
                      active.requestID == value.requestID,
                      active.terminal == nil,
                      let stop = active.stopElapsedMilliseconds,
                      value.asrEngineID == expectedEngineID,
                      !value.polishApplied
                else {
                    isRejected = true
                    continue
                }
                active.terminal = .final(
                    sampleID: active.sampleID,
                    partials: active.partials,
                    stopReceivedElapsedMilliseconds: stop,
                    text: value.finalText,
                    confidence: value.confidence,
                    elapsedMilliseconds: value.elapsedMilliseconds
                )
                self.active = active
            case let .error(value):
                guard var active,
                      active.requestID == value.requestID,
                      active.terminal == nil
                else {
                    isRejected = true
                    continue
                }
                if value.errorCode == .asrTimeout,
                   let stop = active.stopElapsedMilliseconds {
                    active.terminal = .noResult(
                        sampleID: active.sampleID,
                        partials: active.partials,
                        stopReceivedElapsedMilliseconds: stop
                    )
                } else {
                    active.terminal = .error(
                        sampleID: active.sampleID,
                        partials: active.partials,
                        stopReceivedElapsedMilliseconds:
                            active.stopElapsedMilliseconds
                    )
                }
                self.active = active
            case .disconnect:
                isRejected = true
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    func requireReady() throws -> VoiceReadyResponse {
        condition.lock()
        defer { condition.unlock() }
        guard !isRejected, let ready else {
            throw VoiceEvaluationError.rejected
        }
        return ready
    }

    func recordStop(elapsedMilliseconds: Double) throws {
        condition.lock()
        defer { condition.unlock() }
        guard !isRejected,
              elapsedMilliseconds.isFinite,
              elapsedMilliseconds >= 0,
              var active,
              active.stopElapsedMilliseconds == nil,
              active.terminal == nil
        else { throw VoiceEvaluationError.rejected }
        active.stopElapsedMilliseconds = elapsedMilliseconds
        self.active = active
    }

    func waitForTerminal(timeoutSeconds: Double) throws
        -> VoiceEvaluationObservation
    {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: max(1, timeoutSeconds))
        while !isRejected, active?.terminal == nil {
            guard condition.wait(until: deadline) else { break }
        }
        guard !isRejected, let terminal = active?.terminal else {
            throw VoiceEvaluationError.rejected
        }
        return terminal
    }

    func reject() {
        condition.lock()
        isRejected = true
        condition.broadcast()
        condition.unlock()
    }
}
