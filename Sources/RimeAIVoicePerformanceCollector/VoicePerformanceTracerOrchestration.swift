import Foundation
import RimeAIVoicePerformanceControlCore
import Security

public enum VoicePerformanceTracerCollectorError:
  Error,
  Equatable,
  Sendable
{
  case invalidRequest
  case alreadyRun
  case terminal
  case authenticationFailed
  case timedOut
  case disconnected
  case transportFailure
  case protocolViolation
  case entropyFailure
  case invalidDuration
  case invalidResult
  case internalFailure
}

public struct VoicePerformanceTracerCollectionRequest: Sendable {
  public let measurementPolicy: VoicePerformanceMeasurementPolicy
  public let driverPolicy: SealedPerformanceControlDriverPolicy

  public var expectedEngine: ExpectedPerformanceControlEngine {
    measurementPolicy.expectedEngine
  }

  public var coldTrials: UInt64 { measurementPolicy.coldTrials }

  public let qualification = PerformanceControlQualification.tracer
  public let authenticatedProductionDriver = false

  public init(
    measurementPolicy: VoicePerformanceMeasurementPolicy,
    driverPolicy: SealedPerformanceControlDriverPolicy
  ) throws {
    guard
      PerformanceControlSessionBinding.supportedTrials
        .contains(measurementPolicy.coldTrials),
      measurementPolicy.qualification == .tracer,
      !measurementPolicy.authenticatedProductionDriver,
      driverPolicy.qualification == .tracer,
      !driverPolicy.authenticatedProductionDriver,
      measurementPolicy.controlProtocol == driverPolicy.controlProtocol,
      measurementPolicy.driver.policySHA256
        == driverPolicy.canonicalSHA256.rawValue,
      (try? PerformanceControlNonce(
        measurementPolicy.controlSessionNonce
      )) != nil,
      (try? PerformanceControlSHA256(
        measurementPolicy.canonicalSHA256
      )) != nil,
      (try? PerformanceControlSHA256(
        measurementPolicy.releasePolicySHA256
      )) != nil
    else {
      throw VoicePerformanceTracerCollectorError.invalidRequest
    }
    self.measurementPolicy = measurementPolicy
    self.driverPolicy = driverPolicy
  }
}

public enum VoicePerformanceTracerTransportError:
  Error,
  Equatable,
  Sendable
{
  case timedOut
  case disconnected
  case authenticationFailed
  case failed
}

/// Exact process generation returned by the supervisor that launched the
/// persistent tracer driver.
public struct VoicePerformanceTracerLaunchedDriverIdentity:
  Equatable,
  Sendable
{
  public let role: PerformanceControlPeerRole
  public let pid: Int32
  public let processStartToken: UInt64
  public let processGroupID: Int32

  public init(
    role: PerformanceControlPeerRole,
    pid: Int32,
    processStartToken: UInt64,
    processGroupID: Int32
  ) {
    self.role = role
    self.pid = pid
    self.processStartToken = processStartToken
    self.processGroupID = processGroupID
  }
}

public struct VoicePerformanceTracerPeerRequest: Equatable, Sendable {
  public let role: PerformanceControlPeerRole
  public let trial: UInt64?
  public let expectedExecutablePath: String
  public let expectedExecutableSHA256: String
  public let expectedSigningIdentifier: String
  public let expectedTeamIdentifier: String
  public let expectedCDHash: String

  init(
    role: PerformanceControlPeerRole,
    trial: UInt64?,
    expectedExecutablePath: String,
    expectedExecutableSHA256: String,
    expectedSigningIdentifier: String,
    expectedTeamIdentifier: String,
    expectedCDHash: String
  ) {
    self.role = role
    self.trial = trial
    self.expectedExecutablePath = expectedExecutablePath
    self.expectedExecutableSHA256 = expectedExecutableSHA256
    self.expectedSigningIdentifier = expectedSigningIdentifier
    self.expectedTeamIdentifier = expectedTeamIdentifier
    self.expectedCDHash = expectedCDHash
  }
}

