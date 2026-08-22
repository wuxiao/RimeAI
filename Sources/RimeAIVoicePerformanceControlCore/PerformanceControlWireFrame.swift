import Foundation

public enum PerformanceControlWireFrame: Equatable, Sendable {
    public static let schemaVersion = 2
    public static let maximumEncodedBytes = 4_096

    case challenge(
        peerRole: PerformanceControlPeerRole,
        sessionID: PerformanceControlNonce,
        planNonce: PerformanceControlNonce,
        collectorNonce: PerformanceControlNonce
    )
    case driverHello(
        sessionID: PerformanceControlNonce,
        planNonce: PerformanceControlNonce,
        collectorNonce: PerformanceControlNonce,
        peerNonce: PerformanceControlNonce,
        collectionProtocol: PerformanceControlProtocolIdentity,
        driverPolicySHA256: PerformanceControlSHA256,
        measurementPolicySHA256: PerformanceControlSHA256
    )
    case helperHello(
        sessionID: PerformanceControlNonce,
        planNonce: PerformanceControlNonce,
        collectorNonce: PerformanceControlNonce,
        peerNonce: PerformanceControlNonce,
        measurementPolicySHA256: PerformanceControlSHA256,
        releasePolicySHA256: PerformanceControlSHA256
    )
    case armColdLoad(
        sequence: UInt64,
        sessionID: PerformanceControlNonce,
        trial: UInt64
    )
    case loadEngine(
        sequence: UInt64,
        sessionID: PerformanceControlNonce,
        trial: UInt64,
        loadTicket: PerformanceControlNonce
    )
    case loadStarted(
        sequence: UInt64,
        sessionID: PerformanceControlNonce,
        replyTo: UInt64,
        trial: UInt64,
        loadTicket: PerformanceControlNonce
    )
    case loadStartedAck(
        sequence: UInt64,
        sessionID: PerformanceControlNonce,
        replyTo: UInt64,
        trial: UInt64,
        loadTicket: PerformanceControlNonce
    )
    case loadReady(
        sequence: UInt64,
        sessionID: PerformanceControlNonce,
        replyTo: UInt64,
        trial: UInt64,
        loadTicket: PerformanceControlNonce,
        engine: PerformanceControlEngineSummary
    )

    public var sequence: UInt64 {
        switch self {
        case .challenge, .driverHello, .helperHello:
            0
        case let .armColdLoad(sequence, _, _),
             let .loadEngine(sequence, _, _, _),
             let .loadStarted(sequence, _, _, _, _),
             let .loadStartedAck(sequence, _, _, _, _),
             let .loadReady(sequence, _, _, _, _, _):
            sequence
        }
    }

