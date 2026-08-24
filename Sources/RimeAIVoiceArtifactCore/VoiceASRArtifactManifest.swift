import CryptoKit
import Darwin
import Foundation

public struct VoiceASRArtifactVerificationLimits: Equatable, Sendable {
    public static let production = Self(
        maximumManifestBytes: 1_048_576,
        maximumFileCount: 512,
        maximumTotalBytes: 2_147_483_648,
        maximumJSONDepth: 32,
        maximumJSONNodes: 32_768,
        maximumFilesystemDepth: 32,
        maximumFilesystemEntries: 16_384
    )

    public let maximumManifestBytes: Int
    public let maximumFileCount: Int
    public let maximumTotalBytes: Int64
    public let maximumJSONDepth: Int
    public let maximumJSONNodes: Int
    public let maximumFilesystemDepth: Int
    public let maximumFilesystemEntries: Int

    public init(
        maximumManifestBytes: Int,
        maximumFileCount: Int,
        maximumTotalBytes: Int64,
        maximumJSONDepth: Int = 32,
        maximumJSONNodes: Int = 32_768,
        maximumFilesystemDepth: Int = 32,
        maximumFilesystemEntries: Int = 16_384
    ) {
        self.maximumManifestBytes = maximumManifestBytes
        self.maximumFileCount = maximumFileCount
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumJSONDepth = maximumJSONDepth
        self.maximumJSONNodes = maximumJSONNodes
        self.maximumFilesystemDepth = maximumFilesystemDepth
        self.maximumFilesystemEntries = maximumFilesystemEntries
    }
}

/// A path-safe, stable identifier used as an immutable release-directory name.
public struct VoiceASRArtifactID:
    RawRepresentable,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 128,
              rawValue != ".",
              rawValue != "..",
              let first = rawValue.utf8.first,
              Self.isASCIIAlphaNumeric(first),
              rawValue.utf8.dropFirst().allSatisfy(Self.isAllowed)
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
    }

    private static func isAllowed(_ byte: UInt8) -> Bool {
        isASCIIAlphaNumeric(byte)
            || byte == 0x2D
            || byte == 0x2E
            || byte == 0x5F
    }
}

public enum VoiceASRArtifactError: Error, Equatable, Sendable {
    case invalidJSON
    case duplicateJSONKey(String)
    case unexpectedKeys(context: String, keys: [String])
    case missingKeys(context: String, keys: [String])
    case invalidVerificationLimits
    case manifestTooLarge(maximumBytes: Int, actualBytes: Int)
    case unsupportedSchema(Int)
    case unsupportedArtifactType(String)
    case productManagedRequired
    case invalidField(String)
    case invalidInventoryPath(String)
    case duplicateInventoryPath(String)
    case inventoryMustBeSorted
    case inventoryFileLimitExceeded(maximum: Int, actual: Int)
    case inventoryByteLimitExceeded(maximum: Int64, actual: Int64)
    case JSONResourceLimitExceeded
    case filesystemDepthLimitExceeded(maximum: Int)
    case filesystemEntryLimitExceeded(maximum: Int)
    case contentDigestMismatch(expected: String, actual: String)
    case artifactRootMustBeDirectory
    case insecureFilesystemEntry(String)
    case unsupportedFilesystemEntry(String)
    case missingFile(String)
    case unexpectedFile(String)
    case fileSizeMismatch(path: String, expected: Int64, actual: Int64)
    case fileHashMismatch(path: String, expected: String, actual: String)
    case ioFailure(path: String, errno: Int32)
}

private indirect enum VoiceASRCanonicalJSON {
    case string(String)
    case integer(Int64)
    case boolean(Bool)
    case array([Self])
    case object([String: Self])

    func encoded() -> String {
        switch self {
        case let .string(value):
            return Self.quote(value)
        case let .integer(value):
            return String(value)
        case let .boolean(value):
            return value ? "true" : "false"
        case let .array(values):
            return "[" + values.map { $0.encoded() }.joined(separator: ",") + "]"
        case let .object(values):
            return "{" + values.keys.sorted().map { key in
                Self.quote(key) + ":" + values[key]!.encoded()
            }.joined(separator: ",") + "}"
        }
    }

    private static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08:
                result += "\\b"
            case 0x09:
                result += "\\t"
            case 0x0A:
                result += "\\n"
            case 0x0C:
                result += "\\f"
            case 0x0D:
                result += "\\r"
            case 0x22:
                result += "\\\""
            case 0x5C:
                result += "\\\\"
            case 0x00 ... 0x1F:
                result += String(format: "\\u%04x", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }
}

private struct VoiceASRStrictJSONScanner {
    private let bytes: [UInt8]
    private let maximumDepth: Int
    private let maximumNodes: Int
    private var index = 0
    private var nodes = 0

    init(data: Data, maximumDepth: Int, maximumNodes: Int) {
        bytes = Array(data)
        self.maximumDepth = maximumDepth
        self.maximumNodes = maximumNodes
    }

    mutating func validate() throws {
        skipWhitespace()
        try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else {
            throw VoiceASRArtifactError.invalidJSON
        }
    }

    private mutating func parseValue(depth: Int) throws {
        guard index < bytes.count,
              depth <= maximumDepth,
              nodes < maximumNodes
        else {
            if index < bytes.count {
                throw VoiceASRArtifactError.JSONResourceLimitExceeded
            }
            throw VoiceASRArtifactError.invalidJSON
        }
        nodes += 1
        switch bytes[index] {
        case 0x7B: // {
            try parseObject(depth: depth)
        case 0x5B: // [
            try parseArray(depth: depth)
        case 0x22: // "
            _ = try parseString()
        case 0x74: // true
            try parseLiteral([0x74, 0x72, 0x75, 0x65])
        case 0x66: // false
            try parseLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
        case 0x6E: // null
            try parseLiteral([0x6E, 0x75, 0x6C, 0x6C])
        case 0x2D, 0x30 ... 0x39:
            try parseNumber()
        default:
            throw VoiceASRArtifactError.invalidJSON
        }
    }

