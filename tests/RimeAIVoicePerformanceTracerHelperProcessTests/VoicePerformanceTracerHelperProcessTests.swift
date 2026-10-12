import Foundation
import RimeAIVoicePerformanceControlCore
import Testing

@testable import RimeAIVoicePerformanceTracerHelperProcess
@testable import RimeAIVoicePerformanceTracerProcessDarwin

@Suite("Voice performance tracer helper process facade")
struct VoicePerformanceTracerHelperProcessTests {
    @Test("production helper facade rejects malformed argv before verification")
    func productionFacadeIsWired() {
        #expect(
            throws: VoicePerformanceTracerHelperProcessError
                .invalidArguments
        ) {
            try VoicePerformanceTracerHelperProcess().run(
                argv: ["forged-helper"],
                currentExecutablePath: "/private/tmp/real-helper"
            )
        }
    }

    @Test("helper preflight enforces the global trial ceiling before verification")
    func globalTrialCeilingHasNoAuthorityEffects() {
        let bundle = "/Applications/RimeAIVoicePerformanceTracer.bundle"
        let executable = bundle
            + VoicePerformanceTracerBundleLayout.helperExecutableSuffix
        let runtime = RecordingHelperProcessRuntime()

        #expect(
            throws: VoicePerformanceTracerHelperProcessError
                .invalidArguments
        ) {
            try VoicePerformanceTracerHelperProcess(runtime: runtime).run(
                argv: [
                    executable,
                    "--tracer-bundle", bundle,
                    "--trial", "33",
                    "--deadline-continuous-ns", "1000000000",
                ],
                currentExecutablePath: executable
            )
        }
        #expect(runtime.events == [.parse(policyColdTrials: 32)])
    }

    @Test("signed cold-trial bound is re-applied after helper verification")
    func signedTrialBoundPreventsCommandEffects() throws {
        let fixture = try HelperProcessFixture(coldTrials: 2, trial: 3)
        let runtime = RecordingHelperProcessRuntime(
            verifiedBundle: fixture.context
        )

        #expect(
            throws: VoicePerformanceTracerHelperProcessError
                .invalidArguments
        ) {
            try VoicePerformanceTracerHelperProcess(runtime: runtime).run(
                argv: fixture.argv,
                currentExecutablePath: fixture.executablePath
            )
        }
        #expect(runtime.events == [
            .parse(policyColdTrials: 32),
            .verify,
            .parse(policyColdTrials: 2),
        ])
        #expect(runtime.commandArguments == nil)
    }

    @Test("helper facade orders preflight verify signed parse then command")
    func runsExactFacadeSequence() throws {
        let fixture = try HelperProcessFixture(coldTrials: 2, trial: 2)
        let runtime = RecordingHelperProcessRuntime(
            verifiedBundle: fixture.context
        )

        try VoicePerformanceTracerHelperProcess(runtime: runtime).run(
            argv: fixture.argv,
            currentExecutablePath: fixture.executablePath
        )

        #expect(runtime.events == [
            .parse(policyColdTrials: 32),
            .verify,
            .parse(policyColdTrials: 2),
            .command,
        ])
        #expect(runtime.verifiedPath == fixture.bundlePath)
        #expect(runtime.commandArguments?.trial == 2)
        #expect(runtime.commandBundle?.driverPolicy == nil)
    }

    @Test("known bundle rejection prevents the signed parse and command")
    func knownVerificationRejectionRemainsAuthority() throws {
        let fixture = try HelperProcessFixture(coldTrials: 2, trial: 1)
        let runtime = RecordingHelperProcessRuntime(
            verifyError: VoicePerformanceTracerProcessError
                .invalidTracerBundle
        )

        #expect(
            throws: VoicePerformanceTracerHelperProcessError
                .invalidTracerBundle
        ) {
            try VoicePerformanceTracerHelperProcess(runtime: runtime).run(
                argv: fixture.argv,
                currentExecutablePath: fixture.executablePath
            )
        }
        #expect(runtime.events == [
            .parse(policyColdTrials: 32), .verify,
        ])
    }

    @Test("unexpected verification errors reach the entrypoint as internal")
    func unexpectedVerificationErrorIsInternalAndRedacted() throws {
        let fixture = try HelperProcessFixture(coldTrials: 2, trial: 1)
        let secret = "helper-verify-secret-61c4"
        let runtime = RecordingHelperProcessRuntime(
            verifyError: SensitiveHelperUnexpectedError(secret)
        )
        var diagnostics: [String] = []

        let status = VoicePerformanceTracerHelperEntrypoint.run(
            arguments: fixture.argv,
            resolveCurrentExecutablePath: { fixture.executablePath },
            runProcess: { arguments, executablePath in
                try VoicePerformanceTracerHelperProcess(
                    runtime: runtime
                ).run(
                    argv: arguments,
                    currentExecutablePath: executablePath
                )
            },
            writeDiagnostic: { diagnostics.append($0) }
        )

        #expect(status == 70)
        #expect(
            diagnostics
                == ["rimeai-voice-performance-helper:E_INTERNAL\n"]
        )
        #expect(diagnostics.allSatisfy { !$0.contains(secret) })
        #expect(runtime.events == [
            .parse(policyColdTrials: 32), .verify,
        ])
    }

    @Test("helper rejects every free policy or resource override")
    func rejectsFreeAuthorityFlags() throws {
        let fixture = try HelperProcessFixture(coldTrials: 2, trial: 1)
        for flag in ["--policy", "--socket", "--artifact", "--engine"] {
            let runtime = RecordingHelperProcessRuntime()
            #expect(
                throws: VoicePerformanceTracerHelperProcessError
                    .invalidArguments
            ) {
                try VoicePerformanceTracerHelperProcess(
                    runtime: runtime
                ).run(
                    argv: fixture.argv + [flag, "/private/tmp/free"],
                    currentExecutablePath: fixture.executablePath
                )
            }
            #expect(runtime.events == [.parse(policyColdTrials: 32)])
        }
    }

    @Test("helper argv zero must byte-match the live kernel path")
    func rejectsForgedArgumentZero() throws {
        let fixture = try HelperProcessFixture(coldTrials: 2, trial: 1)
        var forged = fixture.argv
        forged[0] = "rimeai-voice-performance-helper"
        let runtime = RecordingHelperProcessRuntime()

        #expect(
            throws: VoicePerformanceTracerHelperProcessError
                .invalidArguments
        ) {
            try VoicePerformanceTracerHelperProcess(runtime: runtime).run(
                argv: forged,
                currentExecutablePath: fixture.executablePath
            )
        }
        #expect(runtime.events == [.parse(policyColdTrials: 32)])
    }
}

