import Foundation
import RimeAIVoicePerformanceControlCore
import RimeAIVoicePerformanceControlDarwin
import RimeAIVoicePerformanceTracerProcessDarwin

public enum VoicePerformanceTracerDriverCommandError:
    Error,
    Equatable,
    Sendable
{
    case deadlineExpired
    case invalidVerifiedBundle
    case invalidDriverGeneration
    case invalidChallenge
    case nonceReuse
    case helperGenerationReuse
    case helperFailed
    case transportFailed
}

public enum VoicePerformanceTracerDriverConnectionError:
    Error,
    Equatable,
    Sendable
{
    case peerDisconnected
    case timedOut
    case failed
}

public protocol VoicePerformanceTracerDriverConnection: AnyObject, Sendable {
    func receive(
        deadline: VoicePerformanceContinuousDeadline
    ) throws -> PerformanceControlWireFrame
    func send(
        _ frame: PerformanceControlWireFrame,
        deadline: VoicePerformanceContinuousDeadline
    ) throws
    func close()
}

public protocol VoicePerformanceTracerDriverCommandRuntime:
    AnyObject,
    Sendable
{
    func currentContinuousNanoseconds() throws -> UInt64
    func currentDriverGeneration() throws
        -> VoicePerformanceSupervisedProcessGeneration
    func bindCurrentDriver(
        expected: VoicePerformanceSupervisedProcessGeneration
    ) throws
    func connect(
        socketPath: String,
        expectedCollector: PerformanceControlExpectedPeerIdentity,
        deadline: VoicePerformanceContinuousDeadline
    ) throws -> any VoicePerformanceTracerDriverConnection
    func spawnHelper(
        _ request: VoicePerformanceHelperSpawnRequest,
        joiningProcessGroup processGroupID: Int32
    ) throws -> VoicePerformanceSupervisedProcessGeneration
    func reapSucceededHelper(
        expected: VoicePerformanceSupervisedProcessGeneration,
        deadline: VoicePerformanceContinuousDeadline
    ) throws
    func terminateHelperAndReap(
        expected: VoicePerformanceSupervisedProcessGeneration
    ) throws
    func securePeerNonce() throws -> PerformanceControlNonce
}

public enum VoicePerformanceTracerDriverCommand {
    private static let connectPhaseNanoseconds: UInt64 = 3_000_000_000
    private static let framePhaseNanoseconds: UInt64 = 5_000_000_000
    // The driver client can finish its local collector attestation before the
    // collector has finished server-side driver authentication. The first
    // challenge therefore covers both 15s accepts plus the 5s challenge send.
    private static let challengePhaseNanoseconds: UInt64 = 35_000_000_000
    // One helper lifetime includes authentication, the acknowledged native
    // cold load (up to 60s), ready delivery, collector EOF, and process reap.
    private static let helperLifetimeNanoseconds: UInt64 = 125_000_000_000

