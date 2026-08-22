import Foundation
import RimeAIVoicePerformanceControlCore
import RimeAIVoicePerformanceControlDarwin
import Testing
@testable import RimeAIVoicePerformanceTracerHelperProcess
@testable import RimeAIVoicePerformanceTracerProcessDarwin

@Suite("Voice performance tracer helper command")
struct VoicePerformanceTracerHelperCommandTests {
    @Test("raw transport failures normalize to typed helper errors")
    func transportFailuresAreTypedBeforeReachingCommand() {
        #expect(
            VoicePerformanceHelperTransportErrorNormalizer.normalize(
                PerformanceControlTransportError.operationTimedOut
            ) == .timedOut
        )
        #expect(
            VoicePerformanceHelperTransportErrorNormalizer.normalize(
                PerformanceControlTransportError.peerDisconnected
            ) == .peerDisconnected
        )
        #expect(
            VoicePerformanceHelperTransportErrorNormalizer.normalize(
                VoicePerformanceTracerHelperConnectionError.timedOut
            ) == .timedOut
        )
        #expect(
            VoicePerformanceHelperTransportErrorNormalizer.normalize(
                HelperFixtureError.unexpectedCall
            ) == .failed
        )
    }

    @Test("transport conversion samples base before mach remaining time")
    func transportDeadlineNeverAddsConversionLatency() throws {
        let base = ContinuousClock().now
        var events: [String] = []
        let converter = VoicePerformanceHelperTransportDeadlineConverter(
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

    @Test("an expired global deadline creates no facade and performs no I/O")
    func expiredDeadlineHasNoSideEffects() throws {
        let fixture = try HelperCommandFixture(coldTrials: 1)
        let runtime = RecordingHelperRuntime(now: 100)

        #expect(
            throws: VoicePerformanceTracerHelperCommandError.deadlineExpired
        ) {
            try VoicePerformanceTracerHelperCommand.run(
                arguments: VoicePerformanceHelperProcessArguments(
                    tracerBundlePath: fixture.bundlePath,
                    trial: 1,
                    deadline: .init(nanoseconds: 100)
                ),
                verifiedBundle: fixture.context,
                runtime: runtime
            )
        }
        #expect(runtime.sideEffects.isEmpty)
    }

    @Test("helper follows challenge load acknowledgement ready then EOF")
    func happyPathUsesExactFramesAndAcknowledgementBoundary() throws {
        let fixture = try HelperCommandFixture(coldTrials: 3)
        let binding = try fixture.binding(trial: 2)
        let collectorNonce = try helperNonce("8")
        let peerNonce = try helperNonce("9")
        let ticket = try helperNonce("2")
        let facade = try RecordingHelperFacade(
            measurementPolicy: fixture.measurementPolicy,
            peerNonce: peerNonce
        )
        let connection = RecordingHelperConnection(
            frames: [
                .challenge(
                    peerRole: .helper,
                    sessionID: binding.sessionID,
                    planNonce: binding.planNonce,
                    collectorNonce: collectorNonce
                ),
                .loadEngine(
                    sequence: 1,
                    sessionID: binding.sessionID,
                    trial: 2,
                    loadTicket: ticket
                ),
                .loadStartedAck(
                    sequence: 2,
                    sessionID: binding.sessionID,
                    replyTo: 1,
                    trial: 2,
                    loadTicket: ticket
                ),
            ],
            terminalError: .peerDisconnected
        )
        let runtime = RecordingHelperRuntime(
            now: 1_000,
            facade: facade,
            connection: connection
        )
        facade.recorder = runtime.recorder
        connection.recorder = runtime.recorder

        try VoicePerformanceTracerHelperCommand.run(
            arguments: VoicePerformanceHelperProcessArguments(
                tracerBundlePath: fixture.bundlePath,
                trial: 2,
                deadline: .init(nanoseconds: 100_000_000_000)
            ),
            verifiedBundle: fixture.context,
            runtime: runtime
        )

        #expect(runtime.sideEffects == [
            "current-generation",
            "make-facade",
            "connect",
            "receive", "facade-receive", "send",
            "receive", "facade-receive", "send",
            "receive", "facade-receive", "loader", "send",
            "receive", "disconnect", "close",
        ])
        #expect(facade.loaderCountsBeforeReceive == [0, 0, 0])
        #expect(facade.loaderInvocationCount == 1)
        #expect(facade.receivedDeadlines.map(\.nanoseconds) == [
            5_000_001_000,
            5_000_001_000,
            60_000_001_000,
        ])
        #expect(facade.cancelCount == 0)
        #expect(facade.timeoutCount == 0)
        #expect(facade.disconnectCount == 1)
        #expect(connection.sentFrames.count == 3)
        #expect(connection.receiveDeadlines.map(\.nanoseconds) == [
            40_000_001_000,
            20_000_001_000,
            10_000_001_000,
            5_000_001_000,
        ])
        #expect(connection.sentDeadlines.map(\.nanoseconds) == [
            5_000_001_000,
            5_000_001_000,
            5_000_001_000,
        ])
        guard connection.sentFrames.count == 3 else { return }
        #expect(connection.sentFrames[0] == .helperHello(
            sessionID: binding.sessionID,
            planNonce: binding.planNonce,
            collectorNonce: collectorNonce,
            peerNonce: peerNonce,
            measurementPolicySHA256: try PerformanceControlSHA256(
                fixture.measurementPolicy.canonicalSHA256
            ),
            releasePolicySHA256: try PerformanceControlSHA256(
                fixture.measurementPolicy.releasePolicySHA256
            )
        ))
        #expect(connection.sentFrames[1] == .loadStarted(
            sequence: 1,
            sessionID: binding.sessionID,
            replyTo: 1,
            trial: 2,
            loadTicket: ticket
        ))
        guard case let .loadReady(
            sequence,
            sessionID,
            replyTo,
            trial,
            readyTicket,
            _
        ) = connection.sentFrames[2]
        else {
            Issue.record("expected load_ready")
            return
        }
        #expect(sequence == 2)
        #expect(sessionID == binding.sessionID)
        #expect(replyTo == 2)
        #expect(trial == 2)
        #expect(readyTicket == ticket)
        #expect(connection.closeCount == 1)
    }

    @Test("cumulative collector receive phases use exclusive deadlines")
    func cumulativeReceiveBoundariesAreExact() throws {
        let phases: [(receiveIndex: Int, cap: UInt64)] = [
            (0, 40_000_000_000),
            (1, 20_000_000_000),
            (2, 10_000_000_000),
        ]

        for phase in phases {
            for delay in [phase.cap - 1, phase.cap] {
                let fixture = try HelperCommandFixture(coldTrials: 1)
                let binding = try fixture.binding(trial: 1)
                let ticket = try helperNonce("2")
                let facade = try RecordingHelperFacade(
                    measurementPolicy: fixture.measurementPolicy,
                    peerNonce: try helperNonce("9")
                )
                var receiveDelays = [UInt64](
                    repeating: 0,
                    count: 3
                )
                receiveDelays[phase.receiveIndex] = delay
                let connection = RecordingHelperConnection(
                    frames: [
                        .challenge(
                            peerRole: .helper,
                            sessionID: binding.sessionID,
                            planNonce: binding.planNonce,
                            collectorNonce: try helperNonce("8")
                        ),
                        .loadEngine(
                            sequence: 1,
                            sessionID: binding.sessionID,
                            trial: 1,
                            loadTicket: ticket
                        ),
                        .loadStartedAck(
                            sequence: 2,
                            sessionID: binding.sessionID,
                            replyTo: 1,
                            trial: 1,
                            loadTicket: ticket
                        ),
                    ],
                    terminalError: .peerDisconnected,
                    receiveDelaysNanoseconds: receiveDelays
                )
                let runtime = RecordingHelperRuntime(
                    now: 1_000,
                    facade: facade,
                    connection: connection
                )
                facade.recorder = runtime.recorder
                connection.recorder = runtime.recorder
                let operation = {
                    try VoicePerformanceTracerHelperCommand.run(
                        arguments: VoicePerformanceHelperProcessArguments(
                            tracerBundlePath: fixture.bundlePath,
                            trial: 1,
                            deadline: .init(
                                nanoseconds: 300_000_000_000
                            )
                        ),
                        verifiedBundle: fixture.context,
                        runtime: runtime
                    )
                }

                if delay < phase.cap {
                    try operation()
                    #expect(facade.disconnectCount == 1)
                } else {
                    #expect(
                        throws:
                            VoicePerformanceTracerHelperCommandError
                                .deadlineExpired
                    ) {
                        try operation()
                    }
                    #expect(facade.timeoutCount == 1)
                }
                #expect(
                    connection.receiveDeadlines[
                        phase.receiveIndex
                    ].nanoseconds == 1_000 + phase.cap
                )
            }
        }
    }

    @Test("wrong challenge role or policy binding is rejected before facade")
    func wrongChallengeFailsBeforeFacadeOrLoader() throws {
        let fixture = try HelperCommandFixture(coldTrials: 2)
        let expected = try fixture.binding(trial: 2)
        let other = try fixture.binding(trial: 1)
        let invalidChallenges: [PerformanceControlWireFrame] = [
            .challenge(
                peerRole: .driver,
                sessionID: expected.sessionID,
                planNonce: expected.planNonce,
                collectorNonce: try helperNonce("8")
            ),
            .challenge(
                peerRole: .helper,
                sessionID: other.sessionID,
                planNonce: expected.planNonce,
                collectorNonce: try helperNonce("8")
            ),
            .challenge(
                peerRole: .helper,
                sessionID: expected.sessionID,
                planNonce: other.planNonce,
                collectorNonce: try helperNonce("8")
            ),
        ]

        for challenge in invalidChallenges {
            let facade = try RecordingHelperFacade(
                measurementPolicy: fixture.measurementPolicy,
                peerNonce: try helperNonce("9")
            )
            let connection = RecordingHelperConnection(
                frames: [challenge],
                terminalError: .failed
            )
            let runtime = RecordingHelperRuntime(
                now: 1_000,
                facade: facade,
                connection: connection
            )
            facade.recorder = runtime.recorder
            connection.recorder = runtime.recorder

            #expect(
                throws:
                    VoicePerformanceTracerHelperCommandError.invalidChallenge
            ) {
                try VoicePerformanceTracerHelperCommand.run(
                    arguments: VoicePerformanceHelperProcessArguments(
                        tracerBundlePath: fixture.bundlePath,
                        trial: 2,
                        deadline: .init(
                            nanoseconds: 100_000_000_000
                        )
                    ),
                    verifiedBundle: fixture.context,
                    runtime: runtime
                )
            }
            #expect(facade.loaderInvocationCount == 0)
            #expect(facade.cancelCount == 1)
            #expect(!runtime.sideEffects.contains("facade-receive"))
            #expect(connection.closeCount == 1)
        }
    }

    @Test("EOF before load_ready is fatal and cancels without loading")
    func earlyEOFCancels() throws {
        let fixture = try HelperCommandFixture(coldTrials: 1)
        let facade = try RecordingHelperFacade(
            measurementPolicy: fixture.measurementPolicy,
            peerNonce: try helperNonce("9")
        )
        let connection = RecordingHelperConnection(
            frames: [],
            terminalError: .peerDisconnected
        )
        let runtime = RecordingHelperRuntime(
            now: 1_000,
            facade: facade,
            connection: connection
        )
        facade.recorder = runtime.recorder
        connection.recorder = runtime.recorder

        #expect(
            throws:
                VoicePerformanceTracerHelperCommandError
                    .peerDisconnectedEarly
        ) {
            try VoicePerformanceTracerHelperCommand.run(
                arguments: VoicePerformanceHelperProcessArguments(
                    tracerBundlePath: fixture.bundlePath,
                    trial: 1,
                    deadline: .init(nanoseconds: 100_000_000_000)
                ),
                verifiedBundle: fixture.context,
                runtime: runtime
            )
        }
        #expect(facade.loaderInvocationCount == 0)
        #expect(facade.cancelCount == 1)
        #expect(facade.disconnectCount == 0)
        #expect(connection.closeCount == 1)
    }

    @Test("timeout waiting for acknowledgement never enters the loader")
    func acknowledgementTimeoutUsesTimeoutTermination() throws {
        let fixture = try HelperCommandFixture(coldTrials: 1)
        let binding = try fixture.binding(trial: 1)
        let ticket = try helperNonce("2")
        let facade = try RecordingHelperFacade(
            measurementPolicy: fixture.measurementPolicy,
            peerNonce: try helperNonce("9")
        )
        let connection = RecordingHelperConnection(
            frames: [
                .challenge(
                    peerRole: .helper,
                    sessionID: binding.sessionID,
                    planNonce: binding.planNonce,
                    collectorNonce: try helperNonce("8")
                ),
                .loadEngine(
                    sequence: 1,
                    sessionID: binding.sessionID,
                    trial: 1,
                    loadTicket: ticket
                ),
            ],
            terminalError: .timedOut
        )
        let runtime = RecordingHelperRuntime(
            now: 1_000,
            facade: facade,
            connection: connection
        )
        facade.recorder = runtime.recorder
        connection.recorder = runtime.recorder

        #expect(
            throws: VoicePerformanceTracerHelperCommandError.deadlineExpired
        ) {
            try VoicePerformanceTracerHelperCommand.run(
                arguments: VoicePerformanceHelperProcessArguments(
                    tracerBundlePath: fixture.bundlePath,
                    trial: 1,
                    deadline: .init(nanoseconds: 100_000_000_000)
                ),
                verifiedBundle: fixture.context,
                runtime: runtime
            )
        }
        #expect(facade.loaderInvocationCount == 0)
        #expect(facade.timeoutCount == 1)
        #expect(facade.cancelCount == 0)
        #expect(connection.closeCount == 1)
    }

    @Test("a frame after load_ready is fatal; only EOF is success")
    func extraFrameAfterReadyCancels() throws {
        let fixture = try HelperCommandFixture(coldTrials: 1)
        let binding = try fixture.binding(trial: 1)
        let ticket = try helperNonce("2")
        let facade = try RecordingHelperFacade(
            measurementPolicy: fixture.measurementPolicy,
            peerNonce: try helperNonce("9")
        )
        let connection = RecordingHelperConnection(
            frames: [
                .challenge(
                    peerRole: .helper,
                    sessionID: binding.sessionID,
                    planNonce: binding.planNonce,
                    collectorNonce: try helperNonce("8")
                ),
                .loadEngine(
                    sequence: 1,
                    sessionID: binding.sessionID,
                    trial: 1,
                    loadTicket: ticket
                ),
                .loadStartedAck(
                    sequence: 2,
                    sessionID: binding.sessionID,
                    replyTo: 1,
                    trial: 1,
                    loadTicket: ticket
                ),
                .armColdLoad(
                    sequence: 1,
                    sessionID: binding.sessionID,
                    trial: 1
                ),
            ],
            terminalError: .peerDisconnected
        )
        let runtime = RecordingHelperRuntime(
            now: 1_000,
            facade: facade,
            connection: connection
        )
        facade.recorder = runtime.recorder
        connection.recorder = runtime.recorder

        #expect(
            throws:
                VoicePerformanceTracerHelperCommandError
                    .unexpectedFrameAfterReady
        ) {
            try VoicePerformanceTracerHelperCommand.run(
                arguments: VoicePerformanceHelperProcessArguments(
                    tracerBundlePath: fixture.bundlePath,
                    trial: 1,
                    deadline: .init(nanoseconds: 100_000_000_000)
                ),
                verifiedBundle: fixture.context,
                runtime: runtime
            )
        }
        #expect(facade.loaderInvocationCount == 1)
        #expect(facade.cancelCount == 1)
        #expect(facade.disconnectCount == 0)
        #expect(connection.closeCount == 1)
    }

    @Test("global deadline expiry before ACK prevents receive and loader work")
    func globalDeadlineStopsBeforeAcknowledgement() throws {
        let fixture = try HelperCommandFixture(coldTrials: 1)
        let binding = try fixture.binding(trial: 1)
        let ticket = try helperNonce("2")
        let facade = try RecordingHelperFacade(
            measurementPolicy: fixture.measurementPolicy,
            peerNonce: try helperNonce("9")
        )
        let connection = RecordingHelperConnection(
            frames: [
                .challenge(
                    peerRole: .helper,
                    sessionID: binding.sessionID,
                    planNonce: binding.planNonce,
                    collectorNonce: try helperNonce("8")
                ),
                .loadEngine(
                    sequence: 1,
                    sessionID: binding.sessionID,
                    trial: 1,
                    loadTicket: ticket
                ),
                .loadStartedAck(
                    sequence: 2,
                    sessionID: binding.sessionID,
                    replyTo: 1,
                    trial: 1,
                    loadTicket: ticket
                ),
            ],
            terminalError: .failed
        )
        let runtime = RecordingHelperRuntime(
            now: 1,
            facade: facade,
            connection: connection,
            expireAtSideEffectCount: 9,
            expiredNow: 100
        )
        facade.recorder = runtime.recorder
        connection.recorder = runtime.recorder

        #expect(
            throws: VoicePerformanceTracerHelperCommandError.deadlineExpired
        ) {
            try VoicePerformanceTracerHelperCommand.run(
                arguments: VoicePerformanceHelperProcessArguments(
                    tracerBundlePath: fixture.bundlePath,
                    trial: 1,
                    deadline: .init(nanoseconds: 100)
                ),
                verifiedBundle: fixture.context,
                runtime: runtime
            )
        }
        #expect(connection.receiveDeadlines.count == 2)
        #expect(facade.loaderInvocationCount == 0)
        #expect(facade.timeoutCount == 1)
        #expect(connection.closeCount == 1)
    }

    @Test("expiry after synchronous load prevents load_ready send")
    func deadlineAfterLoadUsesTimeoutAndDoesNotSendReady() throws {
        let fixture = try HelperCommandFixture(coldTrials: 1)
        let binding = try fixture.binding(trial: 1)
        let ticket = try helperNonce("2")
        let facade = try RecordingHelperFacade(
            measurementPolicy: fixture.measurementPolicy,
            peerNonce: try helperNonce("9")
        )
        let connection = RecordingHelperConnection(
            frames: [
                .challenge(
                    peerRole: .helper,
                    sessionID: binding.sessionID,
                    planNonce: binding.planNonce,
                    collectorNonce: try helperNonce("8")
                ),
                .loadEngine(
                    sequence: 1,
                    sessionID: binding.sessionID,
                    trial: 1,
                    loadTicket: ticket
                ),
                .loadStartedAck(
                    sequence: 2,
                    sessionID: binding.sessionID,
                    replyTo: 1,
                    trial: 1,
                    loadTicket: ticket
                ),
            ],
            terminalError: .failed
        )
        let runtime = RecordingHelperRuntime(
            now: 1,
            facade: facade,
            connection: connection,
            expireAtSideEffectCount: 12,
            expiredNow: 100
        )
        facade.recorder = runtime.recorder
        connection.recorder = runtime.recorder

        #expect(
            throws: VoicePerformanceTracerHelperCommandError.deadlineExpired
        ) {
            try VoicePerformanceTracerHelperCommand.run(
                arguments: VoicePerformanceHelperProcessArguments(
                    tracerBundlePath: fixture.bundlePath,
                    trial: 1,
                    deadline: .init(nanoseconds: 100)
                ),
                verifiedBundle: fixture.context,
                runtime: runtime
            )
        }
        #expect(facade.loaderInvocationCount == 1)
        #expect(connection.sentFrames.count == 2)
        #expect(facade.timeoutCount == 1)
        #expect(facade.cancelCount == 0)
        #expect(connection.closeCount == 1)
    }

    @Test("a slow load_ready send uses the frame deadline and times out")
    func slowReadySendUsesFrameTimeout() throws {
        let fixture = try HelperCommandFixture(coldTrials: 1)
        let binding = try fixture.binding(trial: 1)
        let ticket = try helperNonce("2")
        let facade = try RecordingHelperFacade(
            measurementPolicy: fixture.measurementPolicy,
            peerNonce: try helperNonce("9")
        )
        let connection = RecordingHelperConnection(
            frames: [
                .challenge(
                    peerRole: .helper,
                    sessionID: binding.sessionID,
                    planNonce: binding.planNonce,
                    collectorNonce: try helperNonce("8")
                ),
                .loadEngine(
                    sequence: 1,
                    sessionID: binding.sessionID,
                    trial: 1,
                    loadTicket: ticket
                ),
                .loadStartedAck(
                    sequence: 2,
                    sessionID: binding.sessionID,
                    replyTo: 1,
                    trial: 1,
                    loadTicket: ticket
                ),
            ],
            terminalError: .failed,
            failingSendNumber: 3,
            sendFailure: .timedOut
        )
        let runtime = RecordingHelperRuntime(
            now: 1_000,
            facade: facade,
            connection: connection
        )
        facade.recorder = runtime.recorder
        connection.recorder = runtime.recorder

        #expect(
            throws: VoicePerformanceTracerHelperCommandError.deadlineExpired
        ) {
            try VoicePerformanceTracerHelperCommand.run(
                arguments: VoicePerformanceHelperProcessArguments(
                    tracerBundlePath: fixture.bundlePath,
                    trial: 1,
                    deadline: .init(nanoseconds: 100_000_000_000)
                ),
                verifiedBundle: fixture.context,
                runtime: runtime
            )
        }

        #expect(facade.loaderInvocationCount == 1)
        #expect(connection.sentFrames.count == 3)
        #expect(connection.sentDeadlines.last?.nanoseconds == 5_000_001_000)
        #expect(connection.receiveDeadlines.count == 3)
        #expect(facade.timeoutCount == 1)
        #expect(facade.cancelCount == 0)
        #expect(connection.closeCount == 1)
    }

    @Test("acknowledgement cannot arrive before load_engine and load_started")
    func acknowledgementCannotSkipLoadSequence() throws {
        let fixture = try HelperCommandFixture(coldTrials: 1)
        let binding = try fixture.binding(trial: 1)
        let facade = try RecordingHelperFacade(
            measurementPolicy: fixture.measurementPolicy,
            peerNonce: try helperNonce("9")
        )
        let connection = RecordingHelperConnection(
            frames: [
                .challenge(
                    peerRole: .helper,
                    sessionID: binding.sessionID,
                    planNonce: binding.planNonce,
                    collectorNonce: try helperNonce("8")
                ),
                .loadStartedAck(
                    sequence: 2,
                    sessionID: binding.sessionID,
                    replyTo: 1,
                    trial: 1,
                    loadTicket: try helperNonce("2")
                ),
            ],
            terminalError: .failed
        )
        let runtime = RecordingHelperRuntime(
            now: 1_000,
            facade: facade,
            connection: connection
        )
        facade.recorder = runtime.recorder
        connection.recorder = runtime.recorder

        #expect(
            throws: VoicePerformanceTracerHelperCommandError.invalidFrame
        ) {
            try VoicePerformanceTracerHelperCommand.run(
                arguments: VoicePerformanceHelperProcessArguments(
                    tracerBundlePath: fixture.bundlePath,
                    trial: 1,
                    deadline: .init(nanoseconds: 100_000_000_000)
                ),
                verifiedBundle: fixture.context,
                runtime: runtime
            )
        }
        #expect(facade.loaderInvocationCount == 0)
        #expect(facade.loaderCountsBeforeReceive == [0])
        #expect(connection.sentFrames.count == 1)
        #expect(facade.cancelCount == 1)
        #expect(connection.closeCount == 1)
    }
}

