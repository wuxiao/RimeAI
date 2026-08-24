import Dispatch
import Foundation
import RimeAIVoicePerformanceControlCore
import Testing
@testable import RimeAIInputCore
@testable import RimeAIVoiceHelperEngine
@testable import RimeAIVoicePerformanceHelperBridge

@Suite(.serialized)
struct VoiceHelperInternalTracerControlBridgeTests {
    @Test
    func loadEngineEmitsStartedWithoutConstructingEngine() throws {
        let factory = TracerBridgeEngineFactory {
            UnavailableVoiceEngine()
        }
        let bridge = try makeTracerBridge(factory: factory)
        let session = try tracerSession(trial: 7)
        let ticket = try tracerNonce("2")

        let response = try bridge.receiveLoadEngine(.loadEngine(
            sequence: 1,
            sessionID: session,
            trial: 7,
            loadTicket: ticket
        ))

        #expect(response == .loadStarted(
            sequence: 1,
            sessionID: session,
            replyTo: 1,
            trial: 7,
            loadTicket: ticket
        ))
        #expect(factory.invocationCount == 0)
        #expect(!bridge.authenticatedProductionDriver)
    }

    @Test
    func matchingAcknowledgementLoadsAndPublishesExactProductSummary()
        throws
    {
        let descriptor = tracerProductDescriptor()
        let factory = TracerBridgeEngineFactory {
            TracerProductEngine(descriptor: descriptor)
        }
        let bridge = try makeTracerBridge(factory: factory)
        let session = try tracerSession(trial: 7)
        let ticket = try tracerNonce("2")
        _ = try bridge.receiveLoadEngine(.loadEngine(
            sequence: 1,
            sessionID: session,
            trial: 7,
            loadTicket: ticket
        ))

        let result = try bridge.receiveLoadStartedAcknowledgement(
            .loadStartedAck(
                sequence: 2,
                sessionID: session,
                replyTo: 1,
                trial: 7,
                loadTicket: ticket
            )
        )

        #expect(result.engine.descriptor == descriptor)
        #expect(result.frame == .loadReady(
            sequence: 2,
            sessionID: session,
            replyTo: 2,
            trial: 7,
            loadTicket: ticket,
            engine: try tracerExpectedEngineSummary()
        ))
        #expect(factory.invocationCount == 1)
        #expect(!result.authenticatedProductionDriver)
    }

    @Test
    func cancellationAfterStartedPreventsFactoryInvocation() throws {
        let factory = TracerBridgeEngineFactory {
            TracerProductEngine(descriptor: tracerProductDescriptor())
        }
        let bridge = try makeTracerBridge(factory: factory)
        let session = try tracerSession(trial: 7)
        let ticket = try tracerNonce("2")
        _ = try bridge.receiveLoadEngine(.loadEngine(
            sequence: 1,
            sessionID: session,
            trial: 7,
            loadTicket: ticket
        ))

        bridge.cancel()

        #expect(
            throws: VoiceHelperInternalTracerControlBridgeError.invalidState
        ) {
            _ = try bridge.receiveLoadStartedAcknowledgement(
                .loadStartedAck(
                    sequence: 2,
                    sessionID: session,
                    replyTo: 1,
                    trial: 7,
                    loadTicket: ticket
                )
            )
        }
        #expect(factory.invocationCount == 0)
    }

    @Test
    func disconnectAfterStartedPreventsFactoryInvocation() throws {
        let factory = TracerBridgeEngineFactory {
            TracerProductEngine(descriptor: tracerProductDescriptor())
        }
        let bridge = try makeTracerBridge(factory: factory)
        let session = try tracerSession(trial: 7)
        let ticket = try tracerNonce("2")
        _ = try bridge.receiveLoadEngine(.loadEngine(
            sequence: 1,
            sessionID: session,
            trial: 7,
            loadTicket: ticket
        ))

        bridge.disconnect()

        #expect(
            throws: VoiceHelperInternalTracerControlBridgeError.invalidState
        ) {
            _ = try bridge.receiveLoadStartedAcknowledgement(
                .loadStartedAck(
                    sequence: 2,
                    sessionID: session,
                    replyTo: 1,
                    trial: 7,
                    loadTicket: ticket
                )
            )
        }
        #expect(factory.invocationCount == 0)
    }

    @Test
    func timeoutAfterStartedPreventsFactoryInvocation() throws {
        let factory = TracerBridgeEngineFactory {
            TracerProductEngine(descriptor: tracerProductDescriptor())
        }
        let bridge = try makeTracerBridge(factory: factory)
        let session = try tracerSession(trial: 7)
        let ticket = try tracerNonce("2")
        _ = try bridge.receiveLoadEngine(.loadEngine(
            sequence: 1,
            sessionID: session,
            trial: 7,
            loadTicket: ticket
        ))

        bridge.timeout()

        #expect(
            throws: VoiceHelperInternalTracerControlBridgeError.invalidState
        ) {
            _ = try bridge.receiveLoadStartedAcknowledgement(
                .loadStartedAck(
                    sequence: 2,
                    sessionID: session,
                    replyTo: 1,
                    trial: 7,
                    loadTicket: ticket
                )
            )
        }
        #expect(factory.invocationCount == 0)
    }

    @Test
    func malformedLoadEngineIsTerminalWithoutFactoryInvocation() throws {
        let session = try tracerSession(trial: 7)
        let ticket = try tracerNonce("2")
        let malformedFrames: [PerformanceControlWireFrame] = [
            .loadEngine(
                sequence: 2,
                sessionID: session,
                trial: 7,
                loadTicket: ticket
            ),
            .loadEngine(
                sequence: 1,
                sessionID: session,
                trial: 0,
                loadTicket: ticket
            ),
            .loadEngine(
                sequence: 1,
                sessionID: session,
                trial: 33,
                loadTicket: ticket
            ),
            .loadStartedAck(
                sequence: 2,
                sessionID: session,
                replyTo: 1,
                trial: 7,
                loadTicket: ticket
            ),
        ]

        for malformed in malformedFrames {
            let factory = TracerBridgeEngineFactory {
                TracerProductEngine(descriptor: tracerProductDescriptor())
            }
            let bridge = try makeTracerBridge(factory: factory)

            #expect(
                throws: VoiceHelperInternalTracerControlBridgeError
                    .invalidFrame
            ) {
                _ = try bridge.receiveLoadEngine(malformed)
            }
            #expect(
                throws: VoiceHelperInternalTracerControlBridgeError
                    .invalidState
            ) {
                _ = try bridge.receiveLoadEngine(.loadEngine(
                    sequence: 1,
                    sessionID: session,
                    trial: 7,
                    loadTicket: ticket
                ))
            }
            #expect(factory.invocationCount == 0)
        }
    }

    @Test
    func loadSessionMustBeDerivedFromTheSealedControlNonce() throws {
        let factory = TracerBridgeEngineFactory {
            TracerProductEngine(descriptor: tracerProductDescriptor())
        }
        let bridge = try makeTracerBridge(factory: factory)
        #expect(
            throws: VoiceHelperInternalTracerControlBridgeError
                .bindingMismatch
        ) {
            _ = try bridge.receiveLoadEngine(.loadEngine(
                sequence: 1,
                sessionID: try tracerNonce("4"),
                trial: 7,
                loadTicket: try tracerNonce("2")
            ))
        }
        #expect(factory.invocationCount == 0)
        #expect(
            throws: VoiceHelperInternalTracerControlBridgeError.invalidState
        ) {
            _ = try bridge.receiveLoadEngine(.loadEngine(
                sequence: 1,
                sessionID: try tracerSession(trial: 7),
                trial: 7,
                loadTicket: try tracerNonce("2")
            ))
        }
    }

    @Test
    func acknowledgementBindingMismatchIsTerminalBeforeLoading() throws {
        let session = try tracerSession(trial: 7)
        let ticket = try tracerNonce("2")
        let staleAcknowledgements: [PerformanceControlWireFrame] = [
            .loadStartedAck(
                sequence: 2,
                sessionID: try tracerNonce("4"),
                replyTo: 1,
                trial: 7,
                loadTicket: ticket
            ),
            .loadStartedAck(
                sequence: 2,
                sessionID: session,
                replyTo: 1,
                trial: 8,
                loadTicket: ticket
            ),
            .loadStartedAck(
                sequence: 2,
                sessionID: session,
                replyTo: 1,
                trial: 7,
                loadTicket: try tracerNonce("5")
            ),
        ]

        for stale in staleAcknowledgements {
            let factory = TracerBridgeEngineFactory {
                TracerProductEngine(descriptor: tracerProductDescriptor())
            }
            let bridge = try makeTracerBridge(factory: factory)
            _ = try bridge.receiveLoadEngine(.loadEngine(
                sequence: 1,
                sessionID: session,
                trial: 7,
                loadTicket: ticket
            ))

            #expect(
                throws: VoiceHelperInternalTracerControlBridgeError
                    .bindingMismatch
            ) {
                _ = try bridge.receiveLoadStartedAcknowledgement(stale)
            }
            #expect(
                throws: VoiceHelperInternalTracerControlBridgeError
                    .invalidState
            ) {
                _ = try bridge.receiveLoadStartedAcknowledgement(
                    .loadStartedAck(
                        sequence: 2,
                        sessionID: session,
                        replyTo: 1,
                        trial: 7,
                        loadTicket: ticket
                    )
                )
            }
            #expect(factory.invocationCount == 0)
        }
    }

    @Test
    func malformedAcknowledgementIsTerminalBeforeLoading() throws {
        let session = try tracerSession(trial: 7)
        let ticket = try tracerNonce("2")
        let malformedAcknowledgements: [PerformanceControlWireFrame] = [
            .loadStartedAck(
                sequence: 1,
                sessionID: session,
                replyTo: 1,
                trial: 7,
                loadTicket: ticket
            ),
            .loadStartedAck(
                sequence: 2,
                sessionID: session,
                replyTo: 2,
                trial: 7,
                loadTicket: ticket
            ),
            .loadEngine(
                sequence: 1,
                sessionID: session,
                trial: 7,
                loadTicket: ticket
            ),
        ]

        for malformed in malformedAcknowledgements {
            let factory = TracerBridgeEngineFactory {
                TracerProductEngine(descriptor: tracerProductDescriptor())
            }
            let bridge = try makeTracerBridge(factory: factory)
            _ = try bridge.receiveLoadEngine(.loadEngine(
                sequence: 1,
                sessionID: session,
                trial: 7,
                loadTicket: ticket
            ))

            #expect(
                throws: VoiceHelperInternalTracerControlBridgeError
                    .invalidFrame
            ) {
                _ = try bridge.receiveLoadStartedAcknowledgement(malformed)
            }
            #expect(factory.invocationCount == 0)
        }
    }

    @Test
    func duplicateLoadEngineTerminatesTheSingleGenerationTrial() throws {
        let factory = TracerBridgeEngineFactory {
            TracerProductEngine(descriptor: tracerProductDescriptor())
        }
        let bridge = try makeTracerBridge(factory: factory)
        let session = try tracerSession(trial: 7)
        let ticket = try tracerNonce("2")
        let loadEngine = PerformanceControlWireFrame.loadEngine(
            sequence: 1,
            sessionID: session,
            trial: 7,
            loadTicket: ticket
        )
        _ = try bridge.receiveLoadEngine(loadEngine)

        #expect(
            throws: VoiceHelperInternalTracerControlBridgeError.invalidState
        ) {
            _ = try bridge.receiveLoadEngine(loadEngine)
        }
        #expect(
            throws: VoiceHelperInternalTracerControlBridgeError.invalidState
        ) {
            _ = try bridge.receiveLoadStartedAcknowledgement(
                .loadStartedAck(
                    sequence: 2,
                    sessionID: session,
                    replyTo: 1,
                    trial: 7,
                    loadTicket: ticket
                )
            )
        }
        #expect(factory.invocationCount == 0)
    }

    @Test
    func nonProductDescriptorIsNeverPublishedOrRetried() throws {
        let factory = TracerBridgeEngineFactory {
            UnavailableVoiceEngine()
        }
        let bridge = try makeTracerBridge(factory: factory)
        let session = try tracerSession(trial: 7)
        let ticket = try tracerNonce("2")
        _ = try bridge.receiveLoadEngine(.loadEngine(
            sequence: 1,
            sessionID: session,
            trial: 7,
            loadTicket: ticket
        ))

        #expect(
            throws: VoiceHelperInternalTracerControlBridgeError
                .invalidProductDescriptor
        ) {
            _ = try bridge.receiveLoadStartedAcknowledgement(
                .loadStartedAck(
                    sequence: 2,
                    sessionID: session,
                    replyTo: 1,
                    trial: 7,
                    loadTicket: ticket
                )
            )
        }
        #expect(
            throws: VoiceHelperInternalTracerControlBridgeError.invalidState
        ) {
            _ = try bridge.receiveLoadEngine(.loadEngine(
                sequence: 1,
                sessionID: session,
                trial: 8,
                loadTicket: try tracerNonce("6")
            ))
        }
        #expect(factory.invocationCount == 1)
        #expect(!bridge.authenticatedProductionDriver)
    }

    @Test
    func knownArtifactFailureIsTerminalWithoutFallback() throws {
        let factory = TracerBridgeEngineFactory {
            throw VoiceASRArtifactError.missingFile("encoder.onnx")
        }
        let bridge = try makeTracerBridge(factory: factory)
        let session = try tracerSession(trial: 7)
        let ticket = try tracerNonce("2")
        _ = try bridge.receiveLoadEngine(.loadEngine(
            sequence: 1,
            sessionID: session,
            trial: 7,
            loadTicket: ticket
        ))

        #expect(
            throws: VoiceHelperInternalTracerControlBridgeError
                .engineLoadFailed
        ) {
            _ = try bridge.receiveLoadStartedAcknowledgement(
                .loadStartedAck(
                    sequence: 2,
                    sessionID: session,
                    replyTo: 1,
                    trial: 7,
                    loadTicket: ticket
                )
            )
        }
        #expect(
            throws: VoiceHelperInternalTracerControlBridgeError.invalidState
        ) {
            _ = try bridge.receiveLoadStartedAcknowledgement(
                .loadStartedAck(
                    sequence: 2,
                    sessionID: session,
                    replyTo: 1,
                    trial: 7,
                    loadTicket: ticket
                )
            )
        }
        #expect(factory.invocationCount == 1)
    }

    @Test
    func opaqueFactoryFailureIsTerminalAndPreserved() throws {
        let unexpected = TracerBridgeUnexpectedError(
            description: "prepared-loader-secret-b72e"
        )
        let factory = TracerBridgeEngineFactory { throw unexpected }
        let bridge = try makeTracerBridge(factory: factory)
        let session = try tracerSession(trial: 7)
        let ticket = try tracerNonce("2")
        _ = try bridge.receiveLoadEngine(.loadEngine(
            sequence: 1,
            sessionID: session,
            trial: 7,
            loadTicket: ticket
        ))
        let acknowledgement = PerformanceControlWireFrame.loadStartedAck(
            sequence: 2,
            sessionID: session,
            replyTo: 1,
            trial: 7,
            loadTicket: ticket
        )

        #expect(throws: unexpected) {
            _ = try bridge.receiveLoadStartedAcknowledgement(acknowledgement)
        }
        #expect(
            throws: VoiceHelperInternalTracerControlBridgeError.invalidState
        ) {
            _ = try bridge.receiveLoadStartedAcknowledgement(acknowledgement)
        }
        #expect(factory.invocationCount == 1)
    }

    @Test
    func disconnectDuringBlockedLoadDoesNotPublishConstructedEngine()
        throws
    {
        let factoryStarted = DispatchSemaphore(value: 0)
        let releaseFactory = DispatchSemaphore(value: 0)
        let factory = TracerBridgeEngineFactory {
            factoryStarted.signal()
            guard releaseFactory.wait(timeout: .now() + 2) == .success else {
                throw TracerBridgeTestError.factoryTimedOut
            }
            return TracerProductEngine(
                descriptor: tracerProductDescriptor()
            )
        }
        let bridge = try makeTracerBridge(factory: factory)
        let session = try tracerSession(trial: 7)
        let ticket = try tracerNonce("2")
        _ = try bridge.receiveLoadEngine(.loadEngine(
            sequence: 1,
            sessionID: session,
            trial: 7,
            loadTicket: ticket
        ))
        let outcome = TracerBridgeLoadOutcome()
        let acknowledgement = DispatchGroup()
        acknowledgement.enter()
        DispatchQueue.global().async {
            defer { acknowledgement.leave() }
            do {
                let result = try bridge
                    .receiveLoadStartedAcknowledgement(.loadStartedAck(
                        sequence: 2,
                        sessionID: session,
                        replyTo: 1,
                        trial: 7,
                        loadTicket: ticket
                    ))
                outcome.recordSuccess(result.frame)
            } catch let error
                as VoiceHelperInternalTracerControlBridgeError
            {
                outcome.recordFailure(error)
            } catch {
                outcome.recordUnexpectedFailure()
            }
        }

        #expect(factoryStarted.wait(timeout: .now() + 2) == .success)
        bridge.disconnect()
        releaseFactory.signal()
        #expect(acknowledgement.wait(timeout: .now() + 2) == .success)

        #expect(outcome.successCount == 0)
        #expect(outcome.failures == [.engineLoadFailed])
        #expect(outcome.unexpectedFailureCount == 0)
        #expect(factory.invocationCount == 1)
    }

    @Test
    func productEvidenceWithNonExactRuntimeFactsIsNotPublished() throws {
        let rejectedDescriptors = [
            tracerProductDescriptor(capabilities: [
                .hotwordSnapshot, .localASR, .polish, .streaming,
            ]),
            tracerProductDescriptor(maximumAlternatives: 2),
        ]

        for descriptor in rejectedDescriptors {
            let factory = TracerBridgeEngineFactory {
                TracerProductEngine(descriptor: descriptor)
            }
            let bridge = try makeTracerBridge(factory: factory)
            let session = try tracerSession(trial: 7)
            let ticket = try tracerNonce("2")
            _ = try bridge.receiveLoadEngine(.loadEngine(
                sequence: 1,
                sessionID: session,
                trial: 7,
                loadTicket: ticket
            ))

            #expect(
                throws: VoiceHelperInternalTracerControlBridgeError
                    .invalidProductDescriptor
            ) {
                _ = try bridge.receiveLoadStartedAcknowledgement(
                    .loadStartedAck(
                        sequence: 2,
                        sessionID: session,
                        replyTo: 1,
                        trial: 7,
                        loadTicket: ticket
                    )
                )
            }
            #expect(factory.invocationCount == 1)
        }
    }

    @Test
    func duplicateAcknowledgementCannotLoadTwice() throws {
        let factory = TracerBridgeEngineFactory {
            TracerProductEngine(descriptor: tracerProductDescriptor())
        }
        let bridge = try makeTracerBridge(factory: factory)
        let session = try tracerSession(trial: 7)
        let ticket = try tracerNonce("2")
        _ = try bridge.receiveLoadEngine(.loadEngine(
            sequence: 1,
            sessionID: session,
            trial: 7,
            loadTicket: ticket
        ))
        let acknowledgement = PerformanceControlWireFrame.loadStartedAck(
            sequence: 2,
            sessionID: session,
            replyTo: 1,
            trial: 7,
            loadTicket: ticket
        )
        _ = try bridge.receiveLoadStartedAcknowledgement(acknowledgement)

        #expect(
            throws: VoiceHelperInternalTracerControlBridgeError.invalidState
        ) {
            _ = try bridge.receiveLoadStartedAcknowledgement(acknowledgement)
        }
        #expect(factory.invocationCount == 1)
    }

    @Test
    func policyExpectedEngineRejectsAnotherValidDescriptor() throws {
        let adapterID = String(repeating: "a", count: 128)
        let factory = TracerBridgeEngineFactory {
            TracerProductEngine(descriptor: tracerProductDescriptor(
                adapterID: adapterID
            ))
        }
        let bridge = try makeTracerBridge(factory: factory)
        let session = try tracerSession(trial: 7)
        let ticket = try tracerNonce("2")
        _ = try bridge.receiveLoadEngine(.loadEngine(
            sequence: 1,
            sessionID: session,
            trial: 7,
            loadTicket: ticket
        ))

        #expect(
            throws: VoiceHelperInternalTracerControlBridgeError
                .invalidProductDescriptor
        ) {
            _ = try bridge.receiveLoadStartedAcknowledgement(.loadStartedAck(
                sequence: 2,
                sessionID: session,
                replyTo: 1,
                trial: 7,
                loadTicket: ticket
            ))
        }

        #expect(factory.invocationCount == 1)
    }
}

