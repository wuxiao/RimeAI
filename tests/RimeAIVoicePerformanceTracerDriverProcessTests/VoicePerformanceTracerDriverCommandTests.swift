import Foundation
import RimeAIVoicePerformanceControlCore
import RimeAIVoicePerformanceControlDarwin
import Testing
@testable import RimeAIVoicePerformanceTracerProcessDarwin
@testable import RimeAIVoicePerformanceTracerDriverProcess

@Suite("Voice performance tracer driver command")
struct VoicePerformanceTracerDriverCommandTests {
    @Test("transport conversion samples base before mach remaining time")
    func transportDeadlineNeverAddsConversionLatency() throws {
        let base = ContinuousClock().now
        var events: [String] = []
        let converter = VoicePerformanceDriverTransportDeadlineConverter(
            baseInstant: {
                events.append("base")
                return base
            },
            remainingNanoseconds: { _ in
                events.append("remaining")
                return 42
            }
        )

        let converted = try converter.instant(
            for: .init(nanoseconds: 1_000)
        )

        #expect(events == ["base", "remaining"])
        #expect(converted == base.advanced(by: .nanoseconds(42)))
    }

    @Test("an expired global deadline performs no spawn or transport I/O")
    func expiredDeadlineHasNoSideEffects() throws {
        let fixture = try DriverCommandFixture(coldTrials: 1)
        let runtime = RecordingDriverRuntime(now: 100)

        #expect(
            throws: VoicePerformanceTracerDriverCommandError.deadlineExpired
        ) {
            try VoicePerformanceTracerDriverCommand.run(
                arguments: VoicePerformanceDriverProcessArguments(
                    tracerBundlePath: fixture.bundlePath,
                    deadline: VoicePerformanceContinuousDeadline(
                        nanoseconds: 100
                    )
                ),
                verifiedBundle: fixture.context,
                runtime: runtime
            )
        }
        #expect(runtime.sideEffects.isEmpty)
    }

    @Test("one cold trial spawns before challenge and sends the exact handshake")
    func oneTrialUsesExactOrderingAndBinding() throws {
        let fixture = try DriverCommandFixture(coldTrials: 1)
        let binding = try fixture.binding(trial: 1)
        let collectorNonce = try driverNonce("8")
        let peerNonce = try driverNonce("9")
        let connection = RecordingDriverConnection(frames: [
            .challenge(
                peerRole: .driver,
                sessionID: binding.sessionID,
                planNonce: binding.planNonce,
                collectorNonce: collectorNonce
            ),
        ])
        let helper = VoicePerformanceSupervisedProcessGeneration(
            pid: 51,
            startToken: 10_001,
            processGroupID: 41
        )
        let runtime = RecordingDriverRuntime(
            now: 1_000,
            connection: connection,
            helperGenerations: [helper],
            peerNonces: [peerNonce]
        )
        connection.recorder = runtime.recorder
        let deadline = VoicePerformanceContinuousDeadline(
            nanoseconds: 200_000_000_000
        )

        try VoicePerformanceTracerDriverCommand.run(
            arguments: VoicePerformanceDriverProcessArguments(
                tracerBundlePath: fixture.bundlePath,
                deadline: deadline
            ),
            verifiedBundle: fixture.context,
            runtime: runtime
        )

        #expect(runtime.sideEffects == [
            "current-generation",
            "bind-driver",
            "connect",
            "spawn",
            "receive",
            "random",
            "send",
            "send",
            "reap",
            "close",
        ])
        #expect(runtime.connectedSocketPath
            == fixture.measurementPolicy.controlSocketPath)
        let expectedCollector = try fixture.expectedCollector()
        #expect(runtime.connectedCollector == expectedCollector)
        #expect(runtime.connectDeadline?.nanoseconds == 3_000_001_000)
        let expectedSpawn = try VoicePerformanceHelperSpawnRequest(
            tracerBundlePath: fixture.bundlePath,
            trial: 1,
            policyColdTrials: fixture.measurementPolicy.coldTrials,
            expectedChildIdentity: try fixture.expectedHelperIdentity(),
            deadline: deadline
        )
        #expect(runtime.spawnedRequests == [expectedSpawn])
        #expect(runtime.joinedProcessGroups == [41])
        #expect(connection.sentFrames == [
            .driverHello(
                sessionID: binding.sessionID,
                planNonce: binding.planNonce,
                collectorNonce: collectorNonce,
                peerNonce: peerNonce,
                collectionProtocol:
                    fixture.measurementPolicy.controlProtocol,
                driverPolicySHA256:
                    fixture.driverPolicy.canonicalSHA256,
                measurementPolicySHA256:
                    try PerformanceControlSHA256(
                        fixture.measurementPolicy.canonicalSHA256
                    )
            ),
            .armColdLoad(
                sequence: 1,
                sessionID: binding.sessionID,
                trial: 1
            ),
        ])
        #expect(connection.sentDeadlines.map(\.nanoseconds)
            == [5_000_001_000, 5_000_001_000])
        #expect(connection.receiveDeadlines.map(\.nanoseconds)
            == [35_000_001_000])
        #expect(runtime.reapedHelpers == [helper])
        #expect(runtime.reapDeadlines.map(\.nanoseconds)
            == [125_000_001_000])
        #expect(connection.closeCount == 1)
    }

    @Test("helper identity path mismatch is rejected before spawn or I/O")
    func helperIdentityMismatchHasNoSideEffects() throws {
        let fixture = try DriverCommandFixture(
            coldTrials: 1,
            helperExecutablePath:
                "/Applications/OtherTracer.bundle/Contents/Helpers/"
                + "RimeAIVoicePerformanceHelper.app/Contents/MacOS/"
                + "rimeai-voice-performance-helper"
        )
        let runtime = RecordingDriverRuntime(now: 1_000)

        #expect(
            throws:
                VoicePerformanceTracerDriverCommandError
                    .invalidVerifiedBundle
        ) {
            try VoicePerformanceTracerDriverCommand.run(
                arguments: VoicePerformanceDriverProcessArguments(
                    tracerBundlePath: fixture.bundlePath,
                    deadline: .init(nanoseconds: 300_000_000_000)
                ),
                verifiedBundle: fixture.context,
                runtime: runtime
            )
        }

        #expect(runtime.sideEffects.isEmpty)
        #expect(runtime.spawnedRequests.isEmpty)
    }

    @Test("first challenge enforces the exclusive cumulative deadline")
    func firstChallengeUsesExactCumulativeBoundary() throws {
        let phaseCap: UInt64 = 35_000_000_000

        for delay in [phaseCap - 1, phaseCap] {
            let fixture = try DriverCommandFixture(coldTrials: 1)
            let binding = try fixture.binding(trial: 1)
            let connection = RecordingDriverConnection(
                frames: [
                    .challenge(
                        peerRole: .driver,
                        sessionID: binding.sessionID,
                        planNonce: binding.planNonce,
                        collectorNonce: try driverNonce("8")
                    ),
                ],
                receiveDelaysNanoseconds: [delay]
            )
            let helper = VoicePerformanceSupervisedProcessGeneration(
                pid: 51,
                startToken: 10_001,
                processGroupID: 41
            )
            let runtime = RecordingDriverRuntime(
                now: 1_000,
                connection: connection,
                helperGenerations: [helper],
                peerNonces: [try driverNonce("9")]
            )
            connection.recorder = runtime.recorder
            let operation = {
                try VoicePerformanceTracerDriverCommand.run(
                    arguments: VoicePerformanceDriverProcessArguments(
                        tracerBundlePath: fixture.bundlePath,
                        deadline: .init(
                            nanoseconds: 300_000_000_000
                        )
                    ),
                    verifiedBundle: fixture.context,
                    runtime: runtime
                )
            }

            if delay < phaseCap {
                try operation()
                #expect(runtime.terminatedHelpers.isEmpty)
            } else {
                #expect(
                    throws:
                        VoicePerformanceTracerDriverCommandError
                            .deadlineExpired
                ) {
                    try operation()
                }
                #expect(runtime.terminatedHelpers == [helper])
            }
            #expect(
                connection.receiveDeadlines.first?.nanoseconds
                    == 35_000_001_000
            )
        }
    }

    @Test("every trial owns one fresh helper and no helper overlaps the next")
    func twoTrialsUseFreshNonOverlappingHelpers() throws {
        let fixture = try DriverCommandFixture(coldTrials: 2)
        let first = try fixture.binding(trial: 1)
        let second = try fixture.binding(trial: 2)
        let connection = RecordingDriverConnection(frames: [
            .challenge(
                peerRole: .driver,
                sessionID: first.sessionID,
                planNonce: first.planNonce,
                collectorNonce: try driverNonce("8")
            ),
            .challenge(
                peerRole: .driver,
                sessionID: second.sessionID,
                planNonce: second.planNonce,
                collectorNonce: try driverNonce("a")
            ),
        ])
        let helpers = [
            VoicePerformanceSupervisedProcessGeneration(
                pid: 51,
                startToken: 10_001,
                processGroupID: 41
            ),
            VoicePerformanceSupervisedProcessGeneration(
                pid: 52,
                startToken: 10_002,
                processGroupID: 41
            ),
        ]
        let runtime = RecordingDriverRuntime(
            now: 1_000,
            connection: connection,
            helperGenerations: helpers,
            peerNonces: [
                try driverNonce("9"),
                try driverNonce("b"),
            ]
        )
        connection.recorder = runtime.recorder

        try VoicePerformanceTracerDriverCommand.run(
            arguments: VoicePerformanceDriverProcessArguments(
                tracerBundlePath: fixture.bundlePath,
                deadline: .init(nanoseconds: 100_000_000_000)
            ),
            verifiedBundle: fixture.context,
            runtime: runtime
        )

        #expect(runtime.sideEffects == [
            "current-generation", "bind-driver", "connect",
            "spawn", "receive", "random", "send", "send", "reap",
            "spawn", "receive", "random", "send", "send", "reap",
            "close",
        ])
        #expect(runtime.spawnedRequests.map(\.trial) == [1, 2])
        #expect(runtime.reapedHelpers == helpers)
        #expect(runtime.maximumActiveHelpers == 1)
    }

    @Test("wrong role or derived binding closes and reaps the exact helper")
    func wrongChallengeBindingFailsClosed() throws {
        let fixture = try DriverCommandFixture(coldTrials: 1)
        let expected = try fixture.binding(trial: 1)
        let other = try PerformanceControlSessionBinding.derive(
            controlSessionNonce: try driverNonce("6"),
            trial: 1
        )
        let invalidChallenges: [PerformanceControlWireFrame] = [
            .challenge(
                peerRole: .helper,
                sessionID: expected.sessionID,
                planNonce: expected.planNonce,
                collectorNonce: try driverNonce("8")
            ),
            .challenge(
                peerRole: .driver,
                sessionID: other.sessionID,
                planNonce: expected.planNonce,
                collectorNonce: try driverNonce("8")
            ),
            .challenge(
                peerRole: .driver,
                sessionID: expected.sessionID,
                planNonce: other.planNonce,
                collectorNonce: try driverNonce("8")
            ),
        ]

        for challenge in invalidChallenges {
            let connection = RecordingDriverConnection(frames: [challenge])
            let helper = VoicePerformanceSupervisedProcessGeneration(
                pid: 51,
                startToken: 10_001,
                processGroupID: 41
            )
            let runtime = RecordingDriverRuntime(
                now: 1_000,
                connection: connection,
                helperGenerations: [helper]
            )
            connection.recorder = runtime.recorder

            #expect(
                throws:
                    VoicePerformanceTracerDriverCommandError.invalidChallenge
            ) {
                try VoicePerformanceTracerDriverCommand.run(
                    arguments: VoicePerformanceDriverProcessArguments(
                        tracerBundlePath: fixture.bundlePath,
                        deadline: .init(nanoseconds: 100_000_000_000)
                    ),
                    verifiedBundle: fixture.context,
                    runtime: runtime
                )
            }
            #expect(runtime.terminatedHelpers == [helper])
            #expect(connection.closeCount == 1)
            #expect(!runtime.sideEffects.contains("random"))
            #expect(!runtime.sideEffects.contains("send"))
        }
    }

    @Test("collector and peer nonces are globally single-use across trials")
    func nonceReplayFailsClosed() throws {
        let fixture = try DriverCommandFixture(coldTrials: 2)
        let first = try fixture.binding(trial: 1)
        let second = try fixture.binding(trial: 2)
        let replayedCollectorNonce = try driverNonce("8")
        let connection = RecordingDriverConnection(frames: [
            .challenge(
                peerRole: .driver,
                sessionID: first.sessionID,
                planNonce: first.planNonce,
                collectorNonce: replayedCollectorNonce
            ),
            .challenge(
                peerRole: .driver,
                sessionID: second.sessionID,
                planNonce: second.planNonce,
                collectorNonce: replayedCollectorNonce
            ),
        ])
        let helpers = [
            VoicePerformanceSupervisedProcessGeneration(
                pid: 51,
                startToken: 10_001,
                processGroupID: 41
            ),
            VoicePerformanceSupervisedProcessGeneration(
                pid: 52,
                startToken: 10_002,
                processGroupID: 41
            ),
        ]
        let runtime = RecordingDriverRuntime(
            now: 1_000,
            connection: connection,
            helperGenerations: helpers,
            peerNonces: [try driverNonce("9")]
        )
        connection.recorder = runtime.recorder

        #expect(
            throws: VoicePerformanceTracerDriverCommandError.nonceReuse
        ) {
            try VoicePerformanceTracerDriverCommand.run(
                arguments: VoicePerformanceDriverProcessArguments(
                    tracerBundlePath: fixture.bundlePath,
                    deadline: .init(nanoseconds: 100_000_000_000)
                ),
                verifiedBundle: fixture.context,
                runtime: runtime
            )
        }
        #expect(runtime.reapedHelpers == [helpers[0]])
        #expect(runtime.terminatedHelpers == [helpers[1]])
        #expect(connection.closeCount == 1)
    }

    @Test("a nonzero helper result closes transport and terminates exact child")
    func helperFailureUsesExactCleanupAuthority() throws {
        let fixture = try DriverCommandFixture(coldTrials: 1)
        let binding = try fixture.binding(trial: 1)
        let helper = VoicePerformanceSupervisedProcessGeneration(
            pid: 51,
            startToken: 10_001,
            processGroupID: 41
        )
        let connection = RecordingDriverConnection(frames: [
            .challenge(
                peerRole: .driver,
                sessionID: binding.sessionID,
                planNonce: binding.planNonce,
                collectorNonce: try driverNonce("8")
            ),
        ])
        let runtime = RecordingDriverRuntime(
            now: 1_000,
            connection: connection,
            helperGenerations: [helper],
            peerNonces: [try driverNonce("9")],
            failingReapProcessIDs: [helper.pid]
        )
        connection.recorder = runtime.recorder

        #expect(
            throws: VoicePerformanceTracerDriverCommandError.helperFailed
        ) {
            try VoicePerformanceTracerDriverCommand.run(
                arguments: VoicePerformanceDriverProcessArguments(
                    tracerBundlePath: fixture.bundlePath,
                    deadline: .init(nanoseconds: 100_000_000_000)
                ),
                verifiedBundle: fixture.context,
                runtime: runtime
            )
        }
        #expect(runtime.terminatedHelpers == [helper])
        #expect(connection.closeCount == 1)
        #expect(runtime.activeHelpers == 0)
    }

    @Test("a reused helper pid/start generation is rejected and cleaned")
    func helperGenerationReuseFailsClosed() throws {
        let fixture = try DriverCommandFixture(coldTrials: 2)
        let first = try fixture.binding(trial: 1)
        let second = try fixture.binding(trial: 2)
        let helper = VoicePerformanceSupervisedProcessGeneration(
            pid: 51,
            startToken: 10_001,
            processGroupID: 41
        )
        let connection = RecordingDriverConnection(frames: [
            .challenge(
                peerRole: .driver,
                sessionID: first.sessionID,
                planNonce: first.planNonce,
                collectorNonce: try driverNonce("8")
            ),
            .challenge(
                peerRole: .driver,
                sessionID: second.sessionID,
                planNonce: second.planNonce,
                collectorNonce: try driverNonce("a")
            ),
        ])
        let runtime = RecordingDriverRuntime(
            now: 1_000,
            connection: connection,
            helperGenerations: [helper, helper],
            peerNonces: [try driverNonce("9")]
        )
        connection.recorder = runtime.recorder

        #expect(
            throws:
                VoicePerformanceTracerDriverCommandError
                    .helperGenerationReuse
        ) {
            try VoicePerformanceTracerDriverCommand.run(
                arguments: VoicePerformanceDriverProcessArguments(
                    tracerBundlePath: fixture.bundlePath,
                    deadline: .init(nanoseconds: 100_000_000_000)
                ),
                verifiedBundle: fixture.context,
                runtime: runtime
            )
        }
        #expect(runtime.reapedHelpers == [helper])
        #expect(runtime.terminatedHelpers == [helper])
        #expect(connection.closeCount == 1)
    }

    @Test("driver peer nonce replay is rejected before second hello")
    func peerNonceReplayFailsClosed() throws {
        let fixture = try DriverCommandFixture(coldTrials: 2)
        let first = try fixture.binding(trial: 1)
        let second = try fixture.binding(trial: 2)
        let repeatedPeerNonce = try driverNonce("9")
        let connection = RecordingDriverConnection(frames: [
            .challenge(
                peerRole: .driver,
                sessionID: first.sessionID,
                planNonce: first.planNonce,
                collectorNonce: try driverNonce("8")
            ),
            .challenge(
                peerRole: .driver,
                sessionID: second.sessionID,
                planNonce: second.planNonce,
                collectorNonce: try driverNonce("a")
            ),
        ])
        let helpers = [
            VoicePerformanceSupervisedProcessGeneration(
                pid: 51,
                startToken: 10_001,
                processGroupID: 41
            ),
            VoicePerformanceSupervisedProcessGeneration(
                pid: 52,
                startToken: 10_002,
                processGroupID: 41
            ),
        ]
        let runtime = RecordingDriverRuntime(
            now: 1_000,
            connection: connection,
            helperGenerations: helpers,
            peerNonces: [repeatedPeerNonce, repeatedPeerNonce]
        )
        connection.recorder = runtime.recorder

        #expect(
            throws: VoicePerformanceTracerDriverCommandError.nonceReuse
        ) {
            try VoicePerformanceTracerDriverCommand.run(
                arguments: VoicePerformanceDriverProcessArguments(
                    tracerBundlePath: fixture.bundlePath,
                    deadline: .init(nanoseconds: 100_000_000_000)
                ),
                verifiedBundle: fixture.context,
                runtime: runtime
            )
        }
        #expect(connection.sentFrames.count == 2)
        #expect(runtime.reapedHelpers == [helpers[0]])
        #expect(runtime.terminatedHelpers == [helpers[1]])
    }

    @Test("global expiry after spawn prevents challenge I/O and reaps helper")
    func deadlineAfterSpawnUsesExactCleanup() throws {
        let fixture = try DriverCommandFixture(coldTrials: 1)
        let helper = VoicePerformanceSupervisedProcessGeneration(
            pid: 51,
            startToken: 10_001,
            processGroupID: 41
        )
        let connection = RecordingDriverConnection(frames: [])
        let runtime = RecordingDriverRuntime(
            now: 1,
            connection: connection,
            helperGenerations: [helper],
            expireAtSideEffectCount: 4,
            expiredNow: 100
        )
        connection.recorder = runtime.recorder

        #expect(
            throws: VoicePerformanceTracerDriverCommandError.deadlineExpired
        ) {
            try VoicePerformanceTracerDriverCommand.run(
                arguments: VoicePerformanceDriverProcessArguments(
                    tracerBundlePath: fixture.bundlePath,
                    deadline: .init(nanoseconds: 100)
                ),
                verifiedBundle: fixture.context,
                runtime: runtime
            )
        }
        #expect(connection.receiveDeadlines.isEmpty)
        #expect(runtime.terminatedHelpers == [helper])
        #expect(connection.closeCount == 1)
        #expect(!runtime.sideEffects.contains("random"))
        #expect(!runtime.sideEffects.contains("send"))
    }

    @Test("global expiry before helper wait remains a deadline failure")
    func deadlineBeforeHelperWaitKeepsDeadlineClassification() throws {
        let fixture = try DriverCommandFixture(coldTrials: 1)
        let binding = try fixture.binding(trial: 1)
        let helper = VoicePerformanceSupervisedProcessGeneration(
            pid: 51,
            startToken: 10_001,
            processGroupID: 41
        )
        let connection = RecordingDriverConnection(frames: [
            .challenge(
                peerRole: .driver,
                sessionID: binding.sessionID,
                planNonce: binding.planNonce,
                collectorNonce: try driverNonce("8")
            ),
        ])
        let runtime = RecordingDriverRuntime(
            now: 1,
            connection: connection,
            helperGenerations: [helper],
            peerNonces: [try driverNonce("9")],
            expireAtSideEffectCount: 8,
            expiredNow: 100
        )
        connection.recorder = runtime.recorder

        #expect(
            throws: VoicePerformanceTracerDriverCommandError.deadlineExpired
        ) {
            try VoicePerformanceTracerDriverCommand.run(
                arguments: VoicePerformanceDriverProcessArguments(
                    tracerBundlePath: fixture.bundlePath,
                    deadline: .init(nanoseconds: 100)
                ),
                verifiedBundle: fixture.context,
                runtime: runtime
            )
        }
        #expect(runtime.reapedHelpers.isEmpty)
        #expect(runtime.terminatedHelpers == [helper])
        #expect(connection.closeCount == 1)
    }

    @Test("helper lifetime admits 16s and 60s cold loads")
    func helperLifetimeAllowsLegitimateColdLoads() throws {
        for duration in [
            UInt64(16_000_000_000),
            UInt64(60_000_000_000),
        ] {
            let fixture = try DriverCommandFixture(coldTrials: 1)
            let binding = try fixture.binding(trial: 1)
            let connection = RecordingDriverConnection(frames: [
                .challenge(
                    peerRole: .driver,
                    sessionID: binding.sessionID,
                    planNonce: binding.planNonce,
                    collectorNonce: try driverNonce("8")
                ),
            ])
            let helper = VoicePerformanceSupervisedProcessGeneration(
                pid: 51,
                startToken: 10_001,
                processGroupID: 41
            )
            let runtime = RecordingDriverRuntime(
                now: 1,
                connection: connection,
                helperGenerations: [helper],
                peerNonces: [try driverNonce("9")],
                helperRunNanoseconds: [duration]
            )
            connection.recorder = runtime.recorder

            try VoicePerformanceTracerDriverCommand.run(
                arguments: VoicePerformanceDriverProcessArguments(
                    tracerBundlePath: fixture.bundlePath,
                    deadline: .init(nanoseconds: 200_000_000_000)
                ),
                verifiedBundle: fixture.context,
                runtime: runtime
            )

            #expect(runtime.reapDeadlines.map(\.nanoseconds)
                == [125_000_000_001])
            #expect(runtime.terminatedHelpers.isEmpty)
        }
    }

    @Test("helper lifetime exceeding 125s is rejected and cleaned")
    func helperLifetimeTimeoutFailsClosed() throws {
        let fixture = try DriverCommandFixture(coldTrials: 1)
        let binding = try fixture.binding(trial: 1)
        let connection = RecordingDriverConnection(frames: [
            .challenge(
                peerRole: .driver,
                sessionID: binding.sessionID,
                planNonce: binding.planNonce,
                collectorNonce: try driverNonce("8")
            ),
        ])
        let helper = VoicePerformanceSupervisedProcessGeneration(
            pid: 51,
            startToken: 10_001,
            processGroupID: 41
        )
        let runtime = RecordingDriverRuntime(
            now: 1,
            connection: connection,
            helperGenerations: [helper],
            peerNonces: [try driverNonce("9")],
            helperRunNanoseconds: [126_000_000_000]
        )
        connection.recorder = runtime.recorder

        #expect(
            throws: VoicePerformanceTracerDriverCommandError.helperFailed
        ) {
            try VoicePerformanceTracerDriverCommand.run(
                arguments: VoicePerformanceDriverProcessArguments(
                    tracerBundlePath: fixture.bundlePath,
                    deadline: .init(nanoseconds: 200_000_000_000)
                ),
                verifiedBundle: fixture.context,
                runtime: runtime
            )
        }
        #expect(runtime.terminatedHelpers == [helper])
        #expect(connection.closeCount == 1)
    }
}

