import Foundation

public enum ContextPolicy: String, Codable, Sendable {
    case strict
    case standard
    case smart

    var maximumCharacters: Int {
        switch self {
        case .strict:
            0
        case .standard:
            100
        case .smart:
            400
        }
    }
}

public enum SemanticInferenceDecision: String, Codable, Sendable {
    case rankedCandidate = "ranked_candidate"
    case sentenceSuggestion = "sentence_suggestion"
    case sameTopCandidate = "same_top_candidate"
    case belowConfidence = "below_confidence"
    case noCandidate = "no_candidate"
    case sentenceTooLong = "sentence_too_long"
    case sentenceIncomplete = "sentence_incomplete"
}

public enum SemanticCandidatePresentation: Equatable, Sendable {
    case idle
    case analyzing
    case candidate(
        text: String,
        decision: SemanticInferenceDecision,
        confidence: Double
    )
    case sameTopCandidate
    case belowConfidence
    case noCandidate
    case sentenceTooLong
    case sentenceIncomplete
    case inputTooLong
    case unavailable
    case failure

    public var title: String {
        switch self {
        case .idle:
            "✦ 本地模型待命"
        case .analyzing:
            "✦ 本地模型分析中…"
        case let .candidate(text, _, _):
            "✦ \(text)"
        case .sameTopCandidate:
            "✦ 本地模型：首选一致"
        case .belowConfidence:
            "✦ 本地模型：置信度不足，保留 Rime"
        case .noCandidate:
            "✦ 本地模型：没有可用语义候选"
        case .sentenceTooLong:
            "✦ 本地模型：整句超过 30 字，请分段输入"
        case .sentenceIncomplete:
            "✦ 本地模型：候选未覆盖完整拼音，保留 Rime"
        case .inputTooLong:
            "✦ 本地模型：拼音输入过长，保留 Rime"
        case .unavailable:
            "✦ 本地模型已停用"
        case .failure:
            "✦ 本地模型暂不可用，已回退 Rime"
        }
    }

    public var isSelectable: Bool {
        if case .candidate = self {
            return true
        }
        return false
    }

    public var prefersCommitOnSpace: Bool {
        guard case let .candidate(_, decision, confidence) = self else {
            return false
        }
        switch decision {
        case .rankedCandidate:
            return confidence >= 0.90
        case .sentenceSuggestion:
            return confidence >= 0.97
        case .sameTopCandidate,
             .belowConfidence,
             .noCandidate,
             .sentenceTooLong,
             .sentenceIncomplete:
            return false
        }
    }
}

public struct DaemonHelloRequest: Codable, Sendable {
    public let schemaVersion = 1
    public let type = "hello"
    public let clientID: String
    public let capabilities: [String]

    public init(
        clientID: String,
        capabilities: [String] = [
            "rerank",
            "sentence",
            "cancel",
            "deadline",
            "decision-reasons",
            "long-input-reasons",
        ]
    ) {
        self.clientID = clientID
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case type
        case clientID = "client_id"
        case capabilities
    }
}

public struct DaemonHelloResponse: Codable, Sendable {
    public let schemaVersion: Int
    public let type: String
    public let status: String
    public let protocolVersion: Int
    public let capabilities: [String]
    public let modelArtifactID: String
    public let offlineLock: Bool?
    public let modelArtifacts: [DaemonModelArtifact]?

    public var isCompatible: Bool {
        schemaVersion == 1
            && type == "hello"
            && status == "ok"
            && protocolVersion == 1
            && capabilities.contains("decision-reasons")
            && capabilities.contains("long-input-reasons")
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case type
        case status
        case protocolVersion = "protocol_version"
        case capabilities
        case modelArtifactID = "model_artifact_id"
        case offlineLock = "offline_lock"
        case modelArtifacts = "model_artifacts"
    }
}

public struct DaemonModelArtifact: Codable, Equatable, Sendable {
    public let role: String
    public let path: String
    public let sha256: String

    public init(role: String, path: String, sha256: String) {
        self.role = role
        self.path = path
        self.sha256 = sha256
    }
}

public struct SemanticInferenceRequest: Codable, Sendable {
    public let schemaVersion = 1
    public let type = "infer"
    public let requestID: String
    public let compositionID: String
    public let revision: UInt64
    public let appSessionID: String
    public let contextPolicy: ContextPolicy
    public let context: String
    public let pinyin: String
    public let candidates: [String]
    public let deadlineMilliseconds: Int
    public let allowSentence: Bool
    public let sensitive = false

    public init(
        requestID: String,
        token: CompositionToken,
        contextPolicy: ContextPolicy,
        context: String,
        pinyin: String,
        candidates: [String],
        deadlineMilliseconds: Int,
        allowSentence: Bool
    ) {
        self.requestID = requestID
        compositionID = token.compositionID.uuidString
        revision = token.revision
        appSessionID = token.appSessionID
        self.contextPolicy = contextPolicy
        self.context = String(context.suffix(contextPolicy.maximumCharacters))
        self.pinyin = String(pinyin.prefix(256))
        self.candidates = Array(candidates.prefix(10))
        self.deadlineMilliseconds = min(
            max(deadlineMilliseconds, 1),
            5_000
        )
        self.allowSentence = allowSentence
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case type
        case requestID = "request_id"
        case compositionID = "composition_id"
        case revision
        case appSessionID = "app_session_id"
        case contextPolicy = "context_policy"
        case context
        case pinyin
        case candidates
        case deadlineMilliseconds = "deadline_ms"
        case allowSentence = "allow_sentence"
        case sensitive
    }
}

