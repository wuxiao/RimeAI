import Foundation
import Testing
@testable import RimeAIVoicePerformanceControlCore

@Suite("Authenticated performance-control tracer state machine")
struct PerformanceControlStateMachineTests {
    @Test("one cold generation follows the exact authenticated load chain")
    func oneColdGenerationCompletes() throws {
        let fixture = try Fixture()
        var machine = try fixture.machine()

        _ = try machine.receive(
            fixture.driverChallenge,
            on: .collectorToDriver
        )
        _ = try machine.receive(
            fixture.driverHello,
            on: .driverToCollector
        )
        _ = try machine.receive(
            fixture.helperChallenge,
            on: .collectorToHelper(fixture.generation)
        )
        var snapshot = try machine.receive(
            fixture.helperHello,
            on: .helperToCollector(fixture.generation)
        )
        #expect(snapshot.phase == .waitingUnloadedHelper)
        #expect(snapshot.qualification == .tracer)
        #expect(!snapshot.authenticatedProductionDriver)
        #expect(snapshot.helperGeneration == fixture.generation)

        snapshot = try machine.receive(
            .armColdLoad(
                sequence: 1,
                sessionID: fixture.sessionID,
                trial: 1
            ),
            on: .driverToCollector
        )
        #expect(snapshot.phase == .loadArmed)

        _ = try machine.receive(
            .loadEngine(
                sequence: 1,
                sessionID: fixture.sessionID,
                trial: 1,
                loadTicket: fixture.ticket
            ),
            on: .collectorToHelper(fixture.generation)
        )
        snapshot = try machine.receive(
            .loadStarted(
                sequence: 1,
                sessionID: fixture.sessionID,
                replyTo: 1,
                trial: 1,
                loadTicket: fixture.ticket
            ),
            on: .helperToCollector(fixture.generation)
        )
        #expect(snapshot.phase == .loadStartedAcknowledged)

        snapshot = try machine.receive(
            .loadStartedAck(
                sequence: 2,
                sessionID: fixture.sessionID,
                replyTo: 1,
                trial: 1,
                loadTicket: fixture.ticket
            ),
            on: .collectorToHelper(fixture.generation)
        )
        #expect(snapshot.phase == .loading)

        snapshot = try machine.receive(
            .loadReady(
                sequence: 2,
                sessionID: fixture.sessionID,
                replyTo: 2,
                trial: 1,
                loadTicket: fixture.ticket,
                engine: fixture.engine
            ),
            on: .helperToCollector(fixture.generation)
        )
        #expect(snapshot.phase == .helperReady)
        #expect(snapshot.completedColdTrials == 1)
        #expect(snapshot.lastCompletedTrial?.trial == 1)
        #expect(
            snapshot.lastCompletedTrial?.helperGeneration
                == fixture.generation
        )
        #expect(
            snapshot.lastCompletedTrial?.artifactGeneration
                == fixture.engine.artifactGeneration
        )
        #expect(machine.report.qualification == .tracer)
        #expect(!machine.report.authenticatedProductionDriver)
        #expect(machine.report.completedColdTrials == 1)
    }

    @Test("driver cannot register or speak for the helper")
    func actorAuthorityIsNotInterchangeable() throws {
        let fixture = try Fixture()
        var machine = try fixture.machine()

        _ = try machine.receive(fixture.driverChallenge, on: .collectorToDriver)
        _ = try machine.receive(fixture.driverHello, on: .driverToCollector)

        var registrationProbe = machine
        #expect(throws: PerformanceControlError.unauthorizedDirection) {
            try registrationProbe.receive(
                fixture.helperHello,
                on: .driverToCollector
            )
        }
        #expect(registrationProbe.snapshot.phase == .failed)
        #expect(throws: PerformanceControlError.invalidTransition) {
            try registrationProbe.receive(
                fixture.helperChallenge,
                on: .collectorToHelper(fixture.generation)
            )
        }

        _ = try machine.receive(
            fixture.helperChallenge,
            on: .collectorToHelper(fixture.generation)
        )
        _ = try machine.receive(
            fixture.helperHello,
            on: .helperToCollector(fixture.generation)
        )

        var helperArmProbe = machine
        #expect(throws: PerformanceControlError.unauthorizedDirection) {
            try helperArmProbe.receive(
                .armColdLoad(
                    sequence: 1,
                    sessionID: fixture.sessionID,
                    trial: 1
                ),
                on: .helperToCollector(fixture.generation)
            )
        }
        #expect(helperArmProbe.snapshot.phase == .failed)

        var driverReadyProbe = machine
        #expect(throws: PerformanceControlError.unauthorizedDirection) {
            try driverReadyProbe.receive(
                .loadReady(
                    sequence: 1,
                    sessionID: fixture.sessionID,
                    replyTo: 1,
                    trial: 1,
                    loadTicket: fixture.ticket,
                    engine: fixture.engine
                ),
                on: .driverToCollector
            )
        }
        #expect(driverReadyProbe.snapshot.phase == .failed)
        #expect(machine.snapshot.phase == .waitingUnloadedHelper)
    }

    @Test("sequence or binding violations fail closed on their connection")
    func sequencesArePerDirectionAndFailClosed() throws {
        let fixture = try Fixture()
        var machine = try fixture.machine()
        try fixture.authenticate(&machine)

        var gapProbe = machine
        #expect(throws: PerformanceControlError.sequenceViolation) {
            try gapProbe.receive(
                .armColdLoad(
                    sequence: 2,
                    sessionID: fixture.sessionID,
                    trial: 1
                ),
                on: .driverToCollector
            )
        }
        #expect(gapProbe.snapshot.phase == .failed)

        var wrongSessionProbe = machine
        #expect(throws: PerformanceControlError.bindingMismatch) {
            try wrongSessionProbe.receive(
                .armColdLoad(
                    sequence: 1,
                    sessionID: try PerformanceControlNonce(
                        String(repeating: "c", count: 64)
                    ),
                    trial: 1
                ),
                on: .driverToCollector
            )
        }
        #expect(wrongSessionProbe.snapshot.phase == .failed)

        var zeroTrialProbe = machine
        #expect(throws: PerformanceControlError.invalidTransition) {
            try zeroTrialProbe.receive(
                .armColdLoad(
                    sequence: 1,
                    sessionID: fixture.sessionID,
                    trial: 0
                ),
                on: .driverToCollector
            )
        }
        #expect(zeroTrialProbe.snapshot.phase == .failed)

        _ = try machine.receive(
            .armColdLoad(
                sequence: 1,
                sessionID: fixture.sessionID,
                trial: 1
            ),
            on: .driverToCollector
        )

        var replayProbe = machine
        #expect(throws: PerformanceControlError.sequenceViolation) {
            try replayProbe.receive(
                .armColdLoad(
                    sequence: 1,
                    sessionID: fixture.sessionID,
                    trial: 2
                ),
                on: .driverToCollector
            )
        }
        #expect(replayProbe.snapshot.phase == .failed)

        var helperGapProbe = machine
        #expect(throws: PerformanceControlError.sequenceViolation) {
            try helperGapProbe.receive(
                .loadEngine(
                    sequence: 2,
                    sessionID: fixture.sessionID,
                    trial: 1,
                    loadTicket: fixture.ticket
                ),
                on: .collectorToHelper(fixture.generation)
            )
        }
        #expect(helperGapProbe.snapshot.phase == .failed)

        _ = try machine.receive(
            .loadEngine(
                sequence: 1,
                sessionID: fixture.sessionID,
                trial: 1,
                loadTicket: fixture.ticket
            ),
            on: .collectorToHelper(fixture.generation)
        )
        #expect(machine.snapshot.phase == .loadArmed)
    }

    @Test("load-ready must match the plan-bound engine identity")
    func loadReadyMatchesExpectedEngine() throws {
        let fixture = try Fixture()
        var machine = try fixture.machine()
        try fixture.advanceToLoading(&machine)

        let unexpectedEngines = try [
            fixture.engine(
                artifactID: "other-model",
                artifactSHA256Digit: "d",
                maximumHotwords: 32
            ),
            fixture.engine(
                artifactID: "voice-model-v1",
                artifactSHA256Digit: "e",
                maximumHotwords: 32
            ),
            fixture.engine(
                artifactID: "voice-model-v1",
                artifactSHA256Digit: "d",
                maximumHotwords: 31
            ),
        ]
        for engine in unexpectedEngines {
            var mismatchProbe = machine
            #expect(throws: PerformanceControlError.bindingMismatch) {
                try mismatchProbe.receive(
                    .loadReady(
                        sequence: 2,
                        sessionID: fixture.sessionID,
                        replyTo: 2,
                        trial: 1,
                        loadTicket: fixture.ticket,
                        engine: engine
                    ),
                    on: .helperToCollector(fixture.generation)
                )
            }
            #expect(mismatchProbe.snapshot.phase == .failed)
        }
        #expect(machine.snapshot.phase == .loading)
        _ = try machine.receive(
            .loadReady(
                sequence: 2,
                sessionID: fixture.sessionID,
                replyTo: 2,
                trial: 1,
                loadTicket: fixture.ticket,
                engine: fixture.engine
            ),
            on: .helperToCollector(fixture.generation)
        )
        #expect(machine.snapshot.phase == .helperReady)
    }

    @Test("every cold trial consumes a new helper and artifact generation once")
    func coldTrialsRotateGenerationsExactlyOnce() throws {
        let fixture = try Fixture()
        var machine = try fixture.machine()
        try fixture.advanceToLoading(&machine)
        _ = try machine.receive(
            .loadReady(
                sequence: 2,
                sessionID: fixture.sessionID,
                replyTo: 2,
                trial: 1,
                loadTicket: fixture.ticket,
                engine: fixture.engine
            ),
            on: .helperToCollector(fixture.generation)
        )

        let binding = try PerformanceControlSessionBinding.derive(
            controlSessionNonce: fixture.controlSessionNonce,
            trial: 2
        )
        let sessionID = binding.sessionID
        let planNonce = binding.planNonce
        let driverCollectorNonce = try token("e")
        let driverPeerNonce = try token("f")
        let helperCollectorNonce = try token("0")
        let helperPeerNonce = try token("ab")
        let ticket = try token("cd")
        let generation = try HelperGenerationIdentity(
            pid: 102,
            processStartToken: 2_002,
            instanceID: ControlledPerformanceID(token("ef").rawValue)
        )

        let helperChallenge = PerformanceControlWireFrame.challenge(
            peerRole: .helper,
            sessionID: sessionID,
            planNonce: planNonce,
            collectorNonce: helperCollectorNonce
        )

        var generationReplayProbe = machine
        #expect(throws: PerformanceControlError.generationReuse) {
            try generationReplayProbe.receive(
                helperChallenge,
                on: .collectorToHelper(fixture.generation)
            )
        }
        #expect(generationReplayProbe.snapshot.phase == .failed)

        let sameProcessDifferentInstance = try HelperGenerationIdentity(
            pid: fixture.generation.pid,
            processStartToken: fixture.generation.processStartToken,
            instanceID: ControlledPerformanceID(token("ac").rawValue)
        )
        var processReplayProbe = machine
        #expect(throws: PerformanceControlError.generationReuse) {
            try processReplayProbe.receive(
                helperChallenge,
                on: .collectorToHelper(sameProcessDifferentInstance)
            )
        }
        #expect(processReplayProbe.snapshot.phase == .failed)

        let sameInstanceDifferentProcess = try HelperGenerationIdentity(
            pid: 103,
            processStartToken: 3_003,
            instanceID: fixture.generation.instanceID
        )
        var instanceReplayProbe = machine
        #expect(throws: PerformanceControlError.generationReuse) {
            try instanceReplayProbe.receive(
                helperChallenge,
                on: .collectorToHelper(sameInstanceDifferentProcess)
            )
        }
        #expect(instanceReplayProbe.snapshot.phase == .failed)

        _ = try machine.receive(
            helperChallenge,
            on: .collectorToHelper(generation)
        )
        _ = try machine.receive(
            .helperHello(
                sessionID: sessionID,
                planNonce: planNonce,
                collectorNonce: helperCollectorNonce,
                peerNonce: helperPeerNonce,
                measurementPolicySHA256: fixture.measurementPolicySHA256,
                releasePolicySHA256: fixture.releasePolicySHA256
            ),
            on: .helperToCollector(generation)
        )
        _ = try machine.receive(
            .challenge(
                peerRole: .driver,
                sessionID: sessionID,
                planNonce: planNonce,
                collectorNonce: driverCollectorNonce
            ),
            on: .collectorToDriver
        )
        _ = try machine.receive(
            .driverHello(
                sessionID: sessionID,
                planNonce: planNonce,
                collectorNonce: driverCollectorNonce,
                    peerNonce: driverPeerNonce,
                    collectionProtocol: fixture.driverPolicy.controlProtocol,
                    driverPolicySHA256: fixture.driverPolicy.canonicalSHA256,
                    measurementPolicySHA256:
                        fixture.measurementPolicySHA256
            ),
            on: .driverToCollector
        )

        var trialReplayProbe = machine
        #expect(throws: PerformanceControlError.trialReplay) {
            try trialReplayProbe.receive(
                .armColdLoad(
                    sequence: 1,
                    sessionID: sessionID,
                    trial: 1
                ),
                on: .driverToCollector
            )
        }
        #expect(trialReplayProbe.snapshot.phase == .failed)

        _ = try machine.receive(
            .armColdLoad(sequence: 1, sessionID: sessionID, trial: 2),
            on: .driverToCollector
        )

        var ticketReplayProbe = machine
        #expect(throws: PerformanceControlError.ticketReplay) {
            try ticketReplayProbe.receive(
                .loadEngine(
                    sequence: 1,
                    sessionID: sessionID,
                    trial: 2,
                    loadTicket: fixture.ticket
                ),
                on: .collectorToHelper(generation)
            )
        }
        #expect(ticketReplayProbe.snapshot.phase == .failed)

        _ = try machine.receive(
            .loadEngine(
                sequence: 1,
                sessionID: sessionID,
                trial: 2,
                loadTicket: ticket
            ),
            on: .collectorToHelper(generation)
        )
        _ = try machine.receive(
            .loadStarted(
                sequence: 1,
                sessionID: sessionID,
                replyTo: 1,
                trial: 2,
                loadTicket: ticket
            ),
            on: .helperToCollector(generation)
        )
        _ = try machine.receive(
            .loadStartedAck(
                sequence: 2,
                sessionID: sessionID,
                replyTo: 1,
                trial: 2,
                loadTicket: ticket
            ),
            on: .collectorToHelper(generation)
        )

        var artifactReplayProbe = machine
        #expect(throws: PerformanceControlError.artifactGenerationReuse) {
            try artifactReplayProbe.receive(
                .loadReady(
                    sequence: 2,
                    sessionID: sessionID,
                    replyTo: 2,
                    trial: 2,
                    loadTicket: ticket,
                    engine: fixture.engine
                ),
                on: .helperToCollector(generation)
            )
        }
        #expect(artifactReplayProbe.snapshot.phase == .failed)

        let secondEngine = try fixture.engine(
            artifactID: "voice-model-v1",
            artifactSHA256Digit: "d",
            maximumHotwords: 32
        )
        _ = try machine.receive(
            .loadReady(
                sequence: 2,
                sessionID: sessionID,
                replyTo: 2,
                trial: 2,
                loadTicket: ticket,
                engine: secondEngine
            ),
            on: .helperToCollector(generation)
        )
        #expect(machine.snapshot.completedColdTrials == 2)
        #expect(machine.snapshot.lastCompletedTrial?.trial == 2)
        #expect(machine.snapshot.lastCompletedTrial?.helperGeneration == generation)
        #expect(
            machine.snapshot.lastCompletedTrial?.artifactGeneration
                == secondEngine.artifactGeneration
        )
    }

    @Test("sessions and trials are policy-derived, bounded, and sequential")
    func sessionsAndTrialsAreBoundToTheSealedControlNonce() throws {
        let fixture = try Fixture()

        var wrongBinding = try fixture.machine()
        #expect(throws: PerformanceControlError.bindingMismatch) {
            try wrongBinding.receive(
                .challenge(
                    peerRole: .driver,
                    sessionID: try token("c"),
                    planNonce: try token("d"),
                    collectorNonce: fixture.driverCollectorNonce
                ),
                on: .collectorToDriver
            )
        }
        #expect(wrongBinding.snapshot.phase == .failed)

        for trial in [UInt64(2), UInt64(33), UInt64.max] {
            var nonSequential = try fixture.machine()
            try fixture.authenticate(&nonSequential)
            #expect(throws: PerformanceControlError.invalidTransition) {
                try nonSequential.receive(
                    .armColdLoad(
                        sequence: 1,
                        sessionID: fixture.sessionID,
                        trial: trial
                    ),
                    on: .driverToCollector
                )
            }
            #expect(nonSequential.snapshot.phase == .failed)
        }
    }

    @Test("a fresh helper may establish the initial session before the driver")
    func initialHelperFirstHandshakeSucceeds() throws {
        let fixture = try Fixture()
        var machine = try fixture.machine()

        _ = try machine.receive(
            fixture.helperChallenge,
            on: .collectorToHelper(fixture.generation)
        )
        var snapshot = try machine.receive(
            fixture.helperHello,
            on: .helperToCollector(fixture.generation)
        )
        #expect(snapshot.phase == .handshaking)
        #expect(snapshot.helperGeneration == fixture.generation)

        _ = try machine.receive(fixture.driverChallenge, on: .collectorToDriver)
        snapshot = try machine.receive(
            fixture.driverHello,
            on: .driverToCollector
        )
        #expect(snapshot.phase == .waitingUnloadedHelper)
        #expect(snapshot.helperGeneration == fixture.generation)
    }

    @Test("production-shaped policy cannot enter the first tracer machine")
    func productionPolicyIsRejectedByTracerMachine() throws {
        let fixture = try Fixture()
        let policy = try SealedPerformanceControlDriverPolicy.decodeCanonical(
            Data(
                (#"{"capabilities":["authenticated_control","corpus_sessions","helper_generation_rotation","keyboard_phases","late_challenges","lazy_load_ticket"],"control_protocol":{"id":"rimeai-performance-control-v2","sha256":""#
                    + String(repeating: "a", count: 64)
                    + #""},"qualification":"production","schema_version":1}"#)
                    .utf8
            ),
            expectedControlProtocol: fixture.driverPolicy.controlProtocol
        )

        #expect(throws: PerformanceControlError.unsupportedQualification) {
            try PerformanceControlStateMachine(
                driverPolicy: policy,
                measurementPolicy: fixture.measurementPolicy
            )
        }
        #expect(!policy.authenticatedProductionDriver)
    }

    @Test("public construction binds one decoded measurement policy")
    func publicConstructionRejectsCrossPolicySplicing() throws {
        let fixture = try Fixture()
        let mismatched = try VoicePerformanceMeasurementPolicy.decodeCanonical(
            Fixture.measurementPolicyData(
                driverPolicySHA256: String(repeating: "0", count: 64)
            )
        )

        #expect(throws: PerformanceControlError.bindingMismatch) {
            try PerformanceControlStateMachine(
                driverPolicy: fixture.driverPolicy,
                measurementPolicy: mismatched
            )
        }
        let initializer: (
            SealedPerformanceControlDriverPolicy,
            VoicePerformanceMeasurementPolicy
        ) throws -> PerformanceControlStateMachine =
            PerformanceControlStateMachine.init
        _ = initializer
        _ = try fixture.machine()
    }

    @Test("driver hello cannot attest a different measurement policy")
    func driverHelloRejectsCrossPolicyDigest() throws {
        let fixture = try Fixture()
        var machine = try fixture.machine()
        _ = try machine.receive(
            fixture.driverChallenge,
            on: .collectorToDriver
        )

        #expect(throws: PerformanceControlError.bindingMismatch) {
            try machine.receive(
                .driverHello(
                    sessionID: fixture.sessionID,
                    planNonce: fixture.planNonce,
                    collectorNonce: fixture.driverCollectorNonce,
                    peerNonce: fixture.driverPeerNonce,
                    collectionProtocol: fixture.driverPolicy.controlProtocol,
                    driverPolicySHA256:
                        fixture.driverPolicy.canonicalSHA256,
                    measurementPolicySHA256: try PerformanceControlSHA256(
                        String(repeating: "8", count: 64)
                    )
                ),
                on: .driverToCollector
            )
        }
        #expect(machine.snapshot.phase == .failed)
    }

    @Test("the sealed policy trial count is a state-machine upper bound")
    func sealedPolicyTrialCountBoundsTheMachine() throws {
        let fixture = try Fixture(coldTrials: 1)
        var machine = try fixture.machine()
        try fixture.advanceToLoading(&machine)
        _ = try machine.receive(
            .loadReady(
                sequence: 2,
                sessionID: fixture.sessionID,
                replyTo: 2,
                trial: 1,
                loadTicket: fixture.ticket,
                engine: fixture.engine
            ),
            on: .helperToCollector(fixture.generation)
        )
        let secondBinding = try PerformanceControlSessionBinding.derive(
            controlSessionNonce: fixture.controlSessionNonce,
            trial: 2
        )

        #expect(throws: PerformanceControlError.bindingMismatch) {
            try machine.receive(
                .challenge(
                    peerRole: .driver,
                    sessionID: secondBinding.sessionID,
                    planNonce: secondBinding.planNonce,
                    collectorNonce: try token("8")
                ),
                on: .collectorToDriver
            )
        }
        #expect(machine.snapshot.phase == .failed)
    }

    private func token(_ pattern: String) throws -> PerformanceControlNonce {
        let repetitions = 64 / pattern.utf8.count
        return try PerformanceControlNonce(
            String(repeating: pattern, count: repetitions)
        )
    }
}

