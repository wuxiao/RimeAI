import Foundation

public struct HelperGenerationIdentity: Hashable, Sendable {
    public let pid: Int32
    public let processStartToken: UInt64
    public let instanceID: ControlledPerformanceID

    public init(
        pid: Int32,
        processStartToken: UInt64,
        instanceID: ControlledPerformanceID
    ) throws {
        guard pid > 0,
              processStartToken > 0,
              (try? PerformanceControlNonce(instanceID.rawValue)) != nil
        else {
            throw PerformanceControlError.invalidHelperGeneration
        }
        self.pid = pid
        self.processStartToken = processStartToken
        self.instanceID = instanceID
    }
}

public enum PerformanceControlChannel: Equatable, Hashable, Sendable {
    case collectorToDriver
    case driverToCollector
    case collectorToHelper(HelperGenerationIdentity)
    case helperToCollector(HelperGenerationIdentity)
}

public enum PerformanceControlPhase:
    String,
    Equatable,
    Hashable,
    Sendable
{
    case failed
    case handshaking
    case waitingUnloadedHelper = "waiting_unloaded_helper"
    case loadArmed = "load_armed"
    case loadStartedAcknowledged = "load_started_acknowledged"
    case loading
    case helperReady = "helper_ready"
}

public struct PerformanceControlColdTrialRecord: Equatable, Sendable {
    public let trial: UInt64
    public let loadTicket: PerformanceControlNonce
    public let helperGeneration: HelperGenerationIdentity
    public let artifactGeneration: PerformanceControlArtifactGeneration
}

public struct PerformanceControlSnapshot: Equatable, Sendable {
    public let phase: PerformanceControlPhase
    public let qualification: PerformanceControlQualification
    public let authenticatedProductionDriver: Bool
    public let sessionID: PerformanceControlNonce?
    public let helperGeneration: HelperGenerationIdentity?
    public let activeTrial: UInt64?
    public let completedColdTrials: UInt64
    public let lastCompletedTrial: PerformanceControlColdTrialRecord?
}

public struct PerformanceControlReport: Equatable, Sendable {
    public let phase: PerformanceControlPhase
    public let qualification: PerformanceControlQualification
    public let authenticatedProductionDriver: Bool
    public let completedColdTrials: UInt64
    public let lastCompletedTrial: PerformanceControlColdTrialRecord?
}

public struct PerformanceControlStateMachine: Sendable {
    private enum Direction: Hashable {
        case collectorToDriver
        case driverToCollector
        case collectorToHelper
        case helperToCollector
    }

    private struct ChallengeBinding: Sendable {
        let collectorNonce: PerformanceControlNonce
    }

    private struct HelperProcessGeneration: Hashable, Sendable {
        let pid: Int32
        let processStartToken: UInt64
    }

    private let driverPolicy: SealedPerformanceControlDriverPolicy
    private let controlSessionNonce: PerformanceControlNonce
    private let measurementPolicySHA256: PerformanceControlSHA256
    private let releasePolicySHA256: PerformanceControlSHA256
    private let expectedEngine: ExpectedPerformanceControlEngine
    private let coldTrials: UInt64

    private var phase: PerformanceControlPhase = .handshaking
    private var sessionID: PerformanceControlNonce?
    private var planNonce: PerformanceControlNonce?
    private var driverChallenge: ChallengeBinding?
    private var helperChallenge: ChallengeBinding?
    private var driverHelloReceived = false
    private var helperHelloReceived = false
    private var helperGeneration: HelperGenerationIdentity?
    private var sequences: [Direction: UInt64] = [:]
    private var activeTrial: UInt64?
    private var loadTicket: PerformanceControlNonce?
    private var loadEngineSequence: UInt64?
    private var loadStartedSequence: UInt64?
    private var loadStartedAckSequence: UInt64?
    private var completedColdTrials: UInt64 = 0

    private var usedTokens = Set<PerformanceControlNonce>()
    private var usedTrials = Set<UInt64>()
    private var usedTickets = Set<PerformanceControlNonce>()
    private var usedGenerations = Set<HelperGenerationIdentity>()
    private var usedHelperProcesses = Set<HelperProcessGeneration>()
    private var usedHelperInstanceIDs = Set<ControlledPerformanceID>()
    private var usedArtifactGenerations = Set<PerformanceControlArtifactGeneration>()
    private var completedTrialRecords: [PerformanceControlColdTrialRecord] = []