    private mutating func parseObject(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consume(0x7D) { // }
            return
        }
        var keys: Set<String> = []
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw VoiceASRArtifactError.invalidJSON
            }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw VoiceASRArtifactError.duplicateJSONKey(key)
            }
            skipWhitespace()
            guard consume(0x3A) else { // :
                throw VoiceASRArtifactError.invalidJSON
            }
            skipWhitespace()
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if consume(0x7D) {
                return
            }
            guard consume(0x2C) else { // ,
                throw VoiceASRArtifactError.invalidJSON
            }
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { // ]
            return
        }
        while true {
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if consume(0x5D) {
                return
            }
            guard consume(0x2C) else {
                throw VoiceASRArtifactError.invalidJSON
            }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                let encoded = Data(bytes[start ..< index])
                do {
                    return try JSONDecoder().decode(String.self, from: encoded)
                } catch {
                    throw VoiceASRArtifactError.invalidJSON
                }
            }
            if byte < 0x20 {
                throw VoiceASRArtifactError.invalidJSON
            }
            if byte == 0x5C { // backslash
                index += 1
                guard index < bytes.count else {
                    throw VoiceASRArtifactError.invalidJSON
                }
                if bytes[index] == 0x75 { // u
                    guard index + 4 < bytes.count else {
                        throw VoiceASRArtifactError.invalidJSON
                    }
                    for offset in 1 ... 4 where !Self.isHex(bytes[index + offset]) {
                        throw VoiceASRArtifactError.invalidJSON
                    }
                    index += 5
                    continue
                }
                guard [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74]
                    .contains(bytes[index])
                else {
                    throw VoiceASRArtifactError.invalidJSON
                }
            }
            index += 1
        }
        throw VoiceASRArtifactError.invalidJSON
    }

    private mutating func parseLiteral(_ literal: [UInt8]) throws {
        guard index + literal.count <= bytes.count,
              Array(bytes[index ..< index + literal.count]) == literal
        else {
            throw VoiceASRArtifactError.invalidJSON
        }
        index += literal.count
    }

    private mutating func parseNumber() throws {
        if consume(0x2D), index == bytes.count {
            throw VoiceASRArtifactError.invalidJSON
        }
        guard index < bytes.count else {
            throw VoiceASRArtifactError.invalidJSON
        }
        if consume(0x30) {
            if index < bytes.count, Self.isDigit(bytes[index]) {
                throw VoiceASRArtifactError.invalidJSON
            }
        } else {
            guard index < bytes.count,
                  bytes[index] >= 0x31,
                  bytes[index] <= 0x39
            else {
                throw VoiceASRArtifactError.invalidJSON
            }
            while index < bytes.count, Self.isDigit(bytes[index]) {
                index += 1
            }
        }
        if consume(0x2E) { // .
            guard index < bytes.count, Self.isDigit(bytes[index]) else {
                throw VoiceASRArtifactError.invalidJSON
            }
            while index < bytes.count, Self.isDigit(bytes[index]) {
                index += 1
            }
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
                index += 1
            }
            guard index < bytes.count, Self.isDigit(bytes[index]) else {
                throw VoiceASRArtifactError.invalidJSON
            }
            while index < bytes.count, Self.isDigit(bytes[index]) {
                index += 1
            }
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else {
            return false
        }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
              bytes[index] == 0x20
                  || bytes[index] == 0x09
                  || bytes[index] == 0x0A
                  || bytes[index] == 0x0D
        {
            index += 1
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        isDigit(byte)
            || (byte >= 0x41 && byte <= 0x46)
            || (byte >= 0x61 && byte <= 0x66)
    }
}

private struct VoiceASRJSONKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private struct VoiceASRStrictJSONObject {
    private let container: KeyedDecodingContainer<VoiceASRJSONKey>

    init(
        _ decoder: Decoder,
        context: String,
        expectedKeys: Set<String>
    ) throws {
        container = try decoder.container(keyedBy: VoiceASRJSONKey.self)
        let actualKeys = Set(container.allKeys.map(\.stringValue))
        let unexpected = actualKeys.subtracting(expectedKeys).sorted()
        guard unexpected.isEmpty else {
            throw VoiceASRArtifactError.unexpectedKeys(
                context: context,
                keys: unexpected
            )
        }
        let missing = expectedKeys.subtracting(actualKeys).sorted()
        guard missing.isEmpty else {
            throw VoiceASRArtifactError.missingKeys(
                context: context,
                keys: missing
            )
        }
    }

    func decode<Value: Decodable>(
        _ type: Value.Type,
        forKey key: String
    ) throws -> Value {
        try container.decode(type, forKey: VoiceASRJSONKey(stringValue: key)!)
    }
}

/// Versioned metadata for a local voice-ASR model pack managed by RimeAI.
///
/// This contract proves deterministic contents and compatibility metadata. It
/// deliberately does not authenticate who produced the manifest; release
/// signing and provenance verification belong to a separate layer.
public struct VoiceASRArtifactManifest: Equatable, Sendable {
    public static let supportedSchemaVersion = 2
    public static let supportedArtifactType = "rimeai.voice-asr-model"
    public static let manifestFileName = "manifest.json"

    public enum AssetManagement: String, Decodable, Equatable, Sendable {
        case productManaged = "product-managed"
        case systemManaged = "system-managed"
    }

    public struct Adapter: Decodable, Equatable, Sendable {
        public let id: String
        public let version: String
        public let abiVersion: Int

        public init(from decoder: Decoder) throws {
            let object = try VoiceASRStrictJSONObject(
                decoder,
                context: "adapter",
                expectedKeys: ["id", "version", "abi_version"]
            )
            id = try object.decode(String.self, forKey: "id")
            version = try object.decode(String.self, forKey: "version")
            abiVersion = try object.decode(Int.self, forKey: "abi_version")
        }
    }

    public enum ModelFormat: String, Decodable, Equatable, Sendable {
        case onnx
        case coreML = "coreml"
    }

    public enum ModelQuantization: String, Decodable, Equatable, Sendable {
        case fp32
        case fp16
        case int8
        case mixed
    }

    public struct Model: Decodable, Equatable, Sendable {
        public let id: String
        public let revision: String
        public let format: ModelFormat
        public let quantization: ModelQuantization

        public init(from decoder: Decoder) throws {
            let object = try VoiceASRStrictJSONObject(
                decoder,
                context: "model",
                expectedKeys: ["id", "revision", "format", "quantization"]
            )
            id = try object.decode(String.self, forKey: "id")
            revision = try object.decode(String.self, forKey: "revision")
            format = try object.decode(ModelFormat.self, forKey: "format")
            quantization = try object.decode(
                ModelQuantization.self,
                forKey: "quantization"
            )
        }
    }

    public enum TargetOS: String, Decodable, Equatable, Sendable {
        case macOS = "macos"
    }

    public enum TargetArchitecture: String, Decodable, Equatable, Sendable {
        case arm64
    }

    public struct Target: Decodable, Equatable, Sendable {
        public let os: TargetOS
        public let architecture: TargetArchitecture
        public let minimumOSVersion: String

        public init(from decoder: Decoder) throws {
            let object = try VoiceASRStrictJSONObject(
                decoder,
                context: "target",
                expectedKeys: ["os", "architecture", "minimum_os_version"]
            )
            os = try object.decode(TargetOS.self, forKey: "os")
            architecture = try object.decode(
                TargetArchitecture.self,
                forKey: "architecture"
            )
            minimumOSVersion = try object.decode(
                String.self,
                forKey: "minimum_os_version"
            )
        }
    }

    public enum AudioSampleFormat: String, Decodable, Equatable, Sendable {
        case float32LittleEndian = "float32le"
    }

    public struct Audio: Decodable, Equatable, Sendable {
        public let sampleRateHertz: Int
        public let channelCount: Int
        public let sampleFormat: AudioSampleFormat
        public let frameDurationMilliseconds: Int

        public init(from decoder: Decoder) throws {
            let object = try VoiceASRStrictJSONObject(
                decoder,
                context: "audio",
                expectedKeys: [
                    "sample_rate_hz",
                    "channel_count",
                    "sample_format",
                    "frame_duration_ms",
                ]
            )
            sampleRateHertz = try object.decode(
                Int.self,
                forKey: "sample_rate_hz"
            )
            channelCount = try object.decode(
                Int.self,
                forKey: "channel_count"
            )
            sampleFormat = try object.decode(
                AudioSampleFormat.self,
                forKey: "sample_format"
            )
            frameDurationMilliseconds = try object.decode(
                Int.self,
                forKey: "frame_duration_ms"
            )
        }
    }

    /// Schema-v1 runtime entrypoints for the first product-managed streaming
    /// adapter. Paths are data-only artifact-relative paths; the runtime binary
    /// remains pinned and linked by the helper build rather than downloaded by
    /// the model pack.
    public struct Runtime: Decodable, Equatable, Sendable {
        public enum Kind: String, Decodable, Equatable, Sendable {
            case sherpaOnnxOnlineTransducer =
                "sherpa-onnx-online-transducer"
        }

        public enum ModelingUnit: String, Decodable, Equatable, Sendable {
            case cjkCharacterAndBPE = "cjkchar+bpe"
        }

        public enum ModelType: String, Decodable, Equatable, Sendable {
            case zipformer
        }

        public enum Provider: String, Decodable, Equatable, Sendable {
            case cpu
        }

        public enum DecodingMethod: String, Decodable, Equatable, Sendable {
            case modifiedBeamSearch = "modified_beam_search"
        }

