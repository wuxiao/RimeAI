import CryptoKit
import Foundation
import Testing
@testable import RimeAIVoicePerformanceControlCore

@Suite("Code-owned performance control protocol contract")
struct PerformanceControlProtocolContractTests {
    @Test("canonical bytes are bounded single-line canonical UTF-8")
    func canonicalBytesAreBoundedSingleLineCanonicalUTF8() throws {
        let data = PerformanceControlProtocolContract.canonicalData

        #expect(!data.isEmpty)
        #expect(
            data.count
                <= PerformanceControlProtocolContract.maximumEncodedBytes
        )
        #expect(!data.contains(0x0A))
        #expect(!data.contains(0x0D))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(Data(text.utf8) == data)

        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let canonical = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        #expect(canonical == data)
        #expect(
            object["id"] as? String
                == PerformanceControlProtocolIdentity.requiredID
        )
        #expect(
            object["schema_version"] as? Int
                == PerformanceControlWireFrame.schemaVersion
        )
    }

    @Test("all eight public wire messages bind direction and exact keys")
    func allWireMessagesBindDirectionAndExactKeys() throws {
        let contract = try contractObject()
        let messages = try #require(
            contract["messages"] as? [[String: Any]]
        )
        #expect(messages.count == 8)

        let protocolIdentity = try PerformanceControlProtocolIdentity(
            sha256: String(repeating: "5", count: 64)
        )
        let sha6 = try PerformanceControlSHA256(
            String(repeating: "6", count: 64)
        )
        let sha7 = try PerformanceControlSHA256(
            String(repeating: "7", count: 64)
        )
        let session = try nonce("1")
        let plan = try nonce("2")
        let collector = try nonce("3")
        let peer = try nonce("4")
        let ticket = try nonce("8")
        let engine = try performanceEngine()
        let fixtures: [(PerformanceControlWireFrame, [String])] = [
            (
                .challenge(
                    peerRole: .driver,
                    sessionID: session,
                    planNonce: plan,
                    collectorNonce: collector
                ),
                ["collector_to_driver", "collector_to_helper"]
            ),
            (
                .driverHello(
                    sessionID: session,
                    planNonce: plan,
                    collectorNonce: collector,
                    peerNonce: peer,
                    collectionProtocol: protocolIdentity,
                    driverPolicySHA256: sha6,
                    measurementPolicySHA256: sha7
                ),
                ["driver_to_collector"]
            ),
            (
                .helperHello(
                    sessionID: session,
                    planNonce: plan,
                    collectorNonce: collector,
                    peerNonce: peer,
                    measurementPolicySHA256: sha6,
                    releasePolicySHA256: sha7
                ),
                ["helper_to_collector"]
            ),
            (
                .armColdLoad(sequence: 1, sessionID: session, trial: 1),
                ["driver_to_collector"]
            ),
            (
                .loadEngine(
                    sequence: 1,
                    sessionID: session,
                    trial: 1,
                    loadTicket: ticket
                ),
                ["collector_to_helper"]
            ),
            (
                .loadStarted(
                    sequence: 1,
                    sessionID: session,
                    replyTo: 1,
                    trial: 1,
                    loadTicket: ticket
                ),
                ["helper_to_collector"]
            ),
            (
                .loadStartedAck(
                    sequence: 2,
                    sessionID: session,
                    replyTo: 1,
                    trial: 1,
                    loadTicket: ticket
                ),
                ["collector_to_helper"]
            ),
            (
                .loadReady(
                    sequence: 2,
                    sessionID: session,
                    replyTo: 2,
                    trial: 1,
                    loadTicket: ticket,
                    engine: engine
                ),
                ["helper_to_collector"]
            ),
        ]

        for (frame, expectedDirections) in fixtures {
            let wire = try #require(
                JSONSerialization.jsonObject(
                    with: frame.encodedCanonical()
                ) as? [String: Any]
            )
            let type = try #require(wire["type"] as? String)
            let descriptor = try #require(
                messages.first { $0["type"] as? String == type }
            )
            #expect(descriptor["directions"] as? [String] == expectedDirections)
            #expect(
                descriptor["exact_keys"] as? [String]
                    == wire.keys.sorted()
            )

            let nested = try #require(
                descriptor["nested_exact_keys"] as? [String: [String]]
            )
            let actualNested = nested.keys.reduce(
                into: [String: [String]]()
            ) { result, key in
                if let object = wire[key] as? [String: Any] {
                    result[key] = object.keys.sorted()
                }
            }
            #expect(nested == actualNested)

            let fixed = try #require(
                descriptor["fixed_values"] as? [String: Any]
            )
            let actualFixed = fixed.keys.reduce(
                into: [String: Any]()
            ) { result, key in
                result[key] = wire[key]
            }
            #expect(actualFixed.count == fixed.count)
            let expectedFixedData = try JSONSerialization.data(
                withJSONObject: fixed,
                options: [.sortedKeys]
            )
            let actualFixedData = try JSONSerialization.data(
                withJSONObject: actualFixed,
                options: [.sortedKeys]
            )
            #expect(actualFixedData == expectedFixedData)
        }

        let describedTypes = messages.compactMap { $0["type"] as? String }
        #expect(Set(describedTypes).count == fixtures.count)
    }

    @Test("wire limits, causal rules, and state order match public v2 types")
    func wireLimitsCausalityAndStateOrderMatchPublicV2Types() throws {
        let contract = try contractObject()
        #expect(contract["authenticated_production_driver"] as? Bool == false)

        let frame = try #require(contract["frame"] as? [String: Any])
        #expect(frame["canonical_json"] as? Bool == true)
        #expect(frame["single_line_utf8"] as? Bool == true)
        #expect(frame["carriage_return_allowed"] as? Bool == false)
        #expect(frame["line_feed_allowed"] as? Bool == false)
        #expect(frame["unknown_keys_allowed"] as? Bool == false)
        #expect(
            frame["maximum_encoded_bytes"] as? Int
                == PerformanceControlWireFrame.maximumEncodedBytes
        )

        let formats = try #require(contract["formats"] as? [String: Any])
        let nonceFormat = try #require(
            formats["nonce"] as? [String: Any]
        )
        let ticketFormat = try #require(
            formats["load_ticket"] as? [String: Any]
        )
        let sha256Format = try #require(
            formats["sha256"] as? [String: Any]
        )
        #expect(nonceFormat["alphabet"] as? String == "lowercase_hex")
        #expect(ticketFormat["alphabet"] as? String == "lowercase_hex")
        #expect(sha256Format["alphabet"] as? String == "lowercase_hex")
        #expect(
            nonceFormat["encoded_utf8_bytes"] as? Int
                == PerformanceControlNonce.encodedLength
        )
        #expect(
            ticketFormat["encoded_utf8_bytes"] as? Int
                == PerformanceControlNonce.encodedLength
        )
        #expect(
            sha256Format["encoded_utf8_bytes"] as? Int
                == PerformanceControlSHA256.encodedLength
        )
        let controlledID = try #require(
            formats["controlled_id"] as? [String: Any]
        )
        #expect(
            controlledID["maximum_utf8_bytes"] as? Int
                == ControlledPerformanceID.maximumUTF8Bytes
        )

        let engineContract = try #require(
            contract["engine_contract"] as? [String: Any]
        )
        #expect(
            engineContract["capabilities"] as? [String]
                == ExpectedPerformanceControlEngine.evaluationCapabilities
        )
        #expect(
            engineContract["network_policy"] as? String
                == PerformanceControlNetworkPolicy.offline.rawValue
        )
        let hotwords = try #require(
            engineContract["maximum_hotwords"] as? [String: Any]
        )
        #expect(hotwords["minimum"] as? UInt64 == 1)
        #expect(hotwords["maximum"] as? UInt64 == 128)

        let trial = try #require(contract["trial"] as? [String: Any])
        #expect(
            trial["minimum"] as? UInt64
                == PerformanceControlSessionBinding.supportedTrials
                    .lowerBound
        )
        #expect(
            trial["maximum"] as? UInt64
                == PerformanceControlSessionBinding.supportedTrials
                    .upperBound
        )
        #expect(trial["order"] as? String == "strictly_ascending_from_one")

        let sessionBinding = try #require(
            contract["session_binding"] as? [String: Any]
        )
        #expect(
            sessionBinding["input"] as? String
                == "SHA-256(domain || control_session_nonce_bytes || trial)"
        )
        #expect(
            sessionBinding["trial_encoding"] as? String
                == "UInt64 big-endian"
        )
        let sessionDomain = try #require(
            sessionBinding["session_id_domain"] as? String
        )
        let planDomain = try #require(
            sessionBinding["plan_nonce_domain"] as? String
        )
        let zeroNonce = try PerformanceControlNonce(
            String(repeating: "0", count: 64)
        )
        let derived = try PerformanceControlSessionBinding.derive(
            controlSessionNonce: zeroNonce,
            trial: 1
        )
        #expect(
            derived.sessionID.rawValue
                == bindingDigest(domain: sessionDomain, trial: 1)
        )
        #expect(
            derived.planNonce.rawValue
                == bindingDigest(domain: planDomain, trial: 1)
        )

        let sequence = try #require(
            contract["sequence"] as? [String: Any]
        )
        #expect(sequence["handshake_seq"] as? UInt64 == 0)
        #expect(sequence["data_seq_minimum"] as? UInt64 == 1)
        #expect(sequence["next_data_seq"] as? String == "previous_plus_one")
        #expect(
            sequence["independent_directions"] as? [String] == [
                "collector_to_driver",
                "collector_to_helper",
                "driver_to_collector",
                "helper_to_collector",
            ]
        )
        #expect(
            sequence["reply_to"] as? [String: String] == [
                "load_ready": "load_started_ack.seq",
                "load_started": "load_engine.seq",
                "load_started_ack": "load_started.seq",
            ]
        )

        let stateMachine = try #require(
            contract["state_machine"] as? [String: Any]
        )
        #expect(
            stateMachine["successful_trial_order"] as? [String] == [
                PerformanceControlPhase.handshaking.rawValue,
                PerformanceControlPhase.waitingUnloadedHelper.rawValue,
                PerformanceControlPhase.loadArmed.rawValue,
                PerformanceControlPhase.loadStartedAcknowledged.rawValue,
                PerformanceControlPhase.loading.rawValue,
                PerformanceControlPhase.helperReady.rawValue,
            ]
        )
        #expect(
            stateMachine["failure"] as? String
                == "terminal_on_any_protocol_error"
        )
        #expect(
            stateMachine["failure_phase"] as? String
                == PerformanceControlPhase.failed.rawValue
        )

        let messages = try #require(
            contract["messages"] as? [[String: Any]]
        )
        let challenge = try #require(
            messages.first { $0["type"] as? String == "challenge" }
        )
        let challengeFixed = try #require(
            challenge["fixed_values"] as? [String: Any]
        )
        #expect(challengeFixed["schema_version"] as? Int == 2)
        #expect(challengeFixed["seq"] as? UInt64 == 0)
        #expect(
            challenge["peer_role_values"] as? [String] == [
                PerformanceControlPeerRole.driver.rawValue,
                PerformanceControlPeerRole.helper.rawValue,
            ]
        )
        let helperHelloDescriptor = try #require(
            messages.first { $0["type"] as? String == "helper_hello" }
        )
        let helperFixed = try #require(
            helperHelloDescriptor["fixed_values"] as? [String: Any]
        )
        #expect(helperFixed["engine_state"] as? String == "unloaded")
        #expect(helperFixed["schema_version"] as? Int == 2)
        #expect(helperFixed["seq"] as? UInt64 == 0)

        let session = try nonce("a")
        let plan = try nonce("b")
        let collector = try nonce("c")
        let peer = try nonce("d")
        let ticket = try nonce("e")
        let collectorToDriver = PerformanceControlWireFrame.challenge(
            peerRole: .driver,
            sessionID: session,
            planNonce: plan,
            collectorNonce: collector
        )
        let collectorToHelper = PerformanceControlWireFrame.challenge(
            peerRole: .helper,
            sessionID: session,
            planNonce: plan,
            collectorNonce: collector
        )
        let driverHello = PerformanceControlWireFrame.driverHello(
            sessionID: session,
            planNonce: plan,
            collectorNonce: collector,
            peerNonce: peer,
            collectionProtocol: try PerformanceControlProtocolIdentity(
                sha256: String(repeating: "1", count: 64)
            ),
            driverPolicySHA256: try PerformanceControlSHA256(
                String(repeating: "2", count: 64)
            ),
            measurementPolicySHA256: try PerformanceControlSHA256(
                String(repeating: "3", count: 64)
            )
        )
        let helperHelloFrame = PerformanceControlWireFrame.helperHello(
            sessionID: session,
            planNonce: plan,
            collectorNonce: collector,
            peerNonce: peer,
            measurementPolicySHA256: try PerformanceControlSHA256(
                String(repeating: "4", count: 64)
            ),
            releasePolicySHA256: try PerformanceControlSHA256(
                String(repeating: "5", count: 64)
            )
        )
        let arm = PerformanceControlWireFrame.armColdLoad(
            sequence: 1,
            sessionID: session,
            trial: 1
        )
        let loadEngine = PerformanceControlWireFrame.loadEngine(
            sequence: 1,
            sessionID: session,
            trial: 1,
            loadTicket: ticket
        )
        let loadStarted = PerformanceControlWireFrame.loadStarted(
            sequence: 1,
            sessionID: session,
            replyTo: loadEngine.sequence,
            trial: 1,
            loadTicket: ticket
        )
        let loadStartedAck = PerformanceControlWireFrame.loadStartedAck(
            sequence: 2,
            sessionID: session,
            replyTo: loadStarted.sequence,
            trial: 1,
            loadTicket: ticket
        )
        let loadReady = PerformanceControlWireFrame.loadReady(
            sequence: 2,
            sessionID: session,
            replyTo: loadStartedAck.sequence,
            trial: 1,
            loadTicket: ticket,
            engine: try performanceEngine()
        )

        #expect(collectorToDriver.sequence == 0)
        #expect(collectorToHelper.sequence == 0)
        #expect(driverHello.sequence == 0)
        #expect(helperHelloFrame.sequence == 0)
        #expect(arm.sequence == 1)
        #expect(loadEngine.sequence == collectorToHelper.sequence + 1)
        #expect(loadStarted.sequence == helperHelloFrame.sequence + 1)
        #expect(loadStartedAck.sequence == loadEngine.sequence + 1)
        #expect(loadReady.sequence == loadStarted.sequence + 1)

        let startedWire = try wireObject(loadStarted)
        let ackWire = try wireObject(loadStartedAck)
        let readyWire = try wireObject(loadReady)
        #expect(startedWire["reply_to"] as? UInt64 == loadEngine.sequence)
        #expect(ackWire["reply_to"] as? UInt64 == loadStarted.sequence)
        #expect(readyWire["reply_to"] as? UInt64 == loadStartedAck.sequence)
    }

    @Test("identity is the golden SHA-256 of exactly the canonical bytes")
    func identityIsGoldenSHA256AndEveryByteIsBound() {
        let data = PerformanceControlProtocolContract.canonicalData
        let identity = PerformanceControlProtocolContract.identity

        #expect(identity.id == PerformanceControlProtocolIdentity.requiredID)
        #expect(identity.sha256 == sha256(data))
        #expect(
            identity.sha256
                == "b7784bd825b63851ad02bf376020e41f6949f8d51f076da222ff8b6b383dfad3"
        )

        for index in data.indices {
            var mutated = data
            mutated[index] ^= 0x01
            #expect(sha256(mutated) != identity.sha256)
        }
    }

    private func contractObject() throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(
                with: PerformanceControlProtocolContract.canonicalData
            ) as? [String: Any]
        )
    }

    private func wireObject(
        _ frame: PerformanceControlWireFrame
    ) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(
                with: frame.encodedCanonical()
            ) as? [String: Any]
        )
    }

    private func performanceEngine() throws -> PerformanceControlEngineSummary {
        let artifactSHA256 = try PerformanceControlSHA256(
            String(repeating: "6", count: 64)
        )
        return try PerformanceControlEngineSummary(
            adapterID: ControlledPerformanceID("sherpa-onnx"),
            engineID: "sherpa-onnx@6666666666666666",
            artifactID: ControlledPerformanceID("voice-model-v1"),
            artifactContentSHA256: artifactSHA256,
            artifactGeneration: PerformanceControlArtifactGeneration(
                "11111111-1111-4111-8111-111111111111"
            ),
            capabilities: try ExpectedPerformanceControlEngine
                .evaluationCapabilities.map(ControlledPerformanceID.init),
            networkPolicy: .offline,
            maximumHotwords: 32
        )
    }

    private func nonce(_ digit: Character) throws -> PerformanceControlNonce {
        try PerformanceControlNonce(String(repeating: digit, count: 64))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func bindingDigest(domain: String, trial: UInt64) -> String {
        var input = Data(domain.utf8)
        input.append(Data(repeating: 0, count: 32))
        input.append(
            contentsOf: withUnsafeBytes(of: trial.bigEndian, Array.init)
        )
        return sha256(input)
    }
}
