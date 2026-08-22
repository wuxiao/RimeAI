import CryptoKit
import Foundation

/// 语音听写模态协议 V2。权威定义见 docs/VOICE_INPUT_DESIGN.md 第 3 节。
/// 输入法是客户端，语音 helper 是服务端。Debug UDS 使用 UTF-8 NDJSON；
/// Release XPC 的每次 Data RPC 承载一条无尾随换行的 JSON 消息。
public enum VoiceDictationConstants {
    public static let protocolVersion = 2
    public static let maximumTextCharacters = 200
    public static let maximumContextCharacters = 600
    public static let minimumDeadlineMilliseconds = 1
    public static let maximumDeadlineMilliseconds = 5_000
    public static let maximumDurationMilliseconds = 60_000
    public static let deltaTimeoutMilliseconds = 2_000
    public static let circuitBreakerLimit = 3
    public static let maximumHotwordCount = 128
    public static let maximumHotwordCharacters = 32
    public static let maximumHotwordUTF8Bytes = 128
    public static let maximumHotwordSetUTF8Bytes = 16_384
    public static let clientID = "fun.wwcn.inputmethod.RimeAI"
    public static let serverID = "fun.wwcn.rimeai.voice-helper"

    public static let clientCapabilities: Set<String> = [
        "dictation",
        "cancel",
        "accept-ack",
    ]
    public static let serverCapabilities: Set<String> = [
        "local_asr",
        "cloud_asr",
        "streaming",
        "polish",
        "hotword_snapshot",
    ]
}

public enum VoiceDictationMode: String, Codable, Sendable {
    case direct
    case polish
}

public enum VoiceNetworkPolicy: String, Codable, Sendable {
    case offline
    case cloudASROnly = "cloud_asr_only"
    case cloudASRAndPolish = "cloud_asr_and_polish"
}

public enum VoiceDictationCancelReason: String, Codable, Sendable {
    case userAbort = "user_abort"
    case sessionSwitch = "session_switch"
    case secureInput = "secure_input"
    case clientTimeout = "client_timeout"
}

public enum VoiceDictationErrorCode: String, Codable, Sendable {
    case micDenied = "mic_denied"
    case micUnavailable = "mic_unavailable"
    case asrEngineError = "asr_engine_error"
    case asrTimeout = "asr_timeout"
    case asrOverload = "asr_overload"
    case polishFailed = "polish_failed"
    case invalidRequest = "invalid_request"
    case incompatibleProtocol = "incompatible_protocol"
    case internalError = "internal_error"
}

enum VoiceTextValidation {
    /// 听写文本必须单行；换行在 delta、final 中都按协议错误处理。
    static func isValidSingleLine(_ text: String) -> Bool {
        !text.contains("\n") && !text.contains("\r")
    }

    /// 协议长度以 Swift `Character`（扩展字素簇）计数；`prefix` 不会
    /// 把 emoji 或组合字符截成无效的 Unicode 片段。
    static func truncatedToMaximumCharacters(_ text: String) -> String {
        guard text.count > VoiceDictationConstants.maximumTextCharacters else {
            return text
        }
        return String(text.prefix(
            VoiceDictationConstants.maximumTextCharacters
        ))
    }
}

/// One immutable, bounded hotword set captured by the input method before a
/// voice request. The digest binds the exact normalized order; neither the
/// phrases nor this low-entropy digest belongs in diagnostics or telemetry.
public struct VoiceHotwordSnapshot: Codable, Equatable, Sendable {
    public let normalizationVersion: Int
    public let phrases: [String]
    public let hotwordSetSHA256: String

    public init(phrases: [String]) throws {
        let canonical = try Self.canonicalized(phrases)
        self.normalizationVersion = 1
        self.phrases = canonical
        self.hotwordSetSHA256 = Self.digest(canonical)
    }

    public static let empty: Self = {
        // The empty array satisfies every invariant by construction.
        try! Self(phrases: [])
    }()

    public var isEmpty: Bool { phrases.isEmpty }

