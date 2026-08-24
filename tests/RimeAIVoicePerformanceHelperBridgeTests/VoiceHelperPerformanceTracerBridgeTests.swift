import CryptoKit
import Dispatch
import Foundation
import RimeAIVoicePerformanceControlCore
import Testing
@testable import RimeAIInputCore
@testable import RimeAIVoiceHelperEngine
@_spi(VoicePerformanceTracer) @testable import RimeAIVoicePerformanceHelperBridge

@Suite(.serialized)
struct VoiceHelperPerformanceTracerBridgeTests {
    @Test
    func spiFactoryRequiresPolicyWithoutSpoofableGeneration() {
        let factory: (
            RimeAIProductDataLayout,
            VoicePerformanceMeasurementPolicy
        ) throws -> VoiceHelperPerformanceTracerBridge =
            VoiceHelperPerformanceTracerBridgeFactory.make
        _ = factory
    }

    @Test
    func privateTemporaryVerifiedHelperPathIsThePolicyAuthority() throws {
        let fixture = try TracerFacadeFixture()
        defer { fixture.remove() }

        _ = try VoiceHelperPerformanceTracerBridgeFactory.make(
            bootstrap: fixture.bootstrap,
            measurementPolicy: fixture.measurementPolicy,
            peerNonceSource: { try tracerFacadeNonce("9") },
            processStartTokenSource: { 9_001 }
        )

        #expect(fixture.bundleValidationCount == 1)
    }

