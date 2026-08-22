import Foundation

public enum VoicePerformanceCollectorError: Error, Equatable, Sendable {
    case invalidPlan
    case invalidEvent
    case invalidCollectorIdentity
    case invalidProcessIdentity
    case invalidEnvironment
    case invalidArtifact
    case invalidStateTransition
    case incompleteCollection
    case samplingFailed
}

public enum VoicePerformanceProcessRole:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case inputMethod = "input_method"
    case candidateService = "candidate_service"
    case voiceHelper = "voice_helper"
}

public struct VoicePerformanceCollectionProtocol:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let sha256: String

    public init(id: String, sha256: String) {
        self.id = id
        self.sha256 = sha256
    }

    fileprivate init(validating wire: Wire) throws {
        guard VoicePerformancePlanValidation.isSafeIdentifier(wire.id),
              VoicePerformancePlanValidation.isLowercaseHex(
                  wire.sha256,
                  length: 64
              )
        else {
            throw VoicePerformanceCollectorError.invalidPlan
        }
        self.init(id: wire.id, sha256: wire.sha256)
    }

    fileprivate struct Wire: Decodable {
        let id: String
        let sha256: String
    }
}

public struct VoicePerformanceProcessPlan: Equatable, Sendable {
    public let role: VoicePerformanceProcessRole
    public let processIdentifier: pid_t
    public let expectedExecutablePath: String
    public let expectedSigningIdentifier: String
    public let expectedCDHash: String

    fileprivate init(wire: Wire) throws {
        guard wire.pid > 0,
              VoicePerformancePlanValidation.isCanonicalAbsolutePath(
                  wire.expectedExecutablePath
              ),
              VoicePerformancePlanValidation.expectedSigningIdentifier(
                  for: wire.role
              ) == wire.expectedSigningIdentifier,
              VoicePerformancePlanValidation.isLowercaseHex(
                  wire.expectedCDHash,
                  length: 40
              )
        else {
            throw VoicePerformanceCollectorError.invalidPlan
        }
        role = wire.role
        processIdentifier = pid_t(wire.pid)
        expectedExecutablePath = wire.expectedExecutablePath
        expectedSigningIdentifier = wire.expectedSigningIdentifier
        expectedCDHash = wire.expectedCDHash
    }

    fileprivate struct Wire: Decodable {
        let role: VoicePerformanceProcessRole
        let pid: Int32
        let expectedExecutablePath: String
        let expectedSigningIdentifier: String
        let expectedCDHash: String

        enum CodingKeys: String, CodingKey {
            case role
            case pid
            case expectedExecutablePath = "expected_executable_path"
            case expectedSigningIdentifier = "expected_signing_identifier"
            case expectedCDHash = "expected_cdhash"
        }
    }
}

public struct VoicePerformanceExpectedArtifact: Equatable, Sendable {
    public let artifactID: String
    public let artifactContentSHA256: String
    public let adapterID: String
    public let engineID: String
    public let modelID: String
    public let modelRevision: String

    fileprivate init(wire: Wire) throws {
        let digest = wire.artifactContentSHA256
        let candidateEngineID = "\(wire.adapterID)@\(digest.prefix(16))"
        let derivedEngineID = candidateEngineID.utf8.count <= 128
            ? candidateEngineID
            : "product@\(digest.prefix(16))"
        guard VoicePerformancePlanValidation.isSafeIdentifier(wire.artifactID),
              VoicePerformancePlanValidation.isLowercaseHex(digest, length: 64),
              VoicePerformancePlanValidation.isSafeIdentifier(wire.adapterID),
              VoicePerformancePlanValidation.isEngineIdentifier(wire.engineID),
              wire.engineID == derivedEngineID,
              VoicePerformancePlanValidation.isSafeIdentifier(wire.modelID),
              VoicePerformancePlanValidation.isSafeIdentifier(
                  wire.modelRevision
              )
        else {
            throw VoicePerformanceCollectorError.invalidPlan
        }
        artifactID = wire.artifactID
        artifactContentSHA256 = wire.artifactContentSHA256
        adapterID = wire.adapterID
        engineID = wire.engineID
        modelID = wire.modelID
        modelRevision = wire.modelRevision
    }