    public init(
        driverPolicy: SealedPerformanceControlDriverPolicy,
        measurementPolicy: VoicePerformanceMeasurementPolicy
    ) throws {
        guard driverPolicy.qualification == .tracer,
              driverPolicy.capabilities
                == SealedPerformanceControlDriverPolicy.tracerCapabilities,
              !driverPolicy.authenticatedProductionDriver
        else {
            throw PerformanceControlError.unsupportedQualification
        }
        guard measurementPolicy.qualification == .tracer,
              !measurementPolicy.authenticatedProductionDriver,
              measurementPolicy.controlProtocol == driverPolicy.controlProtocol,
              measurementPolicy.driver.policySHA256
                == driverPolicy.canonicalSHA256.rawValue,
              let controlSessionNonce = try? PerformanceControlNonce(
                  measurementPolicy.controlSessionNonce
              ),
              let measurementPolicySHA256 = try? PerformanceControlSHA256(
                  measurementPolicy.canonicalSHA256
              ),
              let releasePolicySHA256 = try? PerformanceControlSHA256(
                  measurementPolicy.releasePolicySHA256
              )
        else {
            throw PerformanceControlError.bindingMismatch
        }
        self.driverPolicy = driverPolicy
        self.controlSessionNonce = controlSessionNonce
        self.measurementPolicySHA256 = measurementPolicySHA256
        self.releasePolicySHA256 = releasePolicySHA256
        expectedEngine = measurementPolicy.expectedEngine
        coldTrials = measurementPolicy.coldTrials
    }

    public var snapshot: PerformanceControlSnapshot {
        PerformanceControlSnapshot(
            phase: phase,
            qualification: .tracer,
            authenticatedProductionDriver: false,
            sessionID: sessionID,
            helperGeneration: helperGeneration,
            activeTrial: activeTrial,
            completedColdTrials: completedColdTrials,
            lastCompletedTrial: completedTrialRecords.last
        )
    }

    public var report: PerformanceControlReport {
        PerformanceControlReport(
            phase: phase,
            qualification: .tracer,
            authenticatedProductionDriver: false,
            completedColdTrials: completedColdTrials,
            lastCompletedTrial: completedTrialRecords.last
        )
    }

    /// Every thrown error is protocol-fatal. The machine enters `.failed`, and
    /// the transport must close the authenticated connection immediately.
    @discardableResult
    public mutating func receive(
        _ frame: PerformanceControlWireFrame,
        on channel: PerformanceControlChannel
    ) throws -> PerformanceControlSnapshot {
        guard phase != .failed else {
            throw PerformanceControlError.invalidTransition
        }
        do {
            try apply(frame, on: channel)
        } catch {
            phase = .failed
            throw error
        }
        return snapshot
    }