    @Test
    func temporarySymlinkAliasCannotBecomeThePolicyAuthority() throws {
        let fixture = try TracerFacadeFixture(
            helperExecutablePathTransform: {
                guard $0.hasPrefix("/private/tmp/") else { return $0 }
                return "/tmp/" + $0.dropFirst("/private/tmp/".count)
            }
        )
        defer { fixture.remove() }

        #expect(
            throws: VoiceHelperPerformanceTracerBridgeError.rejected
        ) {
            _ = try fixture.makeBridge()
        }
        #expect(fixture.bundleValidationCount == 0)
    }

    @Test
    func decomposedVerifiedHelperPathCannotBecomeThePolicyAuthority() {
        let decomposedPath =
            "/private/tmp/RimeAI-e\u{301}.app"
            + "/Contents/MacOS/rimeai-voice-performance-helper"

        #expect(
            throws: VoiceHelperPerformanceTracerBootstrapError
                .invalidVerifiedHelperExecutablePath
        ) {
            _ = try VoiceHelperPerformanceTracerBootstrap
                .deriveVerifiedHelperBundleURL(
                    executablePath: decomposedPath
                )
        }
    }

    @Test
    func symlinkedPolicyAncestorIsRejectedAfterBundleValidation() throws {
        let fixture = try TracerFacadeFixture()
        defer { fixture.remove() }
        try fixture.replaceResourcesWithSymlink()

        #expect(
            throws: VoiceHelperPerformanceTracerBridgeError.rejected
        ) {
            _ = try fixture.makeBridge()
        }
        #expect(fixture.bundleValidationCount == 1)
        #expect(fixture.factory.invocationCount == 0)
    }

    @Test
    func matchingChallengeReturnsPolicyBoundHelperHelloWithoutLoading()
        throws
    {
        let fixture = try TracerFacadeFixture()
        defer { fixture.remove() }
        let peerNonce = try tracerFacadeNonce("9")
        let bridge = try fixture.makeBridge(peerNonce: peerNonce)
        let binding = try PerformanceControlSessionBinding.derive(
            controlSessionNonce: try PerformanceControlNonce(
                fixture.measurementPolicy.controlSessionNonce
            ),
            trial: 7
        )
        let collectorNonce = try tracerFacadeNonce("8")

        let response = try bridge.receive(.challenge(
            peerRole: .helper,
            sessionID: binding.sessionID,
            planNonce: binding.planNonce,
            collectorNonce: collectorNonce
        ))

        #expect(response == .helperHello(
            sessionID: binding.sessionID,
            planNonce: binding.planNonce,
            collectorNonce: collectorNonce,
            peerNonce: peerNonce,
            measurementPolicySHA256: try PerformanceControlSHA256(
                fixture.measurementPolicy.canonicalSHA256
            ),
            releasePolicySHA256: try PerformanceControlSHA256(
                tracerFacadeSHA256(fixture.releasePolicyData)
            )
        ))
        #expect(!bridge.authenticatedProductionDriver)
        #expect(fixture.bundleValidationCount == 1)
        #expect(fixture.factory.invocationCount == 0)
        #expect(fixture.appleReleaseFactory.invocationCount == 0)
        #expect(fixture.productionFactory.invocationCount == 0)
    }

    @Test
    func unexpectedFactorySourceErrorIsNotMisclassifiedAsRejection() throws {
        let fixture = try TracerFacadeFixture()
        defer { fixture.remove() }
        let unexpected = TracerFacadeUnexpectedError(
            description: "bridge-factory-secret-2d7a"
        )

        #expect(throws: unexpected) {
            _ = try VoiceHelperPerformanceTracerBridgeFactory.make(
                bootstrap: fixture.bootstrap,
                measurementPolicy: fixture.measurementPolicy,
                peerNonceSource: { try tracerFacadeNonce("9") },
                processStartTokenSource: { throw unexpected }
            )
        }
        #expect(fixture.factory.invocationCount == 0)
    }

    @Test
    func verifiedReleasePolicyBytesAreNotReadAgainAfterFactoryReturns()
        throws
    {
        let fixture = try TracerFacadeFixture()
        defer { fixture.remove() }
        let bridge = try fixture.makeBridge()
        try Data("path-was-replaced-after-read".utf8).write(
            to: fixture.policyURL
        )
        let binding = try fixture.binding(trial: 7)
        let hello = try bridge.receive(.challenge(
            peerRole: .helper,
            sessionID: binding.sessionID,
            planNonce: binding.planNonce,
            collectorNonce: try tracerFacadeNonce("8")
        ))
        let ticket = try tracerFacadeNonce("2")
        _ = try bridge.receive(.loadEngine(
            sequence: 1,
            sessionID: binding.sessionID,
            trial: 7,
            loadTicket: ticket
        ))
        _ = try bridge.receive(.loadStartedAck(
            sequence: 2,
            sessionID: binding.sessionID,
            replyTo: 1,
            trial: 7,
            loadTicket: ticket
        ))

        guard case let .helperHello(
            _,
            _,
            _,
            _,
            _,
            releasePolicySHA256
        ) = hello
        else {
            Issue.record("expected helper_hello")
            return
        }
        #expect(
            releasePolicySHA256.rawValue
                == tracerFacadeSHA256(fixture.releasePolicyData)
        )
        #expect(fixture.bundleValidationCount == 1)
        #expect(fixture.factory.invocationCount == 1)
        #expect(fixture.productionFactory.invocationCount == 0)
    }

    @Test
    func opaqueDeferredLoaderFailureSurvivesFacadeTerminalCleanup() throws {
        let unexpected = TracerFacadeUnexpectedError(
            description: "helper-facade-loader-secret-169e"
        )
        let fixture = try TracerFacadeFixture(
            factory: TracerFacadeEngineFactory { throw unexpected }
        )
        defer { fixture.remove() }
        let bridge = try fixture.makeBridge()
        let binding = try fixture.binding(trial: 7)
        let ticket = try tracerFacadeNonce("2")
        _ = try bridge.receive(.challenge(
            peerRole: .helper,
            sessionID: binding.sessionID,
            planNonce: binding.planNonce,
            collectorNonce: try tracerFacadeNonce("8")
        ))
        _ = try bridge.receive(.loadEngine(
            sequence: 1,
            sessionID: binding.sessionID,
            trial: 7,
            loadTicket: ticket
        ))
        let acknowledgement = PerformanceControlWireFrame.loadStartedAck(
            sequence: 2,
            sessionID: binding.sessionID,
            replyTo: 1,
            trial: 7,
            loadTicket: ticket
        )

        #expect(throws: unexpected) {
            _ = try bridge.receive(acknowledgement)
        }
        #expect(throws: VoiceHelperPerformanceTracerBridgeError.rejected) {
            _ = try bridge.receive(acknowledgement)
        }
        #expect(fixture.factory.invocationCount == 1)
    }

    @Test
    func releasePolicyHashMismatchIsNormalizedBeforeLoading() throws {
        let fixture = try TracerFacadeFixture(
            declaredReleasePolicySHA256: String(repeating: "0", count: 64)
        )
        defer { fixture.remove() }

        #expect(
            throws: VoiceHelperPerformanceTracerBridgeError.rejected
        ) {
            _ = try fixture.makeBridge()
        }
        #expect(fixture.bundleValidationCount == 1)
        #expect(fixture.factory.invocationCount == 0)
    }

    @Test
    func ordinaryBootstrapStillSelectsAppleWithoutEvaluation() throws {
        let fixture = try TracerFacadeFixture()
        defer { fixture.remove() }

        _ = try fixture.releaseBootstrap.makeEngine(
            bundleURL: fixture.bundleURL
        )

        #expect(fixture.appleReleaseFactory.invocationCount == 1)
        #expect(fixture.productionFactory.invocationCount == 0)
        #expect(fixture.factory.invocationCount == 0)
    }

    @Test
    func challengeCannotSpliceBindingsFromAnotherMeasurementPolicy()
        throws
    {
        let primaryNonce = String(repeating: "0f", count: 32)
        let otherNonce = String(repeating: "1e", count: 32)
        let primaryBinding = try PerformanceControlSessionBinding.derive(
            controlSessionNonce: PerformanceControlNonce(primaryNonce),
            trial: 7
        )
        let otherBinding = try PerformanceControlSessionBinding.derive(
            controlSessionNonce: PerformanceControlNonce(otherNonce),
            trial: 7
        )
        let rejectedBindings = [
            (otherBinding.sessionID, otherBinding.planNonce),
            (primaryBinding.sessionID, otherBinding.planNonce),
            (otherBinding.sessionID, primaryBinding.planNonce),
        ]

        for (sessionID, planNonce) in rejectedBindings {
            let fixture = try TracerFacadeFixture(
                controlSessionNonce: primaryNonce
            )
            defer { fixture.remove() }
            let bridge = try fixture.makeBridge()

            #expect(
                throws: VoiceHelperPerformanceTracerBridgeError.rejected
            ) {
                _ = try bridge.receive(.challenge(
                    peerRole: .helper,
                    sessionID: sessionID,
                    planNonce: planNonce,
                    collectorNonce: try tracerFacadeNonce("8")
                ))
            }
            #expect(
                throws: VoiceHelperPerformanceTracerBridgeError.rejected
            ) {
                _ = try bridge.receive(.challenge(
                    peerRole: .helper,
                    sessionID: primaryBinding.sessionID,
                    planNonce: primaryBinding.planNonce,
                    collectorNonce: try tracerFacadeNonce("8")
                ))
            }
            #expect(fixture.factory.invocationCount == 0)
        }
    }

    @Test
    func challengeRejectsNonceReuseBeforeAnyLoadIsArmed() throws {
        let reference = try TracerFacadeFixture()
        defer { reference.remove() }
        let binding = try reference.binding(trial: 7)
        let distinctPeer = try tracerFacadeNonce("9")
        let distinctCollector = try tracerFacadeNonce("8")
        let reusedNonces = [
            (distinctPeer, binding.sessionID),
            (distinctPeer, binding.planNonce),
            (binding.sessionID, distinctCollector),
            (binding.planNonce, distinctCollector),
            (distinctCollector, distinctCollector),
        ]

        for (peerNonce, collectorNonce) in reusedNonces {
            let fixture = try TracerFacadeFixture()
            defer { fixture.remove() }
            let bridge = try fixture.makeBridge(peerNonce: peerNonce)

            #expect(
                throws: VoiceHelperPerformanceTracerBridgeError.rejected
            ) {
                _ = try bridge.receive(.challenge(
                    peerRole: .helper,
                    sessionID: binding.sessionID,
                    planNonce: binding.planNonce,
                    collectorNonce: collectorNonce
                ))
            }
            #expect(fixture.factory.invocationCount == 0)
        }
    }

    @Test
    func loadTicketCannotReuseAnyHandshakeNonce() throws {
        let reference = try TracerFacadeFixture()
        defer { reference.remove() }
        let binding = try reference.binding(trial: 7)
        let collectorNonce = try tracerFacadeNonce("8")
        let peerNonce = try tracerFacadeNonce("9")
        let reusedTickets = [
            binding.sessionID,
            binding.planNonce,
            collectorNonce,
            peerNonce,
        ]

        for loadTicket in reusedTickets {
            let fixture = try TracerFacadeFixture()
            defer { fixture.remove() }
            let bridge = try fixture.makeBridge(peerNonce: peerNonce)
            _ = try bridge.receive(.challenge(
                peerRole: .helper,
                sessionID: binding.sessionID,
                planNonce: binding.planNonce,
                collectorNonce: collectorNonce
            ))

            #expect(
                throws: VoiceHelperPerformanceTracerBridgeError.rejected
            ) {
                _ = try bridge.receive(.loadEngine(
                    sequence: 1,
                    sessionID: binding.sessionID,
                    trial: 7,
                    loadTicket: loadTicket
                ))
            }
            #expect(
                throws: VoiceHelperPerformanceTracerBridgeError.rejected
            ) {
                _ = try bridge.receive(.loadEngine(
                    sequence: 1,
                    sessionID: binding.sessionID,
                    trial: 7,
                    loadTicket: try tracerFacadeNonce("2")
                ))
            }
            #expect(fixture.factory.invocationCount == 0)
        }
    }

    @Test
    func loadCannotSwitchTrialsAfterTheChallenge() throws {
        let fixture = try TracerFacadeFixture()
        defer { fixture.remove() }
        let bridge = try fixture.makeBridge()
        let challenged = try fixture.binding(trial: 7)
        let different = try fixture.binding(trial: 8)
        _ = try bridge.receive(.challenge(
            peerRole: .helper,
            sessionID: challenged.sessionID,
            planNonce: challenged.planNonce,
            collectorNonce: try tracerFacadeNonce("8")
        ))

        #expect(
            throws: VoiceHelperPerformanceTracerBridgeError.rejected
        ) {
            _ = try bridge.receive(.loadEngine(
                sequence: 1,
                sessionID: different.sessionID,
                trial: 8,
                loadTicket: try tracerFacadeNonce("2")
            ))
        }
        #expect(fixture.factory.invocationCount == 0)
    }

    @Test
    func duplicateChallengeAndLoadFramesAreTerminal() throws {
        for duplicateLoad in [false, true] {
            let fixture = try TracerFacadeFixture()
            defer { fixture.remove() }
            let bridge = try fixture.makeBridge()
            let binding = try fixture.binding(trial: 7)
            let challenge = PerformanceControlWireFrame.challenge(
                peerRole: .helper,
                sessionID: binding.sessionID,
                planNonce: binding.planNonce,
                collectorNonce: try tracerFacadeNonce("8")
            )
            let load = PerformanceControlWireFrame.loadEngine(
                sequence: 1,
                sessionID: binding.sessionID,
                trial: 7,
                loadTicket: try tracerFacadeNonce("2")
            )
            _ = try bridge.receive(challenge)
            if duplicateLoad {
                _ = try bridge.receive(load)
            }

            #expect(
                throws: VoiceHelperPerformanceTracerBridgeError.rejected
            ) {
                _ = try bridge.receive(duplicateLoad ? load : challenge)
            }
            #expect(
                throws: VoiceHelperPerformanceTracerBridgeError.rejected
            ) {
                _ = try bridge.receive(load)
            }
            #expect(fixture.factory.invocationCount == 0)
        }
    }

    @Test
    func loadAndAcknowledgementReturnOneResponsePerTypedInput() throws {
        let fixture = try TracerFacadeFixture()
        defer { fixture.remove() }
        let bridge = try fixture.makeBridge()
        let controlNonce = try PerformanceControlNonce(
            fixture.measurementPolicy.controlSessionNonce
        )
        let binding = try PerformanceControlSessionBinding.derive(
            controlSessionNonce: controlNonce,
            trial: 7
        )
        _ = try bridge.receive(.challenge(
            peerRole: .helper,
            sessionID: binding.sessionID,
            planNonce: binding.planNonce,
            collectorNonce: try tracerFacadeNonce("8")
        ))
        let ticket = try tracerFacadeNonce("2")

        let started = try bridge.receive(.loadEngine(
            sequence: 1,
            sessionID: binding.sessionID,
            trial: 7,
            loadTicket: ticket
        ))

        #expect(started == .loadStarted(
            sequence: 1,
            sessionID: binding.sessionID,
            replyTo: 1,
            trial: 7,
            loadTicket: ticket
        ))
        #expect(fixture.factory.invocationCount == 0)

        let ready = try bridge.receive(.loadStartedAck(
            sequence: 2,
            sessionID: binding.sessionID,
            replyTo: 1,
            trial: 7,
            loadTicket: ticket
        ))

        guard case let .loadReady(
            sequence,
            sessionID,
            replyTo,
            trial,
            readyTicket,
            engine
        ) = ready
        else {
            Issue.record("expected load_ready")
            return
        }
        #expect(sequence == 2)
        #expect(sessionID == binding.sessionID)
        #expect(replyTo == 2)
        #expect(trial == 7)
        #expect(readyTicket == ticket)
        #expect(engine.adapterID.rawValue == "sherpa-onnx")
        #expect(engine.engineID == "sherpa-onnx@aaaaaaaaaaaaaaaa")
        #expect(fixture.factory.invocationCount == 1)
        #expect(fixture.appleReleaseFactory.invocationCount == 0)
        #expect(fixture.productionFactory.invocationCount == 0)
        #expect(!bridge.authenticatedProductionDriver)

        #expect(
            throws: VoiceHelperPerformanceTracerBridgeError.rejected
        ) {
            _ = try bridge.receive(.loadStartedAck(
                sequence: 2,
                sessionID: binding.sessionID,
                replyTo: 1,
                trial: 7,
                loadTicket: ticket
            ))
        }
        #expect(fixture.factory.invocationCount == 1)
    }

    @Test
    func policyTrialLimitRejectsLaterChallengesBeforeAnyLoad() throws {
        for trial in [UInt64(8), 32] {
            let fixture = try TracerFacadeFixture(coldTrials: 7)
            defer { fixture.remove() }
            let bridge = try fixture.makeBridge()
            let binding = try fixture.binding(trial: trial)

            #expect(
                throws: VoiceHelperPerformanceTracerBridgeError.rejected
            ) {
                _ = try bridge.receive(.challenge(
                    peerRole: .helper,
                    sessionID: binding.sessionID,
                    planNonce: binding.planNonce,
                    collectorNonce: try tracerFacadeNonce("8")
                ))
            }
            #expect(fixture.factory.invocationCount == 0)
            #expect(fixture.productionFactory.invocationCount == 0)
        }
    }

    @Test
    func invalidLiveSelfGenerationFailsBeforeBundleOrEngineFactories()
        throws
    {
        let fixture = try TracerFacadeFixture()
        defer { fixture.remove() }

        #expect(throws: VoiceHelperPerformanceTracerBridgeError.rejected) {
            _ = try fixture.makeBridge(processStartToken: 0)
        }
        #expect(fixture.bundleValidationCount == 0)
        #expect(fixture.factory.invocationCount == 0)
        #expect(fixture.productionFactory.invocationCount == 0)
    }

    @Test
    func policyDescriptorMismatchIsTerminalAndNeverPublishesReady()
        throws
    {
        let mismatchedFactory = TracerFacadeEngineFactory {
            TracerFacadeMismatchedProductEngine()
        }
        let fixture = try TracerFacadeFixture(factory: mismatchedFactory)
        defer { fixture.remove() }
        let bridge = try fixture.makeBridge()
        let binding = try fixture.binding(trial: 7)
        let ticket = try tracerFacadeNonce("2")
        _ = try bridge.receive(.challenge(
            peerRole: .helper,
            sessionID: binding.sessionID,
            planNonce: binding.planNonce,
            collectorNonce: try tracerFacadeNonce("8")
        ))
        _ = try bridge.receive(.loadEngine(
            sequence: 1,
            sessionID: binding.sessionID,
            trial: 7,
            loadTicket: ticket
        ))

        #expect(throws: VoiceHelperPerformanceTracerBridgeError.rejected) {
            _ = try bridge.receive(.loadStartedAck(
                sequence: 2,
                sessionID: binding.sessionID,
                replyTo: 1,
                trial: 7,
                loadTicket: ticket
            ))
        }
        #expect(mismatchedFactory.invocationCount == 1)
        #expect(fixture.productionFactory.invocationCount == 0)
        #expect(throws: VoiceHelperPerformanceTracerBridgeError.rejected) {
            _ = try bridge.receive(.loadStartedAck(
                sequence: 2,
                sessionID: binding.sessionID,
                replyTo: 1,
                trial: 7,
                loadTicket: ticket
            ))
        }
    }

    @Test
    func cancellationDisconnectionAndTimeoutAreTerminalBeforeAck()
        throws
    {
        for termination in TracerFacadeTermination.allCases {
            let fixture = try TracerFacadeFixture()
            defer { fixture.remove() }
            let bridge = try fixture.makeBridge()
            let binding = try fixture.binding(trial: 7)
            let ticket = try tracerFacadeNonce("2")
            _ = try bridge.receive(.challenge(
                peerRole: .helper,
                sessionID: binding.sessionID,
                planNonce: binding.planNonce,
                collectorNonce: try tracerFacadeNonce("8")
            ))
            _ = try bridge.receive(.loadEngine(
                sequence: 1,
                sessionID: binding.sessionID,
                trial: 7,
                loadTicket: ticket
            ))

            termination.apply(to: bridge)

            #expect(
                throws: VoiceHelperPerformanceTracerBridgeError.rejected
            ) {
                _ = try bridge.receive(.loadStartedAck(
                    sequence: 2,
                    sessionID: binding.sessionID,
                    replyTo: 1,
                    trial: 7,
                    loadTicket: ticket
                ))
            }
            #expect(fixture.factory.invocationCount == 0)
        }
    }

    @Test
    func terminalSignalDuringBlockedLoadNeverPublishesReady() throws {
        for termination in TracerFacadeTermination.allCases {
            let factoryStarted = DispatchSemaphore(value: 0)
            let releaseFactory = DispatchSemaphore(value: 0)
            let factory = TracerFacadeEngineFactory {
                factoryStarted.signal()
                guard releaseFactory.wait(timeout: .now() + 2)
                        == .success
                else {
                    throw TracerFacadeTestError.factoryTimedOut
                }
                return TracerFacadeProductEngine()
            }
            let fixture = try TracerFacadeFixture(factory: factory)
            defer { fixture.remove() }
            let bridge = try fixture.makeBridge()
            let binding = try fixture.binding(trial: 7)
            let ticket = try tracerFacadeNonce("2")
            _ = try bridge.receive(.challenge(
                peerRole: .helper,
                sessionID: binding.sessionID,
                planNonce: binding.planNonce,
                collectorNonce: try tracerFacadeNonce("8")
            ))
            _ = try bridge.receive(.loadEngine(
                sequence: 1,
                sessionID: binding.sessionID,
                trial: 7,
                loadTicket: ticket
            ))
            let outcome = TracerFacadeReceiveOutcome()
            let load = DispatchGroup()
            load.enter()
            DispatchQueue.global().async {
                defer { load.leave() }
                do {
                    outcome.recordResponse(try bridge.receive(
                        .loadStartedAck(
                            sequence: 2,
                            sessionID: binding.sessionID,
                            replyTo: 1,
                            trial: 7,
                            loadTicket: ticket
                        )
                    ))
                } catch let error
                    as VoiceHelperPerformanceTracerBridgeError
                {
                    outcome.recordFailure(error)
                } catch {
                    outcome.recordUnexpectedFailure()
                }
            }

            #expect(factoryStarted.wait(timeout: .now() + 2) == .success)
            termination.apply(to: bridge)
            releaseFactory.signal()
            #expect(load.wait(timeout: .now() + 2) == .success)

            #expect(outcome.responseCount == 0)
            #expect(outcome.failures == [.rejected])
            #expect(outcome.unexpectedFailureCount == 0)
            #expect(factory.invocationCount == 1)
        }
    }

    @Test
    func loadedEngineIsHeldUntilTerminationOrFacadeDeinitialization()
        throws
    {
        for release in TracerFacadeEngineRelease.allCases {
            let weakEngine = TracerFacadeWeakEngine()
            let factory = TracerFacadeEngineFactory {
                let engine = TracerFacadeReferenceEngine()
                weakEngine.value = engine
                return engine
            }
            let fixture = try TracerFacadeFixture(factory: factory)
            defer { fixture.remove() }
            var bridge: VoiceHelperPerformanceTracerBridge? = try fixture
                .makeBridge()
            let binding = try fixture.binding(trial: 7)
            let ticket = try tracerFacadeNonce("2")
            _ = try bridge?.receive(.challenge(
                peerRole: .helper,
                sessionID: binding.sessionID,
                planNonce: binding.planNonce,
                collectorNonce: try tracerFacadeNonce("8")
            ))
            _ = try bridge?.receive(.loadEngine(
                sequence: 1,
                sessionID: binding.sessionID,
                trial: 7,
                loadTicket: ticket
            ))
            _ = try bridge?.receive(.loadStartedAck(
                sequence: 2,
                sessionID: binding.sessionID,
                replyTo: 1,
                trial: 7,
                loadTicket: ticket
            ))

            #expect(weakEngine.value != nil)
            release.apply(to: &bridge)
            #expect(weakEngine.value == nil)
            #expect(factory.invocationCount == 1)
        }
    }

    @Test
    func loadedEngineDeinitializesOutsideTheFacadeLock() throws {
        let bridgeReference = TracerFacadeWeakBridge()
        let deinitializations = TracerFacadeCounter()
        let factory = TracerFacadeEngineFactory {
            TracerFacadeReentrantEngine {
                deinitializations.increment()
                bridgeReference.value?.cancel()
            }
        }
        let fixture = try TracerFacadeFixture(factory: factory)
        defer { fixture.remove() }
        let bridge = try fixture.makeBridge()
        bridgeReference.value = bridge
        let binding = try fixture.binding(trial: 7)
        let ticket = try tracerFacadeNonce("2")
        _ = try bridge.receive(.challenge(
            peerRole: .helper,
            sessionID: binding.sessionID,
            planNonce: binding.planNonce,
            collectorNonce: try tracerFacadeNonce("8")
        ))
        _ = try bridge.receive(.loadEngine(
            sequence: 1,
            sessionID: binding.sessionID,
            trial: 7,
            loadTicket: ticket
        ))
        _ = try bridge.receive(.loadStartedAck(
            sequence: 2,
            sessionID: binding.sessionID,
            replyTo: 1,
            trial: 7,
            loadTicket: ticket
        ))
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            bridge.cancel()
            completed.signal()
        }

        #expect(completed.wait(timeout: .now() + 2) == .success)
        #expect(deinitializations.value == 1)
    }
}

