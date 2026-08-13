import Foundation
import Testing
@testable import RimeAIInputCore

@Test
func daemonHandshakeRequiresStructuredDecisionReasons() throws {
    func response(capabilities: [String]) throws -> DaemonHelloResponse {
        let object: [String: Any] = [
            "schema_version": 1,
            "type": "hello",
            "status": "ok",
            "protocol_version": 1,
            "capabilities": capabilities,
            "model_artifact_id": "fixture",
            "offline_lock": true,
        ]
        return try JSONDecoder().decode(
            DaemonHelloResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    #expect(
        try response(
            capabilities: [
                "offline-lock",
                "decision-reasons",
                "long-input-reasons",
            ]
        ).isCompatible
    )
    #expect(
        try !response(capabilities: ["offline-lock"]).isCompatible
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

    #expect(!injected.isDisplayable(for: token, candidates: candidates))
    #expect(
        !invalidConfidence.isDisplayable(
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

    #expect(sameTop.isValid(for: token, candidates: candidates))
    #expect(sameTop.candidatePresentation == .sameTopCandidate)
    #expect(belowConfidence.isValid(for: token, candidates: candidates))
    #expect(belowConfidence.candidatePresentation == .belowConfidence)
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
    let candidate = SemanticCandidatePresentation.candidate(
        text: "命令",
        decision: .rankedCandidate,
        confidence: 0.9
    )
    #expect(candidate.title == "✦ 命令")
    #expect(candidate.isSelectable)
}

@Test
func onlyHighConfidenceSemanticCandidatesOverrideSpaceCommit() {
    let ranked = SemanticCandidatePresentation.candidate(
        text: "命令",
        decision: .rankedCandidate,
        confidence: 0.91
    )
    let uncertainRanked = SemanticCandidatePresentation.candidate(
        text: "命令",
        decision: .rankedCandidate,
        confidence: 0.89
    )
    let sentence = SemanticCandidatePresentation.candidate(
        text: "请执行这条命令",
        decision: .sentenceSuggestion,
        confidence: 0.98
    )
    let uncertainSentence = SemanticCandidatePresentation.candidate(
        text: "请执行这条命令",
        decision: .sentenceSuggestion,
        confidence: 0.96
    )

    #expect(ranked.prefersCommitOnSpace)
    #expect(!uncertainRanked.prefersCommitOnSpace)
    #expect(sentence.prefersCommitOnSpace)
    #expect(!uncertainSentence.prefersCommitOnSpace)
    #expect(!SemanticCandidatePresentation.sameTopCandidate.prefersCommitOnSpace)
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
