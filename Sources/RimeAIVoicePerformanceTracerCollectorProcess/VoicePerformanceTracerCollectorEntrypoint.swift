import RimeAIVoicePerformanceTracerProcessDarwin

public enum VoicePerformanceTracerCollectorEntrypoint {
    public static func run() -> Int32 {
        run(
            arguments: CommandLine.arguments,
            resolveCurrentExecutablePath: {
                try VoicePerformanceCurrentExecutablePath.resolve()
            },
            runProcess: { arguments, currentExecutablePath in
                try VoicePerformanceTracerCollectorProcess().run(
                    argv: arguments,
                    currentExecutablePath: currentExecutablePath
                )
            },
            writeDiagnostic:
                VoicePerformanceTracerEntrypointSupport
                    .writeStandardError
        )
    }

    static func run(
        arguments: [String],
        resolveCurrentExecutablePath: () throws -> String,
        runProcess: ([String], String) throws -> Void,
        writeDiagnostic: (String) -> Void
    ) -> Int32 {
        do {
            let currentExecutablePath =
                try resolveCurrentExecutablePath()
            try runProcess(arguments, currentExecutablePath)
            return VoicePerformanceTracerEntrypointExitStatus
                .success.rawValue
        } catch {
            let status = exitStatus(for: error)
            if let line =
                VoicePerformanceTracerEntrypointSupport.diagnosticLine(
                    role: .collector,
                    status: status
                )
            {
                writeDiagnostic(line)
            }
            return status.rawValue
        }
    }

    private static func exitStatus(
        for error: Error
    ) -> VoicePerformanceTracerEntrypointExitStatus {
        guard let processError =
            error as? VoicePerformanceTracerCollectorProcessError
        else {
            return .internalFailure
        }
        return switch processError {
        case .invalidArguments, .invalidResultPath:
            .usage
        case .collectionFailed:
            .data
        case .invalidTracerBundle, .resultPathAuthority,
             .resultPathOverlap,
             .driverGenerationMismatch, .driverAttestationMismatch:
            .authority
        case .deadlineExpired, .driverLaunchFailed, .driverExitFailed:
            .temporary
        case .transportFailure, .resultAlreadyExists,
             .resultWriteFailed, .resultCommitFailed,
             .resultDurabilityFailed,
             .resultInstallationIndeterminate:
            .io
        case .deadlineFailure, .resultCanonicalizationFailed,
             .cleanupFailed, .internalFailure:
            .internalFailure
        }
    }
}
