import RimeAIVoicePerformanceTracerProcessDarwin

public enum VoicePerformanceTracerDriverEntrypoint {
    public static func run() -> Int32 {
        run(
            arguments: CommandLine.arguments,
            resolveCurrentExecutablePath: {
                try VoicePerformanceCurrentExecutablePath.resolve()
            },
            runProcess: { arguments, currentExecutablePath in
                try VoicePerformanceTracerDriverProcess().run(
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
                    role: .driver,
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
            error as? VoicePerformanceTracerDriverProcessError
        else {
            return .internalFailure
        }
        return switch processError {
        case .invalidArguments:
            .usage
        case .invalidChallenge, .nonceReuse:
            .data
        case .invalidTracerBundle, .invalidVerifiedBundle,
             .invalidDriverGeneration, .helperGenerationReuse:
            .authority
        case .deadlineExpired, .helperFailed:
            .temporary
        case .transportFailed:
            .io
        case .internalFailure:
            .internalFailure
        }
    }
}
