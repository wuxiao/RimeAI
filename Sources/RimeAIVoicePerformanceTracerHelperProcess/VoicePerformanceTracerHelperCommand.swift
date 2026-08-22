import Foundation
import RimeAIVoicePerformanceControlCore
import RimeAIVoicePerformanceControlDarwin
import RimeAIVoicePerformanceTracerProcessDarwin

public enum VoicePerformanceTracerHelperCommandError:
    Error,
    Equatable,
    Sendable
{
    case deadlineExpired
    case invalidVerifiedBundle
    case invalidHelperGeneration
    case invalidChallenge
    case invalidFrame
    case peerDisconnectedEarly
    case unexpectedFrameAfterReady
    case transportFailed
}

public enum VoicePerformanceTracerHelperConnectionError:
    Error,
    Equatable,
    Sendable
{
    case peerDisconnected
    case timedOut
    case failed
}

public protocol VoicePerformanceTracerHelperConnection:
    AnyObject,
    Sendable
{
    func receive(
        deadline: VoicePerformanceContinuousDeadline
    ) throws -> PerformanceControlWireFrame
    func send(
        _ frame: PerformanceControlWireFrame,
        deadline: VoicePerformanceContinuousDeadline
    ) throws
    func close()
}

public protocol VoicePerformanceTracerHelperFacade: AnyObject, Sendable {
    var authenticatedProductionDriver: Bool { get }

    func receive(
        _ frame: PerformanceControlWireFrame,
        deadline: VoicePerformanceContinuousDeadline
    ) throws -> PerformanceControlWireFrame
    func cancel()
    func disconnect()
    func timeout()
}

public protocol VoicePerformanceTracerHelperCommandRuntime:
    AnyObject,
    Sendable
{
    func currentContinuousNanoseconds() throws -> UInt64
    func currentHelperGeneration() throws
        -> VoicePerformanceSupervisedProcessGeneration
    func makeFacade(
        measurementPolicy: VoicePerformanceMeasurementPolicy
    ) throws -> any VoicePerformanceTracerHelperFacade
    func connect(
        socketPath: String,
        expectedCollector: PerformanceControlExpectedPeerIdentity,
        deadline: VoicePerformanceContinuousDeadline
    ) throws -> any VoicePerformanceTracerHelperConnection
}

public enum VoicePerformanceTracerHelperCommand {
    private static let connectPhaseNanoseconds: UInt64 = 3_000_000_000
    private static let framePhaseNanoseconds: UInt64 = 5_000_000_000
    // Client-side collector attestation does not prove the collector has
    // finished either server-side accept. These receive budgets cover the
    // collector's exact upstream sequence before each frame can be sent.
    private static let challengePhaseNanoseconds: UInt64 = 40_000_000_000
    private static let loadEnginePhaseNanoseconds: UInt64 = 20_000_000_000
    private static let acknowledgementPhaseNanoseconds: UInt64 =
        10_000_000_000
    private static let engineLoadPhaseNanoseconds: UInt64 = 60_000_000_000