public protocol VoicePerformanceTracerConnection: AnyObject, Sendable {
  var attestedPeer: VoicePerformanceTracerAttestedPeer { get }

  func send(
    _ frame: PerformanceControlWireFrame,
    deadline: ContinuousClock.Instant
  ) throws

  func receive(
    deadline: ContinuousClock.Instant
  ) throws -> PerformanceControlWireFrame

  func close()

  /// Closes the channel and returns only after this attested process
  /// generation is no longer live.
  func closeAndConfirmPeerExit(
    deadline: ContinuousClock.Instant
  ) throws
}

public protocol VoicePerformanceTracerTransport: Sendable {
  var controlSocketPath: String { get }

  /// Binds the transport once, before its first accept. Implementations must
  /// fail terminally on invalid, repeated, or post-close binding attempts.
  func bindLaunchedDriver(
    _ identity: VoicePerformanceTracerLaunchedDriverIdentity
  ) throws

  func acceptAuthenticatedConnection(
    _ request: VoicePerformanceTracerPeerRequest,
    deadline: ContinuousClock.Instant
  ) throws -> any VoicePerformanceTracerConnection

  /// Terminates the transport and reports whether its owned endpoint was
  /// removed under the same verified filesystem authority that created it.
  @discardableResult
  func close() -> Bool
}

protocol VoicePerformanceTracerNonceSource: Sendable {
  func nextNonce() throws -> PerformanceControlNonce
}

protocol VoicePerformanceTracerMonotonicClock: Sendable {
  func nowNanoseconds() -> UInt64
}

protocol VoicePerformanceTracerContinuousClock: Sendable {
  var now: ContinuousClock.Instant { get }
}

private struct SecureVoicePerformanceTracerNonceSource:
  VoicePerformanceTracerNonceSource
{
  func nextNonce() throws -> PerformanceControlNonce {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard
      SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        == errSecSuccess
    else {
      throw VoicePerformanceTracerCollectorError.entropyFailure
    }
    return try PerformanceControlNonce(
      bytes.map {
        String(format: "%02x", $0)
      }.joined())
  }
}

private struct LiveVoicePerformanceTracerMonotonicClock:
  VoicePerformanceTracerMonotonicClock
{
  func nowNanoseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
  }
}

private struct LiveVoicePerformanceTracerContinuousClock:
  VoicePerformanceTracerContinuousClock
{
  private let clock = ContinuousClock()
  var now: ContinuousClock.Instant { clock.now }
}

public final class VoicePerformanceTracerCollector: @unchecked Sendable {
  private enum RunState {
    case idle
    case running
    case completed
    case failed
  }

  private let transport: any VoicePerformanceTracerTransport
  private let nonceSource: any VoicePerformanceTracerNonceSource
  private let monotonicClock: any VoicePerformanceTracerMonotonicClock
  private let continuousClock: any VoicePerformanceTracerContinuousClock
  private let lock = NSLock()
  private var state = RunState.idle

  public convenience init(transport: any VoicePerformanceTracerTransport) {
    self.init(
      transport: transport,
      nonceSource: SecureVoicePerformanceTracerNonceSource(),
      monotonicClock: LiveVoicePerformanceTracerMonotonicClock(),
      continuousClock: LiveVoicePerformanceTracerContinuousClock()
    )
  }

  init(
    transport: any VoicePerformanceTracerTransport,
    nonceSource: any VoicePerformanceTracerNonceSource,
    monotonicClock: any VoicePerformanceTracerMonotonicClock,
    continuousClock: any VoicePerformanceTracerContinuousClock =
      LiveVoicePerformanceTracerContinuousClock()
  ) {
    self.transport = transport
    self.nonceSource = nonceSource
    self.monotonicClock = monotonicClock
    self.continuousClock = continuousClock
  }