private final class TracerFacadeFixture {
    let root: URL
    let bundleURL: URL
    let policyURL: URL
    let releasePolicyData: Data
    let measurementPolicy: VoicePerformanceMeasurementPolicy
    let factory: TracerFacadeEngineFactory
    let appleReleaseFactory: TracerFacadeEngineFactory
    let productionFactory: TracerFacadeEngineFactory
    let bootstrap: VoiceHelperPerformanceTracerBootstrap
    let releaseBootstrap: VoiceHelperReleaseBootstrap
    private let validationCounter: TracerFacadeCounter

    var bundleValidationCount: Int {
        validationCounter.value
    }

    init(
        controlSessionNonce: String = String(repeating: "0f", count: 32),
        declaredReleasePolicySHA256: String? = nil,
        coldTrials: UInt64 = 7,
        helperExecutablePathTransform: (String) -> String = { $0 },
        factory: TracerFacadeEngineFactory = TracerFacadeEngineFactory()
    ) throws {
        let validationCounter = TracerFacadeCounter()
        let appleReleaseFactory = TracerFacadeEngineFactory()
        let productionFactory = TracerFacadeEngineFactory()
        self.validationCounter = validationCounter
        self.factory = factory
        self.appleReleaseFactory = appleReleaseFactory
        self.productionFactory = productionFactory
        releasePolicyData = tracerFacadeReleasePolicyData()
        root = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        ).appendingPathComponent(
            "rimeai-tracer-facade-\(UUID().uuidString)",
            isDirectory: true
        )
        bundleURL = root.appendingPathComponent(
            "RimeAIVoiceHelper.app",
            isDirectory: true
        )
        let resourcesURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resourcesURL,
            withIntermediateDirectories: true
        )
        policyURL = resourcesURL.appendingPathComponent(
            "VoiceReleasePolicy.plist",
            isDirectory: false
        )
        try releasePolicyData.write(to: policyURL)
        let helperExecutablePath = helperExecutablePathTransform(
            bundleURL.path
                + "/Contents/MacOS/rimeai-voice-performance-helper"
        )
        measurementPolicy = try VoicePerformanceMeasurementPolicy
            .decodeCanonical(tracerFacadeMeasurementPolicyData(
                controlSessionNonce: controlSessionNonce,
                releasePolicySHA256: declaredReleasePolicySHA256
                    ?? tracerFacadeSHA256(releasePolicyData),
                artifactDirectory: root.appendingPathComponent(
                    "EvaluationArtifact",
                    isDirectory: true
                ).path,
                helperExecutablePath: helperExecutablePath,
                coldTrials: coldTrials
            ))
        bootstrap = VoiceHelperPerformanceTracerBootstrap(
            trustedCatalog: tracerFacadeCatalog(),
            bundleValidator: { _ in validationCounter.increment() },
            evaluationFactory: { _ in try factory.makeEngine() }
        )
        releaseBootstrap = VoiceHelperReleaseBootstrap(
            trustedCatalog: tracerFacadeCatalog(),
            bundleValidator: { _ in validationCounter.increment() },
            appleFactory: { try appleReleaseFactory.makeEngine() },
            productFactory: { try productionFactory.makeEngine() }
        )
    }

    func makeBridge(
        peerNonce: PerformanceControlNonce? = nil,
        processStartToken: UInt64 = 9_001
    ) throws -> VoiceHelperPerformanceTracerBridge {
        let resolvedPeerNonce = try peerNonce ?? tracerFacadeNonce("9")
        return try VoiceHelperPerformanceTracerBridgeFactory.make(
            bootstrap: bootstrap,
            measurementPolicy: measurementPolicy,
            peerNonceSource: { resolvedPeerNonce },
            processStartTokenSource: { processStartToken }
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

    func replaceResourcesWithSymlink() throws {
        let resourcesURL = policyURL.deletingLastPathComponent()
        let externalResourcesURL = root.appendingPathComponent(
            "ExternalResources",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: externalResourcesURL,
            withIntermediateDirectories: false
        )
        try releasePolicyData.write(
            to: externalResourcesURL.appendingPathComponent(
                "VoiceReleasePolicy.plist",
                isDirectory: false
            )
        )
        try FileManager.default.removeItem(at: resourcesURL)
        try FileManager.default.createSymbolicLink(
            at: resourcesURL,
            withDestinationURL: externalResourcesURL
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class TracerFacadeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private enum TracerFacadeTermination: CaseIterable {
    case cancel
    case disconnect
    case timeout

    func apply(to bridge: VoiceHelperPerformanceTracerBridge) {
        switch self {
        case .cancel: bridge.cancel()
        case .disconnect: bridge.disconnect()
        case .timeout: bridge.timeout()
        }
    }
}

private enum TracerFacadeEngineRelease: CaseIterable {
    case cancel
    case disconnect
    case timeout
    case deinitialize

    func apply(to bridge: inout VoiceHelperPerformanceTracerBridge?) {
        switch self {
        case .cancel: bridge?.cancel()
        case .disconnect: bridge?.disconnect()
        case .timeout: bridge?.timeout()
        case .deinitialize: bridge = nil
        }
    }
}

private final class TracerFacadeEngineFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let build: @Sendable () throws -> any VoiceDictationEngine
    private var invocations = 0

    init(
        build: @escaping @Sendable () throws -> any VoiceDictationEngine = {
            TracerFacadeProductEngine()
        }
    ) {
        self.build = build
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }

    func makeEngine() throws -> any VoiceDictationEngine {
        lock.lock()
        invocations += 1
        lock.unlock()
        return try build()
    }
}

private enum TracerFacadeTestError: Error {
    case factoryTimedOut
}

private struct TracerFacadeUnexpectedError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    let description: String
}

private final class TracerFacadeReceiveOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [PerformanceControlWireFrame] = []
    private var recordedFailures: [
        VoiceHelperPerformanceTracerBridgeError
    ] = []
    private var unexpectedFailures = 0

    var responseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return responses.count
    }

    var failures: [VoiceHelperPerformanceTracerBridgeError] {
        lock.lock()
        defer { lock.unlock() }
        return recordedFailures
    }

    var unexpectedFailureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return unexpectedFailures
    }

    func recordResponse(_ frame: PerformanceControlWireFrame) {
        lock.lock()
        responses.append(frame)
        lock.unlock()
    }

    func recordFailure(
        _ error: VoiceHelperPerformanceTracerBridgeError
    ) {
        lock.lock()
        recordedFailures.append(error)
        lock.unlock()
    }

    func recordUnexpectedFailure() {
        lock.lock()
        unexpectedFailures += 1
        lock.unlock()
    }
}

