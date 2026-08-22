import Foundation
@testable import RimeAIVoicePerformanceCollector
import RimeAIVoicePerformanceControlCore
import Testing

@testable import RimeAIVoicePerformanceControlDarwin
@testable import RimeAIVoicePerformanceTracerDarwin

@Suite("Darwin voice-performance tracer adapter", .serialized)
struct DarwinVoicePerformanceTracerAdapterTests {
    @Test("accept before launched-driver binding fails terminally")
    func unboundAcceptIsTerminal() throws {
        let fixture = try AdapterFixture()
        let listener = SequenceControlListener(connections: [])
        let transport = DarwinVoicePerformanceTracerTransport(
            controlSocketPath: fixture.measurementPolicy.controlSocketPath,
            listener: listener,
            processSystem: SequenceProcessSystem(
                events: EventLog(),
                probes: []
            )
        )

        #expect(throws: VoicePerformanceTracerCollectorError.transportFailure) {
            try VoicePerformanceTracerCollector(transport: transport).collect(
                fixture.request,
                deadline: ContinuousClock().now.advanced(by: .seconds(1))
            )
        }
        #expect(listener.expectedPeers.isEmpty)
        #expect(throws: VoicePerformanceTracerTransportError.failed) {
            try transport.bindLaunchedDriver(.validDriver)
        }
    }

    @Test("launched-driver binding is one-shot and repetition is terminal")
    func repeatedBindingIsTerminal() throws {
        let fixture = try AdapterFixture()
        let listener = SequenceControlListener(connections: [])
        let transport = DarwinVoicePerformanceTracerTransport(
            controlSocketPath: fixture.measurementPolicy.controlSocketPath,
            listener: listener,
            processSystem: SequenceProcessSystem(
                events: EventLog(),
                probes: []
            )
        )

        try transport.bindLaunchedDriver(.validDriver)
        #expect(throws: VoicePerformanceTracerTransportError.failed) {
            try transport.bindLaunchedDriver(.validDriver)
        }
        #expect(throws: VoicePerformanceTracerCollectorError.transportFailure) {
            try VoicePerformanceTracerCollector(transport: transport).collect(
                fixture.request,
                deadline: ContinuousClock().now.advanced(by: .seconds(1))
            )
        }
        #expect(listener.expectedPeers.isEmpty)
    }

    @Test("an accept failure closes the listener and leaves transport terminal")
    func acceptFailureIsTerminal() throws {
        let fixture = try AdapterFixture()
        let listener = SequenceControlListener(connections: [])
        let transport = DarwinVoicePerformanceTracerTransport(
            controlSocketPath: fixture.measurementPolicy.controlSocketPath,
            listener: listener,
            processSystem: SequenceProcessSystem(
                events: EventLog(),
                probes: []
            )
        )
        try transport.bindLaunchedDriver(.validDriver)

        #expect(throws: VoicePerformanceTracerCollectorError.transportFailure) {
            try VoicePerformanceTracerCollector(transport: transport).collect(
                fixture.request,
                deadline: ContinuousClock().now.advanced(by: .seconds(1))
            )
        }
        #expect(listener.didClose)
        #expect(throws: VoicePerformanceTracerTransportError.failed) {
            try transport.bindLaunchedDriver(.validDriver)
        }
    }

    @Test("invalid driver launch identities fail closed and terminal")
    func invalidBindingsAreTerminal() throws {
        let invalid = [
            VoicePerformanceTracerLaunchedDriverIdentity(
                role: .helper,
                pid: 4_201,
                processStartToken: 77_000,
                processGroupID: 4_201
            ),
            VoicePerformanceTracerLaunchedDriverIdentity(
                role: .driver,
                pid: 0,
                processStartToken: 77_000,
                processGroupID: 0
            ),
            VoicePerformanceTracerLaunchedDriverIdentity(
                role: .driver,
                pid: 4_201,
                processStartToken: 0,
                processGroupID: 4_201
            ),
            VoicePerformanceTracerLaunchedDriverIdentity(
                role: .driver,
                pid: 4_201,
                processStartToken: 77_000,
                processGroupID: 4_200
            ),
        ]
        for identity in invalid {
            let transport = DarwinVoicePerformanceTracerTransport(
                listener: SequenceControlListener(connections: []),
                processSystem: SequenceProcessSystem(
                    events: EventLog(),
                    probes: []
                )
            )
            #expect(throws: VoicePerformanceTracerTransportError.failed) {
                try transport.bindLaunchedDriver(identity)
            }
            #expect(throws: VoicePerformanceTracerTransportError.failed) {
                try transport.bindLaunchedDriver(.validDriver)
            }
        }
    }

    @Test("helper-before-driver and post-close accepts fail terminally")
    func wrongRoleAndClosedTransportAreTerminal() throws {
        let fixture = try AdapterFixture()
        do {
            let listener = SequenceControlListener(connections: [])
            let transport = DarwinVoicePerformanceTracerTransport(
                listener: listener,
                processSystem: SequenceProcessSystem(
                    events: EventLog(),
                    probes: []
                )
            )
            try transport.bindLaunchedDriver(.validDriver)
            #expect(throws: VoicePerformanceTracerTransportError.failed) {
                try transport.acceptAuthenticatedConnection(
                    helperRequest(fixture.measurementPolicy, trial: 1),
                    deadline: ContinuousClock().now.advanced(by: .seconds(1))
                )
            }
            #expect(throws: VoicePerformanceTracerTransportError.failed) {
                try transport.acceptAuthenticatedConnection(
                    driverRequest(fixture.measurementPolicy),
                    deadline: ContinuousClock().now.advanced(by: .seconds(1))
                )
            }
            #expect(listener.expectedPeers.isEmpty)
        }
        do {
            let transport = DarwinVoicePerformanceTracerTransport(
                listener: SequenceControlListener(connections: []),
                processSystem: SequenceProcessSystem(
                    events: EventLog(),
                    probes: []
                )
            )
            transport.close()
            #expect(throws: VoicePerformanceTracerTransportError.failed) {
                try transport.bindLaunchedDriver(.validDriver)
            }
            #expect(throws: VoicePerformanceTracerTransportError.failed) {
                try transport.acceptAuthenticatedConnection(
                    driverRequest(fixture.measurementPolicy),
                    deadline: ContinuousClock().now.advanced(by: .seconds(1))
                )
            }
        }
    }

    @Test("a same-signed driver outside the launched generation is rejected")
    func nonSpawnedDriverIsRejected() throws {
        let fixture = try AdapterFixture()
        for (pid, startToken) in [
            (Int32(4_202), UInt64(77_000)),
            (Int32(4_201), UInt64(77_001)),
        ] {
            let events = EventLog()
            let listener = SequenceControlListener(
                connections: [
                    FakeControlConnection(
                        events: events,
                        peer: attestedControlPeer(
                            pid: pid,
                            startToken: startToken,
                            instance: "x"
                        )
                    )
                ]
            )
            let transport = DarwinVoicePerformanceTracerTransport(
                controlSocketPath:
                    fixture.measurementPolicy.controlSocketPath,
                listener: listener,
                processSystem: SequenceProcessSystem(
                    events: events,
                    probes: []
                )
            )
            try transport.bindLaunchedDriver(.validDriver)

            #expect(
                throws:
                    VoicePerformanceTracerCollectorError
                    .authenticationFailed
            ) {
                try VoicePerformanceTracerCollector(
                    transport: transport
                ).collect(
                    fixture.request,
                    deadline:
                        ContinuousClock().now.advanced(by: .seconds(1))
                )
            }
            #expect(events.values == ["close"])
            #expect(listener.expectedPeers.count == 1)
        }
    }

    @Test("the attested driver must still lead its launched process group")
    func driverProcessGroupDriftIsRejected() throws {
        let fixture = try AdapterFixture()
        let events = EventLog()
        let listener = SequenceControlListener(
            connections: [FakeControlConnection(events: events)]
        )
        let system = SequenceProcessSystem(
            events: events,
            probes: [.usage(.active), .usage(.activeAdvanced)],
            processInfos: [
                .info(.driverWrongProcessGroup),
                .info(.driverWrongProcessGroup),
            ]
        )
        let transport = DarwinVoicePerformanceTracerTransport(
            controlSocketPath: fixture.measurementPolicy.controlSocketPath,
            listener: listener,
            processSystem: system
        )
        try transport.bindLaunchedDriver(.validDriver)

        #expect(throws: VoicePerformanceTracerCollectorError.authenticationFailed) {
            try VoicePerformanceTracerCollector(transport: transport).collect(
                fixture.request,
                deadline: ContinuousClock().now.advanced(by: .seconds(1))
            )
        }
        #expect(system.probedPIDs == [4_201, 4_201])
        #expect(system.processInfoPIDs == [4_201, 4_201])
        #expect(events.values.last == "close")
    }

    @Test("a same-signed helper outside the launched driver tree is rejected")
    func nonChildHelperIsRejected() throws {
        let fixture = try AdapterFixture()
        let events = EventLog()
        let driver = FakeControlConnection(events: events)
        let helper = FakeControlConnection(
            events: events,
            peer: attestedControlPeer(
                pid: 4_202,
                startToken: 78_000,
                instance: "b"
            )
        )
        let listener = SequenceControlListener(
            connections: [driver, helper]
        )
        let system = SequenceProcessSystem(
            events: events,
            probes: [
                .usage(.active),
                .usage(.activeAdvanced),
                .usage(.activeAdvanced),
                .usage(.helperActive),
                .usage(.helperActiveAdvanced),
                .usage(.driverAfterHelper),
            ],
            processInfos: [
                .info(.driver),
                .info(.driver),
                .info(.driver),
                .info(.helperWrongParent),
                .info(.helperWrongParent),
                .info(.driver),
            ]
        )
        let transport = DarwinVoicePerformanceTracerTransport(
            controlSocketPath: fixture.measurementPolicy.controlSocketPath,
            listener: listener,
            processSystem: system
        )
        try transport.bindLaunchedDriver(.validDriver)

        #expect(throws: VoicePerformanceTracerCollectorError.authenticationFailed) {
            try VoicePerformanceTracerCollector(transport: transport).collect(
                fixture.request,
                deadline: ContinuousClock().now.advanced(by: .seconds(1))
            )
        }
        #expect(
            system.probedPIDs
                == [4_201, 4_201, 4_201, 4_202, 4_202, 4_201]
        )
        #expect(driver.didClose)
        #expect(helper.didClose)
    }

    @Test("helper generation relationship drift is generically rejected")
    func helperRelationshipDriftIsRejected() throws {
        let helperInfoPairs: [(
            DarwinVoicePerformanceTracerBSDInfo,
            DarwinVoicePerformanceTracerBSDInfo
        )] = [
            (.helperWrongPID, .helperWrongPID),
            (.helperWrongParent, .helperWrongParent),
            (.helperWrongProcessGroup, .helperWrongProcessGroup),
            (.helper, .helperWrongParent),
        ]
        for pair in helperInfoPairs {
            try expectHelperAuthenticationFailure(
                helperUsages: [.helperActive, .helperActiveAdvanced],
                helperInfos: [pair.0, pair.1]
            )
        }
        try expectHelperAuthenticationFailure(
            helperUsages: [.helperReusedPID, .helperReusedPIDAdvanced],
            helperInfos: [.helper, .helper]
        )
        try expectHelperAuthenticationFailure(
            helperUsages: [.helperActiveAdvanced, .helperRolledBack],
            helperInfos: [.helper, .helper]
        )
        try expectHelperAuthenticationFailure(
            helperUsages: [.helperExited, .helperExited],
            helperInfos: [.helper, .helper]
        )
    }

    @Test("driver exit reuse and counter rollback while accepting a helper are rejected")
    func driverGenerationDriftDuringHelperAcceptIsRejected() throws {
        let driverPairs: [(
            DarwinVoicePerformanceTracerRUsageV6,
            DarwinVoicePerformanceTracerRUsageV6
        )] = [
            (.exited, .exited),
            (.reusedPID, .reusedPIDAdvanced),
            (.active, .driverAfterHelper),
        ]
        for pair in driverPairs {
            try expectHelperAuthenticationFailure(
                driverUsages: [pair.0, pair.1],
                helperUsages: [.helperActive, .helperActiveAdvanced],
                helperInfos: [.helper, .helper]
            )
        }
    }

    @Test("one driver can authenticate one or two ordered child generations")
    func launchedTreeHappyPathSupportsOneAndTwoTrials() throws {
        let fixture = try AdapterFixture()
        for helperCount in [1, 2] {
            let events = EventLog()
            var connections: [
                any DarwinVoicePerformanceTracerControlConnection
            ] = [FakeControlConnection(events: events)]
            var usages: [DarwinVoicePerformanceTracerProcessProbe] = [
                .usage(testUsage(start: 77_000, counter: 10)),
                .usage(testUsage(start: 77_000, counter: 11)),
            ]
            var infos: [DarwinVoicePerformanceTracerBSDProbe] = [
                .info(.driver),
                .info(.driver),
            ]
            for index in 0..<helperCount {
                let pid = Int32(4_202 + index)
                let start = UInt64(78_000 + index)
                connections.append(
                    FakeControlConnection(
                        events: events,
                        peer: attestedControlPeer(
                            pid: pid,
                            startToken: start,
                            instance: index == 0 ? "b" : "c"
                        )
                    )
                )
                let driverCounter = UInt64(12 + index * 2)
                usages.append(contentsOf: [
                    .usage(testUsage(
                        start: 77_000,
                        counter: driverCounter
                    )),
                    .usage(testUsage(start: start, counter: 5)),
                    .usage(testUsage(start: start, counter: 6)),
                    .usage(testUsage(
                        start: 77_000,
                        counter: driverCounter + 1
                    )),
                ])
                let helperInfo = DarwinVoicePerformanceTracerBSDInfo(
                    processIdentifier: pid,
                    parentProcessIdentifier: 4_201,
                    processGroupIdentifier: 4_201
                )
                infos.append(contentsOf: [
                    .info(.driver),
                    .info(helperInfo),
                    .info(helperInfo),
                    .info(.driver),
                ])
            }
            let listener = SequenceControlListener(
                connections: connections
            )
            let system = SequenceProcessSystem(
                events: events,
                probes: usages,
                processInfos: infos
            )
            let transport = DarwinVoicePerformanceTracerTransport(
                controlSocketPath:
                    fixture.measurementPolicy.controlSocketPath,
                listener: listener,
                processSystem: system
            )
            try transport.bindLaunchedDriver(.validDriver)
            let deadline = system.now.advanced(by: .seconds(1))

            let driver = try transport.acceptAuthenticatedConnection(
                driverRequest(fixture.measurementPolicy),
                deadline: deadline
            )
            #expect(driver.attestedPeer.pid == 4_201)
            for trial in 1...helperCount {
                let helper = try transport.acceptAuthenticatedConnection(
                    helperRequest(
                        fixture.measurementPolicy,
                        trial: UInt64(trial)
                    ),
                    deadline: deadline
                )
                #expect(helper.attestedPeer.pid == Int32(4_201 + trial))
                helper.close()
            }
            driver.close()
            #expect(listener.expectedPeers.count == helperCount + 1)
        }
    }

    private func expectHelperAuthenticationFailure(
        driverUsages: [DarwinVoicePerformanceTracerRUsageV6] = [
            .activeAdvanced,
            .driverAfterHelper,
        ],
        helperUsages: [DarwinVoicePerformanceTracerRUsageV6],
        helperInfos: [DarwinVoicePerformanceTracerBSDInfo]
    ) throws {
        let fixture = try AdapterFixture()
        let events = EventLog()
        let driver = FakeControlConnection(events: events)
        let helper = FakeControlConnection(
            events: events,
            peer: attestedControlPeer(
                pid: 4_202,
                startToken: 78_000,
                instance: "b"
            )
        )
        let system = SequenceProcessSystem(
            events: events,
            probes: [
                .usage(.active),
                .usage(.activeAdvanced),
                .usage(driverUsages[0]),
                .usage(helperUsages[0]),
                .usage(helperUsages[1]),
                .usage(driverUsages[1]),
            ],
            processInfos: [
                .info(.driver),
                .info(.driver),
                .info(.driver),
                .info(helperInfos[0]),
                .info(helperInfos[1]),
                .info(.driver),
            ]
        )
        let transport = DarwinVoicePerformanceTracerTransport(
            controlSocketPath: fixture.measurementPolicy.controlSocketPath,
            listener: SequenceControlListener(
                connections: [driver, helper]
            ),
            processSystem: system
        )
        try transport.bindLaunchedDriver(.validDriver)

        #expect(throws: VoicePerformanceTracerCollectorError.authenticationFailed) {
            try VoicePerformanceTracerCollector(transport: transport).collect(
                fixture.request,
                deadline: ContinuousClock().now.advanced(by: .seconds(1))
            )
        }
        #expect(driver.didClose)
        #expect(helper.didClose)
    }

    @Test("helper close is followed by evidence of the attested generation exiting")
    func activeHelperThenExitIsConfirmed() throws {
        let events = EventLog()
        let control = FakeControlConnection(events: events)
        let system = SequenceProcessSystem(
            events: events,
            probes: [
                .usage(.active),
                .usage(.exited),
            ]
        )
        let connection = try DarwinVoicePerformanceTracerConnection(
            controlConnection: control,
            role: .helper,
            processSystem: system
        )

        try connection.closeAndConfirmPeerExit(
            deadline: system.now.advanced(by: .seconds(1))
        )

        #expect(events.values == ["close", "probe", "wait", "probe"])
        #expect(system.probedPIDs == [4_201, 4_201])
    }

    @Test("a newer start token confirms that the attested PID generation is gone")
    func pidReuseConfirmsOriginalExit() throws {
        let events = EventLog()
        let control = FakeControlConnection(events: events)
        let system = SequenceProcessSystem(
            events: events,
            probes: [.usage(.reusedPID)]
        )
        let connection = try DarwinVoicePerformanceTracerConnection(
            controlConnection: control,
            role: .helper,
            processSystem: system
        )

        try connection.closeAndConfirmPeerExit(
            deadline: system.now.advanced(by: .seconds(1))
        )

        #expect(events.values == ["close", "probe"])
    }

    @Test("driver connections cannot be mistaken for helper exit evidence")
    func driverExitConfirmationFailsClosedWithoutProbing() throws {
        let events = EventLog()
        let control = FakeControlConnection(events: events)
        let system = SequenceProcessSystem(
            events: events,
            probes: [.noSuchProcess]
        )
        let connection = try DarwinVoicePerformanceTracerConnection(
            controlConnection: control,
            role: .driver,
            processSystem: system
        )

        #expect(throws: VoicePerformanceTracerTransportError.failed) {
            try connection.closeAndConfirmPeerExit(
                deadline: system.now.advanced(by: .seconds(1))
            )
        }
        #expect(events.values == ["close"])
        #expect(system.probedPIDs.isEmpty)
    }

    @Test("active helper polling consumes one absolute deadline")
    func activeHelperTimesOutWithoutResettingDeadline() throws {
        let events = EventLog()
        let control = FakeControlConnection(events: events)
        let system = SequenceProcessSystem(
            events: events,
            probes: [
                .usage(.active),
                .usage(.active),
                .usage(.active),
            ]
        )
        let connection = try DarwinVoicePerformanceTracerConnection(
            controlConnection: control,
            role: .helper,
            processSystem: system
        )

        #expect(throws: VoicePerformanceTracerTransportError.timedOut) {
            try connection.closeAndConfirmPeerExit(
                deadline: system.now.advanced(by: .milliseconds(25))
            )
        }

        #expect(
            system.waitDurations == [
                .milliseconds(10),
                .milliseconds(10),
                .milliseconds(5),
            ]
        )
    }

    @Test("same-generation rusage counters cannot roll back")
    func counterRollbackFailsClosed() throws {
        let events = EventLog()
        let control = FakeControlConnection(events: events)
        let system = SequenceProcessSystem(
            events: events,
            probes: [
                .usage(.active),
                .usage(.rolledBack),
                .noSuchProcess,
            ]
        )
        let connection = try DarwinVoicePerformanceTracerConnection(
            controlConnection: control,
            role: .helper,
            processSystem: system
        )

        #expect(throws: VoicePerformanceTracerTransportError.failed) {
            try connection.closeAndConfirmPeerExit(
                deadline: system.now.advanced(by: .seconds(1))
            )
        }
        #expect(system.probedPIDs.count == 2)
    }

    @Test("invalid start or exit tokens fail closed")
    func startAndExitTokenAnomaliesFailClosed() throws {
        for usage in [
            DarwinVoicePerformanceTracerRUsageV6.zeroStart,
            .rolledBackStart,
            .exitBeforeStart,
        ] {
            let events = EventLog()
            let system = SequenceProcessSystem(
                events: events,
                probes: [.usage(usage)]
            )
            let connection = try DarwinVoicePerformanceTracerConnection(
                controlConnection: FakeControlConnection(events: events),
                role: .helper,
                processSystem: system
            )

            #expect(throws: VoicePerformanceTracerTransportError.failed) {
                try connection.closeAndConfirmPeerExit(
                    deadline: system.now.advanced(by: .seconds(1))
                )
            }
        }
    }

    @Test("ESRCH confirms exit while every other process error fails closed")
    func processProbeErrorsAreClassifiedSafely() throws {
        do {
            let events = EventLog()
            let system = SequenceProcessSystem(
                events: events,
                probes: [.noSuchProcess]
            )
            let connection = try DarwinVoicePerformanceTracerConnection(
                controlConnection: FakeControlConnection(events: events),
                role: .helper,
                processSystem: system
            )
            try connection.closeAndConfirmPeerExit(
                deadline: system.now.advanced(by: .seconds(1))
            )
        }

        do {
            let events = EventLog()
            let system = SequenceProcessSystem(
                events: events,
                probes: [],
                probeError: TestProcessError.permissionDenied
            )
            let connection = try DarwinVoicePerformanceTracerConnection(
                controlConnection: FakeControlConnection(events: events),
                role: .helper,
                processSystem: system
            )
            #expect(throws: VoicePerformanceTracerTransportError.failed) {
                try connection.closeAndConfirmPeerExit(
                    deadline: system.now.advanced(by: .seconds(1))
                )
            }
        }
    }

    @Test("process evidence observed after the absolute deadline is rejected")
    func slowProbeCannotOutliveDeadline() throws {
        let events = EventLog()
        let system = SequenceProcessSystem(
            events: events,
            probes: [.noSuchProcess],
            probeAdvance: .milliseconds(20)
        )
        let connection = try DarwinVoicePerformanceTracerConnection(
            controlConnection: FakeControlConnection(events: events),
            role: .helper,
            processSystem: system
        )

        #expect(throws: VoicePerformanceTracerTransportError.timedOut) {
            try connection.closeAndConfirmPeerExit(
                deadline: system.now.advanced(by: .milliseconds(10))
            )
        }
    }

    @Test("control errors are normalized without leaking Darwin details")
    func transportErrorsAreNormalizedSafely() {
        let cases: [(
            PerformanceControlTransportError,
            VoicePerformanceTracerTransportError
        )] = [
            (.operationTimedOut, .timedOut),
            (.peerDisconnected, .disconnected),
            (.authenticationFailed, .authenticationFailed),
            (.ioFailure, .failed),
            (.insecureSocket, .failed),
        ]
        for (input, expected) in cases {
            #expect(
                normalizedTracerTransportError(input)
                    == expected
            )
        }
        #expect(
            normalizedTracerTransportError(TestProcessError.permissionDenied)
                == .failed
        )
    }

    @Test("collector driver and helper requests map to exact Darwin identities")
    func adapterMapsAuthenticationAndRoles() throws {
        let fixture = try AdapterFixture()
        let driver = FakeControlConnection(
            events: EventLog(),
            peer: attestedControlPeer(
                pid: 4_201,
                startToken: 77_000,
                instance: "a"
            )
        )
        let helper = FakeControlConnection(
            events: EventLog(),
            peer: attestedControlPeer(
                pid: 4_202,
                startToken: 78_000,
                instance: "b"
            )
        )
        let listener = SequenceControlListener(
            connections: [driver, helper]
        )
        let transport = DarwinVoicePerformanceTracerTransport(
            controlSocketPath: fixture.measurementPolicy.controlSocketPath,
            listener: listener,
            processSystem: SequenceProcessSystem(
                events: EventLog(),
                probes: [
                    .usage(.active),
                    .usage(.activeAdvanced),
                    .usage(.activeAdvanced),
                    .usage(.helperActive),
                    .usage(.helperActiveAdvanced),
                    .usage(.driverAfterHelper),
                    .noSuchProcess,
                ],
                processInfos: [
                    .info(.driver),
                    .info(.driver),
                    .info(.driver),
                    .info(.helper),
                    .info(.helper),
                    .info(.driver),
                ]
            )
        )
        try transport.bindLaunchedDriver(.validDriver)
        #expect(
            transport.controlSocketPath
                == fixture.measurementPolicy.controlSocketPath
        )
        let collector = VoicePerformanceTracerCollector(
            transport: transport
        )

        #expect(throws: VoicePerformanceTracerCollectorError.transportFailure) {
            try collector.collect(
                fixture.request,
                deadline: ContinuousClock().now.advanced(by: .seconds(10))
            )
        }

        let expectedDriver = try expectedIdentity(
            path: fixture.measurementPolicy.driver.expectedExecutablePath,
            sha256: fixture.measurementPolicy.driver
                .expectedExecutableSHA256,
            signingID: fixture.measurementPolicy.driver
                .expectedSigningIdentifier,
            teamID: fixture.measurementPolicy.driver.expectedTeamIdentifier,
            cdHash: fixture.measurementPolicy.driver.expectedCDHash
        )
        let expectedHelper = try expectedIdentity(
            path: fixture.measurementPolicy.helper.expectedExecutablePath,
            sha256: fixture.measurementPolicy.helper
                .expectedExecutableSHA256,
            signingID: fixture.measurementPolicy.helper
                .expectedSigningIdentifier,
            teamID: fixture.measurementPolicy.helper.expectedTeamIdentifier,
            cdHash: fixture.measurementPolicy.helper.expectedCDHash
        )
        #expect(listener.expectedPeers.count == 2)
        #expect(listener.expectedPeers[0] == expectedDriver)
        #expect(listener.expectedPeers[1] == expectedHelper)
        #expect(driver.sentFrames.first?.challengeRole == .driver)
        #expect(helper.sentFrames.first?.challengeRole == .helper)
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class FakeControlConnection:
    DarwinVoicePerformanceTracerControlConnection,
    @unchecked Sendable
{
    let attestedPeer: PerformanceControlAttestedPeer
    private let events: EventLog
    private let lock = NSLock()
    private(set) var sentFrames: [PerformanceControlWireFrame] = []
    private(set) var didClose = false

    init(
        events: EventLog,
        peer: PerformanceControlAttestedPeer = attestedControlPeer()
    ) {
        self.events = events
        attestedPeer = peer
    }

    func send(
        _ frame: PerformanceControlWireFrame,
        deadline: ContinuousClock.Instant
    ) throws {
        lock.lock()
        sentFrames.append(frame)
        lock.unlock()
    }

    func receive(
        deadline: ContinuousClock.Instant
    ) throws -> PerformanceControlWireFrame {
        throw VoicePerformanceTracerTransportError.failed
    }

    func close() {
        lock.lock()
        didClose = true
        lock.unlock()
        events.append("close")
    }
}