private func makeTracerBridge(
    factory: TracerBridgeEngineFactory
) throws -> VoiceHelperInternalTracerControlBridge {
    let prepared = VoiceHelperInternalTracerPreparedEngine(
        loader: { try factory.makeEngine() }
    )
    return VoiceHelperInternalTracerControlBridge(
        preparedEngine: prepared,
        helperProcessStartToken: 9_001,
        controlSessionNonce: try tracerControlSessionNonce(),
        expectedEngine: ExpectedPerformanceControlEngine(
            try tracerExpectedEngineSummary()
        )
    )
}

private func tracerControlSessionNonce() throws -> PerformanceControlNonce {
    try PerformanceControlNonce(String(repeating: "0f", count: 32))
}

private func tracerSession(trial: UInt64) throws -> PerformanceControlNonce {
    try PerformanceControlSessionBinding.derive(
        controlSessionNonce: tracerControlSessionNonce(),
        trial: trial
    ).sessionID
}

private func tracerNonce(_ digit: Character) throws -> PerformanceControlNonce {
    try PerformanceControlNonce(String(repeating: digit, count: 64))
}

private func tracerExpectedEngineSummary()
    throws -> PerformanceControlEngineSummary
{
    try PerformanceControlEngineSummary(
        adapterID: ControlledPerformanceID("sherpa-onnx"),
        engineID: "sherpa-onnx@aaaaaaaaaaaaaaaa",
        artifactID: ControlledPerformanceID("approved-voice-model-v1"),
        artifactContentSHA256: PerformanceControlSHA256(
            String(repeating: "a", count: 64)
        ),
        artifactGeneration: PerformanceControlArtifactGeneration(
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        ),
        capabilities: try [
            "hotword_snapshot", "local_asr", "streaming",
        ].map(ControlledPerformanceID.init),
        networkPolicy: .offline,
        maximumHotwords: 8
    )
}

