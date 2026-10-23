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
/// 云策略层的 CompositionState 派生：语义候选整句覆盖判定与提交
/// 文本组装。仅 macOS 主线目标编译（iOS 键盘为本地-only，不编译
/// 云协议层，也不使用这些成员）。
extension CompositionState {
    /// 语义候选是否已整句覆盖定稿前缀：候选携带跨标点段布局，且
    /// 布局与候选文本的结构校验（分隔符按序出现、各段非空、整体
    /// 不超上限）通过即视为覆盖。校验与准入用同一个
    /// `CloudGeneratedSentencePolicy`（confidence 传 1，只关心结
    /// 构），提交判定因此与准入判定同口径。
    var semanticCandidateCoversPrefix: Bool {
        guard let text = semanticCandidate,
              let segments = semanticCandidateSegments
        else {
            return false
        }
        return CloudGeneratedSentencePolicy.allows(
            text: text,
            pinyinSegments: segments,
            confidence: 1
        )
    }

    /// 语义候选提交时上屏的完整文本：候选携带跨标点段布局且布局
    /// 与候选文本匹配（`semanticCandidateCoversPrefix`）时，整句已
    /// 覆盖焦点之外的全部内容，直接返回候选本身，前置定稿文本会
    /// 造成重复上屏；无布局或布局不匹配时前置全部定稿文本（前缀 +
    /// 字面量运行 + 后缀）。段布局随 `beginSelection()` 清空，须在
    /// 此之前调用。
    public func semanticCandidateCommitText(for candidate: String) -> String {
        if candidate == semanticCandidate, semanticCandidateCoversPrefix {
            return candidate
        }
        return committedOuterText + candidate
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
    /// 续写短语末尾允许保留的单个中文标点（2026-10-22 决策：允许尾部
    /// 标点并随接受上屏）。句中任意位置与非集合标点仍然拒绝。
    public static let trailingPunctuation: Set<Character> = [
        "，", "。", "？", "！", "；", "：",
    ]

    public static func hanCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            count + ((0x3400 ... 0x9FFF).contains(scalar.value) ? 1 : 0)
        }
    }

    /// 剥离可选的单个尾部中文标点，返回参与纯汉字校验的主体。
    /// 标点不计入 2-16 的长度上限，但必须在集合内且只能出现在末尾。
    static func hanOnlyBody(of text: String) -> Substring {
        if let last = text.last, trailingPunctuation.contains(last) {
            return text.dropLast()
        }
        return text[...]
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
        // 尾部允许一个中文标点：主体必须全部是 CJK 汉字，
        // 长度上限按汉字数计（标点不计入）。
        let scalars = Array(hanOnlyBody(of: text).unicodeScalars)
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

    /// Longest overlap length such that `context`'s suffix equals `text`'s
    /// prefix of the same length (the model repeating the tail of what it
    /// saw).
    static func tailOverlap(context: String, text: String) -> Int {
        let contextCharacters = Array(context)
        let textCharacters = Array(text)
        let bound = min(contextCharacters.count, textCharacters.count)
        var overlap = 0
        for overlapLength in 1 ... bound where
            String(contextCharacters.suffix(overlapLength))
                == String(textCharacters.prefix(overlapLength))
        {
            overlap = overlapLength
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
