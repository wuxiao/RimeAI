import Foundation
import RimeAIVoicePerformanceControlCore
import Testing

@testable import RimeAIVoicePerformanceTracerDriverProcess
@testable import RimeAIVoicePerformanceTracerProcessDarwin

@Suite("Voice performance tracer driver process facade")
struct VoicePerformanceTracerDriverProcessTests {
    @Test("production driver facade rejects malformed argv before verification")
    func productionFacadeIsWired() {
        #expect(
            throws: VoicePerformanceTracerDriverProcessError
                .invalidArguments
        ) {
            try VoicePerformanceTracerDriverProcess().run(
                argv: ["forged-driver"],
                currentExecutablePath: "/private/tmp/real-driver"
            )
        }
    }

    @Test("invalid argv stops before bundle verification or command effects")
    func invalidArgumentsHaveNoAuthorityEffects() {
        let runtime = RecordingDriverProcessRuntime(
            parseError: VoicePerformanceTracerProcessError.invalidArguments
        )

        #expect(
            throws: VoicePerformanceTracerDriverProcessError
                .invalidArguments
        ) {
            try VoicePerformanceTracerDriverProcess(runtime: runtime).run(
                argv: ["forged-driver"],
                currentExecutablePath: "/private/tmp/real-driver"
            )
        }
        #expect(runtime.events == [.parse])
    }

    @Test("driver facade orders parse then driver verification then command")
    func runsExactFacadeSequence() throws {
        let fixture = try DriverProcessFixture()
        let runtime = RecordingDriverProcessRuntime(
            verifiedBundle: fixture.context
        )

        try VoicePerformanceTracerDriverProcess(runtime: runtime).run(
            argv: fixture.argv,
            currentExecutablePath: fixture.executablePath
        )

        #expect(runtime.events == [.parse, .verify, .command])
        #expect(runtime.verifiedPath == fixture.bundlePath)
        #expect(runtime.commandArguments?.tracerBundlePath == fixture.bundlePath)
        #expect(runtime.commandBundle?.outerPath == fixture.bundlePath)
    }

    @Test("driver verification failure prevents the command")
    func verificationFailureHasNoCommandEffects() throws {
        let fixture = try DriverProcessFixture()
        let runtime = RecordingDriverProcessRuntime(
            verifyError: VoicePerformanceTracerProcessError
                .invalidTracerBundle
        )

        #expect(
            throws: VoicePerformanceTracerDriverProcessError
                .invalidTracerBundle
        ) {
            try VoicePerformanceTracerDriverProcess(runtime: runtime).run(
                argv: fixture.argv,
                currentExecutablePath: fixture.executablePath
            )
        }
        #expect(runtime.events == [.parse, .verify])
    }

    @Test("unexpected verification errors reach the entrypoint as internal")
    func unexpectedVerificationErrorIsInternalAndRedacted() throws {
        let fixture = try DriverProcessFixture()
        let secret = "driver-verify-secret-1de8"
        let runtime = RecordingDriverProcessRuntime(
            verifyError: SensitiveDriverUnexpectedError(secret)
        )
        var diagnostics: [String] = []

        let status = VoicePerformanceTracerDriverEntrypoint.run(
            arguments: fixture.argv,
            resolveCurrentExecutablePath: { fixture.executablePath },
            runProcess: { arguments, executablePath in
                try VoicePerformanceTracerDriverProcess(
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
                == ["rimeai-voice-performance-driver:E_INTERNAL\n"]
        )
        #expect(diagnostics.allSatisfy { !$0.contains(secret) })
        #expect(runtime.events == [.parse, .verify])
    }

    @Test("driver rejects every free policy or resource override")
    func rejectsFreeAuthorityFlags() throws {
        let fixture = try DriverProcessFixture()
        for flag in ["--policy", "--socket", "--artifact", "--engine"] {
            let runtime = RecordingDriverProcessRuntime()
            #expect(
                throws: VoicePerformanceTracerDriverProcessError
                    .invalidArguments
            ) {
                try VoicePerformanceTracerDriverProcess(
                    runtime: runtime
                ).run(
                    argv: fixture.argv + [flag, "/private/tmp/free"],
                    currentExecutablePath: fixture.executablePath
                )
            }
            #expect(runtime.events == [.parse])
        }
    }

    @Test("driver argv zero must byte-match the live kernel path")
    func rejectsForgedArgumentZero() throws {
        let fixture = try DriverProcessFixture()
        var forged = fixture.argv
        forged[0] = "rimeai-voice-performance-driver"
        let runtime = RecordingDriverProcessRuntime()

        #expect(
            throws: VoicePerformanceTracerDriverProcessError
                .invalidArguments
        ) {
            try VoicePerformanceTracerDriverProcess(runtime: runtime).run(
                argv: forged,
                currentExecutablePath: fixture.executablePath
            )
        }
        #expect(runtime.events == [.parse])
    }
}

