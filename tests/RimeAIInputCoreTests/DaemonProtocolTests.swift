import Foundation
import Testing
@testable import RimeAIInputCore

private func daemonHelloResponse(
    capabilities: [String] = [
        "offline-lock",
        "decision-reasons",
        "long-input-reasons",
    ],
    offlineLock: Bool = true
) throws -> DaemonHelloResponse {
    let object: [String: Any] = [
        "schema_version": 1,
        "type": "hello",
        "status": "ok",
        "protocol_version": 1,
        "capabilities": capabilities,
        "model_artifact_id": "fixture",
        "offline_lock": offlineLock,
    ]
    return try JSONDecoder().decode(
        DaemonHelloResponse.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
}

@Test
func daemonTransportReadinessDoesNotAuthorizeApplicationFrames() {
    var state = DaemonClientConnectionState()

    let generation = state.beginConnection()
    #expect(!state.canSendApplicationFrames)
    let becameTransportReady = state.transportBecameReady(
        generation: generation
    )
    #expect(becameTransportReady)
    #expect(state.phase == .awaitingHello)
    #expect(!state.canSendApplicationFrames)
}

@Test
func daemonProtocolReadinessRequiresCompatibleOfflineHello() throws {
    var state = DaemonClientConnectionState()
    let generation = state.beginConnection()
    _ = state.transportBecameReady(generation: generation)

    let rejected = state.acceptHello(
        try daemonHelloResponse(offlineLock: false),
        generation: generation
    )
    #expect(!rejected)
    #expect(state.phase == .awaitingHello)
    #expect(!state.canSendApplicationFrames)

    let accepted = state.acceptHello(
        try daemonHelloResponse(),
        generation: generation
    )
    #expect(accepted)
    #expect(state.phase == .ready)
    #expect(state.canSendApplicationFrames)
}

@Test
func daemonRejectsApplicationFramesUntilHelloCompletes() throws {
    var state = DaemonClientConnectionState()
    let generation = state.beginConnection()
    _ = state.transportBecameReady(generation: generation)

    #expect(!state.canAcceptApplicationFrame(generation: generation))

    _ = state.acceptHello(
        try daemonHelloResponse(),
        generation: generation
    )
    #expect(state.canAcceptApplicationFrame(generation: generation))
}

@Test
func staleDaemonGenerationCannotInvalidateCurrentConnection() {
    var state = DaemonClientConnectionState()
    let staleGeneration = state.beginConnection()
    let currentGeneration = state.beginConnection()

    let staleInvalidation = state.invalidate(
        generation: staleGeneration
    )
    #expect(!staleInvalidation)
    #expect(state.generation == currentGeneration)
    #expect(state.phase == .connecting)

    let currentInvalidation = state.invalidate(
        generation: currentGeneration
    )
    #expect(currentInvalidation)
    #expect(state.phase == .disconnected)
    let duplicateInvalidation = state.invalidate(
        generation: currentGeneration
    )
    #expect(!duplicateInvalidation)
}

@Test
func daemonHelloTimeoutOnlyExpiresTheAwaitingGeneration() throws {
    var state = DaemonClientConnectionState()
    let timedOutGeneration = state.beginConnection()
    _ = state.transportBecameReady(generation: timedOutGeneration)

    let shouldExpire = state.shouldExpireHello(
        generation: timedOutGeneration
    )
    #expect(shouldExpire)
    #expect(state.phase == .awaitingHello)
    let timeoutInvalidated = state.invalidate(
        generation: timedOutGeneration
    )
    #expect(timeoutInvalidated)
    #expect(state.phase == .disconnected)

    let readyGeneration = state.beginConnection()
    _ = state.transportBecameReady(generation: readyGeneration)
    _ = state.acceptHello(
        try daemonHelloResponse(),
        generation: readyGeneration
    )
    let readyShouldExpire = state.shouldExpireHello(
        generation: readyGeneration
    )
    #expect(!readyShouldExpire)
    #expect(state.phase == .ready)
}

@Test
func daemonConnectionTimeoutOnlyExpiresTheConnectingGeneration() {
    var state = DaemonClientConnectionState()
    let staleGeneration = state.beginConnection()
    let connectingGeneration = state.beginConnection()

    #expect(
        !state.shouldExpireConnection(generation: staleGeneration)
    )
    #expect(
        state.shouldExpireConnection(generation: connectingGeneration)
    )

    _ = state.transportBecameReady(generation: connectingGeneration)
    #expect(
        !state.shouldExpireConnection(generation: connectingGeneration)
    )
    #expect(state.shouldExpireHello(generation: connectingGeneration))
}

