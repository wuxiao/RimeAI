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
    case mixedComposition = "mixed_composition"
    case phraseBook = "phrase_book"
    case sameTopCandidate = "same_top_candidate"
    case insufficientCandidates = "insufficient_candidates"
    case belowConfidence = "below_confidence"
    case noCandidate = "no_candidate"
    case sentenceTooLong = "sentence_too_long"
    case sentenceIncomplete = "sentence_incomplete"
}

public enum SemanticCandidatePresentation: Hashable, Sendable {
    case idle
    case analyzing
    case candidate(
        text: String,
        decision: SemanticInferenceDecision,
        confidence: Double
    )
    case sameTopCandidate
    case insufficientCandidates
    case belowConfidence
    case noCandidate
    case sentenceTooLong
    case sentenceIncomplete
    case scriptMismatch
    case inputTooLong
    case cloudAnalyzing
    case cloudSameTopCandidate
    case cloudBelowConfidence
    case cloudFailure
    case continuation(candidate: String)
    case unavailable
    case failure

    public var title: String {
        title(mainCandidate: nil)
    }

    public func title(mainCandidate: String?) -> String {
        switch self {
        case let .candidate(text, decision, _):
            switch decision {
            case .mixedComposition:
                return "✦ 中英混输：\(text)"
            case .phraseBook:
                return "✦ 个人短语：\(text)"
            default:
                return "✦ \(text)"
            }
        case .sameTopCandidate:
            if let mainCandidate, !mainCandidate.isEmpty {
                return "✦ AI 建议：\(mainCandidate)（与 Rime 首选一致）"
            }
            return "✦ 本地模型：首选一致"
        case let .continuation(candidate):
            return "✦ 续写：\(candidate)"
        default:
            return Self.fixedTitles[self]
                ?? "✦ 本地模型暂不可用，已回退 Rime"
        }
    }

    /// Constant titles for the payload-free cases; parameterized cases
    /// (`.candidate`/`.sameTopCandidate`/`.continuation`) are formatted
    /// inline in `title(mainCandidate:)`.
    private static let fixedTitles: [SemanticCandidatePresentation: String] = [
        .idle: "✦ 本地模型待命",
        .analyzing: "✦ 本地模型分析中…",
        .insufficientCandidates: "✦ 本地模型：完整候选不足，未执行重排",
        .belowConfidence: "✦ 本地模型：置信度不足，保留 Rime",
        .noCandidate: "✦ 本地模型：没有可用语义候选",
        .sentenceTooLong: "✦ 本地模型：整句超过 30 字，请分段输入",
        .sentenceIncomplete: "✦ 本地模型：候选未覆盖完整拼音，保留 Rime",
        .scriptMismatch: "✦ 本地模型：整句字形与当前简繁设置不符，保留 Rime",
        .inputTooLong: "✦ 本地模型：拼音输入过长，保留 Rime",
        .cloudAnalyzing: "☁︎ 云端分析中…",
        .cloudSameTopCandidate: "☁︎ 云端：首选一致",
        .cloudBelowConfidence: "☁︎ 云端：置信度不足，保留 Rime",
        .cloudFailure: "☁︎ 云端暂不可用，已回退 Rime",
        .unavailable: "✦ 本地模型已停用",
        .failure: "✦ 本地模型暂不可用，已回退 Rime",
    ]

    public var isSelectable: Bool {
        switch self {
        case .candidate, .continuation:
            return true
        default:
            return false
        }
    }

    public var isContinuation: Bool {
        if case .continuation = self {
            return true
        }
        return false
    }

    public var isMixedCompositionCandidate: Bool {
        if case let .candidate(_, decision, _) = self {
            return decision == .mixedComposition
        }
        return false
    }

