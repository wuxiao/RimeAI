import Foundation
import Testing
@testable import RimeAIInputCore

// MARK: - Manual doubles

/// Records every block the pipeline hands to its scheduling seam so tests
/// fire debounces and queue hops deterministically, without wall-clock
/// waits or real concurrency.
private final class ManualScheduling:
    SemanticSuggestionScheduling, @unchecked Sendable
{
    final class TaskBox: SemanticSuggestionTask, @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }

        func cancel() {
            lock.withLock { cancelled = true }
        }
    }

    struct ScheduledBlock {
        let delay: TimeInterval
        let action: @MainActor () -> Void
        let box: TaskBox
    }

    private let lock = NSLock()
    private var scheduledBlocks: [ScheduledBlock] = []
    private var offMainBlocks: [@Sendable () -> Void] = []
    private var onMainBlocks: [@MainActor () -> Void] = []

    var scheduledDelays: [TimeInterval] {
        lock.withLock { scheduledBlocks.map(\.delay) }
    }

    var pendingScheduledCount: Int {
        lock.withLock { scheduledBlocks.count }
    }

    func scheduleOnMain(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any SemanticSuggestionTask {
        let box = TaskBox()
        lock.withLock {
            scheduledBlocks.append(
                ScheduledBlock(delay: delay, action: action, box: box)
            )
        }
        return box
    }

    func dispatchOffMain(_ action: @escaping @Sendable () -> Void) {
        lock.withLock { offMainBlocks.append(action) }
    }

    func dispatchOnMain(_ action: @escaping @MainActor () -> Void) {
        lock.withLock { onMainBlocks.append(action) }
    }

    /// Fire the next armed debounce timer and return its delay.
    @discardableResult
    @MainActor
    func fireNextScheduled() -> TimeInterval? {
        let block = lock.withLock { () -> ScheduledBlock? in
            guard let first = scheduledBlocks.first else {
                return nil
            }
            scheduledBlocks.removeFirst()
            return first
        }
        guard let block else {
            return nil
        }
        if !block.box.isCancelled {
            block.action()
        }
        return block.delay
    }

    /// Fire every armed debounce timer except the last one.
    @MainActor
    func fireAllButLastScheduled() {
        while pendingScheduledCount > 1 {
            _ = fireNextScheduled()
        }
    }

    @discardableResult
    func runNextOffMain() -> Bool {
        let block = lock.withLock { () -> (@Sendable () -> Void)? in
            guard offMainBlocks.isEmpty else {
                return offMainBlocks.removeFirst()
            }
            return nil
        }
        guard let block else {
            return false
        }
        block()
        return true
    }

    @MainActor
    func runNextOnMain() {
        let block = lock.withLock { () -> (@MainActor () -> Void)? in
            guard onMainBlocks.isEmpty else {
                return onMainBlocks.removeFirst()
            }
            return nil
        }
        block?()
    }
}

/// Mutable knobs the tests flip mid-flight. All access happens on the test
/// thread; `@unchecked Sendable` only satisfies the dependency closures.
private final class HarnessFlags: @unchecked Sendable {
    var secureInput = false
    var localAllowed = true
    var cloudConfigured = false
    var apiKey: String? = "test-api-key"
    var historyGeneration: Int64 = 7
    var historySnapshot = HistoryContextSnapshot(
        recentText: "最近输入",
        relevantSnippets: [],
        generation: 7
    )
    var onHistorySnapshot: (() -> Void)?
    var phraseBookMatches: [PhraseBookEntry] = []
}

/// Wires a pipeline to recording fakes plus a real, controller-owned
/// `CompositionState`. The class is deliberately not actor-isolated: the
/// dependency closures are nonisolated `@Sendable`, mirroring how the IMK
/// controller injects them. Tests drive everything from the main actor.
private final class PipelineHarness: @unchecked Sendable {
    let scheduling = ManualScheduling()
    let flags = HarnessFlags()
    var composition = CompositionState(appSessionID: "app-session")
    var clock: TimeInterval = 1_000

    private(set) var diagnostics: [RimeAIDiagnosticEvent] = []
    private(set) var latencies: [Double] = []
    private(set) var localRequests: [SemanticInferenceRequest] = []
    private(set) var cancelledLocalRequestIDs: [String] = []
    private(set) var cloudRequests: [CloudInferenceRequest] = []
    private(set) var cancelledCloudRequestIDs: [String] = []
    private(set) var appliedCandidates:
        [(
            text: String,
            decision: SemanticInferenceDecision,
            segments: [PinyinSegment]?
        )] = []
    private(set) var secureInputEvents = 0
    private(set) var refreshEvents = 0
    private(set) var cloudDisconnects = 0

    @MainActor
    lazy var pipeline: SemanticSuggestionPipeline =
        SemanticSuggestionPipeline(
            dependencies: SemanticSuggestionDependencies(
                now: { [self] in clock },
                scheduling: scheduling,
                isSecureEventInputEnabled: { [flags] in
                    flags.secureInput
                },
                isLocalInferenceAllowed: { [flags] bundleIdentifier in
                    bundleIdentifier == "com.apple.notes" && flags.localAllowed
                },
                isCloudConfigured: { [flags] in flags.cloudConfigured },
                contextPolicy: { _ in .standard },
                cloudModelID: { RimeAICloudConfiguration.defaultRankingModelID },
                characterSet: { .simplified },
                sendLocalInference: { [self] request, _ in
                    localRequests.append(request)
                },
                cancelLocalInference: { [self] requestID in
                    cancelledLocalRequestIDs.append(requestID)
                },
                clientSessionID: "client-session",
                loadCloudAPIKey: { [flags] in flags.apiKey },
                cloudHistorySnapshot: { [flags] _ in
                    flags.onHistorySnapshot?()
                    return flags.historySnapshot
                },
                currentHistoryGeneration: { [flags] in
                    flags.historyGeneration
                },
                phraseBookPhrases: { [flags] pinyin, _ in
                    flags.phraseBookMatches.filter {
                        $0.pinyinKeys == pinyin
                            || $0.pinyinKeys.hasPrefix(pinyin)
                    }
                },
                sendCloudInference: { [self] request, _, _ in
                    cloudRequests.append(request)
                },
                cancelCloudInference: { [self] requestID in
                    cancelledCloudRequestIDs.append(requestID)
                },
                disconnectCloud: { [self] in
                    cloudDisconnects += 1
                },
                compositionSnapshot: { [self] in composition },
                applySemanticCandidate: { [self] text, token, decision, segments in
                    appliedCandidates.append((text, decision, segments))
                    return composition.applySemanticCandidate(
                        text,
                        token: token,
                        decision: decision,
                        segments: segments
                    )
                },
                onEvent: { [self] event in
                    switch event {
                    case let .diagnostic(metric):
                        diagnostics.append(metric)
                    case let .latency(milliseconds):
                        latencies.append(milliseconds)
                    case .secureInputDetected:
                        secureInputEvents += 1
                    case .suggestionSlotChanged:
                        refreshEvents += 1
                    }
                }
            )
        )