private final class DriverEventRecorder: @unchecked Sendable {
    var events: [String] = []
}

private final class DriverTestClock: @unchecked Sendable {
    var now: UInt64

    init(now: UInt64) {
        self.now = now
    }
}

private final class RecordingDriverConnection:
    VoicePerformanceTracerDriverConnection,
    @unchecked Sendable
{
    var recorder = DriverEventRecorder()
    var clock = DriverTestClock(now: 0)
    private var frames: [PerformanceControlWireFrame]
    private var receiveDelaysNanoseconds: [UInt64]
    private(set) var sentFrames: [PerformanceControlWireFrame] = []
    private(set) var sentDeadlines: [VoicePerformanceContinuousDeadline] = []
    private(set) var receiveDeadlines: [
        VoicePerformanceContinuousDeadline
    ] = []
    private(set) var closeCount = 0

    init(
        frames: [PerformanceControlWireFrame],
        receiveDelaysNanoseconds: [UInt64] = []
    ) {
        self.frames = frames
        self.receiveDelaysNanoseconds = receiveDelaysNanoseconds
    }

    func receive(
        deadline: VoicePerformanceContinuousDeadline
    ) throws -> PerformanceControlWireFrame {
        recorder.events.append("receive")
        receiveDeadlines.append(deadline)
        let delay = receiveDelaysNanoseconds.isEmpty
            ? 0
            : receiveDelaysNanoseconds.removeFirst()
        let (completion, overflow) = clock.now.addingReportingOverflow(
            delay
        )
        guard !overflow,
              completion < deadline.nanoseconds
        else {
            throw VoicePerformanceTracerDriverConnectionError.timedOut
        }
        clock.now = completion
        guard !frames.isEmpty else {
            throw DriverFixtureError.unexpectedCall
        }
        return frames.removeFirst()
    }

    func send(
        _ frame: PerformanceControlWireFrame,
        deadline: VoicePerformanceContinuousDeadline
    ) throws {
        recorder.events.append("send")
        sentFrames.append(frame)
        sentDeadlines.append(deadline)
    }

    func close() {
        recorder.events.append("close")
        closeCount += 1
    }
}

