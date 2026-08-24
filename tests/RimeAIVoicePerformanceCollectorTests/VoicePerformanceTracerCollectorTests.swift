import Foundation
import RimeAIVoicePerformanceControlCore
import Testing

@testable import RimeAIVoicePerformanceCollector

@Suite("Voice performance tracer collector")
struct VoicePerformanceTracerCollectorTests {
  @Test("a tracer request derives trials and engine only from one policy")
  func requestDerivesThePolicyContract() throws {
    for accepted in [UInt64(1), 32] {
      let fixture = try TracerFixture(coldTrials: accepted)
      let request = try VoicePerformanceTracerCollectionRequest(
        measurementPolicy: fixture.measurementPolicy,
        driverPolicy: fixture.driverPolicy
      )
      #expect(request.coldTrials == accepted)
      #expect(request.expectedEngine == fixture.measurementPolicy.expectedEngine)
      #expect(request.qualification == .tracer)
      #expect(!request.authenticatedProductionDriver)
    }
    let initializer: (
      VoicePerformanceMeasurementPolicy,
      SealedPerformanceControlDriverPolicy
    ) throws -> VoicePerformanceTracerCollectionRequest =
      VoicePerformanceTracerCollectionRequest.init
    _ = initializer
  }

  @Test("one cold trial is driven end-to-end as tracer-only evidence")
  func collectsOneColdTrial() throws {
    let fixture = try TracerFixture()
    let transport = try ScriptedTracerTransport(fixture: fixture)
    let collector = VoicePerformanceTracerCollector(
      transport: transport,
      nonceSource: SequenceTracerNonceSource([
        try nonce("c", suffix: 1),
        try nonce("c", suffix: 2),
        try nonce("c", suffix: 3),
      ]),
      monotonicClock: SequenceTracerMonotonicClock([100, 350])
    )
    let request = try VoicePerformanceTracerCollectionRequest(
      measurementPolicy: fixture.measurementPolicy,
      driverPolicy: fixture.driverPolicy
    )

    let result = try collector.collect(request)

    #expect(result.qualification == .tracer)
    #expect(!result.authenticatedProductionDriver)
    #expect(result.trials.count == 1)
    #expect(result.trials[0].trial == 1)
    #expect(result.trials[0].coldLoadDurationNanoseconds == 250)
    #expect(result.trials[0].helperExitConfirmed)
    #expect(result.trials[0].helperGeneration.pid == 201)
    #expect(
      result.trials[0].helperGeneration.instanceID
        == result.trials[0].helperAttestation.instanceID
    )
    #expect(result.transcript.count == 9)
    #expect(
      result.transcript.map(\.channel) == [
        .collectorToDriver,
        .collectorToHelper,
        .driverToCollector,
        .helperToCollector,
        .driverToCollector,
        .collectorToHelper,
        .helperToCollector,
        .collectorToHelper,
        .helperToCollector,
      ])
    #expect(transport.acceptedRoles == [.driver, .helper])
    #expect(
      transport.acceptedRequests[0].expectedSigningIdentifier
        == VoicePerformanceMeasurementPolicy
        .requiredDriverSigningIdentifier
    )
    #expect(
      transport.acceptedRequests[1].expectedExecutableSHA256
        == fixture.measurementPolicy.helper
        .expectedExecutableSHA256
    )
    #expect(transport.connectionsAreClosed)
    #expect(transport.helpersConfirmedExit)
    #expect(
      try VoicePerformanceTracerResult.decodeCanonical(
        result.encodedCanonical()
      ) == result
    )
    #expect(try result.encodedCanonical().count > 0)
  }

  @Test("transport cleanup failure prevents final evidence publication")
  func cleanupFailurePreventsFinalEvidencePublication() throws {
    let fixture = try TracerFixture()
    let transport = try ScriptedTracerTransport(
      fixture: fixture,
      closeSucceeds: false
    )
    let collector = VoicePerformanceTracerCollector(
      transport: transport,
      nonceSource: SequenceTracerNonceSource([
        try nonce("c", suffix: 1),
        try nonce("c", suffix: 2),
        try nonce("c", suffix: 3),
      ]),
      monotonicClock: SequenceTracerMonotonicClock([100, 350])
    )
    let request = try VoicePerformanceTracerCollectionRequest(
      measurementPolicy: fixture.measurementPolicy,
      driverPolicy: fixture.driverPolicy
    )

    #expect(throws: VoicePerformanceTracerCollectorError.transportFailure) {
      _ = try collector.collect(request)
    }
    #expect(transport.closeCallCount == 1)
    #expect(transport.connectionsAreClosed)
    #expect(transport.helpersConfirmedExit)
  }

  @Test("thirty-two trials derive ordered sessions and rotate helpers")
  func collectsMaximumColdTrialsWithFreshHelpers() throws {
    let fixture = try TracerFixture(coldTrials: 32)
    let transport = try ScriptedTracerTransport(
      fixture: fixture,
      trials: 32
    )
    let nonces = try (1...96).map {
      try nonce("c", suffix: $0)
    }
    let ticks = (1...32).flatMap { trial -> [UInt64] in
      let begin = UInt64(trial) * 1_000
      return [begin, begin + 250]
    }
    let collector = VoicePerformanceTracerCollector(
      transport: transport,
      nonceSource: SequenceTracerNonceSource(nonces),
      monotonicClock: SequenceTracerMonotonicClock(ticks)
    )
    let request = try VoicePerformanceTracerCollectionRequest(
      measurementPolicy: fixture.measurementPolicy,
      driverPolicy: fixture.driverPolicy
    )

    let result = try collector.collect(request)

    #expect(result.trials.count == 32)
    #expect(result.transcript.count == 288)
    #expect(result.trials.map(\.trial) == Array(UInt64(1)...32))
    #expect(Set(result.trials.map(\.helperGeneration)).count == 32)
    #expect(Set(result.trials.map(\.helperAttestation.instanceID)).count == 32)
    #expect(Set(result.trials.map(\.loadTicket)).count == 32)
    for trial in result.trials {
      let expected = try PerformanceControlSessionBinding.derive(
        controlSessionNonce: PerformanceControlNonce(
          fixture.measurementPolicy.controlSessionNonce
        ),
        trial: trial.trial
      )
      #expect(trial.sessionID == expected.sessionID)
      #expect(trial.planNonce == expected.planNonce)
      #expect(trial.coldLoadDurationNanoseconds == 250)
    }
    #expect(transport.acceptedRoles.count == 33)
    #expect(transport.connectionsAreClosed)
    #expect(transport.helpersConfirmedExit)
    #expect(
      try VoicePerformanceTracerResult.decodeCanonical(
        result.encodedCanonical()
      ) == result
    )
  }

  @Test("tracer result round-trips only exact canonical bounded JSON")
  func resultIsExactCanonicalAndBounded() throws {
    let fixture = try TracerFixture()
    let transport = try ScriptedTracerTransport(fixture: fixture)
    let collector = VoicePerformanceTracerCollector(
      transport: transport,
      nonceSource: SequenceTracerNonceSource([
        try nonce("c", suffix: 1),
        try nonce("c", suffix: 2),
        try nonce("c", suffix: 3),
      ]),
      monotonicClock: SequenceTracerMonotonicClock([100, 350])
    )
    let result = try collector.collect(
      VoicePerformanceTracerCollectionRequest(
        measurementPolicy: fixture.measurementPolicy,
        driverPolicy: fixture.driverPolicy
      )
    )
    let canonical = try result.encodedCanonical()

    #expect(
      try VoicePerformanceTracerResult.decodeCanonical(canonical)
        == result
    )

    let text = String(decoding: canonical, as: UTF8.self)
    let invalid = [
      Data([0x20] + canonical),
      Data(
        text.replacingOccurrences(
          of: #""authenticated_production_driver":false"#,
          with: #""authenticated_production_driver":true"#
        ).utf8),
      Data(
        text.replacingOccurrences(
          of: #""qualification":"tracer""#,
          with: #""qualification":"production""#
        ).utf8),
      Data(
        text.replacingOccurrences(
          of: #""schema_version":2"#,
          with: #""schema_version":2,"unknown":0"#
        ).utf8),
      Data(
        text.replacingOccurrences(
          of: #""schema_version":2"#,
          with: #""schema_version":2.0"#
        ).utf8),
      Data(
        text.replacingOccurrences(
          of: #""helper_exit_confirmed":true"#,
          with: #""helper_exit_confirmed":false"#
        ).utf8),
      Data(
        text.replacingOccurrences(
          of: #""cold_load_duration_ns":250"#,
          with: #""cold_load_duration_ns":0"#
        ).utf8),
      Data(
        repeating: 0x20,
        count:
          VoicePerformanceTracerResult.maximumEncodedBytes + 1),
    ]
    #expect(invalid[4] != canonical)
    for data in invalid {
      #expect(
        throws: VoicePerformanceTracerCollectorError.invalidResult
      ) {
        try VoicePerformanceTracerResult.decodeCanonical(data)
      }
    }
  }

  @Test("transport failures are classified and leave the collector terminal")
  func transportFailuresAreTerminal() throws {
    let fixture = try TracerFixture()
    let request = try VoicePerformanceTracerCollectionRequest(
      measurementPolicy: fixture.measurementPolicy,
      driverPolicy: fixture.driverPolicy
    )
    let cases:
      [(
        VoicePerformanceTracerTransportError,
        VoicePerformanceTracerCollectorError
      )] = [
        (.timedOut, .timedOut),
        (.disconnected, .disconnected),
        (.authenticationFailed, .authenticationFailed),
        (.failed, .transportFailure),
      ]
    for (transportError, expected) in cases {
      let collector = VoicePerformanceTracerCollector(
        transport: ImmediateFailureTracerTransport(
          transportError,
          controlSocketPath: fixture.measurementPolicy.controlSocketPath
        ),
        nonceSource: SequenceTracerNonceSource([]),
        monotonicClock: SequenceTracerMonotonicClock([])
      )
      #expect(throws: expected) {
        try collector.collect(request)
      }
      #expect(throws: VoicePerformanceTracerCollectorError.terminal) {
        try collector.collect(request)
      }
    }
  }

  @Test("unexpected transport errors remain internal instead of I/O failures")
  func unexpectedTransportErrorIsInternal() throws {
    let fixture = try TracerFixture()
    let request = try VoicePerformanceTracerCollectionRequest(
      measurementPolicy: fixture.measurementPolicy,
      driverPolicy: fixture.driverPolicy
    )
    let collector = VoicePerformanceTracerCollector(
      transport: UnexpectedFailureTracerTransport(
        failure: SensitiveCollectorUnexpectedError(
          description: "orchestration-secret-5c09"
        ),
        controlSocketPath: fixture.measurementPolicy.controlSocketPath
      ),
      nonceSource: SequenceTracerNonceSource([]),
      monotonicClock: SequenceTracerMonotonicClock([])
    )

    #expect(throws: VoicePerformanceTracerCollectorError.internalFailure) {
      try collector.collect(request)
    }
    #expect(throws: VoicePerformanceTracerCollectorError.terminal) {
      try collector.collect(request)
    }
  }

  @Test("an expired global deadline fails before transport I/O")
  func expiredGlobalDeadlineFailsBeforeTransportIO() throws {
    let fixture = try TracerFixture()
    let transport = try ScriptedTracerTransport(fixture: fixture)
    let collector = VoicePerformanceTracerCollector(
      transport: transport,
      nonceSource: SequenceTracerNonceSource([]),
      monotonicClock: SequenceTracerMonotonicClock([])
    )

    #expect(throws: VoicePerformanceTracerCollectorError.timedOut) {
      try collector.collect(
        makeRequest(fixture: fixture),
        deadline: ContinuousClock().now.advanced(by: .seconds(-1))
      )
    }
    #expect(transport.acceptedRoles.isEmpty)
    #expect(transport.observedDeadlines.isEmpty)
    #expect(throws: VoicePerformanceTracerCollectorError.terminal) {
      try collector.collect(
        makeRequest(fixture: fixture),
        deadline: ContinuousClock().now.advanced(by: .seconds(1))
      )
    }
  }

  @Test("every transport operation is capped by one global deadline")
  func allTransportDeadlinesAreCappedGlobally() throws {
    let fixture = try TracerFixture()
    let transport = try ScriptedTracerTransport(fixture: fixture)
    let collector = VoicePerformanceTracerCollector(
      transport: transport,
      nonceSource: SequenceTracerNonceSource([
        try nonce("c", suffix: 1),
        try nonce("c", suffix: 2),
        try nonce("c", suffix: 3),
      ]),
      monotonicClock: SequenceTracerMonotonicClock([100, 350])
    )
    let globalDeadline = ContinuousClock().now.advanced(by: .seconds(1))

    _ = try collector.collect(
      makeRequest(fixture: fixture),
      deadline: globalDeadline
    )

    #expect(!transport.allObservedDeadlines.isEmpty)
    #expect(
      transport.allObservedDeadlines.allSatisfy { $0 <= globalDeadline }
    )
  }

  @Test("accept frame engine-ready and exit phases use fixed absolute caps")
  func phaseDeadlinesUseTheirDeclaredLimits() throws {
    let fixture = try TracerFixture()
    let transport = try ScriptedTracerTransport(fixture: fixture)
    let base = ContinuousClock().now
    let collector = VoicePerformanceTracerCollector(
      transport: transport,
      nonceSource: SequenceTracerNonceSource([
        try nonce("c", suffix: 1),
        try nonce("c", suffix: 2),
        try nonce("c", suffix: 3),
      ]),
      monotonicClock: SequenceTracerMonotonicClock([100, 350]),
      continuousClock: FixedTracerContinuousClock(base)
    )

    _ = try collector.collect(
      makeRequest(fixture: fixture),
      deadline: base.advanced(by: .seconds(120))
    )

    #expect(
      transport.observedDeadlines == [
        base.advanced(by: .seconds(15)),
        base.advanced(by: .seconds(15)),
      ]
    )
    #expect(
      transport.driverObservedDeadlines.allSatisfy {
        $0 == base.advanced(by: .seconds(5))
      }
    )
    #expect(
      transport.helperObservedDeadlines == [
        base.advanced(by: .seconds(5)),
        base.advanced(by: .seconds(10)),
        base.advanced(by: .seconds(5)),
        base.advanced(by: .seconds(10)),
        base.advanced(by: .seconds(5)),
        base.advanced(by: .seconds(65)),
        base.advanced(by: .seconds(15)),
      ]
    )
  }

  @Test("load-ready delivery uses an exclusive sixty-five-second deadline")
  func loadReadyDeadlineIncludesDeliveryWindow() throws {
    let fixture = try TracerFixture()
    let base = ContinuousClock().now
    let exactBoundary = base.advanced(by: .seconds(65))
    let acceptedTransport = try ScriptedTracerTransport(
      fixture: fixture,
      fault: .loadReadyArrivesAt(
        exactBoundary.advanced(by: .nanoseconds(-1))
      )
    )
    let accepted = VoicePerformanceTracerCollector(
      transport: acceptedTransport,
      nonceSource: SequenceTracerNonceSource([
        try nonce("c", suffix: 1),
        try nonce("c", suffix: 2),
        try nonce("c", suffix: 3),
      ]),
      monotonicClock: SequenceTracerMonotonicClock([100, 350]),
      continuousClock: FixedTracerContinuousClock(base)
    )

    _ = try accepted.collect(
      makeRequest(fixture: fixture),
      deadline: base.advanced(by: .seconds(120))
    )
    #expect(
      acceptedTransport.helperObservedDeadlines[5] == exactBoundary
    )

    let lateTransport = try ScriptedTracerTransport(
      fixture: fixture,
      fault: .loadReadyArrivesAt(exactBoundary)
    )
    let late = VoicePerformanceTracerCollector(
      transport: lateTransport,
      nonceSource: SequenceTracerNonceSource([
        try nonce("c", suffix: 1),
        try nonce("c", suffix: 2),
        try nonce("c", suffix: 3),
      ]),
      monotonicClock: SequenceTracerMonotonicClock([100, 350]),
      continuousClock: FixedTracerContinuousClock(base)
    )
    #expect(throws: VoicePerformanceTracerCollectorError.timedOut) {
      try late.collect(
        makeRequest(fixture: fixture),
        deadline: base.advanced(by: .seconds(120))
      )
    }
  }

  @Test("collector nonce exhaustion and reuse fail terminally")
  func collectorOwnedNonceFailuresAreTerminal() throws {
    let fixture = try TracerFixture()
    let request = try VoicePerformanceTracerCollectionRequest(
      measurementPolicy: fixture.measurementPolicy,
      driverPolicy: fixture.driverPolicy
    )
    let nonceSequences = try [
      [nonce("c", suffix: 1)],
      [nonce("c", suffix: 1), nonce("c", suffix: 1)],
    ]
    for nonces in nonceSequences {
      let transport = try ScriptedTracerTransport(fixture: fixture)
      let collector = VoicePerformanceTracerCollector(
        transport: transport,
        nonceSource: SequenceTracerNonceSource(nonces),
        monotonicClock: SequenceTracerMonotonicClock([])
      )
      #expect(
        throws: VoicePerformanceTracerCollectorError.entropyFailure
      ) {
        try collector.collect(request)
      }
      #expect(transport.connectionsAreClosed)
      #expect(transport.helpersConfirmedExit)
      #expect(throws: VoicePerformanceTracerCollectorError.terminal) {
        try collector.collect(request)
      }
    }
  }

  @Test("illegal protocol input is terminal and closes both peers")
  func illegalProtocolInputIsTerminal() throws {
    let fixture = try TracerFixture()
    let transport = try ScriptedTracerTransport(
      fixture: fixture,
      fault: .wrongArmTrial
    )
    let collector = try makeCollector(
      transport: transport,
      fixture: fixture,
      ticks: []
    )
    let request = try makeRequest(fixture: fixture)

    #expect(
      throws: VoicePerformanceTracerCollectorError.protocolViolation
    ) {
      try collector.collect(request)
    }
    #expect(transport.connectionsAreClosed)
    #expect(transport.helpersConfirmedExit)
    #expect(throws: VoicePerformanceTracerCollectorError.terminal) {
      try collector.collect(request)
    }
  }

  @Test("midstream disconnect and helper-exit timeout are terminal")
  func midstreamTransportFailuresClosePeers() throws {
    let fixture = try TracerFixture()
    let cases: [(ScriptedTracerFault, VoicePerformanceTracerCollectorError)] = [
      (.helperReceive(1, .disconnected), .disconnected),
      (.helperExit(.timedOut), .timedOut),
    ]
    for (fault, expected) in cases {
      let transport = try ScriptedTracerTransport(
        fixture: fixture,
        fault: fault
      )
      let collector = try makeCollector(
        transport: transport,
        fixture: fixture,
        ticks: [100, 350]
      )
      #expect(throws: expected) {
        try collector.collect(makeRequest(fixture: fixture))
      }
      #expect(transport.connectionsAreClosed)
      #expect(transport.helpersConfirmedExit)
      #expect(throws: VoicePerformanceTracerCollectorError.terminal) {
        try collector.collect(makeRequest(fixture: fixture))
      }
    }
  }

  @Test("transport endpoint cannot be spliced with another policy")
  func transportEndpointIsBoundBeforeAccept() throws {
    let fixture = try TracerFixture()
    let transport = try ScriptedTracerTransport(
      fixture: fixture,
      controlSocketPath: "/private/tmp/another.sock"
    )
    let collector = try makeCollector(
      transport: transport,
      fixture: fixture,
      ticks: []
    )

    #expect(throws: VoicePerformanceTracerCollectorError.invalidRequest) {
      try collector.collect(makeRequest(fixture: fixture))
    }
    #expect(transport.acceptedRoles.isEmpty)
  }

  @Test("helper cleanup failure takes precedence over a protocol failure")
  func cleanupFailureTakesPrecedence() throws {
    let fixture = try TracerFixture()
    let transport = try ScriptedTracerTransport(
      fixture: fixture,
      fault: .helperReceiveAndExit(
        1,
        .disconnected,
        .timedOut
      )
    )
    let collector = try makeCollector(
      transport: transport,
      fixture: fixture,
      ticks: []
    )

    #expect(throws: VoicePerformanceTracerCollectorError.timedOut) {
      try collector.collect(makeRequest(fixture: fixture))
    }
    #expect(transport.helpersConfirmedExit)
  }

  @Test("attestation and duration invariants fail closed")
  func attestationAndDurationInvariantsFailClosed() throws {
    let fixture = try TracerFixture()
    let cases:
      [(
        ScriptedTracerFault,
        [UInt64],
        VoicePerformanceTracerCollectorError
      )] = [
        (.helperEffectiveUserID(502), [100, 350], .authenticationFailed),
        (.none, [350, 100], .invalidDuration),
      ]
    for (fault, ticks, expected) in cases {
      let transport = try ScriptedTracerTransport(
        fixture: fixture,
        fault: fault
      )
      let collector = try makeCollector(
        transport: transport,
        fixture: fixture,
        ticks: ticks
      )
      #expect(throws: expected) {
        try collector.collect(makeRequest(fixture: fixture))
      }
      #expect(transport.connectionsAreClosed)
      #expect(transport.helpersConfirmedExit)
    }
  }

  private func makeRequest(fixture: TracerFixture)
    throws -> VoicePerformanceTracerCollectionRequest
  {
    try VoicePerformanceTracerCollectionRequest(
      measurementPolicy: fixture.measurementPolicy,
      driverPolicy: fixture.driverPolicy
    )
  }

  private func makeCollector(
    transport: ScriptedTracerTransport,
    fixture _: TracerFixture,
    ticks: [UInt64]
  ) throws -> VoicePerformanceTracerCollector {
    VoicePerformanceTracerCollector(
      transport: transport,
      nonceSource: SequenceTracerNonceSource([
        try nonce("c", suffix: 1),
        try nonce("c", suffix: 2),
        try nonce("c", suffix: 3),
      ]),
      monotonicClock: SequenceTracerMonotonicClock(ticks)
    )
  }
}