  func collect(
    _ request: VoicePerformanceTracerCollectionRequest
  ) throws -> VoicePerformanceTracerResult {
    try collect(
      request,
      deadline: continuousClock.now.advanced(by: .seconds(3_600))
    )
  }

  /// Collects within one absolute deadline shared by every transport phase.
  public func collect(
    _ request: VoicePerformanceTracerCollectionRequest,
    deadline: ContinuousClock.Instant
  ) throws -> VoicePerformanceTracerResult {
    try collectInternal(request, globalDeadline: deadline)
  }

  private func collectInternal(
    _ request: VoicePerformanceTracerCollectionRequest,
    globalDeadline: ContinuousClock.Instant
  ) throws -> VoicePerformanceTracerResult {
    try beginRun()
    var transportCloseAttempted = false
    do {
      guard continuousClock.now < globalDeadline else {
        throw VoicePerformanceTracerCollectorError.timedOut
      }
      let result = try performCollection(
        request,
        globalDeadline: globalDeadline
      )
      guard
        let encoded = try? result.encodedCanonical(),
        let decoded = try? VoicePerformanceTracerResult
          .decodeCanonical(encoded),
        decoded == result
      else {
        throw VoicePerformanceTracerCollectorError.invalidResult
      }
      transportCloseAttempted = true
      guard transport.close() else {
        throw VoicePerformanceTracerTransportError.failed
      }
      finishRun(.completed)
      return result
    } catch {
      let primary = Self.normalized(error)
      if !transportCloseAttempted {
        transportCloseAttempted = true
        _ = transport.close()
      }
      finishRun(.failed)
      throw primary
    }
  }