private final class HelperEventRecorder: @unchecked Sendable {
    var events: [String] = []
}

private final class HelperTestClock: @unchecked Sendable {
    var now: UInt64

    init(now: UInt64) {
        self.now = now
    }
}

private final class RecordingHelperConnection:
    VoicePerformanceTracerHelperConnection,
    @unchecked Sendable
{
    var recorder = HelperEventRecorder()
    var clock = HelperTestClock(now: 0)
    private var frames: [PerformanceControlWireFrame]
    private var receiveDelaysNanoseconds: [UInt64]
    private let terminalError: VoicePerformanceTracerHelperConnectionError
    private let failingSendNumber: Int?
    private let sendFailure: VoicePerformanceTracerHelperConnectionError
    private(set) var sentFrames: [PerformanceControlWireFrame] = []
    private(set) var sentDeadlines: [VoicePerformanceContinuousDeadline] = []
    private(set) var receiveDeadlines: [VoicePerformanceContinuousDeadline] = []
    private(set) var closeCount = 0

    init(
        frames: [PerformanceControlWireFrame],
        terminalError: VoicePerformanceTracerHelperConnectionError,
        failingSendNumber: Int? = nil,
        sendFailure: VoicePerformanceTracerHelperConnectionError = .failed,
        receiveDelaysNanoseconds: [UInt64] = []
    ) {
        self.frames = frames
        self.receiveDelaysNanoseconds = receiveDelaysNanoseconds
        self.terminalError = terminalError
        self.failingSendNumber = failingSendNumber
        self.sendFailure = sendFailure
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
            throw VoicePerformanceTracerHelperConnectionError.timedOut
        }
        clock.now = completion
        guard !frames.isEmpty else { throw terminalError }
        return frames.removeFirst()
    }

    func send(
        _ frame: PerformanceControlWireFrame,
        deadline: VoicePerformanceContinuousDeadline
    ) throws {
        recorder.events.append("send")
        sentFrames.append(frame)
        sentDeadlines.append(deadline)
        if let failingSendNumber,
           sentFrames.count == failingSendNumber
        {
            throw sendFailure
        }
    }

    func close() {
        recorder.events.append("close")
        closeCount += 1
    }
}

