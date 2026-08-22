import Dispatch
import Foundation
import Testing
@testable import RimeAIInputCore
@testable import RimeAIVoiceHelperEngine
@testable import RimeAIVoicePerformanceHelperBridge

@Suite(.serialized)
struct VoiceHelperReleaseBootstrapTests {
    @Test
    func debugArgumentsUseOneExactSocketFirstGrammar() throws {
        let defaultEngine = try VoiceHelperReleaseBootstrap
            .parseDebugArguments([
                "rimeai-voice-helper", "--socket", "/tmp/voice.sock",
            ])
        #expect(defaultEngine.socketPath == "/tmp/voice.sock")
        #expect(defaultEngine.engineName == "unavailable")

        let productEngine = try VoiceHelperReleaseBootstrap
            .parseDebugArguments([
                "rimeai-voice-helper", "--socket", "/tmp/voice.sock",
                "--engine", "product-managed",
            ])
        #expect(productEngine.socketPath == "/tmp/voice.sock")
        #expect(productEngine.engineName == "product-managed")

        let rejectedArguments = [
            ["rimeai-voice-helper", "--socket", ""],
            [
                "rimeai-voice-helper", "--socket", "/tmp/voice.sock",
                "--socket", "/tmp/other.sock",
            ],
            [
                "rimeai-voice-helper", "--socket", "/tmp/voice.sock",
                "unexpected",
            ],
            [
                "rimeai-voice-helper", "--engine", "apple-speech",
                "--socket", "/tmp/voice.sock",
            ],
            [
                "rimeai-voice-helper", "--socket", "/tmp/voice.sock",
                "--engine",
            ],
            [
                "rimeai-voice-helper", "--socket", "/tmp/voice.sock",
                "--engine", "unknown",
            ],
            [
                "rimeai-voice-helper", "--socket", "/tmp/voice.sock",
                "--engine", "evaluation-product-managed",
            ],
            [
                "rimeai-voice-helper", "--socket", "/tmp/voice.sock",
                "--engine", "evaluation-product-managed",
                "--artifact-dir", "relative/model",
            ],
            [
                "rimeai-voice-helper", "--socket", "/tmp/voice.sock",
                "--engine", "evaluation-product-managed",
                "--artifact-dir",
                "/private/tmp/evaluation-artifact",
            ],
            [
                "rimeai-voice-helper", "--socket", "/tmp/voice.sock",
                "--engine", "evaluation-product-managed",
                "--artifact-dir", "/private/tmp/evaluation-artifact",
                "unexpected",
            ],
            [
                "rimeai-voice-helper", "--socket", "/tmp/voice.sock",
                "--engine", "product-managed", "--artifact-dir",
                "/private/tmp/evaluation-artifact",
            ],
            [
                "rimeai-voice-helper", "--socket", "/tmp/voice.sock",
                "--artifact-dir", "/private/tmp/evaluation-artifact",
                "--engine", "evaluation-product-managed",
            ],
        ]
        for arguments in rejectedArguments {
            #expect(
                throws: VoiceHelperReleaseBootstrapError
                    .invalidDebugArguments
            ) {
                _ = try VoiceHelperReleaseBootstrap.parseDebugArguments(
                    arguments
                )
            }
        }
    }

    @Test
    func releaseArgumentsAcceptOnlyTheFixedMachService() throws {
        let service = VoiceDictationXPCConstants.machServiceName
        try VoiceHelperReleaseBootstrap.validateReleaseArguments([
            "rimeai-voice-helper", "--mach-service", service,
        ])

        let rejectedArguments = [
            ["rimeai-voice-helper", "--engine", "apple-speech"],
            [
                "rimeai-voice-helper", "--engine",
                "evaluation-product-managed", "--artifact-dir",
                "/private/tmp/evaluation-artifact",
            ],
            [
                "rimeai-voice-helper", "--mach-service", service,
                "--engine", "apple-speech",
            ],
            [
                "rimeai-voice-helper", "--mach-service", service,
                "unexpected",
            ],
            [
                "rimeai-voice-helper", "--mach-service",
                "fun.wwcn.rimeai.voice-helper.lookalike",
            ],
        ]
        for arguments in rejectedArguments {
            #expect(
                throws: VoiceHelperReleaseBootstrapError
                    .invalidReleaseArguments
            ) {
                try VoiceHelperReleaseBootstrap.validateReleaseArguments(
                    arguments
                )
            }
        }
    }

    @Test
    func catalogMismatchFailsBeforeEitherFactory() {
        let catalog = VoiceASRTrustedArtifactCatalog.production
        let calls = ReleaseFactoryCalls()
        let bootstrap = calls.bootstrap(trustedCatalog: catalog)
        let mismatchedDigest = catalog.canonicalSHA256 == String(
            repeating: "0",
            count: 64
        )
            ? String(repeating: "1", count: 64)
            : String(repeating: "0", count: 64)

        #expect(
            throws: VoiceReleasePolicyError
                .trustedCatalogSHA256Mismatch(
                    expected: catalog.canonicalSHA256,
                    actual: mismatchedDigest
                )
        ) {
            _ = try bootstrap.makeEngine(policyData: releasePolicyData(
                runtimeEngine: .appleSpeech,
                catalogDigest: mismatchedDigest
            ))
        }
        #expect(calls.appleCount == 0)
        #expect(calls.productCount == 0)
    }

    @Test
    func systemPolicyFromFixedBundlePathCallsOnlyAppleFactory() throws {
        let catalog = VoiceASRTrustedArtifactCatalog.production
        let fixture = try ReleaseBundleFixture(policyData: releasePolicyData(
            runtimeEngine: .appleSpeech,
            catalogDigest: catalog.canonicalSHA256
        ))
        defer { fixture.remove() }
        let calls = ReleaseFactoryCalls()

        _ = try calls.bootstrap(trustedCatalog: catalog).makeEngine(
            bundleURL: fixture.bundleURL
        )

        #expect(calls.appleCount == 1)
        #expect(calls.productCount == 0)
        #expect(calls.bundleValidationCount == 1)
    }

    @Test
    func matchingProductPolicyCallsOnlyProductFactory() throws {
        let catalog = releaseApprovedCatalog()
        let calls = ReleaseFactoryCalls()

        _ = try calls.bootstrap(trustedCatalog: catalog).makeEngine(
            policyData: releasePolicyData(
                runtimeEngine: .productManaged,
                catalogDigest: catalog.canonicalSHA256
            )
        )

        #expect(calls.appleCount == 0)
        #expect(calls.productCount == 1)
    }

    @Test
    func ordinaryMakeEnginePreservesTheSelectedFactoryError() {
        let catalog = releaseApprovedCatalog()
        var appleCount = 0
        var productCount = 0
        let bootstrap = VoiceHelperReleaseBootstrap(
            trustedCatalog: catalog,
            bundleValidator: { _ in },
            appleFactory: {
                appleCount += 1
                return UnavailableVoiceEngine()
            },
            productFactory: {
                productCount += 1
                throw ReleaseBootstrapTestFailure.productFactoryFailed
            }
        )

        #expect(throws: ReleaseBootstrapTestFailure.productFactoryFailed) {
            _ = try bootstrap.makeEngine(policyData: releasePolicyData(
                runtimeEngine: .productManaged,
                catalogDigest: catalog.canonicalSHA256
            ))
        }
        #expect(appleCount == 0)
        #expect(productCount == 1)
    }

    @Test
    func internalTracerPreparationDoesNotConstructAnEngine() throws {
        let catalog = releaseApprovedCatalog()
        let calls = ReleaseFactoryCalls()

        _ = try calls.bootstrap(trustedCatalog: catalog)
            .prepareInternalTracerEngine(
                policyData: releasePolicyData(
                    runtimeEngine: .productManaged,
                    catalogDigest: catalog.canonicalSHA256
                )
            )

        #expect(calls.appleCount == 0)
        #expect(calls.productCount == 0)
    }

    @Test
    func preparedLoaderAdapterDefersBundleReadAndEngineConstruction()
        throws
    {
        let catalog = releaseApprovedCatalog()
        let fixture = try ReleaseBundleFixture(policyData: releasePolicyData(
            runtimeEngine: .productManaged,
            catalogDigest: catalog.canonicalSHA256
        ))
        defer { fixture.remove() }
        let calls = ReleaseFactoryCalls()

        _ = try calls.bootstrap(trustedCatalog: catalog)
            .prepareInternalTracerEngine(bundleURL: fixture.bundleURL)

        #expect(calls.bundleValidationCount == 0)
        #expect(calls.appleCount == 0)
        #expect(calls.productCount == 0)
    }

    @Test
    func internalTracerArmDoesNotConstructAnEngine() throws {
        let catalog = releaseApprovedCatalog()
        let calls = ReleaseFactoryCalls()
        let prepared = try calls.bootstrap(trustedCatalog: catalog)
            .prepareInternalTracerEngine(
                policyData: releasePolicyData(
                    runtimeEngine: .productManaged,
                    catalogDigest: catalog.canonicalSHA256
                )
            )

        try prepared.arm(
            sessionID: "session-1",
            generation: 7,
            ticket: "ticket-1"
        )

        #expect(calls.appleCount == 0)
        #expect(calls.productCount == 0)
    }

    @Test
    func acknowledgementBeforeArmCannotLoad() throws {
        let catalog = releaseApprovedCatalog()
        let calls = ReleaseFactoryCalls()
        let prepared = try calls.bootstrap(trustedCatalog: catalog)
            .prepareInternalTracerEngine(
                policyData: releasePolicyData(
                    runtimeEngine: .productManaged,
                    catalogDigest: catalog.canonicalSHA256
                )
            )

        #expect(throws: VoiceHelperInternalTracerLoadError.invalidState) {
            _ = try prepared.completeBeginBoundaryAcknowledgement(
                sessionID: "session-1",
                generation: 7,
                ticket: "ticket-1"
            )
        }
        #expect(throws: VoiceHelperInternalTracerLoadError.invalidState) {
            try prepared.arm(
                sessionID: "session-1",
                generation: 7,
                ticket: "ticket-1"
            )
        }
        #expect(calls.appleCount == 0)
        #expect(calls.productCount == 0)
    }

    @Test
    func matchingBeginBoundaryAcknowledgementLoadsTheSelectedEngine() throws {
        let catalog = releaseApprovedCatalog()
        let calls = ReleaseFactoryCalls()
        let prepared = try calls.bootstrap(trustedCatalog: catalog)
            .prepareInternalTracerEngine(
                policyData: releasePolicyData(
                    runtimeEngine: .productManaged,
                    catalogDigest: catalog.canonicalSHA256
                )
            )
        try prepared.arm(
            sessionID: "session-1",
            generation: 7,
            ticket: "ticket-1"
        )

        _ = try prepared.completeBeginBoundaryAcknowledgement(
            sessionID: "session-1",
            generation: 7,
            ticket: "ticket-1"
        )

        #expect(calls.appleCount == 0)
        #expect(calls.productCount == 1)
    }

    @Test
    func staleBeginBoundaryAcknowledgementFailsClosedBeforeLoading() throws {
        let catalog = releaseApprovedCatalog()
        let staleAuthorizations: [(String, UInt64, String)] = [
            ("stale-session", 7, "ticket-1"),
            ("session-1", 8, "ticket-1"),
            ("session-1", 7, "stale-ticket"),
        ]

        for stale in staleAuthorizations {
            let calls = ReleaseFactoryCalls()
            let prepared = try calls.bootstrap(trustedCatalog: catalog)
                .prepareInternalTracerEngine(
                    policyData: releasePolicyData(
                        runtimeEngine: .productManaged,
                        catalogDigest: catalog.canonicalSHA256
                    )
                )
            try prepared.arm(
                sessionID: "session-1",
                generation: 7,
                ticket: "ticket-1"
            )

            #expect(
                throws: VoiceHelperInternalTracerLoadError
                    .authorizationMismatch
            ) {
                _ = try prepared.completeBeginBoundaryAcknowledgement(
                    sessionID: stale.0,
                    generation: stale.1,
                    ticket: stale.2
                )
            }
            #expect(
                throws: VoiceHelperInternalTracerLoadError.invalidState
            ) {
                _ = try prepared.completeBeginBoundaryAcknowledgement(
                    sessionID: "session-1",
                    generation: 7,
                    ticket: "ticket-1"
                )
            }
            #expect(calls.appleCount == 0)
            #expect(calls.productCount == 0)
        }
    }

    @Test
    func duplicateArmFailsClosedBeforeLoading() throws {
        let catalog = releaseApprovedCatalog()
        let calls = ReleaseFactoryCalls()
        let prepared = try calls.bootstrap(trustedCatalog: catalog)
            .prepareInternalTracerEngine(
                policyData: releasePolicyData(
                    runtimeEngine: .productManaged,
                    catalogDigest: catalog.canonicalSHA256
                )
            )
        try prepared.arm(
            sessionID: "session-1",
            generation: 7,
            ticket: "ticket-1"
        )

        #expect(throws: VoiceHelperInternalTracerLoadError.invalidState) {
            try prepared.arm(
                sessionID: "session-1",
                generation: 7,
                ticket: "ticket-1"
            )
        }
        #expect(throws: VoiceHelperInternalTracerLoadError.invalidState) {
            _ = try prepared.completeBeginBoundaryAcknowledgement(
                sessionID: "session-1",
                generation: 7,
                ticket: "ticket-1"
            )
        }
        #expect(calls.appleCount == 0)
        #expect(calls.productCount == 0)
    }

    @Test
    func duplicateBeginBoundaryAcknowledgementCannotLoadTwice() throws {
        let catalog = releaseApprovedCatalog()
        let calls = ReleaseFactoryCalls()
        let prepared = try calls.bootstrap(trustedCatalog: catalog)
            .prepareInternalTracerEngine(
                policyData: releasePolicyData(
                    runtimeEngine: .productManaged,
                    catalogDigest: catalog.canonicalSHA256
                )
            )
        try prepared.arm(
            sessionID: "session-1",
            generation: 7,
            ticket: "ticket-1"
        )
        _ = try prepared.completeBeginBoundaryAcknowledgement(
            sessionID: "session-1",
            generation: 7,
            ticket: "ticket-1"
        )

        #expect(throws: VoiceHelperInternalTracerLoadError.invalidState) {
            _ = try prepared.completeBeginBoundaryAcknowledgement(
                sessionID: "session-1",
                generation: 7,
                ticket: "ticket-1"
            )
        }
        #expect(calls.appleCount == 0)
        #expect(calls.productCount == 1)
    }

    @Test
    func concurrentMatchingAcknowledgementsLoadExactlyOnce() throws {
        let catalog = releaseApprovedCatalog()
        let calls = ReleaseFactoryCalls()
        let prepared = try calls.bootstrap(trustedCatalog: catalog)
            .prepareInternalTracerEngine(
                policyData: releasePolicyData(
                    runtimeEngine: .productManaged,
                    catalogDigest: catalog.canonicalSHA256
                )
            )
        try prepared.arm(
            sessionID: "session-1",
            generation: 7,
            ticket: "ticket-1"
        )
        let outcomes = ConcurrentLoadOutcomes()

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            do {
                _ = try prepared.completeBeginBoundaryAcknowledgement(
                    sessionID: "session-1",
                    generation: 7,
                    ticket: "ticket-1"
                )
                outcomes.recordSuccess()
            } catch let error as VoiceHelperInternalTracerLoadError {
                outcomes.recordFailure(error)
            } catch {
                outcomes.recordUnexpectedFailure()
            }
        }

        #expect(outcomes.successCount == 1)
        #expect(outcomes.failures == Array(
            repeating: VoiceHelperInternalTracerLoadError.invalidState,
            count: 31
        ))
        #expect(outcomes.unexpectedFailureCount == 0)
        #expect(calls.appleCount == 0)
        #expect(calls.productCount == 1)
    }

    @Test
    func selectedFactoryExecutesOutsideTheStateLock() throws {
        let catalog = releaseApprovedCatalog()
        let reference = PreparedEngineReference()
        var productCount = 0
        let bootstrap = VoiceHelperReleaseBootstrap(
            trustedCatalog: catalog,
            bundleValidator: { _ in },
            appleFactory: { UnavailableVoiceEngine() },
            productFactory: {
                productCount += 1
                reference.prepared?.cancel()
                return UnavailableVoiceEngine()
            }
        )
        let prepared = try bootstrap.prepareInternalTracerEngine(
            policyData: releasePolicyData(
                runtimeEngine: .productManaged,
                catalogDigest: catalog.canonicalSHA256
            )
        )
        reference.prepared = prepared
        try prepared.arm(
            sessionID: "session-1",
            generation: 7,
            ticket: "ticket-1"
        )

        #expect(throws: VoiceHelperInternalTracerLoadError.invalidState) {
            _ = try prepared.completeBeginBoundaryAcknowledgement(
                sessionID: "session-1",
                generation: 7,
                ticket: "ticket-1"
            )
        }

        #expect(productCount == 1)
    }

    @Test
    func selectedFactoryFailureHasOneFixedErrorAndNoFallback() throws {
        let catalog = releaseApprovedCatalog()
        var appleCount = 0
        var productCount = 0
        let bootstrap = VoiceHelperReleaseBootstrap(
            trustedCatalog: catalog,
            bundleValidator: { _ in },
            appleFactory: {
                appleCount += 1
                return UnavailableVoiceEngine()
            },
            productFactory: {
                productCount += 1
                throw ReleaseBootstrapTestFailure.productFactoryFailed
            }
        )
        let prepared = try bootstrap.prepareInternalTracerEngine(
            policyData: releasePolicyData(
                runtimeEngine: .productManaged,
                catalogDigest: catalog.canonicalSHA256
            )
        )
        try prepared.arm(
            sessionID: "session-1",
            generation: 7,
            ticket: "ticket-1"
        )

        #expect(
            throws: VoiceHelperInternalTracerLoadError.engineLoadFailed
        ) {
            _ = try prepared.completeBeginBoundaryAcknowledgement(
                sessionID: "session-1",
                generation: 7,
                ticket: "ticket-1"
            )
        }
        #expect(throws: VoiceHelperInternalTracerLoadError.invalidState) {
            _ = try prepared.completeBeginBoundaryAcknowledgement(
                sessionID: "session-1",
                generation: 7,
                ticket: "ticket-1"
            )
        }
        #expect(appleCount == 0)
        #expect(productCount == 1)
    }

    @Test
    func cancellationBeforeLoadIsTerminal() throws {
        try expectInternalTracerTermination { prepared in
            prepared.cancel()
        }
    }

    @Test
    func disconnectBeforeLoadIsTerminal() throws {
        try expectInternalTracerTermination { prepared in
            prepared.disconnect()
        }
    }

    @Test
    func timeoutBeforeLoadIsTerminal() throws {
        try expectInternalTracerTermination { prepared in
            prepared.timeout()
        }
    }

    @Test
    func cancellationDuringLoadDoesNotPublishTheConstructedEngine() throws {
        try expectInternalTracerTerminationDuringLoad { prepared in
            prepared.cancel()
        }
    }

    @Test
    func disconnectDuringLoadDoesNotPublishTheConstructedEngine() throws {
        try expectInternalTracerTerminationDuringLoad { prepared in
            prepared.disconnect()
        }
    }

    @Test
    func timeoutDuringLoadDoesNotPublishTheConstructedEngine() throws {
        try expectInternalTracerTerminationDuringLoad { prepared in
            prepared.timeout()
        }
    }

    @Test
    func symlinkPolicyIsRejectedBeforeEitherFactory() throws {
        let catalog = VoiceASRTrustedArtifactCatalog.production
        let fixture = try ReleaseBundleFixture(policyData: releasePolicyData(
            runtimeEngine: .appleSpeech,
            catalogDigest: catalog.canonicalSHA256
        ))
        defer { fixture.remove() }
        try fixture.replacePolicyWithSymlink()
        let calls = ReleaseFactoryCalls()
        var rejected = false

        do {
            _ = try calls.bootstrap(trustedCatalog: catalog).makeEngine(
                bundleURL: fixture.bundleURL
            )
        } catch {
            rejected = true
        }

        #expect(rejected)
        #expect(calls.appleCount == 0)
        #expect(calls.productCount == 0)
        #expect(calls.bundleValidationCount == 1)
    }

    @Test
    func missingPolicyFailsBeforeEitherFactory() throws {
        let catalog = VoiceASRTrustedArtifactCatalog.production
        let fixture = try ReleaseBundleFixture(policyData: releasePolicyData(
            runtimeEngine: .appleSpeech,
            catalogDigest: catalog.canonicalSHA256
        ))
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.policyURL)
        let calls = ReleaseFactoryCalls()

        #expect(throws: VoiceHelperReleaseBootstrapError.self) {
            _ = try calls.bootstrap(trustedCatalog: catalog).makeEngine(
                bundleURL: fixture.bundleURL
            )
        }
        #expect(calls.appleCount == 0)
        #expect(calls.productCount == 0)
        #expect(calls.bundleValidationCount == 1)
    }

    @Test
    func invalidPolicyFailsBeforeEitherFactory() throws {
        let catalog = VoiceASRTrustedArtifactCatalog.production
        let fixture = try ReleaseBundleFixture(policyData: Data())
        defer { fixture.remove() }
        let calls = ReleaseFactoryCalls()

        #expect(throws: VoiceReleasePolicyError.invalidXML) {
            _ = try calls.bootstrap(trustedCatalog: catalog).makeEngine(
                bundleURL: fixture.bundleURL
            )
        }
        #expect(calls.appleCount == 0)
        #expect(calls.productCount == 0)
        #expect(calls.bundleValidationCount == 1)
    }

    @Test
    func bundleValidationFailsBeforePolicyReadAndEitherFactory() {
        let catalog = VoiceASRTrustedArtifactCatalog.production
        let calls = ReleaseFactoryCalls()
        let bootstrap = calls.bootstrap(
            trustedCatalog: catalog,
            bundleValidator: { _ in
                throw ReleaseBootstrapTestFailure.invalidBundleSeal
            }
        )
        let missingBundle = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        #expect(throws: ReleaseBootstrapTestFailure.invalidBundleSeal) {
            _ = try bootstrap.makeEngine(bundleURL: missingBundle)
        }
        #expect(calls.appleCount == 0)
        #expect(calls.productCount == 0)
        #expect(calls.bundleValidationCount == 0)
    }

    private func expectInternalTracerTermination(
        _ terminate: (VoiceHelperInternalTracerPreparedEngine) -> Void
    ) throws {
        let catalog = releaseApprovedCatalog()
        let preparedCalls = ReleaseFactoryCalls()
        let prepared = try preparedCalls.bootstrap(trustedCatalog: catalog)
            .prepareInternalTracerEngine(
                policyData: releasePolicyData(
                    runtimeEngine: .productManaged,
                    catalogDigest: catalog.canonicalSHA256
                )
            )
        terminate(prepared)
        #expect(throws: VoiceHelperInternalTracerLoadError.invalidState) {
            try prepared.arm(
                sessionID: "session-1",
                generation: 7,
                ticket: "ticket-1"
            )
        }
        #expect(preparedCalls.productCount == 0)

        let armedCalls = ReleaseFactoryCalls()
        let armed = try armedCalls.bootstrap(trustedCatalog: catalog)
            .prepareInternalTracerEngine(
                policyData: releasePolicyData(
                    runtimeEngine: .productManaged,
                    catalogDigest: catalog.canonicalSHA256
                )
            )
        try armed.arm(
            sessionID: "session-1",
            generation: 7,
            ticket: "ticket-1"
        )
        terminate(armed)
        #expect(throws: VoiceHelperInternalTracerLoadError.invalidState) {
            _ = try armed.completeBeginBoundaryAcknowledgement(
                sessionID: "session-1",
                generation: 7,
                ticket: "ticket-1"
            )
        }
        #expect(armedCalls.productCount == 0)
    }

    private func expectInternalTracerTerminationDuringLoad(
        _ terminate: (VoiceHelperInternalTracerPreparedEngine) -> Void
    ) throws {
        let catalog = releaseApprovedCatalog()
        let factory = BlockingReleaseEngineFactory()
        let bootstrap = VoiceHelperReleaseBootstrap(
            trustedCatalog: catalog,
            bundleValidator: { _ in },
            appleFactory: { UnavailableVoiceEngine() },
            productFactory: { try factory.makeEngine() }
        )
        let prepared = try bootstrap.prepareInternalTracerEngine(
            policyData: releasePolicyData(
                runtimeEngine: .productManaged,
                catalogDigest: catalog.canonicalSHA256
            )
        )
        try prepared.arm(
            sessionID: "session-1",
            generation: 7,
            ticket: "ticket-1"
        )
        let outcomes = ConcurrentLoadOutcomes()
        let acknowledgement = DispatchGroup()
        acknowledgement.enter()
        DispatchQueue.global().async {
            defer { acknowledgement.leave() }
            do {
                _ = try prepared.completeBeginBoundaryAcknowledgement(
                    sessionID: "session-1",
                    generation: 7,
                    ticket: "ticket-1"
                )
                outcomes.recordSuccess()
            } catch let error as VoiceHelperInternalTracerLoadError {
                outcomes.recordFailure(error)
            } catch {
                outcomes.recordUnexpectedFailure()
            }
        }

        #expect(factory.waitUntilStarted())
        terminate(prepared)
        factory.resume()
        #expect(
            acknowledgement.wait(timeout: .now() + 2) == .success
        )
        #expect(factory.invocationCount == 1)
        #expect(outcomes.successCount == 0)
        #expect(
            outcomes.failures
                == [VoiceHelperInternalTracerLoadError.invalidState]
        )
        #expect(outcomes.unexpectedFailureCount == 0)
    }
}