    public func encodedCanonical() throws -> Data {
        let encoded: String
        switch self {
        case let .challenge(
            peerRole,
            sessionID,
            planNonce,
            collectorNonce
        ):
            encoded = "{\"collector_nonce\":\"\(collectorNonce.rawValue)\","
                + "\"peer_role\":\"\(peerRole.rawValue)\","
                + "\"plan_nonce\":\"\(planNonce.rawValue)\","
                + "\"schema_version\":2,\"seq\":0,"
                + "\"session_id\":\"\(sessionID.rawValue)\","
                + "\"type\":\"challenge\"}"
        case let .driverHello(
            sessionID,
            planNonce,
            collectorNonce,
            peerNonce,
            collectionProtocol,
            driverPolicySHA256,
            measurementPolicySHA256
        ):
            encoded = "{\"collection_protocol\":{"
                + "\"id\":\"\(collectionProtocol.id)\","
                + "\"sha256\":\"\(collectionProtocol.sha256)\"},"
                + "\"collector_nonce\":\"\(collectorNonce.rawValue)\","
                + "\"driver_policy_sha256\":"
                + "\"\(driverPolicySHA256.rawValue)\","
                + "\"measurement_policy_sha256\":"
                + "\"\(measurementPolicySHA256.rawValue)\","
                + "\"peer_nonce\":\"\(peerNonce.rawValue)\","
                + "\"plan_nonce\":\"\(planNonce.rawValue)\","
                + "\"schema_version\":2,\"seq\":0,"
                + "\"session_id\":\"\(sessionID.rawValue)\","
                + "\"type\":\"driver_hello\"}"
        case let .helperHello(
            sessionID,
            planNonce,
            collectorNonce,
            peerNonce,
            measurementPolicySHA256,
            releasePolicySHA256
        ):
            encoded = "{\"collector_nonce\":\"\(collectorNonce.rawValue)\","
                + "\"engine_state\":\"unloaded\","
                + "\"measurement_policy_sha256\":"
                + "\"\(measurementPolicySHA256.rawValue)\","
                + "\"peer_nonce\":\"\(peerNonce.rawValue)\","
                + "\"plan_nonce\":\"\(planNonce.rawValue)\","
                + "\"release_policy_sha256\":"
                + "\"\(releasePolicySHA256.rawValue)\","
                + "\"schema_version\":2,\"seq\":0,"
                + "\"session_id\":\"\(sessionID.rawValue)\","
                + "\"type\":\"helper_hello\"}"
        case let .armColdLoad(sequence, sessionID, trial):
            try Self.requirePositive(sequence, trial)
            encoded = "{\"schema_version\":2,\"seq\":\(sequence),"
                + "\"session_id\":\"\(sessionID.rawValue)\","
                + "\"trial\":\(trial),\"type\":\"arm_cold_load\"}"
        case let .loadEngine(sequence, sessionID, trial, loadTicket):
            try Self.requirePositive(sequence, trial)
            encoded = "{\"load_ticket\":\"\(loadTicket.rawValue)\","
                + "\"schema_version\":2,\"seq\":\(sequence),"
                + "\"session_id\":\"\(sessionID.rawValue)\","
                + "\"trial\":\(trial),\"type\":\"load_engine\"}"
        case let .loadStarted(
            sequence,
            sessionID,
            replyTo,
            trial,
            loadTicket
        ):
            try Self.requirePositive(sequence, replyTo, trial)
            encoded = Self.encodeReplyFrame(
                type: "load_started",
                sequence: sequence,
                sessionID: sessionID,
                replyTo: replyTo,
                trial: trial,
                loadTicket: loadTicket
            )
        case let .loadStartedAck(
            sequence,
            sessionID,
            replyTo,
            trial,
            loadTicket
        ):
            try Self.requirePositive(sequence, replyTo, trial)
            encoded = Self.encodeReplyFrame(
                type: "load_started_ack",
                sequence: sequence,
                sessionID: sessionID,
                replyTo: replyTo,
                trial: trial,
                loadTicket: loadTicket
            )
        case let .loadReady(
            sequence,
            sessionID,
            replyTo,
            trial,
            loadTicket,
            engine
        ):
            try Self.requirePositive(sequence, replyTo, trial)
            encoded = "{\"engine\":\(Self.encodeEngine(engine)),"
                + "\"load_ticket\":\"\(loadTicket.rawValue)\","
                + "\"reply_to\":\(replyTo),"
                + "\"schema_version\":2,\"seq\":\(sequence),"
                + "\"session_id\":\"\(sessionID.rawValue)\","
                + "\"trial\":\(trial),\"type\":\"load_ready\"}"
        }
        guard let data = encoded.data(using: .utf8),
              data.count <= Self.maximumEncodedBytes
        else {
            throw PerformanceControlError.frameTooLarge
        }
        return data
    }