private final class SequenceControlListener:
    DarwinVoicePerformanceTracerControlListening,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var connections: [any DarwinVoicePerformanceTracerControlConnection]
    private(set) var expectedPeers: [PerformanceControlExpectedPeerIdentity] = []
    private(set) var didClose = false

    init(
        connections: [any DarwinVoicePerformanceTracerControlConnection]
    ) {
        self.connections = connections
    }

    func acceptControlConnection(
        expectedPeer: PerformanceControlExpectedPeerIdentity,
        deadline: ContinuousClock.Instant
    ) throws -> any DarwinVoicePerformanceTracerControlConnection {
        lock.lock()
        defer { lock.unlock() }
        expectedPeers.append(expectedPeer)
        guard !connections.isEmpty else {
            throw PerformanceControlTransportError.ioFailure
        }
        return connections.removeFirst()
    }

    func close() {
        lock.lock()
        didClose = true
        lock.unlock()
    }
}

private final class SequenceProcessSystem:
    DarwinVoicePerformanceTracerProcessSystem,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let events: EventLog
    private var probes: [DarwinVoicePerformanceTracerProcessProbe]
    private var processInfos: [DarwinVoicePerformanceTracerBSDProbe]
    private let probeError: (any Error)?
    private let probeAdvance: Duration
    private var instant: ContinuousClock.Instant
    private(set) var probedPIDs: [Int32] = []
    private(set) var processInfoPIDs: [Int32] = []
    private(set) var waitDurations: [Duration] = []

    init(
        events: EventLog,
        probes: [DarwinVoicePerformanceTracerProcessProbe],
        processInfos: [DarwinVoicePerformanceTracerBSDProbe] = [],
        probeError: (any Error)? = nil,
        probeAdvance: Duration = .zero
    ) {
        self.events = events
        self.probes = probes
        self.processInfos = processInfos
        self.probeError = probeError
        self.probeAdvance = probeAdvance
        instant = ContinuousClock().now
    }

    var now: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func probe(processIdentifier: Int32) throws
        -> DarwinVoicePerformanceTracerProcessProbe
    {
        lock.lock()
        defer { lock.unlock() }
        events.append("probe")
        probedPIDs.append(processIdentifier)
        instant = instant.advanced(by: probeAdvance)
        if let probeError { throw probeError }
        guard !probes.isEmpty else {
            throw TestProcessError.permissionDenied
        }
        return probes.removeFirst()
    }

    func wait(for duration: Duration) throws {
        lock.lock()
        events.append("wait")
        waitDurations.append(duration)
        instant = instant.advanced(by: duration)
        lock.unlock()
    }

    func probeBSDInfo(processIdentifier: Int32) throws
        -> DarwinVoicePerformanceTracerBSDProbe
    {
        lock.lock()
        defer { lock.unlock() }
        events.append("processInfo")
        processInfoPIDs.append(processIdentifier)
        guard !processInfos.isEmpty else {
            throw TestProcessError.permissionDenied
        }
        return processInfos.removeFirst()
    }
}

