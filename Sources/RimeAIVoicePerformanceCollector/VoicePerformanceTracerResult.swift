import Foundation
import RimeAIVoicePerformanceControlCore

public struct VoicePerformanceTracerAttestedPeer: Equatable, Sendable {
  public let pid: Int32
  public let effectiveUserID: UInt32
  public let processStartToken: UInt64
  public let pidVersion: Int32
  public let instanceID: ControlledPerformanceID

  public let authenticatedProductionDriver = false

  public init(
    pid: Int32,
    effectiveUserID: UInt32,
    processStartToken: UInt64,
    pidVersion: Int32,
    instanceID: String
  ) throws {
    guard pid > 0,
      processStartToken > 0,
      pidVersion > 0,
      let controlledID = try? ControlledPerformanceID(instanceID),
      (try? PerformanceControlNonce(instanceID)) != nil
    else {
      throw VoicePerformanceTracerCollectorError.authenticationFailed
    }
    self.pid = pid
    self.effectiveUserID = effectiveUserID
    self.processStartToken = processStartToken
    self.pidVersion = pidVersion
    self.instanceID = controlledID
  }
}

public enum VoicePerformanceTracerTranscriptChannel:
  String,
  Equatable,
  Sendable
{
  case collectorToDriver = "collector_to_driver"
  case driverToCollector = "driver_to_collector"
  case collectorToHelper = "collector_to_helper"
  case helperToCollector = "helper_to_collector"
}

public struct VoicePerformanceTracerTranscriptEntry: Equatable, Sendable {
  public let trial: UInt64
  public let channel: VoicePerformanceTracerTranscriptChannel
  public let frameUTF8: String

  init(
    trial: UInt64,
    channel: VoicePerformanceTracerTranscriptChannel,
    frame: PerformanceControlWireFrame
  ) throws {
    guard PerformanceControlSessionBinding.supportedTrials.contains(trial)
    else {
      throw VoicePerformanceTracerCollectorError.invalidResult
    }
    let data = try frame.encodedCanonical()
    guard let encoded = String(data: data, encoding: .utf8),
      try PerformanceControlWireFrame.decodeCanonical(data) == frame
    else {
      throw VoicePerformanceTracerCollectorError.invalidResult
    }
    self.trial = trial
    self.channel = channel
    frameUTF8 = encoded
  }

  public func decodedFrame() throws -> PerformanceControlWireFrame {
    try PerformanceControlWireFrame.decodeCanonical(Data(frameUTF8.utf8))
  }
}

public struct VoicePerformanceTracerColdTrialResult: Equatable, Sendable {
  public let trial: UInt64
  public let sessionID: PerformanceControlNonce
  public let planNonce: PerformanceControlNonce
  public let loadTicket: PerformanceControlNonce
  public let helperGeneration: HelperGenerationIdentity
  public let helperAttestation: VoicePerformanceTracerAttestedPeer
  public let helperExitConfirmed = true
  public let artifactGeneration: PerformanceControlArtifactGeneration
  public let coldLoadDurationNanoseconds: UInt64

  init(
    trial: UInt64,
    sessionID: PerformanceControlNonce,
    planNonce: PerformanceControlNonce,
    loadTicket: PerformanceControlNonce,
    helperGeneration: HelperGenerationIdentity,
    helperAttestation: VoicePerformanceTracerAttestedPeer,
    artifactGeneration: PerformanceControlArtifactGeneration,
    coldLoadDurationNanoseconds: UInt64
  ) throws {
    guard PerformanceControlSessionBinding.supportedTrials.contains(trial),
      coldLoadDurationNanoseconds > 0,
      helperGeneration.pid == helperAttestation.pid,
      helperGeneration.processStartToken
        == helperAttestation.processStartToken,
      helperGeneration.instanceID == helperAttestation.instanceID
    else {
      throw VoicePerformanceTracerCollectorError.invalidResult
    }
    self.trial = trial
    self.sessionID = sessionID
    self.planNonce = planNonce
    self.loadTicket = loadTicket
    self.helperGeneration = helperGeneration
    self.helperAttestation = helperAttestation
    self.artifactGeneration = artifactGeneration
    self.coldLoadDurationNanoseconds = coldLoadDurationNanoseconds
  }
}

