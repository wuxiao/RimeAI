import Testing

@testable import RimeAIVoicePerformanceTracerDriverProcess

@Suite("Voice performance tracer driver entrypoint")
struct VoicePerformanceTracerDriverEntrypointTests {
    @Test("success forwards untouched argv and emits no diagnostics")
    func successfulEntrypointIsSilent() {
        let argv = ["caller-owned-argv-zero", "--flag"]
        var forwarded: ([String], String)?
        var diagnostics: [String] = []

        let status = VoicePerformanceTracerDriverEntrypoint.run(
            arguments: argv,
            resolveCurrentExecutablePath: { "/kernel/driver" },
            runProcess: { forwarded = ($0, $1) },
            writeDiagnostic: { diagnostics.append($0) }
        )

        #expect(status == 0)
        #expect(forwarded?.0 == argv)
        #expect(forwarded?.1 == "/kernel/driver")
        #expect(diagnostics.isEmpty)
    }

    @Test("driver errors map exhaustively to fixed exit diagnostics")
    func mapsEveryDriverErrorWithoutEchoingDescriptions() {
        let prefix = "rimeai-voice-performance-driver:"
        let cases: [(Error, Int32, String)] = [
            (VoicePerformanceTracerDriverProcessError.invalidArguments,
             64, prefix + "E_USAGE\n"),
            (VoicePerformanceTracerDriverProcessError.invalidChallenge,
             65, prefix + "E_DATA\n"),
            (VoicePerformanceTracerDriverProcessError.nonceReuse,
             65, prefix + "E_DATA\n"),
            (VoicePerformanceTracerDriverProcessError.helperGenerationReuse,
             77, prefix + "E_AUTHORITY\n"),
            (VoicePerformanceTracerDriverProcessError.invalidTracerBundle,
             77, prefix + "E_AUTHORITY\n"),
            (VoicePerformanceTracerDriverProcessError.invalidVerifiedBundle,
             77, prefix + "E_AUTHORITY\n"),
            (VoicePerformanceTracerDriverProcessError.invalidDriverGeneration,
             77, prefix + "E_AUTHORITY\n"),
            (VoicePerformanceTracerDriverProcessError.deadlineExpired,
             75, prefix + "E_TEMPORARY\n"),
            (VoicePerformanceTracerDriverProcessError.helperFailed,
             75, prefix + "E_TEMPORARY\n"),
            (VoicePerformanceTracerDriverProcessError.transportFailed,
             74, prefix + "E_IO\n"),
            (VoicePerformanceTracerDriverProcessError.internalFailure,
             70, prefix + "E_INTERNAL\n"),
            (DriverEntrypointFixtureError.sensitiveDescription,
             70, prefix + "E_INTERNAL\n"),
        ]

        for (error, expectedStatus, expectedDiagnostic) in cases {
            var diagnostics: [String] = []
            let status = VoicePerformanceTracerDriverEntrypoint.run(
                arguments: ["argv-zero"],
                resolveCurrentExecutablePath: { "/kernel/driver" },
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

private enum DriverEntrypointFixtureError: Error {
    case sensitiveDescription
}