    private mutating func apply(
        _ frame: PerformanceControlWireFrame,
        on channel: PerformanceControlChannel
    ) throws {
        switch frame {
        case let .challenge(role, sessionID, planNonce, collectorNonce):
            try receiveChallenge(
                role: role,
                sessionID: sessionID,
                planNonce: planNonce,
                collectorNonce: collectorNonce,
                channel: channel
            )
        case let .driverHello(
            sessionID,
            planNonce,
            collectorNonce,
            peerNonce,
            collectionProtocol,
            driverPolicySHA256,
            measurementPolicySHA256
        ):
            guard channel == .driverToCollector,
                  let challenge = driverChallenge,
                  !driverHelloReceived
            else {
                throw PerformanceControlError.unauthorizedDirection
            }
            try requireHandshakeSequence(.driverToCollector)
            guard sessionID == self.sessionID,
                  planNonce == self.planNonce,
                  collectorNonce == challenge.collectorNonce,
                  collectionProtocol == driverPolicy.controlProtocol,
                  driverPolicySHA256 == driverPolicy.canonicalSHA256,
                  measurementPolicySHA256 == self.measurementPolicySHA256
            else {
                throw PerformanceControlError.bindingMismatch
            }
            try reserve(peerNonce)
            driverHelloReceived = true
            enterWaitingWhenAuthenticated()
        case let .helperHello(
            sessionID,
            planNonce,
            collectorNonce,
            peerNonce,
            measurementPolicySHA256,
            releasePolicySHA256
        ):
            guard case let .helperToCollector(generation) = channel,
                  generation == helperGeneration,
                  let challenge = helperChallenge,
                  !helperHelloReceived
            else {
                throw PerformanceControlError.unauthorizedDirection
            }
            try requireHandshakeSequence(.helperToCollector)
            guard sessionID == self.sessionID,
                  planNonce == self.planNonce,
                  collectorNonce == challenge.collectorNonce,
                  measurementPolicySHA256 == self.measurementPolicySHA256,
                  releasePolicySHA256 == self.releasePolicySHA256
            else {
                throw PerformanceControlError.bindingMismatch
            }
            try reserve(peerNonce)
            helperHelloReceived = true
            enterWaitingWhenAuthenticated()
        case let .armColdLoad(sequence, sessionID, trial):
            guard channel == .driverToCollector else {
                throw PerformanceControlError.unauthorizedDirection
            }
            try requireDataSequence(sequence, .driverToCollector)
            try requireSession(sessionID)
            guard !usedTrials.contains(trial) else {
                throw PerformanceControlError.trialReplay
            }
            guard completedColdTrials
                    < coldTrials,
                  trial == completedColdTrials + 1,
                  trial <= coldTrials,
                  PerformanceControlSessionBinding.supportedTrials
                    .contains(trial),
                  phase == .waitingUnloadedHelper,
                  activeTrial == nil,
                  trial > 0
            else {
                throw PerformanceControlError.invalidTransition
            }
            usedTrials.insert(trial)
            activeTrial = trial
            phase = .loadArmed
        case let .loadEngine(sequence, sessionID, trial, ticket):
            guard case let .collectorToHelper(generation) = channel,
                  generation == helperGeneration
            else {
                throw PerformanceControlError.unauthorizedDirection
            }
            try requireDataSequence(sequence, .collectorToHelper)
            try requireTrialBinding(sessionID: sessionID, trial: trial)
            guard phase == .loadArmed, loadTicket == nil else {
                throw PerformanceControlError.invalidTransition
            }
            guard usedTickets.insert(ticket).inserted else {
                throw PerformanceControlError.ticketReplay
            }
            try reserve(ticket)
            loadTicket = ticket
            loadEngineSequence = sequence
        case let .loadStarted(
            sequence,
            sessionID,
            replyTo,
            trial,
            ticket
        ):
            guard case let .helperToCollector(generation) = channel,
                  generation == helperGeneration
            else {
                throw PerformanceControlError.unauthorizedDirection
            }
            try requireDataSequence(sequence, .helperToCollector)
            try requireLoadBinding(
                sessionID: sessionID,
                trial: trial,
                ticket: ticket
            )
            guard phase == .loadArmed,
                  replyTo == loadEngineSequence
            else {
                throw PerformanceControlError.invalidTransition
            }
            loadStartedSequence = sequence
            phase = .loadStartedAcknowledged
        case let .loadStartedAck(
            sequence,
            sessionID,
            replyTo,
            trial,
            ticket
        ):
            guard case let .collectorToHelper(generation) = channel,
                  generation == helperGeneration
            else {
                throw PerformanceControlError.unauthorizedDirection
            }
            try requireDataSequence(sequence, .collectorToHelper)
            try requireLoadBinding(
                sessionID: sessionID,
                trial: trial,
                ticket: ticket
            )
            guard phase == .loadStartedAcknowledged,
                  replyTo == loadStartedSequence
            else {
                throw PerformanceControlError.invalidTransition
            }
            loadStartedAckSequence = sequence
            phase = .loading
        case let .loadReady(
            sequence,
            sessionID,
            replyTo,
            trial,
            ticket,
            engine
        ):
            guard case let .helperToCollector(generation) = channel,
                  generation == helperGeneration
            else {
                throw PerformanceControlError.unauthorizedDirection
            }
            try requireDataSequence(sequence, .helperToCollector)
            try requireLoadBinding(
                sessionID: sessionID,
                trial: trial,
                ticket: ticket
            )
            guard phase == .loading,
                  replyTo == loadStartedAckSequence,
                  expectedEngine.matches(engine)
            else {
                throw PerformanceControlError.bindingMismatch
            }
            guard usedArtifactGenerations
                .insert(engine.artifactGeneration).inserted
            else {
                throw PerformanceControlError.artifactGenerationReuse
            }
            guard let generation = helperGeneration,
                  let activeTrial,
                  let loadTicket
            else {
                throw PerformanceControlError.invalidTransition
            }
            guard completedColdTrials < UInt64.max else {
                throw PerformanceControlError.invalidTransition
            }
            completedColdTrials += 1
            completedTrialRecords.append(
                PerformanceControlColdTrialRecord(
                    trial: activeTrial,
                    loadTicket: loadTicket,
                    helperGeneration: generation,
                    artifactGeneration: engine.artifactGeneration
                )
            )
            phase = .helperReady
        }
    }