    public static func run(
        arguments: VoicePerformanceHelperProcessArguments,
        verifiedBundle: VerifiedPerformanceTracerBundleContext,
        runtime: any VoicePerformanceTracerHelperCommandRuntime
    ) throws {
        try requireUnexpired(arguments.deadline, runtime: runtime)
        let policy = verifiedBundle.measurementPolicy
        guard arguments.tracerBundlePath == verifiedBundle.outerPath,
              verifiedBundle.outerURL.path == verifiedBundle.outerPath,
              verifiedBundle.driverPolicy == nil,
              policy.qualification == .tracer,
              !policy.authenticatedProductionDriver,
              policy.coldTrials >= arguments.trial,
              arguments.trial > 0,
              policy.helper.expectedExecutablePath
                == verifiedBundle.outerPath
                    + VoicePerformanceTracerBundleLayout
                        .helperExecutableSuffix
        else {
            throw VoicePerformanceTracerHelperCommandError
                .invalidVerifiedBundle
        }
        let controlSessionNonce: PerformanceControlNonce
        let binding: PerformanceControlSessionBinding
        let expectedCollector: PerformanceControlExpectedPeerIdentity
        let measurementPolicySHA256: PerformanceControlSHA256
        let releasePolicySHA256: PerformanceControlSHA256
        do {
            controlSessionNonce = try PerformanceControlNonce(
                policy.controlSessionNonce
            )
            binding = try PerformanceControlSessionBinding.derive(
                controlSessionNonce: controlSessionNonce,
                trial: arguments.trial
            )
            expectedCollector = try PerformanceControlExpectedPeerIdentity(
                expectedExecutablePath:
                    policy.collector.expectedExecutablePath,
                expectedExecutableSHA256:
                    policy.collector.expectedExecutableSHA256,
                expectedSigningIdentifier:
                    policy.collector.expectedSigningIdentifier,
                expectedTeamIdentifier:
                    policy.collector.expectedTeamIdentifier,
                expectedCDHash:
                    policy.collector.expectedCDHash
            )
            measurementPolicySHA256 = try PerformanceControlSHA256(
                policy.canonicalSHA256
            )
            releasePolicySHA256 = try PerformanceControlSHA256(
                policy.releasePolicySHA256
            )
        } catch {
            throw VoicePerformanceTracerHelperCommandError
                .invalidVerifiedBundle
        }

        try requireUnexpired(arguments.deadline, runtime: runtime)
        let generation = try runtime.currentHelperGeneration()
        guard generation.pid > 1,
              generation.startToken == verifiedBundle.selfStartToken,
              generation.processGroupID > 1,
              generation.processGroupID != generation.pid
        else {
            throw VoicePerformanceTracerHelperCommandError
                .invalidHelperGeneration
        }

        try requireUnexpired(arguments.deadline, runtime: runtime)
        let facade: any VoicePerformanceTracerHelperFacade
        do {
            facade = try runtime.makeFacade(measurementPolicy: policy)
        } catch {
            throw VoicePerformanceTracerHelperCommandError.invalidFrame
        }
        guard !facade.authenticatedProductionDriver else {
            facade.cancel()
            throw VoicePerformanceTracerHelperCommandError
                .invalidVerifiedBundle
        }

        var connection: (any VoicePerformanceTracerHelperConnection)?
        do {
            connection = try runtime.connect(
                socketPath: policy.controlSocketPath,
                expectedCollector: expectedCollector,
                deadline: try phaseDeadline(
                    maximumNanoseconds: connectPhaseNanoseconds,
                    global: arguments.deadline,
                    runtime: runtime
                )
            )
            guard let connection else {
                throw VoicePerformanceTracerHelperCommandError
                    .transportFailed
            }

            var reservedNonces: Set<PerformanceControlNonce> = [
                controlSessionNonce,
                binding.sessionID,
                binding.planNonce,
            ]
            let challenge = try connection.receive(
                deadline: try phaseDeadline(
                    maximumNanoseconds: challengePhaseNanoseconds,
                    global: arguments.deadline,
                    runtime: runtime
                )
            )
            let collectorNonce: PerformanceControlNonce
            guard case let .challenge(
                role,
                sessionID,
                planNonce,
                nonce
            ) = challenge,
                  role == .helper,
                  sessionID == binding.sessionID,
                  planNonce == binding.planNonce
            else {
                throw VoicePerformanceTracerHelperCommandError
                    .invalidChallenge
            }
            guard reservedNonces.insert(nonce).inserted else {
                throw VoicePerformanceTracerHelperCommandError.invalidChallenge
            }
            collectorNonce = nonce

            let helperHello = try facade.receive(
                challenge,
                deadline: try phaseDeadline(
                    maximumNanoseconds: framePhaseNanoseconds,
                    global: arguments.deadline,
                    runtime: runtime
                )
            )
            guard case let .helperHello(
                helloSession,
                helloPlan,
                helloCollectorNonce,
                peerNonce,
                helloMeasurementSHA,
                helloReleaseSHA
            ) = helperHello,
                  helloSession == binding.sessionID,
                  helloPlan == binding.planNonce,
                  helloCollectorNonce == collectorNonce,
                  helloMeasurementSHA == measurementPolicySHA256,
                  helloReleaseSHA == releasePolicySHA256,
                  reservedNonces.insert(peerNonce).inserted
            else {
                throw VoicePerformanceTracerHelperCommandError.invalidFrame
            }
            try connection.send(
                helperHello,
                deadline: try phaseDeadline(
                    maximumNanoseconds: framePhaseNanoseconds,
                    global: arguments.deadline,
                    runtime: runtime
                )
            )

            let loadEngine = try connection.receive(
                deadline: try phaseDeadline(
                    maximumNanoseconds: loadEnginePhaseNanoseconds,
                    global: arguments.deadline,
                    runtime: runtime
                )
            )
            let loadTicket: PerformanceControlNonce
            guard case let .loadEngine(
                loadSequence,
                loadSession,
                loadTrial,
                ticket
            ) = loadEngine,
                  loadSequence == 1,
                  loadSession == binding.sessionID,
                  loadTrial == arguments.trial,
                  reservedNonces.insert(ticket).inserted
            else {
                throw VoicePerformanceTracerHelperCommandError.invalidFrame
            }
            loadTicket = ticket
            let loadStarted = try facade.receive(
                loadEngine,
                deadline: try phaseDeadline(
                    maximumNanoseconds: framePhaseNanoseconds,
                    global: arguments.deadline,
                    runtime: runtime
                )
            )
            guard case let .loadStarted(
                startedSequence,
                startedSession,
                startedReplyTo,
                startedTrial,
                startedTicket
            ) = loadStarted,
                  startedSequence == 1,
                  startedSession == binding.sessionID,
                  startedReplyTo == 1,
                  startedTrial == arguments.trial,
                  startedTicket == loadTicket
            else {
                throw VoicePerformanceTracerHelperCommandError.invalidFrame
            }
            try connection.send(
                loadStarted,
                deadline: try phaseDeadline(
                    maximumNanoseconds: framePhaseNanoseconds,
                    global: arguments.deadline,
                    runtime: runtime
                )
            )

            let acknowledgement = try connection.receive(
                deadline: try phaseDeadline(
                    maximumNanoseconds:
                        acknowledgementPhaseNanoseconds,
                    global: arguments.deadline,
                    runtime: runtime
                )
            )
            guard case let .loadStartedAck(
                acknowledgementSequence,
                acknowledgementSession,
                acknowledgementReplyTo,
                acknowledgementTrial,
                acknowledgementTicket
            ) = acknowledgement,
                  acknowledgementSequence == 2,
                  acknowledgementSession == binding.sessionID,
                  acknowledgementReplyTo == 1,
                  acknowledgementTrial == arguments.trial,
                  acknowledgementTicket == loadTicket
            else {
                throw VoicePerformanceTracerHelperCommandError.invalidFrame
            }
            let loadReady = try facade.receive(
                acknowledgement,
                deadline: try phaseDeadline(
                    maximumNanoseconds: engineLoadPhaseNanoseconds,
                    global: arguments.deadline,
                    runtime: runtime
                )
            )
            guard case let .loadReady(
                readySequence,
                readySession,
                readyReplyTo,
                readyTrial,
                readyTicket,
                engine
            ) = loadReady,
                  readySequence == 2,
                  readySession == binding.sessionID,
                  readyReplyTo == 2,
                  readyTrial == arguments.trial,
                  readyTicket == loadTicket,
                  policy.expectedEngine.matches(engine)
            else {
                throw VoicePerformanceTracerHelperCommandError.invalidFrame
            }
            try connection.send(
                loadReady,
                deadline: try phaseDeadline(
                    maximumNanoseconds: framePhaseNanoseconds,
                    global: arguments.deadline,
                    runtime: runtime
                )
            )

            do {
                _ = try connection.receive(
                    deadline: try phaseDeadline(
                        maximumNanoseconds: framePhaseNanoseconds,
                        global: arguments.deadline,
                        runtime: runtime
                    )
                )
                throw VoicePerformanceTracerHelperCommandError
                    .unexpectedFrameAfterReady
            } catch VoicePerformanceTracerHelperConnectionError
                .peerDisconnected
            {
                facade.disconnect()
                connection.close()
                return
            }
        } catch {
            connection?.close()
            if isTimeout(error) {
                facade.timeout()
            } else {
                facade.cancel()
            }
            throw normalize(error)
        }
    }