private struct TracerFacadeProductEngine: VoiceDictationEngine {
    let descriptor = tracerFacadeProductDescriptor()

    func start(
        _ request: VoiceDictationEngineRequest,
        events: @escaping @Sendable (VoiceDictationEngineEvent) -> Void
    ) {}

    func stop(requestID: String) {}
    func cancel(requestID: String) {}
}

private struct TracerFacadeMismatchedProductEngine: VoiceDictationEngine {
    let descriptor = VoiceEngineDescriptor(
        adapterID: "sherpa-onnx",
        adapterVersion: "1.13.6",
        assetManagement: .productManaged,
        qualification: .integrityVerifiedProductArtifact,
        artifactID: VoiceASRArtifactID(rawValue: "different-model"),
        artifactSHA256: String(repeating: "b", count: 64),
        artifactGeneration: UUID(
            uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
        ),
        supportedLocales: ["zh-CN"],
        capabilities: [.hotwordSnapshot, .localASR, .streaming],
        networkPolicy: .offline,
        audioFormat: .fixedLinearPCM(
            sampleRateHertz: 16_000,
            channelCount: 1,
            bitsPerChannel: 32
        ),
        hotwordMode: .boundedPhraseList(maximumEntries: 8),
        maximumAlternatives: 1
    )

    func start(
        _ request: VoiceDictationEngineRequest,
        events: @escaping @Sendable (VoiceDictationEngineEvent) -> Void
    ) {}