private final class RecordingHelperProcessRuntime:
    VoicePerformanceTracerHelperProcessRuntime
{
    enum Event: Equatable {
        case parse(policyColdTrials: UInt64)
        case verify
        case command
    }

    private(set) var events: [Event] = []
    private(set) var verifiedPath: String?
    private(set) var commandArguments:
        VoicePerformanceHelperProcessArguments?
    private(set) var commandBundle:
        VerifiedPerformanceTracerBundleContext?
    let verifiedBundle: VerifiedPerformanceTracerBundleContext?
    let verifyError: Error?

    init(
        verifiedBundle: VerifiedPerformanceTracerBundleContext? = nil,
        verifyError: Error? = nil
    ) {
        self.verifiedBundle = verifiedBundle
        self.verifyError = verifyError
    }

    func parseArguments(
        _ argv: [String],
        currentExecutablePath: String,
        policyColdTrials: UInt64
    ) throws -> VoicePerformanceHelperProcessArguments {
        events.append(.parse(policyColdTrials: policyColdTrials))
        return try VoicePerformanceHelperProcessArguments.parse(
            argv,
            currentExecutablePath: currentExecutablePath,
            policyColdTrials: policyColdTrials
        )
    }

    func verifyHelperBundle(
        declaredPath: String
    ) throws -> VerifiedPerformanceTracerBundleContext {
        events.append(.verify)
        verifiedPath = declaredPath
        if let verifyError { throw verifyError }
        guard let verifiedBundle else {
            throw HelperProcessFixtureError.failure
        }
        return verifiedBundle
    }

    func runCommand(
        arguments: VoicePerformanceHelperProcessArguments,
        verifiedBundle: VerifiedPerformanceTracerBundleContext
    ) throws {
        events.append(.command)
        commandArguments = arguments
        commandBundle = verifiedBundle
    }
}

private enum HelperProcessFixtureError: Error {
    case failure
}

private struct SensitiveHelperUnexpectedError:
    Error,
    CustomStringConvertible
{
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private struct HelperProcessFixture {
    let bundlePath = "/Applications/RimeAIVoicePerformanceTracer.bundle"
    let executablePath: String
    let argv: [String]
    let context: VerifiedPerformanceTracerBundleContext

    init(coldTrials: UInt64, trial: UInt64) throws {
        executablePath = bundlePath
            + VoicePerformanceTracerBundleLayout.helperExecutableSuffix
        argv = [
            executablePath,
            "--tracer-bundle", bundlePath,
            "--trial", String(trial),
            "--deadline-continuous-ns", "1000000000",
        ]

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
        let policyPrefix = "{\"cold_trials\":\(coldTrials),"
            + "\"collector\":{\"expected_cdhash\":\"\(String(repeating: "1", count: 40))\","
            + "\"expected_executable_path\":\"\(collectorPath)\","
            + "\"expected_executable_sha256\":\"\(String(repeating: "a", count: 64))\","
            + "\"expected_signing_identifier\":\"\(VoicePerformanceMeasurementPolicy.requiredCollectorSigningIdentifier)\","
            + "\"expected_team_identifier\":\"ABCDEFGHIJ\"},"
            + "\"control_protocol\":{\"id\":\"\(protocolIdentity.id)\",\"sha256\":\"\(protocolSHA)\"},"
            + "\"control_session_nonce\":\"\(String(repeating: "7", count: 64))\","
            + "\"control_socket_path\":\"/tmp/rimeai-performance.sock\","
        let policyData = Data(
            (policyPrefix
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
                + "\"expected_executable_path\":\"\(executablePath)\","
                + "\"expected_executable_sha256\":\"\(String(repeating: "c", count: 64))\","
                + "\"expected_signing_identifier\":\"\(VoicePerformanceMeasurementPolicy.requiredHelperSigningIdentifier)\","
                + "\"expected_team_identifier\":\"ABCDEFGHIJ\"},"
                + "\"release_policy_sha256\":\"\(String(repeating: "e", count: 64))\","
                + "\"schema_version\":2}").utf8
        )
        let measurementPolicy = try VoicePerformanceMeasurementPolicy
            .decodeCanonical(policyData)
        context = VerifiedPerformanceTracerBundleContext(
            outerPath: bundlePath,
            outerURL: URL(fileURLWithPath: bundlePath),
            measurementPolicy: measurementPolicy,
            driverPolicy: nil,
            selfStartToken: 10_001
        )
    }
}