    /// A composition with fresh candidates for `pinyin`, mirroring what
    /// `compositionInput` leaves behind before scheduling.
    @MainActor
    func typePinyin(_ pinyin: String, candidates: [String]) {
        _ = composition.replaceInput(pinyin: pinyin, candidates: candidates)
    }

    /// Drive the local send path: schedule and fire the 100 ms debounce so
    /// `sendInference` runs synchronously.
    @MainActor
    @discardableResult
    func runLocalSendCycle(
        bundleIdentifier: String? = "com.apple.notes"
    ) -> SemanticInferenceRequest? {
        pipeline.scheduleInference(
            token: composition.token,
            bundleIdentifier: bundleIdentifier,
            contextProvider: { policy in
                policy == .strict ? "" : "上下文"
            }
        )
        guard scheduling.fireNextScheduled() != nil else {
            return nil
        }
        return localRequests.last
    }

    /// Drive the cloud send path (cloud-only): schedule, fire the 1000 ms
    /// debounce, run the background assembly and the main-queue validation,
    /// and return the request that reached the transport.
    @MainActor
    @discardableResult
    func runCloudSendCycle(
        pinyin: String = "nihao"
    ) -> CloudInferenceRequest? {
        flags.localAllowed = false
        flags.cloudConfigured = true
        pipeline.scheduleInference(
            token: composition.token,
            bundleIdentifier: "com.apple.notes",
            contextProvider: { _ in "" }
        )
        // The first armed timer is the (empty) local debounce; the cloud
        // debounce follows at 1000 ms.
        scheduling.fireAllButLastScheduled()
        guard scheduling.fireNextScheduled() != nil else {
            return nil
        }
        guard scheduling.runNextOffMain() else {
            return nil
        }
        scheduling.runNextOnMain()
        return cloudRequests.last
    }

    /// Fabricate a structurally valid response for `request`.
    func makeCloudResponse(
        for request: CloudInferenceRequest,
        decision: CloudInferenceDecision = .abstain,
        confidence: Double? = nil,
        generatedText: String? = nil,
        generatedPinyin: String? = nil,
        generatedSegments: String? = nil,
        requestID: String? = nil,
        historyGeneration: Int64? = nil
    ) -> CloudInferenceResponse {
        CloudInferenceResponse(
            requestID: requestID ?? request.requestID,
            compositionID: request.compositionID,
            revision: request.revision,
            appSessionID: request.appSessionID,
            clientSessionID: request.clientSessionID,
            historyGeneration: historyGeneration ?? request.historyGeneration,
            decision: decision,
            confidence: confidence,
            reason: .contextMatch,
            modelID: request.modelID,
            elapsedMilliseconds: 12,
            generatedText: generatedText,
            generatedPinyin: generatedPinyin,
            generatedSegments: generatedSegments
        )
    }
}

// MARK: - Debounce timings

@Test @MainActor
func debounceTimingsStayExactDualChannel() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好"])
    harness.flags.cloudConfigured = true

    harness.pipeline.scheduleInference(
        token: harness.composition.token,
        bundleIdentifier: "com.apple.notes",
        contextProvider: { _ in "上下文" }
    )

    #expect(
        harness.scheduling.scheduledDelays == [
            SemanticSuggestionPipeline.localDebounceInterval,
            SemanticSuggestionPipeline.cloudDebounceInterval,
        ]
    )
    #expect(SemanticSuggestionPipeline.localDebounceInterval == 0.1)
    #expect(SemanticSuggestionPipeline.cloudDebounceInterval == 1.0)
}

@Test @MainActor
func cloudOnlyModeStillArmsBothTimersAndSkipsLocalSend() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好"])
    harness.flags.localAllowed = false
    harness.flags.cloudConfigured = true

    harness.pipeline.scheduleInference(
        token: harness.composition.token,
        bundleIdentifier: "com.apple.notes",
        contextProvider: { _ in "" }
    )

    #expect(harness.pipeline.presentation == .cloudAnalyzing)
    // The empty local debounce must not send anything.
    _ = harness.scheduling.fireNextScheduled()
    #expect(harness.localRequests.isEmpty)
    _ = harness.scheduling.fireNextScheduled()
    #expect(harness.cloudRequests.isEmpty)
    #expect(harness.scheduling.runNextOffMain())
}

// MARK: - Request gating

@Test @MainActor
func gatingRejectsOversizedPinyin() {
    let harness = PipelineHarness()
    harness.typePinyin(
        String(repeating: "a", count: 257),
        candidates: ["啊"]
    )

    harness.pipeline.scheduleInference(
        token: harness.composition.token,
        bundleIdentifier: "com.apple.notes",
        contextProvider: { _ in "" }
    )

    #expect(harness.pipeline.presentation == .inputTooLong)
    #expect(harness.pipeline.contextCharacterCount == 0)
    #expect(harness.scheduling.pendingScheduledCount == 0)
    #expect(harness.diagnostics.isEmpty)
}

@Test @MainActor
func gatingAtBoundaryPinyin256StillSchedules() {
    let harness = PipelineHarness()
    harness.typePinyin(
        String(repeating: "a", count: 256),
        candidates: ["啊"]
    )

    harness.pipeline.scheduleInference(
        token: harness.composition.token,
        bundleIdentifier: "com.apple.notes",
        contextProvider: { _ in "" }
    )

    #expect(harness.pipeline.presentation == .analyzing)
    #expect(harness.scheduling.pendingScheduledCount == 1)
}

