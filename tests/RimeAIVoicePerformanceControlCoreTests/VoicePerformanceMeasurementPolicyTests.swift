import CryptoKit
import Foundation
import Testing
@testable import RimeAIVoicePerformanceControlCore

@Suite("Sealed voice performance measurement policy v2")
struct VoicePerformanceMeasurementPolicyTests {
    @Test("canonical schema-v2 policy derives the complete tracer contract")
    func canonicalPolicyDecodesAsTracerOnlyAuthority() throws {
        let policy = try VoicePerformanceMeasurementPolicy.decodeCanonical(
            canonicalPolicyData()
        )

        #expect(policy.schemaVersion == 2)
        #expect(policy.enabled)
        #expect(policy.coldTrials == 7)
        #expect(policy.controlProtocol.id == "rimeai-performance-control-v2")
        #expect(policy.controlProtocol.sha256 == String(repeating: "a", count: 64))
        #expect(policy.controlSocketPath == "/private/tmp/rimeai-performance.sock")
        #expect(policy.controlSessionNonce == String(repeating: "b", count: 64))
        #expect(
            policy.collector.expectedExecutablePath
                == "/usr/local/libexec/rimeai-voice-performance-collector"
        )
        #expect(policy.driver.policySHA256 == String(repeating: "0", count: 64))
        #expect(
            policy.helper.expectedExecutablePath
                == "/usr/local/libexec/rimeai-voice-helper"
        )
        #expect(
            policy.helper.expectedExecutableSHA256
                == String(repeating: "1", count: 64)
        )
        #expect(
            policy.helper.expectedSigningIdentifier
                == "fun.wwcn.rimeai.voice-helper"
        )
        #expect(policy.helper.expectedTeamIdentifier == "TEAMID1234")
        #expect(policy.helper.expectedCDHash == String(repeating: "3", count: 40))
        #expect(policy.releasePolicySHA256 == String(repeating: "2", count: 64))
        #expect(
            policy.evaluationArtifact.directory
                == "/private/tmp/rimeai-evaluation-artifact"
        )
        #expect(policy.evaluationArtifact.adapterID == "sherpa-onnx")
        #expect(policy.evaluationArtifact.artifactID == "voice-model")
        #expect(
            policy.evaluationArtifact.contentSHA256
                == String(repeating: "4", count: 64)
        )
        #expect(policy.evaluationArtifact.maximumHotwords == 64)
        #expect(policy.expectedEngine.adapterID.rawValue == "sherpa-onnx")
        #expect(policy.expectedEngine.artifactID.rawValue == "voice-model")
        #expect(
            policy.expectedEngine.engineID
                == "sherpa-onnx@" + String(repeating: "4", count: 16)
        )
        #expect(
            policy.expectedEngine.capabilities.map(\.rawValue) == [
                "hotword_snapshot", "local_asr", "streaming",
            ]
        )
        #expect(policy.expectedEngine.networkPolicy == .offline)
        #expect(policy.expectedEngine.maximumHotwords == 64)
        #expect(policy.qualification == .tracer)
        #expect(!policy.authenticatedProductionDriver)
    }

    @Test("unknown top-level authority is rejected")
    func unknownTopLevelAuthorityIsRejected() {
        for authority in [
            #""qualification":"production""#,
            #""authenticated_production_driver":true"#,
            #""helper_executable_sha256":"legacy-scalar""#,
        ] {
            let policy = replacing(
                #""schema_version":2}"#,
                with: #""schema_version":2,"# + authority + "}"
            )

            #expect(
                throws: VoicePerformanceMeasurementPolicyError.unknownFields(
                    .policy
                )
            ) {
                try VoicePerformanceMeasurementPolicy.decodeCanonical(policy)
            }
        }
    }

    @Test("unknown nested identity fields are rejected at every boundary")
    func unknownNestedIdentityFieldsAreRejected() {
        let cases: [(
            Data,
            VoicePerformanceMeasurementPolicyError.Object
        )] = [
            (
                replacing(
                    String(repeating: "a", count: 64) + #""}"#,
                    with: String(repeating: "a", count: 64)
                        + #"","extra":true}"#
                ),
                .controlProtocol
            ),
            (
                replacing(
                    #""expected_team_identifier":"TEAMID1234"},"control_protocol""#,
                    with: #""expected_team_identifier":"TEAMID1234","extra":true},"control_protocol""#
                ),
                .collector
            ),
            (
                replacing(
                    String(repeating: "0", count: 64) + #""},"enabled""#,
                    with: String(repeating: "0", count: 64)
                        + #"","extra":true},"enabled""#
                ),
                .driver
            ),
            (
                replacing(
                    #""expected_team_identifier":"TEAMID1234"},"release_policy_sha256""#,
                    with: #""expected_team_identifier":"TEAMID1234","extra":true},"release_policy_sha256""#
                ),
                .helper
            ),
            (
                replacing(
                    #""maximum_hotwords":64},"helper""#,
                    with: #""maximum_hotwords":64,"extra":true},"helper""#
                ),
                .evaluationArtifact
            ),
        ]

        for (data, context) in cases {
            #expect(
                throws: VoicePerformanceMeasurementPolicyError.unknownFields(
                    context
                )
            ) {
                try VoicePerformanceMeasurementPolicy.decodeCanonical(data)
            }
        }
    }

    @Test("duplicate keys and non-canonical bytes are rejected")
    func duplicateKeysAndNonCanonicalBytesAreRejected() {
        let duplicateTopLevel = replacing(
            #""enabled":true"#,
            with: #""enabled":true,"enabled":true"#
        )
        let duplicateNested = replacing(
            #""id":"rimeai-performance-control-v2""#,
            with: #""id":"rimeai-performance-control-v2","id":"rimeai-performance-control-v2""#
        )
        let leadingWhitespace = Data(
            [0x20] + canonicalPolicyData()
        )
        let evaluationArtifactField = canonicalEvaluationArtifactField()
        let unsorted = replacing(
            #""enabled":true,"# + evaluationArtifactField,
            with: evaluationArtifactField + ",\"enabled\":true"
        )

        for data in [
            duplicateTopLevel,
            duplicateNested,
            leadingWhitespace,
            unsorted,
        ] {
            #expect(
                throws:
                    VoicePerformanceMeasurementPolicyError.nonCanonicalJSON
            ) {
                try VoicePerformanceMeasurementPolicy.decodeCanonical(data)
            }
        }
    }

    @Test("enabled false fails closed")
    func enabledFalseFailsClosed() {
        #expect(
            throws: VoicePerformanceMeasurementPolicyError.enabledRequired
        ) {
            try VoicePerformanceMeasurementPolicy.decodeCanonical(
                replacing(#""enabled":true"#, with: #""enabled":false"#)
            )
        }
    }

    @Test("schema version is exactly integer two and v1 fails closed")
    func schemaVersionIsExactlyIntegerTwo() {
        #expect(
            throws: VoicePerformanceMeasurementPolicyError.unsupportedSchema
        ) {
            try VoicePerformanceMeasurementPolicy.decodeCanonical(
                replacing(#""schema_version":2"#, with: #""schema_version":1"#)
            )
        }

        for invalid in ["true", "2.0"] {
            #expect(throws: (any Error).self) {
                try VoicePerformanceMeasurementPolicy.decodeCanonical(
                    replacing(
                        #""schema_version":2"#,
                        with: #""schema_version":"# + invalid
                    )
                )
            }
        }
    }

    @Test("cold trial count is an exact bounded integer")
    func coldTrialCountIsExactAndBounded() throws {
        for accepted in [1, 32] {
            let policy = try VoicePerformanceMeasurementPolicy.decodeCanonical(
                replacing(#""cold_trials":7"#, with: "\"cold_trials\":\(accepted)")
            )
            #expect(policy.coldTrials == UInt64(accepted))
        }
        for invalid in ["0", "33", "7.0", "true"] {
            #expect(throws: (any Error).self) {
                try VoicePerformanceMeasurementPolicy.decodeCanonical(
                    replacing(
                        #""cold_trials":7"#,
                        with: #""cold_trials":"# + invalid
                    )
                )
            }
        }
    }

    @Test("evaluation artifact fields are exact and bounded")
    func evaluationArtifactFieldsAreExactAndBounded() throws {
        let maximumPath = "/" + String(repeating: "e", count: 4_095)
        #expect(
            try VoicePerformanceMeasurementPolicy.decodeCanonical(
                replacingEvaluationDirectory(with: maximumPath)
            ).evaluationArtifact.directory == maximumPath
        )
        for invalidPath in [
            "/",
            "relative/artifact",
            "/private/tmp/../tmp/artifact",
            "/private/tmp/e\u{301}",
            "/private/tmp/a\\u0000",
            "/private/tmp/a\\n",
            "/private/tmp/a\\u007f",
            "/" + String(repeating: "e", count: 4_096),
        ] {
            #expect(
                throws: VoicePerformanceMeasurementPolicyError.invalidField(
                    .evaluationArtifactDirectory
                )
            ) {
                try VoicePerformanceMeasurementPolicy.decodeCanonical(
                    replacingEvaluationDirectory(with: invalidPath)
                )
            }
        }

        let invalidFields: [(
            Data,
            VoicePerformanceMeasurementPolicyError.Field
        )] = [
            (
                replacingJSONField(
                    "adapter_id",
                    current: "sherpa-onnx",
                    with: "invalid/id"
                ),
                .evaluationArtifactAdapterID
            ),
            (
                replacingJSONField(
                    "artifact_id",
                    current: "voice-model",
                    with: ""
                ),
                .evaluationArtifactID
            ),
            (
                replacingJSONField(
                    "content_sha256",
                    current: String(repeating: "4", count: 64),
                    with: String(repeating: "A", count: 64)
                ),
                .evaluationArtifactContentSHA256
            ),
        ]
        for (data, field) in invalidFields {
            #expect(
                throws: VoicePerformanceMeasurementPolicyError.invalidField(
                    field
                )
            ) {
                try VoicePerformanceMeasurementPolicy.decodeCanonical(data)
            }
        }
        for invalid in ["0", "129", "64.0", "false"] {
            #expect(throws: (any Error).self) {
                try VoicePerformanceMeasurementPolicy.decodeCanonical(
                    replacing(
                        #""maximum_hotwords":64"#,
                        with: #""maximum_hotwords":"# + invalid
                    )
                )
            }
        }
    }

    @Test("control socket path enforces lexical boundary only")
    func controlSocketPathEnforcesLexicalBoundaryOnly() throws {
        let maximumPath = "/" + String(repeating: "s", count: 102)
        let accepted = try VoicePerformanceMeasurementPolicy.decodeCanonical(
            replacingSocketPath(with: maximumPath)
        )
        #expect(accepted.controlSocketPath == maximumPath)

        let invalidPaths = [
            "/",
            "relative/socket.sock",
            "/private/tmp/../tmp/socket.sock",
            "/private/tmp/e\u{301}.sock",
            "/private/tmp/a\\u0000.sock",
            "/private/tmp/a\\n.sock",
            "/private/tmp/a\\r.sock",
            "/private/tmp/a\\t.sock",
            "/private/tmp/a\\u007f.sock",
            "/" + String(repeating: "s", count: 103),
        ]
        for path in invalidPaths {
            #expect(
                throws: VoicePerformanceMeasurementPolicyError.invalidField(
                    .controlSocketPath
                )
            ) {
                try VoicePerformanceMeasurementPolicy.decodeCanonical(
                    replacingSocketPath(with: path)
                )
            }
        }
    }

    @Test("collector, driver, and helper paths are bounded canonical absolutes")
    func executablePathsAreBoundedCanonicalAbsolutes() throws {
        let maximumPath = "/" + String(repeating: "x", count: 4_095)
        let collector = try VoicePerformanceMeasurementPolicy.decodeCanonical(
            replacingCollectorPath(with: maximumPath)
        )
        let driver = try VoicePerformanceMeasurementPolicy.decodeCanonical(
            replacingDriverPath(with: maximumPath)
        )
        let helper = try VoicePerformanceMeasurementPolicy.decodeCanonical(
            replacingHelperPath(with: maximumPath)
        )
        #expect(collector.collector.expectedExecutablePath == maximumPath)
        #expect(driver.driver.expectedExecutablePath == maximumPath)
        #expect(helper.helper.expectedExecutablePath == maximumPath)

        let invalidPaths = [
            "/",
            "usr/local/bin/driver",
            "/usr/local/bin/../bin/driver",
            "/usr/local/bin/e\u{301}",
            "/usr/local/bin/a\\t",
            "/usr/local/bin/a\\u007f",
            "/" + String(repeating: "x", count: 4_096),
        ]
        for path in invalidPaths {
            #expect(
                throws: VoicePerformanceMeasurementPolicyError.invalidField(
                    .collectorExpectedExecutablePath
                )
            ) {
                try VoicePerformanceMeasurementPolicy.decodeCanonical(
                    replacingCollectorPath(with: path)
                )
            }
            #expect(
                throws: VoicePerformanceMeasurementPolicyError.invalidField(
                    .driverExpectedExecutablePath
                )
            ) {
                try VoicePerformanceMeasurementPolicy.decodeCanonical(
                    replacingDriverPath(with: path)
                )
            }
            #expect(
                throws: VoicePerformanceMeasurementPolicyError.invalidField(
                    .helperExpectedExecutablePath
                )
            ) {
                try VoicePerformanceMeasurementPolicy.decodeCanonical(
                    replacingHelperPath(with: path)
                )
            }
        }
    }

    @Test("control session nonce is exactly 64 lowercase hex characters")
    func controlSessionNonceIsExactly64LowercaseHex() {
        let invalidNonces = [
            String(repeating: "b", count: 63),
            String(repeating: "b", count: 65),
            String(repeating: "B", count: 64),
            String(repeating: "g", count: 64),
        ]
        for nonce in invalidNonces {
            #expect(
                throws: VoicePerformanceMeasurementPolicyError.invalidField(
                    .controlSessionNonce
                )
            ) {
                try VoicePerformanceMeasurementPolicy.decodeCanonical(
                    replacing(
                        String(repeating: "b", count: 64),
                        with: nonce
                    )
                )
            }
        }
    }

    @Test("protocol identity is the frozen v2 identity")
    func protocolIdentityIsFrozenV2Identity() {
        #expect(throws: PerformanceControlError.invalidProtocolIdentity) {
            try VoicePerformanceMeasurementPolicy.decodeCanonical(
                replacingJSONField(
                    "id",
                    current: "rimeai-performance-control-v2",
                    with: "rimeai-performance-control-v1"
                )
            )
        }
        #expect(throws: PerformanceControlError.invalidProtocolIdentity) {
            try VoicePerformanceMeasurementPolicy.decodeCanonical(
                replacingJSONField(
                    "sha256",
                    current: String(repeating: "a", count: 64),
                    with: String(repeating: "A", count: 64)
                )
            )
        }
    }

    @Test("executable and policy digests use exact lowercase hex widths")
    func identityDigestsUseExactLowercaseHexWidths() {
        let cases: [(Data, VoicePerformanceMeasurementPolicyError.Field)] = [
            (
                replacingJSONField(
                    "expected_executable_sha256",
                    current: String(repeating: "c", count: 64),
                    with: String(repeating: "c", count: 63)
                ),
                .collectorExpectedExecutableSHA256
            ),
            (
                replacingJSONField(
                    "expected_cdhash",
                    current: String(repeating: "d", count: 40),
                    with: String(repeating: "D", count: 40)
                ),
                .collectorExpectedCDHash
            ),
            (
                replacingJSONField(
                    "expected_executable_sha256",
                    current: String(repeating: "e", count: 64),
                    with: String(repeating: "e", count: 65)
                ),
                .driverExpectedExecutableSHA256
            ),
            (
                replacingJSONField(
                    "expected_cdhash",
                    current: String(repeating: "f", count: 40),
                    with: String(repeating: "f", count: 39)
                ),
                .driverExpectedCDHash
            ),
            (
                replacingJSONField(
                    "policy_sha256",
                    current: String(repeating: "0", count: 64),
                    with: String(repeating: "G", count: 64)
                ),
                .driverPolicySHA256
            ),
            (
                replacingJSONField(
                    "expected_executable_sha256",
                    current: String(repeating: "1", count: 64),
                    with: String(repeating: "1", count: 63)
                ),
                .helperExpectedExecutableSHA256
            ),
            (
                replacingJSONField(
                    "expected_cdhash",
                    current: String(repeating: "3", count: 40),
                    with: String(repeating: "3", count: 41)
                ),
                .helperExpectedCDHash
            ),
            (
                replacingJSONField(
                    "release_policy_sha256",
                    current: String(repeating: "2", count: 64),
                    with: String(repeating: "2", count: 65)
                ),
                .releasePolicySHA256
            ),
        ]

        for (data, field) in cases {
            #expect(
                throws: VoicePerformanceMeasurementPolicyError.invalidField(
                    field
                )
            ) {
                try VoicePerformanceMeasurementPolicy.decodeCanonical(data)
            }
        }
    }

    @Test("signing identities are fixed and share one valid Team ID")
    func signingIdentitiesAreFixedAndShareOneValidTeamID() {
        let invalidFields: [
            (Data, VoicePerformanceMeasurementPolicyError.Field)
        ] = [
            (
                replacingJSONField(
                    "expected_signing_identifier",
                    current:
                        "fun.wwcn.rimeai.voice-performance-collector",
                    with: "com.example.collector"
                ),
                .collectorExpectedSigningIdentifier
            ),
            (
                replacingJSONField(
                    "expected_signing_identifier",
                    current: "fun.wwcn.rimeai.voice-performance-driver",
                    with: "fun.wwcn.rimeai.voice-performance-drivér"
                ),
                .driverExpectedSigningIdentifier
            ),
            (
                replacingJSONField(
                    "expected_signing_identifier",
                    current: "fun.wwcn.rimeai.voice-helper",
                    with: "com.example.helper"
                ),
                .helperExpectedSigningIdentifier
            ),
            (
                replacingFirstTeamIdentifier(with: "teamid1234"),
                .collectorExpectedTeamIdentifier
            ),
            (
                replacingLastTeamIdentifier(with: "TEAM-ID123"),
                .driverExpectedTeamIdentifier
            ),
            (
                replacingLastTeamIdentifier(with: "TEAMID123"),
                .driverExpectedTeamIdentifier
            ),
            (
                replacingHelperTeamIdentifier(with: "helper1234"),
                .helperExpectedTeamIdentifier
            ),
        ]
        for (data, field) in invalidFields {
            #expect(
                throws: VoicePerformanceMeasurementPolicyError.invalidField(
                    field
                )
            ) {
                try VoicePerformanceMeasurementPolicy.decodeCanonical(data)
            }
        }

        #expect(
            throws:
                VoicePerformanceMeasurementPolicyError.teamIdentifierMismatch
        ) {
            try VoicePerformanceMeasurementPolicy.decodeCanonical(
                replacingLastTeamIdentifier(with: "OTHERID123")
            )
        }
        #expect(
            throws:
                VoicePerformanceMeasurementPolicyError.teamIdentifierMismatch
        ) {
            try VoicePerformanceMeasurementPolicy.decodeCanonical(
                replacingHelperTeamIdentifier(with: "OTHERID123")
            )
        }
    }

    @Test("missing fields are rejected at every object boundary")
    func missingFieldsAreRejectedAtEveryObjectBoundary() {
        let protocolID = #""id":"rimeai-performance-control-v2","#
        let collectorCDHash = #""expected_cdhash":""#
            + String(repeating: "d", count: 40) + #"","#
        let helperCDHash = #""expected_cdhash":""#
            + String(repeating: "3", count: 40) + #"","#
        let driverPolicySHA = ",\"policy_sha256\":\""
            + String(repeating: "0", count: 64) + "\""
        let cases: [(
            Data,
            VoicePerformanceMeasurementPolicyError.Object
        )] = [
            (replacing(#""enabled":true,"#, with: ""), .policy),
            (replacing(protocolID, with: ""), .controlProtocol),
            (replacing(collectorCDHash, with: ""), .collector),
            (replacing(driverPolicySHA, with: ""), .driver),
            (replacing(helperCDHash, with: ""), .helper),
            (replacing("," + canonicalHelperField(), with: ""), .policy),
            (
                replacing("," + canonicalEvaluationArtifactField(), with: ""),
                .policy
            ),
            (
                replacing(#""adapter_id":"sherpa-onnx","# , with: ""),
                .evaluationArtifact
            ),
        ]

        for (data, context) in cases {
            #expect(
                throws: VoicePerformanceMeasurementPolicyError.missingFields(
                    context
                )
            ) {
                try VoicePerformanceMeasurementPolicy.decodeCanonical(data)
            }
        }
    }

    @Test("policy input is bounded and carriage-return free")
    func policyInputIsBoundedAndCarriageReturnFree() {
        #expect(throws: (any Error).self) {
            try VoicePerformanceMeasurementPolicy.decodeCanonical(Data())
        }
        #expect(throws: (any Error).self) {
            try VoicePerformanceMeasurementPolicy.decodeCanonical(
                Data(repeating: 0x20, count: 65_537)
            )
        }
        var withCarriageReturn = canonicalPolicyData()
        withCarriageReturn.append(0x0D)
        #expect(
            throws:
                VoicePerformanceMeasurementPolicyError.carriageReturnForbidden
        ) {
            try VoicePerformanceMeasurementPolicy.decodeCanonical(
                withCarriageReturn
            )
        }
    }

    @Test("canonical SHA-256 is domain-separated and mutation-sensitive")
    func canonicalSHA256IsDomainSeparatedAndMutationSensitive() throws {
        let canonical = canonicalPolicyData()
        let policy = try VoicePerformanceMeasurementPolicy.decodeCanonical(
            canonical
        )
        #expect(
            policy.canonicalSHA256
                == expectedMeasurementPolicySHA256(for: canonical)
        )
        #expect(policy.canonicalSHA256 != sha256Hex(canonical))

        let helperMutatedCanonical = replacingJSONField(
            "expected_executable_sha256",
            current: String(repeating: "1", count: 64),
            with: String(repeating: "4", count: 64)
        )
        let mutated = try VoicePerformanceMeasurementPolicy.decodeCanonical(
            helperMutatedCanonical
        )
        #expect(mutated.canonicalSHA256 != policy.canonicalSHA256)
        #expect(
            mutated.canonicalSHA256
                == expectedMeasurementPolicySHA256(
                    for: helperMutatedCanonical
                )
        )

        let artifactMutatedCanonical = replacingJSONField(
            "content_sha256",
            current: String(repeating: "4", count: 64),
            with: String(repeating: "5", count: 64)
        )
        let artifactMutated = try VoicePerformanceMeasurementPolicy
            .decodeCanonical(artifactMutatedCanonical)
        #expect(artifactMutated.canonicalSHA256 != policy.canonicalSHA256)
        #expect(
            artifactMutated.expectedEngine.engineID
                == "sherpa-onnx@" + String(repeating: "5", count: 16)
        )

        let trialsMutatedCanonical = replacing(
            #""cold_trials":7"#,
            with: #""cold_trials":8"#
        )
        let trialsMutated = try VoicePerformanceMeasurementPolicy
            .decodeCanonical(trialsMutatedCanonical)
        #expect(trialsMutated.canonicalSHA256 != policy.canonicalSHA256)
    }
}

