import RimeAIVoicePerformanceTracerProcessDarwin

public enum VoicePerformanceTracerHelperEntrypoint {
    public static func run() -> Int32 {
        run(
            arguments: CommandLine.arguments,
            resolveCurrentExecutablePath: {
                try VoicePerformanceCurrentExecutablePath.resolve()
            },
            runProcess: { arguments, currentExecutablePath in
                try VoicePerformanceTracerHelperProcess().run(
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
                    role: .helper,
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
            error as? VoicePerformanceTracerHelperProcessError
        else {
            return .internalFailure
        }
        return switch processError {
        case .invalidArguments:
            .usage
        case .invalidChallenge, .invalidFrame,
             .unexpectedFrameAfterReady:
            .data
        case .invalidTracerBundle, .invalidVerifiedBundle,
             .invalidHelperGeneration:
            .authority
        case .deadlineExpired:
            .temporary
        case .peerDisconnectedEarly, .transportFailed:
            .io
        case .internalFailure:
            .internalFailure
        }
    }
}