        public struct Endpoint: Decodable, Equatable, Sendable {
            public let enabled: Bool
            public let rule1MinimumTrailingSilenceMilliseconds: Int
            public let rule2MinimumTrailingSilenceMilliseconds: Int
            public let rule3MinimumUtteranceMilliseconds: Int

            public init(from decoder: Decoder) throws {
                let object = try VoiceASRStrictJSONObject(
                    decoder,
                    context: "runtime.endpoint",
                    expectedKeys: [
                        "enabled",
                        "rule1_min_trailing_silence_ms",
                        "rule2_min_trailing_silence_ms",
                        "rule3_min_utterance_ms",
                    ]
                )
                enabled = try object.decode(Bool.self, forKey: "enabled")
                rule1MinimumTrailingSilenceMilliseconds = try object.decode(
                    Int.self,
                    forKey: "rule1_min_trailing_silence_ms"
                )
                rule2MinimumTrailingSilenceMilliseconds = try object.decode(
                    Int.self,
                    forKey: "rule2_min_trailing_silence_ms"
                )
                rule3MinimumUtteranceMilliseconds = try object.decode(
                    Int.self,
                    forKey: "rule3_min_utterance_ms"
                )
            }
        }

        public let kind: Kind
        public let encoderPath: String
        public let decoderPath: String
        public let joinerPath: String
        public let tokensPath: String
        public let bpeVocabularyPath: String
        public let modelingUnit: ModelingUnit
        public let modelType: ModelType
        public let featureDimension: Int
        public let provider: Provider
        public let numberOfThreads: Int
        public let decodingMethod: DecodingMethod
        public let maximumActivePaths: Int
        public let endpoint: Endpoint
        public let hotwordProbePhrase: String
        public let hotwordsScoreMilli: Int
        public let blankPenaltyMilli: Int

        public init(from decoder: Decoder) throws {
            let object = try VoiceASRStrictJSONObject(
                decoder,
                context: "runtime",
                expectedKeys: [
                    "kind",
                    "encoder_path",
                    "decoder_path",
                    "joiner_path",
                    "tokens_path",
                    "bpe_vocab_path",
                    "modeling_unit",
                    "model_type",
                    "feature_dimension",
                    "provider",
                    "num_threads",
                    "decoding_method",
                    "max_active_paths",
                    "endpoint",
                    "hotword_probe_phrase",
                    "hotwords_score_milli",
                    "blank_penalty_milli",
                ]
            )
            kind = try object.decode(Kind.self, forKey: "kind")
            encoderPath = try object.decode(
                String.self,
                forKey: "encoder_path"
            )
            decoderPath = try object.decode(
                String.self,
                forKey: "decoder_path"
            )
            joinerPath = try object.decode(
                String.self,
                forKey: "joiner_path"
            )
            tokensPath = try object.decode(
                String.self,
                forKey: "tokens_path"
            )
            bpeVocabularyPath = try object.decode(
                String.self,
                forKey: "bpe_vocab_path"
            )
            modelingUnit = try object.decode(
                ModelingUnit.self,
                forKey: "modeling_unit"
            )
            modelType = try object.decode(ModelType.self, forKey: "model_type")
            featureDimension = try object.decode(
                Int.self,
                forKey: "feature_dimension"
            )
            provider = try object.decode(Provider.self, forKey: "provider")
            numberOfThreads = try object.decode(
                Int.self,
                forKey: "num_threads"
            )
            decodingMethod = try object.decode(
                DecodingMethod.self,
                forKey: "decoding_method"
            )
            maximumActivePaths = try object.decode(
                Int.self,
                forKey: "max_active_paths"
            )
            endpoint = try object.decode(Endpoint.self, forKey: "endpoint")
            hotwordProbePhrase = try object.decode(
                String.self,
                forKey: "hotword_probe_phrase"
            )
            hotwordsScoreMilli = try object.decode(
                Int.self,
                forKey: "hotwords_score_milli"
            )
            blankPenaltyMilli = try object.decode(
                Int.self,
                forKey: "blank_penalty_milli"
            )
        }
    }

    public enum NetworkPolicy: String, Decodable, Equatable, Sendable {
        case offline
    }

    public enum HotwordMode: String, Decodable, Equatable, Sendable {
        case unsupported
        case boundedPhraseList = "bounded-phrase-list"
    }

    public struct Capabilities: Decodable, Equatable, Sendable {
        public let streaming: Bool
        public let partialResults: Bool
        public let endpointDetection: Bool
        public let hotwordMode: HotwordMode
        public let maximumHotwords: Int
        public let maximumAlternatives: Int

        public init(from decoder: Decoder) throws {
            let object = try VoiceASRStrictJSONObject(
                decoder,
                context: "capabilities",
                expectedKeys: [
                    "streaming",
                    "partial_results",
                    "endpoint_detection",
                    "hotword_mode",
                    "maximum_hotwords",
                    "maximum_alternatives",
                ]
            )
            streaming = try object.decode(Bool.self, forKey: "streaming")
            partialResults = try object.decode(
                Bool.self,
                forKey: "partial_results"
            )
            endpointDetection = try object.decode(
                Bool.self,
                forKey: "endpoint_detection"
            )
            hotwordMode = try object.decode(
                HotwordMode.self,
                forKey: "hotword_mode"
            )
            maximumHotwords = try object.decode(
                Int.self,
                forKey: "maximum_hotwords"
            )
            maximumAlternatives = try object.decode(
                Int.self,
                forKey: "maximum_alternatives"
            )
        }
    }

    public struct License: Decodable, Equatable, Sendable {
        public let spdxID: String
        public let licensePath: String
        public let noticePath: String
        public let sourceURL: String

        public init(from decoder: Decoder) throws {
            let object = try VoiceASRStrictJSONObject(
                decoder,
                context: "license",
                expectedKeys: [
                    "spdx_id",
                    "license_path",
                    "notice_path",
                    "source_url",
                ]
            )
            spdxID = try object.decode(String.self, forKey: "spdx_id")
            licensePath = try object.decode(
                String.self,
                forKey: "license_path"
            )
            noticePath = try object.decode(
                String.self,
                forKey: "notice_path"
            )
            sourceURL = try object.decode(String.self, forKey: "source_url")
        }
    }

    public struct InventoryEntry: Decodable, Equatable, Sendable {
        public let path: String
        public let bytes: Int64
        public let sha256: String

        public init(from decoder: Decoder) throws {
            let object = try VoiceASRStrictJSONObject(
                decoder,
                context: "inventory entry",
                expectedKeys: ["path", "bytes", "sha256"]
            )
            path = try object.decode(String.self, forKey: "path")
            bytes = try object.decode(Int64.self, forKey: "bytes")
            sha256 = try object.decode(String.self, forKey: "sha256")
        }
    }

    private struct Wire: Decodable {
        let schemaVersion: Int
        let artifactType: String
        let assetManagement: AssetManagement
        let artifactID: VoiceASRArtifactID
        let adapter: Adapter
        let model: Model
        let target: Target
        let audio: Audio
        let runtime: Runtime
        let networkPolicy: NetworkPolicy
        let locales: [String]
        let capabilities: Capabilities
        let license: License
        let inventory: [InventoryEntry]
        let contentSHA256: String