@Test
func daemonReadyWaitOnlyConsumesCurrentProtocolReadyGeneration() throws {
    var connectionState = DaemonClientConnectionState()
    let staleGeneration = connectionState.beginConnection()
    _ = connectionState.transportBecameReady(generation: staleGeneration)
    var waitState = DaemonClientReadyWaitState()
    waitState.arm(generation: staleGeneration)

    let currentGeneration = connectionState.beginConnection()
    _ = connectionState.transportBecameReady(generation: currentGeneration)
    _ = connectionState.acceptHello(
        try daemonHelloResponse(),
        generation: currentGeneration
    )
    let staleReady = waitState.consumeReady(
        generation: staleGeneration,
        connectionState: connectionState
    )
    #expect(!staleReady)
    #expect(waitState.generation == staleGeneration)

    waitState.arm(generation: currentGeneration)
    let currentReady = waitState.consumeReady(
        generation: currentGeneration,
        connectionState: connectionState
    )
    #expect(currentReady)
    #expect(waitState.generation == nil)
}

@Test
func daemonReadyWaitFailureOnlyConsumesItsBoundGeneration() {
    var waitState = DaemonClientReadyWaitState()
    waitState.arm(generation: 9)

    let staleFailure = waitState.consumeFailure(generation: 8)
    #expect(!staleFailure)
    #expect(waitState.generation == 9)

    let currentFailure = waitState.consumeFailure(generation: 9)
    #expect(currentFailure)
    #expect(waitState.generation == nil)
    let duplicateFailure = waitState.consumeFailure(generation: 9)
    #expect(!duplicateFailure)
}

@Test
func cancellingBeforeHelloDiscardsBufferedInferenceWithoutSendingCancel() {
    var outbound = DaemonClientOutboundQueue()
    outbound.enqueueApplication(
        requestID: "request-before-hello",
        data: Data("inference".utf8)
    )

    let shouldSendCancel = outbound.cancelRequest(
        requestID: "request-before-hello",
        protocolReady: false
    )

    #expect(!shouldSendCancel)
    #expect(outbound.isEmpty)
    #expect(outbound.drain().isEmpty)
}

@Test
func expiringBeforeHelloRemovesOnlyTheStaleBufferedInference() {
    var outbound = DaemonClientOutboundQueue()
    outbound.enqueueApplication(
        requestID: "expired-before-hello",
        data: Data("expired".utf8)
    )
    outbound.enqueueApplication(
        requestID: "still-live-before-hello",
        data: Data("live".utf8)
    )

    let shouldSendCancel = outbound.cancelRequest(
        requestID: "expired-before-hello",
        protocolReady: false
    )

    #expect(!shouldSendCancel)
    #expect(
        outbound.drain() == [
            DaemonClientOutboundFrame(
                requestID: "still-live-before-hello",
                data: Data("live".utf8)
            ),
        ]
    )
}

@Test
func cancellingAfterInferenceWasSentRequiresAControlFrame() {
    var outbound = DaemonClientOutboundQueue()
    outbound.enqueueApplication(
        requestID: "request-after-hello",
        data: Data("inference".utf8)
    )
    _ = outbound.drain()

    let shouldSendCancel = outbound.cancelRequest(
        requestID: "request-after-hello",
        protocolReady: true
    )

    #expect(shouldSendCancel)
    #expect(outbound.isEmpty)
}