private final class RecordingDriverRuntime:
    VoicePerformanceTracerDriverCommandRuntime,
    @unchecked Sendable
{
    let recorder = DriverEventRecorder()
    private let clock: DriverTestClock
    private let connection: RecordingDriverConnection?
    private var helperGenerations: [
        VoicePerformanceSupervisedProcessGeneration
    ]
    private var peerNonces: [PerformanceControlNonce]
    private let failingReapProcessIDs: Set<Int32>
    private var helperRunNanoseconds: [UInt64]
    private let expireAtSideEffectCount: Int?
    private let expiredNow: UInt64
    private(set) var connectedSocketPath: String?
    private(set) var connectedCollector:
        PerformanceControlExpectedPeerIdentity?
    private(set) var connectDeadline: VoicePerformanceContinuousDeadline?
    private(set) var spawnedRequests: [VoicePerformanceHelperSpawnRequest] = []
    private(set) var joinedProcessGroups: [Int32] = []
    private(set) var reapedHelpers: [
        VoicePerformanceSupervisedProcessGeneration
    ] = []
    private(set) var terminatedHelpers: [
        VoicePerformanceSupervisedProcessGeneration
    ] = []
    private(set) var reapDeadlines: [VoicePerformanceContinuousDeadline] = []
    private(set) var activeHelpers = 0
    private(set) var maximumActiveHelpers = 0

    var sideEffects: [String] { recorder.events }

    init(
        now: UInt64,
        connection: RecordingDriverConnection? = nil,
        helperGenerations: [
            VoicePerformanceSupervisedProcessGeneration
        ] = [],
        peerNonces: [PerformanceControlNonce] = [],
        failingReapProcessIDs: Set<Int32> = [],
        helperRunNanoseconds: [UInt64] = [],
        expireAtSideEffectCount: Int? = nil,
        expiredNow: UInt64 = .max
    ) {
        clock = DriverTestClock(now: now)
        self.connection = connection
        self.helperGenerations = helperGenerations
        self.peerNonces = peerNonces
        self.failingReapProcessIDs = failingReapProcessIDs
        self.helperRunNanoseconds = helperRunNanoseconds
        self.expireAtSideEffectCount = expireAtSideEffectCount
        self.expiredNow = expiredNow
        connection?.clock = clock
    }

    func currentContinuousNanoseconds() throws -> UInt64 {
        if let expireAtSideEffectCount,
           recorder.events.count >= expireAtSideEffectCount
        {
            return expiredNow
        }
        return clock.now
    }

    func currentDriverGeneration() throws
        -> VoicePerformanceSupervisedProcessGeneration
    {
        recorder.events.append("current-generation")
        return .init(pid: 41, startToken: 9_001, processGroupID: 41)
    }

    func bindCurrentDriver(
        expected: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        recorder.events.append("bind-driver")
    }

    func connect(
        socketPath: String,
        expectedCollector: PerformanceControlExpectedPeerIdentity,
        deadline: VoicePerformanceContinuousDeadline
    ) throws -> any VoicePerformanceTracerDriverConnection {
        recorder.events.append("connect")
        connectedSocketPath = socketPath
        connectedCollector = expectedCollector
        connectDeadline = deadline
        guard let connection else {
            throw DriverFixtureError.unexpectedCall
        }
        return connection
    }

    func spawnHelper(
        _ request: VoicePerformanceHelperSpawnRequest,
        joiningProcessGroup processGroupID: Int32
    ) throws -> VoicePerformanceSupervisedProcessGeneration {
        recorder.events.append("spawn")
        spawnedRequests.append(request)
        joinedProcessGroups.append(processGroupID)
        guard !helperGenerations.isEmpty else {
            throw DriverFixtureError.unexpectedCall
        }
        activeHelpers += 1
        maximumActiveHelpers = max(maximumActiveHelpers, activeHelpers)
        return helperGenerations.removeFirst()
    }

    func reapSucceededHelper(
        expected: VoicePerformanceSupervisedProcessGeneration,
        deadline: VoicePerformanceContinuousDeadline
    ) throws {
        recorder.events.append("reap")
        reapedHelpers.append(expected)
        reapDeadlines.append(deadline)
        if !helperRunNanoseconds.isEmpty {
            let duration = helperRunNanoseconds.removeFirst()
            let (completion, overflow) = clock.now.addingReportingOverflow(
                duration
            )
            if overflow || completion >= deadline.nanoseconds {
                throw DriverFixtureError.helperFailed
            }
        }
        if failingReapProcessIDs.contains(expected.pid) {
            throw DriverFixtureError.helperFailed
        }
        activeHelpers -= 1
    }

    func terminateHelperAndReap(
        expected: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        recorder.events.append("terminate")
        terminatedHelpers.append(expected)
        activeHelpers -= 1
    }

    func securePeerNonce() throws -> PerformanceControlNonce {
        recorder.events.append("random")
        guard !peerNonces.isEmpty else {
            throw DriverFixtureError.unexpectedCall
        }
        return peerNonces.removeFirst()
    }
}