private final class RecordingHelperFacade:
    VoicePerformanceTracerHelperFacade,
    @unchecked Sendable
{
    let authenticatedProductionDriver = false
    var recorder = HelperEventRecorder()
    private let measurementPolicy: VoicePerformanceMeasurementPolicy
    private let peerNonce: PerformanceControlNonce
    private(set) var loaderInvocationCount = 0
    private(set) var loaderCountsBeforeReceive: [Int] = []
    private(set) var receivedDeadlines: [
        VoicePerformanceContinuousDeadline
    ] = []
    private(set) var cancelCount = 0
    private(set) var disconnectCount = 0
    private(set) var timeoutCount = 0

    init(
        measurementPolicy: VoicePerformanceMeasurementPolicy,
        peerNonce: PerformanceControlNonce
    ) throws {
        self.measurementPolicy = measurementPolicy
        self.peerNonce = peerNonce
    }

    func receive(
        _ frame: PerformanceControlWireFrame,
        deadline: VoicePerformanceContinuousDeadline
    ) throws -> PerformanceControlWireFrame {
        recorder.events.append("facade-receive")
        loaderCountsBeforeReceive.append(loaderInvocationCount)
        receivedDeadlines.append(deadline)
        switch frame {
        case let .challenge(
            role,
            sessionID,
            planNonce,
            collectorNonce
        ):
            guard role == .helper else {
                throw HelperFixtureError.unexpectedCall
            }
            return .helperHello(
                sessionID: sessionID,
                planNonce: planNonce,
                collectorNonce: collectorNonce,
                peerNonce: peerNonce,
                measurementPolicySHA256: try PerformanceControlSHA256(
                    measurementPolicy.canonicalSHA256
                ),
                releasePolicySHA256: try PerformanceControlSHA256(
                    measurementPolicy.releasePolicySHA256
                )
            )
        case let .loadEngine(
            sequence,
            sessionID,
            trial,
            loadTicket
        ):
            return .loadStarted(
                sequence: sequence,
                sessionID: sessionID,
                replyTo: sequence,
                trial: trial,
                loadTicket: loadTicket
            )
        case let .loadStartedAck(
            sequence,
            sessionID,
            _,
            trial,
            loadTicket
        ):
            recorder.events.append("loader")
            loaderInvocationCount += 1
            return .loadReady(
                sequence: sequence,
                sessionID: sessionID,
                replyTo: sequence,
                trial: trial,
                loadTicket: loadTicket,
                engine: try helperEngineSummary(
                    policy: measurementPolicy
                )
            )
        default:
            throw HelperFixtureError.unexpectedCall
        }
    }

    func cancel() {
        recorder.events.append("cancel")
        cancelCount += 1
    }

    func disconnect() {
        recorder.events.append("disconnect")
        disconnectCount += 1
    }

    func timeout() {
        recorder.events.append("timeout")
        timeoutCount += 1
    }
}

