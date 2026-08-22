import Testing

@testable import RimeAIVoicePerformanceTracerHelperProcess

@Suite("Voice performance tracer helper entrypoint")
struct VoicePerformanceTracerHelperEntrypointTests {
    @Test("success forwards untouched argv and emits no diagnostics")
    func successfulEntrypointIsSilent() {
        let argv = ["caller-owned-argv-zero", "--flag"]
        var forwarded: ([String], String)?
        var diagnostics: [String] = []

        let status = VoicePerformanceTracerHelperEntrypoint.run(
            arguments: argv,
            resolveCurrentExecutablePath: { "/kernel/helper" },
            runProcess: { forwarded = ($0, $1) },
            writeDiagnostic: { diagnostics.append($0) }
        )

        #expect(status == 0)
        #expect(forwarded?.0 == argv)
        #expect(forwarded?.1 == "/kernel/helper")
        #expect(diagnostics.isEmpty)
    }

    @Test("helper errors map exhaustively to fixed exit diagnostics")
    func mapsEveryHelperErrorWithoutEchoingDescriptions() {
        let prefix = "rimeai-voice-performance-helper:"
        let cases: [(Error, Int32, String)] = [
            (VoicePerformanceTracerHelperProcessError.invalidArguments,
             64, prefix + "E_USAGE\n"),
            (VoicePerformanceTracerHelperProcessError.invalidChallenge,
             65, prefix + "E_DATA\n"),
            (VoicePerformanceTracerHelperProcessError.invalidFrame,
             65, prefix + "E_DATA\n"),
            (VoicePerformanceTracerHelperProcessError.unexpectedFrameAfterReady,
             65, prefix + "E_DATA\n"),
            (VoicePerformanceTracerHelperProcessError.invalidTracerBundle,
             77, prefix + "E_AUTHORITY\n"),
            (VoicePerformanceTracerHelperProcessError.invalidVerifiedBundle,
             77, prefix + "E_AUTHORITY\n"),
            (VoicePerformanceTracerHelperProcessError.invalidHelperGeneration,
             77, prefix + "E_AUTHORITY\n"),
            (VoicePerformanceTracerHelperProcessError.deadlineExpired,
             75, prefix + "E_TEMPORARY\n"),
            (VoicePerformanceTracerHelperProcessError.peerDisconnectedEarly,
             74, prefix + "E_IO\n"),
            (VoicePerformanceTracerHelperProcessError.transportFailed,
             74, prefix + "E_IO\n"),
            (VoicePerformanceTracerHelperProcessError.internalFailure,
             70, prefix + "E_INTERNAL\n"),
            (HelperEntrypointFixtureError.sensitiveDescription,
             70, prefix + "E_INTERNAL\n"),
        ]

        for (error, expectedStatus, expectedDiagnostic) in cases {
            var diagnostics: [String] = []
            let status = VoicePerformanceTracerHelperEntrypoint.run(
                arguments: ["argv-zero"],
                resolveCurrentExecutablePath: { "/kernel/helper" },
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

private enum HelperEntrypointFixtureError: Error {
    case sensitiveDescription
}
