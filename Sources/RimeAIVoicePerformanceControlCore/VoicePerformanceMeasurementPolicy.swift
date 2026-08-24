import CryptoKit
import Foundation

public enum VoicePerformanceMeasurementPolicyError: Error, Equatable, Sendable {
    public enum Object: String, Equatable, Sendable {
        case policy
        case controlProtocol
        case collector
        case driver
        case evaluationArtifact
        case helper
    }

    public enum Field: String, Equatable, Sendable {
        case controlSocketPath
        case controlSessionNonce
        case coldTrials
        case collectorExpectedExecutablePath
        case collectorExpectedExecutableSHA256
        case collectorExpectedSigningIdentifier
        case collectorExpectedTeamIdentifier
        case collectorExpectedCDHash
        case driverExpectedExecutablePath
        case driverExpectedExecutableSHA256
        case driverExpectedSigningIdentifier
        case driverExpectedTeamIdentifier
        case driverExpectedCDHash
        case driverPolicySHA256
        case evaluationArtifactDirectory
        case evaluationArtifactAdapterID
        case evaluationArtifactID
        case evaluationArtifactContentSHA256
        case evaluationArtifactMaximumHotwords
        case helperExpectedExecutablePath
        case helperExpectedExecutableSHA256
        case helperExpectedSigningIdentifier
        case helperExpectedTeamIdentifier
        case helperExpectedCDHash
        case releasePolicySHA256
    }

    case invalidJSON
    case carriageReturnForbidden
    case unknownFields(Object)
    case missingFields(Object)
    case unsupportedSchema
    case enabledRequired
    case invalidField(Field)
    case teamIdentifierMismatch
    case nonCanonicalJSON
}

public struct VoicePerformanceMeasurementPolicy: Equatable, Sendable {
    public static let schemaVersion = 2
    public static let maximumEncodedBytes = 65_536
    public static let requiredCollectorSigningIdentifier =
        "fun.wwcn.rimeai.voice-performance-collector"
    public static let requiredDriverSigningIdentifier =
        "fun.wwcn.rimeai.voice-performance-driver"
    public static let requiredHelperSigningIdentifier =
        "fun.wwcn.rimeai.voice-helper"

    public enum Qualification: String, Equatable, Sendable {
        case tracer
    }

    /// The complete variable input needed to seal a tracer measurement policy.
    /// Protocol authority, signing identifiers, policy mode, and the driver
    /// policy digest are deliberately absent because construction owns them.
    public struct TracerBuildInput: Equatable, Sendable {
        public struct ExecutableIdentity: Equatable, Sendable {
            public let executablePath: String
            public let executableSHA256: String
            public let cdHash: String

            public init(
                executablePath: String,
                executableSHA256: String,
                cdHash: String
            ) {
                self.executablePath = executablePath
                self.executableSHA256 = executableSHA256
                self.cdHash = cdHash
            }
        }

        public struct VerifiedEvaluationArtifact: Equatable, Sendable {
            public let directory: String
            public let adapterID: String
            public let artifactID: String
            public let contentSHA256: String
            public let maximumHotwords: UInt64

            public init(
                directory: String,
                adapterID: String,
                artifactID: String,
                contentSHA256: String,
                maximumHotwords: UInt64
            ) {
                self.directory = directory
                self.adapterID = adapterID
                self.artifactID = artifactID
                self.contentSHA256 = contentSHA256
                self.maximumHotwords = maximumHotwords
            }
        }

        public let coldTrials: UInt64
        public let controlSocketPath: String
        public let controlSessionNonce: String
        public let teamIdentifier: String
        public let collector: ExecutableIdentity
        public let driver: ExecutableIdentity
        public let helper: ExecutableIdentity
        public let evaluationArtifact: VerifiedEvaluationArtifact
        public let rawReleasePolicySHA256: String

        public init(
            coldTrials: UInt64,
            controlSocketPath: String,
            controlSessionNonce: String,
            teamIdentifier: String,
            collector: ExecutableIdentity,
            driver: ExecutableIdentity,
            helper: ExecutableIdentity,
            evaluationArtifact: VerifiedEvaluationArtifact,
            rawReleasePolicySHA256: String
        ) {
            self.coldTrials = coldTrials
            self.controlSocketPath = controlSocketPath
            self.controlSessionNonce = controlSessionNonce
            self.teamIdentifier = teamIdentifier
            self.collector = collector
            self.driver = driver
            self.helper = helper
            self.evaluationArtifact = evaluationArtifact
            self.rawReleasePolicySHA256 = rawReleasePolicySHA256
        }
    }