    public var isValid: Bool {
        guard let canonical = try? Self.canonicalized(phrases),
              canonical == phrases,
              normalizationVersion == 1,
              Self.isSHA256(hotwordSetSHA256)
        else {
            return false
        }
        return hotwordSetSHA256 == Self.digest(canonical)
    }

    public func limited(to maximumEntries: Int) throws -> Self {
        guard maximumEntries >= 0 else {
            throw ValidationError.invalidLimit
        }
        return try Self(phrases: Array(phrases.prefix(maximumEntries)))
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case tooManyPhrases
        case invalidPhrase
        case duplicatePhrase
        case aggregateTooLarge
        case invalidLimit
    }

    private static func canonicalized(
        _ phrases: [String]
    ) throws -> [String] {
        guard phrases.count <= VoiceDictationConstants.maximumHotwordCount
        else {
            throw ValidationError.tooManyPhrases
        }
        var seen = Set<String>()
        var totalUTF8Bytes = 0
        var canonical: [String] = []
        canonical.reserveCapacity(phrases.count)
        for phrase in phrases {
            let normalized = phrase
                .precomposedStringWithCompatibilityMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2 ... VoiceDictationConstants.maximumHotwordCharacters)
                    .contains(normalized.count),
                  normalized.utf8.count
                    <= VoiceDictationConstants.maximumHotwordUTF8Bytes,
                  !normalized.unicodeScalars.contains(where: {
                      $0.value < 0x20
                          || (0x7f ... 0x9f).contains($0.value)
                  }),
                  !normalized.contains("/"),
                  !normalized.contains(":"),
                  !normalized.contains("#"),
                  !normalized.contains("@")
            else {
                throw ValidationError.invalidPhrase
            }
            guard seen.insert(normalized).inserted else {
                throw ValidationError.duplicatePhrase
            }
            totalUTF8Bytes += normalized.utf8.count
            guard totalUTF8Bytes
                <= VoiceDictationConstants.maximumHotwordSetUTF8Bytes
            else {
                throw ValidationError.aggregateTooLarge
            }
            canonical.append(normalized)
        }
        return canonical
    }

    private static func digest(_ phrases: [String]) -> String {
        var payload = Data("rimeai.voice-hotwords.v1\0".utf8)
        append(UInt32(phrases.count), to: &payload)
        for phrase in phrases {
            let bytes = Data(phrase.utf8)
            append(UInt32(bytes.count), to: &payload)
            payload.append(bytes)
        }
        return SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
        }
    }

    enum CodingKeys: String, CodingKey {
        case normalizationVersion = "normalization_version"
        case phrases
        case hotwordSetSHA256 = "hotword_set_sha256"
    }
}

// MARK: - 客户端 → 服务端

public struct VoiceHelloRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let type: String
    public let clientID: String
    public let capabilities: [String]

    public init(
        protocolVersion: Int = VoiceDictationConstants.protocolVersion,
        clientID: String = VoiceDictationConstants.clientID,
        capabilities: [String] = Array(
            VoiceDictationConstants.clientCapabilities
        ).sorted()
    ) {
        self.protocolVersion = protocolVersion
        self.type = "voice_hello"
        self.clientID = clientID
        self.capabilities = capabilities
    }

    /// 客户端只能声明 V2 已知能力，且必须具备听写主能力。
    public var isValid: Bool {
        let advertisedCapabilities = Set(capabilities)
        return protocolVersion == VoiceDictationConstants.protocolVersion
            && type == "voice_hello"
            && clientID == VoiceDictationConstants.clientID
            && advertisedCapabilities.contains("dictation")
            && advertisedCapabilities.isSubset(
                of: VoiceDictationConstants.clientCapabilities
            )
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case type
        case clientID = "client_id"
        case capabilities
    }
}

