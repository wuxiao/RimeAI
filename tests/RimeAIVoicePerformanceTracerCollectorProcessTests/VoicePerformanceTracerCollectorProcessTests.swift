import Foundation
import RimeAIVoicePerformanceControlCore
import RimeAIVoicePerformanceTracerProcessDarwin
import Testing

@testable import RimeAIVoicePerformanceCollector
@testable import RimeAIVoicePerformanceTracerCollectorProcess

@Suite("Voice performance tracer collector process")
struct VoicePerformanceTracerCollectorProcessTests {
    @Test("global budget covers every bounded phase for the signed trial count")
    func globalDeadlineBudgetIsPolicyDerived() throws {
        #expect(
            try VoicePerformanceTracerCollectorDeadlineBudget
                .nanoseconds(coldTrials: 1)
                == 190_000_000_000
        )
        #expect(
            try VoicePerformanceTracerCollectorDeadlineBudget
                .nanoseconds(coldTrials: 32)
                == 4_685_000_000_000
        )
        #expect(
            throws: VoicePerformanceTracerCollectorProcessError
                .deadlineFailure
        ) {
            try VoicePerformanceTracerCollectorDeadlineBudget
                .nanoseconds(coldTrials: 0)
        }
        #expect(
            throws: VoicePerformanceTracerCollectorProcessError
                .deadlineFailure
        ) {
            try VoicePerformanceTracerCollectorDeadlineBudget
                .nanoseconds(coldTrials: 33)
        }
        #expect(
            throws: VoicePerformanceTracerCollectorProcessError
                .deadlineFailure
        ) {
            try VoicePerformanceTracerCollectorDeadlineBudget
                .checkedNanoseconds(
                    coldTrials: 32,
                    fixedSeconds: 45,
                    secondsPerTrial: .max
                )
        }
    }

    @Test("collector deadline samples its base before the process remainder")
    func collectorDeadlineCannotExtendTheProcessDeadline() throws {
        let processDeadline = VoicePerformanceContinuousDeadline(
            nanoseconds: 1_000
        )
        let collectorBase = ContinuousClock().now
        var samples: [String] = []
        var sampledProcessDeadline:
            VoicePerformanceContinuousDeadline?

        let collectorDeadline = try
            VoicePerformanceTracerCollectorDeadlineAlignment
                .collectorDeadline(
                    processDeadline: processDeadline,
                    collectorNow: {
                        samples.append("collector-base")
                        return collectorBase
                    },
                    remainingNanoseconds: { deadline in
                        samples.append("process-remaining")
                        sampledProcessDeadline = deadline
                        return 25
                    }
                )

        #expect(samples == ["collector-base", "process-remaining"])
        #expect(sampledProcessDeadline == processDeadline)
        #expect(
            collectorDeadline
                == collectorBase.advanced(by: .nanoseconds(25))
        )
    }

    @Test("production collector command wires the Darwin runtime")
    func productionCommandIsConstructible() {
        let command = VoicePerformanceTracerCollectorProcess()
        _ = command
    }

    @Test("production runtime rejects malformed argv before touching the bundle")
    func productionRuntimeRejectsMalformedArguments() {
        #expect(
            throws: VoicePerformanceTracerCollectorProcessError
                .invalidArguments
        ) {
            try VoicePerformanceTracerCollectorProcess().run(
                argv: ["rimeai-voice-performance-tracer"],
                currentExecutablePath: "/private/tmp/not-a-tracer"
            )
        }
    }

    @Test("an expired global deadline fails before listener or driver launch")
    func expiredBeforeSpawn() throws {
        let fixture = try CollectorProcessFixture()
        let runtime = ScriptedCollectorProcessRuntime(fixture: fixture)
        runtime.timeRemaining = [false]
        let command = VoicePerformanceTracerCollectorProcess(runtime: runtime)

        #expect(throws: VoicePerformanceTracerCollectorProcessError.deadlineExpired) {
            try command.run(
                argv: fixture.collectorArguments,
                currentExecutablePath: fixture.collectorExecutablePath
            )
        }
        #expect(runtime.events == [.parse, .verify, .makeDeadline, .checkDeadline, .close])
        #expect(runtime.writeCount == 0)
    }

    @Test("listener setup cannot consume the deadline and still launch a driver")
    func expirationDuringListenerSetupPreventsSpawn() throws {
        let fixture = try CollectorProcessFixture()
        let runtime = ScriptedCollectorProcessRuntime(fixture: fixture)
        runtime.timeRemaining = [true, false]

        #expect(throws: VoicePerformanceTracerCollectorProcessError.deadlineExpired) {
            try VoicePerformanceTracerCollectorProcess(runtime: runtime).run(
                argv: fixture.collectorArguments,
                currentExecutablePath: fixture.collectorExecutablePath
            )
        }
        #expect(runtime.events == [
            .parse,
            .verify,
            .makeDeadline,
            .checkDeadline,
            .startTransport,
            .checkDeadline,
            .close,
        ])
        #expect(!runtime.events.contains(.launch))
        #expect(!runtime.events.contains(.terminate))
        #expect(runtime.writeCount == 0)
    }

    @Test("result publication cannot overlap signed or measured inputs")
    func rejectsResultPathOverlap() throws {
        let fixture = try CollectorProcessFixture()
        let protectedPaths = [
            fixture.outerPath,
            fixture.outerPath + "/Contents/Resources/VoicePerformanceMeasurementPolicy.json",
            fixture.outerPath + VoicePerformanceTracerBundleLayout.driverExecutableSuffix,
            fixture.measurementPolicy.evaluationArtifact.directory,
            fixture.measurementPolicy.evaluationArtifact.directory + "/result.json",
            "/private/tmp",
        ]

        for resultPath in protectedPaths {
            let runtime = ScriptedCollectorProcessRuntime(fixture: fixture)
            let command = VoicePerformanceTracerCollectorProcess(runtime: runtime)
            let argv = [
                fixture.collectorExecutablePath,
                "--tracer-bundle", fixture.outerPath,
                "--result", resultPath,
            ]

            #expect(
                throws: VoicePerformanceTracerCollectorProcessError
                    .resultPathOverlap
            ) {
                try command.run(
                    argv: argv,
                    currentExecutablePath: fixture.collectorExecutablePath
                )
            }
            #expect(runtime.events == [.parse, .verify, .close])
            #expect(runtime.writeCount == 0)
        }
    }

    @Test("collector argv must exactly bind argv zero and the derived outer bundle")
    func rejectsInvalidArguments() throws {
        let fixture = try CollectorProcessFixture()
        let invalidArguments: [([String], VoicePerformanceTracerCollectorProcessError)] = [
            ([fixture.collectorExecutablePath], .invalidArguments),
            ([
                "/private/tmp/alias-tracer",
                "--tracer-bundle", fixture.outerPath,
                "--result", fixture.resultPath,
            ], .invalidArguments),
            ([
                fixture.collectorExecutablePath,
                "--tracer-bundle", fixture.outerPath + "-copy",
                "--result", fixture.resultPath,
            ], .invalidTracerBundle),
        ]

        for (argv, expectedError) in invalidArguments {
            let runtime = ScriptedCollectorProcessRuntime(fixture: fixture)
            let command = VoicePerformanceTracerCollectorProcess(runtime: runtime)
            #expect(
                throws: expectedError
            ) {
                try command.run(
                    argv: argv,
                    currentExecutablePath: fixture.collectorExecutablePath
                )
            }
            #expect(runtime.events == [.parse, .close])
            #expect(runtime.writeCount == 0)
        }
    }

    @Test("result path must be a canonical absolute path before verification")
    func rejectsInvalidResultPath() throws {
        let fixture = try CollectorProcessFixture()
        for resultPath in [
            "relative/result.json",
            "/private/tmp/../result.json",
            "/private/tmp/result.json/",
            "/private/tmp/result\n.json",
        ] {
            let runtime = ScriptedCollectorProcessRuntime(fixture: fixture)
            #expect(
                throws: VoicePerformanceTracerCollectorProcessError
                    .invalidResultPath
            ) {
                try VoicePerformanceTracerCollectorProcess(
                    runtime: runtime
                ).run(
                    argv: [
                        fixture.collectorExecutablePath,
                        "--tracer-bundle", fixture.outerPath,
                        "--result", resultPath,
                    ],
                    currentExecutablePath: fixture.collectorExecutablePath
                )
            }
            #expect(runtime.events == [.parse, .close])
        }
    }

    @Test("a failed signed-bundle verification is terminal before deadline setup")
    func rejectsUnverifiedBundle() throws {
        let fixture = try CollectorProcessFixture()
        let runtime = ScriptedCollectorProcessRuntime(fixture: fixture)
        runtime.verifyFailure = VoicePerformanceTracerProcessError
            .invalidTracerBundle
        let command = VoicePerformanceTracerCollectorProcess(runtime: runtime)

        #expect(
            throws: VoicePerformanceTracerCollectorProcessError
                .invalidTracerBundle
        ) {
            try command.run(
                argv: fixture.collectorArguments,
                currentExecutablePath: fixture.collectorExecutablePath
            )
        }
        #expect(runtime.events == [.parse, .verify, .close])
        #expect(runtime.writeCount == 0)
    }

    @Test("launch preparation failure is cleaned before the runtime throws")
    func launchPreparationFailureCleansInternally() throws {
        let fixture = try CollectorProcessFixture()
        let runtime = ScriptedCollectorProcessRuntime(fixture: fixture)
        runtime.launchFailure = VoicePerformanceTracerProcessError
            .processGenerationMismatch

        #expect(
            throws: VoicePerformanceTracerCollectorProcessError
                .driverGenerationMismatch
        ) {
            try VoicePerformanceTracerCollectorProcess(runtime: runtime).run(
                argv: fixture.collectorArguments,
                currentExecutablePath: fixture.collectorExecutablePath
            )
        }
        #expect(runtime.events.suffix(2) == [.launch, .close])
        #expect(runtime.launchInternalCleanupCount == 1)
        #expect(!runtime.events.contains(.terminate))
        #expect(runtime.writeCount == 0)
    }

    @Test("launch cleanup failure is never reported as an ordinary launch error")
    func launchCleanupFailureIsExplicit() throws {
        let fixture = try CollectorProcessFixture()
        let runtime = ScriptedCollectorProcessRuntime(fixture: fixture)
        runtime.launchFailure = VoicePerformanceTracerProcessError
            .processCleanupFailed

        #expect(
            throws: VoicePerformanceTracerCollectorProcessError.cleanupFailed
        ) {
            try VoicePerformanceTracerCollectorProcess(runtime: runtime).run(
                argv: fixture.collectorArguments,
                currentExecutablePath: fixture.collectorExecutablePath
            )
        }
        #expect(runtime.launchInternalCleanupCount == 1)
        #expect(!runtime.events.contains(.terminate))
        #expect(runtime.writeCount == 0)
    }

    @Test("a returned invalid generation or bind failure reaps the owned driver")
    func postLaunchFailureCleansOwnedDriver() throws {
        let fixture = try CollectorProcessFixture()
        let scenarios: [(ScriptedCollectorProcessRuntime, VoicePerformanceTracerCollectorProcessError, ScriptedCollectorProcessRuntime.Event)] = [
            ({
                let runtime = ScriptedCollectorProcessRuntime(fixture: fixture)
                runtime.launchedGeneration = .init(
                    pid: 701,
                    startToken: 7_001,
                    processGroupID: 702
                )
                return runtime
            }(), .driverGenerationMismatch, .launch),
            ({
                let runtime = ScriptedCollectorProcessRuntime(fixture: fixture)
                runtime.bindFailure = VoicePerformanceTracerTransportError
                    .authenticationFailed
                return runtime
            }(), .transportFailure, .bind),
        ]

        for (runtime, expectedError, failureEvent) in scenarios {
            let command = VoicePerformanceTracerCollectorProcess(runtime: runtime)
            #expect(throws: expectedError) {
                try command.run(
                    argv: fixture.collectorArguments,
                    currentExecutablePath: fixture.collectorExecutablePath
                )
            }
            #expect(runtime.events.last == .terminate)
            #expect(runtime.events.contains(failureEvent))
            #expect(runtime.events.contains(.close))
            #expect(!runtime.events.contains(.collect))
            #expect(runtime.writeCount == 0)
        }
    }

    @Test("collection failure closes the listener and tears down the full driver group")
    func collectionFailureCleansOwnedDriver() throws {
        let fixture = try CollectorProcessFixture()
        let runtime = ScriptedCollectorProcessRuntime(fixture: fixture)
        runtime.collectFailure = VoicePerformanceTracerCollectorError
            .protocolViolation
        let command = VoicePerformanceTracerCollectorProcess(runtime: runtime)

        #expect(
            throws: VoicePerformanceTracerCollectorProcessError
                .collectionFailed
        ) {
            try command.run(
                argv: fixture.collectorArguments,
                currentExecutablePath: fixture.collectorExecutablePath
            )
        }
        #expect(runtime.events.suffix(2) == [.close, .terminate])
        #expect(runtime.events.contains(.collect))
        #expect(!runtime.events.contains(.waitForDriver))
        #expect(runtime.writeCount == 0)
    }

    @Test("collected evidence must attest the exact launched driver generation")
    func rejectsMismatchedDriverAttestation() throws {
        let fixture = try CollectorProcessFixture()
        for (pid, startToken) in [
            (Int32(799), UInt64(7_001)),
            (Int32(701), UInt64(7_999)),
        ] {
            let runtime = ScriptedCollectorProcessRuntime(fixture: fixture)
            runtime.collectedResult = try fixture.makeResult(
                driverPID: pid,
                driverStartToken: startToken
            )
            let command = VoicePerformanceTracerCollectorProcess(runtime: runtime)

            #expect(
                throws: VoicePerformanceTracerCollectorProcessError
                    .driverAttestationMismatch
            ) {
                try command.run(
                    argv: fixture.collectorArguments,
                    currentExecutablePath: fixture.collectorExecutablePath
                )
            }
            #expect(runtime.events.suffix(2) == [.close, .terminate])
            #expect(!runtime.events.contains(.waitForDriver))
            #expect(runtime.writeCount == 0)
        }
    }

    @Test("nonzero driver exit or surviving process-group members reject evidence")
    func rejectsUnsuccessfulDriverTree() throws {
        let fixture = try CollectorProcessFixture()
        for failure in [
            VoicePerformanceTracerProcessError.processExitedUnsuccessfully,
            VoicePerformanceTracerProcessError.processGroupFailure,
            VoicePerformanceTracerProcessError.processTerminationTimedOut,
        ] {
            let runtime = ScriptedCollectorProcessRuntime(fixture: fixture)
            runtime.collectedResult = try fixture.makeResult()
            runtime.waitFailure = failure
            let command = VoicePerformanceTracerCollectorProcess(runtime: runtime)

            #expect(
                throws: VoicePerformanceTracerCollectorProcessError
                    .driverExitFailed
            ) {
                try command.run(
                    argv: fixture.collectorArguments,
                    currentExecutablePath: fixture.collectorExecutablePath
                )
            }
            #expect(runtime.events.suffix(2) == [.close, .terminate])
            #expect(runtime.events.contains(.waitForDriver))
            #expect(runtime.writeCount == 0)
        }
    }

    @Test("result bytes must decode canonically back to the identical result")
    func rejectsNonCanonicalResultRoundTrip() throws {
        let fixture = try CollectorProcessFixture()
        let runtime = ScriptedCollectorProcessRuntime(fixture: fixture)
        runtime.collectedResult = try fixture.makeResult(validTranscript: false)
        runtime.timeRemaining = [true, true, true]
        let command = VoicePerformanceTracerCollectorProcess(runtime: runtime)

        #expect(
            throws: VoicePerformanceTracerCollectorProcessError
                .resultCanonicalizationFailed
        ) {
            try command.run(
                argv: fixture.collectorArguments,
                currentExecutablePath: fixture.collectorExecutablePath
            )
        }
        #expect(runtime.events.suffix(2) == [.close, .terminate])
        #expect(runtime.events.contains(.waitForDriver))
        #expect(runtime.writeCount == 0)
    }

    @Test("an expired global deadline after collection forbids result publication")
    func expirationBeforeCommitWritesNothing() throws {
        let fixture = try CollectorProcessFixture()
        let runtime = ScriptedCollectorProcessRuntime(fixture: fixture)
        runtime.collectedResult = try fixture.makeResult()
        runtime.timeRemaining = [true, true, true, false]
        let command = VoicePerformanceTracerCollectorProcess(runtime: runtime)

        #expect(
            throws: VoicePerformanceTracerCollectorProcessError
                .deadlineExpired
        ) {
            try command.run(
                argv: fixture.collectorArguments,
                currentExecutablePath: fixture.collectorExecutablePath
            )
        }
        #expect(runtime.events.suffix(2) == [.close, .terminate])
        #expect(runtime.events.contains(.waitForDriver))
        #expect(runtime.writeCount == 0)
    }

    @Test("atomic-writer failures preserve their safe publication semantics")
    func preservesWriterFailureCodes() throws {
        let fixture = try CollectorProcessFixture()
        let failures: [(VoicePerformanceTracerProcessError, VoicePerformanceTracerCollectorProcessError)] = [
            (.invalidResultPath, .resultPathAuthority),
            (.resultAlreadyExists, .resultAlreadyExists),
            (.resultWriteFailed, .resultWriteFailed),
            (.resultCommitFailed, .resultCommitFailed),
            (.resultDurabilityFailed, .resultDurabilityFailed),
            (.deadlineExpired, .deadlineExpired),
            (
                .resultInstallationIndeterminate,
                .resultInstallationIndeterminate
            ),
        ]

        for (writerFailure, expectedError) in failures {
            let runtime = ScriptedCollectorProcessRuntime(fixture: fixture)
            runtime.collectedResult = try fixture.makeResult()
            runtime.timeRemaining = [true, true, true, true]
            runtime.writeFailure = writerFailure
            let command = VoicePerformanceTracerCollectorProcess(runtime: runtime)

            #expect(throws: expectedError) {
                try command.run(
                    argv: fixture.collectorArguments,
                    currentExecutablePath: fixture.collectorExecutablePath
                )
            }
            #expect(runtime.events.suffix(2) == [.write, .terminate])
            #expect(runtime.events.filter { $0 == .close }.count == 1)
            #expect(runtime.writeCount == 1)
        }
    }

    @Test("cleanup failure is explicit but never masks indeterminate installation")
    func cleanupFailurePrecedenceIsSafe() throws {
        let fixture = try CollectorProcessFixture()

        let collectionRuntime = ScriptedCollectorProcessRuntime(fixture: fixture)
        collectionRuntime.collectFailure = VoicePerformanceTracerCollectorError
            .protocolViolation
        collectionRuntime.cleanupFailure = VoicePerformanceTracerProcessError
            .processTerminationTimedOut
        #expect(
            throws: VoicePerformanceTracerCollectorProcessError.cleanupFailed
        ) {
            try VoicePerformanceTracerCollectorProcess(
                runtime: collectionRuntime
            ).run(
                argv: fixture.collectorArguments,
                currentExecutablePath: fixture.collectorExecutablePath
            )
        }

        let publicationRuntime = ScriptedCollectorProcessRuntime(fixture: fixture)
        publicationRuntime.collectedResult = try fixture.makeResult()
        publicationRuntime.timeRemaining = [true, true, true, true]
        publicationRuntime.writeFailure = VoicePerformanceTracerProcessError
            .resultInstallationIndeterminate
        publicationRuntime.cleanupFailure = VoicePerformanceTracerProcessError
            .processTerminationTimedOut
        #expect(
            throws: VoicePerformanceTracerCollectorProcessError
                .resultInstallationIndeterminate
        ) {
            try VoicePerformanceTracerCollectorProcess(
                runtime: publicationRuntime
            ).run(
                argv: fixture.collectorArguments,
                currentExecutablePath: fixture.collectorExecutablePath
            )
        }
        #expect(collectionRuntime.writeCount == 0)
        #expect(publicationRuntime.writeCount == 1)
    }

    @Test("success uses one deadline and publishes only after the exact driver tree exits")
    func successHasExactLifecycleOrder() throws {
        let fixture = try CollectorProcessFixture()
        let runtime = ScriptedCollectorProcessRuntime(fixture: fixture)
        let result = try fixture.makeResult()
        runtime.collectedResult = result
        runtime.timeRemaining = [true, true, true, true]

        try VoicePerformanceTracerCollectorProcess(runtime: runtime).run(
            argv: fixture.collectorArguments,
            currentExecutablePath: fixture.collectorExecutablePath
        )

        #expect(runtime.events == [
            .parse,
            .verify,
            .makeDeadline,
            .checkDeadline,
            .startTransport,
            .checkDeadline,
            .launch,
            .bind,
            .collect,
            .waitForDriver,
            .checkDeadline,
            .checkDeadline,
            .close,
            .write,
        ])
        #expect(
            runtime.startedSocketPath
                == fixture.measurementPolicy.controlSocketPath
        )
        #expect(
            runtime.launchedExecutablePath
                == fixture.measurementPolicy.driver.expectedExecutablePath
        )
        #expect(runtime.launchedArgv == [
            fixture.measurementPolicy.driver.expectedExecutablePath,
            "--tracer-bundle", fixture.outerPath,
            "--deadline-continuous-ns", "10000",
        ])
        #expect(runtime.boundDriver == .init(
            role: .driver,
            pid: 701,
            processStartToken: 7_001,
            processGroupID: 701
        ))
        #expect(
            runtime.collectedRequest?.measurementPolicy
                == fixture.measurementPolicy
        )
        #expect(runtime.collectedRequest?.driverPolicy == fixture.driverPolicy)
        #expect(runtime.collectedRequest?.qualification == .tracer)
        #expect(runtime.collectedRequest?.authenticatedProductionDriver == false)
        #expect(runtime.collectedDeadline == runtime.globalDeadline.collectorDeadline)
        #expect(
            runtime.checkedDeadlines.map(\.processDeadline)
                == Array(repeating: runtime.globalDeadline.processDeadline, count: 4)
        )
        #expect(
            runtime.waitedDeadline?.processDeadline
                == runtime.globalDeadline.processDeadline
        )
        #expect(
            runtime.waitedDeadline?.collectorDeadline
                == runtime.globalDeadline.collectorDeadline
        )
        #expect(runtime.writtenResultPath == fixture.resultPath)
        #expect(
            runtime.writtenDeadline
                == runtime.globalDeadline.processDeadline
        )
        #expect(try VoicePerformanceTracerResult.decodeCanonical(
            runtime.writtenData ?? Data()
        ) == result)
        #expect(runtime.writeCount == 1)
    }
}

