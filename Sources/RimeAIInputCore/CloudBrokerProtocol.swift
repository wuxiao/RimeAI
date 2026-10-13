import Foundation

/// Local attribution record for an applied semantic suggestion (commit
/// attribution, Tab-commit pinyin/rime-index lookup). It is constructed
/// client-side only and never serialized to the cloud wire: the inference
/// request stopped carrying `candidates`/`candidate_pool_hash` on
/// 2026-10-12.
public struct CloudCandidate: Equatable, Sendable {
    public let text: String
    public let rimeIndex: Int?
    /// Letters consumed across all segments (apostrophes excluded),
    /// keeping the segmented and unsegmented paths consistent.
    public let consumedLength: Int
    public let alignedPinyin: String

    public init(
        text: String,
        rimeIndex: Int?,
        consumedLength: Int,
        alignedPinyin: String
    ) {
        self.text = text
        self.rimeIndex = rimeIndex
        self.consumedLength = consumedLength
        self.alignedPinyin = alignedPinyin
    }
}

public struct CloudHistorySnippet: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let bundleIdentifier: String
    public let committedAtMilliseconds: Int64
    public let score: Double

    public init(
        id: String,
        text: String,
        bundleIdentifier: String,
        committedAtMilliseconds: Int64,
        score: Double
    ) {
        self.id = id
        self.text = text
        self.bundleIdentifier = bundleIdentifier
        self.committedAtMilliseconds = committedAtMilliseconds
        self.score = score
    }

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case bundleIdentifier = "bundle_id"
        case committedAtMilliseconds = "committed_at_ms"
        case score
    }
}

/// Inference request for the cloud broker. The broker generates text
/// from pinyin/context/history alone; the wire carries no candidate pool
/// and no pool hash (removed from the contract on 2026-10-12 — the
/// broker ignores both if a legacy client still sends them).
public struct CloudInferenceRequest: Codable, Equatable, Sendable {
    public let schemaVersion = 1
    public let type = "inference"
    public let requestID: String
    public let compositionID: String
    public let revision: UInt64
    public let bundleIdentifier: String
    public let appSessionID: String
    public let clientSessionID: String
    public let modelID: String
    public let deadlineMilliseconds: Int
    public let pinyin: String
    public let recentContext: String
    public let historySnippets: [CloudHistorySnippet]
    public let historyGeneration: Int64
    /// Cross-punctuation segment layout; nil keeps the single-segment
    /// protocol identical to before. When present the last segment must
    /// echo `pinyin` exactly.
    public let segments: [PinyinSegment]?

    public init(
        requestID: String,
        token: CompositionToken,
        bundleIdentifier: String,
        clientSessionID: String,
        modelID: String = RimeAICloudConfiguration.defaultRankingModelID,
        deadlineMilliseconds: Int = 30_000,
        pinyin: String,
        recentContext: String,
        historySnippets: [CloudHistorySnippet],
        historyGeneration: Int64,
        segments: [PinyinSegment]? = nil
    ) {
        self.requestID = requestID
        compositionID = token.compositionID.uuidString
        revision = token.revision
        self.bundleIdentifier = bundleIdentifier
        appSessionID = token.appSessionID
        self.clientSessionID = clientSessionID
        self.modelID = modelID
        self.deadlineMilliseconds = min(
            max(deadlineMilliseconds, 1),
            30_000
        )
        self.pinyin = pinyin
        self.recentContext = String(recentContext.suffix(600))
        self.historySnippets = Array(historySnippets.prefix(8))
        self.historyGeneration = historyGeneration
        self.segments = segments
    }

    public var isValid: Bool {
        // The mixed composition (pinyin interleaved with raw English
        // words) is part of the input, so letters of both cases are
        // accepted; alignment is the model's job, never checked here.
        let pinyinIsAcceptable = pinyin.unicodeScalars.allSatisfy { scalar in
            scalar.value == 39
                || (65 ... 90).contains(scalar.value)
                || (97 ... 122).contains(scalar.value)
        }
        return !requestID.isEmpty
            && UUID(uuidString: compositionID) != nil
            && !bundleIdentifier.isEmpty
            && !appSessionID.isEmpty
            && !clientSessionID.isEmpty
            && RimeAICloudConfiguration.rankingModelIDs.contains(modelID)
            && (1 ... 30_000).contains(deadlineMilliseconds)
            && !pinyin.isEmpty
            && pinyin.utf8.count <= 256
            && pinyinIsAcceptable
            && (segments == nil
                || PinyinSegmentPolicy.isValid(
                    segments!,
                    activePinyin: pinyin
                ))
            && recentContext.count <= 600
            && historySnippets.count <= 8
            && historySnippets.allSatisfy {
                !$0.id.isEmpty
                    && !$0.text.isEmpty
                    && $0.text.utf8.count <= 4_096
                    && !$0.text.contains("\u{0000}")
                    && !$0.bundleIdentifier.isEmpty
                    && $0.score.isFinite
            }
            && historyGeneration >= 0
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case type
        case requestID = "request_id"
        case compositionID = "composition_id"
        case revision
        case bundleIdentifier = "bundle_id"
        case appSessionID = "app_session_id"
        case clientSessionID = "client_session_id"
        case modelID = "model_id"
        case deadlineMilliseconds = "deadline_ms"
        case pinyin
        case recentContext = "recent_context"
        case historySnippets = "history_snippets"
        case historyGeneration = "history_generation"
        case segments
    }
}