        init(from decoder: Decoder) throws {
            let object = try VoiceASRStrictJSONObject(
                decoder,
                context: "manifest",
                expectedKeys: [
                    "schema_version",
                    "artifact_type",
                    "asset_management",
                    "artifact_id",
                    "adapter",
                    "model",
                    "target",
                    "audio",
                    "runtime",
                    "network_policy",
                    "locales",
                    "capabilities",
                    "license",
                    "inventory",
                    "content_sha256",
                ]
            )
            schemaVersion = try object.decode(
                Int.self,
                forKey: "schema_version"
            )
            artifactType = try object.decode(
                String.self,
                forKey: "artifact_type"
            )
            assetManagement = try object.decode(
                AssetManagement.self,
                forKey: "asset_management"
            )
            let artifactIDString = try object.decode(
                String.self,
                forKey: "artifact_id"
            )
            guard let decodedArtifactID = VoiceASRArtifactID(
                rawValue: artifactIDString
            ) else {
                throw VoiceASRArtifactError.invalidJSON
            }
            artifactID = decodedArtifactID
            adapter = try object.decode(Adapter.self, forKey: "adapter")
            model = try object.decode(Model.self, forKey: "model")
            target = try object.decode(Target.self, forKey: "target")
            audio = try object.decode(Audio.self, forKey: "audio")
            runtime = try object.decode(Runtime.self, forKey: "runtime")
            networkPolicy = try object.decode(
                NetworkPolicy.self,
                forKey: "network_policy"
            )
            locales = try object.decode([String].self, forKey: "locales")
            capabilities = try object.decode(
                Capabilities.self,
                forKey: "capabilities"
            )
            license = try object.decode(License.self, forKey: "license")
            inventory = try object.decode(
                [InventoryEntry].self,
                forKey: "inventory"
            )
            contentSHA256 = try object.decode(
                String.self,
                forKey: "content_sha256"
            )
        }
    }

    public let schemaVersion: Int
    public let artifactType: String
    public let assetManagement: AssetManagement
    public let artifactID: VoiceASRArtifactID
    public let adapter: Adapter
    public let model: Model
    public let target: Target
    public let audio: Audio
    public let runtime: Runtime
    public let networkPolicy: NetworkPolicy
    public let locales: [String]
    public let capabilities: Capabilities
    public let license: License
    public let inventory: [InventoryEntry]
    public let contentSHA256: String

    private init(wire: Wire) {
        schemaVersion = wire.schemaVersion
        artifactType = wire.artifactType
        assetManagement = wire.assetManagement
        artifactID = wire.artifactID
        adapter = wire.adapter
        model = wire.model
        target = wire.target
        audio = wire.audio
        runtime = wire.runtime
        networkPolicy = wire.networkPolicy
        locales = wire.locales
        capabilities = wire.capabilities
        license = wire.license
        inventory = wire.inventory
        contentSHA256 = wire.contentSHA256
    }

    public static func decodeStrict(
        _ data: Data,
        limits: VoiceASRArtifactVerificationLimits = .production
    ) throws -> Self {
        try decodeStrict(data, limits: limits, verifyContentDigest: true)
    }

    @_spi(RimeAIInternal)
    public static func decodeStrict(
        _ data: Data,
        limits: VoiceASRArtifactVerificationLimits = .production,
        verifyContentDigest: Bool
    ) throws -> Self {
        guard limits.maximumManifestBytes > 0,
              limits.maximumFileCount > 0,
              limits.maximumTotalBytes > 0,
              limits.maximumJSONDepth > 0,
              limits.maximumJSONNodes > 0,
              limits.maximumFilesystemDepth > 0,
              limits.maximumFilesystemEntries > 0
        else {
            throw VoiceASRArtifactError.invalidVerificationLimits
        }
        guard data.count <= limits.maximumManifestBytes else {
            throw VoiceASRArtifactError.manifestTooLarge(
                maximumBytes: limits.maximumManifestBytes,
                actualBytes: data.count
            )
        }
        do {
            var scanner = VoiceASRStrictJSONScanner(
                data: data,
                maximumDepth: limits.maximumJSONDepth,
                maximumNodes: limits.maximumJSONNodes
            )
            try scanner.validate()
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            let manifest = Self(wire: wire)
            try manifest.validate(
                limits: limits,
                verifyContentDigest: verifyContentDigest
            )
            return manifest
        } catch let error as VoiceASRArtifactError {
            throw error
        } catch {
            throw VoiceASRArtifactError.invalidJSON
        }
    }

    /// Stable identity input: a domain separator followed by canonical JSON
    /// for all metadata and the inventory sorted by path. The declared
    /// `content_sha256` is intentionally excluded to avoid self-reference.
    public var canonicalContentData: Data {
        let sortedInventory = inventory.sorted { $0.path < $1.path }
        let value = VoiceASRCanonicalJSON.object([
            "adapter": .object([
                "abi_version": .integer(Int64(adapter.abiVersion)),
                "id": .string(adapter.id),
                "version": .string(adapter.version),
            ]),
            "artifact_id": .string(artifactID.rawValue),
            "artifact_type": .string(artifactType),
            "asset_management": .string(assetManagement.rawValue),
            "audio": .object([
                "channel_count": .integer(Int64(audio.channelCount)),
                "frame_duration_ms": .integer(
                    Int64(audio.frameDurationMilliseconds)
                ),
                "sample_format": .string(audio.sampleFormat.rawValue),
                "sample_rate_hz": .integer(Int64(audio.sampleRateHertz)),
            ]),
            "capabilities": .object([
                "endpoint_detection": .boolean(
                    capabilities.endpointDetection
                ),
                "hotword_mode": .string(capabilities.hotwordMode.rawValue),
                "maximum_alternatives": .integer(
                    Int64(capabilities.maximumAlternatives)
                ),
                "maximum_hotwords": .integer(
                    Int64(capabilities.maximumHotwords)
                ),
                "partial_results": .boolean(capabilities.partialResults),
                "streaming": .boolean(capabilities.streaming),
            ]),
            "inventory": .array(sortedInventory.map { entry in
                .object([
                    "bytes": .integer(entry.bytes),
                    "path": .string(entry.path),
                    "sha256": .string(entry.sha256),
                ])
            }),
            "license": .object([
                "license_path": .string(license.licensePath),
                "notice_path": .string(license.noticePath),
                "source_url": .string(license.sourceURL),
                "spdx_id": .string(license.spdxID),
            ]),
            "locales": .array(locales.map { .string($0) }),
            "model": .object([
                "format": .string(model.format.rawValue),
                "id": .string(model.id),
                "quantization": .string(model.quantization.rawValue),
                "revision": .string(model.revision),
            ]),
            "network_policy": .string(networkPolicy.rawValue),
            "runtime": .object([
                "bpe_vocab_path": .string(runtime.bpeVocabularyPath),
                "blank_penalty_milli": .integer(
                    Int64(runtime.blankPenaltyMilli)
                ),
                "decoding_method": .string(runtime.decodingMethod.rawValue),
                "decoder_path": .string(runtime.decoderPath),
                "encoder_path": .string(runtime.encoderPath),
                "endpoint": .object([
                    "enabled": .boolean(runtime.endpoint.enabled),
                    "rule1_min_trailing_silence_ms": .integer(Int64(
                        runtime.endpoint
                            .rule1MinimumTrailingSilenceMilliseconds
                    )),
                    "rule2_min_trailing_silence_ms": .integer(Int64(
                        runtime.endpoint
                            .rule2MinimumTrailingSilenceMilliseconds
                    )),
                    "rule3_min_utterance_ms": .integer(Int64(
                        runtime.endpoint.rule3MinimumUtteranceMilliseconds
                    )),
                ]),
                "feature_dimension": .integer(
                    Int64(runtime.featureDimension)
                ),
                "hotword_probe_phrase": .string(
                    runtime.hotwordProbePhrase
                ),
                "hotwords_score_milli": .integer(
                    Int64(runtime.hotwordsScoreMilli)
                ),
                "joiner_path": .string(runtime.joinerPath),
                "kind": .string(runtime.kind.rawValue),
                "max_active_paths": .integer(
                    Int64(runtime.maximumActivePaths)
                ),
                "model_type": .string(runtime.modelType.rawValue),
                "modeling_unit": .string(runtime.modelingUnit.rawValue),
                "num_threads": .integer(Int64(runtime.numberOfThreads)),
                "provider": .string(runtime.provider.rawValue),
                "tokens_path": .string(runtime.tokensPath),
            ]),
            "schema_version": .integer(Int64(schemaVersion)),
            "target": .object([
                "architecture": .string(target.architecture.rawValue),
                "minimum_os_version": .string(target.minimumOSVersion),
                "os": .string(target.os.rawValue),
            ]),
        ])
        var data = Data("rimeai.voice-asr.content.v2\0".utf8)
        data.append(contentsOf: value.encoded().utf8)
        return data
    }