private final class RecordingDriverProcessRuntime:
    VoicePerformanceTracerDriverProcessRuntime
{
    enum Event: Equatable {
        case parse
        case verify
        case command
    }

    private(set) var events: [Event] = []
    private(set) var verifiedPath: String?
    private(set) var commandArguments:
        VoicePerformanceDriverProcessArguments?
    private(set) var commandBundle:
        VerifiedPerformanceTracerBundleContext?
    let parseError: Error?
    let verifyError: Error?
    let verifiedBundle: VerifiedPerformanceTracerBundleContext?
    let commandError: Error?

    init(
        parseError: Error? = nil,
        verifyError: Error? = nil,
        verifiedBundle: VerifiedPerformanceTracerBundleContext? = nil,
        commandError: Error? = nil
    ) {
        self.parseError = parseError
        self.verifyError = verifyError
        self.verifiedBundle = verifiedBundle
        self.commandError = commandError
    }

    func parseArguments(
        _ argv: [String],
        currentExecutablePath: String
    ) throws -> VoicePerformanceDriverProcessArguments {
        events.append(.parse)
        if let parseError { throw parseError }
        return try VoicePerformanceDriverProcessArguments.parse(
            argv,
            currentExecutablePath: currentExecutablePath
        )
    }

    func verifyDriverBundle(
        declaredPath: String
    ) throws -> VerifiedPerformanceTracerBundleContext {
        events.append(.verify)
        verifiedPath = declaredPath
        if let verifyError { throw verifyError }
        guard let verifiedBundle else {
            throw DriverProcessFixtureError.failure
        }
        return verifiedBundle
    }

    func runCommand(
        arguments: VoicePerformanceDriverProcessArguments,
        verifiedBundle: VerifiedPerformanceTracerBundleContext
    ) throws {
        events.append(.command)
        commandArguments = arguments
        commandBundle = verifiedBundle
        if let commandError { throw commandError }
    }
}

private enum DriverProcessFixtureError: Error {
    case failure
}

private struct SensitiveDriverUnexpectedError:
    Error,
    CustomStringConvertible
{
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private struct DriverProcessFixture {
    let bundlePath = "/Applications/RimeAIVoicePerformanceTracer.bundle"
    let executablePath: String
    let argv: [String]
    let context: VerifiedPerformanceTracerBundleContext

    init() throws {
        executablePath = bundlePath
            + VoicePerformanceTracerBundleLayout.driverExecutableSuffix
        argv = [
            executablePath,
            "--tracer-bundle", bundlePath,
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
        let helperPath = bundlePath
            + VoicePerformanceTracerBundleLayout.helperExecutableSuffix
        let policyData = Data(
            ("{\"cold_trials\":1,"
                + "\"collector\":{\"expected_cdhash\":\"\(String(repeating: "1", count: 40))\","
                + "\"expected_executable_path\":\"\(collectorPath)\","
                + "\"expected_executable_sha256\":\"\(String(repeating: "a", count: 64))\","
                + "\"expected_signing_identifier\":\"\(VoicePerformanceMeasurementPolicy.requiredCollectorSigningIdentifier)\","
                + "\"expected_team_identifier\":\"ABCDEFGHIJ\"},"
                + "\"control_protocol\":{\"id\":\"\(protocolIdentity.id)\",\"sha256\":\"\(protocolSHA)\"},"
                + "\"control_session_nonce\":\"\(String(repeating: "7", count: 64))\","
                + "\"control_socket_path\":\"/tmp/rimeai-performance.sock\","
                + "\"driver\":{\"expected_cdhash\":\"\(String(repeating: "2", count: 40))\","
                + "\"expected_executable_path\":\"\(executablePath)\","
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
        let measurementPolicy = try VoicePerformanceMeasurementPolicy
            .decodeCanonical(policyData)
        context = VerifiedPerformanceTracerBundleContext(
            outerPath: bundlePath,
            outerURL: URL(fileURLWithPath: bundlePath),
            measurementPolicy: measurementPolicy,
            driverPolicy: driverPolicy,
            selfStartToken: 9_001
        )
    }
}