private struct Fixture {
    let controlSessionNonce: PerformanceControlNonce
    let sessionID: PerformanceControlNonce
    let planNonce: PerformanceControlNonce
    let driverCollectorNonce: PerformanceControlNonce
    let driverPeerNonce: PerformanceControlNonce
    let helperCollectorNonce: PerformanceControlNonce
    let helperPeerNonce: PerformanceControlNonce
    let ticket: PerformanceControlNonce
    let measurementPolicySHA256: PerformanceControlSHA256
    let releasePolicySHA256: PerformanceControlSHA256
    let measurementPolicy: VoicePerformanceMeasurementPolicy
    let driverPolicy: SealedPerformanceControlDriverPolicy
    let generation: HelperGenerationIdentity
    let engine: PerformanceControlEngineSummary

    init(coldTrials: UInt64 = 7) throws {
        let protocolIdentity = try PerformanceControlProtocolIdentity(
            sha256: String(repeating: "a", count: 64)
        )
        let decodedDriverPolicy = try SealedPerformanceControlDriverPolicy
            .decodeCanonical(
                Self.tracerPolicyData,
                expectedControlProtocol: protocolIdentity
            )
        driverPolicy = decodedDriverPolicy
        let decodedMeasurementPolicy = try VoicePerformanceMeasurementPolicy
            .decodeCanonical(Self.measurementPolicyData(
                driverPolicySHA256: decodedDriverPolicy.canonicalSHA256.rawValue,
                coldTrials: coldTrials
            ))
        measurementPolicy = decodedMeasurementPolicy
        controlSessionNonce = try PerformanceControlNonce(
            decodedMeasurementPolicy.controlSessionNonce
        )
        let binding = try PerformanceControlSessionBinding.derive(
            controlSessionNonce: controlSessionNonce,
            trial: 1
        )
        sessionID = binding.sessionID
        planNonce = binding.planNonce
        driverCollectorNonce = try Self.nonce("3")
        driverPeerNonce = try Self.nonce("4")
        helperCollectorNonce = try Self.nonce("5")
        helperPeerNonce = try Self.nonce("6")
        ticket = try Self.nonce("7")
        measurementPolicySHA256 = try PerformanceControlSHA256(
            decodedMeasurementPolicy.canonicalSHA256
        )
        releasePolicySHA256 = try PerformanceControlSHA256(
            decodedMeasurementPolicy.releasePolicySHA256
        )
        generation = try HelperGenerationIdentity(
            pid: 101,
            processStartToken: 1_001,
            instanceID: ControlledPerformanceID(
                String(repeating: "b", count: 64)
            )
        )
        let artifactSHA256 = try Self.digest("d")
        engine = try PerformanceControlEngineSummary(
            adapterID: ControlledPerformanceID("sherpa-onnx"),
            engineID: "sherpa-onnx@dddddddddddddddd",
            artifactID: ControlledPerformanceID("voice-model-v1"),
            artifactContentSHA256: artifactSHA256,
            artifactGeneration: PerformanceControlArtifactGeneration(
                "11111111-1111-4111-8111-111111111111"
            ),
            capabilities: [
                ControlledPerformanceID("hotword_snapshot"),
                ControlledPerformanceID("local_asr"),
                ControlledPerformanceID("streaming"),
            ],
            networkPolicy: .offline,
            maximumHotwords: 32
        )
    }