public struct SemanticInferenceResult: Codable, Sendable {
    public let schemaVersion: Int
    public let type: String
    public let status: String
    public let requestID: String?
    public let compositionID: String?
    public let revision: UInt64?
    public let appSessionID: String?
    public let rankedCandidate: String?
    public let sentenceSuggestion: String?
    public let confidence: Double?
    public let decision: SemanticInferenceDecision?
    public let modelArtifactID: String?
    public let elapsedMilliseconds: Double?

    public init(
        schemaVersion: Int = 1,
        type: String = "result",
        status: String,
        requestID: String?,
        compositionID: String?,
        revision: UInt64?,
        appSessionID: String?,
        rankedCandidate: String?,
        sentenceSuggestion: String?,
        confidence: Double?,
        decision: SemanticInferenceDecision? = nil,
        modelArtifactID: String? = nil,
        elapsedMilliseconds: Double? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.type = type
        self.status = status
        self.requestID = requestID
        self.compositionID = compositionID
        self.revision = revision
        self.appSessionID = appSessionID
        self.rankedCandidate = rankedCandidate
        self.sentenceSuggestion = sentenceSuggestion
        self.confidence = confidence
        self.decision = decision
        self.modelArtifactID = modelArtifactID
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    public func matches(_ token: CompositionToken) -> Bool {
        schemaVersion == 1
            && type == "result"
            && status == "ok"
            && compositionID == token.compositionID.uuidString
            && revision == token.revision
            && appSessionID == token.appSessionID
    }

    public var displayCandidate: String {
        if let sentenceSuggestion, !sentenceSuggestion.isEmpty {
            return sentenceSuggestion
        }
        return rankedCandidate ?? ""
    }

    public var resolvedDecision: SemanticInferenceDecision? {
        if let decision {
            return decision
        }
        if let sentenceSuggestion, !sentenceSuggestion.isEmpty {
            return .sentenceSuggestion
        }
        if let rankedCandidate, !rankedCandidate.isEmpty {
            return .rankedCandidate
        }
        return nil
    }

    public var candidatePresentation: SemanticCandidatePresentation {
        guard let confidence,
              let decision = resolvedDecision
        else {
            return .failure
        }
        switch decision {
        case .rankedCandidate:
            return .candidate(
                text: rankedCandidate ?? "",
                decision: decision,
                confidence: confidence
            )
        case .sentenceSuggestion:
            return .candidate(
                text: sentenceSuggestion ?? "",
                decision: decision,
                confidence: confidence
            )
        case .sameTopCandidate:
            return .sameTopCandidate
        case .belowConfidence:
            return .belowConfidence
        case .noCandidate:
            return .noCandidate
        case .sentenceTooLong:
            return .sentenceTooLong
        case .sentenceIncomplete:
            return .sentenceIncomplete
        }
    }

    public func isValid(
        for token: CompositionToken,
        candidates: [String]
    ) -> Bool {
        guard matches(token),
              let confidence,
              confidence.isFinite,
              (0 ... 1).contains(confidence)
        else {
            return false
        }
        let rankedCandidate = rankedCandidate ?? ""
        let sentenceSuggestion = sentenceSuggestion ?? ""
        guard rankedCandidate.isEmpty || candidates.contains(rankedCandidate),
              rankedCandidate.count <= 128,
              !rankedCandidate.contains("\n"),
              !rankedCandidate.contains("\r"),
              sentenceSuggestion.count <= 30,
              !sentenceSuggestion.contains("\n"),
              !sentenceSuggestion.contains("\r")
        else {
            return false
        }
        switch resolvedDecision {
        case .rankedCandidate:
            return !rankedCandidate.isEmpty && sentenceSuggestion.isEmpty
        case .sentenceSuggestion:
            return rankedCandidate.isEmpty && !sentenceSuggestion.isEmpty
        case .sameTopCandidate,
             .belowConfidence,
             .noCandidate,
             .sentenceTooLong,
             .sentenceIncomplete:
            return rankedCandidate.isEmpty && sentenceSuggestion.isEmpty
        case nil:
            return false
        }
    }

    public func isDisplayable(
        for token: CompositionToken,
        candidates: [String]
    ) -> Bool {
        isValid(for: token, candidates: candidates)
            && candidatePresentation.isSelectable
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case type
        case status
        case requestID = "request_id"
        case compositionID = "composition_id"
        case revision
        case appSessionID = "app_session_id"
        case rankedCandidate = "ranked_candidate"
        case sentenceSuggestion = "sentence_suggestion"
        case confidence
        case decision
        case modelArtifactID = "model_artifact_id"
        case elapsedMilliseconds = "elapsed_ms"
    }
}

public struct DaemonCancelRequest: Codable, Sendable {
    public let schemaVersion = 1
    public let type = "cancel"
    public let requestID: String

    public init(requestID: String) {
        self.requestID = requestID
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case type
        case requestID = "request_id"
    }
}
