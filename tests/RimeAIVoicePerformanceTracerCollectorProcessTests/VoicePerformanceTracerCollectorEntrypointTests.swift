import Testing

@testable import RimeAIVoicePerformanceTracerCollectorProcess

@Suite("Voice performance tracer collector entrypoint")
struct VoicePerformanceTracerCollectorEntrypointTests {
    @Test("success resolves the kernel path and forwards argv without output")
    func successfulEntrypointIsSilent() {
        let argv = ["caller-owned-argv-zero", "--flag"]
        let currentPath = "/private/tmp/kernel-owned-path"
        var receivedArguments: [String]?
        var receivedPath: String?
        var diagnostics: [String] = []

        let status = VoicePerformanceTracerCollectorEntrypoint.run(
            arguments: argv,
            resolveCurrentExecutablePath: { currentPath },
            runProcess: { arguments, path in
                receivedArguments = arguments
                receivedPath = path
            },
            writeDiagnostic: { diagnostics.append($0) }
        )

        #expect(status == 0)
        #expect(receivedArguments == argv)
        #expect(receivedPath == currentPath)
        #expect(diagnostics.isEmpty)
    }

    @Test("collector errors map exhaustively to fixed exit diagnostics")
    func mapsEveryCollectorErrorWithoutEchoingDescriptions() {
        let cases: [(Error, Int32, String)] = [
            (VoicePerformanceTracerCollectorProcessError.invalidArguments,
             64, "rimeai-voice-performance-tracer:E_USAGE\n"),
            (VoicePerformanceTracerCollectorProcessError.invalidResultPath,
             64, "rimeai-voice-performance-tracer:E_USAGE\n"),
            (VoicePerformanceTracerCollectorProcessError.resultPathAuthority,
             77, "rimeai-voice-performance-tracer:E_AUTHORITY\n"),
            (VoicePerformanceTracerCollectorProcessError.collectionFailed,
             65, "rimeai-voice-performance-tracer:E_DATA\n"),
            (VoicePerformanceTracerCollectorProcessError.invalidTracerBundle,
             77, "rimeai-voice-performance-tracer:E_AUTHORITY\n"),
            (VoicePerformanceTracerCollectorProcessError.resultPathOverlap,
             77, "rimeai-voice-performance-tracer:E_AUTHORITY\n"),
            (VoicePerformanceTracerCollectorProcessError.driverGenerationMismatch,
             77, "rimeai-voice-performance-tracer:E_AUTHORITY\n"),
            (VoicePerformanceTracerCollectorProcessError.driverAttestationMismatch,
             77, "rimeai-voice-performance-tracer:E_AUTHORITY\n"),
            (VoicePerformanceTracerCollectorProcessError.deadlineExpired,
             75, "rimeai-voice-performance-tracer:E_TEMPORARY\n"),
            (VoicePerformanceTracerCollectorProcessError.driverLaunchFailed,
             75, "rimeai-voice-performance-tracer:E_TEMPORARY\n"),
            (VoicePerformanceTracerCollectorProcessError.driverExitFailed,
             75, "rimeai-voice-performance-tracer:E_TEMPORARY\n"),
            (VoicePerformanceTracerCollectorProcessError.transportFailure,
             74, "rimeai-voice-performance-tracer:E_IO\n"),
            (VoicePerformanceTracerCollectorProcessError.resultAlreadyExists,
             74, "rimeai-voice-performance-tracer:E_IO\n"),
            (VoicePerformanceTracerCollectorProcessError.resultWriteFailed,
             74, "rimeai-voice-performance-tracer:E_IO\n"),
            (VoicePerformanceTracerCollectorProcessError.resultCommitFailed,
             74, "rimeai-voice-performance-tracer:E_IO\n"),
            (VoicePerformanceTracerCollectorProcessError.resultDurabilityFailed,
             74, "rimeai-voice-performance-tracer:E_IO\n"),
            (VoicePerformanceTracerCollectorProcessError.resultInstallationIndeterminate,
             74, "rimeai-voice-performance-tracer:E_IO\n"),
            (VoicePerformanceTracerCollectorProcessError.deadlineFailure,
             70, "rimeai-voice-performance-tracer:E_INTERNAL\n"),
            (VoicePerformanceTracerCollectorProcessError.resultCanonicalizationFailed,
             70, "rimeai-voice-performance-tracer:E_INTERNAL\n"),
            (VoicePerformanceTracerCollectorProcessError.cleanupFailed,
             70, "rimeai-voice-performance-tracer:E_INTERNAL\n"),
            (VoicePerformanceTracerCollectorProcessError.internalFailure,
             70, "rimeai-voice-performance-tracer:E_INTERNAL\n"),
            (EntrypointFixtureError.sensitiveDescription,
             70, "rimeai-voice-performance-tracer:E_INTERNAL\n"),
        ]

        for (error, expectedStatus, expectedDiagnostic) in cases {
            var diagnostics: [String] = []
            let status = VoicePerformanceTracerCollectorEntrypoint.run(
                arguments: ["argv-zero"],
                resolveCurrentExecutablePath: { "/kernel/path" },
                runProcess: { _, _ in throw error },
                writeDiagnostic: { diagnostics.append($0) }
            )

            #expect(status == expectedStatus)
            #expect(diagnostics == [expectedDiagnostic])
            #expect(
                diagnostics.first?.contains("sensitive") == false
            )
        }
    }
}

private enum EntrypointFixtureError: Error {
    case sensitiveDescription
}