public struct VoicePerformanceTracerResult: Equatable, Sendable {
  public static let schemaVersion = 2
  public static let maximumEncodedBytes = 1_048_576

  public let qualification = PerformanceControlQualification.tracer
  public let authenticatedProductionDriver = false
  public let controlProtocol: PerformanceControlProtocolIdentity
  public let controlSessionNonce: PerformanceControlNonce
  public let measurementPolicySHA256: PerformanceControlSHA256
  public let driverPolicySHA256: PerformanceControlSHA256
  public let releasePolicySHA256: PerformanceControlSHA256
  public let expectedEngine: ExpectedPerformanceControlEngine
  public let driverAttestation: VoicePerformanceTracerAttestedPeer
  public let trials: [VoicePerformanceTracerColdTrialResult]
  public let transcript: [VoicePerformanceTracerTranscriptEntry]

  init(
    controlProtocol: PerformanceControlProtocolIdentity,
    controlSessionNonce: PerformanceControlNonce,
    measurementPolicySHA256: PerformanceControlSHA256,
    driverPolicySHA256: PerformanceControlSHA256,
    releasePolicySHA256: PerformanceControlSHA256,
    expectedEngine: ExpectedPerformanceControlEngine,
    driverAttestation: VoicePerformanceTracerAttestedPeer,
    trials: [VoicePerformanceTracerColdTrialResult],
    transcript: [VoicePerformanceTracerTranscriptEntry]
  ) throws {
    guard
      PerformanceControlSessionBinding.supportedTrials
        .contains(UInt64(trials.count)),
      transcript.count == trials.count * 9,
      !driverAttestation.authenticatedProductionDriver
    else {
      throw VoicePerformanceTracerCollectorError.invalidResult
    }
    self.controlProtocol = controlProtocol
    self.controlSessionNonce = controlSessionNonce
    self.measurementPolicySHA256 = measurementPolicySHA256
    self.driverPolicySHA256 = driverPolicySHA256
    self.releasePolicySHA256 = releasePolicySHA256
    self.expectedEngine = expectedEngine
    self.driverAttestation = driverAttestation
    self.trials = trials
    self.transcript = transcript
  }

  public func encodedCanonical() throws -> Data {
    let trialJSON = trials.map(Self.encodeTrial).joined(separator: ",")
    let transcriptJSON = transcript.map(Self.encodeTranscript)
      .joined(separator: ",")
    let encoded =
      "{\"authenticated_production_driver\":false,"
      + "\"control_protocol\":{\"id\":"
      + Self.jsonString(controlProtocol.id)
      + ",\"sha256\":" + Self.jsonString(controlProtocol.sha256) + "},"
      + "\"control_session_nonce\":"
      + Self.jsonString(controlSessionNonce.rawValue) + ","
      + "\"driver_attestation\":"
      + Self.encodeAttestation(driverAttestation) + ","
      + "\"driver_policy_sha256\":"
      + Self.jsonString(driverPolicySHA256.rawValue) + ","
      + "\"expected_engine\":" + Self.encodeExpectedEngine(expectedEngine)
      + ",\"measurement_policy_sha256\":"
      + Self.jsonString(measurementPolicySHA256.rawValue) + ","
      + "\"qualification\":\"tracer\","
      + "\"release_policy_sha256\":"
      + Self.jsonString(releasePolicySHA256.rawValue) + ","
      + "\"schema_version\":2,\"transcript\":[" + transcriptJSON
      + "],\"trials\":[" + trialJSON + "]}"
    let data = Data(encoded.utf8)
    guard !data.isEmpty, data.count <= Self.maximumEncodedBytes else {
      throw VoicePerformanceTracerCollectorError.invalidResult
    }
    return data
  }