@Test @MainActor
func gatingBlocksPrivacySensitiveScheduling() {
    // Missing bundle identifier: nothing can be policy-checked.
    let missingBundle = PipelineHarness()
    missingBundle.typePinyin("nihao", candidates: ["你好"])
    missingBundle.pipeline.scheduleInference(
        token: missingBundle.composition.token,
        bundleIdentifier: nil,
        contextProvider: { _ in "" }
    )
    #expect(missingBundle.pipeline.presentation == .unavailable)
    #expect(missingBundle.diagnostics == [.privacyBlocked])
    #expect(missingBundle.scheduling.pendingScheduledCount == 0)

    // Secure input active at schedule time: same fail-closed outcome.
    let secure = PipelineHarness()
    secure.typePinyin("nihao", candidates: ["你好"])
    secure.flags.secureInput = true
    secure.pipeline.scheduleInference(
        token: secure.composition.token,
        bundleIdentifier: "com.apple.notes",
        contextProvider: { _ in "" }
    )
    #expect(secure.pipeline.presentation == .unavailable)
    #expect(secure.diagnostics == [.privacyBlocked])
    #expect(secure.scheduling.pendingScheduledCount == 0)
}

@Test @MainActor
func gatingBlocksCompositionSecureInput() {
    let harness = PipelineHarness()
    harness.composition.enterSecureInput()

    harness.pipeline.scheduleInference(
        token: harness.composition.token,
        bundleIdentifier: "com.apple.notes",
        contextProvider: { _ in "" }
    )

    #expect(harness.pipeline.presentation == .unavailable)
    #expect(harness.diagnostics == [.privacyBlocked])
}

@Test @MainActor
func gatingBlocksDisallowedAppWithoutCloud() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好"])

    harness.pipeline.scheduleInference(
        token: harness.composition.token,
        bundleIdentifier: "com.terminals.xterm",
        contextProvider: { _ in "" }
    )

    #expect(harness.pipeline.presentation == .unavailable)
    #expect(harness.scheduling.pendingScheduledCount == 0)
    #expect(harness.diagnostics.isEmpty)
}

// MARK: - Local result ladder

@Test @MainActor
func latestRequestWinsRejectsLateLocalResult() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好"])
    guard let first = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }
    harness.typePinyin("nihao", candidates: ["你好", "拟好"])
    guard let second = harness.runLocalSendCycle() else {
        Issue.record("second local request must be sent")
        return
    }
    #expect(first.requestID != second.requestID)

    // The first (now superseded) response lands after the second was sent.
    harness.pipeline.applyInferenceResult(
        nil,
        requestID: first.requestID,
        token: harness.composition.token
    )

    #expect(
        harness.diagnostics.suffix(1) == [.staleResult],
        "superseded response must be counted stale"
    )
    #expect(harness.pipeline.presentation == .analyzing)
}

@Test @MainActor
func circuitOpenStatusRecordsDiagnosticAndFailsPresentation() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好"])
    let token = harness.composition.token
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }

    harness.pipeline.applyInferenceResult(
        SemanticInferenceResult(
            status: "circuit_open",
            requestID: request.requestID,
            compositionID: nil,
            revision: nil,
            appSessionID: nil,
            rankedCandidate: nil,
            sentenceSuggestion: nil,
            confidence: nil
        ),
        requestID: request.requestID,
        token: token
    )

    #expect(harness.pipeline.presentation == .failure)
    #expect(harness.diagnostics.contains(.circuitOpen))
    #expect(harness.latencies == [0])
}

@Test @MainActor
func secureInputActivatingMidFlightDefersToSecureHandling() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好"])
    let token = harness.composition.token
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }
    harness.flags.secureInput = true

    harness.pipeline.applyInferenceResult(
        okRankedResult(request, candidate: "你好"),
        requestID: request.requestID,
        token: token
    )

    #expect(harness.secureInputEvents == 1)
    #expect(!harness.diagnostics.contains(.staleResult))
    #expect(harness.pipeline.presentation == .analyzing)
    #expect(harness.appliedCandidates.isEmpty)
}

@Test @MainActor
func localResultEchoingWrongCompositionIsStale() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好"])
    let token = harness.composition.token
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }

    harness.pipeline.applyInferenceResult(
        SemanticInferenceResult(
            status: "ok",
            requestID: request.requestID,
            compositionID: UUID().uuidString,
            revision: request.revision,
            appSessionID: request.appSessionID,
            rankedCandidate: "你好",
            sentenceSuggestion: nil,
            confidence: 0.9,
            decision: .rankedCandidate
        ),
        requestID: request.requestID,
        token: token
    )

    #expect(harness.diagnostics.suffix(1) == [.staleResult])
    #expect(harness.pipeline.presentation == .idle)
    #expect(harness.appliedCandidates.isEmpty)
}

@Test @MainActor
func localResultForExpiredTokenFailsCandidateApplication() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好"])
    let token = harness.composition.token
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }
    // The composition moved on, so the live-token guard inside
    // `isValid`/`applySemanticCandidate` must refuse the stale candidate.
    harness.typePinyin("niha", candidates: ["你"])

    harness.pipeline.applyInferenceResult(
        okRankedResult(request, candidate: "你好"),
        requestID: request.requestID,
        token: token
    )

    #expect(harness.diagnostics.suffix(1) == [.invalidResult])
    #expect(harness.pipeline.presentation == .failure)
}

@Test @MainActor
func validLocalResultOwnsTheSlot() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好"])
    let token = harness.composition.token
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }

    harness.pipeline.applyInferenceResult(
        okRankedResult(request, candidate: "你好"),
        requestID: request.requestID,
        token: token
    )

    guard case let .candidate(text, decision, confidence) =
        harness.pipeline.presentation
    else {
        Issue.record("local candidate must be shown")
        return
    }
    #expect(text == "你好")
    #expect(decision == .rankedCandidate)
    #expect(confidence == 0.9)
    #expect(harness.pipeline.historySource == .localSemantic)
    #expect(harness.pipeline.cloudCandidate == nil)
    #expect(harness.diagnostics.contains(.resultShown))
    #expect(harness.diagnostics.contains(.rankedCandidateShown))
}

