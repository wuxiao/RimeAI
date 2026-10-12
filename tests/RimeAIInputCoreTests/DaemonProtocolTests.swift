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

private func fixtureSegments(
    activePinyin: String = "jutouwangshanshi"
) -> [PinyinSegment] {
    [
        PinyinSegment(
            pinyin: "chuangqianmingyueguang",
            separator: "，",
            committedText: "床前明月光"
        ),
        PinyinSegment(
            pinyin: activePinyin,
            separator: "",
            committedText: nil
        ),
    ]
}

private func uniformSegments(
    count: Int,
    letters: Int = 1,
    lastSeparator: String = ""
) -> [PinyinSegment] {
    (0 ..< count).map { index in
        PinyinSegment(
            pinyin: String(repeating: "a", count: letters),
            separator: index == count - 1 ? lastSeparator : "，",
            committedText: index == count - 1 ? nil : "一"
        )
    }
}

@Test
func test_pinyinSegmentPolicyValidation() {
    let segments = fixtureSegments()

    #expect(
        PinyinSegmentPolicy.isValid(segments, activePinyin: "jutouwangshanshi")
    )
    #expect(!PinyinSegmentPolicy.isValid([], activePinyin: ""))
    #expect(
        PinyinSegmentPolicy.isValid(
            uniformSegments(count: 8),
            activePinyin: "a"
        )
    )
    #expect(
        !PinyinSegmentPolicy.isValid(
            uniformSegments(count: 9),
            activePinyin: "a"
        )
    )

    // Per-segment pinyin charset and letter bounds.
    #expect(
        !PinyinSegmentPolicy.isValid(
            [PinyinSegment(pinyin: "ming4", separator: "")],
            activePinyin: "ming4"
        )
    )
    #expect(
        !PinyinSegmentPolicy.isValid(
            [PinyinSegment(pinyin: "", separator: "")],
            activePinyin: ""
        )
    )
    #expect(
        PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(
                    pinyin: String(repeating: "a", count: 64),
                    separator: ""
                ),
            ],
            activePinyin: String(repeating: "a", count: 64)
        )
    )
    #expect(
        !PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(
                    pinyin: String(repeating: "a", count: 65),
                    separator: ""
                ),
            ],
            activePinyin: String(repeating: "a", count: 65)
        )
    )

    // Total letters across all segments.
    #expect(
        PinyinSegmentPolicy.isValid(
            uniformSegments(count: 4, letters: 64),
            activePinyin: String(repeating: "a", count: 64)
        )
    )
    #expect(
        !PinyinSegmentPolicy.isValid(
            uniformSegments(count: 8, letters: 33),
            activePinyin: String(repeating: "a", count: 33)
        )
    )

    // Separators must be punctuation, bounded, and empty only on the
    // last segment.
    #expect(
        !PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(pinyin: "ming", separator: "明"),
                PinyinSegment(pinyin: "ling", separator: ""),
            ],
            activePinyin: "ling"
        )
    )
    #expect(
        !PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(pinyin: "ming", separator: "a"),
                PinyinSegment(pinyin: "ling", separator: ""),
            ],
            activePinyin: "ling"
        )
    )
    #expect(
        !PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(
                    pinyin: "ming",
                    separator: String(repeating: "。", count: 3)
                ),
                PinyinSegment(pinyin: "ling", separator: ""),
            ],
            activePinyin: "ling"
        )
    )
    #expect(
        PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(
                    pinyin: "ming",
                    separator: String(repeating: "。", count: 2)
                ),
                PinyinSegment(pinyin: "ling", separator: ""),
            ],
            activePinyin: "ling"
        )
    )
    #expect(
        !PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(pinyin: "ming", separator: "，"),
                PinyinSegment(pinyin: "ling", separator: "。"),
            ],
            activePinyin: "ling"
        )
    )

    // The active segment must echo the request pinyin exactly.
    #expect(
        !PinyinSegmentPolicy.isValid(segments, activePinyin: "chuangqian")
    )

    // committed_text bounds.
    #expect(
        !PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(
                    pinyin: "ming",
                    separator: "，",
                    committedText: String(repeating: "字", count: 65)
                ),
                PinyinSegment(pinyin: "ling", separator: ""),
            ],
            activePinyin: "ling"
        )
    )
    #expect(
        !PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(
                    pinyin: "ming",
                    separator: "，",
                    committedText: "明\n令"
                ),
                PinyinSegment(pinyin: "ling", separator: ""),
            ],
            activePinyin: "ling"
        )
    )
    #expect(
        !PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(
                    pinyin: "ming",
                    separator: "，",
                    committedText: "明\u{0}令"
                ),
                PinyinSegment(pinyin: "ling", separator: ""),
            ],
            activePinyin: "ling"
        )
    )
    #expect(
        PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(
                    pinyin: "ming",
                    separator: "，",
                    committedText: String(repeating: "字", count: 64)
                ),
                PinyinSegment(pinyin: "ling", separator: ""),
            ],
            activePinyin: "ling"
        )
    )

    // Canonical JSON must match the Python mirror byte for byte
    // (json.dumps(..., sort_keys=True, ensure_ascii=False,
    // separators=(",", ":"))).
    #expect(
        PinyinSegmentPolicy.canonicalJSON(segments)
            == #"[{"committed_text":"床前明月光","pinyin":"chuangqianmingyueguang","separator":"，"},{"pinyin":"jutouwangshanshi","separator":""}]"#
    )
    #expect(PinyinSegmentPolicy.canonicalJSON([]) == nil)
    #expect(PinyinSegmentPolicy.canonicalJSON(uniformSegments(count: 9)) == nil)
}