  private func performCollection(
    _ request: VoicePerformanceTracerCollectionRequest,
    globalDeadline: ContinuousClock.Instant
  ) throws -> VoicePerformanceTracerResult {
    guard transport.controlSocketPath
      == request.measurementPolicy.controlSocketPath
    else {
      throw VoicePerformanceTracerCollectorError.invalidRequest
    }
    let measurementSHA = try PerformanceControlSHA256(
      request.measurementPolicy.canonicalSHA256
    )
    let releaseSHA = try PerformanceControlSHA256(
      request.measurementPolicy.releasePolicySHA256
    )
    let controlSessionNonce = try PerformanceControlNonce(
      request.measurementPolicy.controlSessionNonce
    )
    var machine = try PerformanceControlStateMachine(
      driverPolicy: request.driverPolicy,
      measurementPolicy: request.measurementPolicy
    )
    let driver = try transport.acceptAuthenticatedConnection(
      Self.driverRequest(request.measurementPolicy),
      deadline: try operationDeadline(
        global: globalDeadline,
        phaseLimit: .seconds(15)
      )
    )
    defer { driver.close() }

    var issuedNonces = Set<PerformanceControlNonce>()
    var helperProcesses = Set<HelperProcessKey>()
    var helperInstances = Set<ControlledPerformanceID>()
    let driverProcess = HelperProcessKey(
      pid: driver.attestedPeer.pid,
      startToken: driver.attestedPeer.processStartToken
    )
    var transcript: [VoicePerformanceTracerTranscriptEntry] = []
    var trials: [VoicePerformanceTracerColdTrialResult] = []

    for trial in UInt64(1)...request.coldTrials {
      let binding = try PerformanceControlSessionBinding.derive(
        controlSessionNonce: controlSessionNonce,
        trial: trial
      )
      let helper = try transport.acceptAuthenticatedConnection(
        Self.helperRequest(request.measurementPolicy, trial: trial),
        deadline: try operationDeadline(
          global: globalDeadline,
          phaseLimit: .seconds(15)
        )
      )
      defer { helper.close() }
      var exitConfirmationAttempted = false
      do {
        let helperProcess = HelperProcessKey(
          pid: helper.attestedPeer.pid,
          startToken: helper.attestedPeer.processStartToken
        )
        guard helperProcess != driverProcess,
          helper.attestedPeer.instanceID
            != driver.attestedPeer.instanceID,
          helper.attestedPeer.effectiveUserID
            == driver.attestedPeer.effectiveUserID,
          helperProcesses.insert(helperProcess).inserted,
          helperInstances.insert(helper.attestedPeer.instanceID).inserted
        else {
          throw VoicePerformanceTracerCollectorError
            .authenticationFailed
        }
        let generation = try HelperGenerationIdentity(
          pid: helper.attestedPeer.pid,
          processStartToken: helper.attestedPeer.processStartToken,
          instanceID: helper.attestedPeer.instanceID
        )
        let driverCollectorNonce = try nextUniqueNonce(&issuedNonces)
        let helperCollectorNonce = try nextUniqueNonce(&issuedNonces)

        try send(
          .challenge(
            peerRole: .driver,
            sessionID: binding.sessionID,
            planNonce: binding.planNonce,
            collectorNonce: driverCollectorNonce
          ),
          channel: .collectorToDriver,
          transcriptChannel: .collectorToDriver,
          trial: trial,
          connection: driver,
          machine: &machine,
          transcript: &transcript,
          globalDeadline: globalDeadline
        )
        try send(
          .challenge(
            peerRole: .helper,
            sessionID: binding.sessionID,
            planNonce: binding.planNonce,
            collectorNonce: helperCollectorNonce
          ),
          channel: .collectorToHelper(generation),
          transcriptChannel: .collectorToHelper,
          trial: trial,
          connection: helper,
          machine: &machine,
          transcript: &transcript,
          globalDeadline: globalDeadline
        )
        _ = try receive(
          channel: .driverToCollector,
          transcriptChannel: .driverToCollector,
          trial: trial,
          connection: driver,
          machine: &machine,
          transcript: &transcript,
          globalDeadline: globalDeadline
        )
        _ = try receive(
          channel: .helperToCollector(generation),
          transcriptChannel: .helperToCollector,
          trial: trial,
          connection: helper,
          machine: &machine,
          transcript: &transcript,
          globalDeadline: globalDeadline,
          phaseLimit: .seconds(10)
        )
        _ = try receive(
          channel: .driverToCollector,
          transcriptChannel: .driverToCollector,
          trial: trial,
          connection: driver,
          machine: &machine,
          transcript: &transcript,
          globalDeadline: globalDeadline
        )

        let loadTicket = try nextUniqueNonce(&issuedNonces)
        try send(
          .loadEngine(
            sequence: 1,
            sessionID: binding.sessionID,
            trial: trial,
            loadTicket: loadTicket
          ),
          channel: .collectorToHelper(generation),
          transcriptChannel: .collectorToHelper,
          trial: trial,
          connection: helper,
          machine: &machine,
          transcript: &transcript,
          globalDeadline: globalDeadline
        )
        let started = try receive(
          channel: .helperToCollector(generation),
          transcriptChannel: .helperToCollector,
          trial: trial,
          connection: helper,
          machine: &machine,
          transcript: &transcript,
          globalDeadline: globalDeadline,
          phaseLimit: .seconds(10)
        )
        guard case .loadStarted(let startedSequence, _, _, _, _) = started
        else {
          throw VoicePerformanceTracerCollectorError.protocolViolation
        }
        let ack = PerformanceControlWireFrame.loadStartedAck(
          sequence: 2,
          sessionID: binding.sessionID,
          replyTo: startedSequence,
          trial: trial,
          loadTicket: loadTicket
        )
        try machine.receive(ack, on: .collectorToHelper(generation))
        let begin = monotonicClock.nowNanoseconds()
        try helper.send(
          ack,
          deadline: try operationDeadline(
            global: globalDeadline,
            phaseLimit: .seconds(5)
          )
        )
        transcript.append(
          try VoicePerformanceTracerTranscriptEntry(
            trial: trial,
            channel: .collectorToHelper,
            frame: ack
          ))

        let ready = try helper.receive(
          deadline: try operationDeadline(
            global: globalDeadline,
            phaseLimit: .seconds(65)
          )
        )
        try machine.receive(ready, on: .helperToCollector(generation))
        let end = monotonicClock.nowNanoseconds()
        guard end > begin else {
          throw VoicePerformanceTracerCollectorError.invalidDuration
        }
        transcript.append(
          try VoicePerformanceTracerTranscriptEntry(
            trial: trial,
            channel: .helperToCollector,
            frame: ready
          ))
        guard case .loadReady(_, _, _, _, _, let engine) = ready,
          request.expectedEngine.matches(engine),
          machine.snapshot.phase == .helperReady,
          machine.snapshot.completedColdTrials == trial
        else {
          throw VoicePerformanceTracerCollectorError.protocolViolation
        }
        let trialResult = try VoicePerformanceTracerColdTrialResult(
          trial: trial,
          sessionID: binding.sessionID,
          planNonce: binding.planNonce,
          loadTicket: loadTicket,
          helperGeneration: generation,
          helperAttestation: helper.attestedPeer,
          artifactGeneration: engine.artifactGeneration,
          coldLoadDurationNanoseconds: end - begin
        )
        exitConfirmationAttempted = true
        try helper.closeAndConfirmPeerExit(
          deadline: try operationDeadline(
            global: globalDeadline,
            phaseLimit: .seconds(15)
          )
        )
        trials.append(trialResult)
      } catch let primaryError {
        if !exitConfirmationAttempted {
          do {
            exitConfirmationAttempted = true
            try helper.closeAndConfirmPeerExit(
              deadline: try operationDeadline(
                global: globalDeadline,
                phaseLimit: .seconds(15)
              )
            )
          } catch let cleanupError {
            throw cleanupError
          }
        }
        throw primaryError
      }
    }

    guard machine.report.qualification == .tracer,
      !machine.report.authenticatedProductionDriver,
      machine.report.completedColdTrials == request.coldTrials
    else {
      throw VoicePerformanceTracerCollectorError.protocolViolation
    }
    return try VoicePerformanceTracerResult(
      controlProtocol: request.driverPolicy.controlProtocol,
      controlSessionNonce: controlSessionNonce,
      measurementPolicySHA256: measurementSHA,
      driverPolicySHA256: request.driverPolicy.canonicalSHA256,
      releasePolicySHA256: releaseSHA,
      expectedEngine: request.expectedEngine,
      driverAttestation: driver.attestedPeer,
      trials: trials,
      transcript: transcript
    )
  }