  public static func decodeCanonical(_ data: Data) throws -> Self {
    do {
      let value = try VoicePerformanceStrictJSON.validate(
        data,
        maximumBytes: maximumEncodedBytes,
        maximumDepth: 8,
        maximumNodes: 4_096
      )
      guard hasExactShape(value) else {
        throw VoicePerformanceTracerCollectorError.invalidResult
      }
      let wire = try JSONDecoder().decode(Wire.self, from: data)
      guard wire.schemaVersion == schemaVersion,
        wire.qualification == "tracer",
        !wire.authenticatedProductionDriver,
        PerformanceControlSessionBinding.supportedTrials.contains(
          UInt64(wire.trials.count)
        ),
        wire.transcript.count == wire.trials.count * 9
      else {
        throw VoicePerformanceTracerCollectorError.invalidResult
      }

      let protocolIdentity = try PerformanceControlProtocolIdentity(
        id: wire.controlProtocol.id,
        sha256: wire.controlProtocol.sha256
      )
      let controlSessionNonce = try PerformanceControlNonce(
        wire.controlSessionNonce
      )
      let measurementSHA = try PerformanceControlSHA256(
        wire.measurementPolicySHA256
      )
      let driverSHA = try PerformanceControlSHA256(
        wire.driverPolicySHA256
      )
      let releaseSHA = try PerformanceControlSHA256(
        wire.releasePolicySHA256
      )
      let driverAttestation = try decodeAttestation(
        wire.driverAttestation
      )

      var helperProcesses = Set<ProcessKey>()
      var helperInstances = Set<ControlledPerformanceID>()
      var tickets = Set<PerformanceControlNonce>()
      var artifactGenerations = Set<PerformanceControlArtifactGeneration>()
      let driverProcess = ProcessKey(
        pid: driverAttestation.pid,
        startToken: driverAttestation.processStartToken
      )
      var trials: [VoicePerformanceTracerColdTrialResult] = []
      for (index, trialWire) in wire.trials.enumerated() {
        let ordinal = UInt64(index + 1)
        guard trialWire.trial == ordinal,
          trialWire.helperExitConfirmed
        else {
          throw VoicePerformanceTracerCollectorError.invalidResult
        }
        let sessionID = try PerformanceControlNonce(
          trialWire.sessionID
        )
        let planNonce = try PerformanceControlNonce(
          trialWire.planNonce
        )
        let binding = try PerformanceControlSessionBinding.derive(
          controlSessionNonce: controlSessionNonce,
          trial: ordinal
        )
        guard sessionID == binding.sessionID,
          planNonce == binding.planNonce
        else {
          throw VoicePerformanceTracerCollectorError.invalidResult
        }
        let ticket = try PerformanceControlNonce(
          trialWire.loadTicket
        )
        let helperAttestation = try decodeAttestation(
          trialWire.helperAttestation
        )
        let helperGeneration = try HelperGenerationIdentity(
          pid: trialWire.helperGeneration.pid,
          processStartToken:
            trialWire.helperGeneration.processStartToken,
          instanceID: ControlledPerformanceID(
            trialWire.helperGeneration.instanceID
          )
        )
        let helperProcess = ProcessKey(
          pid: helperAttestation.pid,
          startToken: helperAttestation.processStartToken
        )
        let artifactGeneration = try PerformanceControlArtifactGeneration(
          trialWire.artifactGeneration
        )
        guard
          helperAttestation.effectiveUserID
            == driverAttestation.effectiveUserID,
          helperProcess != driverProcess,
          helperAttestation.instanceID
            != driverAttestation.instanceID,
          helperProcesses.insert(helperProcess).inserted,
          helperInstances.insert(
            helperAttestation.instanceID
          ).inserted,
          tickets.insert(ticket).inserted,
          artifactGenerations.insert(artifactGeneration).inserted
        else {
          throw VoicePerformanceTracerCollectorError.invalidResult
        }
        trials.append(
          try VoicePerformanceTracerColdTrialResult(
            trial: ordinal,
            sessionID: sessionID,
            planNonce: planNonce,
            loadTicket: ticket,
            helperGeneration: helperGeneration,
            helperAttestation: helperAttestation,
            artifactGeneration: artifactGeneration,
            coldLoadDurationNanoseconds:
              trialWire.coldLoadDurationNanoseconds
          ))
      }

      guard
        let firstArtifactGeneration = trials.first?
          .artifactGeneration,
        let networkPolicy = PerformanceControlNetworkPolicy(
          rawValue: wire.expectedEngine.networkPolicy
        )
      else {
        throw VoicePerformanceTracerCollectorError.invalidResult
      }
      let expectedSummary = try PerformanceControlEngineSummary(
        adapterID: ControlledPerformanceID(
          wire.expectedEngine.adapterID
        ),
        engineID: wire.expectedEngine.engineID,
        artifactID: ControlledPerformanceID(
          wire.expectedEngine.artifactID
        ),
        artifactContentSHA256: PerformanceControlSHA256(
          wire.expectedEngine.artifactContentSHA256
        ),
        artifactGeneration: firstArtifactGeneration,
        capabilities: try wire.expectedEngine.capabilities.map(
          ControlledPerformanceID.init
        ),
        networkPolicy: networkPolicy,
        maximumHotwords: wire.expectedEngine.maximumHotwords
      )
      let expectedEngine = ExpectedPerformanceControlEngine(
        expectedSummary
      )
      let transcript = try wire.transcript.map { entry in
        guard
          let channel = VoicePerformanceTracerTranscriptChannel(
            rawValue: entry.channel
          )
        else {
          throw VoicePerformanceTracerCollectorError.invalidResult
        }
        let frame = try PerformanceControlWireFrame.decodeCanonical(
          Data(entry.frameUTF8.utf8)
        )
        return try VoicePerformanceTracerTranscriptEntry(
          trial: entry.trial,
          channel: channel,
          frame: frame
        )
      }
      let result = try Self(
        controlProtocol: protocolIdentity,
        controlSessionNonce: controlSessionNonce,
        measurementPolicySHA256: measurementSHA,
        driverPolicySHA256: driverSHA,
        releasePolicySHA256: releaseSHA,
        expectedEngine: expectedEngine,
        driverAttestation: driverAttestation,
        trials: trials,
        transcript: transcript
      )
      try validateTranscript(result)
      guard try result.encodedCanonical() == data else {
        throw VoicePerformanceTracerCollectorError.invalidResult
      }
      return result
    } catch {
      throw VoicePerformanceTracerCollectorError.invalidResult
    }
  }