    public static func decodeCanonical(_ data: Data) throws -> Self {
        guard !data.isEmpty else {
            throw PerformanceControlError.invalidFrame
        }
        guard data.count <= maximumEncodedBytes else {
            throw PerformanceControlError.frameTooLarge
        }
        guard !data.contains(0x0D) else {
            throw PerformanceControlError.carriageReturnForbidden
        }
        try PerformanceControlStrictJSON.validate(data)
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              strictUInt(object["schema_version"])
                == UInt64(schemaVersion),
              let type = object["type"] as? String
        else {
            throw PerformanceControlError.invalidFrame
        }
        let frame: Self
        switch type {
        case "challenge":
            guard Set(object.keys) == [
                  "collector_nonce",
                  "peer_role",
                  "plan_nonce",
                  "schema_version",
                  "seq",
                  "session_id",
                  "type",
              ],
                  strictUInt(object["seq"]) == 0,
                  let roleValue = object["peer_role"] as? String,
                  let peerRole = PerformanceControlPeerRole(
                      rawValue: roleValue
                  ),
                  let session = object["session_id"] as? String,
                  let plan = object["plan_nonce"] as? String,
                  let collector = object["collector_nonce"] as? String
            else {
                throw PerformanceControlError.invalidFrame
            }
            frame = try Self.challenge(
                peerRole: peerRole,
                sessionID: PerformanceControlNonce(session),
                planNonce: PerformanceControlNonce(plan),
                collectorNonce: PerformanceControlNonce(collector)
            )
        case "driver_hello":
            guard Set(object.keys) == [
                "collection_protocol",
                "collector_nonce",
                "driver_policy_sha256",
                "measurement_policy_sha256",
                "peer_nonce",
                "plan_nonce",
                "schema_version",
                "seq",
                "session_id",
                "type",
            ],
                  strictUInt(object["seq"]) == 0,
                  let protocolObject = object["collection_protocol"]
                    as? [String: Any],
                  Set(protocolObject.keys) == ["id", "sha256"],
                  let protocolID = protocolObject["id"] as? String,
                  let protocolSHA256 = protocolObject["sha256"] as? String,
                  let session = object["session_id"] as? String,
                  let plan = object["plan_nonce"] as? String,
                  let collector = object["collector_nonce"] as? String,
                  let peer = object["peer_nonce"] as? String,
                  let policy = object["driver_policy_sha256"] as? String,
                  let measurement = object["measurement_policy_sha256"]
                    as? String
            else {
                throw PerformanceControlError.invalidFrame
            }
            frame = try Self.driverHello(
                sessionID: PerformanceControlNonce(session),
                planNonce: PerformanceControlNonce(plan),
                collectorNonce: PerformanceControlNonce(collector),
                peerNonce: PerformanceControlNonce(peer),
                collectionProtocol: PerformanceControlProtocolIdentity(
                    id: protocolID,
                    sha256: protocolSHA256
                ),
                driverPolicySHA256: PerformanceControlSHA256(policy),
                measurementPolicySHA256: PerformanceControlSHA256(
                    measurement
                )
            )
        case "helper_hello":
            guard Set(object.keys) == [
                "collector_nonce",
                "engine_state",
                "measurement_policy_sha256",
                "peer_nonce",
                "plan_nonce",
                "release_policy_sha256",
                "schema_version",
                "seq",
                "session_id",
                "type",
            ],
                  strictUInt(object["seq"]) == 0,
                  object["engine_state"] as? String == "unloaded",
                  let session = object["session_id"] as? String,
                  let plan = object["plan_nonce"] as? String,
                  let collector = object["collector_nonce"] as? String,
                  let peer = object["peer_nonce"] as? String,
                  let measurement = object["measurement_policy_sha256"]
                    as? String,
                  let release = object["release_policy_sha256"] as? String
            else {
                throw PerformanceControlError.invalidFrame
            }
            frame = try Self.helperHello(
                sessionID: PerformanceControlNonce(session),
                planNonce: PerformanceControlNonce(plan),
                collectorNonce: PerformanceControlNonce(collector),
                peerNonce: PerformanceControlNonce(peer),
                measurementPolicySHA256: PerformanceControlSHA256(
                    measurement
                ),
                releasePolicySHA256: PerformanceControlSHA256(release)
            )
        case "arm_cold_load":
            guard Set(object.keys) == [
                "schema_version", "seq", "session_id", "trial", "type",
            ],
                  let sequence = positiveUInt(object["seq"]),
                  let session = object["session_id"] as? String,
                  let trial = positiveUInt(object["trial"])
            else {
                throw PerformanceControlError.invalidFrame
            }
            frame = try Self.armColdLoad(
                sequence: sequence,
                sessionID: PerformanceControlNonce(session),
                trial: trial
            )
        case "load_engine":
            guard Set(object.keys) == [
                "load_ticket",
                "schema_version",
                "seq",
                "session_id",
                "trial",
                "type",
            ],
                  let sequence = positiveUInt(object["seq"]),
                  let session = object["session_id"] as? String,
                  let trial = positiveUInt(object["trial"]),
                  let ticket = object["load_ticket"] as? String
            else {
                throw PerformanceControlError.invalidFrame
            }
            frame = try Self.loadEngine(
                sequence: sequence,
                sessionID: PerformanceControlNonce(session),
                trial: trial,
                loadTicket: PerformanceControlNonce(ticket)
            )
        case "load_started", "load_started_ack":
            guard Set(object.keys) == [
                "load_ticket",
                "reply_to",
                "schema_version",
                "seq",
                "session_id",
                "trial",
                "type",
            ],
                  let sequence = positiveUInt(object["seq"]),
                  let session = object["session_id"] as? String,
                  let replyTo = positiveUInt(object["reply_to"]),
                  let trial = positiveUInt(object["trial"]),
                  let ticket = object["load_ticket"] as? String
            else {
                throw PerformanceControlError.invalidFrame
            }
            if type == "load_started" {
                frame = try Self.loadStarted(
                    sequence: sequence,
                    sessionID: PerformanceControlNonce(session),
                    replyTo: replyTo,
                    trial: trial,
                    loadTicket: PerformanceControlNonce(ticket)
                )
            } else {
                frame = try Self.loadStartedAck(
                    sequence: sequence,
                    sessionID: PerformanceControlNonce(session),
                    replyTo: replyTo,
                    trial: trial,
                    loadTicket: PerformanceControlNonce(ticket)
                )
            }
        case "load_ready":
            guard Set(object.keys) == [
                "engine",
                "load_ticket",
                "reply_to",
                "schema_version",
                "seq",
                "session_id",
                "trial",
                "type",
            ],
                  let sequence = positiveUInt(object["seq"]),
                  let session = object["session_id"] as? String,
                  let replyTo = positiveUInt(object["reply_to"]),
                  let trial = positiveUInt(object["trial"]),
                  let ticket = object["load_ticket"] as? String,
                  let engineObject = object["engine"] as? [String: Any]
            else {
                throw PerformanceControlError.invalidFrame
            }
            frame = try Self.loadReady(
                sequence: sequence,
                sessionID: PerformanceControlNonce(session),
                replyTo: replyTo,
                trial: trial,
                loadTicket: PerformanceControlNonce(ticket),
                engine: decodeEngine(engineObject)
            )
        default:
            throw PerformanceControlError.invalidFrame
        }
        guard try frame.encodedCanonical() == data else {
            throw PerformanceControlError.nonCanonicalJSON
        }
        return frame
    }