    /// 云端"与首选一致"表态：建议位本身不可选（无独立候选文本），
    /// 但 Tab 允许直接上屏该一致的全局首选候选。
    public var tabCommitsFirstMainCandidate: Bool {
        self == .cloudSameTopCandidate
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
            "sentence-late",
        ]
    ) {
        // reveal B-F8（冻结的不对称）：客户端无条件通告 sentence-late
        // 并随发送登记迟到帧期望槽；服务端只在自身配置了神经臂且
        // 客户端也通告时才发帧。旧 daemon 从不发帧，客户端期望槽
        // 由下一次请求/组合重置回收，fail-safe。不依据服务端回显
        // 决定是否武装是有意为之（避免对 hello 时序的额外依赖）。
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
            && offlineLock == true
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

struct DaemonClientConnectionState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case disconnected
        case connecting
        case awaitingHello
        case ready
    }

    private(set) var generation: UInt64 = 0
    private(set) var phase: Phase = .disconnected

    var canSendApplicationFrames: Bool {
        phase == .ready
    }

    func canAcceptApplicationFrame(generation: UInt64) -> Bool {
        generation == self.generation && phase == .ready
    }

    mutating func beginConnection() -> UInt64 {
        generation &+= 1
        phase = .connecting
        return generation
    }

    mutating func transportBecameReady(generation: UInt64) -> Bool {
        guard generation == self.generation, phase == .connecting else {
            return false
        }
        phase = .awaitingHello
        return true
    }

    mutating func acceptHello(
        _ response: DaemonHelloResponse,
        generation: UInt64
    ) -> Bool {
        guard generation == self.generation,
              phase == .awaitingHello,
              response.isCompatible
        else {
            return false
        }
        phase = .ready
        return true
    }

    mutating func invalidate(generation: UInt64) -> Bool {
        guard generation == self.generation, phase != .disconnected else {
            return false
        }
        phase = .disconnected
        return true
    }

    func shouldExpireConnection(generation: UInt64) -> Bool {
        generation == self.generation && phase == .connecting
    }

    func shouldExpireHello(generation: UInt64) -> Bool {
        generation == self.generation && phase == .awaitingHello
    }
}

struct DaemonClientReadyWaitState: Equatable, Sendable {
    private(set) var generation: UInt64?

    mutating func arm(generation: UInt64) {
        self.generation = generation
    }

    mutating func consumeReady(
        generation: UInt64,
        connectionState: DaemonClientConnectionState
    ) -> Bool {
        guard self.generation == generation,
              connectionState.canAcceptApplicationFrame(
                  generation: generation
              )
        else {
            return false
        }
        self.generation = nil
        return true
    }

    mutating func consumeFailure(generation: UInt64) -> Bool {
        guard self.generation == generation else {
            return false
        }
        self.generation = nil
        return true
    }
}

struct DaemonClientOutboundFrame: Equatable, Sendable {
    let requestID: String?
    let data: Data
}

struct DaemonClientOutboundQueue: Equatable, Sendable {
    private(set) var frames: [DaemonClientOutboundFrame] = []

    var isEmpty: Bool { frames.isEmpty }

    mutating func enqueueApplication(requestID: String, data: Data) {
        frames.append(
            DaemonClientOutboundFrame(requestID: requestID, data: data)
        )
    }

    mutating func enqueueControl(data: Data) {
        frames.append(DaemonClientOutboundFrame(requestID: nil, data: data))
    }

    mutating func drain() -> [DaemonClientOutboundFrame] {
        let result = frames
        frames.removeAll(keepingCapacity: true)
        return result
    }

    mutating func removeAll() {
        frames.removeAll(keepingCapacity: false)
    }

    mutating func cancelRequest(
        requestID: String,
        protocolReady: Bool
    ) -> Bool {
        let hadBufferedApplication = frames.contains {
            $0.requestID == requestID
        }
        frames.removeAll { $0.requestID == requestID }
        return hadBufferedApplication ? false : protocolReady
    }
}

public struct DaemonModelArtifact: Codable, Equatable, Sendable {
    public let role: String
    public let path: String
    /// 脚本类工件（如 neural_sentence 的 constrained_mlx_service.sh）
    /// 无法稳定取哈希，daemon 不回该字段：必须可选，否则整个
    /// hello 帧解码失败 → “协议不兼容”拆连 ×3 → 熔断，
    /// 面板永久“本地模型暂不可用”（2026-10-23 定案）。
    public let sha256: String?

    public init(role: String, path: String, sha256: String? = nil) {
        self.role = role
        self.path = path
        self.sha256 = sha256
    }
}