  private static func validateTranscript(_ result: Self) throws {
    let expectedChannels: [VoicePerformanceTracerTranscriptChannel] = [
      .collectorToDriver,
      .collectorToHelper,
      .driverToCollector,
      .helperToCollector,
      .driverToCollector,
      .collectorToHelper,
      .helperToCollector,
      .collectorToHelper,
      .helperToCollector,
    ]
    var usedTokens = Set<PerformanceControlNonce>()
    for (index, trial) in result.trials.enumerated() {
      let entries = Array(
        result.transcript[(index * 9)..<(index * 9 + 9)]
      )
      guard entries.allSatisfy({ $0.trial == trial.trial }),
        entries.map(\.channel) == expectedChannels
      else {
        throw VoicePerformanceTracerCollectorError.invalidResult
      }
      let frames = try entries.map { try $0.decodedFrame() }
      guard
        case .challenge(
          let
            driverRole,
          let
            driverSession,
          let
            driverPlan,
          let
            driverCollectorNonce
        ) = frames[0],
        driverRole == .driver,
        case .challenge(
          let
            helperRole,
          let
            helperSession,
          let
            helperPlan,
          let
            helperCollectorNonce
        ) = frames[1],
        helperRole == .helper,
        case .driverHello(
          let
            driverHelloSession,
          let
            driverHelloPlan,
          let
            echoedDriverCollectorNonce,
          let
            driverPeerNonce,
          let
            controlProtocol,
          let
            driverPolicySHA256,
          let
            driverMeasurementPolicySHA256
        ) = frames[2],
        case .helperHello(
          let
            helperHelloSession,
          let
            helperHelloPlan,
          let
            echoedHelperCollectorNonce,
          let
            helperPeerNonce,
          let
            measurementPolicySHA256,
          let
            releasePolicySHA256
        ) = frames[3],
        case .armColdLoad(
          let
            armSequence,
          let
            armSession,
          let
            armTrial
        ) = frames[4],
        case .loadEngine(
          let
            loadSequence,
          let
            loadSession,
          let
            loadTrial,
          let
            loadTicket
        ) = frames[5],
        case .loadStarted(
          let
            startedSequence,
          let
            startedSession,
          let
            startedReply,
          let
            startedTrial,
          let
            startedTicket
        ) = frames[6],
        case .loadStartedAck(
          let
            ackSequence,
          let
            ackSession,
          let
            ackReply,
          let
            ackTrial,
          let
            ackTicket
        ) = frames[7],
        case .loadReady(
          let
            readySequence,
          let
            readySession,
          let
            readyReply,
          let
            readyTrial,
          let
            readyTicket,
          let
            engine
        ) = frames[8],
        driverSession == trial.sessionID,
        helperSession == trial.sessionID,
        driverHelloSession == trial.sessionID,
        helperHelloSession == trial.sessionID,
        armSession == trial.sessionID,
        loadSession == trial.sessionID,
        startedSession == trial.sessionID,
        ackSession == trial.sessionID,
        readySession == trial.sessionID,
        driverPlan == trial.planNonce,
        helperPlan == trial.planNonce,
        driverHelloPlan == trial.planNonce,
        helperHelloPlan == trial.planNonce,
        echoedDriverCollectorNonce == driverCollectorNonce,
        echoedHelperCollectorNonce == helperCollectorNonce,
        controlProtocol == result.controlProtocol,
        driverPolicySHA256 == result.driverPolicySHA256,
        driverMeasurementPolicySHA256
          == result.measurementPolicySHA256,
        measurementPolicySHA256 == result.measurementPolicySHA256,
        releasePolicySHA256 == result.releasePolicySHA256,
        armSequence == 1,
        loadSequence == 1,
        startedSequence == 1,
        startedReply == loadSequence,
        ackSequence == 2,
        ackReply == startedSequence,
        readySequence == 2,
        readyReply == ackSequence,
        armTrial == trial.trial,
        loadTrial == trial.trial,
        startedTrial == trial.trial,
        ackTrial == trial.trial,
        readyTrial == trial.trial,
        loadTicket == trial.loadTicket,
        startedTicket == trial.loadTicket,
        ackTicket == trial.loadTicket,
        readyTicket == trial.loadTicket,
        engine.artifactGeneration == trial.artifactGeneration,
        result.expectedEngine.matches(engine)
      else {
        throw VoicePerformanceTracerCollectorError.invalidResult
      }
      for token in [
        trial.sessionID,
        trial.planNonce,
        driverCollectorNonce,
        helperCollectorNonce,
        driverPeerNonce,
        helperPeerNonce,
        trial.loadTicket,
      ] where !usedTokens.insert(token).inserted {
        throw VoicePerformanceTracerCollectorError.invalidResult
      }
    }
  }

