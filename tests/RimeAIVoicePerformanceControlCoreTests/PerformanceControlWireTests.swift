import Foundation
import Testing
@testable import RimeAIVoicePerformanceControlCore

@Suite("Performance control canonical wire v2")
struct PerformanceControlWireTests {
    @Test("collector challenge round-trips as one bounded canonical frame")
    func collectorChallengeRoundTripsCanonically() throws {
        let frame = PerformanceControlWireFrame.challenge(
            peerRole: .driver,
            sessionID: try nonce("1"),
            planNonce: try nonce("2"),
            collectorNonce: try nonce("3")
        )

        let encoded = try frame.encodedCanonical()

        #expect(frame.sequence == 0)
        #expect(encoded.count <= PerformanceControlWireFrame.maximumEncodedBytes)
        #expect(
            String(decoding: encoded, as: UTF8.self)
                == #"{"collector_nonce":"3333333333333333333333333333333333333333333333333333333333333333","peer_role":"driver","plan_nonce":"2222222222222222222222222222222222222222222222222222222222222222","schema_version":2,"seq":0,"session_id":"1111111111111111111111111111111111111111111111111111111111111111","type":"challenge"}"#
        )
        #expect(try PerformanceControlWireFrame.decodeCanonical(encoded) == frame)
    }

    @Test("driver hello binds both challenge nonces and the sealed policy")
    func driverHelloRoundTripsCanonically() throws {
        let frame = PerformanceControlWireFrame.driverHello(
            sessionID: try nonce("1"),
            planNonce: try nonce("2"),
            collectorNonce: try nonce("3"),
            peerNonce: try nonce("4"),
            collectionProtocol: try PerformanceControlProtocolIdentity(
                sha256: String(repeating: "5", count: 64)
            ),
            driverPolicySHA256: try PerformanceControlSHA256(
                String(repeating: "6", count: 64)
            ),
            measurementPolicySHA256: try PerformanceControlSHA256(
                String(repeating: "7", count: 64)
            )
        )

        let encoded = try frame.encodedCanonical()

        #expect(frame.sequence == 0)
        #expect(
            String(decoding: encoded, as: UTF8.self)
                == #"{"collection_protocol":{"id":"rimeai-performance-control-v2","sha256":"5555555555555555555555555555555555555555555555555555555555555555"},"collector_nonce":"3333333333333333333333333333333333333333333333333333333333333333","driver_policy_sha256":"6666666666666666666666666666666666666666666666666666666666666666","measurement_policy_sha256":"7777777777777777777777777777777777777777777777777777777777777777","peer_nonce":"4444444444444444444444444444444444444444444444444444444444444444","plan_nonce":"2222222222222222222222222222222222222222222222222222222222222222","schema_version":2,"seq":0,"session_id":"1111111111111111111111111111111111111111111111111111111111111111","type":"driver_hello"}"#
        )
        #expect(try PerformanceControlWireFrame.decodeCanonical(encoded) == frame)
    }

    @Test("helper hello can attest only an unloaded helper")
    func helperHelloRoundTripsCanonically() throws {
        let frame = PerformanceControlWireFrame.helperHello(
            sessionID: try nonce("1"),
            planNonce: try nonce("2"),
            collectorNonce: try nonce("3"),
            peerNonce: try nonce("4"),
            measurementPolicySHA256: try PerformanceControlSHA256(
                String(repeating: "5", count: 64)
            ),
            releasePolicySHA256: try PerformanceControlSHA256(
                String(repeating: "6", count: 64)
            )
        )

        let encoded = try frame.encodedCanonical()

        #expect(frame.sequence == 0)
        #expect(
            String(decoding: encoded, as: UTF8.self)
                == #"{"collector_nonce":"3333333333333333333333333333333333333333333333333333333333333333","engine_state":"unloaded","measurement_policy_sha256":"5555555555555555555555555555555555555555555555555555555555555555","peer_nonce":"4444444444444444444444444444444444444444444444444444444444444444","plan_nonce":"2222222222222222222222222222222222222222222222222222222222222222","release_policy_sha256":"6666666666666666666666666666666666666666666666666666666666666666","schema_version":2,"seq":0,"session_id":"1111111111111111111111111111111111111111111111111111111111111111","type":"helper_hello"}"#
        )
        #expect(try PerformanceControlWireFrame.decodeCanonical(encoded) == frame)
    }

    @Test("cold-load frames preserve their causal ticket and reply binding")
    func coldLoadFramesRoundTripCanonically() throws {
        let sessionID = try nonce("1")
        let ticket = try nonce("2")
        let engine = try PerformanceControlEngineSummary(
            adapterID: ControlledPerformanceID("sherpa-onnx"),
            engineID: "sherpa-onnx@3333333333333333",
            artifactID: ControlledPerformanceID("voice-model-v1"),
            artifactContentSHA256: PerformanceControlSHA256(
                String(repeating: "3", count: 64)
            ),
            artifactGeneration: PerformanceControlArtifactGeneration(
                "11111111-1111-4111-8111-111111111111"
            ),
            capabilities: [
                ControlledPerformanceID("hotword_snapshot"),
                ControlledPerformanceID("local_asr"),
                ControlledPerformanceID("streaming"),
            ],
            networkPolicy: .offline,
            maximumHotwords: 32
        )
        let frames: [PerformanceControlWireFrame] = [
            .armColdLoad(sequence: 1, sessionID: sessionID, trial: 7),
            .loadEngine(
                sequence: 1,
                sessionID: sessionID,
                trial: 7,
                loadTicket: ticket
            ),
            .loadStarted(
                sequence: 1,
                sessionID: sessionID,
                replyTo: 1,
                trial: 7,
                loadTicket: ticket
            ),
            .loadStartedAck(
                sequence: 2,
                sessionID: sessionID,
                replyTo: 1,
                trial: 7,
                loadTicket: ticket
            ),
            .loadReady(
                sequence: 2,
                sessionID: sessionID,
                replyTo: 2,
                trial: 7,
                loadTicket: ticket,
                engine: engine
            ),
        ]

        for frame in frames {
            let encoded = try frame.encodedCanonical()
            #expect(encoded.count <= PerformanceControlWireFrame.maximumEncodedBytes)
            #expect(try PerformanceControlWireFrame.decodeCanonical(encoded) == frame)
        }
    }

    @Test("unsigned 64-bit fields round-trip without accepting bools or floats")
    func unsigned64BitFieldsAreSymmetricAndStrict() throws {
        let frame = PerformanceControlWireFrame.armColdLoad(
            sequence: 1,
            sessionID: try nonce("1"),
            trial: UInt64.max
        )
        let encoded = try frame.encodedCanonical()
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(text.contains(#""trial":18446744073709551615"#))
        #expect(try PerformanceControlWireFrame.decodeCanonical(encoded) == frame)
        for replacement in [#""trial":true"#, #""trial":1.0"#] {
            let malformed = text.replacingOccurrences(
                of: #""trial":18446744073709551615"#,
                with: replacement
            )
            #expect(throws: PerformanceControlError.invalidFrame) {
                try PerformanceControlWireFrame.decodeCanonical(
                    Data(malformed.utf8)
                )
            }
        }
    }

    @Test("wire decoder rejects non-canonical or ambiguous JSON")
    func wireDecoderRejectsAmbiguity() throws {
        let canonical = try PerformanceControlWireFrame.challenge(
            peerRole: .driver,
            sessionID: nonce("1"),
            planNonce: nonce("2"),
            collectorNonce: nonce("3")
        ).encodedCanonical()
        let text = String(decoding: canonical, as: UTF8.self)
        let malformed = [
            text.replacingOccurrences(
                of: #""type":"challenge""#,
                with: #""type":"challenge","type":"challenge""#
            ),
            text.replacingOccurrences(
                of: #""type":"challenge""#,
                with: #""type":"challenge","unknown":0"#
            ),
            text.replacingOccurrences(of: #""seq":0"#, with: #""seq":true"#),
            text.replacingOccurrences(of: #""seq":0"#, with: #""seq":0.0"#),
            text.replacingOccurrences(of: #""seq":0"#, with: #""seq":1"#),
            " \(text)",
        ]

        for value in malformed {
            #expect(throws: PerformanceControlError.self) {
                try PerformanceControlWireFrame.decodeCanonical(Data(value.utf8))
            }
        }
        for truncatedNumber in ["1", "1e", "1E", "1e+"] {
            #expect(throws: PerformanceControlError.invalidFrame) {
                try PerformanceControlWireFrame.decodeCanonical(
                    Data(truncatedNumber.utf8)
                )
            }
        }
        #expect(
            throws: PerformanceControlError.carriageReturnForbidden
        ) {
            try PerformanceControlWireFrame.decodeCanonical(
                canonical + Data([0x0D])
            )
        }
        #expect(throws: PerformanceControlError.frameTooLarge) {
            try PerformanceControlWireFrame.decodeCanonical(
                Data(
                    repeating: 0x20,
                    count: PerformanceControlWireFrame.maximumEncodedBytes + 1
                )
            )
        }
    }

    @Test("nonces and controlled identifiers are normalized and bounded")
    func identifiersAreStrict() {
        #expect(throws: PerformanceControlError.invalidNonce) {
            try PerformanceControlNonce("abcd")
        }
        #expect(throws: PerformanceControlError.invalidNonce) {
            try PerformanceControlNonce(String(repeating: "A", count: 64))
        }
        #expect(throws: PerformanceControlError.invalidNonce) {
            try PerformanceControlNonce(String(repeating: "g", count: 64))
        }
        #expect(throws: PerformanceControlError.invalidIdentifier) {
            try ControlledPerformanceID("e\u{301}")
        }
        #expect(throws: PerformanceControlError.invalidIdentifier) {
            try ControlledPerformanceID("helper\ninstance")
        }
    }

    @Test("load-ready accepts only the real offline product engine contract")
    func engineSummaryIsExact() throws {
        let adapterID = try ControlledPerformanceID("sherpa-onnx")
        let artifactSHA256 = try PerformanceControlSHA256(
            String(repeating: "3", count: 64)
        )
        let artifactID = try ControlledPerformanceID("voice-model-v1")
        let generation = try PerformanceControlArtifactGeneration(
            "11111111-1111-4111-8111-111111111111"
        )
        let capabilities = try [
            ControlledPerformanceID("hotword_snapshot"),
            ControlledPerformanceID("local_asr"),
            ControlledPerformanceID("streaming"),
        ]

        for invalidEngineID in [
            "product-local",
            "sherpa-onnx@3333333333333334",
        ] {
            #expect(throws: PerformanceControlError.invalidEngineSummary) {
                try PerformanceControlEngineSummary(
                    adapterID: adapterID,
                    engineID: invalidEngineID,
                    artifactID: artifactID,
                    artifactContentSHA256: artifactSHA256,
                    artifactGeneration: generation,
                    capabilities: capabilities,
                    networkPolicy: .offline,
                    maximumHotwords: 32
                )
            }
        }
        for invalidMaximum in [0, 129] {
            #expect(throws: PerformanceControlError.invalidEngineSummary) {
                try PerformanceControlEngineSummary(
                    adapterID: adapterID,
                    engineID: "sherpa-onnx@3333333333333333",
                    artifactID: artifactID,
                    artifactContentSHA256: artifactSHA256,
                    artifactGeneration: generation,
                    capabilities: capabilities,
                    networkPolicy: .offline,
                    maximumHotwords: UInt64(invalidMaximum)
                )
            }
        }
        #expect(throws: PerformanceControlError.invalidEngineSummary) {
            try PerformanceControlEngineSummary(
                adapterID: adapterID,
                engineID: "sherpa-onnx@3333333333333333",
                artifactID: artifactID,
                artifactContentSHA256: artifactSHA256,
                artifactGeneration: generation,
                capabilities: [
                    try ControlledPerformanceID("cloud_asr"),
                    try ControlledPerformanceID("streaming"),
                ],
                networkPolicy: .offline,
                maximumHotwords: 32
            )
        }
        #expect(throws: PerformanceControlError.invalidEngineSummary) {
            try PerformanceControlArtifactGeneration(
                "11111111-1111-4111-8111-11111111111A"
            )
        }

        let longAdapterID = try ControlledPerformanceID(
            String(repeating: "a", count: 128)
        )
        let fallbackSummary = try PerformanceControlEngineSummary(
            adapterID: longAdapterID,
            engineID: "product@3333333333333333",
            artifactID: artifactID,
            artifactContentSHA256: artifactSHA256,
            artifactGeneration: generation,
            capabilities: capabilities,
            networkPolicy: .offline,
            maximumHotwords: 32
        )
        #expect(fallbackSummary.engineID == "product@3333333333333333")
    }

    private func nonce(_ digit: Character) throws -> PerformanceControlNonce {
        try PerformanceControlNonce(String(repeating: digit, count: 64))
    }
}