public struct VoiceDictationStart: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let type: String
    public let requestID: String
    public let compositionID: String
    public let appSessionID: String
    public let bundleID: String
    public let mode: VoiceDictationMode
    public let deadlineMilliseconds: Int
    public let maximumDurationMilliseconds: Int
    public let hotwordSnapshot: VoiceHotwordSnapshot?

    public init(
        protocolVersion: Int = VoiceDictationConstants.protocolVersion,
        requestID: String,
        compositionID: UUID,
        appSessionID: String,
        bundleID: String,
        mode: VoiceDictationMode,
        deadlineMilliseconds: Int,
        maximumDurationMilliseconds: Int = VoiceDictationConstants
            .maximumDurationMilliseconds,
        hotwordSnapshot: VoiceHotwordSnapshot? = .empty
    ) {
        self.protocolVersion = protocolVersion
        self.type = "dictation_start"
        self.requestID = requestID
        self.compositionID = compositionID.uuidString
        self.appSessionID = appSessionID
        self.bundleID = bundleID
        self.mode = mode
        self.deadlineMilliseconds = deadlineMilliseconds
        self.maximumDurationMilliseconds = maximumDurationMilliseconds
        self.hotwordSnapshot = hotwordSnapshot
    }

    public var isValid: Bool {
        protocolVersion == VoiceDictationConstants.protocolVersion
            && type == "dictation_start"
            && !requestID.isEmpty
            && requestID.utf8.count <= 128
            && UUID(uuidString: compositionID) != nil
            && !appSessionID.isEmpty
            && appSessionID.utf8.count <= 256
            && !bundleID.isEmpty
            && bundleID.utf8.count <= 256
            && (VoiceDictationConstants.minimumDeadlineMilliseconds
                ... VoiceDictationConstants.maximumDeadlineMilliseconds)
                .contains(deadlineMilliseconds)
            && maximumDurationMilliseconds > 0
            && maximumDurationMilliseconds
                <= VoiceDictationConstants.maximumDurationMilliseconds
            && (hotwordSnapshot?.isValid ?? true)
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case type
        case requestID = "request_id"
        case compositionID = "composition_id"
        case appSessionID = "app_session_id"
        case bundleID = "bundle_id"
        case mode
        case deadlineMilliseconds = "deadline_ms"
        case maximumDurationMilliseconds = "max_duration_ms"
        case hotwordSnapshot = "hotword_snapshot"
    }
}

/// 松开按住说话快捷键后，客户端停止提交新音频并请求当前会话 final。
public struct VoiceDictationStop: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let type: String
    public let requestID: String

    public init(
        protocolVersion: Int = VoiceDictationConstants.protocolVersion,
        requestID: String
    ) {
        self.protocolVersion = protocolVersion
        self.type = "dictation_stop"
        self.requestID = requestID
    }

    public var isValid: Bool {
        protocolVersion == VoiceDictationConstants.protocolVersion
            && type == "dictation_stop"
            && !requestID.isEmpty
            && requestID.utf8.count <= 128
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case type
        case requestID = "request_id"
    }
}

public struct VoiceDictationCancel: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let type: String
    public let requestID: String
    public let reason: VoiceDictationCancelReason

    public init(
        protocolVersion: Int = VoiceDictationConstants.protocolVersion,
        requestID: String,
        reason: VoiceDictationCancelReason
    ) {
        self.protocolVersion = protocolVersion
        self.type = "dictation_cancel"
        self.requestID = requestID
        self.reason = reason
    }

    public var isValid: Bool {
        protocolVersion == VoiceDictationConstants.protocolVersion
            && type == "dictation_cancel"
            && !requestID.isEmpty
            && requestID.utf8.count <= 128
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case type
        case requestID = "request_id"
        case reason
    }
}