  private static func decodeAttestation(
    _ wire: Wire.Attestation
  ) throws -> VoicePerformanceTracerAttestedPeer {
    try VoicePerformanceTracerAttestedPeer(
      pid: wire.pid,
      effectiveUserID: wire.effectiveUserID,
      processStartToken: wire.processStartToken,
      pidVersion: wire.pidVersion,
      instanceID: wire.instanceID
    )
  }

  private static func hasExactShape(_ value: Any) -> Bool {
    guard
      VoicePerformanceStrictJSON.hasExactKeys(
        value,
        [
          "authenticated_production_driver",
          "control_protocol",
          "control_session_nonce",
          "driver_attestation",
          "driver_policy_sha256",
          "expected_engine",
          "measurement_policy_sha256",
          "qualification",
          "release_policy_sha256",
          "schema_version",
          "transcript",
          "trials",
        ]),
      let object = value as? [String: Any],
      VoicePerformanceStrictJSON.hasExactKeys(
        object["control_protocol"] as Any,
        ["id", "sha256"]
      ),
      hasExactAttestationShape(object["driver_attestation"] as Any),
      VoicePerformanceStrictJSON.hasExactKeys(
        object["expected_engine"] as Any,
        [
          "adapter_id",
          "artifact_content_sha256",
          "artifact_id",
          "capabilities",
          "engine_id",
          "maximum_hotwords",
          "network_policy",
        ]
      ),
      let transcript = object["transcript"] as? [[String: Any]],
      transcript.allSatisfy({
        VoicePerformanceStrictJSON.hasExactKeys(
          $0,
          ["channel", "frame_utf8", "trial"]
        )
      }),
      let trials = object["trials"] as? [[String: Any]],
      trials.allSatisfy({ trial in
        VoicePerformanceStrictJSON.hasExactKeys(
          trial,
          [
            "artifact_generation",
            "cold_load_duration_ns",
            "helper_attestation",
            "helper_exit_confirmed",
            "helper_generation",
            "load_ticket",
            "plan_nonce",
            "session_id",
            "trial",
          ])
          && hasExactAttestationShape(
            trial["helper_attestation"] as Any
          )
          && VoicePerformanceStrictJSON.hasExactKeys(
            trial["helper_generation"] as Any,
            ["instance_id", "pid", "process_start_token"]
          )
      })
    else {
      return false
    }
    return true
  }