    public struct CollectorIdentity: Equatable, Sendable {
        public let expectedExecutablePath: String
        public let expectedExecutableSHA256: String
        public let expectedSigningIdentifier: String
        public let expectedTeamIdentifier: String
        public let expectedCDHash: String
    }

    public struct DriverIdentity: Equatable, Sendable {
        public let expectedExecutablePath: String
        public let expectedExecutableSHA256: String
        public let expectedSigningIdentifier: String
        public let expectedTeamIdentifier: String
        public let expectedCDHash: String
        public let policySHA256: String
    }

    public struct HelperIdentity: Equatable, Sendable {
        public let expectedExecutablePath: String
        public let expectedExecutableSHA256: String
        public let expectedSigningIdentifier: String
        public let expectedTeamIdentifier: String
        public let expectedCDHash: String
    }

    public struct EvaluationArtifact: Equatable, Sendable {
        public let directory: String
        public let adapterID: String
        public let artifactID: String
        public let contentSHA256: String
        public let maximumHotwords: UInt64
    }

    public let schemaVersion: Int
    public let enabled: Bool
    public let coldTrials: UInt64
    public let controlProtocol: PerformanceControlProtocolIdentity
    public let controlSocketPath: String
    public let controlSessionNonce: String
    public let collector: CollectorIdentity
    public let driver: DriverIdentity
    public let evaluationArtifact: EvaluationArtifact
    public let helper: HelperIdentity
    public let releasePolicySHA256: String
    public let qualification: Qualification
    public let authenticatedProductionDriver: Bool
    public let expectedEngine: ExpectedPerformanceControlEngine

    public var canonicalSHA256: String {
        var input = Data(
            "rimeai.voice-performance-measurement-policy.v2\0".utf8
        )
        input.append(canonicalData)
        return SHA256.hash(data: input).map {
            String(format: "%02x", $0)
        }.joined()
    }

    /// Seals canonical tracer measurement-policy bytes from only verified,
    /// build-specific inputs. Protocol identity, eligibility, signing IDs, and
    /// the linked driver-policy digest are code-owned.
    public static func tracerCanonicalData(
        for input: TracerBuildInput
    ) throws -> Data {
        guard PerformanceControlSessionBinding.supportedTrials.contains(
            input.coldTrials
        ) else {
            throw VoicePerformanceMeasurementPolicyError.invalidField(
                .coldTrials
            )
        }
        guard (1 ... 128).contains(
            input.evaluationArtifact.maximumHotwords
        ) else {
            throw VoicePerformanceMeasurementPolicyError.invalidField(
                .evaluationArtifactMaximumHotwords
            )
        }
        let driverPolicyData = try SealedPerformanceControlDriverPolicy
            .tracerCanonicalData()
        let driverPolicySHA256 = SHA256.hash(data: driverPolicyData).map {
            String(format: "%02x", $0)
        }.joined()
        let teamIdentifier = input.teamIdentifier
        let data = canonicalData(
            schemaVersion: schemaVersion,
            enabled: true,
            coldTrials: input.coldTrials,
            controlProtocol: PerformanceControlProtocolContract.identity,
            controlSocketPath: input.controlSocketPath,
            controlSessionNonce: input.controlSessionNonce,
            collector: CollectorIdentity(
                expectedExecutablePath: input.collector.executablePath,
                expectedExecutableSHA256: input.collector.executableSHA256,
                expectedSigningIdentifier:
                    requiredCollectorSigningIdentifier,
                expectedTeamIdentifier: teamIdentifier,
                expectedCDHash: input.collector.cdHash
            ),
            driver: DriverIdentity(
                expectedExecutablePath: input.driver.executablePath,
                expectedExecutableSHA256: input.driver.executableSHA256,
                expectedSigningIdentifier: requiredDriverSigningIdentifier,
                expectedTeamIdentifier: teamIdentifier,
                expectedCDHash: input.driver.cdHash,
                policySHA256: driverPolicySHA256
            ),
            evaluationArtifact: EvaluationArtifact(
                directory: input.evaluationArtifact.directory,
                adapterID: input.evaluationArtifact.adapterID,
                artifactID: input.evaluationArtifact.artifactID,
                contentSHA256: input.evaluationArtifact.contentSHA256,
                maximumHotwords: input.evaluationArtifact.maximumHotwords
            ),
            helper: HelperIdentity(
                expectedExecutablePath: input.helper.executablePath,
                expectedExecutableSHA256: input.helper.executableSHA256,
                expectedSigningIdentifier: requiredHelperSigningIdentifier,
                expectedTeamIdentifier: teamIdentifier,
                expectedCDHash: input.helper.cdHash
            ),
            releasePolicySHA256: input.rawReleasePolicySHA256
        )
        guard data.count <= maximumEncodedBytes,
              !data.contains(0x0A),
              !data.contains(0x0D)
        else {
            throw VoicePerformanceMeasurementPolicyError.invalidJSON
        }
        let decoded = try decodeCanonical(data)
        guard decoded.schemaVersion == schemaVersion,
              decoded.enabled,
              decoded.qualification == .tracer,
              !decoded.authenticatedProductionDriver,
              decoded.controlProtocol
                == PerformanceControlProtocolContract.identity,
              decoded.driver.policySHA256 == driverPolicySHA256
        else {
            throw VoicePerformanceMeasurementPolicyError.invalidJSON
        }
        return data
    }