  private func send(
    _ frame: PerformanceControlWireFrame,
    channel: PerformanceControlChannel,
    transcriptChannel: VoicePerformanceTracerTranscriptChannel,
    trial: UInt64,
    connection: any VoicePerformanceTracerConnection,
    machine: inout PerformanceControlStateMachine,
    transcript: inout [VoicePerformanceTracerTranscriptEntry],
    globalDeadline: ContinuousClock.Instant
  ) throws {
    try machine.receive(frame, on: channel)
    try connection.send(
      frame,
      deadline: try operationDeadline(
        global: globalDeadline,
        phaseLimit: .seconds(5)
      )
    )
    transcript.append(
      try VoicePerformanceTracerTranscriptEntry(
        trial: trial,
        channel: transcriptChannel,
        frame: frame
      ))
  }

  private func receive(
    channel: PerformanceControlChannel,
    transcriptChannel: VoicePerformanceTracerTranscriptChannel,
    trial: UInt64,
    connection: any VoicePerformanceTracerConnection,
    machine: inout PerformanceControlStateMachine,
    transcript: inout [VoicePerformanceTracerTranscriptEntry],
    globalDeadline: ContinuousClock.Instant,
    phaseLimit: Duration = .seconds(5)
  ) throws -> PerformanceControlWireFrame {
    let frame = try connection.receive(
      deadline: try operationDeadline(
        global: globalDeadline,
        phaseLimit: phaseLimit
      )
    )
    try machine.receive(frame, on: channel)
    transcript.append(
      try VoicePerformanceTracerTranscriptEntry(
        trial: trial,
        channel: transcriptChannel,
        frame: frame
      ))
    return frame
  }