private extension DarwinVoicePerformanceTracerRUsageV6 {
    static let active = Self(
        processStartToken: 77_000,
        processExitToken: 0,
        userCPUNanoseconds: 10,
        systemCPUNanoseconds: 20,
        energyNanojoules: 30
    )

    static let activeAdvanced = Self(
        processStartToken: 77_000,
        processExitToken: 0,
        userCPUNanoseconds: 11,
        systemCPUNanoseconds: 21,
        energyNanojoules: 31
    )

    static let helperActive = Self(
        processStartToken: 78_000,
        processExitToken: 0,
        userCPUNanoseconds: 5,
        systemCPUNanoseconds: 6,
        energyNanojoules: 7
    )

    static let helperActiveAdvanced = Self(
        processStartToken: 78_000,
        processExitToken: 0,
        userCPUNanoseconds: 6,
        systemCPUNanoseconds: 7,
        energyNanojoules: 8
    )

    static let helperReusedPID = Self(
        processStartToken: 88_000,
        processExitToken: 0,
        userCPUNanoseconds: 5,
        systemCPUNanoseconds: 6,
        energyNanojoules: 7
    )

    static let helperReusedPIDAdvanced = Self(
        processStartToken: 88_000,
        processExitToken: 0,
        userCPUNanoseconds: 6,
        systemCPUNanoseconds: 7,
        energyNanojoules: 8
    )

