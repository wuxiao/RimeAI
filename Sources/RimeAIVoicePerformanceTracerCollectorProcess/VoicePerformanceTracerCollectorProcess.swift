import Foundation
import RimeAIVoicePerformanceCollector
import RimeAIVoicePerformanceControlCore
import RimeAIVoicePerformanceTracerProcessDarwin

public enum VoicePerformanceTracerCollectorProcessError:
    String,
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case invalidArguments = "E_ARGUMENTS"
    case invalidTracerBundle = "E_TRACER_BUNDLE"
    case invalidResultPath = "E_RESULT_PATH"
    case resultPathAuthority = "E_RESULT_AUTHORITY"
    case resultPathOverlap = "E_RESULT_OVERLAP"
    case deadlineFailure = "E_DEADLINE"
    case deadlineExpired = "E_DEADLINE_EXPIRED"
    case transportFailure = "E_TRANSPORT"
    case driverLaunchFailed = "E_DRIVER_LAUNCH"
    case driverGenerationMismatch = "E_DRIVER_GENERATION"
    case collectionFailed = "E_COLLECTION"
    case driverAttestationMismatch = "E_DRIVER_ATTESTATION"
    case driverExitFailed = "E_DRIVER_EXIT"
    case resultCanonicalizationFailed = "E_RESULT_CANONICAL"
    case resultAlreadyExists = "E_RESULT_EXISTS"
    case resultWriteFailed = "E_RESULT_WRITE"
    case resultCommitFailed = "E_RESULT_COMMIT"
    case resultDurabilityFailed = "E_RESULT_DURABILITY"
    case resultInstallationIndeterminate = "E_RESULT_INDETERMINATE"
    case cleanupFailed = "E_CLEANUP"
    case internalFailure = "E_INTERNAL"

    public var code: String { rawValue }
    public var description: String { rawValue }
}

struct VoicePerformanceTracerCollectorVerifiedContext: Sendable {
    let outerPath: String
    let measurementPolicy: VoicePerformanceMeasurementPolicy
    let driverPolicy: SealedPerformanceControlDriverPolicy
    let selfStartToken: UInt64
    let authenticatedProductionDriver = false
}

struct VoicePerformanceTracerCollectorGlobalDeadline: Sendable {
    /// The sole absolute mach-continuous deadline passed to every child.
    let processDeadline: VoicePerformanceContinuousDeadline
    /// The collector view of that same runtime-owned deadline budget.
    let collectorDeadline: ContinuousClock.Instant
}

/// Stateful system boundary for one collector command invocation.
///
/// A successful `launchPreparedDriver` transfers exact-generation lifecycle
/// ownership to the runtime. `terminateDriverGroupAndReap` must remain
/// effective and idempotent even when generation validation, binding, normal
/// wait, or result publication has already failed.
protocol VoicePerformanceTracerCollectorProcessRuntime: AnyObject {
    func parseArguments(
        _ argv: [String],
        currentExecutablePath: String
    ) throws -> VoicePerformanceCollectorProcessArguments

    func verifyCollectorBundle(
        declaredPath: String
    ) throws -> VoicePerformanceTracerCollectorVerifiedContext

    func makeGlobalDeadline()
        throws -> VoicePerformanceTracerCollectorGlobalDeadline
    func hasTimeRemaining(
        before deadline: VoicePerformanceTracerCollectorGlobalDeadline
    ) throws -> Bool

    func startTransport(socketPath: String) throws
    /// Atomically spawns, adopts, and prepares a new driver process group.
    /// Throwing guarantees that the runtime has already terminated and reaped
    /// any child it may have created. Returning transfers cleanup authority to
    /// the runtime until normal wait or explicit teardown completes.
    func launchPreparedDriver(
        executablePath: String,
        argv: [String]
    ) throws -> VoicePerformanceSupervisedProcessGeneration
    func bindLaunchedDriver(
        _ identity: VoicePerformanceTracerLaunchedDriverIdentity
    ) throws
    func collect(
        _ request: VoicePerformanceTracerCollectionRequest,
        deadline: ContinuousClock.Instant
    ) throws -> VoicePerformanceTracerResult
    /// Waits at most the driver's 15-second exit phase and never beyond the
    /// command's one global deadline. Success proves exit zero and an empty
    /// process group; failure retains cleanup authority.
    func waitForSucceededDriver(
        before deadline: VoicePerformanceTracerCollectorGlobalDeadline
    ) throws
    func closeTransport()
    func terminateDriverGroupAndReap() throws
    func writeResult(
        _ data: Data,
        to resultPath: String,
        before deadline: VoicePerformanceContinuousDeadline
    ) throws
}