    fileprivate struct Wire: Decodable {
        let artifactID: String
        let artifactContentSHA256: String
        let adapterID: String
        let engineID: String
        let modelID: String
        let modelRevision: String

        enum CodingKeys: String, CodingKey {
            case artifactID = "artifact_id"
            case artifactContentSHA256 = "artifact_content_sha256"
            case adapterID = "adapter_id"
            case engineID = "engine_id"
            case modelID = "model_id"
            case modelRevision = "model_revision"
        }
    }
}

public struct VoicePerformanceCollectionPlan: Equatable, Sendable {
    public static let maximumEncodedBytes = 131_072

    public let sampleIntervalMilliseconds: Int
    public let collectionProtocol: VoicePerformanceCollectionProtocol
    public let nativeCollectorSHA256: String
    public let expectedTeamIdentifier: String
    public let processes: [VoicePerformanceProcessPlan]
    public let artifactDirectory: URL?
    public let artifact: VoicePerformanceExpectedArtifact?

    public static func decodeStrict(_ data: Data) throws -> Self {
        do {
            let value = try VoicePerformanceStrictJSON.validate(
                data,
                maximumBytes: maximumEncodedBytes
            )
            guard VoicePerformanceStrictJSON.hasExactKeys(value, [
                "schema_version",
                "collection_protocol",
                "sample_interval_ms",
                "native_collector_sha256",
                "expected_team_identifier",
                "processes",
                "artifact_directory",
                "artifact",
                  ]),
                  let object = value as? [String: Any],
                  VoicePerformanceStrictJSON.strictInteger(
                      object["schema_version"]
                  ) == 1,
                  VoicePerformanceStrictJSON.strictInteger(
                      object["sample_interval_ms"]
                  ) != nil,
                  VoicePerformanceStrictJSON.hasExactKeys(
                      object["collection_protocol"] as Any,
                      ["id", "sha256"]
                  ),
                  let processObjects = object["processes"]
                    as? [[String: Any]],
                  processObjects.allSatisfy({
                      VoicePerformanceStrictJSON.hasExactKeys($0, [
                          "role",
                          "pid",
                          "expected_executable_path",
                          "expected_signing_identifier",
                          "expected_cdhash",
                      ])
                          && VoicePerformanceStrictJSON.strictInteger(
                              $0["pid"]
                          ) != nil
                  }),
                  object["artifact"] is NSNull
                    || VoicePerformanceStrictJSON.hasExactKeys(
                        object["artifact"] as Any,
                        [
                            "artifact_id",
                            "artifact_content_sha256",
                            "adapter_id",
                            "engine_id",
                            "model_id",
                            "model_revision",
                        ]
                    )
            else {
                throw VoicePerformanceCollectorError.invalidPlan
            }
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            guard wire.schemaVersion == 1,
                  (1 ... 100).contains(wire.sampleIntervalMilliseconds),
                  VoicePerformancePlanValidation.isLowercaseHex(
                      wire.nativeCollectorSHA256,
                      length: 64
                  ),
                  VoicePerformancePlanValidation.isTeamIdentifier(
                      wire.expectedTeamIdentifier
                  ),
                  wire.processes.map(\.role)
                    == VoicePerformanceProcessRole.allCases
            else {
                throw VoicePerformanceCollectorError.invalidPlan
            }
            let processes = try wire.processes.map(
                VoicePerformanceProcessPlan.init(wire:)
            )
            guard Set(processes.map(\.processIdentifier)).count
                    == processes.count
            else {
                throw VoicePerformanceCollectorError.invalidPlan
            }
            if let artifactDirectory = wire.artifactDirectory,
               !VoicePerformancePlanValidation.isCanonicalAbsolutePath(
                   artifactDirectory
               ) {
                throw VoicePerformanceCollectorError.invalidPlan
            }
            let directory = wire.artifactDirectory.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            guard (directory == nil) == (wire.artifact == nil) else {
                throw VoicePerformanceCollectorError.invalidPlan
            }
            return Self(
                sampleIntervalMilliseconds: wire.sampleIntervalMilliseconds,
                collectionProtocol: try VoicePerformanceCollectionProtocol(
                    validating: wire.collectionProtocol
                ),
                nativeCollectorSHA256: wire.nativeCollectorSHA256,
                expectedTeamIdentifier: wire.expectedTeamIdentifier,
                processes: processes,
                artifactDirectory: directory,
                artifact: try wire.artifact.map(
                    VoicePerformanceExpectedArtifact.init(wire:)
                )
            )
        } catch let error as VoicePerformanceCollectorError {
            throw error
        } catch {
            throw VoicePerformanceCollectorError.invalidPlan
        }
    }