    func machine() throws -> PerformanceControlStateMachine {
        try PerformanceControlStateMachine(
            driverPolicy: driverPolicy,
            measurementPolicy: measurementPolicy
        )
    }

    func authenticate(
        _ machine: inout PerformanceControlStateMachine
    ) throws {
        _ = try machine.receive(driverChallenge, on: .collectorToDriver)
        _ = try machine.receive(driverHello, on: .driverToCollector)
        _ = try machine.receive(
            helperChallenge,
            on: .collectorToHelper(generation)
        )
        _ = try machine.receive(
            helperHello,
            on: .helperToCollector(generation)
        )
    }

    func advanceToLoading(
        _ machine: inout PerformanceControlStateMachine
    ) throws {
        try authenticate(&machine)
        _ = try machine.receive(
            .armColdLoad(sequence: 1, sessionID: sessionID, trial: 1),
            on: .driverToCollector
        )
        _ = try machine.receive(
            .loadEngine(
                sequence: 1,
                sessionID: sessionID,
                trial: 1,
                loadTicket: ticket
            ),
            on: .collectorToHelper(generation)
        )
        _ = try machine.receive(
            .loadStarted(
                sequence: 1,
                sessionID: sessionID,
                replyTo: 1,
                trial: 1,
                loadTicket: ticket
            ),
            on: .helperToCollector(generation)
        )
        _ = try machine.receive(
            .loadStartedAck(
                sequence: 2,
                sessionID: sessionID,
                replyTo: 1,
                trial: 1,
                loadTicket: ticket
            ),
            on: .collectorToHelper(generation)
        )
    }