    private static func requireUnexpired(
        _ deadline: VoicePerformanceContinuousDeadline,
        runtime: any VoicePerformanceTracerHelperCommandRuntime
    ) throws {
        guard try runtime.currentContinuousNanoseconds()
                < deadline.nanoseconds
        else {
            throw VoicePerformanceTracerHelperCommandError.deadlineExpired
        }
    }

    private static func phaseDeadline(
        maximumNanoseconds: UInt64,
        global: VoicePerformanceContinuousDeadline,
        runtime: any VoicePerformanceTracerHelperCommandRuntime
    ) throws -> VoicePerformanceContinuousDeadline {
        let now = try runtime.currentContinuousNanoseconds()
        guard now < global.nanoseconds else {
            throw VoicePerformanceTracerHelperCommandError.deadlineExpired
        }
        let (phaseEnd, overflow) = now.addingReportingOverflow(
            maximumNanoseconds
        )
        return .init(
            nanoseconds: min(
                global.nanoseconds,
                overflow ? UInt64.max : phaseEnd
            )
        )
    }

    private static func isTimeout(_ error: Error) -> Bool {
        if error as? VoicePerformanceTracerHelperConnectionError
            == .timedOut
        {
            return true
        }
        return error as? VoicePerformanceTracerHelperCommandError
            == .deadlineExpired
    }

    private static func normalize(
        _ error: Error
    ) -> VoicePerformanceTracerHelperCommandError {
        if let command =
            error as? VoicePerformanceTracerHelperCommandError
        {
            return command
        }
        if let connection =
            error as? VoicePerformanceTracerHelperConnectionError
        {
            switch connection {
            case .peerDisconnected:
                return .peerDisconnectedEarly
            case .timedOut:
                return .deadlineExpired
            case .failed:
                return .transportFailed
            }
        }
        return .invalidFrame
    }
}