    func stop(requestID: String) {}
    func cancel(requestID: String) {}
}

private final class TracerFacadeReferenceEngine:
    VoiceDictationEngine,
    @unchecked Sendable
{
    let descriptor = tracerFacadeProductDescriptor()

    func start(
        _ request: VoiceDictationEngineRequest,
        events: @escaping @Sendable (VoiceDictationEngineEvent) -> Void
    ) {}

    func stop(requestID: String) {}
    func cancel(requestID: String) {}
}

private final class TracerFacadeReentrantEngine:
    VoiceDictationEngine,
    @unchecked Sendable
{
    let descriptor = tracerFacadeProductDescriptor()
    private let onDeinitialize: @Sendable () -> Void

    init(onDeinitialize: @escaping @Sendable () -> Void) {
        self.onDeinitialize = onDeinitialize
    }

    deinit { onDeinitialize() }

    func start(
        _ request: VoiceDictationEngineRequest,
        events: @escaping @Sendable (VoiceDictationEngineEvent) -> Void
    ) {}

    func stop(requestID: String) {}
    func cancel(requestID: String) {}
}

private final class TracerFacadeWeakEngine: @unchecked Sendable {
    weak var value: TracerFacadeReferenceEngine?
}

private final class TracerFacadeWeakBridge: @unchecked Sendable {
    weak var value: VoiceHelperPerformanceTracerBridge?
}