    func engine(
        artifactID: String,
        artifactSHA256Digit: Character,
        maximumHotwords: UInt64
    ) throws -> PerformanceControlEngineSummary {
        let sha256 = try Self.digest(artifactSHA256Digit)
        return try PerformanceControlEngineSummary(
            adapterID: ControlledPerformanceID("sherpa-onnx"),
            engineID: "sherpa-onnx@"
                + String(sha256.rawValue.prefix(16)),
            artifactID: ControlledPerformanceID(artifactID),
            artifactContentSHA256: sha256,
            artifactGeneration: PerformanceControlArtifactGeneration(
                "22222222-2222-4222-8222-222222222222"
            ),
            capabilities: [
                ControlledPerformanceID("hotword_snapshot"),
                ControlledPerformanceID("local_asr"),
                ControlledPerformanceID("streaming"),
            ],
            networkPolicy: .offline,
            maximumHotwords: maximumHotwords
        )
    }

    var driverChallenge: PerformanceControlWireFrame {
        .challenge(
            peerRole: .driver,
            sessionID: sessionID,
            planNonce: planNonce,
            collectorNonce: driverCollectorNonce
        )
    }

    var driverHello: PerformanceControlWireFrame {
        .driverHello(
            sessionID: sessionID,
            planNonce: planNonce,
            collectorNonce: driverCollectorNonce,
            peerNonce: driverPeerNonce,
            collectionProtocol: driverPolicy.controlProtocol,
            driverPolicySHA256: driverPolicy.canonicalSHA256,
            measurementPolicySHA256: measurementPolicySHA256
        )
    }