/// Helper: a structurally well-formed ranked-candidate result echoing
/// `request`.
private func okRankedResult(
    _ request: SemanticInferenceRequest,
    candidate: String
) -> SemanticInferenceResult {
    SemanticInferenceResult(
        status: "ok",
        requestID: request.requestID,
        compositionID: request.compositionID,
        revision: request.revision,
        appSessionID: request.appSessionID,
        rankedCandidate: candidate,
        sentenceSuggestion: nil,
        confidence: 0.9,
        decision: .rankedCandidate
    )
}

/// Helper: a well-formed local result whose daemon abstained with no
/// usable candidate.
private func noCandidateResult(
    _ request: SemanticInferenceRequest
) -> SemanticInferenceResult {
    SemanticInferenceResult(
        status: "ok",
        requestID: request.requestID,
        compositionID: request.compositionID,
        revision: request.revision,
        appSessionID: request.appSessionID,
        rankedCandidate: nil,
        sentenceSuggestion: nil,
        confidence: 0.1,
        decision: .noCandidate
    )
}

/// Helper: one phrasebook entry for the fallback slot tests.
private func phraseEntry(
    _ text: String,
    pinyin: String,
    count: Int = 5
) -> PhraseBookEntry {
    PhraseBookEntry(
        id: "phrase-\(text)",
        domain: PhraseBookDomain.global,
        text: text,
        pinyinKeys: pinyin,
        count: count,
        firstSeenAt: Date(timeIntervalSince1970: 0),
        lastUsedAt: Date(timeIntervalSince1970: 100),
        source: .auto,
        isProtected: false
    )
}

// MARK: - L1 phrasebook fallback (LP-006)

@Test @MainActor
func phraseBookFillsTheSlotWhenLocalYieldsNoCandidate() {
    let harness = PipelineHarness()
    harness.typePinyin("wwcn", candidates: ["问", "稳"])
    harness.flags.phraseBookMatches = [
        phraseEntry("wayne专属短语", pinyin: "wwcn")
    ]
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }

    harness.pipeline.applyInferenceResult(
        noCandidateResult(request),
        requestID: request.requestID,
        token: harness.composition.token
    )

    guard case let .candidate(text, decision, _) =
        harness.pipeline.presentation
    else {
        Issue.record("phrasebook phrase must fill the empty slot")
        return
    }
    #expect(text == "wayne专属短语")
    #expect(decision == .phraseBook)
    #expect(harness.pipeline.historySource == .phraseBook)
    #expect(harness.appliedCandidates.map(\.text) == ["wayne专属短语"])
    // REQ-KBD-02: numeric candidates stay in place; only the independent
    // suggestion slot received the phrase.
    #expect(harness.composition.mainCandidates == ["问", "稳"])
    #expect(harness.diagnostics.contains(.phraseBookSuggestionShown))
}

@Test @MainActor
func phraseBookWaitsForTheCloudCycleToResolve() {
    let harness = PipelineHarness()
    harness.typePinyin("wwcn", candidates: ["问", "稳"])
    harness.flags.phraseBookMatches = [
        phraseEntry("wayne专属短语", pinyin: "wwcn")
    ]
    harness.flags.cloudConfigured = true
    let token = harness.composition.token
    harness.pipeline.scheduleInference(
        token: token,
        bundleIdentifier: "com.apple.notes",
        contextProvider: { _ in "" }
    )
    // Local debounce sends the daemon request.
    _ = harness.scheduling.fireNextScheduled()
    guard let request = harness.localRequests.last else {
        Issue.record("local request must be sent")
        return
    }
    harness.pipeline.applyInferenceResult(
        noCandidateResult(request),
        requestID: request.requestID,
        token: token
    )
    // 云端周期仍在途：本地无建议也不能抢先填 L1。
    #expect(harness.pipeline.presentation == .noCandidate)
    #expect(harness.appliedCandidates.isEmpty)

    // Cloud round trip fails → both channels are empty → L1 fills.
    _ = harness.scheduling.fireNextScheduled()
    #expect(harness.scheduling.runNextOffMain())
    harness.scheduling.runNextOnMain()
    guard let cloudRequest = harness.cloudRequests.last else {
        Issue.record("cloud request must reach the transport")
        return
    }
    harness.pipeline.applyCloudInferenceResult(
        nil,
        request: cloudRequest,
        token: token,
        deadlineAt: harness.clock + 4.0,
        localRequestWasScheduled: true
    )

    guard case let .candidate(text, decision, _) =
        harness.pipeline.presentation
    else {
        Issue.record("phrasebook phrase must fill after cloud failure")
        return
    }
    #expect(text == "wayne专属短语")
    #expect(decision == .phraseBook)
}

@Test @MainActor
func appliedCloudDecisionBlocksThePhraseBookFill() {
    let harness = PipelineHarness()
    harness.typePinyin("wwcn", candidates: ["问", "稳"])
    harness.flags.phraseBookMatches = [
        phraseEntry("wayne专属短语", pinyin: "wwcn")
    ]
    guard let request = harness.runCloudSendCycle(pinyin: "wwcn") else {
        Issue.record("cloud request must reach the transport")
        return
    }

    harness.pipeline.applyCloudInferenceResult(
        harness.makeCloudResponse(
            for: request,
            decision: .generate,
            confidence: 0.9,
            generatedText: "温文稳问",
            generatedPinyin: "wwcn"
        ),
        request: request,
        token: harness.composition.token,
        deadlineAt: harness.clock + 4.0,
        localRequestWasScheduled: false
    )

    #expect(harness.pipeline.cloudSuggestionApplied)
    guard case let .candidate(text, decision, _) =
        harness.pipeline.presentation
    else {
        Issue.record("cloud candidate must own the slot")
        return
    }
    #expect(text == "温文稳问")
    #expect(decision == .sentenceSuggestion)
    #expect(!harness.diagnostics.contains(.phraseBookSuggestionShown))
}