private func tracerFacadeProductDescriptor() -> VoiceEngineDescriptor {
    VoiceEngineDescriptor(
        adapterID: "sherpa-onnx",
        adapterVersion: "1.13.6",
        assetManagement: .productManaged,
        qualification: .integrityVerifiedProductArtifact,
        artifactID: VoiceASRArtifactID(
            rawValue: "evaluation-voice-model-v1"
        ),
        artifactSHA256: String(repeating: "a", count: 64),
        artifactGeneration: UUID(
            uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        ),
        supportedLocales: ["zh-CN"],
        capabilities: [.hotwordSnapshot, .localASR, .streaming],
        networkPolicy: .offline,
        audioFormat: .fixedLinearPCM(
            sampleRateHertz: 16_000,
            channelCount: 1,
            bitsPerChannel: 32
        ),
        hotwordMode: .boundedPhraseList(maximumEntries: 8),
        maximumAlternatives: 1
    )
}

private func tracerFacadeNonce(
    _ digit: Character
) throws -> PerformanceControlNonce {
    try PerformanceControlNonce(String(repeating: digit, count: 64))
}

private func tracerFacadeSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map {
        String(format: "%02x", $0)
    }.joined()
}

private func tracerFacadeCatalog() -> VoiceASRTrustedArtifactCatalog {
    .production
}

