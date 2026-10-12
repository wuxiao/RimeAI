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
    // 本地管线在跑时 abstain 不再覆盖当前展示：即使本地只剩负面
    // 诊断，「云端弃权」也没有可操作的新信息，反复刷这条表态被用
    // 户视为噪声。
    #expect(
        CloudSemanticPresentationResolver.resolveFallback(
            current: .failure,
            localRequestWasScheduled: true,
            cloudDecision: .abstain
        ) == .failure
    )
    #expect(
        CloudSemanticPresentationResolver.resolveFallback(
            current: .insufficientCandidates,
            localRequestWasScheduled: true,
            cloudDecision: .abstain
        ) == .insufficientCandidates
    )
    #expect(
        CloudSemanticPresentationResolver.resolveFallback(
            current: .belowConfidence,
            localRequestWasScheduled: true,
            cloudDecision: .abstain
        ) == .belowConfidence
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
        modelID: "glm-5.3-flash",
        pinyin: "mingling",
        recentContext: String(repeating: "前", count: 610),
        historySnippets: [],
        historyGeneration: 4
    )
}

@Test("cloud request has bounded context and carries no candidate pool")
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
    #expect(object["candidates"] == nil)
    #expect(object["candidate_pool_hash"] == nil)
    #expect(object["history_generation"] as? Int == 4)
    #expect(
        object["model_id"] as? String
            == "glm-5.3-flash"
    )
    #expect(object["deadline_ms"] as? Int == 30_000)
    #expect(object["correction_text"] == nil)
    #expect(object["segments"] == nil)

    let segmentedObject = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                segmentedCloudFixtureRequest(
                    segments: segmentedFixtureSegments()
                )
            )
        ) as? [String: Any]
    )
    #expect((segmentedObject["segments"] as? [[String: Any]])?.count == 2)

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
        recentContext: request.recentContext,
        historySnippets: request.historySnippets,
        historyGeneration: request.historyGeneration
    )
    #expect(reducedBudget.isValid)
    #expect(reducedBudget.deadlineMilliseconds == 120)
}

@Test("abstain results validate only without payload fields")
func cloudAbstainResponseValidation() {
    let request = cloudFixtureRequest()
    func response(
        confidence: Double?,
        generatedText: String?
    ) -> CloudInferenceResponse {
        CloudInferenceResponse(
            requestID: request.requestID,
            compositionID: request.compositionID,
            revision: request.revision,
            appSessionID: request.appSessionID,
            clientSessionID: request.clientSessionID,
            historyGeneration: request.historyGeneration,
            decision: .abstain,
            confidence: confidence,
            reason: .rimeRank,
            modelID: request.modelID,
            elapsedMilliseconds: 100,
            generatedText: generatedText,
            generatedPinyin: generatedText == nil ? nil : request.pinyin
        )
    }

    #expect(response(confidence: nil, generatedText: nil).isValid(for: request))
    #expect(
        !response(confidence: 0.99, generatedText: nil)
            .isValid(for: request)
    )
    #expect(
        !response(confidence: nil, generatedText: "命令")
            .isValid(for: request)
    )
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
        historyGeneration: request.historyGeneration,
        decision: .abstain,
        confidence: nil,
        reason: .typoMatch,
        modelID: request.modelID,
        elapsedMilliseconds: Double(request.deadlineMilliseconds) + 1
    )
    let staleGeneration = CloudInferenceResponse(
        requestID: request.requestID,
        compositionID: request.compositionID,
        revision: request.revision,
        appSessionID: request.appSessionID,
        clientSessionID: request.clientSessionID,
        historyGeneration: request.historyGeneration - 1,
        decision: .abstain,
        confidence: nil,
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
        historyGeneration: request.historyGeneration,
        decision: .generate,
        confidence: confidence,
        reason: .contextMatch,
        modelID: request.modelID,
        elapsedMilliseconds: 1_200,
        generatedText: text,
        generatedPinyin: echoedPinyin
    )
}