  private func nextUniqueNonce(
    _ issued: inout Set<PerformanceControlNonce>
  ) throws -> PerformanceControlNonce {
    let value: PerformanceControlNonce
    do {
      value = try nonceSource.nextNonce()
    } catch let error as VoicePerformanceTracerCollectorError {
      throw error
    } catch is PerformanceControlError {
      throw VoicePerformanceTracerCollectorError.entropyFailure
    } catch {
      throw VoicePerformanceTracerCollectorError.internalFailure
    }
    guard issued.insert(value).inserted else {
      throw VoicePerformanceTracerCollectorError.entropyFailure
    }
    return value
  }

  private func operationDeadline(
    global: ContinuousClock.Instant,
    phaseLimit: Duration
  ) throws -> ContinuousClock.Instant {
    let now = continuousClock.now
    guard now < global else {
      throw VoicePerformanceTracerCollectorError.timedOut
    }
    return min(global, now.advanced(by: phaseLimit))
  }

  private func beginRun() throws {
    lock.lock()
    defer { lock.unlock() }
    switch state {
    case .idle:
      state = .running
    case .running:
      throw VoicePerformanceTracerCollectorError.alreadyRun
    case .completed, .failed:
      throw VoicePerformanceTracerCollectorError.terminal
    }
  }

  private func finishRun(_ finalState: RunState) {
    lock.lock()
    state = finalState
    lock.unlock()
  }

  private static func normalized(_ error: any Error)
    -> VoicePerformanceTracerCollectorError
  {
    if let error = error as? VoicePerformanceTracerCollectorError {
      return error
    }
    if let error = error as? VoicePerformanceTracerTransportError {
      switch error {
      case .timedOut: return .timedOut
      case .disconnected: return .disconnected
      case .authenticationFailed: return .authenticationFailed
      case .failed: return .transportFailure
      }
    }
    if error is PerformanceControlError
      || error is PerformanceControlSessionBindingError
    {
      return .protocolViolation
    }
    return .internalFailure
  }

  private static func driverRequest(
    _ policy: VoicePerformanceMeasurementPolicy
  ) -> VoicePerformanceTracerPeerRequest {
    VoicePerformanceTracerPeerRequest(
      role: .driver,
      trial: nil,
      expectedExecutablePath: policy.driver.expectedExecutablePath,
      expectedExecutableSHA256:
        policy.driver.expectedExecutableSHA256,
      expectedSigningIdentifier:
        policy.driver.expectedSigningIdentifier,
      expectedTeamIdentifier: policy.driver.expectedTeamIdentifier,
      expectedCDHash: policy.driver.expectedCDHash
    )
  }

  private static func helperRequest(
    _ policy: VoicePerformanceMeasurementPolicy,
    trial: UInt64
  ) -> VoicePerformanceTracerPeerRequest {
    VoicePerformanceTracerPeerRequest(
      role: .helper,
      trial: trial,
      expectedExecutablePath: policy.helper.expectedExecutablePath,
      expectedExecutableSHA256:
        policy.helper.expectedExecutableSHA256,
      expectedSigningIdentifier:
        policy.helper.expectedSigningIdentifier,
      expectedTeamIdentifier: policy.helper.expectedTeamIdentifier,
      expectedCDHash: policy.helper.expectedCDHash
    )
  }

  private struct HelperProcessKey: Hashable {
    let pid: Int32
    let startToken: UInt64
  }
}