@Test @MainActor
func validLocalCandidateBlocksThePhraseBookFill() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好", "拟好"])
    harness.flags.phraseBookMatches = [
        phraseEntry("你好世界", pinyin: "nihaoshijie")
    ]
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }

    harness.pipeline.applyInferenceResult(
        okRankedResult(request, candidate: "你好"),
        requestID: request.requestID,
        token: harness.composition.token
    )

    #expect(harness.pipeline.historySource == .localSemantic)
    #expect(!harness.diagnostics.contains(.phraseBookSuggestionShown))
    #expect(harness.appliedCandidates.map(\.text) == ["你好"])
}

@Test @MainActor
func emptyPhrasebookLeavesTheEmptySlotAlone() {
    let harness = PipelineHarness()
    harness.typePinyin("wwcn", candidates: ["问", "稳"])
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }

    harness.pipeline.applyInferenceResult(
        noCandidateResult(request),
        requestID: request.requestID,
        token: harness.composition.token
    )

    #expect(harness.pipeline.presentation == .noCandidate)
    #expect(harness.appliedCandidates.isEmpty)
    #expect(!harness.diagnostics.contains(.phraseBookSuggestionShown))
}

@Test @MainActor
func secureInputBlocksThePhraseBookFill() {
    let harness = PipelineHarness()
    harness.typePinyin("wwcn", candidates: ["问", "稳"])
    harness.flags.phraseBookMatches = [
        phraseEntry("wayne专属短语", pinyin: "wwcn")
    ]
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }
    harness.flags.secureInput = true

    harness.pipeline.applyInferenceResult(
        noCandidateResult(request),
        requestID: request.requestID,
        token: harness.composition.token
    )

    #expect(harness.secureInputEvents == 1)
    #expect(harness.appliedCandidates.isEmpty)
    #expect(!harness.diagnostics.contains(.phraseBookSuggestionShown))
}

// MARK: - Cloud guard ladder (frozen order, table-driven)

/// One row per broken rung of the frozen ladder: request id → secure
/// input → composition token/isSelecting → history generation → deadline
/// → structural validation.
private enum CloudLadderRow: String, CaseIterable {
    case replacedRequest = "replaced-request"
    case secureInputMidFlight = "secure-input-mid-flight"
    case tokenMismatch = "token-mismatch"
    case selecting = "selecting"
    case historyGenerationChange = "history-generation-change"
    case deadlineExceeded = "deadline-exceeded"
    case missingResult = "missing-result"
    case invalidResponse = "invalid-response"
}

@Test(arguments: CloudLadderRow.allCases.map(\.rawValue))
@MainActor
func cloudGuardLadderRejectsBrokenRungs(row: String) {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好"])
    guard let request = harness.runCloudSendCycle() else {
        Issue.record("cloud request must reach the transport")
        return
    }
    let token = harness.composition.token
    #expect(harness.cloudRequests.count == 1)

    var deadline = harness.clock + 4.0
    var response: CloudInferenceResponse? =
        harness.makeCloudResponse(for: request)
    switch CloudLadderRow(rawValue: row) ?? .replacedRequest {
    case .replacedRequest:
        // A newer cloud cycle already claimed the pending slot.
        harness.pipeline.invalidate()
        _ = harness.runCloudSendCycle()
        response = harness.makeCloudResponse(for: request)
    case .secureInputMidFlight:
        harness.flags.secureInput = true
    case .tokenMismatch:
        harness.typePinyin("niha", candidates: ["你"])
    case .selecting:
        harness.composition.beginSelection()
    case .historyGenerationChange:
        // A commit landed between request and response.
        harness.flags.historyGeneration += 1
    case .deadlineExceeded:
        harness.clock += 5.0
        deadline = harness.clock - 1.0
    case .missingResult:
        response = nil
    case .invalidResponse:
        response = harness.makeCloudResponse(
            for: request,
            requestID: "not-the-request"
        )
    }

    harness.pipeline.applyCloudInferenceResult(
        response,
        request: request,
        token: token,
        deadlineAt: deadline,
        localRequestWasScheduled: false
    )

    #expect(harness.pipeline.cloudSuggestionApplied == false)
    #expect(harness.pipeline.cloudCandidate == nil)
    switch CloudLadderRow(rawValue: row) ?? .replacedRequest {
    case .replacedRequest,
         .tokenMismatch,
         .selecting,
         .historyGenerationChange:
        #expect(harness.diagnostics.contains(.staleResult))
        #expect(harness.pipeline.presentation == .cloudAnalyzing)
    case .secureInputMidFlight:
        #expect(harness.secureInputEvents == 1)
        #expect(!harness.diagnostics.contains(.staleResult))
    case .deadlineExceeded:
        #expect(harness.diagnostics.contains(.cloudTimeout))
        #expect(harness.pipeline.presentation == .cloudFailure)
    case .missingResult:
        #expect(harness.diagnostics.contains(.cloudTransportFailure))
        #expect(harness.pipeline.presentation == .cloudFailure)
    case .invalidResponse:
        #expect(harness.diagnostics.contains(.cloudInvalidResult))
        #expect(harness.pipeline.presentation == .cloudFailure)
    }
}

// MARK: - Cloud happy paths

@Test @MainActor
func cloudValidGeneratedSentenceOwnsTheSlot() {
    let harness = PipelineHarness()
    harness.typePinyin("wnshiysgr", candidates: ["我"])
    guard let request = harness.runCloudSendCycle(pinyin: "wnshiysgr") else {
        Issue.record("cloud request must reach the transport")
        return
    }

    harness.pipeline.applyCloudInferenceResult(
        harness.makeCloudResponse(
            for: request,
            decision: .generate,
            confidence: 0.8,
            generatedText: "我是一个",
            generatedPinyin: "wnshiysgr"
        ),
        request: request,
        token: harness.composition.token,
        deadlineAt: harness.clock + 4.0,
        localRequestWasScheduled: false
    )

    #expect(harness.pipeline.cloudSuggestionApplied == true)
    #expect(harness.pipeline.historySource == .cloudGenerated)
    guard case let .candidate(text, decision, _) =
        harness.pipeline.presentation
    else {
        Issue.record("generated sentence must own the slot")
        return
    }
    #expect(text == "我是一个")
    #expect(decision == .sentenceSuggestion)
    #expect(harness.diagnostics.contains(.cloudGenerateReceived))
    #expect(harness.diagnostics.contains(.cloudGeneratedShown))
}