@Test("result frames without candidate_pool_hash decode and validate")
func oldBrokerResponseDecodesWithoutPoolHash() throws {
    let request = cloudFixtureRequest()
    // The broker echoes candidate_pool_hash only when the request carried
    // one; the new client never does, so the key is absent. The broker
    // still sends a null candidate_id for transitional clients — the
    // decoder must ignore it.
    let payload: [String: Any] = [
        "schema_version": 1,
        "type": "result",
        "status": "ok",
        "request_id": request.requestID,
        "composition_id": request.compositionID,
        "revision": request.revision,
        "app_session_id": request.appSessionID,
        "client_session_id": request.clientSessionID,
        "history_generation": request.historyGeneration,
        "decision": "abstain",
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
    #expect(response.decision == .abstain)
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
    #expect(response.decision == .generate)
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
    // Bounded length; empty text is not a sentence.
    #expect(
        !generateFixtureResponse(
            for: request,
            text: "",
            echoedPinyin: request.pinyin,
            confidence: 0.9
        ).isValid(for: request)
    )
    #expect(
        !generateFixtureResponse(
            for: request,
            text: String(repeating: "命", count: 129),
            echoedPinyin: String(repeating: "m", count: 129),
            confidence: 0.9
        ).isValid(for: request)
    )
    // Mixed-script text is the contract: punctuation and latin inside a
    // single-segment sentence are accepted (only the segmented protocol
    // pins separators to the requested layout).
    #expect(
        generateFixtureResponse(
            for: request,
            text: "命令,",
            echoedPinyin: request.pinyin,
            confidence: 0.9
        ).isValid(for: request)
    )
    #expect(
        generateFixtureResponse(
            for: request,
            text: "命令abc",
            echoedPinyin: request.pinyin,
            confidence: 0.9
        ).isValid(for: request)
    )
    // Control scalars must never reach presentation.
    #expect(
        !generateFixtureResponse(
            for: request,
            text: "命\u{07}令",
            echoedPinyin: request.pinyin,
            confidence: 0.9
        ).isValid(for: request)
    )
    // More characters than typed letters is still accepted: pinyin
    // alignment is deliberately not checked (product decision).
    #expect(
        generateFixtureResponse(
            for: request,
            text: String(repeating: "命", count: 9),
            echoedPinyin: request.pinyin,
            confidence: 0.9
        ).isValid(for: request)
    )
}