    static let helperRolledBack = Self(
        processStartToken: 78_000,
        processExitToken: 0,
        userCPUNanoseconds: 5,
        systemCPUNanoseconds: 6,
        energyNanojoules: 7
    )

    static let helperExited = Self(
        processStartToken: 78_000,
        processExitToken: 78_100,
        userCPUNanoseconds: 6,
        systemCPUNanoseconds: 7,
        energyNanojoules: 8
    )

    static let driverAfterHelper = Self(
        processStartToken: 77_000,
        processExitToken: 0,
        userCPUNanoseconds: 12,
        systemCPUNanoseconds: 22,
        energyNanojoules: 32
    )

    static let reusedPIDAdvanced = Self(
        processStartToken: 88_000,
        processExitToken: 0,
        userCPUNanoseconds: 2,
        systemCPUNanoseconds: 2,
        energyNanojoules: 2
    )

    static let exited = Self(
        processStartToken: 77_000,
        processExitToken: 78_000,
        userCPUNanoseconds: 11,
        systemCPUNanoseconds: 21,
        energyNanojoules: 31
    )

    static let reusedPID = Self(
        processStartToken: 88_000,
        processExitToken: 0,
        userCPUNanoseconds: 1,
        systemCPUNanoseconds: 1,
        energyNanojoules: 1
    )