@Test @MainActor
func cloudGeneratedTextMatchingTopCandidateAnnouncesAgreement() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好"])
    guard let request = harness.runCloudSendCycle() else {
        Issue.record("cloud request must reach the transport")
        return
    }

    harness.pipeline.applyCloudInferenceResult(
        harness.makeCloudResponse(
            for: request,
            decision: .generate,
            confidence: 0.8,
            generatedText: "你好",
            generatedPinyin: "nihao"
        ),
        request: request,
        token: harness.composition.token,
        deadlineAt: harness.clock + 4.0,
        localRequestWasScheduled: false
    )

    #expect(harness.pipeline.presentation == .cloudSameTopCandidate)
    #expect(harness.pipeline.cloudSuggestionApplied == false)
}

// MARK: - Cloud-over-local arbitration (decision 2026-08-16)

@Test @MainActor
func validCloudDecisionOverridesAnAlreadyShownLocalCandidate() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好", "拟好"])
    let token = harness.composition.token
    guard let localRequest = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }
    harness.pipeline.applyInferenceResult(
        okRankedResult(localRequest, candidate: "你好"),
        requestID: localRequest.requestID,
        token: token
    )
    guard case let .candidate(localText, _, _) =
        harness.pipeline.presentation
    else {
        Issue.record("local candidate must be shown first")
        return
    }
    #expect(localText == "你好")

    // Cloud answers for the same cycle with a different sentence.
    harness.flags.cloudConfigured = true
    harness.pipeline.scheduleInference(
        token: token,
        bundleIdentifier: "com.apple.notes",
        contextProvider: { _ in "" }
    )
    // Fire the local debounce, then the cloud debounce plus queue hops.
    _ = harness.scheduling.fireNextScheduled()
    _ = harness.scheduling.fireNextScheduled()
    #expect(harness.scheduling.runNextOffMain())
    harness.scheduling.runNextOnMain()
    guard let cloudRequest = harness.cloudRequests.last else {
        Issue.record("cloud request must reach the transport")
        return
    }

    harness.pipeline.applyCloudInferenceResult(
        harness.makeCloudResponse(
            for: cloudRequest,
            decision: .generate,
            confidence: 0.9,
            generatedText: "拟好",
            generatedPinyin: "nihao"
        ),
        request: cloudRequest,
        token: token,
        deadlineAt: harness.clock + 4.0,
        localRequestWasScheduled: true
    )

    guard case let .candidate(cloudText, _, _) =
        harness.pipeline.presentation
    else {
        Issue.record("cloud decision must own the slot")
        return
    }
    #expect(cloudText == "拟好")
    #expect(harness.pipeline.cloudSuggestionApplied == true)
    #expect(harness.pipeline.historySource == .cloudGenerated)
}

@Test @MainActor
func lateLocalResultNeverOverwritesAnAppliedCloudDecision() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好", "拟好"])
    let token = harness.composition.token
    harness.flags.cloudConfigured = true
    harness.pipeline.scheduleInference(
        token: token,
        bundleIdentifier: "com.apple.notes",
        contextProvider: { _ in "" }
    )
    // Local debounce first: the daemon request becomes pending…
    _ = harness.scheduling.fireNextScheduled()
    guard let localRequest = harness.localRequests.last else {
        Issue.record("local request must be sent")
        return
    }
    // …then the cloud round trip completes and owns the slot.
    _ = harness.scheduling.fireNextScheduled()
    #expect(harness.scheduling.runNextOffMain())
    harness.scheduling.runNextOnMain()
    guard let cloudRequest = harness.cloudRequests.last else {
        Issue.record("cloud request must reach the transport")
        return
    }
    harness.pipeline.applyCloudInferenceResult(
        harness.makeCloudResponse(
            for: cloudRequest,
            decision: .generate,
            confidence: 0.9,
            generatedText: "拟好",
            generatedPinyin: "nihao"
        ),
        request: cloudRequest,
        token: token,
        deadlineAt: harness.clock + 4.0,
        localRequestWasScheduled: true
    )
    #expect(harness.pipeline.cloudSuggestionApplied == true)
    guard case let .candidate(cloudText, _, _) =
        harness.pipeline.presentation
    else {
        Issue.record("cloud decision must be applied first")
        return
    }
    #expect(cloudText == "拟好")

    // The local result for this very cycle now lands late: the pending
    // request id still matches, so the cloud-ownership guard (not the
    // stale guard) must silently drop it.
    let diagnosticsBefore = harness.diagnostics
    harness.pipeline.applyInferenceResult(
        okRankedResult(localRequest, candidate: "你好"),
        requestID: localRequest.requestID,
        token: token
    )

    #expect(harness.diagnostics == diagnosticsBefore)
    #expect(harness.latencies == [0])
    #expect(harness.pipeline.cloudSuggestionApplied == true)
    guard case let .candidate(finalText, _, _) =
        harness.pipeline.presentation
    else {
        Issue.record("cloud candidate must survive the late local result")
        return
    }
    #expect(finalText == "拟好")
}

@Test @MainActor
func cloudFailureNeverOverwritesALocalSuccess() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好", "拟好"])
    let token = harness.composition.token
    harness.flags.cloudConfigured = true
    harness.pipeline.scheduleInference(
        token: token,
        bundleIdentifier: "com.apple.notes",
        contextProvider: { _ in "" }
    )
    // One keystroke cycle, both channels: the fast local result lands
    // first, then the slow cloud round trip fails.
    _ = harness.scheduling.fireNextScheduled()
    guard let localRequest = harness.localRequests.last else {
        Issue.record("local request must be sent")
        return
    }
    harness.pipeline.applyInferenceResult(
        okRankedResult(localRequest, candidate: "你好"),
        requestID: localRequest.requestID,
        token: token
    )
    #expect(harness.pipeline.presentation.isSelectable)

    _ = harness.scheduling.fireNextScheduled()
    #expect(harness.scheduling.runNextOffMain())
    harness.scheduling.runNextOnMain()
    guard let cloudRequest = harness.cloudRequests.last else {
        Issue.record("cloud request must reach the transport")
        return
    }

    harness.pipeline.applyCloudInferenceResult(
        nil,
        request: cloudRequest,
        token: token,
        deadlineAt: harness.clock + 4.0,
        localRequestWasScheduled: true
    )

    guard case let .candidate(text, _, _) = harness.pipeline.presentation
    else {
        Issue.record("local candidate must survive the cloud failure")
        return
    }
    #expect(text == "你好")
    #expect(harness.pipeline.cloudSuggestionApplied == false)
    #expect(harness.diagnostics.contains(.cloudTransportFailure))
}