    public var calculatedContentSHA256: String {
        SHA256.hash(data: canonicalContentData).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func validate(
        limits: VoiceASRArtifactVerificationLimits,
        verifyContentDigest: Bool
    ) throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw VoiceASRArtifactError.unsupportedSchema(schemaVersion)
        }
        guard artifactType == Self.supportedArtifactType else {
            throw VoiceASRArtifactError.unsupportedArtifactType(artifactType)
        }
        guard assetManagement == .productManaged else {
            throw VoiceASRArtifactError.productManagedRequired
        }
        guard Self.isControlledIdentifier(adapter.id, maximumBytes: 128) else {
            throw VoiceASRArtifactError.invalidField("adapter.id")
        }
        guard Self.isBoundedASCIIValue(adapter.version, maximumBytes: 64) else {
            throw VoiceASRArtifactError.invalidField("adapter.version")
        }
        guard (1 ... 65_535).contains(adapter.abiVersion) else {
            throw VoiceASRArtifactError.invalidField("adapter.abi_version")
        }
        guard Self.isControlledIdentifier(model.id, maximumBytes: 128) else {
            throw VoiceASRArtifactError.invalidField("model.id")
        }
        guard Self.isBoundedASCIIValue(model.revision, maximumBytes: 128) else {
            throw VoiceASRArtifactError.invalidField("model.revision")
        }
        guard target.minimumOSVersion == "14.0" else {
            throw VoiceASRArtifactError.invalidField(
                "target.minimum_os_version"
            )
        }
        guard audio.sampleRateHertz == 16_000,
              audio.channelCount == 1,
              audio.sampleFormat == .float32LittleEndian,
              audio.frameDurationMilliseconds == 20
        else {
            throw VoiceASRArtifactError.invalidField("audio")
        }
        guard adapter.id == "sherpa-onnx",
              model.format == .onnx,
              runtime.kind == .sherpaOnnxOnlineTransducer,
              runtime.modelingUnit == .cjkCharacterAndBPE,
              runtime.modelType == .zipformer,
              runtime.featureDimension == 80,
              runtime.provider == .cpu,
              (1 ... 8).contains(runtime.numberOfThreads),
              runtime.decodingMethod == .modifiedBeamSearch,
              (1 ... 64).contains(runtime.maximumActivePaths),
              runtime.endpoint.enabled,
              (1 ... 30_000).contains(
                  runtime.endpoint.rule1MinimumTrailingSilenceMilliseconds
              ),
              (1 ... 30_000).contains(
                  runtime.endpoint.rule2MinimumTrailingSilenceMilliseconds
              ),
              runtime.endpoint.rule1MinimumTrailingSilenceMilliseconds
                  >= runtime.endpoint.rule2MinimumTrailingSilenceMilliseconds,
              (1_000 ... 60_000).contains(
                  runtime.endpoint.rule3MinimumUtteranceMilliseconds
              ),
              (1 ... 10_000).contains(runtime.hotwordsScoreMilli),
              (-10_000 ... 10_000).contains(runtime.blankPenaltyMilli)
        else {
            throw VoiceASRArtifactError.invalidField("runtime")
        }
        guard locales == locales.sorted(),
              Set(locales).count == locales.count,
              (1 ... 32).contains(locales.count),
              locales.allSatisfy(Self.isCanonicalLocale)
        else {
            throw VoiceASRArtifactError.invalidField("locales")
        }
        guard (1 ... 8).contains(capabilities.maximumAlternatives),
              !capabilities.partialResults || capabilities.streaming
        else {
            throw VoiceASRArtifactError.invalidField("capabilities")
        }
        switch capabilities.hotwordMode {
        case .unsupported:
            guard capabilities.maximumHotwords == 0,
                  runtime.hotwordProbePhrase.isEmpty
            else {
                throw VoiceASRArtifactError.invalidField("capabilities")
            }
        case .boundedPhraseList:
            guard (1 ... 128).contains(capabilities.maximumHotwords),
                  Self.isCanonicalHotwordProbePhrase(
                      runtime.hotwordProbePhrase
                  )
            else {
                throw VoiceASRArtifactError.invalidField("capabilities")
            }
        }
        guard Self.isSPDXID(license.spdxID) else {
            throw VoiceASRArtifactError.invalidField("license.spdx_id")
        }
        guard Self.isHTTPSURLWithoutCredentials(license.sourceURL) else {
            throw VoiceASRArtifactError.invalidField("license.source_url")
        }
        guard inventory.count <= limits.maximumFileCount else {
            throw VoiceASRArtifactError.inventoryFileLimitExceeded(
                maximum: limits.maximumFileCount,
                actual: inventory.count
            )
        }
        guard !inventory.isEmpty else {
            throw VoiceASRArtifactError.invalidField("inventory")
        }