@Test("abstain decisions must not carry generated fields")
func generatedFieldsAreRejectedOutsideGenerate() {
    let request = cloudFixtureRequest()
    func response(
        decision: CloudInferenceDecision,
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
            historyGeneration: request.historyGeneration,
            decision: decision,
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
            decision: .abstain,
            confidence: nil,
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

// MARK: - Cross-punctuation segmented requests

private func segmentedFixtureSegments() -> [PinyinSegment] {
    [
        PinyinSegment(
            pinyin: "chuangqianmingyueguang",
            separator: "，",
            committedText: "床前明月光"
        ),
        PinyinSegment(pinyin: "jutouwangshanshi", separator: ""),
    ]
}

private func segmentedCloudFixtureRequest(
    segments: [PinyinSegment]?,
    pinyin: String = "jutouwangshanshi"
) -> CloudInferenceRequest {
    let token = CompositionToken(
        compositionID: UUID(
            uuidString: "10000000-0000-0000-0000-000000000002"
        )!,
        revision: 11,
        appSessionID: "com.example.Editor#session"
    )
    return CloudInferenceRequest(
        requestID: "cloud-request-segmented",
        token: token,
        bundleIdentifier: "com.example.Editor",
        clientSessionID: "client-session",
        modelID: "glm-5.3-flash",
        pinyin: pinyin,
        recentContext: "",
        historySnippets: [],
        historyGeneration: 4,
        segments: segments
    )
}

@Test("segmented generate response must echo the canonical segments JSON")
func test_generateResponseRequiresSegmentEchoMatch() {
    let canonicalSegments = segmentedFixtureSegments()
    let canonical = PinyinSegmentPolicy.canonicalJSON(canonicalSegments)
    #expect(
        canonical
            == #"[{"committed_text":"床前明月光","pinyin":"chuangqianmingyueguang","separator":"，"},{"pinyin":"jutouwangshanshi","separator":""}]"#
    )

    let request = segmentedCloudFixtureRequest(segments: canonicalSegments)
    #expect(request.isValid)
    // The active segment must echo the request pinyin byte for byte.
    #expect(
        !segmentedCloudFixtureRequest(
            segments: [
                PinyinSegment(pinyin: "chuangqian", separator: "，", committedText: "床前"),
                PinyinSegment(pinyin: "cuowu", separator: ""),
            ]
        ).isValid
    )

    func segmentedResponse(
        generatedSegments: String?
    ) -> CloudInferenceResponse {
        CloudInferenceResponse(
            requestID: request.requestID,
            compositionID: request.compositionID,
            revision: request.revision,
            appSessionID: request.appSessionID,
            clientSessionID: request.clientSessionID,
            historyGeneration: request.historyGeneration,
            decision: .generate,
            confidence: 0.9,
            reason: .contextMatch,
            modelID: request.modelID,
            elapsedMilliseconds: 1_200,
            generatedText: "床前明月光，举头望山石",
            generatedPinyin: request.pinyin,
            generatedSegments: generatedSegments
        )
    }

    #expect(segmentedResponse(generatedSegments: canonical).isValid(for: request))
    #expect(!segmentedResponse(generatedSegments: nil).isValid(for: request))
    #expect(
        !segmentedResponse(
            generatedSegments: #"[{"committed_text":"床前","pinyin":"chuangqianmingyueguang","separator":"，"},{"pinyin":"jutouwangshanshi","separator":""}]"#
        ).isValid(for: request)
    )

    // Unsegmented requests must not accept any segment echo.
    let unsegmented = cloudFixtureRequest()
    #expect(
        !CloudInferenceResponse(
            requestID: unsegmented.requestID,
            compositionID: unsegmented.compositionID,
            revision: unsegmented.revision,
            appSessionID: unsegmented.appSessionID,
            clientSessionID: unsegmented.clientSessionID,
            historyGeneration: unsegmented.historyGeneration,
            decision: .generate,
            confidence: 0.9,
            reason: .contextMatch,
            modelID: unsegmented.modelID,
            elapsedMilliseconds: 100,
            generatedText: "命令",
            generatedPinyin: unsegmented.pinyin,
            generatedSegments: canonical
        ).isValid(for: unsegmented)
    )
}

@Test("cross-punctuation sentence layout passes the segmented policy")
func test_generatedSentencePolicyAllowsCrossPunctuationLayout() {
    let policy = CloudGeneratedSentencePolicy.self
    let segments = segmentedFixtureSegments()

    #expect(
        policy.allows(
            text: "床前明月光，举头望山石",
            pinyinSegments: segments,
            confidence: 0.9
        )
    )
    #expect(
        policy.allows(
            text: "床前明月光，举头望山石",
            pinyinSegments: segments,
            confidence: CloudGeneratedSentencePolicy.minimumConfidence
        )
    )

    // Full-width ASCII and multi-character separators are legal.
    let threeSegments = [
        PinyinSegment(pinyin: "yi", separator: "？", committedText: "一"),
        PinyinSegment(pinyin: "er", separator: "。", committedText: "二"),
        PinyinSegment(pinyin: "san", separator: ""),
    ]
    #expect(
        policy.allows(
            text: "一？二。三",
            pinyinSegments: threeSegments,
            confidence: 0.7
        )
    )

    // Separators count against the structural budget like every other
    // character, but 31 total characters is well within the 128 cap.
    #expect(
        policy.allows(
            text: String(repeating: "一", count: 29) + "，" + "二",
            pinyinSegments: [
                PinyinSegment(
                    pinyin: String(repeating: "a", count: 29),
                    separator: "，",
                    committedText: "一"
                ),
                PinyinSegment(pinyin: "er", separator: ""),
            ],
            confidence: 0.9
        )
    )
}

