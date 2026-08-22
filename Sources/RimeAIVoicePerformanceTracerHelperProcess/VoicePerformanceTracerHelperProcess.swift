import Foundation
import RimeAIVoicePerformanceControlCore
import RimeAIVoicePerformanceTracerProcessDarwin

public enum VoicePerformanceTracerHelperProcessError:
    Error,
    Equatable,
    Sendable
{
    case invalidArguments
    case invalidTracerBundle
    case deadlineExpired
    case invalidVerifiedBundle
    case invalidHelperGeneration
    case invalidChallenge
    case invalidFrame
    case peerDisconnectedEarly
    case unexpectedFrameAfterReady
    case transportFailed
    case internalFailure
}

protocol VoicePerformanceTracerHelperProcessRuntime: AnyObject {
    func parseArguments(
        _ argv: [String],
        currentExecutablePath: String,
        policyColdTrials: UInt64
    ) throws -> VoicePerformanceHelperProcessArguments
    func verifyHelperBundle(
        declaredPath: String
    ) throws -> VerifiedPerformanceTracerBundleContext
    func runCommand(
        arguments: VoicePerformanceHelperProcessArguments,
        verifiedBundle: VerifiedPerformanceTracerBundleContext
    ) throws
}

public final class VoicePerformanceTracerHelperProcess {
    private let runtime: any VoicePerformanceTracerHelperProcessRuntime

    public convenience init() {
        self.init(runtime: DarwinVoicePerformanceTracerHelperProcessRuntime())
    }

    init(runtime: any VoicePerformanceTracerHelperProcessRuntime) {
        self.runtime = runtime
    }

    public func run(
        argv: [String],
        currentExecutablePath: String
    ) throws {
        let preflight: VoicePerformanceHelperProcessArguments
        do {
            preflight = try runtime.parseArguments(
                argv,
                currentExecutablePath: currentExecutablePath,
                policyColdTrials:
                    PerformanceControlSessionBinding
                        .supportedTrials.upperBound
            )
        } catch {
            throw Self.mapArgumentError(error)
        }

        let verifiedBundle: VerifiedPerformanceTracerBundleContext
        do {
            verifiedBundle = try runtime.verifyHelperBundle(
                declaredPath: preflight.tracerBundlePath
            )
        } catch {
            throw VoicePerformanceTracerHelperProcessError
                .invalidTracerBundle
        }

        let boundedArguments: VoicePerformanceHelperProcessArguments
        do {
            boundedArguments = try runtime.parseArguments(
                argv,
                currentExecutablePath: currentExecutablePath,
                policyColdTrials:
                    verifiedBundle.measurementPolicy.coldTrials
            )
        } catch {
            throw Self.mapArgumentError(error)
        }

        do {
            try runtime.runCommand(
                arguments: boundedArguments,
                verifiedBundle: verifiedBundle
            )
        } catch {
            throw Self.mapCommandError(error)
        }
    }

    private static func mapArgumentError(
        _ error: Error
    ) -> VoicePerformanceTracerHelperProcessError {
        guard let processError = error as? VoicePerformanceTracerProcessError
        else {
            return .internalFailure
        }
        return switch processError {
        case .invalidArguments, .invalidDeadline, .invalidTrial:
            .invalidArguments
        case .invalidTracerBundle:
            .invalidTracerBundle
        default:
            .internalFailure
        }
    }

    private static func mapCommandError(
        _ error: Error
    ) -> VoicePerformanceTracerHelperProcessError {
        guard let commandError =
            error as? VoicePerformanceTracerHelperCommandError
        else {
            return .internalFailure
        }
        return switch commandError {
        case .deadlineExpired:
            .deadlineExpired
        case .invalidVerifiedBundle:
            .invalidVerifiedBundle
        case .invalidHelperGeneration:
            .invalidHelperGeneration
        case .invalidChallenge:
            .invalidChallenge
        case .invalidFrame:
            .invalidFrame
        case .peerDisconnectedEarly:
            .peerDisconnectedEarly
        case .unexpectedFrameAfterReady:
            .unexpectedFrameAfterReady
        case .transportFailed:
            .transportFailed
        }
    }
}

private final class DarwinVoicePerformanceTracerHelperProcessRuntime:
    VoicePerformanceTracerHelperProcessRuntime
{
    private let commandRuntime = DarwinVoicePerformanceTracerHelperRuntime()

    func parseArguments(
        _ argv: [String],
        currentExecutablePath: String,
        policyColdTrials: UInt64
    ) throws -> VoicePerformanceHelperProcessArguments {
        try VoicePerformanceHelperProcessArguments.parse(
            argv,
            currentExecutablePath: currentExecutablePath,
            policyColdTrials: policyColdTrials
        )
    }

    func verifyHelperBundle(
        declaredPath: String
    ) throws -> VerifiedPerformanceTracerBundleContext {
        try PerformanceTracerBundleVerifier().verify(
            role: .helper,
            declaredTracerBundlePath: declaredPath
        )
    }

    func runCommand(
        arguments: VoicePerformanceHelperProcessArguments,
        verifiedBundle: VerifiedPerformanceTracerBundleContext
    ) throws {
        try VoicePerformanceTracerHelperCommand.run(
            arguments: arguments,
            verifiedBundle: verifiedBundle,
            runtime: commandRuntime
        )
    }
}