public struct VoiceDictationAccept: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let type: String
    public let requestID: String
    public let acceptedTextSHA256: String

    public init(
        protocolVersion: Int = VoiceDictationConstants.protocolVersion,
        requestID: String,
        acceptedTextSHA256: String
    ) {
        self.protocolVersion = protocolVersion
        self.type = "dictation_accept"
        self.requestID = requestID
        self.acceptedTextSHA256 = acceptedTextSHA256
    }

    public var isValid: Bool {
        protocolVersion == VoiceDictationConstants.protocolVersion
            && type == "dictation_accept"
            && !requestID.isEmpty
            && requestID.utf8.count <= 128
            && Self.isAcceptHash(acceptedTextSHA256)
    }

    /// 回执哈希固定为 "sha256-" 加 16 个小写十六进制字符。
    public static func isAcceptHash(_ value: String) -> Bool {
        guard value.count == "sha256-".count + 16,
              value.hasPrefix("sha256-")
        else {
            return false
        }
        let hex = value.dropFirst("sha256-".count)
        return hex.allSatisfy { character in
            character.isHexDigit && !character.isUppercase
        }
    }

    /// 计算上屏文本的回执哈希。
    public static func acceptHash(for text: String) -> String {
        let digest = SHA256Hex.prefix16(of: Data(text.utf8))
        return "sha256-\(digest)"
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case type
        case requestID = "request_id"
        case acceptedTextSHA256 = "accepted_text_sha256"
    }
}

enum SHA256Hex {
    static func prefix16(of data: Data) -> String {
        SHA256.hash(data: data)
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - 服务端 → 客户端

public struct VoiceReadyResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let type: String
    public let serverID: String
    public let capabilities: [String]
    public let networkPolicy: VoiceNetworkPolicy
    public let asrEngineID: String
    public let maximumHotwords: Int

    public init(
        protocolVersion: Int = VoiceDictationConstants.protocolVersion,
        serverID: String = VoiceDictationConstants.serverID,
        capabilities: [String],
        networkPolicy: VoiceNetworkPolicy,
        asrEngineID: String,
        maximumHotwords: Int = 0
    ) {
        self.protocolVersion = protocolVersion
        self.type = "voice_ready"
        self.serverID = serverID
        self.capabilities = capabilities
        self.networkPolicy = networkPolicy
        self.asrEngineID = asrEngineID
        self.maximumHotwords = maximumHotwords
    }

    /// mode 为 polish 时握手能力必须包含 polish。
    public func supports(_ mode: VoiceDictationMode) -> Bool {
        let advertised = Set(capabilities)
        let hasASR = advertised.contains("local_asr")
            || advertised.contains("cloud_asr")
        switch mode {
        case .direct:
            return hasASR
        case .polish:
            return hasASR && advertised.contains("polish")
        }
    }

    public var isCompatible: Bool {
        let advertised = Set(capabilities)
        let hasLocalASR = advertised.contains("local_asr")
        let hasCloudASR = advertised.contains("cloud_asr")
        let supportsHotwordSnapshot = advertised.contains(
            "hotword_snapshot"
        )
        let networkPolicyMatches: Bool
        switch networkPolicy {
        case .offline:
            networkPolicyMatches = hasLocalASR && !hasCloudASR
        case .cloudASROnly:
            networkPolicyMatches = hasCloudASR
                && !hasLocalASR
                && !advertised.contains("polish")
        case .cloudASRAndPolish:
            networkPolicyMatches = (hasLocalASR || hasCloudASR)
                && advertised.contains("polish")
        }
        return protocolVersion == VoiceDictationConstants.protocolVersion
            && type == "voice_ready"
            && serverID == VoiceDictationConstants.serverID
            && !capabilities.isEmpty
            && advertised.count == capabilities.count
            && advertised.isSubset(of: VoiceDictationConstants.serverCapabilities)
            && (hasLocalASR || hasCloudASR)
            && networkPolicyMatches
            && !asrEngineID.isEmpty
            && asrEngineID.utf8.count <= 128
            && (supportsHotwordSnapshot
                ? (1 ... VoiceDictationConstants.maximumHotwordCount)
                    .contains(maximumHotwords)
                : maximumHotwords == 0)
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case type
        case serverID = "server_id"
        case capabilities
        case networkPolicy = "network_policy"
        case asrEngineID = "asr_engine_id"
        case maximumHotwords = "maximum_hotwords"
    }
}

public struct VoiceDictationDelta: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let type: String
    public let requestID: String
    public let sequence: Int
    public let stableText: String
    public let partialText: String
    public let confidence: Double
    public let elapsedMilliseconds: Double