    static let rolledBack = Self(
        processStartToken: 77_000,
        processExitToken: 0,
        userCPUNanoseconds: 9,
        systemCPUNanoseconds: 20,
        energyNanojoules: 30
    )

    static let zeroStart = Self(
        processStartToken: 0,
        processExitToken: 0,
        userCPUNanoseconds: 1,
        systemCPUNanoseconds: 1,
        energyNanojoules: 1
    )

    static let rolledBackStart = Self(
        processStartToken: 76_000,
        processExitToken: 0,
        userCPUNanoseconds: 1,
        systemCPUNanoseconds: 1,
        energyNanojoules: 1
    )

    static let exitBeforeStart = Self(
        processStartToken: 77_000,
        processExitToken: 76_999,
        userCPUNanoseconds: 1,
        systemCPUNanoseconds: 1,
        energyNanojoules: 1
    )
}

private extension DarwinVoicePerformanceTracerBSDInfo {
    static let driver = Self(
        processIdentifier: 4_201,
        parentProcessIdentifier: 1,
        processGroupIdentifier: 4_201
    )

    static let driverWrongProcessGroup = Self(
        processIdentifier: 4_201,
        parentProcessIdentifier: 1,
        processGroupIdentifier: 4_200
    )

    static let helperWrongParent = Self(
        processIdentifier: 4_202,
        parentProcessIdentifier: 4_200,
        processGroupIdentifier: 4_201
    )