@Test("segmented policy rejects separator layout mismatches")
func test_generatedSentencePolicyRejectsMismatchedSeparators() {
    let policy = CloudGeneratedSentencePolicy.self
    let segments = segmentedFixtureSegments()

    // Wrong separator.
    #expect(
        !policy.allows(
            text: "床前明月光。举头望山石",
            pinyinSegments: segments,
            confidence: 0.9
        )
    )
    // Missing separator.
    #expect(
        !policy.allows(
            text: "床前明月光举头望山石",
            pinyinSegments: segments,
            confidence: 0.9
        )
    )
    // Stray separator copies land inside a part and are tolerated:
    // with no Han-only part check, the layout only requires each
    // separator to appear in order with non-empty parts.
    #expect(
        policy.allows(
            text: "床前明月光，举头望山石，",
            pinyinSegments: segments,
            confidence: 0.9
        )
    )
    #expect(
        policy.allows(
            text: "床前明月光，，举头望山石",
            pinyinSegments: segments,
            confidence: 0.9
        )
    )
    // Separators out of order.
    let mixed = [
        PinyinSegment(pinyin: "yi", separator: "。", committedText: "一"),
        PinyinSegment(pinyin: "er", separator: "，", committedText: "二"),
        PinyinSegment(pinyin: "san", separator: ""),
    ]
    #expect(
        !policy.allows(
            text: "一，二。三",
            pinyinSegments: mixed,
            confidence: 0.9
        )
    )
}

@Test("segmented policy accepts mixed parts but rejects empty ones")
func test_generatedSentencePolicyAllowsMixedPartsRejectsEmpty() {
    let policy = CloudGeneratedSentencePolicy.self
    let segments = segmentedFixtureSegments()

    // Mixed-script parts are allowed; only the separator layout and
    // non-empty parts are structural requirements.
    #expect(
        policy.allows(
            text: "床前明月光，jutou",
            pinyinSegments: segments,
            confidence: 0.9
        )
    )
    #expect(
        policy.allows(
            text: "bed前明月光，举头望山石",
            pinyinSegments: segments,
            confidence: 0.9
        )
    )
    // An empty leading part means the model dropped the segment text.
    #expect(
        !policy.allows(
            text: "，举头望山石",
            pinyinSegments: segments,
            confidence: 0.9
        )
    )
    #expect(
        !policy.allows(
            text: "",
            pinyinSegments: segments,
            confidence: 0.9
        )
    )
}

@Test("segmented policy keeps the total bound and drops per-part letter fit")
func test_generatedSentencePolicyRejectsOverLength() {
    let policy = CloudGeneratedSentencePolicy.self
    let shortSegments = [
        PinyinSegment(pinyin: "ming", separator: "，", committedText: "明"),
        PinyinSegment(pinyin: "er", separator: ""),
    ]

    // More characters than letters in the matching segment: pinyin
    // alignment is no longer checked, so this passes now.
    #expect(
        policy.allows(
            text: "明明白白白，二",
            pinyinSegments: shortSegments,
            confidence: 0.9
        )
    )
    #expect(
        policy.allows(
            text: "明明白白，二",
            pinyinSegments: shortSegments,
            confidence: 0.9
        )
    )

    // Whole text beyond the 128-character structural bound.
    let longSegments = [
        PinyinSegment(
            pinyin: String(repeating: "a", count: 16),
            separator: "，",
            committedText: "一"
        ),
        PinyinSegment(pinyin: String(repeating: "b", count: 16), separator: ""),
    ]
    #expect(
        !policy.allows(
            text: String(repeating: "一", count: 70)
                + "，"
                + String(repeating: "二", count: 70),
            pinyinSegments: longSegments,
            confidence: 0.9
        )
    )

    // Structurally invalid segments never allow anything.
    #expect(
        !policy.allows(
            text: "明",
            pinyinSegments: [],
            confidence: 0.9
        )
    )
    // Confidence below the floor.
    #expect(
        !policy.allows(
            text: "明明白白，二",
            pinyinSegments: shortSegments,
            confidence: 0.59
        )
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