    var helperChallenge: PerformanceControlWireFrame {
        .challenge(
            peerRole: .helper,
            sessionID: sessionID,
            planNonce: planNonce,
            collectorNonce: helperCollectorNonce
        )
    }

    var helperHello: PerformanceControlWireFrame {
        .helperHello(
            sessionID: sessionID,
            planNonce: planNonce,
            collectorNonce: helperCollectorNonce,
            peerNonce: helperPeerNonce,
            measurementPolicySHA256: measurementPolicySHA256,
            releasePolicySHA256: releasePolicySHA256
        )
    }

    private static func nonce(_ digit: Character) throws
        -> PerformanceControlNonce
    {
        try PerformanceControlNonce(String(repeating: digit, count: 64))
    }

    private static func digest(_ digit: Character) throws
        -> PerformanceControlSHA256
    {
        try PerformanceControlSHA256(String(repeating: digit, count: 64))
    }

    private static let tracerPolicyData = Data(
        (#"{"capabilities":["authenticated_control","lazy_load_ticket"],"control_protocol":{"id":"rimeai-performance-control-v2","sha256":""#
            + String(repeating: "a", count: 64)
            + #""},"qualification":"tracer","schema_version":1}"#).utf8
    )

    static func measurementPolicyData(
        driverPolicySHA256: String,
        coldTrials: UInt64 = 7
    ) -> Data {
        Data(
            (#"{"cold_trials":"# + String(coldTrials)
                + #","collector":{"expected_cdhash":""#
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
                + #""},"enabled":true,"evaluation_artifact":{"adapter_id":"sherpa-onnx","artifact_id":"voice-model-v1","content_sha256":""#
                + String(repeating: "d", count: 64)
                + #"","directory":"/private/tmp/rimeai-evaluation-artifact","maximum_hotwords":32},"helper":{"expected_cdhash":""#
                + String(repeating: "3", count: 40)
                + #"","expected_executable_path":"/usr/local/libexec/rimeai-voice-helper","expected_executable_sha256":""#
                + String(repeating: "1", count: 64)
                + #"","expected_signing_identifier":"fun.wwcn.rimeai.voice-helper","expected_team_identifier":"TEAMID1234"},"release_policy_sha256":""#
                + String(repeating: "9", count: 64)
                + #"","schema_version":2}"#).utf8
        )
    }
}