    private static func strictUInt(_ value: Any?) -> UInt64? {
        PerformanceControlStrictJSON.uint64(value)
    }

    private static func positiveUInt(_ value: Any?) -> UInt64? {
        guard let result = strictUInt(value), result > 0 else { return nil }
        return result
    }

    private static func requirePositive(_ values: UInt64...) throws {
        guard values.allSatisfy({ $0 > 0 }) else {
            throw PerformanceControlError.invalidFrame
        }
    }

    private static func encodeReplyFrame(
        type: String,
        sequence: UInt64,
        sessionID: PerformanceControlNonce,
        replyTo: UInt64,
        trial: UInt64,
        loadTicket: PerformanceControlNonce
    ) -> String {
        "{\"load_ticket\":\"\(loadTicket.rawValue)\","
            + "\"reply_to\":\(replyTo),"
            + "\"schema_version\":2,\"seq\":\(sequence),"
            + "\"session_id\":\"\(sessionID.rawValue)\","
            + "\"trial\":\(trial),\"type\":\"\(type)\"}"
    }

    private static func encodeEngine(
        _ engine: PerformanceControlEngineSummary
    ) -> String {
        let capabilities = engine.capabilities
            .map { "\"\($0.rawValue)\"" }
            .joined(separator: ",")
        return "{\"adapter_id\":\"\(engine.adapterID.rawValue)\","
            + "\"artifact_content_sha256\":"
            + "\"\(engine.artifactContentSHA256.rawValue)\","
            + "\"artifact_generation\":"
            + "\"\(engine.artifactGeneration.rawValue)\","
            + "\"artifact_id\":\"\(engine.artifactID.rawValue)\","
            + "\"capabilities\":[\(capabilities)],"
            + "\"engine_id\":\"\(engine.engineID)\","
            + "\"maximum_hotwords\":\(engine.maximumHotwords),"
            + "\"network_policy\":\"\(engine.networkPolicy.rawValue)\"}"
    }

    private static func decodeEngine(
        _ object: [String: Any]
    ) throws -> PerformanceControlEngineSummary {
        guard Set(object.keys) == [
            "adapter_id",
            "artifact_content_sha256",
            "artifact_generation",
            "artifact_id",
            "capabilities",
            "engine_id",
            "maximum_hotwords",
            "network_policy",
        ],
              let adapterID = object["adapter_id"] as? String,
              let artifactSHA256 = object["artifact_content_sha256"]
                as? String,
              let artifactGeneration = object["artifact_generation"]
                as? String,
              let artifactID = object["artifact_id"] as? String,
              let capabilityValues = object["capabilities"] as? [String],
              let engineID = object["engine_id"] as? String,
              let maximumHotwords = strictUInt(object["maximum_hotwords"]),
              let networkValue = object["network_policy"] as? String,
              let networkPolicy = PerformanceControlNetworkPolicy(
                  rawValue: networkValue
              )
        else {
            throw PerformanceControlError.invalidFrame
        }
        return try PerformanceControlEngineSummary(
            adapterID: ControlledPerformanceID(adapterID),
            engineID: engineID,
            artifactID: ControlledPerformanceID(artifactID),
            artifactContentSHA256: PerformanceControlSHA256(artifactSHA256),
            artifactGeneration: PerformanceControlArtifactGeneration(
                artifactGeneration
            ),
            capabilities: try capabilityValues.map(ControlledPerformanceID.init),
            networkPolicy: networkPolicy,
            maximumHotwords: maximumHotwords
        )
    }
}