@Test
func daemonHandshakeRequiresStructuredDecisionReasons() throws {
    #expect(
        try daemonHelloResponse(
            capabilities: [
                "offline-lock",
                "decision-reasons",
                "long-input-reasons",
            ]
        ).isCompatible
    )
    #expect(
        try !daemonHelloResponse(
            capabilities: ["offline-lock"]
        ).isCompatible
    )
    #expect(
        try !daemonHelloResponse(
            capabilities: [
                "offline-lock",
                "decision-reasons",
                "long-input-reasons",
            ],
            offlineLock: false
        ).isCompatible
    )
}

@Test
func strictContextPolicyNeverSerializesContext() throws {
    var state = CompositionState(appSessionID: "app-1")
    let token = state.replaceInput(
        pinyin: "shijian",
        candidates: ["时间", "事件"]
    )

    let request = SemanticInferenceRequest(
        requestID: "request-1",
        token: token,
        contextPolicy: .strict,
        context: "绝不能发送",
        pinyin: state.pinyin,
        candidates: state.mainCandidates,
        deadlineMilliseconds: 400,
        allowSentence: true
    )

    #expect(request.context.isEmpty)
    let object = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request)
        ) as? [String: Any]
    )
    #expect(object["context"] as? String == "")
    #expect(object["sensitive"] as? Bool == false)
}

@Test
func standardContextPolicyKeepsOnlyOneHundredCharacters() {
    var state = CompositionState(appSessionID: "app-1")
    let token = state.replaceInput(
        pinyin: "shijian",
        candidates: ["时间", "事件"]
    )
    let context = String(repeating: "字", count: 110)

    let request = SemanticInferenceRequest(
        requestID: "request-1",
        token: token,
        contextPolicy: .standard,
        context: context,
        pinyin: state.pinyin,
        candidates: state.mainCandidates,
        deadlineMilliseconds: 400,
        allowSentence: false
    )

    #expect(request.context.count == 100)
}

@Test
func daemonResultMustMatchTheExactCompositionToken() {
    var state = CompositionState(appSessionID: "app-1")
    let token = state.replaceInput(
        pinyin: "shijian",
        candidates: ["时间", "事件"]
    )
    let matching = SemanticInferenceResult(
        status: "ok",
        requestID: "request-1",
        compositionID: token.compositionID.uuidString,
        revision: token.revision,
        appSessionID: token.appSessionID,
        rankedCandidate: "事件",
        sentenceSuggestion: "",
        confidence: 0.91,
        decision: .rankedCandidate
    )

    #expect(matching.matches(token))

    let stale = SemanticInferenceResult(
        status: "ok",
        requestID: "request-1",
        compositionID: token.compositionID.uuidString,
        revision: token.revision + 1,
        appSessionID: token.appSessionID,
        rankedCandidate: "事件",
        sentenceSuggestion: "",
        confidence: 0.91,
        decision: .rankedCandidate
    )
    #expect(!stale.matches(token))
}

@Test
func semanticDisplayCandidatePrefersSentenceRepair() {
    let result = SemanticInferenceResult(
        status: "ok",
        requestID: "request-1",
        compositionID: UUID().uuidString,
        revision: 1,
        appSessionID: "app-1",
        rankedCandidate: "事件",
        sentenceSuggestion: "这个事件需要处理。",
        confidence: 0.95,
        decision: .sentenceSuggestion
    )

    #expect(result.displayCandidate == "这个事件需要处理。")
}