private func tracerFacadeReleasePolicyData() -> Data {
    Data(
        """
        <plist version="1.0">
        <dict>
          <key>SchemaVersion</key>
          <integer>2</integer>
          <key>RuntimeEngine</key>
          <string>apple-speech</string>
          <key>EngineIdentifier</key>
          <string>apple-speech-ondevice</string>
          <key>AssetManagement</key>
          <string>system_managed</string>
          <key>ReleaseEligible</key>
          <false/>
          <key>EligibilityReason</key>
          <string>macos14_15_system_managed_probe_only</string>
          <key>TrustedCatalogSHA256</key>
          <string>\(tracerFacadeCatalog().canonicalSHA256)</string>
        </dict>
        </plist>
        """.utf8
    )
}

private func tracerFacadeMeasurementPolicyData(
    controlSessionNonce: String,
    releasePolicySHA256: String,
    artifactDirectory: String,
    helperExecutablePath: String,
    coldTrials: UInt64
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
            + controlSessionNonce
            + #"","control_socket_path":"/private/tmp/rimeai-performance.sock","driver":{"expected_cdhash":""#
            + String(repeating: "f", count: 40)
            + #"","expected_executable_path":"/usr/local/bin/rimeai-voice-performance-driver","expected_executable_sha256":""#
            + String(repeating: "e", count: 64)
            + #"","expected_signing_identifier":"fun.wwcn.rimeai.voice-performance-driver","expected_team_identifier":"TEAMID1234","policy_sha256":""#
            + String(repeating: "0", count: 64)
            + #""},"enabled":true,"evaluation_artifact":{"adapter_id":"sherpa-onnx","artifact_id":"evaluation-voice-model-v1","content_sha256":""#
            + String(repeating: "a", count: 64)
            + #"","directory":""# + artifactDirectory
            + #"","maximum_hotwords":8},"helper":{"expected_cdhash":""#
            + String(repeating: "3", count: 40)
            + #"","expected_executable_path":""#
            + helperExecutablePath
            + #"","expected_executable_sha256":""#
            + String(repeating: "1", count: 64)
            + #"","expected_signing_identifier":"fun.wwcn.rimeai.voice-helper","expected_team_identifier":"TEAMID1234"},"release_policy_sha256":""#
            + releasePolicySHA256
            + #"","schema_version":2}"#).utf8
    )
}