  private static func hasExactAttestationShape(_ value: Any) -> Bool {
    VoicePerformanceStrictJSON.hasExactKeys(
      value,
      [
        "effective_user_id",
        "instance_id",
        "pid",
        "pid_version",
        "process_start_token",
      ])
  }

  private static func encodeTrial(
    _ trial: VoicePerformanceTracerColdTrialResult
  ) -> String {
    "{\"artifact_generation\":"
      + jsonString(trial.artifactGeneration.rawValue)
      + ",\"cold_load_duration_ns\":"
      + String(trial.coldLoadDurationNanoseconds)
      + ",\"helper_attestation\":"
      + encodeAttestation(trial.helperAttestation)
      + ",\"helper_exit_confirmed\":true"
      + ",\"helper_generation\":{\"instance_id\":"
      + jsonString(trial.helperGeneration.instanceID.rawValue)
      + ",\"pid\":" + String(trial.helperGeneration.pid)
      + ",\"process_start_token\":"
      + String(trial.helperGeneration.processStartToken) + "},"
      + "\"load_ticket\":" + jsonString(trial.loadTicket.rawValue)
      + ",\"plan_nonce\":" + jsonString(trial.planNonce.rawValue)
      + ",\"session_id\":" + jsonString(trial.sessionID.rawValue)
      + ",\"trial\":" + String(trial.trial) + "}"
  }

  private static func encodeTranscript(
    _ entry: VoicePerformanceTracerTranscriptEntry
  ) -> String {
    "{\"channel\":" + jsonString(entry.channel.rawValue)
      + ",\"frame_utf8\":" + jsonString(entry.frameUTF8)
      + ",\"trial\":" + String(entry.trial) + "}"
  }

  private static func encodeAttestation(
    _ peer: VoicePerformanceTracerAttestedPeer
  ) -> String {
    "{\"effective_user_id\":" + String(peer.effectiveUserID)
      + ",\"instance_id\":" + jsonString(peer.instanceID.rawValue)
      + ",\"pid\":" + String(peer.pid)
      + ",\"pid_version\":" + String(peer.pidVersion)
      + ",\"process_start_token\":"
      + String(peer.processStartToken) + "}"
  }

  private static func encodeExpectedEngine(
    _ engine: ExpectedPerformanceControlEngine
  ) -> String {
    let capabilities = engine.capabilities.map {
      jsonString($0.rawValue)
    }.joined(separator: ",")
    return "{\"adapter_id\":" + jsonString(engine.adapterID.rawValue)
      + ",\"artifact_content_sha256\":"
      + jsonString(engine.artifactContentSHA256.rawValue)
      + ",\"artifact_id\":" + jsonString(engine.artifactID.rawValue)
      + ",\"capabilities\":[" + capabilities + "]"
      + ",\"engine_id\":" + jsonString(engine.engineID)
      + ",\"maximum_hotwords\":" + String(engine.maximumHotwords)
      + ",\"network_policy\":"
      + jsonString(engine.networkPolicy.rawValue) + "}"
  }