    public static func run(
        arguments: VoicePerformanceDriverProcessArguments,
        verifiedBundle: VerifiedPerformanceTracerBundleContext,
        runtime: any VoicePerformanceTracerDriverCommandRuntime
    ) throws {
        try requireUnexpired(arguments.deadline, runtime: runtime)
        let policy = verifiedBundle.measurementPolicy
        guard arguments.tracerBundlePath == verifiedBundle.outerPath,
              verifiedBundle.outerURL.path == verifiedBundle.outerPath,
              let driverPolicy = verifiedBundle.driverPolicy,
              policy.qualification == .tracer,
              !policy.authenticatedProductionDriver,
              !driverPolicy.authenticatedProductionDriver,
              driverPolicy.qualification == .tracer,
              driverPolicy.controlProtocol == policy.controlProtocol,
              driverPolicy.canonicalSHA256.rawValue
                == policy.driver.policySHA256,
              policy.helper.expectedExecutablePath
                == verifiedBundle.outerPath
                    + VoicePerformanceTracerBundleLayout
                        .helperExecutableSuffix
        else {
            throw VoicePerformanceTracerDriverCommandError
                .invalidVerifiedBundle
        }
        let controlSessionNonce: PerformanceControlNonce
        let measurementPolicySHA256: PerformanceControlSHA256
        let expectedCollector: PerformanceControlExpectedPeerIdentity
        let expectedHelper: VoicePerformanceExpectedChildIdentity
        do {
            controlSessionNonce = try PerformanceControlNonce(
                policy.controlSessionNonce
            )
            measurementPolicySHA256 = try PerformanceControlSHA256(
                policy.canonicalSHA256
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
            expectedHelper = try VoicePerformanceExpectedChildIdentity(
                executablePath: policy.helper.expectedExecutablePath,
                executableSHA256:
                    policy.helper.expectedExecutableSHA256,
                signingIdentifier:
                    policy.helper.expectedSigningIdentifier,
                teamIdentifier: policy.helper.expectedTeamIdentifier,
                cdHash: policy.helper.expectedCDHash
            )
        } catch {
            throw VoicePerformanceTracerDriverCommandError
                .invalidVerifiedBundle
        }

        try requireUnexpired(arguments.deadline, runtime: runtime)
        let driver = try runtime.currentDriverGeneration()
        guard driver.pid > 1,
              driver.startToken == verifiedBundle.selfStartToken,
              driver.processGroupID == driver.pid
        else {
            throw VoicePerformanceTracerDriverCommandError
                .invalidDriverGeneration
        }
        try runtime.bindCurrentDriver(expected: driver)

        let connection: any VoicePerformanceTracerDriverConnection
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
        } catch let error as VoicePerformanceTracerDriverCommandError {
            throw error
        } catch VoicePerformanceTracerDriverConnectionError.timedOut {
            throw VoicePerformanceTracerDriverCommandError.deadlineExpired
        } catch {
            throw VoicePerformanceTracerDriverCommandError.transportFailed
        }

        var activeHelper: VoicePerformanceSupervisedProcessGeneration?
        do {
            var usedNonces: Set<PerformanceControlNonce> = [
                controlSessionNonce,
            ]
            var usedHelperGenerations = Set<
                VoicePerformanceSupervisedProcessGeneration
            >()

            for trial in UInt64(1) ... policy.coldTrials {
                try requireUnexpired(arguments.deadline, runtime: runtime)
                let helper = try runtime.spawnHelper(
                    VoicePerformanceHelperSpawnRequest(
                        tracerBundlePath: verifiedBundle.outerPath,
                        trial: trial,
                        policyColdTrials: policy.coldTrials,
                        expectedChildIdentity: expectedHelper,
                        deadline: arguments.deadline
                    ),
                    joiningProcessGroup: driver.processGroupID
                )
                activeHelper = helper
                guard helper.pid > 1,
                      helper.pid != driver.pid,
                      helper.startToken > 0,
                      helper.processGroupID == driver.processGroupID,
                      usedHelperGenerations.insert(helper).inserted
                else {
                    throw VoicePerformanceTracerDriverCommandError
                        .helperGenerationReuse
                }

                let binding = try PerformanceControlSessionBinding.derive(
                    controlSessionNonce: controlSessionNonce,
                    trial: trial
                )
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
                      role == .driver,
                      sessionID == binding.sessionID,
                      planNonce == binding.planNonce
                else {
                    throw VoicePerformanceTracerDriverCommandError
                        .invalidChallenge
                }
                guard usedNonces.insert(sessionID).inserted,
                      usedNonces.insert(planNonce).inserted,
                      usedNonces.insert(nonce).inserted
                else {
                    throw VoicePerformanceTracerDriverCommandError.nonceReuse
                }
                collectorNonce = nonce

                let peerNonce = try runtime.securePeerNonce()
                guard usedNonces.insert(peerNonce).inserted else {
                    throw VoicePerformanceTracerDriverCommandError.nonceReuse
                }
                try connection.send(
                    .driverHello(
                        sessionID: binding.sessionID,
                        planNonce: binding.planNonce,
                        collectorNonce: collectorNonce,
                        peerNonce: peerNonce,
                        collectionProtocol: policy.controlProtocol,
                        driverPolicySHA256:
                            driverPolicy.canonicalSHA256,
                        measurementPolicySHA256:
                            measurementPolicySHA256
                    ),
                    deadline: try phaseDeadline(
                        maximumNanoseconds: framePhaseNanoseconds,
                        global: arguments.deadline,
                        runtime: runtime
                    )
                )
                try connection.send(
                    .armColdLoad(
                        sequence: 1,
                        sessionID: binding.sessionID,
                        trial: trial
                    ),
                    deadline: try phaseDeadline(
                        maximumNanoseconds: framePhaseNanoseconds,
                        global: arguments.deadline,
                        runtime: runtime
                    )
                )
                do {
                    try runtime.reapSucceededHelper(
                        expected: helper,
                        deadline: try phaseDeadline(
                            maximumNanoseconds:
                                helperLifetimeNanoseconds,
                            global: arguments.deadline,
                            runtime: runtime
                        )
                    )
                } catch let error
                    as VoicePerformanceTracerDriverCommandError
                    where error == .deadlineExpired
                {
                    throw error
                } catch VoicePerformanceTracerDriverConnectionError
                    .timedOut
                {
                    throw VoicePerformanceTracerDriverCommandError
                        .deadlineExpired
                } catch {
                    throw VoicePerformanceTracerDriverCommandError
                        .helperFailed
                }
                activeHelper = nil
            }
            connection.close()
        } catch {
            connection.close()
            if let activeHelper {
                do {
                    try runtime.terminateHelperAndReap(
                        expected: activeHelper
                    )
                } catch {
                    throw VoicePerformanceTracerDriverCommandError
                        .helperFailed
                }
            }
            if let commandError =
                error as? VoicePerformanceTracerDriverCommandError
            {
                throw commandError
            }
            if error as? VoicePerformanceTracerDriverConnectionError
                == .timedOut
            {
                throw VoicePerformanceTracerDriverCommandError
                    .deadlineExpired
            }
            throw VoicePerformanceTracerDriverCommandError.transportFailed
        }
    }

    private static func requireUnexpired(
        _ deadline: VoicePerformanceContinuousDeadline,
        runtime: any VoicePerformanceTracerDriverCommandRuntime
    ) throws {
        guard try runtime.currentContinuousNanoseconds()
                < deadline.nanoseconds
        else {
            throw VoicePerformanceTracerDriverCommandError.deadlineExpired
        }
    }

    private static func phaseDeadline(
        maximumNanoseconds: UInt64,
        global: VoicePerformanceContinuousDeadline,
        runtime: any VoicePerformanceTracerDriverCommandRuntime
    ) throws -> VoicePerformanceContinuousDeadline {
        let now = try runtime.currentContinuousNanoseconds()
        guard now < global.nanoseconds else {
            throw VoicePerformanceTracerDriverCommandError.deadlineExpired
        }
        let (phaseEnd, overflow) = now.addingReportingOverflow(
            maximumNanoseconds
        )
        return VoicePerformanceContinuousDeadline(
            nanoseconds: min(
                global.nanoseconds,
                overflow ? UInt64.max : phaseEnd
            )
        )
    }
}