private final class RecordingHelperRuntime:
    VoicePerformanceTracerHelperCommandRuntime,
    @unchecked Sendable
{
    let recorder = HelperEventRecorder()
    private let clock: HelperTestClock
    private let facade: RecordingHelperFacade?
    private let connection: RecordingHelperConnection?
    private let expireAtSideEffectCount: Int?
    private let expiredNow: UInt64

    var sideEffects: [String] { recorder.events }

    init(
        now: UInt64,
        facade: RecordingHelperFacade? = nil,
        connection: RecordingHelperConnection? = nil,
        expireAtSideEffectCount: Int? = nil,
        expiredNow: UInt64 = .max
    ) {
        clock = HelperTestClock(now: now)
        self.facade = facade
        self.connection = connection
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

    func currentHelperGeneration() throws
        -> VoicePerformanceSupervisedProcessGeneration
    {
        recorder.events.append("current-generation")
        return .init(pid: 51, startToken: 10_001, processGroupID: 41)
    }

    func makeFacade(
        measurementPolicy: VoicePerformanceMeasurementPolicy
    ) throws -> any VoicePerformanceTracerHelperFacade {
        recorder.events.append("make-facade")
        guard let facade else {
            throw HelperFixtureError.unexpectedCall
        }
        return facade
    }

    func connect(
        socketPath: String,
        expectedCollector: PerformanceControlExpectedPeerIdentity,
        deadline: VoicePerformanceContinuousDeadline
    ) throws -> any VoicePerformanceTracerHelperConnection {
        recorder.events.append("connect")
        guard let connection else {
            throw HelperFixtureError.unexpectedCall
        }
        return connection
    }
}

private enum HelperFixtureError: Error {
    case unexpectedCall
}

private struct HelperCommandFixture {
    let bundlePath = "/Applications/RimeAIVoicePerformanceTracer.bundle"
    let measurementPolicy: VoicePerformanceMeasurementPolicy
    let context: VerifiedPerformanceTracerBundleContext

    init(coldTrials: UInt64) throws {
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
        let driverPolicy = try SealedPerformanceControlDriverPolicy
            .decodeCanonical(
                driverPolicyData,
                expectedControlProtocol: protocolIdentity
            )
        let collectorPath = bundlePath
            + VoicePerformanceTracerBundleLayout.collectorExecutableSuffix
        let driverPath = bundlePath
            + VoicePerformanceTracerBundleLayout.driverExecutableSuffix
        let helperPath = bundlePath
            + VoicePerformanceTracerBundleLayout.helperExecutableSuffix
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
            driverPolicy: nil,
            selfStartToken: 10_001
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
}

private func helperNonce(
    _ character: Character
) throws -> PerformanceControlNonce {
    try PerformanceControlNonce(String(repeating: character, count: 64))
}

private func helperEngineSummary(
    policy: VoicePerformanceMeasurementPolicy
) throws -> PerformanceControlEngineSummary {
    try PerformanceControlEngineSummary(
        adapterID: policy.expectedEngine.adapterID,
        engineID: policy.expectedEngine.engineID,
        artifactID: policy.expectedEngine.artifactID,
        artifactContentSHA256:
            policy.expectedEngine.artifactContentSHA256,
        artifactGeneration: PerformanceControlArtifactGeneration(
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        ),
        capabilities: policy.expectedEngine.capabilities,
        networkPolicy: policy.expectedEngine.networkPolicy,
        maximumHotwords: policy.expectedEngine.maximumHotwords
    )
}