private struct TracerFixture {
  let measurementPolicy: VoicePerformanceMeasurementPolicy
  let driverPolicy: SealedPerformanceControlDriverPolicy
  let expectedEngine: ExpectedPerformanceControlEngine
  let engineSummary: PerformanceControlEngineSummary

  init(coldTrials: UInt64 = 1) throws {
    let controlProtocol = try PerformanceControlProtocolIdentity(
      sha256: String(repeating: "a", count: 64)
    )
    let driverPolicyData = Data(
      (#"{"capabilities":["authenticated_control","lazy_load_ticket"],"control_protocol":{"id":"rimeai-performance-control-v2","sha256":""#
        + controlProtocol.sha256
        + #""},"qualification":"tracer","schema_version":1}"#).utf8
    )
    driverPolicy = try SealedPerformanceControlDriverPolicy.decodeCanonical(
      driverPolicyData,
      expectedControlProtocol: controlProtocol
    )
    measurementPolicy = try VoicePerformanceMeasurementPolicy.decodeCanonical(
      Self.measurementPolicyData(
        controlProtocolSHA256: controlProtocol.sha256,
        driverPolicySHA256: driverPolicy.canonicalSHA256.rawValue,
        coldTrials: coldTrials
      )
    )
    engineSummary = try PerformanceControlEngineSummary(
      adapterID: ControlledPerformanceID("sherpa-onnx"),
      engineID: "sherpa-onnx@" + String(repeating: "4", count: 16),
      artifactID: ControlledPerformanceID("voice-model"),
      artifactContentSHA256: PerformanceControlSHA256(
        String(repeating: "4", count: 64)
      ),
      artifactGeneration: PerformanceControlArtifactGeneration(
        "00000000-0000-4000-8000-000000000001"
      ),
      capabilities: [
        try ControlledPerformanceID("hotword_snapshot"),
        try ControlledPerformanceID("local_asr"),
        try ControlledPerformanceID("streaming"),
      ],
      networkPolicy: .offline,
      maximumHotwords: 64
    )
    expectedEngine = measurementPolicy.expectedEngine
    #expect(expectedEngine.matches(engineSummary))
  }

  private static func measurementPolicyData(
    controlProtocolSHA256: String,
    driverPolicySHA256: String,
    coldTrials: UInt64
  ) -> Data {
    Data(
      (#"{"cold_trials":"# + String(coldTrials)
        + #","collector":{"expected_cdhash":""#
        + String(repeating: "d", count: 40)
        + #"","expected_executable_path":"/usr/local/libexec/rimeai-voice-performance-collector","expected_executable_sha256":""#
        + String(repeating: "c", count: 64)
        + #"","expected_signing_identifier":"fun.wwcn.rimeai.voice-performance-collector","expected_team_identifier":"TEAMID1234"},"control_protocol":{"id":"rimeai-performance-control-v2","sha256":""#
        + controlProtocolSHA256
        + #""},"control_session_nonce":""#
        + String(repeating: "b", count: 64)
        + #"","control_socket_path":"/private/tmp/rimeai-performance.sock","driver":{"expected_cdhash":""#
        + String(repeating: "f", count: 40)
        + #"","expected_executable_path":"/usr/local/bin/rimeai-voice-performance-driver","expected_executable_sha256":""#
        + String(repeating: "e", count: 64)
        + #"","expected_signing_identifier":"fun.wwcn.rimeai.voice-performance-driver","expected_team_identifier":"TEAMID1234","policy_sha256":""#
        + driverPolicySHA256
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
}

private final class ScriptedTracerTransport:
  VoicePerformanceTracerTransport,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let driver: ScriptedDriverConnection
  private let helpers: [ScriptedHelperConnection]
  private let closeSucceeds: Bool
  private var nextHelper = 0
  private var closeCalls = 0
  let controlSocketPath: String
  private(set) var acceptedRoles: [PerformanceControlPeerRole] = []
  private(set) var acceptedRequests: [VoicePerformanceTracerPeerRequest] = []
  private(set) var observedDeadlines: [ContinuousClock.Instant] = []

  init(
    fixture: TracerFixture,
    trials: Int = 1,
    fault: ScriptedTracerFault = .none,
    controlSocketPath: String? = nil,
    closeSucceeds: Bool = true
  ) throws {
    self.controlSocketPath = controlSocketPath
      ?? fixture.measurementPolicy.controlSocketPath
    driver = try ScriptedDriverConnection(
      fixture: fixture,
      wrongArmTrial: fault == .wrongArmTrial
    )
    helpers = try (1...trials).map {
      try ScriptedHelperConnection(
        trial: UInt64($0),
        fixture: fixture,
        fault: fault
      )
    }
    self.closeSucceeds = closeSucceeds
  }

  func bindLaunchedDriver(
    _: VoicePerformanceTracerLaunchedDriverIdentity
  ) throws {}

  func acceptAuthenticatedConnection(
    _ request: VoicePerformanceTracerPeerRequest,
    deadline: ContinuousClock.Instant
  ) throws -> any VoicePerformanceTracerConnection {
    lock.lock()
    defer { lock.unlock() }
    acceptedRoles.append(request.role)
    acceptedRequests.append(request)
    observedDeadlines.append(deadline)
    switch request.role {
    case .driver:
      return driver
    case .helper:
      guard request.trial == UInt64(nextHelper + 1),
        nextHelper < helpers.count,
        nextHelper == 0 || helpers[nextHelper - 1].didConfirmExit
      else {
        throw VoicePerformanceTracerTransportError.failed
      }
      defer { nextHelper += 1 }
      return helpers[nextHelper]
    }
  }

  @discardableResult
  func close() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    closeCalls += 1
    return closeSucceeds
  }

  var closeCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return closeCalls
  }

  var connectionsAreClosed: Bool {
    driver.isClosed && helpers.allSatisfy(\.isClosed)
  }

  var helpersConfirmedExit: Bool {
    helpers.allSatisfy { $0.exitConfirmationCount == 1 }
  }

  var allObservedDeadlines: [ContinuousClock.Instant] {
    observedDeadlines
      + driver.observedDeadlines
      + helpers.flatMap(\.observedDeadlines)
  }


  var driverObservedDeadlines: [ContinuousClock.Instant] {
    driver.observedDeadlines
  }

  var helperObservedDeadlines: [ContinuousClock.Instant] {
    helpers.flatMap(\.observedDeadlines)
  }
}

private enum ScriptedTracerFault: Equatable {
  case none
  case wrongArmTrial
  case helperReceive(Int, VoicePerformanceTracerTransportError)
  case helperReceiveAndExit(
    Int,
    VoicePerformanceTracerTransportError,
    VoicePerformanceTracerTransportError
  )
  case helperExit(VoicePerformanceTracerTransportError)
  case helperEffectiveUserID(UInt32)
  case loadReadyArrivesAt(ContinuousClock.Instant)
}

private struct ImmediateFailureTracerTransport:
  VoicePerformanceTracerTransport
{
  let failure: VoicePerformanceTracerTransportError
  let controlSocketPath: String

  init(
    _ failure: VoicePerformanceTracerTransportError,
    controlSocketPath: String
  ) {
    self.failure = failure
    self.controlSocketPath = controlSocketPath
  }

  func bindLaunchedDriver(
    _: VoicePerformanceTracerLaunchedDriverIdentity
  ) throws {}

  func acceptAuthenticatedConnection(
    _: VoicePerformanceTracerPeerRequest,
    deadline _: ContinuousClock.Instant
  ) throws -> any VoicePerformanceTracerConnection {
    throw failure
  }

  @discardableResult
  func close() -> Bool { true }
}

private struct UnexpectedFailureTracerTransport:
  VoicePerformanceTracerTransport
{
  let failure: SensitiveCollectorUnexpectedError
  let controlSocketPath: String

  func bindLaunchedDriver(
    _: VoicePerformanceTracerLaunchedDriverIdentity
  ) throws {}

  func acceptAuthenticatedConnection(
    _: VoicePerformanceTracerPeerRequest,
    deadline _: ContinuousClock.Instant
  ) throws -> any VoicePerformanceTracerConnection {
    throw failure
  }

  @discardableResult
  func close() -> Bool { true }
}

private struct SensitiveCollectorUnexpectedError:
  Error,
  Equatable,
  Sendable,
  CustomStringConvertible
{
  let description: String
}

private final class ScriptedDriverConnection:
  VoicePerformanceTracerConnection,
  @unchecked Sendable
{
  let attestedPeer: VoicePerformanceTracerAttestedPeer
  private let fixture: TracerFixture
  private var challenge: PerformanceControlWireFrame?
  private var nextResponseIsHello = true
  private var currentTrial: UInt64 = 0
  private let wrongArmTrial: Bool
  private(set) var isClosed = false
  private(set) var observedDeadlines: [ContinuousClock.Instant] = []

  init(fixture: TracerFixture, wrongArmTrial: Bool) throws {
    self.fixture = fixture
    self.wrongArmTrial = wrongArmTrial
    attestedPeer = try VoicePerformanceTracerAttestedPeer(
      pid: 101,
      effectiveUserID: 501,
      processStartToken: 1_001,
      pidVersion: 1,
      instanceID: String(repeating: "d", count: 64)
    )
  }

  func send(
    _ frame: PerformanceControlWireFrame,
    deadline: ContinuousClock.Instant
  ) throws {
    observedDeadlines.append(deadline)
    challenge = frame
    nextResponseIsHello = true
    currentTrial += 1
  }

  func receive(
    deadline: ContinuousClock.Instant
  ) throws -> PerformanceControlWireFrame {
    observedDeadlines.append(deadline)
    guard
      case .challenge(
        .driver,
        let
          sessionID,
        let
          planNonce,
        let
          collectorNonce
      ) = challenge
    else {
      throw VoicePerformanceTracerTransportError.failed
    }
    if nextResponseIsHello {
      nextResponseIsHello = false
      return .driverHello(
        sessionID: sessionID,
        planNonce: planNonce,
        collectorNonce: collectorNonce,
        peerNonce: try nonce("d", suffix: Int(currentTrial)),
        collectionProtocol: fixture.driverPolicy.controlProtocol,
        driverPolicySHA256: fixture.driverPolicy.canonicalSHA256,
        measurementPolicySHA256: try PerformanceControlSHA256(
          fixture.measurementPolicy.canonicalSHA256
        )
      )
    }
    return .armColdLoad(
      sequence: 1,
      sessionID: sessionID,
      trial: wrongArmTrial ? currentTrial + 1 : currentTrial
    )
  }

  func close() { isClosed = true }

  func closeAndConfirmPeerExit(
    deadline: ContinuousClock.Instant
  ) throws {
    observedDeadlines.append(deadline)
    isClosed = true
  }
}

private final class ScriptedHelperConnection:
  VoicePerformanceTracerConnection,
  @unchecked Sendable
{
  let attestedPeer: VoicePerformanceTracerAttestedPeer
  private let trial: UInt64
  private let fixture: TracerFixture
  private let fault: ScriptedTracerFault
  private var sent: [PerformanceControlWireFrame] = []
  private var response = 0
  private(set) var isClosed = false
  private(set) var didConfirmExit = false
  private(set) var exitConfirmationCount = 0
  private(set) var observedDeadlines: [ContinuousClock.Instant] = []

  init(
    trial: UInt64,
    fixture: TracerFixture,
    fault: ScriptedTracerFault
  ) throws {
    self.trial = trial
    self.fixture = fixture
    self.fault = fault
    let effectiveUserID: UInt32
    if case .helperEffectiveUserID(let value) = fault {
      effectiveUserID = value
    } else {
      effectiveUserID = 501
    }
    attestedPeer = try VoicePerformanceTracerAttestedPeer(
      pid: Int32(200 + trial),
      effectiveUserID: effectiveUserID,
      processStartToken: 2_000 + trial,
      pidVersion: Int32(trial),
      instanceID: try nonce("e", suffix: Int(trial)).rawValue
    )
  }

  func send(
    _ frame: PerformanceControlWireFrame,
    deadline: ContinuousClock.Instant
  ) throws {
    observedDeadlines.append(deadline)
    sent.append(frame)
  }

  func receive(
    deadline: ContinuousClock.Instant
  ) throws -> PerformanceControlWireFrame {
    observedDeadlines.append(deadline)
    if case .loadReadyArrivesAt(let arrival) = fault,
      response == 2,
      deadline <= arrival
    {
      throw VoicePerformanceTracerTransportError.timedOut
    }
    if case .helperReceive(let failingResponse, let error) = fault,
      response == failingResponse
    {
      throw error
    }
    if case .helperReceiveAndExit(
      let failingResponse,
      let error,
      _
    ) = fault,
      response == failingResponse
    {
      throw error
    }
    defer { response += 1 }
    switch response {
    case 0:
      guard
        case .challenge(
          .helper,
          let
            sessionID,
          let
            planNonce,
          let
            collectorNonce
        ) = sent.first
      else {
        throw VoicePerformanceTracerTransportError.failed
      }
      return .helperHello(
        sessionID: sessionID,
        planNonce: planNonce,
        collectorNonce: collectorNonce,
        peerNonce: try nonce("f", suffix: Int(trial)),
        measurementPolicySHA256: try PerformanceControlSHA256(
          fixture.measurementPolicy.canonicalSHA256
        ),
        releasePolicySHA256: try PerformanceControlSHA256(
          fixture.measurementPolicy.releasePolicySHA256
        )
      )
    case 1:
      guard
        case .loadEngine(
          let
            sequence,
          let
            sessionID,
          let
            receivedTrial,
          let
            ticket
        ) = sent.last
      else {
        throw VoicePerformanceTracerTransportError.failed
      }
      return .loadStarted(
        sequence: 1,
        sessionID: sessionID,
        replyTo: sequence,
        trial: receivedTrial,
        loadTicket: ticket
      )
    case 2:
      guard
        case .loadStartedAck(
          let
            sequence,
          let
            sessionID,
          _,
          let
            receivedTrial,
          let
            ticket
        ) = sent.last
      else {
        throw VoicePerformanceTracerTransportError.failed
      }
      let summary = try PerformanceControlEngineSummary(
        adapterID: fixture.expectedEngine.adapterID,
        engineID: fixture.expectedEngine.engineID,
        artifactID: fixture.expectedEngine.artifactID,
        artifactContentSHA256:
          fixture.expectedEngine.artifactContentSHA256,
        artifactGeneration: PerformanceControlArtifactGeneration(
          String(
            format:
              "00000000-0000-4000-8000-%012llu",
            trial
          )
        ),
        capabilities: fixture.expectedEngine.capabilities,
        networkPolicy: fixture.expectedEngine.networkPolicy,
        maximumHotwords: fixture.expectedEngine.maximumHotwords
      )
      return .loadReady(
        sequence: 2,
        sessionID: sessionID,
        replyTo: sequence,
        trial: receivedTrial,
        loadTicket: ticket,
        engine: summary
      )
    default:
      throw VoicePerformanceTracerTransportError.failed
    }
  }

  func close() { isClosed = true }

  func closeAndConfirmPeerExit(
    deadline: ContinuousClock.Instant
  ) throws {
    observedDeadlines.append(deadline)
    isClosed = true
    didConfirmExit = true
    exitConfirmationCount += 1
    if case .helperExit(let error) = fault {
      throw error
    }
    if case .helperReceiveAndExit(_, _, let error) = fault {
      throw error
    }
  }
}

private struct SequenceTracerNonceSource: VoicePerformanceTracerNonceSource {
  private final class Storage: @unchecked Sendable {
    let lock = NSLock()
    var values: [PerformanceControlNonce]
    init(_ values: [PerformanceControlNonce]) { self.values = values }
  }
  private let storage: Storage
  init(_ values: [PerformanceControlNonce]) { storage = Storage(values) }
  func nextNonce() throws -> PerformanceControlNonce {
    storage.lock.lock()
    defer { storage.lock.unlock() }
    guard !storage.values.isEmpty else {
      throw VoicePerformanceTracerCollectorError.entropyFailure
    }
    return storage.values.removeFirst()
  }
}

private struct SequenceTracerMonotonicClock:
  VoicePerformanceTracerMonotonicClock
{
  private final class Storage: @unchecked Sendable {
    let lock = NSLock()
    var values: [UInt64]
    init(_ values: [UInt64]) { self.values = values }
  }
  private let storage: Storage
  init(_ values: [UInt64]) { storage = Storage(values) }
  func nowNanoseconds() -> UInt64 {
    storage.lock.lock()
    defer { storage.lock.unlock() }
    return storage.values.removeFirst()
  }
}

private struct FixedTracerContinuousClock:
  VoicePerformanceTracerContinuousClock
{
  let now: ContinuousClock.Instant
  init(_ now: ContinuousClock.Instant) { self.now = now }
}

private func nonce(_ fill: Character, suffix: Int) throws
  -> PerformanceControlNonce
{
  let tail = String(format: "%08x", UInt32(truncatingIfNeeded: suffix))
  return try PerformanceControlNonce(
    String(repeating: String(fill), count: 64 - tail.count) + tail
  )
}