private func canonicalPolicyData() -> Data {
    Data(
        (#"{"cold_trials":7,"collector":{"expected_cdhash":""#
            + String(repeating: "d", count: 40)
            + #"","expected_executable_path":"/usr/local/libexec/rimeai-voice-performance-collector","expected_executable_sha256":""#
            + String(repeating: "c", count: 64)
            + #"","expected_signing_identifier":"fun.wwcn.rimeai.voice-performance-collector","expected_team_identifier":"TEAMID1234"},"control_protocol":{"id":"rimeai-performance-control-v2","sha256":""#
            + String(repeating: "a", count: 64)
            + #""},"control_session_nonce":""#
            + String(repeating: "b", count: 64)
            + #"","control_socket_path":"/private/tmp/rimeai-performance.sock","driver":{"expected_cdhash":""#
            + String(repeating: "f", count: 40)
            + #"","expected_executable_path":"/usr/local/bin/rimeai-voice-performance-driver","expected_executable_sha256":""#
            + String(repeating: "e", count: 64)
            + #"","expected_signing_identifier":"fun.wwcn.rimeai.voice-performance-driver","expected_team_identifier":"TEAMID1234","policy_sha256":""#
            + String(repeating: "0", count: 64)
            + #""},"enabled":true,"evaluation_artifact":{"adapter_id":"sherpa-onnx","artifact_id":"voice-model","content_sha256":""#
            + String(repeating: "4", count: 64)
            + #"","directory":"/private/tmp/rimeai-evaluation-artifact","maximum_hotwords":64},"helper":{"expected_cdhash":""#
            + String(repeating: "3", count: 40)
            + #"","expected_executable_path":"/usr/local/libexec/rimeai-voice-helper","expected_executable_sha256":""#
            + String(repeating: "1", count: 64)
            + #"","expected_signing_identifier":"fun.wwcn.rimeai.voice-helper","expected_team_identifier":"TEAMID1234"},"release_policy_sha256":""#
            + String(repeating: "2", count: 64)
            + #"","schema_version":2}"#).utf8
    )
}

private func replacing(_ oldValue: String, with newValue: String) -> Data {
    let source = String(decoding: canonicalPolicyData(), as: UTF8.self)
    return Data(source.replacingOccurrences(of: oldValue, with: newValue).utf8)
}

private func replacingSocketPath(with path: String) -> Data {
    replacing(
        "/private/tmp/rimeai-performance.sock",
        with: path
    )
}

private func replacingCollectorPath(with path: String) -> Data {
    replacing(
        "/usr/local/libexec/rimeai-voice-performance-collector",
        with: path
    )
}

private func replacingDriverPath(with path: String) -> Data {
    replacing(
        "/usr/local/bin/rimeai-voice-performance-driver",
        with: path
    )
}

private func replacingHelperPath(with path: String) -> Data {
    replacing(
        "/usr/local/libexec/rimeai-voice-helper",
        with: path
    )
}

private func replacingEvaluationDirectory(with path: String) -> Data {
    replacing(
        "/private/tmp/rimeai-evaluation-artifact",
        with: path
    )
}

private func replacingJSONField(
    _ field: String,
    current: String,
    with replacement: String
) -> Data {
    replacing(
        "\"\(field)\":\"\(current)\"",
        with: "\"\(field)\":\"\(replacement)\""
    )
}

private func replacingFirstTeamIdentifier(with replacement: String) -> Data {
    replacing(
        #""expected_team_identifier":"TEAMID1234"},"control_protocol""#,
        with: #""expected_team_identifier":""# + replacement
            + #""},"control_protocol""#
    )
}

private func replacingLastTeamIdentifier(with replacement: String) -> Data {
    replacing(
        #""expected_team_identifier":"TEAMID1234","policy_sha256""#,
        with: #""expected_team_identifier":""# + replacement
            + #"","policy_sha256""#
    )
}

private func replacingHelperTeamIdentifier(with replacement: String) -> Data {
    replacing(
        #""expected_team_identifier":"TEAMID1234"},"release_policy_sha256""#,
        with: #""expected_team_identifier":""# + replacement
            + #""},"release_policy_sha256""#
    )
}

private func canonicalHelperField() -> String {
    #""helper":{"expected_cdhash":""#
        + String(repeating: "3", count: 40)
        + #"","expected_executable_path":"/usr/local/libexec/rimeai-voice-helper","expected_executable_sha256":""#
        + String(repeating: "1", count: 64)
        + #"","expected_signing_identifier":"fun.wwcn.rimeai.voice-helper","expected_team_identifier":"TEAMID1234"}"#
}

private func canonicalEvaluationArtifactField() -> String {
    #""evaluation_artifact":{"adapter_id":"sherpa-onnx","artifact_id":"voice-model","content_sha256":""#
        + String(repeating: "4", count: 64)
        + #"","directory":"/private/tmp/rimeai-evaluation-artifact","maximum_hotwords":64}"#
}

private func expectedMeasurementPolicySHA256(for canonical: Data) -> String {
    var input = Data(
        "rimeai.voice-performance-measurement-policy.v2\0".utf8
    )
    input.append(canonical)
    return sha256Hex(input)
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