    private init(
        sampleIntervalMilliseconds: Int,
        collectionProtocol: VoicePerformanceCollectionProtocol,
        nativeCollectorSHA256: String,
        expectedTeamIdentifier: String,
        processes: [VoicePerformanceProcessPlan],
        artifactDirectory: URL?,
        artifact: VoicePerformanceExpectedArtifact?
    ) {
        self.sampleIntervalMilliseconds = sampleIntervalMilliseconds
        self.collectionProtocol = collectionProtocol
        self.nativeCollectorSHA256 = nativeCollectorSHA256
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.processes = processes
        self.artifactDirectory = artifactDirectory
        self.artifact = artifact
    }

    private struct Wire: Decodable {
        let schemaVersion: Int
        let collectionProtocol: VoicePerformanceCollectionProtocol.Wire
        let sampleIntervalMilliseconds: Int
        let nativeCollectorSHA256: String
        let expectedTeamIdentifier: String
        let processes: [VoicePerformanceProcessPlan.Wire]
        let artifactDirectory: String?
        let artifact: VoicePerformanceExpectedArtifact.Wire?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case collectionProtocol = "collection_protocol"
            case sampleIntervalMilliseconds = "sample_interval_ms"
            case nativeCollectorSHA256 = "native_collector_sha256"
            case expectedTeamIdentifier = "expected_team_identifier"
            case processes
            case artifactDirectory = "artifact_directory"
            case artifact
        }
    }

}

private enum VoicePerformancePlanValidation {
    static func expectedSigningIdentifier(
        for role: VoicePerformanceProcessRole
    ) -> String {
        switch role {
        case .inputMethod:
            "fun.wwcn.inputmethod.RimeAI"
        case .candidateService:
            "rimeai-daemon"
        case .voiceHelper:
            "fun.wwcn.rimeai.voice-helper"
        }
    }

    static func isLowercaseHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
        }
    }

    static func isTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x41 ... 0x5A).contains($0)
        }
    }

    static func isSigningIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 255,
              let first = value.utf8.first,
              (0x30 ... 0x39).contains(first)
                || (0x41 ... 0x5A).contains(first)
                || (0x61 ... 0x7A).contains(first)
        else { return false }
        return value.utf8.allSatisfy {
            (0x30 ... 0x39).contains($0)
                || (0x41 ... 0x5A).contains($0)
                || (0x61 ... 0x7A).contains($0)
                || $0 == 0x2D
                || $0 == 0x2E
        }
    }

    static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 128,
              let first = value.utf8.first,
              isASCIIAlphaNumeric(first)
        else { return false }
        return value.utf8.allSatisfy {
            isASCIIAlphaNumeric($0)
                || $0 == 0x2D
                || $0 == 0x2E
                || $0 == 0x5F
        }
    }

    static func isEngineIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 128,
              let first = value.utf8.first,
              isASCIIAlphaNumeric(first)
        else { return false }
        return value.utf8.allSatisfy {
            isASCIIAlphaNumeric($0)
                || $0 == 0x2D
                || $0 == 0x2E
                || $0 == 0x5F
                || $0 == 0x40
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
            || (0x41 ... 0x5A).contains(byte)
            || (0x61 ... 0x7A).contains(byte)
    }

    static func isCanonicalAbsolutePath(_ value: String) -> Bool {
        guard value.hasPrefix("/"),
              value != "/",
              !value.hasSuffix("/"),
              value == value.precomposedStringWithCanonicalMapping,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 })
        else { return false }
        let url = URL(fileURLWithPath: value, isDirectory: false)
        return url.path == value && url.standardizedFileURL.path == value
    }
}