    static let helper = Self(
        processIdentifier: 4_202,
        parentProcessIdentifier: 4_201,
        processGroupIdentifier: 4_201
    )

    static let helperWrongPID = Self(
        processIdentifier: 4_203,
        parentProcessIdentifier: 4_201,
        processGroupIdentifier: 4_201
    )

    static let helperWrongProcessGroup = Self(
        processIdentifier: 4_202,
        parentProcessIdentifier: 4_201,
        processGroupIdentifier: 4_202
    )
}

private enum TestProcessError: Error {
    case permissionDenied
}

private struct AdapterFixture {
    let measurementPolicy: VoicePerformanceMeasurementPolicy
    let request: VoicePerformanceTracerCollectionRequest

    init() throws {
        let protocolIdentity = try PerformanceControlProtocolIdentity(
            sha256: String(repeating: "a", count: 64)
        )
        let driverPolicy = try SealedPerformanceControlDriverPolicy
            .decodeCanonical(
                Data(
                    (#"{"capabilities":["authenticated_control","lazy_load_ticket"],"control_protocol":{"id":"rimeai-performance-control-v2","sha256":""#
                        + String(repeating: "a", count: 64)
                        + #""},"qualification":"tracer","schema_version":1}"#)
                        .utf8
                ),
                expectedControlProtocol: protocolIdentity
            )
        measurementPolicy = try VoicePerformanceMeasurementPolicy
            .decodeCanonical(
                measurementPolicyData(
                    driverPolicySHA256: driverPolicy.canonicalSHA256.rawValue
                )
            )
        request = try VoicePerformanceTracerCollectionRequest(
            measurementPolicy: measurementPolicy,
            driverPolicy: driverPolicy
        )
    }
}

private func measurementPolicyData(driverPolicySHA256: String) -> Data {
    Data(
        (#"{"cold_trials":1,"collector":{"expected_cdhash":""#
            + String(repeating: "d", count: 40)
            + #"","expected_executable_path":"/usr/local/libexec/rimeai-voice-performance-collector","expected_executable_sha256":""#
            + String(repeating: "c", count: 64)
            + #"","expected_signing_identifier":"fun.wwcn.rimeai.voice-performance-collector","expected_team_identifier":"TEAMID1234"},"control_protocol":{"id":"rimeai-performance-control-v2","sha256":""#
            + String(repeating: "a", count: 64)
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

private func attestedControlPeer(
    pid: Int32 = 4_201,
    startToken: UInt64 = 77_000,
    instance: Character = "a"
) -> PerformanceControlAttestedPeer {
    PerformanceControlAttestedPeer(
        pid: pid,
        euid: 501,
        startToken: startToken,
        pidVersion: 9,
        instanceID: String(repeating: instance, count: 64)
    )
}

private func expectedIdentity(
    path: String,
    sha256: String,
    signingID: String,
    teamID: String,
    cdHash: String
) throws -> PerformanceControlExpectedPeerIdentity {
    try PerformanceControlExpectedPeerIdentity(
        expectedExecutablePath: path,
        expectedExecutableSHA256: sha256,
        expectedSigningIdentifier: signingID,
        expectedTeamIdentifier: teamID,
        expectedCDHash: cdHash
    )
}

private func driverRequest(
    _ policy: VoicePerformanceMeasurementPolicy
) -> VoicePerformanceTracerPeerRequest {
    VoicePerformanceTracerPeerRequest(
        role: .driver,
        trial: nil,
        expectedExecutablePath: policy.driver.expectedExecutablePath,
        expectedExecutableSHA256: policy.driver.expectedExecutableSHA256,
        expectedSigningIdentifier: policy.driver.expectedSigningIdentifier,
        expectedTeamIdentifier: policy.driver.expectedTeamIdentifier,
        expectedCDHash: policy.driver.expectedCDHash
    )
}

private func helperRequest(
    _ policy: VoicePerformanceMeasurementPolicy,
    trial: UInt64
) -> VoicePerformanceTracerPeerRequest {
    VoicePerformanceTracerPeerRequest(
        role: .helper,
        trial: trial,
        expectedExecutablePath: policy.helper.expectedExecutablePath,
        expectedExecutableSHA256: policy.helper.expectedExecutableSHA256,
        expectedSigningIdentifier: policy.helper.expectedSigningIdentifier,
        expectedTeamIdentifier: policy.helper.expectedTeamIdentifier,
        expectedCDHash: policy.helper.expectedCDHash
    )
}

private func testUsage(
    start: UInt64,
    counter: UInt64
) -> DarwinVoicePerformanceTracerRUsageV6 {
    DarwinVoicePerformanceTracerRUsageV6(
        processStartToken: start,
        processExitToken: 0,
        userCPUNanoseconds: counter,
        systemCPUNanoseconds: counter,
        energyNanojoules: counter
    )
}

private extension PerformanceControlWireFrame {
    var challengeRole: PerformanceControlPeerRole? {
        guard case .challenge(let role, _, _, _) = self else { return nil }
        return role
    }
}

private extension VoicePerformanceTracerLaunchedDriverIdentity {
    static let validDriver = Self(
        role: .driver,
        pid: 4_201,
        processStartToken: 77_000,
        processGroupID: 4_201
    )
}