private enum DriverFixtureError: Error {
    case unexpectedCall
    case helperFailed
}

private struct DriverCommandFixture {
    let bundlePath = "/Applications/RimeAIVoicePerformanceTracer.bundle"
    let measurementPolicy: VoicePerformanceMeasurementPolicy
    let driverPolicy: SealedPerformanceControlDriverPolicy
    let context: VerifiedPerformanceTracerBundleContext

    init(
        coldTrials: UInt64,
        helperExecutablePath: String? = nil
    ) throws {
        let protocolSHA = String(repeating: "9", count: 64)
        let protocolIdentity = try PerformanceControlProtocolIdentity(
            id: PerformanceControlProtocolIdentity.requiredID,
            sha256: protocolSHA
        )
        let driverPolicyData = Data(
            ("{\"capabilities\":[\"authenticated_control\",\"lazy_load_ticket\"],"
                + "\"control_protocol\":{\"id\":\"\(protocolIdentity.id)\","
                + "\"sha256\":\"\(protocolSHA)\"},"
                + "\"qualification\":\"tracer\",\"schema_version\":1}").utf8
        )
        driverPolicy = try SealedPerformanceControlDriverPolicy
            .decodeCanonical(
                driverPolicyData,
                expectedControlProtocol: protocolIdentity
            )
        let collectorPath = bundlePath
            + VoicePerformanceTracerBundleLayout.collectorExecutableSuffix
        let driverPath = bundlePath
            + VoicePerformanceTracerBundleLayout.driverExecutableSuffix
        let helperPath = helperExecutablePath
            ?? bundlePath
                + VoicePerformanceTracerBundleLayout
                    .helperExecutableSuffix
        let data = Data(
            ("{\"cold_trials\":\(coldTrials),"
                + "\"collector\":{\"expected_cdhash\":\"\(String(repeating: "1", count: 40))\","
                + "\"expected_executable_path\":\"\(collectorPath)\","
                + "\"expected_executable_sha256\":\"\(String(repeating: "a", count: 64))\","
                + "\"expected_signing_identifier\":\"\(VoicePerformanceMeasurementPolicy.requiredCollectorSigningIdentifier)\","
                + "\"expected_team_identifier\":\"ABCDEFGHIJ\"},"
                + "\"control_protocol\":{\"id\":\"\(protocolIdentity.id)\",\"sha256\":\"\(protocolSHA)\"},"
                + "\"control_session_nonce\":\"\(String(repeating: "7", count: 64))\","
                + "\"control_socket_path\":\"/tmp/rimeai-performance.sock\","
                + "\"driver\":{\"expected_cdhash\":\"\(String(repeating: "2", count: 40))\","
                + "\"expected_executable_path\":\"\(driverPath)\","
                + "\"expected_executable_sha256\":\"\(String(repeating: "b", count: 64))\","
                + "\"expected_signing_identifier\":\"\(VoicePerformanceMeasurementPolicy.requiredDriverSigningIdentifier)\","
                + "\"expected_team_identifier\":\"ABCDEFGHIJ\","
                + "\"policy_sha256\":\"\(driverPolicy.canonicalSHA256.rawValue)\"},"
                + "\"enabled\":true,"
                + "\"evaluation_artifact\":{\"adapter_id\":\"sherpa-onnx\","
                + "\"artifact_id\":\"fixture-artifact\","
                + "\"content_sha256\":\"\(String(repeating: "d", count: 64))\","
                + "\"directory\":\"/Library/Application Support/RimeAI/fixture\","
                + "\"maximum_hotwords\":64},"
                + "\"helper\":{\"expected_cdhash\":\"\(String(repeating: "3", count: 40))\","
                + "\"expected_executable_path\":\"\(helperPath)\","
                + "\"expected_executable_sha256\":\"\(String(repeating: "c", count: 64))\","
                + "\"expected_signing_identifier\":\"\(VoicePerformanceMeasurementPolicy.requiredHelperSigningIdentifier)\","
                + "\"expected_team_identifier\":\"ABCDEFGHIJ\"},"
                + "\"release_policy_sha256\":\"\(String(repeating: "e", count: 64))\","
                + "\"schema_version\":2}").utf8
        )
        measurementPolicy = try VoicePerformanceMeasurementPolicy
            .decodeCanonical(data)
        context = VerifiedPerformanceTracerBundleContext(
            outerPath: bundlePath,
            outerURL: URL(fileURLWithPath: bundlePath),
            measurementPolicy: measurementPolicy,
            driverPolicy: driverPolicy,
            selfStartToken: 9_001
        )
    }