  private static func jsonString(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x22: result += "\\\""
      case 0x5C: result += "\\\\"
      case 0x08: result += "\\b"
      case 0x0C: result += "\\f"
      case 0x0A: result += "\\n"
      case 0x0D: result += "\\r"
      case 0x09: result += "\\t"
      case 0x00...0x1F:
        result += String(format: "\\u%04x", scalar.value)
      default:
        result.unicodeScalars.append(scalar)
      }
    }
    result += "\""
    return result
  }

  private struct ProcessKey: Hashable {
    let pid: Int32
    let startToken: UInt64
  }

  private struct Wire: Decodable {
    struct ControlProtocol: Decodable {
      let id: String
      let sha256: String
    }

    struct Attestation: Decodable {
      let effectiveUserID: UInt32
      let instanceID: String
      let pid: Int32
      let pidVersion: Int32
      let processStartToken: UInt64

      enum CodingKeys: String, CodingKey {
        case effectiveUserID = "effective_user_id"
        case instanceID = "instance_id"
        case pid
        case pidVersion = "pid_version"
        case processStartToken = "process_start_token"
      }
    }

    struct ExpectedEngine: Decodable {
      let adapterID: String
      let artifactContentSHA256: String
      let artifactID: String
      let capabilities: [String]
      let engineID: String
      let maximumHotwords: UInt64
      let networkPolicy: String

      enum CodingKeys: String, CodingKey {
        case adapterID = "adapter_id"
        case artifactContentSHA256 = "artifact_content_sha256"
        case artifactID = "artifact_id"
        case capabilities
        case engineID = "engine_id"
        case maximumHotwords = "maximum_hotwords"
        case networkPolicy = "network_policy"
      }
    }

    struct Transcript: Decodable {
      let channel: String
      let frameUTF8: String
      let trial: UInt64

      enum CodingKeys: String, CodingKey {
        case channel
        case frameUTF8 = "frame_utf8"
        case trial
      }
    }

    struct HelperGeneration: Decodable {
      let instanceID: String
      let pid: Int32
      let processStartToken: UInt64

      enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case pid
        case processStartToken = "process_start_token"
      }
    }

    struct Trial: Decodable {
      let artifactGeneration: String
      let coldLoadDurationNanoseconds: UInt64
      let helperAttestation: Attestation
      let helperExitConfirmed: Bool
      let helperGeneration: HelperGeneration
      let loadTicket: String
      let planNonce: String
      let sessionID: String
      let trial: UInt64

      enum CodingKeys: String, CodingKey {
        case artifactGeneration = "artifact_generation"
        case coldLoadDurationNanoseconds = "cold_load_duration_ns"
        case helperAttestation = "helper_attestation"
        case helperExitConfirmed = "helper_exit_confirmed"
        case helperGeneration = "helper_generation"
        case loadTicket = "load_ticket"
        case planNonce = "plan_nonce"
        case sessionID = "session_id"
        case trial
      }
    }

    let authenticatedProductionDriver: Bool
    let controlProtocol: ControlProtocol
    let controlSessionNonce: String
    let driverAttestation: Attestation
    let driverPolicySHA256: String
    let expectedEngine: ExpectedEngine
    let measurementPolicySHA256: String
    let qualification: String
    let releasePolicySHA256: String
    let schemaVersion: Int
    let transcript: [Transcript]
    let trials: [Trial]

    enum CodingKeys: String, CodingKey {
      case authenticatedProductionDriver =
        "authenticated_production_driver"
      case controlProtocol = "control_protocol"
      case controlSessionNonce = "control_session_nonce"
      case driverAttestation = "driver_attestation"
      case driverPolicySHA256 = "driver_policy_sha256"
      case expectedEngine = "expected_engine"
      case measurementPolicySHA256 = "measurement_policy_sha256"
      case qualification
      case releasePolicySHA256 = "release_policy_sha256"
      case schemaVersion = "schema_version"
      case transcript
      case trials
    }
  }
}