private struct CollectorProcessFixture {
    let outerPath = "/private/tmp/RimeAIVoicePerformanceTracer.bundle"
    let resultPath = "/private/tmp/rimeai-results/result.json"
    let measurementPolicy: VoicePerformanceMeasurementPolicy
    let driverPolicy: SealedPerformanceControlDriverPolicy

    var collectorExecutablePath: String {
        outerPath
            + VoicePerformanceTracerBundleLayout.collectorExecutableSuffix
    }

    var collectorArguments: [String] {
        [
            collectorExecutablePath,
            "--tracer-bundle", outerPath,
            "--result", resultPath,
        ]
    }

    init() throws {
        let controlProtocol = try PerformanceControlProtocolIdentity(
            sha256: String(repeating: "a", count: 64)
        )
        let driverData = Data(
            (#"{"capabilities":["authenticated_control","lazy_load_ticket"],"control_protocol":{"id":"rimeai-performance-control-v2","sha256":""#
                + controlProtocol.sha256
                + #""},"qualification":"tracer","schema_version":1}"#).utf8
        )
        driverPolicy = try SealedPerformanceControlDriverPolicy.decodeCanonical(
            driverData,
            expectedControlProtocol: controlProtocol
        )
        measurementPolicy = try VoicePerformanceMeasurementPolicy.decodeCanonical(
            Data(
                (#"{"cold_trials":1,"collector":{"expected_cdhash":""#
                    + String(repeating: "c", count: 40)
                    + #"","expected_executable_path":""#
                    + outerPath
                    + VoicePerformanceTracerBundleLayout.collectorExecutableSuffix
                    + #"","expected_executable_sha256":""#
                    + String(repeating: "c", count: 64)
                    + #"","expected_signing_identifier":"fun.wwcn.rimeai.voice-performance-collector","expected_team_identifier":"TEAMID1234"},"control_protocol":{"id":"rimeai-performance-control-v2","sha256":""#
                    + controlProtocol.sha256
                    + #""},"control_session_nonce":""#
                    + String(repeating: "b", count: 64)
                    + #"","control_socket_path":"/private/tmp/rimeai-performance.sock","driver":{"expected_cdhash":""#
                    + String(repeating: "d", count: 40)
                    + #"","expected_executable_path":""#
                    + outerPath
                    + VoicePerformanceTracerBundleLayout.driverExecutableSuffix
                    + #"","expected_executable_sha256":""#
                    + String(repeating: "d", count: 64)
                    + #"","expected_signing_identifier":"fun.wwcn.rimeai.voice-performance-driver","expected_team_identifier":"TEAMID1234","policy_sha256":""#
                    + driverPolicy.canonicalSHA256.rawValue
                    + #""},"enabled":true,"evaluation_artifact":{"adapter_id":"sherpa-onnx","artifact_id":"voice-model","content_sha256":""#
                    + String(repeating: "e", count: 64)
                    + #"","directory":"/private/tmp/rimeai-evaluation-artifact","maximum_hotwords":64},"helper":{"expected_cdhash":""#
                    + String(repeating: "f", count: 40)
                    + #"","expected_executable_path":""#
                    + outerPath
                    + VoicePerformanceTracerBundleLayout.helperExecutableSuffix
                    + #"","expected_executable_sha256":""#
                    + String(repeating: "f", count: 64)
                    + #"","expected_signing_identifier":"fun.wwcn.rimeai.voice-helper","expected_team_identifier":"TEAMID1234"},"release_policy_sha256":""#
                    + String(repeating: "1", count: 64)
                    + #"","schema_version":2}"#).utf8
            )
        )
    }

    func makeResult(
        driverPID: Int32 = 701,
        driverStartToken: UInt64 = 7_001,
        validTranscript: Bool = true
    ) throws -> VoicePerformanceTracerResult {
        let controlSessionNonce = try PerformanceControlNonce(
            measurementPolicy.controlSessionNonce
        )
        let binding = try PerformanceControlSessionBinding.derive(
            controlSessionNonce: controlSessionNonce,
            trial: 1
        )
        let driverCollectorNonce = try fixedNonce("2")
        let helperCollectorNonce = try fixedNonce("3")
        let driverPeerNonce = try fixedNonce("4")
        let helperPeerNonce = try fixedNonce("5")
        let loadTicket = try fixedNonce("6")
        let driverAttestation = try VoicePerformanceTracerAttestedPeer(
            pid: driverPID,
            effectiveUserID: 501,
            processStartToken: driverStartToken,
            pidVersion: 1,
            instanceID: String(repeating: "7", count: 64)
        )
        let helperAttestation = try VoicePerformanceTracerAttestedPeer(
            pid: 702,
            effectiveUserID: 501,
            processStartToken: 7_002,
            pidVersion: 2,
            instanceID: String(repeating: "8", count: 64)
        )
        let helperGeneration = try HelperGenerationIdentity(
            pid: helperAttestation.pid,
            processStartToken: helperAttestation.processStartToken,
            instanceID: helperAttestation.instanceID
        )
        let artifactGeneration = try PerformanceControlArtifactGeneration(
            "00000000-0000-4000-8000-000000000001"
        )
        let engine = try PerformanceControlEngineSummary(
            adapterID: measurementPolicy.expectedEngine.adapterID,
            engineID: measurementPolicy.expectedEngine.engineID,
            artifactID: measurementPolicy.expectedEngine.artifactID,
            artifactContentSHA256:
                measurementPolicy.expectedEngine.artifactContentSHA256,
            artifactGeneration: artifactGeneration,
            capabilities: measurementPolicy.expectedEngine.capabilities,
            networkPolicy: measurementPolicy.expectedEngine.networkPolicy,
            maximumHotwords:
                measurementPolicy.expectedEngine.maximumHotwords
        )
        let measurementSHA = try PerformanceControlSHA256(
            measurementPolicy.canonicalSHA256
        )
        let releaseSHA = try PerformanceControlSHA256(
            measurementPolicy.releasePolicySHA256
        )
        let readyTrial: UInt64 = validTranscript ? 1 : 2
        let frames: [PerformanceControlWireFrame] = [
            .challenge(
                peerRole: .driver,
                sessionID: binding.sessionID,
                planNonce: binding.planNonce,
                collectorNonce: driverCollectorNonce
            ),
            .challenge(
                peerRole: .helper,
                sessionID: binding.sessionID,
                planNonce: binding.planNonce,
                collectorNonce: helperCollectorNonce
            ),
            .driverHello(
                sessionID: binding.sessionID,
                planNonce: binding.planNonce,
                collectorNonce: driverCollectorNonce,
                peerNonce: driverPeerNonce,
                collectionProtocol: measurementPolicy.controlProtocol,
                driverPolicySHA256: driverPolicy.canonicalSHA256,
                measurementPolicySHA256: measurementSHA
            ),
            .helperHello(
                sessionID: binding.sessionID,
                planNonce: binding.planNonce,
                collectorNonce: helperCollectorNonce,
                peerNonce: helperPeerNonce,
                measurementPolicySHA256: measurementSHA,
                releasePolicySHA256: releaseSHA
            ),
            .armColdLoad(
                sequence: 1,
                sessionID: binding.sessionID,
                trial: 1
            ),
            .loadEngine(
                sequence: 1,
                sessionID: binding.sessionID,
                trial: 1,
                loadTicket: loadTicket
            ),
            .loadStarted(
                sequence: 1,
                sessionID: binding.sessionID,
                replyTo: 1,
                trial: 1,
                loadTicket: loadTicket
            ),
            .loadStartedAck(
                sequence: 2,
                sessionID: binding.sessionID,
                replyTo: 1,
                trial: 1,
                loadTicket: loadTicket
            ),
            .loadReady(
                sequence: 2,
                sessionID: binding.sessionID,
                replyTo: 2,
                trial: readyTrial,
                loadTicket: loadTicket,
                engine: engine
            ),
        ]
        let channels: [VoicePerformanceTracerTranscriptChannel] = [
            .collectorToDriver,
            .collectorToHelper,
            .driverToCollector,
            .helperToCollector,
            .driverToCollector,
            .collectorToHelper,
            .helperToCollector,
            .collectorToHelper,
            .helperToCollector,
        ]
        let transcript = try zip(channels, frames).map { channel, frame in
            try VoicePerformanceTracerTranscriptEntry(
                trial: 1,
                channel: channel,
                frame: frame
            )
        }
        let trial = try VoicePerformanceTracerColdTrialResult(
            trial: 1,
            sessionID: binding.sessionID,
            planNonce: binding.planNonce,
            loadTicket: loadTicket,
            helperGeneration: helperGeneration,
            helperAttestation: helperAttestation,
            artifactGeneration: artifactGeneration,
            coldLoadDurationNanoseconds: 250
        )
        return try VoicePerformanceTracerResult(
            controlProtocol: measurementPolicy.controlProtocol,
            controlSessionNonce: controlSessionNonce,
            measurementPolicySHA256: measurementSHA,
            driverPolicySHA256: driverPolicy.canonicalSHA256,
            releasePolicySHA256: releaseSHA,
            expectedEngine: measurementPolicy.expectedEngine,
            driverAttestation: driverAttestation,
            trials: [trial],
            transcript: transcript
        )
    }

    private func fixedNonce(_ character: Character)
        throws -> PerformanceControlNonce
    {
        try PerformanceControlNonce(
            String(repeating: String(character), count: 64)
        )
    }
}

private final class ScriptedCollectorProcessRuntime:
    VoicePerformanceTracerCollectorProcessRuntime
{
    enum Event: Equatable {
        case parse
        case verify
        case makeDeadline
        case checkDeadline
        case startTransport
        case launch
        case bind
        case collect
        case waitForDriver
        case close
        case terminate
        case write
    }

    let fixture: CollectorProcessFixture
    var events: [Event] = []
    var timeRemaining = [true, true]
    var writeCount = 0
    var verifyFailure: Error?
    var launchFailure: Error?
    var launchInternalCleanupCount = 0
    var bindFailure: Error?
    var collectFailure: Error?
    var collectedResult: VoicePerformanceTracerResult?
    var waitFailure: Error?
    var writeFailure: Error?
    var cleanupFailure: Error?
    var launchedGeneration = VoicePerformanceSupervisedProcessGeneration(
        pid: 701,
        startToken: 7_001,
        processGroupID: 701
    )
    private(set) var globalDeadline = VoicePerformanceTracerCollectorGlobalDeadline(
        processDeadline: .init(nanoseconds: 10_000),
        collectorDeadline: ContinuousClock().now.advanced(by: .seconds(60))
    )
    private(set) var startedSocketPath: String?
    private(set) var launchedExecutablePath: String?
    private(set) var launchedArgv: [String]?
    private(set) var boundDriver: VoicePerformanceTracerLaunchedDriverIdentity?
    private(set) var collectedRequest: VoicePerformanceTracerCollectionRequest?
    private(set) var collectedDeadline: ContinuousClock.Instant?
    private(set) var checkedDeadlines:
        [VoicePerformanceTracerCollectorGlobalDeadline] = []
    private(set) var waitedDeadline:
        VoicePerformanceTracerCollectorGlobalDeadline?
    private(set) var writtenData: Data?
    private(set) var writtenResultPath: String?
    private(set) var writtenDeadline: VoicePerformanceContinuousDeadline?

    init(fixture: CollectorProcessFixture) {
        self.fixture = fixture
    }

    func parseArguments(
        _ argv: [String],
        currentExecutablePath: String
    ) throws -> VoicePerformanceCollectorProcessArguments {
        events.append(.parse)
        return try VoicePerformanceCollectorProcessArguments.parse(
            argv,
            currentExecutablePath: currentExecutablePath
        )
    }

    func verifyCollectorBundle(
        declaredPath: String
    ) throws -> VoicePerformanceTracerCollectorVerifiedContext {
        events.append(.verify)
        if let verifyFailure { throw verifyFailure }
        return VoicePerformanceTracerCollectorVerifiedContext(
            outerPath: declaredPath,
            measurementPolicy: fixture.measurementPolicy,
            driverPolicy: fixture.driverPolicy,
            selfStartToken: 500
        )
    }

    func makeGlobalDeadline()
        throws -> VoicePerformanceTracerCollectorGlobalDeadline
    {
        events.append(.makeDeadline)
        return globalDeadline
    }

    func hasTimeRemaining(
        before deadline: VoicePerformanceTracerCollectorGlobalDeadline
    ) throws -> Bool {
        events.append(.checkDeadline)
        checkedDeadlines.append(deadline)
        return timeRemaining.removeFirst()
    }

    func startTransport(socketPath: String) throws {
        events.append(.startTransport)
        startedSocketPath = socketPath
    }

    func launchPreparedDriver(
        executablePath: String,
        argv: [String]
    ) throws -> VoicePerformanceSupervisedProcessGeneration {
        events.append(.launch)
        launchedExecutablePath = executablePath
        launchedArgv = argv
        if let launchFailure {
            launchInternalCleanupCount += 1
            throw launchFailure
        }
        return launchedGeneration
    }

    func bindLaunchedDriver(
        _ identity: VoicePerformanceTracerLaunchedDriverIdentity
    ) throws {
        events.append(.bind)
        boundDriver = identity
        if let bindFailure { throw bindFailure }
    }

    func collect(
        _ request: VoicePerformanceTracerCollectionRequest,
        deadline: ContinuousClock.Instant
    ) throws -> VoicePerformanceTracerResult {
        events.append(.collect)
        collectedRequest = request
        collectedDeadline = deadline
        if let collectFailure { throw collectFailure }
        if let collectedResult { return collectedResult }
        throw ScriptedFailure.unimplemented
    }

    func waitForSucceededDriver(
        before deadline: VoicePerformanceTracerCollectorGlobalDeadline
    ) throws {
        events.append(.waitForDriver)
        waitedDeadline = deadline
        if let waitFailure { throw waitFailure }
    }

    func closeTransport() {
        events.append(.close)
    }

    func terminateDriverGroupAndReap() throws {
        events.append(.terminate)
        if let cleanupFailure { throw cleanupFailure }
    }

    func writeResult(
        _ data: Data,
        to resultPath: String,
        before deadline: VoicePerformanceContinuousDeadline
    ) throws {
        events.append(.write)
        writeCount += 1
        writtenData = data
        writtenResultPath = resultPath
        writtenDeadline = deadline
        if let writeFailure { throw writeFailure }
    }

    enum ScriptedFailure: Error {
        case unimplemented
    }
}