public enum CloudInferenceDecision: String, Codable, Sendable {
    case abstain
    case generate
}

/// Structural deep-defense checks for cloud-generated sentence text.
/// Structural deep-defense checks for cloud-generated sentence text.
/// Pinyin alignment is deliberately NOT checked (product decisions
/// 2026-10-12, tier removal 2026-10-13): the model may correct arbitrary
/// typos and compose beyond the typed syllables, so only the shape is
/// bounded — non-empty, ≤128 characters, printable-only (no scalars
/// ≤0x20 or 0x7F) and the confidence floor — plus, for segmented
/// requests, the separator layout. A malformed or hostile response can
/// still never reach presentation.
public enum CloudGeneratedSentencePolicy {
    public static let maximumCharacterCount = 128
    public static let minimumConfidence = 0.60

    /// Single-segment variant (no cross-punctuation layout): structural
    /// bounds only, mixed Chinese/English text allowed.
    public static func allows(
        text: String,
        confidence: Double
    ) -> Bool {
        !text.isEmpty
            && text.count <= maximumCharacterCount
            && text.unicodeScalars.allSatisfy { scalar in
                scalar.value > 0x20 && scalar.value != 0x7F
            }
            && confidence.isFinite
            && confidence >= minimumConfidence
    }

    /// Cross-punctuation variant: the text is split by the requested
    /// separators in order and each part must be non-empty (a dropped
    /// or misplaced separator breaks the layout); the whole text is
    /// then bounded by the single-segment structural rules. Each part
    /// is not required to be pure Han or to fit its segment's pinyin
    /// letter count.
    public static func allows(
        text: String,
        pinyinSegments: [PinyinSegment],
        confidence: Double
    ) -> Bool {
        guard confidence.isFinite,
              confidence >= minimumConfidence,
              let lastSegment = pinyinSegments.last,
              PinyinSegmentPolicy.isValid(
                  pinyinSegments,
                  activePinyin: lastSegment.pinyin
              )
        else {
            return false
        }
        var remainder = text
        var parts: [String] = []
        for segment in pinyinSegments.dropLast() {
            guard let separatorRange = remainder.range(of: segment.separator)
            else {
                return false
            }
            parts.append(String(remainder[..<separatorRange.lowerBound]))
            remainder = String(remainder[separatorRange.upperBound...])
        }
        parts.append(remainder)
        guard parts.allSatisfy({ !$0.isEmpty })
        else {
            return false
        }
        return allows(text: text, confidence: confidence)
    }
}

public enum CloudSemanticPresentationResolver {
    public static func resolveFallback(
        current: SemanticCandidatePresentation,
        localRequestWasScheduled: Bool,
        cloudDecision: CloudInferenceDecision?
    ) -> SemanticCandidatePresentation {
        if localRequestWasScheduled, current != .failure {
            // 本地已有可采纳候选或仍在分析时保持本地展示；本地只剩
            // 负面诊断时，abstain 也不再覆盖（见下），只有传输
            // 失败（nil）才可能改写当前展示。
            switch current {
            case .candidate,
                 .sameTopCandidate,
                 .analyzing,
                 .idle,
                 .cloudAnalyzing,
                 .scriptMismatch:
                return current
            default:
                break
            }
        }
        switch cloudDecision {
        case .abstain:
            return localRequestWasScheduled ? current : .cloudBelowConfidence
        case .generate:
            // A generate decision that failed client-side validation keeps
            // whatever the local pipeline is already showing.
            return current
        case nil:
            return localRequestWasScheduled ? current : .cloudFailure
        }
    }
}

public enum CloudInferenceReason: String, Codable, Sendable {
    case contextMatch = "context_match"
    case historyMatch = "history_match"
    case typoMatch = "typo_match"
    case rimeRank = "rime_rank"
    case uncertain
}

