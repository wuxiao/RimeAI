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

public struct DaemonHelloRequest: Codable, Sendable {
    public let schemaVersion = 1
    public let type = "hello"
    public let clientID: String
    public let capabilities: [String]

    public init(
        clientID: String,
        capabilities: [String] = ["rerank", "sentence", "cancel", "deadline"]
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
        confidence: Double?
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

    public func isDisplayable(
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
        guard rankedCandidate.isEmpty
                || candidates.contains(rankedCandidate),
              rankedCandidate.count <= 128,
              !rankedCandidate.contains("\n"),
              !rankedCandidate.contains("\r"),
              sentenceSuggestion.count <= 30,
              !sentenceSuggestion.contains("\n"),
              !sentenceSuggestion.contains("\r")
        else {
            return false
        }
        return !displayCandidate.isEmpty
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