// MARK: - Cloud send-path guards

@Test @MainActor
func secureInputDuringBackgroundAssemblyStopsTheCloudSend() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好"])
    harness.flags.localAllowed = false
    harness.flags.cloudConfigured = true

    harness.pipeline.scheduleInference(
        token: harness.composition.token,
        bundleIdentifier: "com.apple.notes",
        contextProvider: { _ in "" }
    )
    harness.scheduling.fireAllButLastScheduled()
    _ = harness.scheduling.fireNextScheduled()
    // Secure input flips while the request is assembled on the
    // background queue.
    harness.flags.onHistorySnapshot = { [flags = harness.flags] in
        flags.secureInput = true
    }
    #expect(harness.scheduling.runNextOffMain())
    harness.scheduling.runNextOnMain()

    #expect(harness.cloudRequests.isEmpty)
    // Secure input superseded the composition mid-assembly: the send is
    // withdrawn as stale, not mislabeled as a cloud timeout.
    #expect(harness.diagnostics.contains(.staleResult))
    #expect(!harness.diagnostics.contains(.cloudTimeout))
    // Secure input owns the UI at this point, so the fallback resolution
    // is deliberately skipped (frozen guard semantics): the slot keeps its
    // pre-send presentation.
    #expect(harness.pipeline.presentation == .cloudAnalyzing)
}

@Test @MainActor
func missingCredentialFallsBackAndDisconnectsCloud() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好"])
    harness.flags.apiKey = nil

    _ = harness.runCloudSendCycle()

    #expect(harness.cloudRequests.isEmpty)
    #expect(harness.diagnostics.contains(.cloudTransportFailure))
    #expect(harness.cloudDisconnects == 1)
    #expect(harness.pipeline.presentation == .cloudFailure)
}

// MARK: - Invalidation

@Test @MainActor
func invalidateCancelsEverythingInFlight() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好"])
    harness.flags.cloudConfigured = true
    harness.pipeline.scheduleInference(
        token: harness.composition.token,
        bundleIdentifier: "com.apple.notes",
        contextProvider: { _ in "" }
    )
    // Local request is sent; cloud request dispatched but its main-queue
    // validation hop is still pending when invalidation lands.
    _ = harness.scheduling.fireNextScheduled()
    _ = harness.scheduling.fireNextScheduled()
    #expect(harness.scheduling.runNextOffMain())

    harness.pipeline.invalidate()

    #expect(harness.cancelledLocalRequestIDs.count == 1)
    #expect(harness.cancelledCloudRequestIDs.count == 1)
    #expect(harness.diagnostics.contains(.requestCancelled))
    #expect(harness.pipeline.hasPendingCloudRequest == false)
}

@Test @MainActor
func invalidateWithClearPresentationResetsTheWholeSlot() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好"])
    _ = harness.runLocalSendCycle()

    harness.pipeline.invalidate(clearPresentation: true)

    #expect(harness.pipeline.presentation == .idle)
    #expect(harness.pipeline.contextCharacterCount == 0)
    #expect(harness.pipeline.historySource == .localSemantic)
    #expect(harness.pipeline.cloudCandidate == nil)
    #expect(harness.pipeline.cloudSuggestionApplied == false)
    #expect(harness.pipeline.mixedCompositionSuggestion == nil)
}

@Test @MainActor
func supersededLocalDebounceSelfRejectsViaTokenGuard() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好"])
    harness.pipeline.scheduleInference(
        token: harness.composition.token,
        bundleIdentifier: "com.apple.notes",
        contextProvider: { _ in "" }
    )
    // The user keeps typing before the 100 ms debounce fires.
    harness.typePinyin("niha", candidates: ["你"])
    harness.pipeline.scheduleInference(
        token: harness.composition.token,
        bundleIdentifier: "com.apple.notes",
        contextProvider: { _ in "" }
    )

    // Fire both armed timers: only the latest token may send.
    let firstDelay = harness.scheduling.fireNextScheduled()
    let secondDelay = harness.scheduling.fireNextScheduled()
    #expect(firstDelay == 0.1)
    #expect(secondDelay == 0.1)
    #expect(harness.localRequests.count == 1)
}

// MARK: - Slot lifecycle helpers

@Test @MainActor
func mixedCompositionSuggestionOwnsTheSlotUntilInvalidated() {
    let harness = PipelineHarness()
    harness.typePinyin("iphone", candidates: [])
    harness.pipeline.beginInputCycle()
    let suggestion = MixedCompositionSuggestion(
        text: "iPhone",
        segments: [],
        confidence: 0.9
    )

    #expect(
        harness.pipeline.presentMixedComposition(
            suggestion,
            token: harness.composition.token
        )
    )
    #expect(harness.pipeline.presentation.isMixedCompositionCandidate)
    #expect(harness.pipeline.mixedCompositionSuggestion == suggestion)
    #expect(harness.pipeline.contextCharacterCount == 0)
    #expect(harness.diagnostics.contains(.mixedCompositionShown))

    harness.pipeline.invalidate(clearPresentation: true)
    #expect(harness.pipeline.mixedCompositionSuggestion == nil)
    #expect(harness.pipeline.presentation == .idle)
}