@Test
func test_canonicalJSONMatchesPythonForSlashSeparator() {
    // Python: json.dumps(..., sort_keys=True, ensure_ascii=False,
    // separators=(",", ":")) leaves "/" unescaped while Swift's
    // JSONEncoder escapes it as "\/".
    let slashSegments = [
        PinyinSegment(
            pinyin: "chuangqianmingyueguang",
            separator: "/",
            committedText: "床前/明月\\光"
        ),
        PinyinSegment(pinyin: "jutouwangshanshi", separator: ""),
    ]
    #expect(
        PinyinSegmentPolicy.isValid(
            slashSegments,
            activePinyin: "jutouwangshanshi"
        )
    )
    #expect(
        PinyinSegmentPolicy.canonicalJSON(slashSegments)
            == #"[{"committed_text":"床前/明月\\光","pinyin":"chuangqianmingyueguang","separator":"/"},{"pinyin":"jutouwangshanshi","separator":""}]"#
    )
}

@Test
func test_segmentedInferenceRequestEncodesOptionalSegments() throws {
    var state = CompositionState(appSessionID: "app-1")
    let token = state.replaceInput(
        pinyin: "shijian",
        candidates: ["时间", "事件"]
    )

    let plain = SemanticInferenceRequest(
        requestID: "request-1",
        token: token,
        contextPolicy: .strict,
        context: "",
        pinyin: state.pinyin,
        candidates: state.mainCandidates,
        deadlineMilliseconds: 400,
        allowSentence: true
    )
    let plainObject = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(plain)
        ) as? [String: Any]
    )
    #expect(plainObject["segments"] == nil)

    let segmented = SemanticInferenceRequest(
        requestID: "request-2",
        token: token,
        contextPolicy: .strict,
        context: "",
        pinyin: state.pinyin,
        candidates: state.mainCandidates,
        deadlineMilliseconds: 400,
        allowSentence: true,
        segments: fixtureSegments(activePinyin: state.pinyin)
    )
    let segmentedObject = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(segmented)
        ) as? [String: Any]
    )
    let encodedSegments = try #require(
        segmentedObject["segments"] as? [[String: Any]]
    )
    #expect(encodedSegments.count == 2)
    #expect(encodedSegments[0]["pinyin"] as? String == "chuangqianmingyueguang")
    #expect(encodedSegments[0]["separator"] as? String == "，")
    #expect(encodedSegments[0]["committed_text"] as? String == "床前明月光")
    #expect(encodedSegments[1]["pinyin"] as? String == "shijian")
    #expect(encodedSegments[1]["separator"] as? String == "")
    #expect(encodedSegments[1]["committed_text"] == nil)
}

@Test
func test_semanticResultValidatesSegmentedSentenceSuggestion() {
    var state = CompositionState(appSessionID: "app-1")
    let token = state.replaceInput(
        pinyin: "jutouwangshanshi",
        candidates: ["举头望山石"]
    )
    let longSegments = [
        PinyinSegment(
            pinyin: String(repeating: "a", count: 15),
            separator: "，",
            committedText: "一二三四五六七八九十一二三四五"
        ),
        PinyinSegment(pinyin: String(repeating: "b", count: 15), separator: ""),
    ]
    let longSentence =
        "一二三四五六七八九十一二三四五，二二二二二二二二二二二二二二二"

    func segmentedResult(
        _ suggestion: String,
        confidence: Double
    ) -> SemanticInferenceResult {
        SemanticInferenceResult(
            status: "ok",
            requestID: "request-1",
            compositionID: token.compositionID.uuidString,
            revision: token.revision,
            appSessionID: token.appSessionID,
            rankedCandidate: "",
            sentenceSuggestion: suggestion,
            confidence: confidence,
            decision: .sentenceSuggestion
        )
    }

    // The single policy bounds the whole text (≤128 printable
    // characters), so a 31-character sentence validates with or
    // without the segment layout.
    #expect(longSentence.count == 31)
    #expect(
        segmentedResult(longSentence, confidence: 0.9).isValid(
            for: token,
            candidates: state.mainCandidates
        )
    )
    #expect(
        segmentedResult(longSentence, confidence: 0.9).isValid(
            for: token,
            candidates: state.mainCandidates,
            segments: longSegments
        )
    )

    // The separator layout and confidence floor must match the contract.
    #expect(
        !segmentedResult(
            "一二三四五六七八九十一二三四五。二二二二二二二二二二二二二二二",
            confidence: 0.9
        ).isValid(
            for: token,
            candidates: state.mainCandidates,
            segments: longSegments
        )
    )
    #expect(
        !segmentedResult(longSentence, confidence: 0.55).isValid(
            for: token,
            candidates: state.mainCandidates,
            segments: longSegments
        )
    )
}

@Test
func daemonCannotInjectAClientOnlyMixedComposition() {
    let token = CompositionState(appSessionID: "app").token
    let result = SemanticInferenceResult(
        status: "ok",
        requestID: "request",
        compositionID: token.compositionID.uuidString,
        revision: token.revision,
        appSessionID: token.appSessionID,
        rankedCandidate: "",
        sentenceSuggestion: "这个API",
        confidence: 0.99,
        decision: .mixedComposition
    )

    #expect(!result.isValid(for: token, candidates: ["这个"]))
    #expect(result.candidatePresentation(characterSet: .simplified) == .failure)
}
