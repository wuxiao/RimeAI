import Foundation

public enum CloudCandidateSource: String, Codable, Sendable {
    case rimeExact = "rime_exact"
    case rimeFuzzy = "rime_fuzzy"
    case userTerm = "user_term"
}

public struct CloudCandidate: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let source: CloudCandidateSource
    public let rimeIndex: Int?
    public let consumedStart: Int
    public let consumedLength: Int
    public let alignedPinyin: String
    public let editCost: Double

    public init(
        id: String = UUID().uuidString,
        text: String,
        source: CloudCandidateSource,
        rimeIndex: Int?,
        consumedStart: Int = 0,
        consumedLength: Int,
        alignedPinyin: String,
        editCost: Double
    ) {
        self.id = id
        self.text = text
        self.source = source
        self.rimeIndex = rimeIndex
        self.consumedStart = consumedStart
        self.consumedLength = consumedLength
        self.alignedPinyin = alignedPinyin
        self.editCost = editCost
    }

    public func isValid(for pinyin: String) -> Bool {
        !id.isEmpty
            && id.utf8.count <= 128
            && !text.isEmpty
            && text.utf8.count <= 512
            && !text.contains("\n")
            && consumedStart == 0
            && consumedLength == pinyin.count
            && !alignedPinyin.isEmpty
            && alignedPinyin.utf8.count <= 256
            && alignedPinyin.unicodeScalars.allSatisfy {
                $0.value == 39 || (97 ... 122).contains($0.value)
            }
            && editCost.isFinite
            && (0 ... 1).contains(editCost)
            && (source != .rimeExact || editCost == 0)
            && (rimeIndex == nil || (0 ..< 50).contains(rimeIndex!))
    }

    public var minimumCloudConfidence: Double {
        source == .rimeFuzzy ? 0.98 : 0.85
    }

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case source
        case rimeIndex = "rime_index"
        case consumedStart = "consumed_start"
        case consumedLength = "consumed_length"
        case alignedPinyin = "aligned_pinyin"
        case editCost = "edit_cost"
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
    public let candidates: [CloudCandidate]
    public let candidatePoolHash: String
    public let recentContext: String
    public let historySnippets: [CloudHistorySnippet]
    public let historyGeneration: Int64

    public init(
        requestID: String,
        token: CompositionToken,
        bundleIdentifier: String,
        clientSessionID: String,
        modelID: String = RimeAICloudConfiguration.defaultRankingModelID,
        deadlineMilliseconds: Int = 4000,
        pinyin: String,
        candidates: [CloudCandidate],
        candidatePoolHash: String,
        recentContext: String,
        historySnippets: [CloudHistorySnippet],
        historyGeneration: Int64
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
            4000
        )
        self.pinyin = pinyin
        self.candidates = Array(candidates.prefix(50))
        self.candidatePoolHash = candidatePoolHash
        self.recentContext = String(recentContext.suffix(600))
        self.historySnippets = Array(historySnippets.prefix(8))
        self.historyGeneration = historyGeneration
    }

    public var isValid: Bool {
        !requestID.isEmpty
            && UUID(uuidString: compositionID) != nil
            && !bundleIdentifier.isEmpty
            && !appSessionID.isEmpty
            && !clientSessionID.isEmpty
            && RimeAICloudConfiguration.rankingModelIDs.contains(modelID)
            && (1 ... 4000).contains(deadlineMilliseconds)
            && !pinyin.isEmpty
            && pinyin.utf8.count <= 256
            && pinyin.unicodeScalars.allSatisfy {
                $0.value == 39 || (97 ... 122).contains($0.value)
            }
            && (1 ... 50).contains(candidates.count)
            && Set(candidates.map(\.id)).count == candidates.count
            && candidates.allSatisfy { $0.isValid(for: pinyin) }
            && !candidatePoolHash.isEmpty
            && candidatePoolHash.utf8.count <= 128
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
        case candidates
        case candidatePoolHash = "candidate_pool_hash"
        case recentContext = "recent_context"
        case historySnippets = "history_snippets"
        case historyGeneration = "history_generation"
    }
}

public enum CloudInferenceDecision: String, Codable, Sendable {
    case choose
    case keep
    case abstain
}

public enum CloudSemanticPresentationResolver {
    public static func resolveFallback(
        current: SemanticCandidatePresentation,
        localRequestWasScheduled: Bool,
        cloudDecision: CloudInferenceDecision?
    ) -> SemanticCandidatePresentation {
        if localRequestWasScheduled, current != .failure {
            return current
        }
        switch cloudDecision {
        case .keep:
            return .cloudSameTopCandidate
        case .abstain:
            return .cloudBelowConfidence
        case .choose:
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

public struct CloudInferenceResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let type: String
    public let status: String
    public let requestID: String
    public let compositionID: String
    public let revision: UInt64
    public let appSessionID: String
    public let clientSessionID: String
    public let candidatePoolHash: String
    public let historyGeneration: Int64
    public let decision: CloudInferenceDecision
    public let candidateID: String?
    public let confidence: Double?
    public let reason: CloudInferenceReason
    public let modelID: String
    public let elapsedMilliseconds: Double

    public init(
        schemaVersion: Int = 1,
        type: String = "result",
        status: String = "ok",
        requestID: String,
        compositionID: String,
        revision: UInt64,
        appSessionID: String,
        clientSessionID: String,
        candidatePoolHash: String,
        historyGeneration: Int64,
        decision: CloudInferenceDecision,
        candidateID: String?,
        confidence: Double?,
        reason: CloudInferenceReason,
        modelID: String,
        elapsedMilliseconds: Double
    ) {
        self.schemaVersion = schemaVersion
        self.type = type
        self.status = status
        self.requestID = requestID
        self.compositionID = compositionID
        self.revision = revision
        self.appSessionID = appSessionID
        self.clientSessionID = clientSessionID
        self.candidatePoolHash = candidatePoolHash
        self.historyGeneration = historyGeneration
        self.decision = decision
        self.candidateID = candidateID
        self.confidence = confidence
        self.reason = reason
        self.modelID = modelID
        self.elapsedMilliseconds = elapsedMilliseconds
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
            && candidatePoolHash == request.candidatePoolHash
            && historyGeneration == request.historyGeneration
            && modelID == request.modelID
    }

    public func selectedCandidate(
        for request: CloudInferenceRequest
    ) -> CloudCandidate? {
        guard isValid(for: request) else {
            return nil
        }
        switch decision {
        case .choose:
            guard let candidateID,
                  let confidence,
                  confidence.isFinite,
                  (0 ... 1).contains(confidence)
            else {
                return nil
            }
            return request.candidates.first { $0.id == candidateID }
        case .keep, .abstain:
            return nil
        }
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
        case .choose:
            guard let candidateID,
                  let candidate = request.candidates.first(
                      where: { $0.id == candidateID }
                  ),
                  let confidence,
                  confidence.isFinite,
                  (candidate.minimumCloudConfidence ... 1)
                      .contains(confidence)
            else {
                return false
            }
            return true
        case .keep, .abstain:
            return candidateID == nil && confidence == nil
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
        case candidatePoolHash = "candidate_pool_hash"
        case historyGeneration = "history_generation"
        case decision
        case candidateID = "candidate_id"
        case confidence
        case reason
        case modelID = "model_id"
        case elapsedMilliseconds = "elapsed_ms"
    }
}