private final class ReleaseFactoryCalls {
    private(set) var bundleValidationCount = 0
    private(set) var appleCount = 0
    private(set) var productCount = 0

    func bootstrap(
        trustedCatalog: VoiceASRTrustedArtifactCatalog,
        bundleValidator: ((URL) throws -> Void)? = nil
    ) -> VoiceHelperReleaseBootstrap {
        let validate = bundleValidator ?? { _ in
            self.bundleValidationCount += 1
        }
        return VoiceHelperReleaseBootstrap(
            trustedCatalog: trustedCatalog,
            bundleValidator: validate,
            appleFactory: {
                self.appleCount += 1
                return UnavailableVoiceEngine()
            },
            productFactory: {
                self.productCount += 1
                return UnavailableVoiceEngine()
            }
        )
    }
}

/// Test-only adapter that keeps the prepared-loader state-machine tests
/// independent from the production target after the tracer gate moved into
/// its own module.
private extension VoiceHelperReleaseBootstrap {
    func prepareInternalTracerEngine(
        policyData: Data
    ) throws -> VoiceHelperInternalTracerPreparedEngine {
        VoiceHelperInternalTracerPreparedEngine(
            loader: { try self.makeEngine(policyData: policyData) }
        )
    }

    func prepareInternalTracerEngine(
        bundleURL: URL
    ) throws -> VoiceHelperInternalTracerPreparedEngine {
        VoiceHelperInternalTracerPreparedEngine(
            loader: { try self.makeEngine(bundleURL: bundleURL) }
        )
    }
}