// MARK: - Generated sentence policy (single tier)

private func pinyinCharsetFixtureRequest(
    pinyin: String
) -> CloudInferenceRequest {
    let token = CompositionToken(
        compositionID: UUID(
            uuidString: "10000000-0000-0000-0000-000000000003"
        )!,
        revision: 3,
        appSessionID: "com.example.Editor#session"
    )
    return CloudInferenceRequest(
        requestID: "pinyin-charset-request",
        token: token,
        bundleIdentifier: "com.example.Editor",
        clientSessionID: "client-session",
        pinyin: pinyin,
        recentContext: "",
        historySnippets: [],
        historyGeneration: 1
    )
}

@Test("requests never encode pinyin_alignment")
func pinyinAlignmentFieldIsGone() throws {
    let object = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(cloudFixtureRequest())
        ) as? [String: Any]
    )
    #expect(object["pinyin_alignment"] == nil)
}

@Test("pinyin accepts letters of both cases plus apostrophes only")
func pinyinCharsetIsLettersAndApostrophes() {
    #expect(pinyinCharsetFixtureRequest(pinyin: "MingLing").isValid)
    #expect(pinyinCharsetFixtureRequest(pinyin: "ming'ling").isValid)
    // Anything beyond [A-Za-z'] stays rejected.
    #expect(!pinyinCharsetFixtureRequest(pinyin: "ming ling").isValid)
    #expect(!pinyinCharsetFixtureRequest(pinyin: "ming，ling").isValid)
}

@Test("generated sentence policy bounds mixed text structurally")
func generatedSentencePolicyBounds() {
    let policy = CloudGeneratedSentencePolicy.self

    // Mixed Chinese/English text is the contract, not an exception.
    #expect(policy.allows(text: "用Python写测试", confidence: 0.9))
    #expect(
        policy.allows(
            text: "用Python写测试",
            confidence: CloudGeneratedSentencePolicy.minimumConfidence
        )
    )
    #expect(policy.allows(text: "plainLatinSentence", confidence: 0.9))
    // Spaces (0x20) are control-adjacent and stay rejected.
    #expect(!policy.allows(text: "plain latin sentence", confidence: 0.9))
    // Empty text and sub-floor confidence stay rejected.
    #expect(!policy.allows(text: "", confidence: 0.9))
    #expect(!policy.allows(text: "用Python写测试", confidence: 0.59))
    // 128 characters fit, 129 do not.
    #expect(
        policy.allows(
            text: String(repeating: "字", count: 128),
            confidence: 0.9
        )
    )
    #expect(
        !policy.allows(
            text: String(repeating: "字", count: 129),
            confidence: 0.9
        )
    )
    // Control characters (<0x20 or 0x7F) never reach presentation.
    #expect(!policy.allows(text: "用Python\n写测试", confidence: 0.9))
    #expect(!policy.allows(text: "用\u{07}写", confidence: 0.9))
    #expect(!policy.allows(text: "用\u{7F}写", confidence: 0.9))
}

@Test("segmented policy keeps separator layout, allows mixed parts")
func segmentedPolicyKeepsSeparatorLayout() {
    let policy = CloudGeneratedSentencePolicy.self
    let segments = [
        PinyinSegment(pinyin: "yong", separator: "，", committedText: "用"),
        PinyinSegment(pinyin: "python", separator: ""),
    ]

    // Mixed-script parts are fine as long as the layout reproduces
    // the separators in order with non-empty parts.
    #expect(
        policy.allows(
            text: "用，Python写测试",
            pinyinSegments: segments,
            confidence: 0.9
        )
    )
    // Wrong or missing separators are rejected.
    #expect(
        !policy.allows(
            text: "用。Python写测试",
            pinyinSegments: segments,
            confidence: 0.9
        )
    )
    #expect(
        !policy.allows(
            text: "用Python写测试",
            pinyinSegments: segments,
            confidence: 0.9
        )
    )
    // Empty part means the model dropped a segment's text.
    #expect(
        !policy.allows(
            text: "，Python写测试",
            pinyinSegments: segments,
            confidence: 0.9
        )
    )
    // Structural bound still applies to the whole mixed-text layout.
    #expect(
        !policy.allows(
            text: String(repeating: "字", count: 128) + "，Python",
            pinyinSegments: segments,
            confidence: 0.9
        )
    )
}