        var seen: Set<String> = []
        var totalBytes: Int64 = 0
        var previousPath: String?
        for entry in inventory {
            guard Self.isCanonicalRelativePath(entry.path),
                  entry.path != Self.manifestFileName
            else {
                throw VoiceASRArtifactError.invalidInventoryPath(entry.path)
            }
            guard seen.insert(entry.path).inserted else {
                throw VoiceASRArtifactError.duplicateInventoryPath(entry.path)
            }
            if let previousPath, entry.path.hasPrefix(previousPath + "/") {
                throw VoiceASRArtifactError.invalidInventoryPath(entry.path)
            }
            previousPath = entry.path
            guard entry.bytes >= 0 else {
                throw VoiceASRArtifactError.invalidField(
                    "inventory.bytes:\(entry.path)"
                )
            }
            guard Self.isSHA256(entry.sha256) else {
                throw VoiceASRArtifactError.invalidField(
                    "inventory.sha256:\(entry.path)"
                )
            }
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(
                entry.bytes
            )
            guard !overflow, newTotal <= limits.maximumTotalBytes else {
                throw VoiceASRArtifactError.inventoryByteLimitExceeded(
                    maximum: limits.maximumTotalBytes,
                    actual: overflow ? Int64.max : newTotal
                )
            }
            totalBytes = newTotal
        }
        let inventoryPaths = inventory.map(\.path)
        guard inventoryPaths == inventoryPaths.sorted() else {
            throw VoiceASRArtifactError.inventoryMustBeSorted
        }
        guard license.licensePath != license.noticePath,
              seen.contains(license.licensePath),
              seen.contains(license.noticePath),
              Self.isCanonicalRelativePath(license.licensePath),
              Self.isCanonicalRelativePath(license.noticePath)
        else {
            throw VoiceASRArtifactError.invalidField("license paths")
        }
        let runtimePaths = [
            runtime.encoderPath,
            runtime.decoderPath,
            runtime.joinerPath,
            runtime.tokensPath,
            runtime.bpeVocabularyPath,
        ]
        guard Set(runtimePaths).count == runtimePaths.count,
              Set(runtimePaths).isDisjoint(with: Set([
                  license.licensePath,
                  license.noticePath,
              ])),
              runtimePaths.allSatisfy(Self.isCanonicalRelativePath),
              runtimePaths.allSatisfy(seen.contains),
              runtime.encoderPath.hasSuffix(".onnx"),
              runtime.decoderPath.hasSuffix(".onnx"),
              runtime.joinerPath.hasSuffix(".onnx"),
              runtime.tokensPath.hasSuffix(".txt"),
              runtime.bpeVocabularyPath.hasSuffix(".vocab"),
              capabilities.streaming,
              capabilities.partialResults,
              capabilities.endpointDetection,
              capabilities.hotwordMode == .boundedPhraseList,
              capabilities.maximumAlternatives == 1
        else {
            throw VoiceASRArtifactError.invalidField("runtime")
        }
        guard Self.isSHA256(contentSHA256) else {
            throw VoiceASRArtifactError.invalidField("content_sha256")
        }
        if verifyContentDigest {
            let actual = calculatedContentSHA256
            guard contentSHA256 == actual else {
                throw VoiceASRArtifactError.contentDigestMismatch(
                    expected: contentSHA256,
                    actual: actual
                )
            }
        }
    }

    private static func isControlledIdentifier(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              let first = value.utf8.first,
              VoiceASRArtifactID.isASCIIAlphaNumericForManifest(first)
        else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy { byte in
            VoiceASRArtifactID.isASCIIAlphaNumericForManifest(byte)
                || byte == 0x2D
                || byte == 0x2E
                || byte == 0x5F
        }
    }

    private static func isBoundedASCIIValue(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && value.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }

    private static func isCanonicalLocale(_ value: String) -> Bool {
        guard value.utf8.count <= 35 else {
            return false
        }
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard (2 ... 3).contains(components.first?.count ?? 0),
              components.count == 2 || components.count == 3,
              components[0].utf8.allSatisfy({
                  $0 >= 0x61 && $0 <= 0x7A
              })
        else {
            return false
        }
        var offset = 1
        if components.count == 3 {
            let script = components[1].utf8
            guard script.count == 4,
                  let first = script.first,
                  first >= 0x41,
                  first <= 0x5A,
                  script.dropFirst().allSatisfy({
                      $0 >= 0x61 && $0 <= 0x7A
                  })
            else {
                return false
            }
            offset = 2
        }
        let region = components[offset].utf8
        return (region.count == 2
            && region.allSatisfy { $0 >= 0x41 && $0 <= 0x5A })
            || (region.count == 3
                && region.allSatisfy { $0 >= 0x30 && $0 <= 0x39 })
    }

    /// Mirrors the one-phrase canonicalization contract used by the voice
    /// protocol without making artifact verification depend on transport code.
    private static func isCanonicalHotwordProbePhrase(
        _ value: String
    ) -> Bool {
        let normalized = value
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == value
            && (2 ... 32).contains(normalized.count)
            && normalized.utf8.count <= 128
            && !normalized.unicodeScalars.contains(where: {
                $0.value < 0x20 || (0x7F ... 0x9F).contains($0.value)
            })
            && !normalized.contains("/")
            && !normalized.contains(":")
            && !normalized.contains("#")
            && !normalized.contains("@")
    }

    private static func isSPDXID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D
                || byte == 0x2E
                || byte == 0x2B
        }
    }

    private static func isHTTPSURLWithoutCredentials(_ value: String) -> Bool {
        guard value.utf8.count <= 2_048,
              let components = URLComponents(string: value),
              components.scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil
        else {
            return false
        }
        return true
    }

    private static func isCanonicalRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.utf8.count <= 512,
              path.utf8.elementsEqual(
                  path.precomposedStringWithCanonicalMapping.utf8
              ),
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\\"),
              !path.contains("//"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 })
        else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.allSatisfy { component in
            !component.isEmpty
                && component != "."
                && component != ".."
                && component.utf8.count <= 255
                && !component.hasPrefix("._")
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x61 && byte <= 0x66)
        }
    }
}

private extension VoiceASRArtifactID {
    static func isASCIIAlphaNumericForManifest(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
    }
}

public struct VoiceASRVerifiedArtifact: Equatable, Sendable {
    public let artifactDirectory: URL
    public let manifest: VoiceASRArtifactManifest
    public let contentSHA256: String
    public let verifiedFileCount: Int
    public let verifiedPayloadBytes: Int64

    @_spi(RimeAIInternal)
    public init(
        artifactDirectory: URL,
        manifest: VoiceASRArtifactManifest,
        contentSHA256: String,
        verifiedFileCount: Int,
        verifiedPayloadBytes: Int64
    ) {
        self.artifactDirectory = artifactDirectory
        self.manifest = manifest
        self.contentSHA256 = contentSHA256
        self.verifiedFileCount = verifiedFileCount
        self.verifiedPayloadBytes = verifiedPayloadBytes
    }
}

public protocol VoiceASRArtifactVerifying: Sendable {
    func verifyArtifact(at artifactDirectory: URL) throws
        -> VoiceASRVerifiedArtifact
}

/// Production filesystem verifier for an already-present, data-only model
/// pack. It performs no downloads, installation, signature validation, or
/// provenance authentication.
public struct VoiceASRArtifactVerifier: VoiceASRArtifactVerifying, Sendable {
    public let limits: VoiceASRArtifactVerificationLimits

    public init(limits: VoiceASRArtifactVerificationLimits = .production) {
        self.limits = limits
    }