private enum ReleaseBootstrapTestFailure: Error {
    case blockingFactoryTimedOut
    case invalidBundleSeal
    case productFactoryFailed
}

private final class ConcurrentLoadOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var successes = 0
    private var recordedFailures: [VoiceHelperInternalTracerLoadError] = []
    private var unexpectedFailures = 0

    var successCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return successes
    }

    var failures: [VoiceHelperInternalTracerLoadError] {
        lock.lock()
        defer { lock.unlock() }
        return recordedFailures.sorted { String(describing: $0) < String(describing: $1) }
    }

    var unexpectedFailureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return unexpectedFailures
    }

    func recordSuccess() {
        lock.lock()
        successes += 1
        lock.unlock()
    }

    func recordFailure(_ error: VoiceHelperInternalTracerLoadError) {
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

private final class PreparedEngineReference {
    var prepared: VoiceHelperInternalTracerPreparedEngine?
}

private final class BlockingReleaseEngineFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var invocations = 0

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }

    func makeEngine() throws -> any VoiceDictationEngine {
        lock.lock()
        invocations += 1
        lock.unlock()
        started.signal()
        guard release.wait(timeout: .now() + 2) == .success else {
            throw ReleaseBootstrapTestFailure.blockingFactoryTimedOut
        }
        return UnavailableVoiceEngine()
    }

    func waitUntilStarted() -> Bool {
        started.wait(timeout: .now() + 2) == .success
    }

    func resume() {
        release.signal()
    }
}