/// One punctuation-delimited slice of the composition. The last segment is
/// the active pinyin; earlier segments carry the committed text snapshot
/// and the separator typed after them.
public struct PinyinSegment: Codable, Equatable, Sendable {
    /// `[a-z']+`, bounded by `PinyinSegmentPolicy`.
    public let pinyin: String
    /// Trailing punctuation committed after this segment; "" on the last
    /// (active) segment.
    public let separator: String
    /// Committed snapshot of the segment text; nil on the active segment.
    /// Serialized as "committed_text" and omitted when nil.
    public let committedText: String?

    public init(
        pinyin: String,
        separator: String,
        committedText: String? = nil
    ) {
        self.pinyin = pinyin
        self.separator = separator
        self.committedText = committedText
    }

    enum CodingKeys: String, CodingKey {
        case pinyin
        case separator
        case committedText = "committed_text"
    }
}

public enum PinyinSegmentPolicy {
    public static let maximumSegments = 8
    public static let maximumSegmentPinyinLetters = 64
    public static let maximumTotalLetters = 256

    private static let maximumCommittedTextLength = 64
    private static let maximumSeparatorUTF8Bytes = 8

    /// ASCII punctuation, General Punctuation, CJK punctuation and
    /// fullwidth ASCII variants. U+2028/U+2029 are excluded so the
    /// canonical JSON encoding stays byte-stable against the Python
    /// mirror.
    private static let punctuationScalarRanges: [ClosedRange<UInt32>] = [
        0x21...0x2F,
        0x3A...0x40,
        0x5B...0x60,
        0x7B...0x7E,
        0x2000...0x2027,
        0x202A...0x206F,
        0x3001...0x303F,
        0xFF01...0xFF5E,
    ]

    public static func isValid(
        _ segments: [PinyinSegment],
        activePinyin: String
    ) -> Bool {
        guard (1 ... maximumSegments).contains(segments.count),
              let last = segments.last,
              last.pinyin == activePinyin,
              last.separator.isEmpty
        else {
            return false
        }
        var totalLetters = 0
        for (index, segment) in segments.enumerated() {
            let isLast = index == segments.count - 1
            let letters = segment.pinyin.unicodeScalars.filter {
                $0.value != 39
            }
            let pinyinIsLowercase = segment.pinyin.unicodeScalars.allSatisfy {
                $0.value == 39 || (97 ... 122).contains($0.value)
            }
            let separatorIsPunctuation = segment.separator.unicodeScalars
                .allSatisfy { scalar in
                    punctuationScalarRanges.contains {
                        $0.contains(scalar.value)
                    }
                }
            guard !segment.pinyin.isEmpty,
                  pinyinIsLowercase,
                  letters.count <= maximumSegmentPinyinLetters,
                  isLast || !segment.separator.isEmpty,
                  segment.separator.utf8.count <= maximumSeparatorUTF8Bytes,
                  separatorIsPunctuation
            else {
                return false
            }
            if let committedText = segment.committedText {
                guard committedText.count <= maximumCommittedTextLength,
                      !committedText.contains("\n"),
                      !committedText.contains("\u{0}")
                else {
                    return false
                }
            }
            totalLetters += letters.count
        }
        return totalLetters <= maximumTotalLetters
    }