private func tracerReadySummary(
    _ frame: PerformanceControlWireFrame
) -> PerformanceControlEngineSummary? {
    guard case let .loadReady(_, _, _, _, _, engine) = frame else {
        return nil
    }
    return engine
}

private func tracerProductDescriptor(
    adapterID: String = "sherpa-onnx",
    capabilities: Set<VoiceEngineCapability> = [
        .hotwordSnapshot, .localASR, .streaming,
    ],
    maximumAlternatives: Int = 1
) -> VoiceEngineDescriptor {
    VoiceEngineDescriptor(
        adapterID: adapterID,
        adapterVersion: "1.13.6",
        assetManagement: .productManaged,
        qualification: .integrityVerifiedProductArtifact,
        artifactID: VoiceASRArtifactID(
            rawValue: "approved-voice-model-v1"
        ),
        artifactSHA256: String(repeating: "a", count: 64),
        artifactGeneration: UUID(
            uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        ),
        supportedLocales: ["zh-CN"],
        capabilities: capabilities,
        networkPolicy: .offline,
        audioFormat: .fixedLinearPCM(
            sampleRateHertz: 16_000,
            channelCount: 1,
            bitsPerChannel: 32
        ),
        hotwordMode: .boundedPhraseList(maximumEntries: 8),
        maximumAlternatives: maximumAlternatives
    )
}