    public static func decodeCanonical(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else {
            throw VoicePerformanceMeasurementPolicyError.invalidJSON
        }
        guard !data.contains(0x0D) else {
            throw VoicePerformanceMeasurementPolicyError
                .carriageReturnForbidden
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            guard (try? ControlledPerformanceID(
                wire.evaluationArtifact.adapterID
            )) != nil else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .evaluationArtifactAdapterID
                )
            }
            guard (try? ControlledPerformanceID(
                wire.evaluationArtifact.artifactID
            )) != nil else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .evaluationArtifactID
                )
            }
            guard Self.isLowercaseHex(
                wire.evaluationArtifact.contentSHA256,
                count: 64
            ) else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .evaluationArtifactContentSHA256
                )
            }
            guard (1 ... 128).contains(
                wire.evaluationArtifact.maximumHotwords
            ) else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .evaluationArtifactMaximumHotwords
                )
            }
            let policy = Self(
                schemaVersion: wire.schemaVersion,
                enabled: wire.enabled,
                coldTrials: wire.coldTrials,
                controlProtocol: try PerformanceControlProtocolIdentity(
                    id: wire.controlProtocol.id,
                    sha256: wire.controlProtocol.sha256
                ),
                controlSocketPath: wire.controlSocketPath,
                controlSessionNonce: wire.controlSessionNonce,
                collector: CollectorIdentity(
                    expectedExecutablePath:
                        wire.collector.expectedExecutablePath,
                    expectedExecutableSHA256:
                        wire.collector.expectedExecutableSHA256,
                    expectedSigningIdentifier:
                        wire.collector.expectedSigningIdentifier,
                    expectedTeamIdentifier:
                        wire.collector.expectedTeamIdentifier,
                    expectedCDHash: wire.collector.expectedCDHash
                ),
                driver: DriverIdentity(
                    expectedExecutablePath:
                        wire.driver.expectedExecutablePath,
                    expectedExecutableSHA256:
                        wire.driver.expectedExecutableSHA256,
                    expectedSigningIdentifier:
                        wire.driver.expectedSigningIdentifier,
                    expectedTeamIdentifier:
                        wire.driver.expectedTeamIdentifier,
                    expectedCDHash: wire.driver.expectedCDHash,
                    policySHA256: wire.driver.policySHA256
                ),
                evaluationArtifact: EvaluationArtifact(
                    directory: wire.evaluationArtifact.directory,
                    adapterID: wire.evaluationArtifact.adapterID,
                    artifactID: wire.evaluationArtifact.artifactID,
                    contentSHA256: wire.evaluationArtifact.contentSHA256,
                    maximumHotwords:
                        wire.evaluationArtifact.maximumHotwords
                ),
                helper: HelperIdentity(
                    expectedExecutablePath:
                        wire.helper.expectedExecutablePath,
                    expectedExecutableSHA256:
                        wire.helper.expectedExecutableSHA256,
                    expectedSigningIdentifier:
                        wire.helper.expectedSigningIdentifier,
                    expectedTeamIdentifier:
                        wire.helper.expectedTeamIdentifier,
                    expectedCDHash: wire.helper.expectedCDHash
                ),
                releasePolicySHA256: wire.releasePolicySHA256,
                qualification: .tracer,
                authenticatedProductionDriver: false,
                expectedEngine: try ExpectedPerformanceControlEngine(
                    adapterID: ControlledPerformanceID(
                        wire.evaluationArtifact.adapterID
                    ),
                    artifactID: ControlledPerformanceID(
                        wire.evaluationArtifact.artifactID
                    ),
                    artifactContentSHA256: PerformanceControlSHA256(
                        wire.evaluationArtifact.contentSHA256
                    ),
                    maximumHotwords:
                        wire.evaluationArtifact.maximumHotwords
                )
            )
            guard policy.schemaVersion == Self.schemaVersion else {
                throw VoicePerformanceMeasurementPolicyError.unsupportedSchema
            }
            guard policy.enabled else {
                throw VoicePerformanceMeasurementPolicyError.enabledRequired
            }
            guard PerformanceControlSessionBinding.supportedTrials.contains(
                policy.coldTrials
            ) else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .coldTrials
                )
            }
            guard Self.isLowercaseHex(
                policy.controlSessionNonce,
                count: 64
            ) else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .controlSessionNonce
                )
            }
            try Self.requireLowercaseHex(
                policy.collector.expectedExecutableSHA256,
                count: 64,
                field: .collectorExpectedExecutableSHA256
            )
            try Self.requireLowercaseHex(
                policy.collector.expectedCDHash,
                count: 40,
                field: .collectorExpectedCDHash
            )
            guard policy.collector.expectedSigningIdentifier
                    == Self.requiredCollectorSigningIdentifier
            else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .collectorExpectedSigningIdentifier
                )
            }
            guard Self.isValidTeamIdentifier(
                policy.collector.expectedTeamIdentifier
            ) else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .collectorExpectedTeamIdentifier
                )
            }
            try Self.requireLowercaseHex(
                policy.driver.expectedExecutableSHA256,
                count: 64,
                field: .driverExpectedExecutableSHA256
            )
            try Self.requireLowercaseHex(
                policy.driver.expectedCDHash,
                count: 40,
                field: .driverExpectedCDHash
            )
            guard policy.driver.expectedSigningIdentifier
                    == Self.requiredDriverSigningIdentifier
            else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .driverExpectedSigningIdentifier
                )
            }
            guard Self.isValidTeamIdentifier(
                policy.driver.expectedTeamIdentifier
            ) else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .driverExpectedTeamIdentifier
                )
            }
            try Self.requireLowercaseHex(
                policy.driver.policySHA256,
                count: 64,
                field: .driverPolicySHA256
            )
            try Self.requireLowercaseHex(
                policy.helper.expectedExecutableSHA256,
                count: 64,
                field: .helperExpectedExecutableSHA256
            )
            try Self.requireLowercaseHex(
                policy.helper.expectedCDHash,
                count: 40,
                field: .helperExpectedCDHash
            )
            guard policy.helper.expectedSigningIdentifier
                    == Self.requiredHelperSigningIdentifier
            else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .helperExpectedSigningIdentifier
                )
            }
            guard Self.isValidTeamIdentifier(
                policy.helper.expectedTeamIdentifier
            ) else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .helperExpectedTeamIdentifier
                )
            }
            guard policy.collector.expectedTeamIdentifier
                    == policy.driver.expectedTeamIdentifier,
                  policy.collector.expectedTeamIdentifier
                    == policy.helper.expectedTeamIdentifier
            else {
                throw VoicePerformanceMeasurementPolicyError
                    .teamIdentifierMismatch
            }
            try Self.requireLowercaseHex(
                policy.releasePolicySHA256,
                count: 64,
                field: .releasePolicySHA256
            )
            guard Self.isValidAbsolutePath(
                policy.evaluationArtifact.directory,
                maximumUTF8Bytes: 4_096
            ) else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .evaluationArtifactDirectory
                )
            }
            guard (try? ControlledPerformanceID(
                policy.evaluationArtifact.adapterID
            )) != nil else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .evaluationArtifactAdapterID
                )
            }
            guard (try? ControlledPerformanceID(
                policy.evaluationArtifact.artifactID
            )) != nil else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .evaluationArtifactID
                )
            }
            try Self.requireLowercaseHex(
                policy.evaluationArtifact.contentSHA256,
                count: 64,
                field: .evaluationArtifactContentSHA256
            )
            guard (1 ... 128).contains(
                policy.evaluationArtifact.maximumHotwords
            ) else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .evaluationArtifactMaximumHotwords
                )
            }
            guard Self.isValidAbsolutePath(
                policy.collector.expectedExecutablePath,
                maximumUTF8Bytes: 4_096
            ) else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .collectorExpectedExecutablePath
                )
            }
            guard Self.isValidAbsolutePath(
                policy.driver.expectedExecutablePath,
                maximumUTF8Bytes: 4_096
            ) else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .driverExpectedExecutablePath
                )
            }
            guard Self.isValidAbsolutePath(
                policy.helper.expectedExecutablePath,
                maximumUTF8Bytes: 4_096
            ) else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .helperExpectedExecutablePath
                )
            }
            guard Self.isValidAbsolutePath(
                policy.controlSocketPath,
                maximumUTF8Bytes: 103
            ) else {
                throw VoicePerformanceMeasurementPolicyError.invalidField(
                    .controlSocketPath
                )
            }
            guard policy.canonicalData == data else {
                throw VoicePerformanceMeasurementPolicyError.nonCanonicalJSON
            }
            return policy
        } catch let error as VoicePerformanceMeasurementPolicyError {
            throw error
        } catch let error as PerformanceControlError {
            throw error
        } catch {
            throw VoicePerformanceMeasurementPolicyError.invalidJSON
        }
    }

    private static func isValidAbsolutePath(
        _ path: String,
        maximumUTF8Bytes: Int
    ) -> Bool {
        !path.isEmpty
            && path.utf8.count <= maximumUTF8Bytes
            && path.utf8.elementsEqual(
                path.precomposedStringWithCanonicalMapping.utf8
            )
            && path.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20 && scalar.value != 0x7F
            }
            && isLexicallyStandardizedAbsolutePath(path)
    }

    private static func isLowercaseHex(
        _ value: String,
        count: Int
    ) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte)
                || (0x61 ... 0x66).contains(byte)
        }
    }

    private static func requireLowercaseHex(
        _ value: String,
        count: Int,
        field: VoicePerformanceMeasurementPolicyError.Field
    ) throws {
        guard isLowercaseHex(value, count: count) else {
            throw VoicePerformanceMeasurementPolicyError.invalidField(field)
        }
    }

    private static func isValidTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte)
                || (0x41 ... 0x5A).contains(byte)
        }
    }

    private static func isLexicallyStandardizedAbsolutePath(
        _ path: String
    ) -> Bool {
        guard path.utf8.first == 0x2F else { return false }
        if path == "/" { return false }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.first?.isEmpty == true else { return false }
        return components.dropFirst().allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    private var canonicalData: Data {
        Self.canonicalData(
            schemaVersion: schemaVersion,
            enabled: enabled,
            coldTrials: coldTrials,
            controlProtocol: controlProtocol,
            controlSocketPath: controlSocketPath,
            controlSessionNonce: controlSessionNonce,
            collector: collector,
            driver: driver,
            evaluationArtifact: evaluationArtifact,
            helper: helper,
            releasePolicySHA256: releasePolicySHA256
        )
    }

    private static func canonicalData(
        schemaVersion: Int,
        enabled: Bool,
        coldTrials: UInt64,
        controlProtocol: PerformanceControlProtocolIdentity,
        controlSocketPath: String,
        controlSessionNonce: String,
        collector: CollectorIdentity,
        driver: DriverIdentity,
        evaluationArtifact: EvaluationArtifact,
        helper: HelperIdentity,
        releasePolicySHA256: String
    ) -> Data {
        Data(MeasurementPolicyCanonicalJSON.object([
            "collector": .object([
                "expected_cdhash": .string(collector.expectedCDHash),
                "expected_executable_path": .string(
                    collector.expectedExecutablePath
                ),
                "expected_executable_sha256": .string(
                    collector.expectedExecutableSHA256
                ),
                "expected_signing_identifier": .string(
                    collector.expectedSigningIdentifier
                ),
                "expected_team_identifier": .string(
                    collector.expectedTeamIdentifier
                ),
            ]),
            "cold_trials": .integer(Int(coldTrials)),
            "control_protocol": .object([
                "id": .string(controlProtocol.id),
                "sha256": .string(controlProtocol.sha256),
            ]),
            "control_session_nonce": .string(controlSessionNonce),
            "control_socket_path": .string(controlSocketPath),
            "driver": .object([
                "expected_cdhash": .string(driver.expectedCDHash),
                "expected_executable_path": .string(
                    driver.expectedExecutablePath
                ),
                "expected_executable_sha256": .string(
                    driver.expectedExecutableSHA256
                ),
                "expected_signing_identifier": .string(
                    driver.expectedSigningIdentifier
                ),
                "expected_team_identifier": .string(
                    driver.expectedTeamIdentifier
                ),
                "policy_sha256": .string(driver.policySHA256),
            ]),
            "enabled": .boolean(enabled),
            "evaluation_artifact": .object([
                "adapter_id": .string(evaluationArtifact.adapterID),
                "artifact_id": .string(evaluationArtifact.artifactID),
                "content_sha256": .string(
                    evaluationArtifact.contentSHA256
                ),
                "directory": .string(evaluationArtifact.directory),
                "maximum_hotwords": .integer(
                    Int(evaluationArtifact.maximumHotwords)
                ),
            ]),
            "helper": .object([
                "expected_cdhash": .string(helper.expectedCDHash),
                "expected_executable_path": .string(
                    helper.expectedExecutablePath
                ),
                "expected_executable_sha256": .string(
                    helper.expectedExecutableSHA256
                ),
                "expected_signing_identifier": .string(
                    helper.expectedSigningIdentifier
                ),
                "expected_team_identifier": .string(
                    helper.expectedTeamIdentifier
                ),
            ]),
            "release_policy_sha256": .string(releasePolicySHA256),
            "schema_version": .integer(schemaVersion),
        ]).encoded().utf8)
    }

    private struct Wire: Decodable {
        struct ProtocolIdentity: Decodable {
            let id: String
            let sha256: String

            private enum CodingKeys: String, CodingKey, CaseIterable {
                case id
                case sha256
            }

            init(from decoder: Decoder) throws {
                let object = try MeasurementPolicyStrictJSONObject(
                    decoder,
                    context: .controlProtocol,
                    expectedKeys: Set(CodingKeys.allCases.map(\.rawValue))
                )
                id = try object.decode(String.self, forKey: "id")
                sha256 = try object.decode(String.self, forKey: "sha256")
            }
        }

        struct Collector: Decodable {
            let expectedExecutablePath: String
            let expectedExecutableSHA256: String
            let expectedSigningIdentifier: String
            let expectedTeamIdentifier: String
            let expectedCDHash: String

            enum CodingKeys: String, CodingKey, CaseIterable {
                case expectedExecutablePath = "expected_executable_path"
                case expectedExecutableSHA256 = "expected_executable_sha256"
                case expectedSigningIdentifier = "expected_signing_identifier"
                case expectedTeamIdentifier = "expected_team_identifier"
                case expectedCDHash = "expected_cdhash"
            }

            init(from decoder: Decoder) throws {
                let object = try MeasurementPolicyStrictJSONObject(
                    decoder,
                    context: .collector,
                    expectedKeys: Set(CodingKeys.allCases.map(\.rawValue))
                )
                expectedExecutablePath = try object.decode(
                    String.self,
                    forKey: CodingKeys.expectedExecutablePath.rawValue
                )
                expectedExecutableSHA256 = try object.decode(
                    String.self,
                    forKey: CodingKeys.expectedExecutableSHA256.rawValue
                )
                expectedSigningIdentifier = try object.decode(
                    String.self,
                    forKey: CodingKeys.expectedSigningIdentifier.rawValue
                )
                expectedTeamIdentifier = try object.decode(
                    String.self,
                    forKey: CodingKeys.expectedTeamIdentifier.rawValue
                )
                expectedCDHash = try object.decode(
                    String.self,
                    forKey: CodingKeys.expectedCDHash.rawValue
                )
            }
        }

        struct Driver: Decodable {
            let expectedExecutablePath: String
            let expectedExecutableSHA256: String
            let expectedSigningIdentifier: String
            let expectedTeamIdentifier: String
            let expectedCDHash: String
            let policySHA256: String

            enum CodingKeys: String, CodingKey, CaseIterable {
                case expectedExecutablePath = "expected_executable_path"
                case expectedExecutableSHA256 = "expected_executable_sha256"
                case expectedSigningIdentifier = "expected_signing_identifier"
                case expectedTeamIdentifier = "expected_team_identifier"
                case expectedCDHash = "expected_cdhash"
                case policySHA256 = "policy_sha256"
            }

            init(from decoder: Decoder) throws {
                let object = try MeasurementPolicyStrictJSONObject(
                    decoder,
                    context: .driver,
                    expectedKeys: Set(CodingKeys.allCases.map(\.rawValue))
                )
                expectedExecutablePath = try object.decode(
                    String.self,
                    forKey: CodingKeys.expectedExecutablePath.rawValue
                )
                expectedExecutableSHA256 = try object.decode(
                    String.self,
                    forKey: CodingKeys.expectedExecutableSHA256.rawValue
                )
                expectedSigningIdentifier = try object.decode(
                    String.self,
                    forKey: CodingKeys.expectedSigningIdentifier.rawValue
                )
                expectedTeamIdentifier = try object.decode(
                    String.self,
                    forKey: CodingKeys.expectedTeamIdentifier.rawValue
                )
                expectedCDHash = try object.decode(
                    String.self,
                    forKey: CodingKeys.expectedCDHash.rawValue
                )
                policySHA256 = try object.decode(
                    String.self,
                    forKey: CodingKeys.policySHA256.rawValue
                )
            }
        }

        struct Helper: Decodable {
            let expectedExecutablePath: String
            let expectedExecutableSHA256: String
            let expectedSigningIdentifier: String
            let expectedTeamIdentifier: String
            let expectedCDHash: String

            enum CodingKeys: String, CodingKey, CaseIterable {
                case expectedExecutablePath = "expected_executable_path"
                case expectedExecutableSHA256 = "expected_executable_sha256"
                case expectedSigningIdentifier = "expected_signing_identifier"
                case expectedTeamIdentifier = "expected_team_identifier"
                case expectedCDHash = "expected_cdhash"
            }

            init(from decoder: Decoder) throws {
                let object = try MeasurementPolicyStrictJSONObject(
                    decoder,
                    context: .helper,
                    expectedKeys: Set(CodingKeys.allCases.map(\.rawValue))
                )
                expectedExecutablePath = try object.decode(
                    String.self,
                    forKey: CodingKeys.expectedExecutablePath.rawValue
                )
                expectedExecutableSHA256 = try object.decode(
                    String.self,
                    forKey: CodingKeys.expectedExecutableSHA256.rawValue
                )
                expectedSigningIdentifier = try object.decode(
                    String.self,
                    forKey: CodingKeys.expectedSigningIdentifier.rawValue
                )
                expectedTeamIdentifier = try object.decode(
                    String.self,
                    forKey: CodingKeys.expectedTeamIdentifier.rawValue
                )
                expectedCDHash = try object.decode(
                    String.self,
                    forKey: CodingKeys.expectedCDHash.rawValue
                )
            }
        }

        struct EvaluationArtifact: Decodable {
            let directory: String
            let adapterID: String
            let artifactID: String
            let contentSHA256: String
            let maximumHotwords: UInt64

            enum CodingKeys: String, CodingKey, CaseIterable {
                case directory
                case adapterID = "adapter_id"
                case artifactID = "artifact_id"
                case contentSHA256 = "content_sha256"
                case maximumHotwords = "maximum_hotwords"
            }

            init(from decoder: Decoder) throws {
                let object = try MeasurementPolicyStrictJSONObject(
                    decoder,
                    context: .evaluationArtifact,
                    expectedKeys: Set(CodingKeys.allCases.map(\.rawValue))
                )
                directory = try object.decode(
                    String.self,
                    forKey: CodingKeys.directory.rawValue
                )
                adapterID = try object.decode(
                    String.self,
                    forKey: CodingKeys.adapterID.rawValue
                )
                artifactID = try object.decode(
                    String.self,
                    forKey: CodingKeys.artifactID.rawValue
                )
                contentSHA256 = try object.decode(
                    String.self,
                    forKey: CodingKeys.contentSHA256.rawValue
                )
                maximumHotwords = try object.decode(
                    UInt64.self,
                    forKey: CodingKeys.maximumHotwords.rawValue
                )
            }
        }

        let schemaVersion: Int
        let enabled: Bool
        let coldTrials: UInt64
        let controlProtocol: ProtocolIdentity
        let controlSocketPath: String
        let controlSessionNonce: String
        let collector: Collector
        let driver: Driver
        let evaluationArtifact: EvaluationArtifact
        let helper: Helper
        let releasePolicySHA256: String

        enum CodingKeys: String, CodingKey, CaseIterable {
            case schemaVersion = "schema_version"
            case enabled
            case coldTrials = "cold_trials"
            case controlProtocol = "control_protocol"
            case controlSocketPath = "control_socket_path"
            case controlSessionNonce = "control_session_nonce"
            case collector
            case driver
            case evaluationArtifact = "evaluation_artifact"
            case helper
            case releasePolicySHA256 = "release_policy_sha256"
        }

        init(from decoder: Decoder) throws {
            let object = try MeasurementPolicyStrictJSONObject(
                decoder,
                context: .policy,
                expectedKeys: Set(CodingKeys.allCases.map(\.rawValue))
            )
            schemaVersion = try object.decode(
                Int.self,
                forKey: CodingKeys.schemaVersion.rawValue
            )
            enabled = try object.decode(
                Bool.self,
                forKey: CodingKeys.enabled.rawValue
            )
            coldTrials = try object.decode(
                UInt64.self,
                forKey: CodingKeys.coldTrials.rawValue
            )
            controlProtocol = try object.decode(
                ProtocolIdentity.self,
                forKey: CodingKeys.controlProtocol.rawValue
            )
            controlSocketPath = try object.decode(
                String.self,
                forKey: CodingKeys.controlSocketPath.rawValue
            )
            controlSessionNonce = try object.decode(
                String.self,
                forKey: CodingKeys.controlSessionNonce.rawValue
            )
            collector = try object.decode(
                Collector.self,
                forKey: CodingKeys.collector.rawValue
            )
            driver = try object.decode(
                Driver.self,
                forKey: CodingKeys.driver.rawValue
            )
            evaluationArtifact = try object.decode(
                EvaluationArtifact.self,
                forKey: CodingKeys.evaluationArtifact.rawValue
            )
            helper = try object.decode(
                Helper.self,
                forKey: CodingKeys.helper.rawValue
            )
            releasePolicySHA256 = try object.decode(
                String.self,
                forKey: CodingKeys.releasePolicySHA256.rawValue
            )
        }
    }
}