@Test("mixed-script generate response validates")
func mixedScriptGenerateResponseValidation() {
    let request = pinyinCharsetFixtureRequest(pinyin: "MingLing")
    #expect(request.isValid)

    func response(
        text: String?,
        echoedPinyin: String?
    ) -> CloudInferenceResponse {
        CloudInferenceResponse(
            requestID: request.requestID,
            compositionID: request.compositionID,
            revision: request.revision,
            appSessionID: request.appSessionID,
            clientSessionID: request.clientSessionID,
            historyGeneration: request.historyGeneration,
            decision: .generate,
            confidence: 0.9,
            reason: .contextMatch,
            modelID: request.modelID,
            elapsedMilliseconds: 1_200,
            generatedText: text,
            generatedPinyin: echoedPinyin
        )
    }

    #expect(
        response(
            text: "用Python写测试",
            echoedPinyin: request.pinyin
        ).isValid(for: request)
    )
    // Control characters are rejected outright.
    #expect(
        !response(
            text: "用\nPython写测试",
            echoedPinyin: request.pinyin
        ).isValid(for: request)
    )
    // The echoed pinyin must still match the request byte for byte.
    #expect(
        !response(
            text: "用Python写测试",
            echoedPinyin: request.pinyin.lowercased()
        ).isValid(for: request)
    )
}

// MARK: - Post-commit continuation protocol (Task 1)

@Test("continuation request encodes snake_case keys and clamps deadline")
func continuationRequestEncodingRoundTrip() throws {
    let snippet = CloudHistorySnippet(
        id: "s1",
        text: "片段",
        bundleIdentifier: "com.example",
        committedAtMilliseconds: 1_760_000_000_000,
        score: 0.9
    )
    let request = CloudContinuationRequest(
        requestID: "req-1",
        clientSessionID: "sess-1",
        bundleIdentifier: "com.example",
        modelID: "glm-5.3-flash",
        recentContext: "床前明月光，",
        historySnippets: [snippet],
        historyGeneration: 42,
        deadlineMilliseconds: 99_999
    )
    let data = try JSONEncoder().encode(request)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["schema_version"] as? Int == 1)
    #expect(json["type"] as? String == "continuation")
    #expect(json["request_id"] as? String == "req-1")
    #expect(json["client_session_id"] as? String == "sess-1")
    #expect(json["bundle_id"] as? String == "com.example")
    #expect(json["model_id"] as? String == "glm-5.3-flash")
    #expect(json["recent_context"] as? String == "床前明月光，")
    #expect(json["history_generation"] as? Int64 == 42)
    #expect(json["deadline_ms"] as? Int == 30_000)
    #expect((json["history_snippets"] as? [[String: Any]])?.count == 1)
    #expect(json["pinyin"] == nil)
    #expect(json["candidates"] == nil)
    let decoded = try JSONDecoder().decode(CloudContinuationRequest.self, from: data)
    #expect(decoded.requestID == "req-1")
    #expect(decoded.deadlineMilliseconds == 30_000)
}

