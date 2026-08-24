import Foundation
import RimeAIVoicePerformanceControlCore
import RimeAIVoicePerformanceControlDarwin
import RimeAIVoicePerformanceTracerProcessDarwin
import Security

public final class DarwinVoicePerformanceTracerDriverRuntime:
    VoicePerformanceTracerDriverCommandRuntime,
    @unchecked Sendable
{
    private let supervisor = VoicePerformanceDriverHelperSupervisor()
    private let spawner = VoicePerformanceSecureChildSpawner()

    public init() {}

    public func currentContinuousNanoseconds() throws -> UInt64 {
        try VoicePerformanceContinuousDeadline.currentNanoseconds()
    }

    public func currentDriverGeneration() throws
        -> VoicePerformanceSupervisedProcessGeneration
    {
        try VoicePerformanceLiveProcessGenerationReader()
            .currentGeneration()
    }

    public func bindCurrentDriver(
        expected: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        try supervisor.bindCurrentDriver(expected: expected)
    }

    public func connect(
        socketPath: String,
        expectedCollector: PerformanceControlExpectedPeerIdentity,
        deadline: VoicePerformanceContinuousDeadline
    ) throws -> any VoicePerformanceTracerDriverConnection {
        do {
            let connection = try DarwinPerformanceControlUnixClient
                .connectAuthenticated(
                    socketPath: socketPath,
                    expectedCollector: expectedCollector,
                    deadline: try
                        VoicePerformanceDriverTransportDeadlineConverter()
                            .instant(for: deadline)
                )
            return DarwinVoicePerformanceTracerDriverConnection(
                connection
            )
        } catch {
            if let known = VoicePerformanceDriverTransportErrorNormalizer
                .normalize(error)
            {
                throw known
            }
            throw error
        }
    }

    public func spawnHelper(
        _ request: VoicePerformanceHelperSpawnRequest,
        joiningProcessGroup processGroupID: Int32
    ) throws -> VoicePerformanceSupervisedProcessGeneration {
        guard supervisor.currentDriverGeneration?.processGroupID
                == processGroupID
        else {
            throw VoicePerformanceTracerDriverCommandError
                .invalidDriverGeneration
        }
        return try spawner.spawnHelper(
            request: request,
            supervisedBy: supervisor
        )
    }

    public func reapSucceededHelper(
        expected: VoicePerformanceSupervisedProcessGeneration,
        deadline: VoicePerformanceContinuousDeadline
    ) throws {
        do {
            _ = try supervisor.waitForSucceededHelper(
                exactGeneration: expected,
                until: deadline
            )
        } catch VoicePerformanceTracerProcessError
            .processTerminationTimedOut
        {
            throw VoicePerformanceTracerDriverConnectionError.timedOut
        }
    }

    public func terminateHelperAndReap(
        expected: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        try supervisor.abortSpawnedHelper(
            exactGeneration: expected
        )
    }

    public func securePeerNonce() throws -> PerformanceControlNonce {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        ) == errSecSuccess
        else {
            throw VoicePerformanceTracerDriverCommandError.transportFailed
        }
        return try PerformanceControlNonce(
            bytes.map { String(format: "%02x", $0) }.joined()
        )
    }
}

private final class DarwinVoicePerformanceTracerDriverConnection:
    VoicePerformanceTracerDriverConnection,
    @unchecked Sendable
{
    private let connection:
        DarwinPerformanceControlAuthenticatedConnection

    init(
        _ connection: DarwinPerformanceControlAuthenticatedConnection
    ) {
        self.connection = connection
    }

    func receive(
        deadline: VoicePerformanceContinuousDeadline
    ) throws -> PerformanceControlWireFrame {
        do {
            return try connection.receive(
                deadline: try
                    VoicePerformanceDriverTransportDeadlineConverter()
                        .instant(for: deadline)
            )
        } catch {
            if let known = VoicePerformanceDriverTransportErrorNormalizer
                .normalize(error)
            {
                throw known
            }
            throw error
        }
    }

    func send(
        _ frame: PerformanceControlWireFrame,
        deadline: VoicePerformanceContinuousDeadline
    ) throws {
        do {
            try connection.send(
                frame,
                deadline: try
                    VoicePerformanceDriverTransportDeadlineConverter()
                        .instant(for: deadline)
            )
        } catch {
            if let known = VoicePerformanceDriverTransportErrorNormalizer
                .normalize(error)
            {
                throw known
            }
            throw error
        }
    }

    func close() {
        connection.close()
    }
}

enum VoicePerformanceDriverTransportErrorNormalizer {
    static func normalize(
        _ error: Error
    ) -> VoicePerformanceTracerDriverConnectionError? {
        if let typed =
            error as? VoicePerformanceTracerDriverConnectionError
        {
            return typed
        }
        if error is VoicePerformanceTracerProcessError {
            return .failed
        }
        guard let transport = error as? PerformanceControlTransportError
        else { return nil }
        return switch transport {
        case .operationTimedOut:
            .timedOut
        case .peerDisconnected:
            .peerDisconnected
        default:
            .failed
        }
    }
}

struct VoicePerformanceDriverTransportDeadlineConverter {
    private let baseInstant: () -> ContinuousClock.Instant
    private let remainingNanoseconds:
        (VoicePerformanceContinuousDeadline) throws -> UInt64

    init(
        baseInstant: @escaping () -> ContinuousClock.Instant = {
            ContinuousClock().now
        },
        remainingNanoseconds: @escaping (
            VoicePerformanceContinuousDeadline
        ) throws -> UInt64 = {
            try $0.remainingNanoseconds()
        }
    ) {
        self.baseInstant = baseInstant
        self.remainingNanoseconds = remainingNanoseconds
    }

    func instant(
        for deadline: VoicePerformanceContinuousDeadline
    ) throws -> ContinuousClock.Instant {
        // Capture the target clock's base first. Sampling mach remaining time
        // afterwards can only make the converted deadline earlier, never
        // later than the absolute global deadline.
        let base = baseInstant()
        let remaining = try remainingNanoseconds(deadline)
        guard remaining > 0 else {
            throw VoicePerformanceTracerDriverConnectionError.timedOut
        }
        let duration = min(remaining, UInt64(Int64.max))
        return base.advanced(by: .nanoseconds(Int64(duration)))
    }
}