@Test
func semanticResultRejectsOutOfRangeOrInjectedPayloads() {
    let token = CompositionToken(
        compositionID: UUID(),
        revision: 3,
        appSessionID: "app-a"
    )
    let candidates = ["明令", "命令"]
    let injected = SemanticInferenceResult(
        status: "ok",
        requestID: "request",
        compositionID: token.compositionID.uuidString,
        revision: token.revision,
        appSessionID: token.appSessionID,
        rankedCandidate: "恶意注入",
        sentenceSuggestion: "",
        confidence: 0.9,
        decision: .rankedCandidate
    )
    let invalidConfidence = SemanticInferenceResult(
        status: "ok",
        requestID: "request",
        compositionID: token.compositionID.uuidString,
        revision: token.revision,
        appSessionID: token.appSessionID,
        rankedCandidate: "命令",
        sentenceSuggestion: "",
        confidence: 1.1,
        decision: .rankedCandidate
    )

    #expect(!injected.isValid(for: token, candidates: candidates))
    #expect(
        !invalidConfidence.isValid(
            for: token,
            candidates: candidates
        )
    )
}

@Test
func semanticAbstentionsAreValidVisibleModelDecisions() {
    let token = CompositionToken(
        compositionID: UUID(),
        revision: 3,
        appSessionID: "app-a"
    )
    let candidates = ["明令", "命令"]
    let sameTop = SemanticInferenceResult(
        status: "ok",
        requestID: "request",
        compositionID: token.compositionID.uuidString,
        revision: token.revision,
        appSessionID: token.appSessionID,
        rankedCandidate: "",
        sentenceSuggestion: "",
        confidence: 0.88,
        decision: .sameTopCandidate
    )
    let belowConfidence = SemanticInferenceResult(
        status: "ok",
        requestID: "request",
        compositionID: token.compositionID.uuidString,
        revision: token.revision,
        appSessionID: token.appSessionID,
        rankedCandidate: "",
        sentenceSuggestion: "",
        confidence: 0.54,
        decision: .belowConfidence
    )
    let insufficientCandidates = SemanticInferenceResult(
        status: "ok",
        requestID: "request",
        compositionID: token.compositionID.uuidString,
        revision: token.revision,
        appSessionID: token.appSessionID,
        rankedCandidate: "",
        sentenceSuggestion: "",
        confidence: 0,
        decision: .insufficientCandidates
    )

    #expect(sameTop.isValid(for: token, candidates: candidates))
    #expect(
        sameTop.candidatePresentation(characterSet: .simplified)
            == .sameTopCandidate
    )
    #expect(
        sameTop.candidatePresentation(characterSet: .simplified)
            .title(mainCandidate: "飞机")
            == "✦ AI 建议：飞机（与 Rime 首选一致）"
    )
    #expect(belowConfidence.isValid(for: token, candidates: candidates))
    #expect(
        belowConfidence.candidatePresentation(characterSet: .simplified)
            == .belowConfidence
    )
    #expect(insufficientCandidates.isValid(for: token, candidates: candidates))
    #expect(
        insufficientCandidates.candidatePresentation(characterSet: .simplified)
            == .insufficientCandidates
    )
}

@Test
func sentenceSuggestionsRejectTheWrongChineseScriptBeforePresentation() {
    let result = SemanticInferenceResult(
        status: "ok",
        requestID: "request",
        compositionID: UUID().uuidString,
        revision: 1,
        appSessionID: "app-a",
        rankedCandidate: "",
        sentenceSuggestion: "飛機",
        confidence: 0.9,
        decision: .sentenceSuggestion
    )

    #expect(
        result.candidatePresentation(characterSet: .simplified)
            == .scriptMismatch
    )
    #expect(
        result.candidatePresentation(characterSet: .traditional)
            == .candidate(
                text: "飛機",
                decision: .sentenceSuggestion,
                confidence: 0.9
            )
    )
}