    public func verifyArtifact(
        at artifactDirectory: URL
    ) throws -> VoiceASRVerifiedArtifact {
        guard limits.maximumManifestBytes > 0,
              limits.maximumFileCount > 0,
              limits.maximumTotalBytes > 0,
              limits.maximumJSONDepth > 0,
              limits.maximumJSONNodes > 0,
              limits.maximumFilesystemDepth > 0,
              limits.maximumFilesystemEntries > 0
        else {
            throw VoiceASRArtifactError.invalidVerificationLimits
        }
        let artifactPath = artifactDirectory.path
        guard artifactDirectory.isFileURL,
              Self.isCanonicalAbsolutePath(artifactPath)
        else {
            throw VoiceASRArtifactError.artifactRootMustBeDirectory
        }

        let openedRoot = try Self.openRootByComponents(artifactPath)
        let rootDescriptor = openedRoot.descriptor
        defer { close(rootDescriptor) }
        var rootStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
              rootStatus.st_mode & S_IFMT == S_IFDIR,
              rootStatus.st_dev == openedRoot.namedStatus.st_dev,
              rootStatus.st_ino == openedRoot.namedStatus.st_ino,
              rootStatus.st_uid == geteuid(),
              rootStatus.st_mode & mode_t(0o022) == 0,
              Self.hasNoExtendedACL(descriptor: rootDescriptor)
        else {
            throw VoiceASRArtifactError.insecureFilesystemEntry(".")
        }

        let manifestData = try readRegularFile(
            relativePath: VoiceASRArtifactManifest.manifestFileName,
            rootDescriptor: rootDescriptor,
            maximumBytes: Int64(limits.maximumManifestBytes)
        )
        let manifest = try VoiceASRArtifactManifest.decodeStrict(
            manifestData,
            limits: limits
        )

        var inspectedEntries = 0
        let tree = try inspectTree(
            directoryDescriptor: rootDescriptor,
            relativePrefix: "",
            depth: 0,
            inspectedEntries: &inspectedEntries
        )
        let expectedFiles = Set(manifest.inventory.map(\.path))
            .union([VoiceASRArtifactManifest.manifestFileName])
        if let unexpected = tree.files.subtracting(expectedFiles).sorted().first {
            throw VoiceASRArtifactError.unexpectedFile(unexpected)
        }
        if let missing = expectedFiles.subtracting(tree.files).sorted().first {
            throw VoiceASRArtifactError.missingFile(missing)
        }

        let expectedDirectories = Self.directoryPrefixes(
            for: manifest.inventory.map(\.path)
        )
        if let unexpected = tree.directories
            .subtracting(expectedDirectories)
            .sorted()
            .first
        {
            throw VoiceASRArtifactError.unexpectedFile(unexpected + "/")
        }
        if let missing = expectedDirectories
            .subtracting(tree.directories)
            .sorted()
            .first
        {
            throw VoiceASRArtifactError.missingFile(missing + "/")
        }

        var verifiedBytes: Int64 = 0
        for entry in manifest.inventory {
            let opened = try openRegularFile(
                relativePath: entry.path,
                rootDescriptor: rootDescriptor
            )
            do {
                defer { close(opened.descriptor) }
                guard opened.bytes == entry.bytes else {
                    throw VoiceASRArtifactError.fileSizeMismatch(
                        path: entry.path,
                        expected: entry.bytes,
                        actual: opened.bytes
                    )
                }
                let digest = try hashFile(
                    descriptor: opened.descriptor,
                    path: entry.path,
                    maximumBytes: entry.bytes
                )
                guard digest.bytes == entry.bytes else {
                    throw VoiceASRArtifactError.fileSizeMismatch(
                        path: entry.path,
                        expected: entry.bytes,
                        actual: digest.bytes
                    )
                }
                guard digest.sha256 == entry.sha256 else {
                    throw VoiceASRArtifactError.fileHashMismatch(
                        path: entry.path,
                        expected: entry.sha256,
                        actual: digest.sha256
                    )
                }
            }
            verifiedBytes += entry.bytes
        }

        let finalManifestData = try readRegularFile(
            relativePath: VoiceASRArtifactManifest.manifestFileName,
            rootDescriptor: rootDescriptor,
            maximumBytes: Int64(limits.maximumManifestBytes)
        )
        guard finalManifestData == manifestData else {
            throw VoiceASRArtifactError.insecureFilesystemEntry(
                VoiceASRArtifactManifest.manifestFileName
            )
        }
        var finalInspectedEntries = 0
        let finalTree = try inspectTree(
            directoryDescriptor: rootDescriptor,
            relativePrefix: "",
            depth: 0,
            inspectedEntries: &finalInspectedEntries
        )
        guard finalTree == tree else {
            throw VoiceASRArtifactError.insecureFilesystemEntry(".")
        }
        var heldFinalStatus = stat()
        guard fstat(rootDescriptor, &heldFinalStatus) == 0,
              heldFinalStatus.st_mode & S_IFMT == S_IFDIR,
              heldFinalStatus.st_dev == rootStatus.st_dev,
              heldFinalStatus.st_ino == rootStatus.st_ino,
              heldFinalStatus.st_uid == geteuid(),
              heldFinalStatus.st_mode & mode_t(0o022) == 0,
              Self.hasNoExtendedACL(descriptor: rootDescriptor)
        else {
            throw VoiceASRArtifactError.insecureFilesystemEntry(".")
        }
        let reboundRoot: OpenedRoot
        do {
            reboundRoot = try Self.openRootByComponents(artifactPath)
        } catch {
            throw VoiceASRArtifactError.insecureFilesystemEntry(".")
        }
        defer { close(reboundRoot.descriptor) }
        var reboundStatus = stat()
        guard fstat(reboundRoot.descriptor, &reboundStatus) == 0,
              reboundStatus.st_mode & S_IFMT == S_IFDIR,
              reboundStatus.st_dev == rootStatus.st_dev,
              reboundStatus.st_ino == rootStatus.st_ino,
              reboundStatus.st_dev == reboundRoot.namedStatus.st_dev,
              reboundStatus.st_ino == reboundRoot.namedStatus.st_ino,
              reboundStatus.st_uid == geteuid(),
              reboundStatus.st_mode & mode_t(0o022) == 0,
              Self.hasNoExtendedACL(descriptor: reboundRoot.descriptor)
        else {
            throw VoiceASRArtifactError.insecureFilesystemEntry(".")
        }

        return VoiceASRVerifiedArtifact(
            artifactDirectory: artifactDirectory,
            manifest: manifest,
            contentSHA256: manifest.contentSHA256,
            verifiedFileCount: manifest.inventory.count,
            verifiedPayloadBytes: verifiedBytes
        )
    }

    private struct InspectedTree: Equatable {
        var files: Set<String> = []
        var directories: Set<String> = []
    }

    private struct OpenedFile {
        let descriptor: Int32
        let bytes: Int64
    }

    private struct OpenedRoot {
        let descriptor: Int32
        let namedStatus: stat
    }