@Test @MainActor
func mixedSuggestionCanRideTheMainCandidateListWithoutTheSemanticSlot() {
    let harness = PipelineHarness()
    harness.typePinyin("inihao", candidates: [])
    harness.pipeline.beginInputCycle()
    let suggestion = MixedCompositionSuggestion(
        text: "i你好",
        segments: [
            MixedCompositionSegment(kind: .ascii, rawText: "i", renderedText: "i"),
            MixedCompositionSegment(kind: .pinyin, rawText: "nihao", renderedText: "你好"),
        ],
        confidence: 0.6
    )

    #expect(
        harness.pipeline.trackMixedSuggestionAsMainCandidate(
            suggestion,
            token: harness.composition.token
        )
    )
    #expect(harness.pipeline.mixedCompositionSuggestion == suggestion)
    #expect(harness.pipeline.presentation == .idle)
    #expect(!harness.pipeline.presentation.isMixedCompositionCandidate)
    #expect(harness.composition.semanticCandidate == "i你好")
    #expect(harness.composition.semanticCandidateDecision == .mixedComposition)
    #expect(harness.diagnostics.contains(.mixedCompositionShown))

    harness.pipeline.invalidate(clearPresentation: true)
    #expect(harness.pipeline.mixedCompositionSuggestion == nil)
}

@Test @MainActor
func noCandidateCycleMarksSlotUnavailable() {
    let harness = PipelineHarness()

    harness.pipeline.beginInputCycle()
    harness.pipeline.markUnavailable()

    #expect(harness.pipeline.presentation == .unavailable)
    #expect(harness.pipeline.contextCharacterCount == 0)
    #expect(harness.diagnostics.isEmpty)
}

// MARK: - Cross-punctuation segments in inference requests

@Test @MainActor
func test_scheduleInferenceSendsSegmentsWhenPrefixPresent() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好"])
    harness.composition.appendLiteral("，")
    harness.typePinyin("shijie", candidates: ["世界"])
    let expectedSegments = [
        PinyinSegment(pinyin: "nihao", separator: "，", committedText: "你好"),
        PinyinSegment(pinyin: "shijie", separator: "", committedText: nil),
    ]

    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }

    #expect(request.pinyin == "shijie")
    #expect(request.segments == expectedSegments)
    // allowSentence 以各段字母总数（nihao + shijie = 11）判定。
    #expect(request.allowSentence)

    // 单字母活跃段在旧逻辑下不够整句阈值；各段字母总数 2 达标。
    let short = PipelineHarness()
    short.typePinyin("a", candidates: ["啊"])
    short.composition.appendLiteral("，")
    short.typePinyin("b", candidates: ["吧"])
    guard let shortRequest = short.runLocalSendCycle() else {
        Issue.record("short local request must be sent")
        return
    }
    #expect(shortRequest.segments?.count == 2)
    #expect(shortRequest.allowSentence)

    // 本地整句结果按段布局校验并把 segments 写回组合状态。
    harness.pipeline.applyInferenceResult(
        SemanticInferenceResult(
            status: "ok",
            requestID: request.requestID,
            compositionID: request.compositionID,
            revision: request.revision,
            appSessionID: request.appSessionID,
            rankedCandidate: nil,
            sentenceSuggestion: "你好，世界",
            confidence: 0.9,
            decision: .sentenceSuggestion
        ),
        requestID: request.requestID,
        token: harness.composition.token
    )

    guard case let .candidate(text, decision, _) =
        harness.pipeline.presentation
    else {
        Issue.record("segmented local sentence must own the slot")
        return
    }
    #expect(text == "你好，世界")
    #expect(decision == .sentenceSuggestion)
    #expect(harness.appliedCandidates.last?.segments == expectedSegments)
    #expect(
        harness.composition.semanticCandidateSegments == expectedSegments
    )
}

@Test @MainActor
func test_cloudGeneratedSegmentsResultAppliedWithSegmentsRecorded() {
    let harness = PipelineHarness()
    harness.typePinyin("nihao", candidates: ["你好"])
    harness.composition.appendLiteral("，")
    harness.typePinyin("shijie", candidates: ["世界"])
    guard let request = harness.runCloudSendCycle(pinyin: "shijie") else {
        Issue.record("cloud request must reach the transport")
        return
    }

    let expectedSegments = [
        PinyinSegment(pinyin: "nihao", separator: "，", committedText: "你好"),
        PinyinSegment(pinyin: "shijie", separator: "", committedText: nil),
    ]
    #expect(request.segments == expectedSegments)

    harness.pipeline.applyCloudInferenceResult(
        harness.makeCloudResponse(
            for: request,
            decision: .generate,
            confidence: 0.9,
            generatedText: "你好，世界",
            generatedPinyin: "shijie",
            generatedSegments: PinyinSegmentPolicy.canonicalJSON(
                expectedSegments
            )
        ),
        request: request,
        token: harness.composition.token,
        deadlineAt: harness.clock + 4.0,
        localRequestWasScheduled: false
    )

    #expect(harness.pipeline.cloudSuggestionApplied)
    // 本地构造的 CloudCandidate 消费各段字母总数（5 + 6）。
    #expect(harness.pipeline.cloudCandidate?.consumedLength == 11)
    #expect(
        harness.composition.semanticCandidateSegments == expectedSegments
    )
    guard case let .candidate(text, decision, _) =
        harness.pipeline.presentation
    else {
        Issue.record("segmented generated sentence must own the slot")
        return
    }
    #expect(text == "你好，世界")
    #expect(decision == .sentenceSuggestion)
    #expect(harness.diagnostics.contains(.cloudGeneratedShown))
}

@Test @MainActor
func test_noSegmentsWhenPrefixEmpty() {
    let local = PipelineHarness()
    local.typePinyin("nihao", candidates: ["你好"])
    guard let request = local.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }

    #expect(request.segments == nil)
    #expect(request.allowSentence)

    let cloud = PipelineHarness()
    cloud.typePinyin("nihao", candidates: ["你好"])
    guard let cloudRequest = cloud.runCloudSendCycle() else {
        Issue.record("cloud request must reach the transport")
        return
    }

    #expect(cloudRequest.segments == nil)

    // 旧单段行为：generate 响应不带 generated_segments 也有效。
    cloud.pipeline.applyCloudInferenceResult(
        cloud.makeCloudResponse(
            for: cloudRequest,
            decision: .generate,
            confidence: 0.8,
            generatedText: "你好好好",
            generatedPinyin: "nihao"
        ),
        request: cloudRequest,
        token: cloud.composition.token,
        deadlineAt: cloud.clock + 4.0,
        localRequestWasScheduled: false
    )
    #expect(cloud.pipeline.cloudSuggestionApplied)
    #expect(cloud.composition.semanticCandidateSegments == nil)
}