private struct ReleaseBundleFixture {
    let root: URL
    let bundleURL: URL
    let policyURL: URL

    init(policyData: Data) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rimeai-release-bootstrap-\(UUID().uuidString)",
            isDirectory: true
        )
        bundleURL = root.appendingPathComponent(
            "RimeAIVoiceHelper.app",
            isDirectory: true
        )
        let resources = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        policyURL = resources.appendingPathComponent(
            "VoiceReleasePolicy.plist",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )
        try policyData.write(to: policyURL)
    }

    func replacePolicyWithSymlink() throws {
        let validPolicyData = try Data(contentsOf: policyURL)
        let target = root.appendingPathComponent(
            "outside-policy.plist",
            isDirectory: false
        )
        try validPolicyData.write(to: target)
        try FileManager.default.removeItem(at: policyURL)
        try FileManager.default.createSymbolicLink(
            at: policyURL,
            withDestinationURL: target
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func releaseApprovedCatalog() -> VoiceASRTrustedArtifactCatalog {
    VoiceASRTrustedArtifactCatalog(approvals: [
        VoiceASRTrustedArtifactApproval(
            artifactID: VoiceASRArtifactID(
                rawValue: "approved-voice-model-v1"
            )!,
            contentSHA256: String(repeating: "a", count: 64),
            adapterID: "sherpa-onnx",
            adapterVersion: "1.13.6",
            adapterABIVersion: 1,
            modelID: "zipformer-zh-en",
            modelRevision: "2026-08-20",
            modelFormat: .onnx,
            modelQuantization: .int8,
            licenseSPDXID: "Apache-2.0",
            licensePath: "licenses/LICENSE.txt",
            noticePath: "licenses/NOTICE.txt",
            sourceURL: "https://example.com/models/approved-voice-model-v1",
            redistributionApproved: true,
            releaseEvidence: VoiceASRReleaseEvidence(
                sourceReviewID: "source-review-2026-08-21",
                modelRightsReviewID: "model-rights-review-2026-08-21",
                redistributionReviewID:
                    "redistribution-review-2026-08-21",
                qualityReportSHA256: String(repeating: "d", count: 64)
            )
        ),
    ])
}

private func releasePolicyData(
    runtimeEngine: VoiceReleasePolicy.RuntimeEngine,
    catalogDigest: String
) -> Data {
    let engineIdentifier: String
    let assetManagement: String
    let releaseEligible: String
    let eligibilityReason: String
    switch runtimeEngine {
    case .appleSpeech:
        engineIdentifier = "apple-speech-ondevice"
        assetManagement = "system_managed"
        releaseEligible = "<false/>"
        eligibilityReason = "macos14_15_system_managed_probe_only"
    case .productManaged:
        engineIdentifier = "sherpa-onnx"
        assetManagement = "product_managed"
        releaseEligible = "<true/>"
        eligibilityReason = "approved_local_product_cohort"
    }

    return Data(
        """
        <plist version="1.0">
        <dict>
          <key>SchemaVersion</key>
          <integer>2</integer>
          <key>RuntimeEngine</key>
          <string>\(runtimeEngine.rawValue)</string>
          <key>EngineIdentifier</key>
          <string>\(engineIdentifier)</string>
          <key>AssetManagement</key>
          <string>\(assetManagement)</string>
          <key>ReleaseEligible</key>
          \(releaseEligible)
          <key>EligibilityReason</key>
          <string>\(eligibilityReason)</string>
          <key>TrustedCatalogSHA256</key>
          <string>\(catalogDigest)</string>
        </dict>
        </plist>
        """.utf8
    )
}
