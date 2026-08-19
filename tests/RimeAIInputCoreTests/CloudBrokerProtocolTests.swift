import Foundation
import Testing
@testable import RimeAIInputCore

@Test("cloud fallback preserves pending and successful local results")
func cloudFallbackPreservesLocalPresentation() {
    let localCandidate = SemanticCandidatePresentation.candidate(
        text: "测试",
        decision: .rankedCandidate,
        confidence: 0.96
    )

    #expect(
        CloudSemanticPresentationResolver.resolveFallback(
            current: localCandidate,
            localRequestWasScheduled: true,
            cloudDecision: nil
        ) == localCandidate
    )
    #expect(
        CloudSemanticPresentationResolver.resolveFallback(
            current: localCandidate,
            localRequestWasScheduled: true,
            cloudDecision: .keep
        ) == localCandidate
    )
    #expect(
        CloudSemanticPresentationResolver.resolveFallback(
            current: localCandidate,
            localRequestWasScheduled: true,
            cloudDecision: .abstain
        ) == localCandidate
    )
    #expect(
        CloudSemanticPresentationResolver.resolveFallback(
            current: .sameTopCandidate,
            localRequestWasScheduled: true,
            cloudDecision: .abstain
        ) == .sameTopCandidate
    )
    #expect(
        CloudSemanticPresentationResolver.resolveFallback(
            current: .analyzing,
            localRequestWasScheduled: true,
            cloudDecision: nil
        ) == .analyzing
    )
    #expect(
        CloudSemanticPresentationResolver.resolveFallback(
            current: .unavailable,
            localRequestWasScheduled: true,
            cloudDecision: nil
        ) == .unavailable
    )
    #expect(
        CloudSemanticPresentationResolver.resolveFallback(
            current: .failure,
            localRequestWasScheduled: true,
            cloudDecision: .keep
        ) == .cloudSameTopCandidate
    )
    #expect(
        CloudSemanticPresentationResolver.resolveFallback(
            current: .failure,
            localRequestWasScheduled: true,
            cloudDecision: nil
        ) == .failure
    )
}

@Test("cloud-only fallback uses cloud-specific status")
func cloudOnlyFallbackUsesCloudPresentation() {
    #expect(
        CloudSemanticPresentationResolver.resolveFallback(
            current: .analyzing,
            localRequestWasScheduled: false,
            cloudDecision: nil
        ) == .cloudFailure
    )
    #expect(
        CloudSemanticPresentationResolver.resolveFallback(
            current: .analyzing,
            localRequestWasScheduled: false,
            cloudDecision: .keep
        ) == .cloudSameTopCandidate
    )
    #expect(
        CloudSemanticPresentationResolver.resolveFallback(
            current: .analyzing,
            localRequestWasScheduled: false,
            cloudDecision: .abstain
        ) == .cloudBelowConfidence
    )
}

private func cloudFixtureRequest() -> CloudInferenceRequest {
    let token = CompositionToken(
        compositionID: UUID(
            uuidString: "10000000-0000-0000-0000-000000000001"
        )!,
        revision: 9,
        appSessionID: "com.example.Editor#session"
    )
    return CloudInferenceRequest(
        requestID: "cloud-request",
        token: token,
        bundleIdentifier: "com.example.Editor",
        clientSessionID: "client-session",
        modelID: "glm-5.3",
        pinyin: "mingling",
        candidates: [
            CloudCandidate(
                id: "candidate-0",
                text: "明令",
                source: .rimeExact,
                rimeIndex: 0,
                consumedLength: 8,
                alignedPinyin: "mingling",
                editCost: 0
            ),
            CloudCandidate(
                id: "candidate-1",
                text: "命令",
                source: .rimeFuzzy,
                rimeIndex: nil,
                consumedLength: 8,
                alignedPinyin: "mingling",
                editCost: 1
            ),
        ],
        candidatePoolHash: "fixture-hash",
        recentContext: String(repeating: "前", count: 610),
        historySnippets: [],
        historyGeneration: 4
    )
}