    func binding(
        trial: UInt64
    ) throws -> PerformanceControlSessionBinding {
        try PerformanceControlSessionBinding.derive(
            controlSessionNonce: PerformanceControlNonce(
                measurementPolicy.controlSessionNonce
            ),
            trial: trial
        )
    }

    func expectedCollector()
        throws -> PerformanceControlExpectedPeerIdentity
    {
        try PerformanceControlExpectedPeerIdentity(
            expectedExecutablePath:
                measurementPolicy.collector.expectedExecutablePath,
            expectedExecutableSHA256:
                measurementPolicy.collector.expectedExecutableSHA256,
            expectedSigningIdentifier:
                measurementPolicy.collector.expectedSigningIdentifier,
            expectedTeamIdentifier:
                measurementPolicy.collector.expectedTeamIdentifier,
            expectedCDHash:
                measurementPolicy.collector.expectedCDHash
        )
    }

    func expectedHelperIdentity()
        throws -> VoicePerformanceExpectedChildIdentity
    {
        try VoicePerformanceExpectedChildIdentity(
            executablePath:
                measurementPolicy.helper.expectedExecutablePath,
            executableSHA256:
                measurementPolicy.helper.expectedExecutableSHA256,
            signingIdentifier:
                measurementPolicy.helper.expectedSigningIdentifier,
            teamIdentifier:
                measurementPolicy.helper.expectedTeamIdentifier,
            cdHash: measurementPolicy.helper.expectedCDHash
        )
    }
}

private func driverNonce(
    _ character: Character
) throws -> PerformanceControlNonce {
    try PerformanceControlNonce(String(repeating: character, count: 64))
}
