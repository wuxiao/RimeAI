import Foundation
import Testing
@testable import RimeAIVoicePerformanceControlCore

@Suite("Sealed performance-control driver policy v1")
struct SealedDriverPolicyTests {
    @Test("control protocol identity is the reviewed ID plus lowercase SHA-256")
    func controlProtocolIdentityIsExact() throws {
        let digest = String(repeating: "a", count: 64)
        let identity = try PerformanceControlProtocolIdentity(sha256: digest)

        #expect(
            PerformanceControlProtocolIdentity.requiredID
                == "rimeai-performance-control-v2"
        )
        #expect(identity.id == PerformanceControlProtocolIdentity.requiredID)
        #expect(identity.sha256 == digest)
        #expect(throws: PerformanceControlError.invalidProtocolIdentity) {
            try PerformanceControlProtocolIdentity(
                id: "fun.wwcn.rimeai.voice-performance-control.v2",
                sha256: digest
            )
        }
        #expect(throws: PerformanceControlError.invalidProtocolIdentity) {
            try PerformanceControlProtocolIdentity(
                sha256: String(repeating: "A", count: 64)
            )
        }
    }

    @Test("tracer policy has exactly the two non-release control capabilities")
    func tracerPolicyIsExactAndFailClosed() throws {
        let protocolIdentity = try PerformanceControlProtocolIdentity(
            sha256: String(repeating: "a", count: 64)
        )
        let data = Data(
            (#"{"capabilities":["authenticated_control","lazy_load_ticket"],"control_protocol":{"id":"rimeai-performance-control-v2","sha256":""#
                + String(repeating: "a", count: 64)
                + #""},"qualification":"tracer","schema_version":1}"#).utf8
        )

        let policy = try SealedPerformanceControlDriverPolicy.decodeCanonical(
            data,
            expectedControlProtocol: protocolIdentity
        )

        #expect(policy.qualification == .tracer)
        #expect(
            policy.capabilities == [
                .authenticatedControl,
                .lazyLoadTicket,
            ]
        )
        #expect(policy.controlProtocol == protocolIdentity)
        #expect(policy.canonicalSHA256.rawValue.utf8.count == 64)
        #expect(!policy.authenticatedProductionDriver)
    }

    @Test("production policy shape parses without granting production auth")
    func productionShapeDoesNotGrantEligibility() throws {
        let protocolIdentity = try PerformanceControlProtocolIdentity(
            sha256: String(repeating: "a", count: 64)
        )
        let data = policyData(
            capabilities: [
                "authenticated_control",
                "corpus_sessions",
                "helper_generation_rotation",
                "keyboard_phases",
                "late_challenges",
                "lazy_load_ticket",
            ],
            qualification: "production"
        )

        let policy = try SealedPerformanceControlDriverPolicy.decodeCanonical(
            data,
            expectedControlProtocol: protocolIdentity
        )

        #expect(policy.qualification == .production)
        #expect(
            policy.capabilities
                == SealedPerformanceControlDriverPolicy.productionCapabilities
        )
        #expect(!policy.authenticatedProductionDriver)
    }

    @Test("policy rejects capability drift and ambiguous JSON")
    func policyRejectsDrift() throws {
        let protocolIdentity = try PerformanceControlProtocolIdentity(
            sha256: String(repeating: "a", count: 64)
        )
        let canonical = policyData(
            capabilities: ["authenticated_control", "lazy_load_ticket"],
            qualification: "tracer"
        )
        let text = String(decoding: canonical, as: UTF8.self)
        let invalid = [
            policyData(
                capabilities: [
                    "authenticated_control",
                    "corpus_sessions",
                    "lazy_load_ticket",
                ],
                qualification: "tracer"
            ),
            Data(
                text.replacingOccurrences(
                    of: #""schema_version":1"#,
                    with: #""schema_version":true"#
                ).utf8
            ),
            Data(
                text.replacingOccurrences(
                    of: #""schema_version":1"#,
                    with: #""schema_version":1.0"#
                ).utf8
            ),
            Data(
                text.replacingOccurrences(
                    of: #""qualification":"tracer""#,
                    with: #""qualification":"tracer","unknown":0"#
                ).utf8
            ),
            Data(
                text.replacingOccurrences(
                    of: #""qualification":"tracer""#,
                    with: #""qualification":"tracer","qualification":"tracer""#
                ).utf8
            ),
        ]

        for data in invalid {
            #expect(throws: PerformanceControlError.self) {
                try SealedPerformanceControlDriverPolicy.decodeCanonical(
                    data,
                    expectedControlProtocol: protocolIdentity
                )
            }
        }
        #expect(throws: PerformanceControlError.controlProtocolMismatch) {
            try SealedPerformanceControlDriverPolicy.decodeCanonical(
                canonical,
                expectedControlProtocol: PerformanceControlProtocolIdentity(
                    sha256: String(repeating: "b", count: 64)
                )
            )
        }
    }

    private func policyData(
        capabilities: [String],
        qualification: String
    ) -> Data {
        let capabilityJSON = capabilities.map { "\"\($0)\"" }
            .joined(separator: ",")
        return Data(
            ("{\"capabilities\":[\(capabilityJSON)],"
                + #""control_protocol":{"id":"rimeai-performance-control-v2","sha256":""#
                + String(repeating: "a", count: 64)
                + #""},"qualification":""#
                + qualification
                + #"","schema_version":1}"#).utf8
        )
    }
}