@Test
func semanticDecisionMustAgreeWithItsPayload() {
    let token = CompositionToken(
        compositionID: UUID(),
        revision: 1,
        appSessionID: "app-a"
    )
    let inconsistent = SemanticInferenceResult(
        status: "ok",
        requestID: "request",
        compositionID: token.compositionID.uuidString,
        revision: token.revision,
        appSessionID: token.appSessionID,
        rankedCandidate: "命令",
        sentenceSuggestion: "",
        confidence: 0.9,
        decision: .sameTopCandidate
    )

    #expect(!inconsistent.isValid(for: token, candidates: ["明令", "命令"]))

    let competingPayloads = SemanticInferenceResult(
        status: "ok",
        requestID: "request",
        compositionID: token.compositionID.uuidString,
        revision: token.revision,
        appSessionID: token.appSessionID,
        rankedCandidate: "命令",
        sentenceSuggestion: "请执行这条命令",
        confidence: 0.93,
        decision: .sentenceSuggestion
    )

    #expect(
        !competingPayloads.isValid(for: token, candidates: ["明令", "命令"])
    )
}

@Test
func semanticCandidatePresentationExplainsEveryNormalModelOutcome() {
    #expect(SemanticCandidatePresentation.analyzing.title.contains("分析中"))
    #expect(
        SemanticCandidatePresentation.sameTopCandidate.title.contains(
            "首选一致"
        )
    )
    #expect(
        SemanticCandidatePresentation.belowConfidence.title.contains(
            "置信度不足"
        )
    )
    #expect(
        SemanticCandidatePresentation.insufficientCandidates.title.contains(
            "未执行重排"
        )
    )
    #expect(
        SemanticCandidatePresentation.cloudFailure.title.contains("云端")
    )
    #expect(
        !SemanticCandidatePresentation.cloudFailure.title.contains("本地模型")
    )
    #expect(!SemanticCandidatePresentation.cloudFailure.isSelectable)
    for presentation in [
        SemanticCandidatePresentation.cloudAnalyzing,
        .cloudSameTopCandidate,
        .cloudBelowConfidence,
    ] {
        #expect(presentation.title.contains("云端"))
        #expect(!presentation.title.contains("本地模型"))
        #expect(!presentation.isSelectable)
    }
    let candidate = SemanticCandidatePresentation.candidate(
        text: "命令",
        decision: .rankedCandidate,
        confidence: 0.9
    )
    #expect(candidate.title == "✦ 命令")
    #expect(candidate.isSelectable)
    let mixed = SemanticCandidatePresentation.candidate(
        text: "这个API需要配置",
        decision: .mixedComposition,
        confidence: 0.98
    )
    #expect(mixed.title == "✦ 中英混输：这个API需要配置")
    #expect(mixed.isSelectable)
}

@Test
func longInputAbstentionsAreVisibleAndNonSelectable() {
    let tooLong = SemanticCandidatePresentation.sentenceTooLong
    let incomplete = SemanticCandidatePresentation.sentenceIncomplete
    let pinyinTooLong = SemanticCandidatePresentation.inputTooLong

    #expect(tooLong.title.contains("30"))
    #expect(incomplete.title.contains("完整拼音"))
    #expect(pinyinTooLong.title.contains("过长"))
    #expect(!tooLong.isSelectable)
    #expect(!incomplete.isSelectable)
    #expect(!pinyinTooLong.isSelectable)
}

@Test
func tabCommitsFirstMainCandidateOnlyForCloudAgreement() {
    #expect(
        SemanticCandidatePresentation.cloudSameTopCandidate
            .tabCommitsFirstMainCandidate
    )
    for presentation in [
        SemanticCandidatePresentation.idle,
        .analyzing,
        .sameTopCandidate,
        .cloudAnalyzing,
        .cloudBelowConfidence,
        .cloudFailure,
        .failure,
        .unavailable,
        .candidate(text: "你好", decision: .sentenceSuggestion, confidence: 1),
        .continuation(candidate: "世界"),
    ] {
        #expect(!presentation.tabCommitsFirstMainCandidate)
    }
}

// MARK: - Cross-punctuation segments (PinyinSegment protocol layer)