/// Broker result frame. `candidate_pool_hash` is no longer echoed (the
/// request no longer carries one); a transitional broker that still sends
/// the key is simply ignored by the decoder. The decision is only
/// "generate" or "abstain" — candidate ranking (choose/keep) was removed
/// from the contract on 2026-10-12.
public struct CloudInferenceResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let type: String
    public let status: String
    public let requestID: String
    public let compositionID: String
    public let revision: UInt64
    public let appSessionID: String
    public let clientSessionID: String
    public let historyGeneration: Int64
    public let decision: CloudInferenceDecision
    public let confidence: Double?
    public let reason: CloudInferenceReason
    public let modelID: String
    public let elapsedMilliseconds: Double
    /// Present only for `.generate`. Older brokers omit the field and it
    /// decodes as nil.
    public let generatedText: String?
    /// The broker echoes the request pinyin verbatim so the client can
    /// reject misaligned or cross-request payloads byte for byte.
    public let generatedPinyin: String?
    /// Canonical-JSON echo of the request segments ("generated_segments");
    /// present only for segmented `.generate` responses. Older brokers
    /// omit the field and it decodes as nil.
    public let generatedSegments: String?

    public init(
        schemaVersion: Int = 1,
        type: String = "result",
        status: String = "ok",
        requestID: String,
        compositionID: String,
        revision: UInt64,
        appSessionID: String,
        clientSessionID: String,
        historyGeneration: Int64,
        decision: CloudInferenceDecision,
        confidence: Double?,
        reason: CloudInferenceReason,
        modelID: String,
        elapsedMilliseconds: Double,
        generatedText: String? = nil,
        generatedPinyin: String? = nil,
        generatedSegments: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.type = type
        self.status = status
        self.requestID = requestID
        self.compositionID = compositionID
        self.revision = revision
        self.appSessionID = appSessionID
        self.clientSessionID = clientSessionID
        self.historyGeneration = historyGeneration
        self.decision = decision
        self.confidence = confidence
        self.reason = reason
        self.modelID = modelID
        self.elapsedMilliseconds = elapsedMilliseconds
        self.generatedText = generatedText
        self.generatedPinyin = generatedPinyin
        self.generatedSegments = generatedSegments
    }

    public func matches(_ request: CloudInferenceRequest) -> Bool {
        schemaVersion == 1
            && type == "result"
            && status == "ok"
            && requestID == request.requestID
            && compositionID == request.compositionID
            && revision == request.revision
            && appSessionID == request.appSessionID
            && clientSessionID == request.clientSessionID
            && historyGeneration == request.historyGeneration
            && modelID == request.modelID
    }

    public func isValid(for request: CloudInferenceRequest) -> Bool {
        guard matches(request),
              elapsedMilliseconds.isFinite,
              elapsedMilliseconds >= 0,
              elapsedMilliseconds <= Double(request.deadlineMilliseconds),
              !modelID.isEmpty
        else {
            return false
        }
        switch decision {
        case .generate:
            guard let text = generatedText,
                  let echoedPinyin = generatedPinyin,
                  echoedPinyin == request.pinyin,
                  let confidence
            else {
                return false
            }
            if let requestSegments = request.segments {
                guard generatedSegments != nil,
                      generatedSegments
                      == PinyinSegmentPolicy.canonicalJSON(requestSegments),
                      CloudGeneratedSentencePolicy.allows(
                          text: text,
                          pinyinSegments: requestSegments,
                          confidence: confidence
                      )
                else {
                    return false
                }
            } else {
                guard generatedSegments == nil,
                      CloudGeneratedSentencePolicy.allows(
                          text: text,
                          confidence: confidence
                      )
                else {
                    return false
                }
            }
            return true
        case .abstain:
            return confidence == nil
                && generatedText == nil
                && generatedPinyin == nil
                && generatedSegments == nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case type
        case status
        case requestID = "request_id"
        case compositionID = "composition_id"
        case revision
        case appSessionID = "app_session_id"
        case clientSessionID = "client_session_id"
        case historyGeneration = "history_generation"
        case decision
        case confidence
        case reason
        case modelID = "model_id"
        case elapsedMilliseconds = "elapsed_ms"
        case generatedText = "generated_text"
        case generatedPinyin = "generated_pinyin"
        case generatedSegments = "generated_segments"
    }
}

// MARK: - Post-commit continuation

/// Request for an open-ended post-commit continuation suggestion: the
/// broker generates the next phrase purely from already-committed context —
/// no pinyin, no candidate pool. Mirrored in rimeai_cloud_broker/server.py
/// (`_validate_continuation_request`) and cloud_model.py
/// (`continuation_text_allows`).
public struct CloudContinuationRequest: Codable, Sendable {
    public let schemaVersion = 1
    public let type = "continuation"
    public let requestID: String
    public let clientSessionID: String
    public let bundleIdentifier: String
    public let modelID: String
    public let recentContext: String
    public let historySnippets: [CloudHistorySnippet]
    public let historyGeneration: Int64?
    public let deadlineMilliseconds: Int

