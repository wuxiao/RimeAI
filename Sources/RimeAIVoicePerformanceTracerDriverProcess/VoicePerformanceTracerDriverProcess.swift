import Foundation
import RimeAIVoicePerformanceTracerProcessDarwin

public enum VoicePerformanceTracerDriverProcessError:
    Error,
    Equatable,
    Sendable
{
    case invalidArguments
    case invalidTracerBundle
    case deadlineExpired
    case invalidVerifiedBundle
    case invalidDriverGeneration
    case invalidChallenge
    case nonceReuse
    case helperGenerationReuse
    case helperFailed
    case transportFailed
    case internalFailure
}

protocol VoicePerformanceTracerDriverProcessRuntime: AnyObject {
    func parseArguments(
        _ argv: [String],
        currentExecutablePath: String
    ) throws -> VoicePerformanceDriverProcessArguments
    func verifyDriverBundle(
        declaredPath: String
    ) throws -> VerifiedPerformanceTracerBundleContext
    func runCommand(
        arguments: VoicePerformanceDriverProcessArguments,
        verifiedBundle: VerifiedPerformanceTracerBundleContext
    ) throws
}

public final class VoicePerformanceTracerDriverProcess {
    private let runtime: any VoicePerformanceTracerDriverProcessRuntime

    public convenience init() {
        self.init(runtime: DarwinVoicePerformanceTracerDriverProcessRuntime())
    }

    init(runtime: any VoicePerformanceTracerDriverProcessRuntime) {
        self.runtime = runtime
    }

    public func run(
        argv: [String],
        currentExecutablePath: String
    ) throws {
        let arguments: VoicePerformanceDriverProcessArguments
        do {
            arguments = try runtime.parseArguments(
                argv,
                currentExecutablePath: currentExecutablePath
            )
        } catch {
            throw Self.mapArgumentError(error)
        }

        let verifiedBundle: VerifiedPerformanceTracerBundleContext
        do {
            verifiedBundle = try runtime.verifyDriverBundle(
                declaredPath: arguments.tracerBundlePath
            )
        } catch {
            throw VoicePerformanceTracerDriverProcessError
                .invalidTracerBundle
        }

        do {
            try runtime.runCommand(
                arguments: arguments,
                verifiedBundle: verifiedBundle
            )
        } catch {
            throw Self.mapCommandError(error)
        }
    }

    private static func mapArgumentError(
        _ error: Error
    ) -> VoicePerformanceTracerDriverProcessError {
        guard let processError = error as? VoicePerformanceTracerProcessError
        else {
            return .internalFailure
        }
        return switch processError {
        case .invalidArguments, .invalidDeadline:
            .invalidArguments
        case .invalidTracerBundle:
            .invalidTracerBundle
        default:
            .internalFailure
        }
    }

    private static func mapCommandError(
        _ error: Error
    ) -> VoicePerformanceTracerDriverProcessError {
        guard let commandError =
            error as? VoicePerformanceTracerDriverCommandError
        else {
            return .internalFailure
        }
        return switch commandError {
        case .deadlineExpired:
            .deadlineExpired
        case .invalidVerifiedBundle:
            .invalidVerifiedBundle
        case .invalidDriverGeneration:
            .invalidDriverGeneration
        case .invalidChallenge:
            .invalidChallenge
        case .nonceReuse:
            .nonceReuse
        case .helperGenerationReuse:
            .helperGenerationReuse
        case .helperFailed:
            .helperFailed
        case .transportFailed:
            .transportFailed
        }
    }
}

private final class DarwinVoicePerformanceTracerDriverProcessRuntime:
    VoicePerformanceTracerDriverProcessRuntime
{
    private let commandRuntime = DarwinVoicePerformanceTracerDriverRuntime()

    func parseArguments(
        _ argv: [String],
        currentExecutablePath: String
    ) throws -> VoicePerformanceDriverProcessArguments {
        try VoicePerformanceDriverProcessArguments.parse(
            argv,
            currentExecutablePath: currentExecutablePath
        )
    }

    func verifyDriverBundle(
        declaredPath: String
    ) throws -> VerifiedPerformanceTracerBundleContext {
        try PerformanceTracerBundleVerifier().verify(
            role: .driver,
            declaredTracerBundlePath: declaredPath
        )
    }

    func runCommand(
        arguments: VoicePerformanceDriverProcessArguments,
        verifiedBundle: VerifiedPerformanceTracerBundleContext
    ) throws {
        try VoicePerformanceTracerDriverCommand.run(
            arguments: arguments,
            verifiedBundle: verifiedBundle,
            runtime: commandRuntime
        )
    }
}