    private mutating func receiveChallenge(
        role: PerformanceControlPeerRole,
        sessionID: PerformanceControlNonce,
        planNonce: PerformanceControlNonce,
        collectorNonce: PerformanceControlNonce,
        channel: PerformanceControlChannel
    ) throws {
        let direction: Direction
        let challengedGeneration: HelperGenerationIdentity?
        switch role {
        case .driver:
            guard channel == .collectorToDriver else {
                throw PerformanceControlError.unauthorizedDirection
            }
            direction = .collectorToDriver
            challengedGeneration = nil
        case .helper:
            guard case let .collectorToHelper(generation) = channel else {
                throw PerformanceControlError.unauthorizedDirection
            }
            direction = .collectorToHelper
            challengedGeneration = generation
        }

        if self.sessionID == nil {
            try beginSession(sessionID: sessionID, planNonce: planNonce)
        } else if phase == .helperReady {
            try beginSession(sessionID: sessionID, planNonce: planNonce)
        } else {
            guard phase == .handshaking,
                  sessionID == self.sessionID,
                  planNonce == self.planNonce
            else {
                throw PerformanceControlError.bindingMismatch
            }
        }
        switch role {
        case .driver:
            guard driverChallenge == nil else {
                throw PerformanceControlError.invalidTransition
            }
        case .helper:
            guard helperChallenge == nil,
                  let challengedGeneration
            else {
                throw PerformanceControlError.invalidTransition
            }
            let process = HelperProcessGeneration(
                pid: challengedGeneration.pid,
                processStartToken: challengedGeneration.processStartToken
            )
            guard !usedGenerations.contains(challengedGeneration),
                  !usedHelperProcesses.contains(process),
                  !usedHelperInstanceIDs.contains(
                      challengedGeneration.instanceID
                  )
            else {
                throw PerformanceControlError.generationReuse
            }
            usedGenerations.insert(challengedGeneration)
            usedHelperProcesses.insert(process)
            usedHelperInstanceIDs.insert(challengedGeneration.instanceID)
            helperGeneration = challengedGeneration
        }
        guard sequences[direction] == nil else {
            throw PerformanceControlError.sequenceViolation
        }
        try reserve(collectorNonce)
        sequences[direction] = 0
        let binding = ChallengeBinding(collectorNonce: collectorNonce)
        switch role {
        case .driver: driverChallenge = binding
        case .helper: helperChallenge = binding
        }
    }

    private mutating func beginSession(
        sessionID: PerformanceControlNonce,
        planNonce: PerformanceControlNonce
    ) throws {
        guard self.sessionID == nil || phase == .helperReady else {
            throw PerformanceControlError.invalidTransition
        }
        guard completedColdTrials
                < coldTrials,
              let expectedBinding = try? PerformanceControlSessionBinding
                .derive(
                    controlSessionNonce: controlSessionNonce,
                    trial: completedColdTrials + 1
                ),
              sessionID == expectedBinding.sessionID,
              planNonce == expectedBinding.planNonce
        else {
            throw PerformanceControlError.bindingMismatch
        }
        try reserve(sessionID)
        try reserve(planNonce)
        self.sessionID = sessionID
        self.planNonce = planNonce
        phase = .handshaking
        driverChallenge = nil
        helperChallenge = nil
        driverHelloReceived = false
        helperHelloReceived = false
        helperGeneration = nil
        sequences = [:]
        activeTrial = nil
        loadTicket = nil
        loadEngineSequence = nil
        loadStartedSequence = nil
        loadStartedAckSequence = nil
    }

    private mutating func reserve(
        _ token: PerformanceControlNonce
    ) throws {
        guard usedTokens.insert(token).inserted else {
            throw PerformanceControlError.bindingMismatch
        }
    }

    private mutating func requireHandshakeSequence(
        _ direction: Direction
    ) throws {
        guard sequences[direction] == nil else {
            throw PerformanceControlError.sequenceViolation
        }
        sequences[direction] = 0
    }

    private mutating func requireDataSequence(
        _ sequence: UInt64,
        _ direction: Direction
    ) throws {
        guard let previous = sequences[direction],
              previous < UInt64.max,
              sequence == previous + 1
        else {
            throw PerformanceControlError.sequenceViolation
        }
        sequences[direction] = sequence
    }

    private func requireSession(
        _ sessionID: PerformanceControlNonce
    ) throws {
        guard sessionID == self.sessionID else {
            throw PerformanceControlError.bindingMismatch
        }
    }

    private func requireTrialBinding(
        sessionID: PerformanceControlNonce,
        trial: UInt64
    ) throws {
        try requireSession(sessionID)
        guard trial == activeTrial else {
            throw PerformanceControlError.bindingMismatch
        }
    }

    private func requireLoadBinding(
        sessionID: PerformanceControlNonce,
        trial: UInt64,
        ticket: PerformanceControlNonce
    ) throws {
        try requireTrialBinding(sessionID: sessionID, trial: trial)
        guard ticket == loadTicket else {
            throw PerformanceControlError.bindingMismatch
        }
    }

    private mutating func enterWaitingWhenAuthenticated() {
        if driverHelloReceived && helperHelloReceived {
            phase = .waitingUnloadedHelper
        }
    }
}