    /// Canonical JSON form of the segments, byte-identical to the Python
    /// mirror `json.dumps(..., sort_keys=True, ensure_ascii=False,
    /// separators=(",", ":"))`. Returns nil for structurally invalid
    /// segments.
    public static func canonicalJSON(_ segments: [PinyinSegment]) -> String? {
        guard let last = segments.last,
              isValid(segments, activePinyin: last.pinyin)
        else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(segments),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        // Swift's JSONEncoder escapes "/" as "\/" while Python leaves it
        // unescaped. The sequence "\/" in the encoded output can only come
        // from that escaping (a literal backslash encodes as "\\"), so the
        // replacement cannot corrupt any other content.
        return json.replacingOccurrences(of: "\\/", with: "/")
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
    /// Cross-punctuation segment layout; nil keeps the single-segment
    /// protocol identical to before. When present the last segment is the
    /// active pinyin echoed by `pinyin`.
    public let segments: [PinyinSegment]?
    /// Caller-resolved domain (bundle→domain mapping, P2-4). nil omits
    /// the key entirely, which old daemons parse as the pre-domain
    /// protocol (engine treats a missing/invalid value as global).
    public let domain: String?
    /// Target script for sentence suggestions ("simplified"). nil omits
    /// the key: the daemon keeps its legacy behavior (beam suggestions
    /// surface in the dictionary's traditional script).
    public let characterSet: String?

    public init(
        requestID: String,
        token: CompositionToken,
        contextPolicy: ContextPolicy,
        context: String,
        pinyin: String,
        candidates: [String],
        deadlineMilliseconds: Int,
        allowSentence: Bool,
        segments: [PinyinSegment]? = nil,
        domain: String? = nil,
        characterSet: String? = nil
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
        self.segments = segments
        self.domain = domain
        self.characterSet = characterSet
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
        case segments
        case domain
        case characterSet = "character_set"
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


    public func candidatePresentation(
        characterSet: RimeAICharacterSetPreference
    ) -> SemanticCandidatePresentation {
        guard let confidence,
              let decision = resolvedDecision
        else {
            return .failure
        }
        switch decision {
        case .rankedCandidate:
            // The Rime dictionary contains traditional entries and the
            // engine applies script options asynchronously, so a ranked
            // candidate must also match the user's script preference.
            let candidate = rankedCandidate ?? ""
            guard SemanticCandidateScriptPolicy.allows(
                text: candidate,
                characterSet: characterSet
            ) else {
                return .scriptMismatch
            }
            return .candidate(
                text: candidate,
                decision: decision,
                confidence: confidence
            )
        case .sentenceSuggestion:
            let suggestion = sentenceSuggestion ?? ""
            guard SemanticCandidateScriptPolicy.allows(
                text: suggestion,
                characterSet: characterSet
            ) else {
                return .scriptMismatch
            }
            return .candidate(
                text: suggestion,
                decision: decision,
                confidence: confidence
            )
        case .mixedComposition:
            // Mixed composition is constructed inside the trusted client from
            // typed segments. The daemon is not allowed to synthesize it.
            return .failure
        case .phraseBook:
            // Phrasebook fill is a client-side slot fallback (LP-006); the
            // daemon is not allowed to claim it.
            return .failure
        case .sameTopCandidate:
            return .sameTopCandidate
        case .insufficientCandidates:
            return .insufficientCandidates
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
        candidates: [String],
        segments: [PinyinSegment]? = nil
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
        // Sentence suggestions share the single cloud-generated policy:
        // non-empty, ≤128 printable characters, confidence floor; a
        // cross-punctuation sentence must additionally match the
        // requested segment layout.
        let sentenceWithinBounds: Bool
        if let segments, !sentenceSuggestion.isEmpty {
            sentenceWithinBounds = CloudGeneratedSentencePolicy.allows(
                text: sentenceSuggestion,
                pinyinSegments: segments,
                confidence: confidence
            )
        } else {
            sentenceWithinBounds = sentenceSuggestion.isEmpty
                || CloudGeneratedSentencePolicy.allows(
                    text: sentenceSuggestion,
                    confidence: confidence
                )
        }
        guard rankedCandidate.isEmpty || candidates.contains(rankedCandidate),
              rankedCandidate.count <= 128,
              !rankedCandidate.contains("\n"),
              !rankedCandidate.contains("\r"),
              sentenceWithinBounds,
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
        case .mixedComposition:
            return false
        case .phraseBook:
            return false
        case .sameTopCandidate,
             .insufficientCandidates,
             .belowConfidence,
             .noCandidate,
             .sentenceTooLong,
             .sentenceIncomplete:
            return rankedCandidate.isEmpty && sentenceSuggestion.isEmpty
        case nil:
            return false
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
        case rankedCandidate = "ranked_candidate"
        case sentenceSuggestion = "sentence_suggestion"
        case confidence
        case decision
        case modelArtifactID = "model_artifact_id"
        case elapsedMilliseconds = "elapsed_ms"
    }
}

/// 异步神经整句迟到帧（LM-001 双延迟档的神经臂）：daemon 在同步
/// result 之后追加交付，绑定同一 composition/revision/session。
/// 结构/绑定校验与 result 同口径；拼音正确性由 worker 端拼音掩码
/// 与终门保证（约束解码合同），客户端不重复拼音校验。
public struct DaemonSentenceLateFrame: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let type: String
    public let status: String
    public let requestID: String?
    public let compositionID: String?
    public let revision: UInt64?
    public let appSessionID: String?
    public let sentenceSuggestion: String?
    public let confidence: Double?
    public let modelArtifactID: String?
    public let elapsedMilliseconds: Double?

    public init(
        schemaVersion: Int = 1,
        type: String = "sentence_late",
        status: String,
        requestID: String? = nil,
        compositionID: String? = nil,
        revision: UInt64? = nil,
        appSessionID: String? = nil,
        sentenceSuggestion: String? = nil,
        confidence: Double? = nil,
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
        self.sentenceSuggestion = sentenceSuggestion
        self.confidence = confidence
        self.modelArtifactID = modelArtifactID
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    /// 与 result.matches 同口径的绑定校验（type 换为迟到帧自身）。
    public func matches(_ token: CompositionToken) -> Bool {
        schemaVersion == 1
            && type == "sentence_late"
            && status == "ok"
            && compositionID == token.compositionID.uuidString
            && revision == token.revision
            && appSessionID == token.appSessionID
    }

    /// 结构门：非空单行整句 ≤30 字、全部可打印（与同步路径
    /// `CloudGeneratedSentencePolicy` 同口径：scalar > 0x20 且非
    /// 0x7F），置信度有限且在 [0, 1]。
    ///
    /// 长度语义（reveal B-F3）：daemon 侧按 Unicode 码点计数
    /// （Python `len()`），本侧按字形簇（`String.count`）计数；
    /// 码点数 ≥ 字形簇数，故 daemon 门更严，不存在仅本侧放行的
    /// 旁路。两侧上限值必须同步演进（daemon：
    /// `neural_sentence.MAX_CHARACTERS`）。
    public var isValid: Bool {
        guard let sentenceSuggestion,
              let confidence,
              confidence.isFinite,
              (0 ... 1).contains(confidence)
        else {
            return false
        }
        return !sentenceSuggestion.isEmpty
            && sentenceSuggestion.count <= 30
            && !sentenceSuggestion.contains("\n")
            && !sentenceSuggestion.contains("\r")
            && sentenceSuggestion.unicodeScalars.allSatisfy {
                $0.value > 0x20 && $0.value != 0x7F
            }
    }

    /// 转换为既有展示/应用路径可消费的 result 形态（decision 固定为
    /// sentenceSuggestion；迟到帧不携带重排候选）。
    ///
    /// reveal B-F2（量纲告警）：本转换刻意不走
    /// `SemanticInferenceResult.isValid`——那条门包含 0.60 的云端
    /// 整句置信度下限（`CloudGeneratedSentencePolicy
    /// .minimumConfidence`），而神经臂的 confidence 是约束解码的
    /// raw-softmax 几何均值（量纲完全不同，基线中约半数样本
    /// <0.01），过那道门会被整帧丢弃。迟到帧结构校验用自身的
    /// `isValid`；不得把本转换结果路由回 `gateLocalResult` /
    /// `applyLocalResult`（那会重新引入 0.60 门）。
    public func asInferenceResult() -> SemanticInferenceResult {
        SemanticInferenceResult(
            status: "ok",
            requestID: requestID,
            compositionID: compositionID,
            revision: revision,
            appSessionID: appSessionID,
            rankedCandidate: nil,
            sentenceSuggestion: sentenceSuggestion,
            confidence: confidence,
            decision: .sentenceSuggestion,
            modelArtifactID: modelArtifactID,
            elapsedMilliseconds: elapsedMilliseconds
        )
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case type
        case status
        case requestID = "request_id"
        case compositionID = "composition_id"
        case revision
        case appSessionID = "app_session_id"
        case sentenceSuggestion = "sentence_suggestion"
        case confidence
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

/// LM-003 传感层反馈帧（fire-and-forget，无响应）：把用户对已展示
/// 建议的裁决回传 daemon 决策日志。仅在 daemon hello 通告
/// `sentence-feedback` capability 时发送；畸形帧由 daemon 静默忽略。
public struct DaemonSentenceFeedback: Codable, Sendable {
    public let schemaVersion = 1
    public let type = "sentence_feedback"
    public let requestID: String
    /// adopted / rejected / superseded / expired / ignored
    public let outcome: String

    public init(requestID: String, outcome: String) {
        self.requestID = requestID
        self.outcome = outcome
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case type
        case requestID = "request_id"
        case outcome
    }
}
