import Foundation
import Testing
@testable import RimeAIInputCore

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
        confidence: 0.91
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
        confidence: 0.91
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
        confidence: 0.95
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
        confidence: 0.9
    )
    let invalidConfidence = SemanticInferenceResult(
        status: "ok",
        requestID: "request",
        compositionID: token.compositionID.uuidString,
        revision: token.revision,
        appSessionID: token.appSessionID,
        rankedCandidate: "命令",
        sentenceSuggestion: "",
        confidence: 1.1
    )

    #expect(!injected.isDisplayable(for: token, candidates: candidates))
    #expect(
        !invalidConfidence.isDisplayable(
            for: token,
            candidates: candidates
        )
    )
}