@Test("continuation request validation bounds")
func continuationRequestValidation() {
    func makeRequest(context: String, deadline: Int = 1_500) -> CloudContinuationRequest {
        CloudContinuationRequest(
            requestID: "r",
            clientSessionID: "s",
            bundleIdentifier: "com.example",
            modelID: "glm-5.3-flash",
            recentContext: context,
            historySnippets: [],
            historyGeneration: nil,
            deadlineMilliseconds: deadline
        )
    }
    // 少于 4 个汉字 → 拒
    #expect(!ContinuationTextPolicy.isValid(request: makeRequest(context: "床前明")))
    // 字符总数 > 400 → 拒
    #expect(!ContinuationTextPolicy.isValid(request: makeRequest(context: String(repeating: "床", count: 401))))
    // 合法例通过
    #expect(ContinuationTextPolicy.isValid(request: makeRequest(context: "床前明月光，疑是地上霜")))
    // deadline 夹取：0 → 1，99999 → 30000（夹取后均合法）
    #expect(makeRequest(context: "床前明月光", deadline: 0).deadlineMilliseconds == 1)
    #expect(makeRequest(context: "床前明月光", deadline: 99_999).deadlineMilliseconds == 30_000)
}

@Test("continuation text policy allows/rejects matrix")
func continuationTextPolicyAllows() {
    let context = "床前明月光"
    // 正例：疑是地上霜
    #expect(ContinuationTextPolicy.allows(text: "疑是地上霜", context: context, confidence: 0.9))
    // 含标点拒
    #expect(!ContinuationTextPolicy.allows(text: "疑是地上霜。", context: context, confidence: 0.9))
    // 超长拒（17 字）
    #expect(!ContinuationTextPolicy.allows(text: "一二三四五六七八九十一二三四五六七", context: context, confidence: 0.9))
    // 过短拒（1 字）
    #expect(!ContinuationTextPolicy.allows(text: "疑", context: context, confidence: 0.9))
    // 低置信拒
    #expect(!ContinuationTextPolicy.allows(text: "疑是地上霜", context: context, confidence: 0.64))
    // 复读：context 尾 32 字的子串拒
    #expect(!ContinuationTextPolicy.allows(text: "明月光", context: context, confidence: 0.9))
    // 半句重复：尾部重叠 ≥ 4 字拒
    #expect(!ContinuationTextPolicy.allows(text: "二三四五六七", context: "一二三四五", confidence: 0.9))
    // 边界：重叠 3 字且非子串允许
    #expect(ContinuationTextPolicy.allows(text: "四五六七八九", context: "一二三四五", confidence: 0.9))
    #expect(ContinuationTextPolicy.hanCount("床前明月光，疑是地上霜") == 10)
    #expect(ContinuationTextPolicy.hanCount("hello") == 0)
}

@Test("continuation response validation")
func continuationResponseValidation() {
    let request = CloudContinuationRequest(
        requestID: "req-1",
        clientSessionID: "sess-1",
        bundleIdentifier: "com.example",
        modelID: "glm-5.3-flash",
        recentContext: "床前明月光，",
        historySnippets: [],
        historyGeneration: 1,
        deadlineMilliseconds: 1_500
    )
    func makeResponse(
        requestID: String? = "req-1",
        decision: String? = "generate",
        text: String? = "疑是地上霜",
        confidence: Double? = 0.9
    ) -> CloudContinuationResponse {
        CloudContinuationResponse(
            status: "ok",
            requestID: requestID,
            decision: decision,
            generatedText: text,
            confidence: confidence,
            reason: nil,
            modelID: "glm-5.3-flash",
            elapsedMilliseconds: 12
        )
    }
    // generate 合法
    #expect(ContinuationTextPolicy.isValid(response: makeResponse(), for: request))
    // generate 缺文本拒
    #expect(!ContinuationTextPolicy.isValid(response: makeResponse(text: nil), for: request))
    // requestID 失配拒
    #expect(!ContinuationTextPolicy.isValid(response: makeResponse(requestID: "other"), for: request))
    // abstain 接受（不产生建议）
    #expect(ContinuationTextPolicy.isValid(response: makeResponse(decision: "abstain", text: nil, confidence: nil), for: request))
    // status 非 ok 拒
    let errored = CloudContinuationResponse(
        status: "error", requestID: "req-1", decision: nil, generatedText: nil,
        confidence: nil, reason: "boom", modelID: nil, elapsedMilliseconds: nil
    )
    #expect(!ContinuationTextPolicy.isValid(response: errored, for: request))
}