public final class VoicePerformanceTracerCollectorProcess {
    private let runtime: any VoicePerformanceTracerCollectorProcessRuntime

    public convenience init() {
        self.init(
            runtime: DarwinVoicePerformanceTracerCollectorProcessRuntime()
        )
    }

    init(runtime: any VoicePerformanceTracerCollectorProcessRuntime) {
        self.runtime = runtime
    }

    public func run(
        argv: [String],
        currentExecutablePath: String
    ) throws {
        var driverOwnershipAcquired = false
        var transportClosed = false

        func closeTransportOnce() {
            guard !transportClosed else { return }
            runtime.closeTransport()
            transportClosed = true
        }

        do {
            let arguments: VoicePerformanceCollectorProcessArguments
            do {
                arguments = try runtime.parseArguments(
                    argv,
                    currentExecutablePath: currentExecutablePath
                )
            } catch {
                throw Self.mapProcessError(
                    error,
                    fallback: .invalidArguments
                )
            }

            let context: VoicePerformanceTracerCollectorVerifiedContext
            do {
                context = try runtime.verifyCollectorBundle(
                    declaredPath: arguments.tracerBundlePath
                )
            } catch VoicePerformanceTracerProcessError
                .invalidTracerBundle
            {
                throw VoicePerformanceTracerCollectorProcessError
                    .invalidTracerBundle
            } catch {
                throw VoicePerformanceTracerCollectorProcessError
                    .internalFailure
            }
            guard context.outerPath == arguments.tracerBundlePath,
                  !context.authenticatedProductionDriver,
                  !context.measurementPolicy.authenticatedProductionDriver,
                  !context.driverPolicy.authenticatedProductionDriver,
                  context.selfStartToken > 0
            else {
                throw VoicePerformanceTracerCollectorProcessError
                    .invalidTracerBundle
            }
            guard !Self.resultPathOverlapsProtectedInput(
                arguments.resultPath,
                context: context
            ) else {
                throw VoicePerformanceTracerCollectorProcessError
                    .resultPathOverlap
            }

            let request: VoicePerformanceTracerCollectionRequest
            do {
                request = try VoicePerformanceTracerCollectionRequest(
                    measurementPolicy: context.measurementPolicy,
                    driverPolicy: context.driverPolicy
                )
            } catch is VoicePerformanceTracerCollectorError {
                throw VoicePerformanceTracerCollectorProcessError
                    .invalidTracerBundle
            } catch {
                throw VoicePerformanceTracerCollectorProcessError
                    .internalFailure
            }

            let deadline: VoicePerformanceTracerCollectorGlobalDeadline
            do {
                deadline = try runtime.makeGlobalDeadline()
                guard try runtime.hasTimeRemaining(before: deadline) else {
                    throw VoicePerformanceTracerCollectorProcessError
                        .deadlineExpired
                }
            } catch let error as VoicePerformanceTracerCollectorProcessError {
                throw error
            } catch is VoicePerformanceTracerProcessError {
                throw VoicePerformanceTracerCollectorProcessError
                    .deadlineFailure
            } catch {
                throw VoicePerformanceTracerCollectorProcessError
                    .internalFailure
            }

            do {
                try runtime.startTransport(
                    socketPath: context.measurementPolicy.controlSocketPath
                )
                guard try runtime.hasTimeRemaining(before: deadline) else {
                    throw VoicePerformanceTracerCollectorProcessError
                        .deadlineExpired
                }
            } catch let error as VoicePerformanceTracerCollectorProcessError {
                throw error
            } catch is VoicePerformanceTracerTransportError {
                throw VoicePerformanceTracerCollectorProcessError
                    .transportFailure
            } catch is VoicePerformanceTracerProcessError {
                throw VoicePerformanceTracerCollectorProcessError
                    .transportFailure
            } catch {
                throw VoicePerformanceTracerCollectorProcessError
                    .internalFailure
            }

            let driverExecutable = context.measurementPolicy.driver
                .expectedExecutablePath
            let driverArguments = [
                driverExecutable,
                "--tracer-bundle", context.outerPath,
                "--deadline-continuous-ns",
                deadline.processDeadline.encoded,
            ]
            let generation: VoicePerformanceSupervisedProcessGeneration
            do {
                generation = try runtime.launchPreparedDriver(
                    executablePath: driverExecutable,
                    argv: driverArguments
                )
                driverOwnershipAcquired = true
            } catch {
                throw Self.mapLaunchError(error)
            }
            guard generation.pid > 1,
                  generation.startToken > 0,
                  generation.processGroupID == generation.pid
            else {
                throw VoicePerformanceTracerCollectorProcessError
                    .driverGenerationMismatch
            }

            do {
                try runtime.bindLaunchedDriver(
                    VoicePerformanceTracerLaunchedDriverIdentity(
                        role: .driver,
                        pid: generation.pid,
                        processStartToken: generation.startToken,
                        processGroupID: generation.processGroupID
                    )
                )
            } catch is VoicePerformanceTracerTransportError {
                throw VoicePerformanceTracerCollectorProcessError
                    .transportFailure
            } catch {
                throw VoicePerformanceTracerCollectorProcessError
                    .internalFailure
            }

            let result: VoicePerformanceTracerResult
            do {
                result = try runtime.collect(
                    request,
                    deadline: deadline.collectorDeadline
                )
            } catch VoicePerformanceTracerCollectorError.internalFailure {
                throw VoicePerformanceTracerCollectorProcessError
                    .internalFailure
            } catch is VoicePerformanceTracerCollectorError {
                throw VoicePerformanceTracerCollectorProcessError
                    .collectionFailed
            } catch {
                throw VoicePerformanceTracerCollectorProcessError
                    .internalFailure
            }
            guard !result.authenticatedProductionDriver,
                  result.driverAttestation.pid == generation.pid,
                  result.driverAttestation.processStartToken
                    == generation.startToken
            else {
                throw VoicePerformanceTracerCollectorProcessError
                    .driverAttestationMismatch
            }

            do {
                try runtime.waitForSucceededDriver(before: deadline)
            } catch is VoicePerformanceTracerProcessError {
                throw VoicePerformanceTracerCollectorProcessError
                    .driverExitFailed
            } catch {
                throw VoicePerformanceTracerCollectorProcessError
                    .internalFailure
            }

            do {
                guard try runtime.hasTimeRemaining(before: deadline) else {
                    throw VoicePerformanceTracerCollectorProcessError
                        .deadlineExpired
                }
            } catch let error as VoicePerformanceTracerCollectorProcessError {
                throw error
            } catch is VoicePerformanceTracerProcessError {
                throw VoicePerformanceTracerCollectorProcessError
                    .deadlineFailure
            } catch {
                throw VoicePerformanceTracerCollectorProcessError
                    .internalFailure
            }

            let canonical: Data
            do {
                canonical = try result.encodedCanonical()
                guard try VoicePerformanceTracerResult
                    .decodeCanonical(canonical) == result
                else {
                    throw VoicePerformanceTracerCollectorProcessError
                        .resultCanonicalizationFailed
                }
            } catch let error as VoicePerformanceTracerCollectorProcessError {
                throw error
            } catch is VoicePerformanceTracerCollectorError {
                throw VoicePerformanceTracerCollectorProcessError
                    .resultCanonicalizationFailed
            } catch {
                throw VoicePerformanceTracerCollectorProcessError
                    .internalFailure
            }

            do {
                guard try runtime.hasTimeRemaining(before: deadline) else {
                    throw VoicePerformanceTracerCollectorProcessError
                        .deadlineExpired
                }
            } catch let error as VoicePerformanceTracerCollectorProcessError {
                throw error
            } catch is VoicePerformanceTracerProcessError {
                throw VoicePerformanceTracerCollectorProcessError
                    .deadlineFailure
            } catch {
                throw VoicePerformanceTracerCollectorProcessError
                    .internalFailure
            }

            closeTransportOnce()
            do {
                try runtime.writeResult(
                    canonical,
                    to: arguments.resultPath,
                    before: deadline.processDeadline
                )
            } catch VoicePerformanceTracerProcessError.invalidResultPath {
                // Syntax was already accepted before bundle verification.
                // A later rejection is the writer's filesystem-authority
                // gate, not caller usage.
                throw VoicePerformanceTracerCollectorProcessError
                    .resultPathAuthority
            } catch {
                throw Self.mapProcessError(
                    error,
                    fallback: .resultWriteFailed
                )
            }
            driverOwnershipAcquired = false
        } catch {
            let primary = Self.normalize(error)
            closeTransportOnce()
            if driverOwnershipAcquired {
                do {
                    try runtime.terminateDriverGroupAndReap()
                } catch is VoicePerformanceTracerProcessError {
                    if primary == .resultInstallationIndeterminate {
                        throw primary
                    }
                    throw VoicePerformanceTracerCollectorProcessError
                        .cleanupFailed
                } catch {
                    if primary == .resultInstallationIndeterminate {
                        throw primary
                    }
                    throw VoicePerformanceTracerCollectorProcessError
                        .internalFailure
                }
            }
            throw primary
        }
    }