    public init(
        protocolVersion: Int = VoiceDictationConstants.protocolVersion,
        requestID: String,
        sequence: Int,
        stableText: String,
        partialText: String = "",
        confidence: Double,
        elapsedMilliseconds: Double
    ) {
        self.protocolVersion = protocolVersion
        self.type = "dictation_delta"
        self.requestID = requestID
        self.sequence = sequence
        self.stableText = stableText
        self.partialText = partialText
        self.confidence = confidence
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    public var isValid: Bool {
        protocolVersion == VoiceDictationConstants.protocolVersion
            && type == "dictation_delta"
            && !requestID.isEmpty
            && requestID.utf8.count <= 128
            && sequence >= 1
            && confidence.isFinite
            && (0 ... 1).contains(confidence)
            && elapsedMilliseconds.isFinite
            && elapsedMilliseconds >= 0
            && VoiceTextValidation.isValidSingleLine(stableText)
            && VoiceTextValidation.isValidSingleLine(partialText)
            && (!stableText.isEmpty || !partialText.isEmpty)
            && (stableText.count + partialText.count)
                <= VoiceDictationConstants.maximumTextCharacters
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case type
        case requestID = "request_id"
        case sequence
        case stableText = "stable_text"
        case partialText = "partial_text"
        case confidence
        case elapsedMilliseconds = "elapsed_ms"
    }
}

public struct VoiceDictationFinal: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let type: String
    public let requestID: String
    public let finalText: String
    public let confidence: Double
    public let asrEngineID: String
    public let polishApplied: Bool
    public let elapsedMilliseconds: Double

    public init(
        protocolVersion: Int = VoiceDictationConstants.protocolVersion,
        requestID: String,
        finalText: String,
        confidence: Double,
        asrEngineID: String,
        polishApplied: Bool,
        elapsedMilliseconds: Double
    ) {
        self.protocolVersion = protocolVersion
        self.type = "dictation_final"
        self.requestID = requestID
        self.finalText = finalText
        self.confidence = confidence
        self.asrEngineID = asrEngineID
        self.polishApplied = polishApplied
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    public var isValid: Bool {
        protocolVersion == VoiceDictationConstants.protocolVersion
            && type == "dictation_final"
            && !requestID.isEmpty
            && requestID.utf8.count <= 128
            && !finalText.isEmpty
            && finalText.count
                <= VoiceDictationConstants.maximumTextCharacters
            && VoiceTextValidation.isValidSingleLine(finalText)
            && confidence.isFinite
            && (0 ... 1).contains(confidence)
            && !asrEngineID.isEmpty
            && asrEngineID.utf8.count <= 128
            && elapsedMilliseconds.isFinite
            && elapsedMilliseconds >= 0
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case type
        case requestID = "request_id"
        case finalText = "final_text"
        case confidence
        case asrEngineID = "asr_engine_id"
        case polishApplied = "polish_applied"
        case elapsedMilliseconds = "elapsed_ms"
    }
}

public struct VoiceDictationError: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let type: String
    public let requestID: String
    public let errorCode: VoiceDictationErrorCode
    public let retryable: Bool

    public init(
        protocolVersion: Int = VoiceDictationConstants.protocolVersion,
        requestID: String,
        errorCode: VoiceDictationErrorCode,
        retryable: Bool
    ) {
        self.protocolVersion = protocolVersion
        self.type = "dictation_error"
        self.requestID = requestID
        self.errorCode = errorCode
        self.retryable = retryable
    }

    public var isValid: Bool {
        protocolVersion == VoiceDictationConstants.protocolVersion
            && type == "dictation_error"
            && !requestID.isEmpty
            && requestID.utf8.count <= 128
    }

    /// 润色失败不得作为独立错误：一律降级为 direct final。
    public var isProtocolViolation: Bool {
        errorCode == .polishFailed
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case type
        case requestID = "request_id"
        case errorCode = "error_code"
        case retryable
    }
}