private struct TracerProductEngine: VoiceDictationEngine {
    let descriptor: VoiceEngineDescriptor

    func start(
        _ request: VoiceDictationEngineRequest,
        events: @escaping @Sendable (VoiceDictationEngineEvent) -> Void
    ) {}

    func stop(requestID: String) {}
    func cancel(requestID: String) {}
}

private enum TracerBridgeTestError: Error {
    case factoryTimedOut
}

private struct TracerBridgeUnexpectedError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    let description: String
}

private final class TracerBridgeLoadOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var successes: [PerformanceControlWireFrame] = []
    private var recordedFailures: [
        VoiceHelperInternalTracerControlBridgeError
    ] = []
    private var unexpectedFailures = 0

    var successCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return successes.count
    }

    var failures: [VoiceHelperInternalTracerControlBridgeError] {
        lock.lock()
        defer { lock.unlock() }
        return recordedFailures
    }

    var unexpectedFailureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return unexpectedFailures
    }

    func recordSuccess(_ frame: PerformanceControlWireFrame) {
        lock.lock()
        successes.append(frame)
        lock.unlock()
    }

    func recordFailure(
        _ error: VoiceHelperInternalTracerControlBridgeError
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

private final class TracerBridgeEngineFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let build: @Sendable () throws -> any VoiceDictationEngine
    private var invocations = 0

    init(
        build: @escaping @Sendable () throws -> any VoiceDictationEngine
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

private func tracerReleaseApprovedCatalog() -> VoiceASRTrustedArtifactCatalog {
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

private func tracerProductPolicyData(catalogDigest: String) -> Data {
    Data(
        """
        <plist version="1.0">
        <dict>
          <key>SchemaVersion</key>
          <integer>2</integer>
          <key>RuntimeEngine</key>
          <string>product-managed</string>
          <key>EngineIdentifier</key>
          <string>sherpa-onnx</string>
          <key>AssetManagement</key>
          <string>product_managed</string>
          <key>ReleaseEligible</key>
          <true/>
          <key>EligibilityReason</key>
          <string>approved_local_product_cohort</string>
          <key>TrustedCatalogSHA256</key>
          <string>\(catalogDigest)</string>
        </dict>
        </plist>
        """.utf8
    )
}