private indirect enum MeasurementPolicyCanonicalJSON {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case object([String: Self])

    func encoded() -> String {
        switch self {
        case let .string(value):
            return Self.quote(value)
        case let .integer(value):
            return String(value)
        case let .boolean(value):
            return value ? "true" : "false"
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

private struct MeasurementPolicyJSONKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private struct MeasurementPolicyStrictJSONObject {
    private let container: KeyedDecodingContainer<MeasurementPolicyJSONKey>

    init(
        _ decoder: Decoder,
        context: VoicePerformanceMeasurementPolicyError.Object,
        expectedKeys: Set<String>
    ) throws {
        container = try decoder.container(
            keyedBy: MeasurementPolicyJSONKey.self
        )
        let actualKeys = Set(container.allKeys.map(\.stringValue))
        guard actualKeys.isSubset(of: expectedKeys) else {
            throw VoicePerformanceMeasurementPolicyError.unknownFields(context)
        }
        guard expectedKeys.isSubset(of: actualKeys) else {
            throw VoicePerformanceMeasurementPolicyError.missingFields(context)
        }
    }

    func decode<Value: Decodable>(
        _ type: Value.Type,
        forKey key: String
    ) throws -> Value {
        try container.decode(
            type,
            forKey: MeasurementPolicyJSONKey(stringValue: key)!
        )
    }
}