@Test("cloud request has bounded context and a candidate-only contract")
func cloudRequestBounds() throws {
    let request = cloudFixtureRequest()

    #expect(request.isValid)
    #expect(request.recentContext.count == 600)
    let object = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request)
        ) as? [String: Any]
    )
    #expect(object["schema_version"] as? Int == 1)
    #expect(object["candidate_pool_hash"] as? String == "fixture-hash")
    #expect(object["history_generation"] as? Int == 4)
    #expect(
        object["model_id"] as? String
            == "glm-5.3"
    )
    #expect(object["deadline_ms"] as? Int == 4000)
    #expect(object["correction_text"] == nil)

    let reducedBudget = CloudInferenceRequest(
        requestID: request.requestID,
        token: CompositionToken(
            compositionID: UUID(uuidString: request.compositionID)!,
            revision: request.revision,
            appSessionID: request.appSessionID
        ),
        bundleIdentifier: request.bundleIdentifier,
        clientSessionID: request.clientSessionID,
        modelID: request.modelID,
        deadlineMilliseconds: 120,
        pinyin: request.pinyin,
        candidates: request.candidates,
        candidatePoolHash: request.candidatePoolHash,
        recentContext: request.recentContext,
        historySnippets: request.historySnippets,
        historyGeneration: request.historyGeneration
    )
    #expect(reducedBudget.isValid)
    #expect(reducedBudget.deadlineMilliseconds == 120)
}

@Test("cloud response can select only a current pool candidate")
func cloudResponseSelection() {
    let request = cloudFixtureRequest()
    let valid = CloudInferenceResponse(
        requestID: request.requestID,
        compositionID: request.compositionID,
        revision: request.revision,
        appSessionID: request.appSessionID,
        clientSessionID: request.clientSessionID,
        candidatePoolHash: request.candidatePoolHash,
        historyGeneration: request.historyGeneration,
        decision: .choose,
        candidateID: "candidate-1",
        confidence: 0.99,
        reason: .typoMatch,
        modelID: "glm-5.3",
        elapsedMilliseconds: 420
    )
    let injected = CloudInferenceResponse(
        requestID: request.requestID,
        compositionID: request.compositionID,
        revision: request.revision,
        appSessionID: request.appSessionID,
        clientSessionID: request.clientSessionID,
        candidatePoolHash: request.candidatePoolHash,
        historyGeneration: request.historyGeneration,
        decision: .choose,
        candidateID: "not-in-pool",
        confidence: 1,
        reason: .historyMatch,
        modelID: "glm-5.3",
        elapsedMilliseconds: 200
    )

    #expect(valid.isValid(for: request))
    #expect(valid.selectedCandidate(for: request)?.text == "命令")
    #expect(!injected.isValid(for: request))
    #expect(injected.selectedCandidate(for: request) == nil)

    let lowConfidenceFuzzy = CloudInferenceResponse(
        requestID: request.requestID,
        compositionID: request.compositionID,
        revision: request.revision,
        appSessionID: request.appSessionID,
        clientSessionID: request.clientSessionID,
        candidatePoolHash: request.candidatePoolHash,
        historyGeneration: request.historyGeneration,
        decision: .choose,
        candidateID: "candidate-1",
        confidence: 0.97,
        reason: .typoMatch,
        modelID: request.modelID,
        elapsedMilliseconds: 200
    )
    #expect(!lowConfidenceFuzzy.isValid(for: request))
    #expect(lowConfidenceFuzzy.selectedCandidate(for: request) == nil)
}

@Test("late or old-history cloud results are rejected")
func cloudResponseIdentityAndDeadline() {
    let request = cloudFixtureRequest()
    let late = CloudInferenceResponse(
        requestID: request.requestID,
        compositionID: request.compositionID,
        revision: request.revision,
        appSessionID: request.appSessionID,
        clientSessionID: request.clientSessionID,
        candidatePoolHash: request.candidatePoolHash,
        historyGeneration: request.historyGeneration,
        decision: .choose,
        candidateID: "candidate-1",
        confidence: 0.99,
        reason: .typoMatch,
        modelID: request.modelID,
        elapsedMilliseconds: 4001
    )
    let staleGeneration = CloudInferenceResponse(
        requestID: request.requestID,
        compositionID: request.compositionID,
        revision: request.revision,
        appSessionID: request.appSessionID,
        clientSessionID: request.clientSessionID,
        candidatePoolHash: request.candidatePoolHash,
        historyGeneration: request.historyGeneration - 1,
        decision: .choose,
        candidateID: "candidate-1",
        confidence: 0.99,
        reason: .historyMatch,
        modelID: request.modelID,
        elapsedMilliseconds: 300
    )

    #expect(!late.isValid(for: request))
    #expect(!staleGeneration.matches(request))
}