    private struct FileDigest {
        let sha256: String
        let bytes: Int64
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.utf8.count > 1,
              path.utf8.count < 4_096,
              path.first == "/",
              path.last != "/",
              path.utf8.elementsEqual(
                  path.precomposedStringWithCanonicalMapping.utf8
              ),
              !path.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7F
              })
        else {
            return false
        }
        return path.dropFirst().split(
            separator: "/",
            omittingEmptySubsequences: false
        ).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
                && $0.utf8.count <= 255
        }
    }

    private static func openRootByComponents(
        _ path: String
    ) throws -> OpenedRoot {
        let components = path.dropFirst().split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty else {
            throw VoiceASRArtifactError.artifactRootMustBeDirectory
        }
        var current = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else {
            throw VoiceASRArtifactError.artifactRootMustBeDirectory
        }
        do {
            for (index, component) in components.enumerated() {
                var named = stat()
                let statusResult = component.withCString { pointer in
                    fstatat(current, pointer, &named, AT_SYMLINK_NOFOLLOW)
                }
                guard statusResult == 0 else {
                    throw VoiceASRArtifactError.artifactRootMustBeDirectory
                }
                guard named.st_mode & S_IFMT != S_IFLNK else {
                    throw VoiceASRArtifactError.insecureFilesystemEntry(".")
                }
                guard named.st_mode & S_IFMT == S_IFDIR else {
                    throw VoiceASRArtifactError.artifactRootMustBeDirectory
                }
                let next = component.withCString { pointer in
                    openat(
                        current,
                        pointer,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard next >= 0 else {
                    throw VoiceASRArtifactError.insecureFilesystemEntry(".")
                }
                var opened = stat()
                guard fstat(next, &opened) == 0,
                      opened.st_mode & S_IFMT == S_IFDIR,
                      opened.st_dev == named.st_dev,
                      opened.st_ino == named.st_ino
                else {
                    close(next)
                    throw VoiceASRArtifactError.insecureFilesystemEntry(".")
                }
                close(current)
                current = next
                if index == components.count - 1 {
                    return OpenedRoot(
                        descriptor: current,
                        namedStatus: named
                    )
                }
            }
        } catch {
            close(current)
            throw error
        }
        close(current)
        throw VoiceASRArtifactError.artifactRootMustBeDirectory
    }

    private func inspectTree(
        directoryDescriptor: Int32,
        relativePrefix: String,
        depth: Int,
        inspectedEntries: inout Int
    ) throws -> InspectedTree {
        guard depth <= limits.maximumFilesystemDepth else {
            throw VoiceASRArtifactError.filesystemDepthLimitExceeded(
                maximum: limits.maximumFilesystemDepth
            )
        }
        let iterationDescriptor = openat(
            directoryDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard iterationDescriptor >= 0 else {
            throw Self.ioError(path: relativePrefix.isEmpty ? "." : relativePrefix)
        }
        guard let directory = fdopendir(iterationDescriptor) else {
            let savedErrno = errno
            close(iterationDescriptor)
            throw VoiceASRArtifactError.ioFailure(
                path: relativePrefix.isEmpty ? "." : relativePrefix,
                errno: savedErrno
            )
        }
        defer { closedir(directory) }

        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { buffer in
                String(
                    cString: buffer.baseAddress!.assumingMemoryBound(
                        to: CChar.self
                    )
                )
            }
            if name != ".", name != ".." {
                inspectedEntries += 1
                guard inspectedEntries <= limits.maximumFilesystemEntries else {
                    throw VoiceASRArtifactError.filesystemEntryLimitExceeded(
                        maximum: limits.maximumFilesystemEntries
                    )
                }
                names.append(name)
            }
        }
        if errno != 0 {
            throw Self.ioError(path: relativePrefix.isEmpty ? "." : relativePrefix)
        }

        var result = InspectedTree()
        for name in names.sorted() {
            let relativePath = relativePrefix.isEmpty
                ? name
                : relativePrefix + "/" + name
            guard relativePath.utf8.count <= 512 else {
                throw VoiceASRArtifactError.insecureFilesystemEntry(
                    relativePath
                )
            }
            if name.hasPrefix("._") {
                throw VoiceASRArtifactError.insecureFilesystemEntry(
                    relativePath
                )
            }
            var status = stat()
            let statusResult = name.withCString { pointer in
                fstatat(
                    directoryDescriptor,
                    pointer,
                    &status,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard statusResult == 0 else {
                throw Self.ioError(path: relativePath)
            }
            switch status.st_mode & S_IFMT {
            case S_IFREG:
                result.files.insert(relativePath)
            case S_IFDIR:
                result.directories.insert(relativePath)
                let childDescriptor = name.withCString { pointer in
                    openat(
                        directoryDescriptor,
                        pointer,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard childDescriptor >= 0 else {
                    if errno == ELOOP {
                        throw VoiceASRArtifactError.insecureFilesystemEntry(
                            relativePath
                        )
                    }
                    throw Self.ioError(path: relativePath)
                }
                let nested: InspectedTree
                do {
                    defer { close(childDescriptor) }
                    try validateSecureDirectory(
                        descriptor: childDescriptor,
                        expected: status,
                        path: relativePath
                    )
                    nested = try inspectTree(
                        directoryDescriptor: childDescriptor,
                        relativePrefix: relativePath,
                        depth: depth + 1,
                        inspectedEntries: &inspectedEntries
                    )
                }
                result.files.formUnion(nested.files)
                result.directories.formUnion(nested.directories)
            case S_IFLNK:
                throw VoiceASRArtifactError.insecureFilesystemEntry(
                    relativePath
                )
            default:
                throw VoiceASRArtifactError.unsupportedFilesystemEntry(
                    relativePath
                )
            }
        }
        return result
    }

    private func readRegularFile(
        relativePath: String,
        rootDescriptor: Int32,
        maximumBytes: Int64
    ) throws -> Data {
        let opened = try openRegularFile(
            relativePath: relativePath,
            rootDescriptor: rootDescriptor
        )
        defer { close(opened.descriptor) }
        guard opened.bytes <= maximumBytes else {
            throw VoiceASRArtifactError.manifestTooLarge(
                maximumBytes: Int(maximumBytes),
                actualBytes: opened.bytes > Int.max
                    ? Int.max
                    : Int(opened.bytes)
            )
        }
        var data = Data()
        data.reserveCapacity(Int(opened.bytes))
        let handle = FileHandle(
            fileDescriptor: opened.descriptor,
            closeOnDealloc: false
        )
        do {
            while let chunk = try handle.read(upToCount: 64 * 1_024),
                  !chunk.isEmpty
            {
                data.append(chunk)
                guard data.count <= maximumBytes else {
                    throw VoiceASRArtifactError.manifestTooLarge(
                        maximumBytes: Int(maximumBytes),
                        actualBytes: data.count
                    )
                }
            }
        } catch let error as VoiceASRArtifactError {
            throw error
        } catch {
            throw Self.ioError(path: relativePath)
        }
        return data
    }

    private func openRegularFile(
        relativePath: String,
        rootDescriptor: Int32
    ) throws -> OpenedFile {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            throw VoiceASRArtifactError.insecureFilesystemEntry(relativePath)
        }
        var parentDescriptor = dup(rootDescriptor)
        guard parentDescriptor >= 0 else {
            throw Self.ioError(path: relativePath)
        }
        for component in components.dropLast() {
            let nextDescriptor = component.withCString { pointer in
                openat(
                    parentDescriptor,
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            let openErrno = errno
            close(parentDescriptor)
            guard nextDescriptor >= 0 else {
                if openErrno == ELOOP {
                    throw VoiceASRArtifactError.insecureFilesystemEntry(
                        relativePath
                    )
                }
                throw VoiceASRArtifactError.ioFailure(
                    path: relativePath,
                    errno: openErrno
                )
            }
            do {
                try validateSecureDirectory(
                    descriptor: nextDescriptor,
                    expected: nil,
                    path: relativePath
                )
            } catch {
                close(nextDescriptor)
                throw error
            }
            parentDescriptor = nextDescriptor
        }
        let descriptor = components.last!.withCString { pointer in
            openat(
                parentDescriptor,
                pointer,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        let openErrno = errno
        close(parentDescriptor)
        guard descriptor >= 0 else {
            if openErrno == ELOOP {
                throw VoiceASRArtifactError.insecureFilesystemEntry(
                    relativePath
                )
            }
            throw VoiceASRArtifactError.ioFailure(
                path: relativePath,
                errno: openErrno
            )
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let savedErrno = errno
            close(descriptor)
            throw VoiceASRArtifactError.ioFailure(
                path: relativePath,
                errno: savedErrno
            )
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & mode_t(0o022) == 0,
              status.st_nlink == 1,
              Self.hasNoExtendedACL(descriptor: descriptor)
        else {
            close(descriptor)
            throw VoiceASRArtifactError.insecureFilesystemEntry(
                relativePath
            )
        }
        return OpenedFile(
            descriptor: descriptor,
            bytes: status.st_size
        )
    }

    private func hashFile(
        descriptor: Int32,
        path: String,
        maximumBytes: Int64
    ) throws -> FileDigest {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw Self.ioError(path: path)
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        )
        var hasher = SHA256()
        var bytesRead: Int64 = 0
        do {
            while let chunk = try handle.read(upToCount: 1_048_576),
                  !chunk.isEmpty
            {
                let (newCount, overflow) = bytesRead.addingReportingOverflow(
                    Int64(chunk.count)
                )
                guard !overflow, newCount <= maximumBytes else {
                    return FileDigest(
                        sha256: "",
                        bytes: overflow ? Int64.max : newCount
                    )
                }
                bytesRead = newCount
                hasher.update(data: chunk)
            }
        } catch {
            throw Self.ioError(path: path)
        }
        return FileDigest(
            sha256: hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined(),
            bytes: bytesRead
        )
    }

    private static func directoryPrefixes(for paths: [String]) -> Set<String> {
        var result: Set<String> = []
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard components.count > 1 else {
                continue
            }
            for count in 1 ..< components.count {
                result.insert(components.prefix(count).joined(separator: "/"))
            }
        }
        return result
    }

    private func validateSecureDirectory(
        descriptor: Int32,
        expected: stat?,
        path: String
    ) throws {
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_mode & S_IFMT == S_IFDIR,
              opened.st_uid == geteuid(),
              opened.st_mode & mode_t(0o022) == 0,
              Self.hasNoExtendedACL(descriptor: descriptor),
              expected.map({
                  $0.st_dev == opened.st_dev && $0.st_ino == opened.st_ino
              }) ?? true
        else {
            throw VoiceASRArtifactError.insecureFilesystemEntry(path)
        }
    }

    private static func hasNoExtendedACL(descriptor: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT
        }
        acl_free(UnsafeMutableRawPointer(acl))
        return false
    }

    private static func ioError(path: String) -> VoiceASRArtifactError {
        VoiceASRArtifactError.ioFailure(path: path, errno: errno)
    }
}