    private static func normalize(
        _ error: Error
    ) -> VoicePerformanceTracerCollectorProcessError {
        if let error = error as? VoicePerformanceTracerCollectorProcessError {
            return error
        }
        return .internalFailure
    }

    private static func resultPathOverlapsProtectedInput(
        _ resultPath: String,
        context: VoicePerformanceTracerCollectorVerifiedContext
    ) -> Bool {
        let outer = context.outerPath
        let policy = context.measurementPolicy
        let protectedPaths = [
            outer,
            outer
                + "/Contents/Resources/VoicePerformanceMeasurementPolicy.json",
            outer
                + "/Contents/Resources/VoicePerformanceDriverPolicy.json",
            policy.collector.expectedExecutablePath,
            policy.driver.expectedExecutablePath,
            policy.helper.expectedExecutablePath,
            policy.evaluationArtifact.directory,
            policy.controlSocketPath,
        ]
        return protectedPaths.contains {
            lexicallyOverlaps(resultPath, $0)
        }
    }

    private static func lexicallyOverlaps(
        _ left: String,
        _ right: String
    ) -> Bool {
        let leftComponents = left.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        let rightComponents = right.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        return leftComponents.starts(with: rightComponents)
            || rightComponents.starts(with: leftComponents)
    }

    private static func mapProcessError(
        _ error: Error,
        fallback: VoicePerformanceTracerCollectorProcessError
    ) -> VoicePerformanceTracerCollectorProcessError {
        guard let error = error as? VoicePerformanceTracerProcessError else {
            return .internalFailure
        }
        return switch error {
        case .invalidArguments:
            .invalidArguments
        case .invalidTracerBundle:
            .invalidTracerBundle
        case .invalidResultPath:
            .invalidResultPath
        case .invalidDeadline, .clockFailure:
            .deadlineFailure
        case .deadlineExpired:
            .deadlineExpired
        case .resultAlreadyExists:
            .resultAlreadyExists
        case .resultWriteFailed:
            .resultWriteFailed
        case .resultCommitFailed:
            .resultCommitFailed
        case .resultDurabilityFailed:
            .resultDurabilityFailed
        case .resultInstallationIndeterminate:
            .resultInstallationIndeterminate
        case .processGenerationMismatch:
            .driverGenerationMismatch
        case .processSpawnFailed:
            .driverLaunchFailed
        case .processGroupFailure, .processTerminationTimedOut,
             .processWaitFailed, .processExitedUnsuccessfully:
            fallback
        case .processCleanupFailed:
            .cleanupFailed
        case .invalidTrial:
            fallback
        }
    }

    private static func mapLaunchError(
        _ error: Error
    ) -> VoicePerformanceTracerCollectorProcessError {
        if let error = error as? VoicePerformanceTracerProcessError {
            switch error {
            case .processGroupFailure, .processTerminationTimedOut,
                 .processWaitFailed, .processCleanupFailed:
                return .cleanupFailed
            default:
                break
            }
        }
        return mapProcessError(error, fallback: .driverLaunchFailed)
    }
}