    public init(
        requestID: String,
        clientSessionID: String,
        bundleIdentifier: String,
        modelID: String,
        recentContext: String,
        historySnippets: [CloudHistorySnippet],
        historyGeneration: Int64?,
        deadlineMilliseconds: Int
    ) {
        self.requestID = requestID
        self.clientSessionID = clientSessionID
        self.bundleIdentifier = bundleIdentifier
        self.modelID = modelID
        self.recentContext = recentContext
        self.historySnippets = historySnippets
        self.historyGeneration = historyGeneration
        self.deadlineMilliseconds = min(
            max(deadlineMilliseconds, 1),
            ContinuationTextPolicy.maximumDeadlineMilliseconds
        )
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case type
        case requestID = "request_id"
        case clientSessionID = "client_session_id"
        case bundleIdentifier = "bundle_id"
        case modelID = "model_id"
        case recentContext = "recent_context"
        case historySnippets = "history_snippets"
        case historyGeneration = "history_generation"
        case deadlineMilliseconds = "deadline_ms"
    }
}

public struct CloudContinuationResponse: Codable, Sendable {
    public let status: String
    public let requestID: String?
    public let decision: String?
    public let generatedText: String?
    public let confidence: Double?
    public let reason: String?
    public let modelID: String?
    public let elapsedMilliseconds: Double?

    public init(
        status: String,
        requestID: String?,
        decision: String?,
        generatedText: String?,
        confidence: Double?,
        reason: String?,
        modelID: String?,
        elapsedMilliseconds: Double?
    ) {
        self.status = status
        self.requestID = requestID
        self.decision = decision
        self.generatedText = generatedText
        self.confidence = confidence
        self.reason = reason
        self.modelID = modelID
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    enum CodingKeys: String, CodingKey {
        case status
        case requestID = "request_id"
        case decision
        case generatedText = "generated_text"
        case confidence
        case reason
        case modelID = "model_id"
        case elapsedMilliseconds = "elapsed_ms"
    }
}

/// Structural deep-defense checks for open-ended continuation text. The
/// broker enforces the same bounds; this mirrors them on the client so a
/// malformed or hostile response can never reach presentation.
public enum ContinuationTextPolicy {
    public static let minHanCharacters = 2
    public static let maxHanCharacters = 16
    public static let minimumConfidence = 0.65
    public static let minimumContextHanCharacters = 4
    public static let maximumContextCharacters = 400
    public static let maximumDeadlineMilliseconds = 30_000
    public static let dedupTailLength = 32
    /// Tail overlap above this many characters is rejected (half-echo).
    public static let maximumTailOverlap = 3

    public static func hanCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            count + ((0x3400 ... 0x9FFF).contains(scalar.value) ? 1 : 0)
        }
    }

    public static func allows(
        text: String,
        context: String,
        confidence: Double
    ) -> Bool {
        guard confidence.isFinite,
              confidence >= minimumConfidence
        else {
            return false
        }
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= minHanCharacters,
              scalars.count <= maxHanCharacters,
              scalars.allSatisfy({ (0x3400 ... 0x9FFF).contains($0.value) })
        else {
            return false
        }
        let tail = String(context.suffix(dedupTailLength))
        guard !tail.contains(text) else {
            return false
        }
        return tailOverlap(context: context, text: text) <= maximumTailOverlap
    }

    /// Longest k such that `context`'s k-character suffix equals `text`'s
    /// k-character prefix (the model repeating the tail of what it saw).
    static func tailOverlap(context: String, text: String) -> Int {
        let contextCharacters = Array(context)
        let textCharacters = Array(text)
        let bound = min(contextCharacters.count, textCharacters.count)
        var overlap = 0
        for k in 1 ... bound where
            String(contextCharacters.suffix(k))
                == String(textCharacters.prefix(k))
        {
            overlap = k
        }
        return overlap
    }

    public static func isValid(request: CloudContinuationRequest) -> Bool {
        guard request.type == "continuation",
              !request.requestID.isEmpty,
              !request.clientSessionID.isEmpty,
              !request.bundleIdentifier.isEmpty,
              !request.modelID.isEmpty,
              hanCount(request.recentContext)
                  >= minimumContextHanCharacters,
              request.recentContext.count <= maximumContextCharacters,
              (1 ... maximumDeadlineMilliseconds)
                  .contains(request.deadlineMilliseconds)
        else {
            return false
        }
        return true
    }

    public static func isValid(
        response: CloudContinuationResponse,
        for request: CloudContinuationRequest
    ) -> Bool {
        guard response.status == "ok",
              response.requestID == request.requestID
        else {
            return false
        }
        switch response.decision {
        case "abstain":
            return true
        case "generate":
            guard let text = response.generatedText,
                  !text.isEmpty,
                  let confidence = response.confidence
            else {
                return false
            }
            return allows(
                text: text,
                context: request.recentContext,
                confidence: confidence
            )
        default:
            return false
        }
    }
}
