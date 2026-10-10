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

// MARK: - Generated sentences (text-generation capability)

private func generateFixtureResponse(
    for request: CloudInferenceRequest,
    text: String?,
    echoedPinyin: String?,
    confidence: Double?
) -> CloudInferenceResponse {
    CloudInferenceResponse(
        requestID: request.requestID,
        compositionID: request.compositionID,
        revision: request.revision,
        appSessionID: request.appSessionID,
        clientSessionID: request.clientSessionID,
        candidatePoolHash: request.candidatePoolHash,
        historyGeneration: request.historyGeneration,
        decision: .generate,
        candidateID: nil,
        confidence: confidence,
        reason: .contextMatch,
        modelID: request.modelID,
        elapsedMilliseconds: 1_200,
        generatedText: text,
        generatedPinyin: echoedPinyin
    )
}

@Test("old broker responses decode without generated fields")
func oldBrokerResponseDecodesGeneratedFieldsAsNil() throws {
    let request = cloudFixtureRequest()
    let payload: [String: Any] = [
        "schema_version": 1,
        "type": "result",
        "status": "ok",
        "request_id": request.requestID,
        "composition_id": request.compositionID,
        "revision": request.revision,
        "app_session_id": request.appSessionID,
        "client_session_id": request.clientSessionID,
        "candidate_pool_hash": request.candidatePoolHash,
        "history_generation": request.historyGeneration,
        "decision": "keep",
        "candidate_id": NSNull(),
        "confidence": NSNull(),
        "reason": "rime_rank",
        "model_id": request.modelID,
        "elapsed_ms": 120,
    ]
    let response = try JSONDecoder().decode(
        CloudInferenceResponse.self,
        from: JSONSerialization.data(withJSONObject: payload)
    )
    #expect(response.decision == .keep)
    #expect(response.generatedText == nil)
    #expect(response.generatedPinyin == nil)
    #expect(response.isValid(for: request))
}

@Test("aligned generated sentence passes client validation")
func alignedGeneratedSentenceIsValid() {
    let request = cloudFixtureRequest()
    let response = generateFixtureResponse(
        for: request,
        text: "命令",
        echoedPinyin: request.pinyin,
        confidence: 0.9
    )

    #expect(response.isValid(for: request))
    #expect(response.selectedCandidate(for: request) == nil)
}

@Test("generated sentence rejects every structural violation")
func generatedSentenceStructuralViolations() {
    let request = cloudFixtureRequest()

    // Echoed pinyin must match the request byte for byte.
    #expect(
        !generateFixtureResponse(
            for: request,
            text: "命令",
            echoedPinyin: "minglin",
            confidence: 0.9
        ).isValid(for: request)
    )
    // Confidence floor mirrors the broker gate.
    #expect(
        !generateFixtureResponse(
            for: request,
            text: "命令",
            echoedPinyin: request.pinyin,
            confidence: 0.59
        ).isValid(for: request)
    )
    // Han-only, bounded length.
    #expect(
        !generateFixtureResponse(
            for: request,
            text: "命令,",
            echoedPinyin: request.pinyin,
            confidence: 0.9
        ).isValid(for: request)
    )
    #expect(
        !generateFixtureResponse(
            for: request,
            text: String(repeating: "命", count: 31),
            echoedPinyin: String(repeating: "m", count: 31),
            confidence: 0.9
        ).isValid(for: request)
    )
    // More characters than available letters is impossible even with
    // first-letter abbreviation.
    #expect(
        !generateFixtureResponse(
            for: request,
            text: String(repeating: "命", count: 9),
            echoedPinyin: request.pinyin,
            confidence: 0.9
        ).isValid(for: request)
    )
}

@Test("choose and keep decisions must not carry generated fields")
func generatedFieldsAreRejectedOutsideGenerate() {
    let request = cloudFixtureRequest()
    func response(
        decision: CloudInferenceDecision,
        candidateID: String?,
        confidence: Double?,
        generatedText: String?,
        generatedPinyin: String?
    ) -> CloudInferenceResponse {
        CloudInferenceResponse(
            requestID: request.requestID,
            compositionID: request.compositionID,
            revision: request.revision,
            appSessionID: request.appSessionID,
            clientSessionID: request.clientSessionID,
            candidatePoolHash: request.candidatePoolHash,
            historyGeneration: request.historyGeneration,
            decision: decision,
            candidateID: candidateID,
            confidence: confidence,
            reason: .rimeRank,
            modelID: request.modelID,
            elapsedMilliseconds: 100,
            generatedText: generatedText,
            generatedPinyin: generatedPinyin
        )
    }

    #expect(
        !response(
            decision: .keep,
            candidateID: nil,
            confidence: nil,
            generatedText: "命令",
            generatedPinyin: request.pinyin
        ).isValid(for: request)
    )
    #expect(
        !response(
            decision: .choose,
            candidateID: "candidate-1",
            confidence: 0.99,
            generatedText: "命令",
            generatedPinyin: request.pinyin
        ).isValid(for: request)
    )
}

@Test("generate fallback keeps the current local presentation")
func generateFallbackKeepsLocalPresentation() {
    let localCandidate = SemanticCandidatePresentation.candidate(
        text: "明令",
        decision: .rankedCandidate,
        confidence: 0.96
    )
    #expect(
        CloudSemanticPresentationResolver.resolveFallback(
            current: localCandidate,
            localRequestWasScheduled: false,
            cloudDecision: .generate
        ) == localCandidate
    )
    #expect(
        CloudSemanticPresentationResolver.resolveFallback(
            current: .failure,
            localRequestWasScheduled: false,
            cloudDecision: .generate
        ) == .failure
    )
}

@Test("cloud generated commit source round-trips")
func cloudGeneratedHistorySourceRoundTrips() throws {
    #expect(
        HistoryCommitSource.cloudGenerated.rawValue == "cloud_generated"
    )
    let decoded = try JSONDecoder().decode(
        [HistoryCommitSource].self,
        from: Data("[\"cloud_generated\",\"rime_main\"]".utf8)
    )
    #expect(decoded == [.cloudGenerated, .rimeMain])
}
